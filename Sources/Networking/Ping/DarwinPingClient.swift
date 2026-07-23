import Darwin
import Foundation
import NetToolCore

// The ICMP datagram socket approach is adapted from 453jerry/NetDiagnosis.
// The original MIT license is stored in Vendor/Licenses/NetDiagnosis-MIT.txt.
struct DarwinPingClient: Sendable {
    func events(
        for configuration: PingConfiguration
    ) -> AsyncStream<PingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PingEvent.self
        )

        let producer = Task.detached(priority: .userInitiated) {
            await Self.run(
                configuration: configuration,
                continuation: continuation
            )
        }

        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }

        return stream
    }

    private static func run(
        configuration: PingConfiguration,
        continuation: AsyncStream<PingEvent>.Continuation
    ) async {
        var transmitted = 0
        var roundTripTimes: [Double] = []

        do {
            let configuration = try configuration.validated()
            let endpoint = try resolve(
                host: configuration.host,
                preference: configuration.addressFamily
            )
            let descriptor = try openSocket(for: endpoint)
            defer {
                Darwin.close(descriptor)
            }

            continuation.yield(
                .started(
                    PingResolvedTarget(
                        host: configuration.host,
                        address: endpoint.address,
                        family: endpoint.pingAddressFamily
                    )
                )
            )

            let identifier = UInt16.random(in: 1 ..< UInt16.max)

            for probeIndex in 0 ..< configuration.count {
                try Task.checkCancellation()

                let sequence = UInt16(probeIndex + 1)
                transmitted += 1

                switch try probe(
                    descriptor: descriptor,
                    endpoint: endpoint,
                    identifier: identifier,
                    sequence: sequence,
                    payloadSize: configuration.payloadSize,
                    timeoutSeconds: configuration.timeoutSeconds
                ) {
                case .reply(let reply):
                    roundTripTimes.append(
                        reply.roundTripTimeMilliseconds
                    )
                    continuation.yield(.reply(reply))
                case .timeout:
                    continuation.yield(.timeout(sequence: sequence))
                }

                if probeIndex + 1 < configuration.count {
                    try await Task.sleep(
                        for: .seconds(configuration.intervalSeconds)
                    )
                }
            }

            try Task.checkCancellation()
            continuation.yield(
                .completed(
                    PingSummary(
                        transmitted: transmitted,
                        roundTripTimesMilliseconds: roundTripTimes
                    )
                )
            )
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.yield(
                .failed(message: error.localizedDescription)
            )
            continuation.finish()
        }
    }
}

private extension DarwinPingClient {
    struct ResolvedEndpoint {
        let storage: sockaddr_storage
        let length: socklen_t
        let family: Int32
        let address: String

        var icmpAddressFamily: ICMPAddressFamily {
            family == AF_INET ? .ipv4 : .ipv6
        }

        var pingAddressFamily: PingAddressFamily {
            family == AF_INET ? .ipv4 : .ipv6
        }
    }

    struct ReceivedPacket {
        let bytes: [UInt8]
        let sourceAddress: String
        let hopLimit: Int
    }

    enum ProbeOutcome {
        case reply(PingReply)
        case timeout
    }

    enum ClientError: Error, LocalizedError {
        case resolutionFailed(host: String, code: Int32, message: String)
        case noAddress(host: String)
        case socketFailure(operation: String, code: Int32, message: String)
        case unexpectedPollEvents(Int16)
        case partialSend(expected: Int, actual: Int)
        case missingHopLimit
        case invalidSourceAddress

        var errorDescription: String? {
            switch self {
            case .resolutionFailed(let host, let code, let message):
                "无法解析 \(host)：\(message)（\(code)）"
            case .noAddress(let host):
                "没有找到符合地址族要求的地址：\(host)"
            case .socketFailure(let operation, let code, let message):
                "\(operation) 失败：\(message)（errno \(code)）"
            case .unexpectedPollEvents(let events):
                "ICMP socket 返回了异常轮询事件：\(events)"
            case .partialSend(let expected, let actual):
                "ICMP 报文未完整发送：应发送 \(expected) 字节，实际 \(actual) 字节。"
            case .missingHopLimit:
                "响应中缺少 TTL 或 Hop Limit 控制信息。"
            case .invalidSourceAddress:
                "无法读取 ICMP 响应的来源地址。"
            }
        }
    }

    static func resolve(
        host: String,
        preference: PingAddressFamily
    ) throws -> ResolvedEndpoint {
        var hints = addrinfo()
        hints.ai_family = {
            switch preference {
            case .automatic:
                AF_UNSPEC
            case .ipv4:
                AF_INET
            case .ipv6:
                AF_INET6
            }
        }()
        hints.ai_socktype = SOCK_DGRAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)

        guard status == 0 else {
            let message = gai_strerror(status).map {
                String(cString: $0)
            } ?? "Unknown resolver error"
            throw ClientError.resolutionFailed(
                host: host,
                code: status,
                message: message
            )
        }
        defer {
            if let result {
                freeaddrinfo(result)
            }
        }

        var cursor = result
        while let info = cursor?.pointee {
            defer {
                cursor = info.ai_next
            }

            guard info.ai_family == AF_INET || info.ai_family == AF_INET6,
                  let source = info.ai_addr else {
                continue
            }

            var storage = sockaddr_storage()
            _ = withUnsafeMutablePointer(to: &storage) { destination in
                memcpy(destination, source, Int(info.ai_addrlen))
            }

            let address = try numericAddress(
                storage: storage,
                length: info.ai_addrlen
            )

            return ResolvedEndpoint(
                storage: storage,
                length: info.ai_addrlen,
                family: info.ai_family,
                address: address
            )
        }

        throw ClientError.noAddress(host: host)
    }

    static func openSocket(
        for endpoint: ResolvedEndpoint
    ) throws -> Int32 {
        let protocolNumber = endpoint.family == AF_INET
            ? IPPROTO_ICMP
            : IPPROTO_ICMPV6
        let descriptor = Darwin.socket(
            endpoint.family,
            SOCK_DGRAM,
            protocolNumber
        )

        guard descriptor >= 0 else {
            throw socketError(operation: "创建 ICMP socket")
        }

        do {
            var enabled: Int32 = 1
            let optionResult = withUnsafePointer(to: &enabled) { pointer in
                if endpoint.family == AF_INET {
                    Darwin.setsockopt(
                        descriptor,
                        IPPROTO_IP,
                        IP_RECVTTL,
                        pointer,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                } else {
                    Darwin.setsockopt(
                        descriptor,
                        IPPROTO_IPV6,
                        IPV6_2292HOPLIMIT,
                        pointer,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                }
            }

            guard optionResult == 0 else {
                throw socketError(operation: "启用 TTL/Hop Limit 接收")
            }

            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func probe(
        descriptor: Int32,
        endpoint: ResolvedEndpoint,
        identifier: UInt16,
        sequence: UInt16,
        payloadSize: Int,
        timeoutSeconds: Double
    ) throws -> ProbeOutcome {
        try Task.checkCancellation()

        let packet = ICMPPacketCodec.makeEchoRequest(
            family: endpoint.icmpAddressFamily,
            identifier: identifier,
            sequence: sequence,
            payloadSize: payloadSize
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds

        var destination = endpoint.storage
        let sentCount = packet.withUnsafeBytes { packetPointer in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { socketAddress in
                    Darwin.sendto(
                        descriptor,
                        packetPointer.baseAddress,
                        packetPointer.count,
                        0,
                        socketAddress,
                        endpoint.length
                    )
                }
            }
        }

        guard sentCount >= 0 else {
            throw socketError(operation: "发送 ICMP 请求")
        }
        guard sentCount == packet.count else {
            throw ClientError.partialSend(
                expected: packet.count,
                actual: sentCount
            )
        }

        let timeoutNanoseconds = UInt64(
            timeoutSeconds * 1_000_000_000
        )
        let deadline = startedAt + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()

            let now = DispatchTime.now().uptimeNanoseconds
            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = Int32(
                max(
                    1,
                    min(
                        100,
                        Int(remainingNanoseconds / 1_000_000)
                    )
                )
            )

            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                remainingMilliseconds
            )

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw socketError(operation: "等待 ICMP 响应")
            }
            if pollResult == 0 {
                continue
            }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else {
                throw ClientError.unexpectedPollEvents(
                    pollDescriptor.revents
                )
            }

            guard let received = try receive(
                descriptor: descriptor,
                family: endpoint.family
            ) else {
                continue
            }
            guard received.sourceAddress == endpoint.address,
                  let offset = icmpOffset(
                    in: received.bytes,
                    family: endpoint.icmpAddressFamily
                  ),
                  let header = ICMPPacketCodec.parseHeader(
                    from: received.bytes,
                    offset: offset
                  ),
                  ICMPPacketCodec.isEchoReply(
                    header,
                    family: endpoint.icmpAddressFamily,
                    identifier: identifier,
                    sequence: sequence
                  ) else {
                continue
            }

            let elapsedNanoseconds =
                DispatchTime.now().uptimeNanoseconds - startedAt
            let byteCount = received.bytes.count - offset

            return .reply(
                PingReply(
                    sequence: sequence,
                    address: received.sourceAddress,
                    byteCount: byteCount,
                    hopLimit: received.hopLimit,
                    roundTripTimeMilliseconds:
                        Double(elapsedNanoseconds) / 1_000_000
                )
            )
        }

        return .timeout
    }

    static func receive(
        descriptor: Int32,
        family: Int32
    ) throws -> ReceivedPacket? {
        var receiveBuffer = [UInt8](repeating: 0, count: 2_048)
        var controlBuffer = [UInt8](repeating: 0, count: 256)
        var source = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var controlLength = 0

        let receivedCount = receiveBuffer.withUnsafeMutableBytes {
            receivePointer in
            controlBuffer.withUnsafeMutableBytes { controlPointer in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    var vector = iovec(
                        iov_base: receivePointer.baseAddress,
                        iov_len: receivePointer.count
                    )

                    return withUnsafeMutablePointer(to: &vector) {
                        vectorPointer in
                        var message = msghdr(
                            msg_name: sourcePointer,
                            msg_namelen: sourceLength,
                            msg_iov: vectorPointer,
                            msg_iovlen: 1,
                            msg_control: controlPointer.baseAddress,
                            msg_controllen: socklen_t(controlPointer.count),
                            msg_flags: 0
                        )

                        let count = Darwin.recvmsg(
                            descriptor,
                            &message,
                            0
                        )
                        sourceLength = message.msg_namelen
                        controlLength = Int(message.msg_controllen)
                        return count
                    }
                }
            }
        }

        guard receivedCount >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return nil
            }
            throw socketError(operation: "接收 ICMP 响应")
        }

        let hopLimit = try parseHopLimit(
            from: controlBuffer,
            validLength: controlLength,
            family: family
        )
        let sourceAddress = try numericAddress(
            storage: source,
            length: sourceLength
        )

        return ReceivedPacket(
            bytes: Array(receiveBuffer.prefix(Int(receivedCount))),
            sourceAddress: sourceAddress,
            hopLimit: hopLimit
        )
    }

    static func parseHopLimit(
        from controlBuffer: [UInt8],
        validLength: Int,
        family: Int32
    ) throws -> Int {
        let headerSize = MemoryLayout<cmsghdr>.size
        // Darwin's CMSG_DATA/CMSG_NXTHDR macros use __DARWIN_ALIGN32.
        let alignment = MemoryLayout<UInt32>.size
        var offset = 0

        while offset + headerSize <= validLength {
            let header: cmsghdr = controlBuffer.withUnsafeBytes { pointer in
                pointer.loadUnaligned(
                    fromByteOffset: offset,
                    as: cmsghdr.self
                )
            }
            let messageLength = Int(header.cmsg_len)
            guard messageLength >= headerSize,
                  offset + messageLength <= validLength else {
                break
            }

            let dataOffset = offset + aligned(
                headerSize,
                to: alignment
            )

            if family == AF_INET,
               header.cmsg_level == IPPROTO_IP,
               header.cmsg_type == IP_RECVTTL,
               dataOffset < validLength {
                return Int(controlBuffer[dataOffset])
            }

            if family == AF_INET6,
               header.cmsg_level == IPPROTO_IPV6,
               header.cmsg_type == IPV6_2292HOPLIMIT,
               dataOffset + MemoryLayout<Int32>.size <= validLength {
                let value: Int32 = controlBuffer.withUnsafeBytes { pointer in
                    pointer.loadUnaligned(
                        fromByteOffset: dataOffset,
                        as: Int32.self
                    )
                }
                return Int(value)
            }

            offset += aligned(messageLength, to: alignment)
        }

        throw ClientError.missingHopLimit
    }

    static func icmpOffset(
        in packet: [UInt8],
        family: ICMPAddressFamily
    ) -> Int? {
        switch family {
        case .ipv4:
            guard packet.count >= 20,
                  packet[0] >> 4 == 4,
                  packet[9] == UInt8(IPPROTO_ICMP) else {
                return nil
            }

            let headerLength = Int(packet[0] & 0x0f) * 4
            guard headerLength >= 20,
                  packet.count >= headerLength
                    + ICMPPacketCodec.headerLength else {
                return nil
            }
            return headerLength
        case .ipv6:
            guard packet.count >= ICMPPacketCodec.headerLength else {
                return nil
            }
            return 0
        }
    }

    static func numericAddress(
        storage: sockaddr_storage,
        length: socklen_t
    ) throws -> String {
        var storage = storage
        var hostBuffer = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )

        let status = withUnsafePointer(to: &storage) { storagePointer in
            storagePointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                getnameinfo(
                    socketAddress,
                    length,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }

        guard status == 0 else {
            throw ClientError.invalidSourceAddress
        }

        let addressBytes = hostBuffer.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        return String(decoding: addressBytes, as: UTF8.self)
    }

    static func socketError(operation: String) -> ClientError {
        let code = errno
        let message = strerror(code).map {
            String(cString: $0)
        } ?? "Unknown POSIX error"

        return .socketFailure(
            operation: operation,
            code: code,
            message: message
        )
    }

    static func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
