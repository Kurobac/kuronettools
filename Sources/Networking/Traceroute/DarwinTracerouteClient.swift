import Darwin
import Foundation
import NetToolCore

// The ICMP traceroute flow is adapted from 453jerry/NetDiagnosis.
// The original MIT license is stored in Vendor/Licenses/NetDiagnosis-MIT.txt.
struct DarwinTracerouteClient: Sendable {
    func events(
        for configuration: TracerouteConfiguration
    ) -> AsyncStream<TracerouteEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TracerouteEvent.self
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
        configuration: TracerouteConfiguration,
        continuation: AsyncStream<TracerouteEvent>.Continuation
    ) async {
        do {
            let configuration = try configuration.validated()
            let endpoint = try DarwinPingClient.resolve(
                host: configuration.host,
                preference: configuration.addressFamily
            )
            let descriptor = try DarwinPingClient.openSocket(
                for: endpoint
            )
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

            let identifier = UInt16.random(
                in: 1 ..< UInt16.max
            )
            var sequence: UInt16 = 0

            for hop in 1 ... configuration.maxHops {
                try Task.checkCancellation()
                try setHopLimit(
                    descriptor: descriptor,
                    endpoint: endpoint,
                    hop: hop
                )

                var reachedDestination = false
                for probeIndex in 1 ... configuration.probesPerHop {
                    try Task.checkCancellation()
                    sequence &+= 1

                    let result: TracerouteProbeResult
                    switch try probe(
                        descriptor: descriptor,
                        endpoint: endpoint,
                        identifier: identifier,
                        sequence: sequence,
                        payloadSize: configuration.payloadSize,
                        timeoutSeconds:
                            configuration.timeoutSeconds
                    ) {
                    case .response(let response):
                        let tracerouteResponse = TracerouteResponse(
                            hop: hop,
                            probeIndex: probeIndex,
                            sequence: sequence,
                            address: response.address,
                            roundTripTimeMilliseconds:
                                response.roundTripTimeMilliseconds,
                            kind: response.kind
                        )
                        result = .response(tracerouteResponse)
                        if response.kind == .destination {
                            reachedDestination = true
                        }
                    case .timeout:
                        result = .timeout(
                            hop: hop,
                            probeIndex: probeIndex,
                            sequence: sequence
                        )
                    }
                    continuation.yield(.probe(result))
                }

                if reachedDestination {
                    continuation.yield(
                        .completed(
                            .reachedDestination(hop: hop)
                        )
                    )
                    continuation.finish()
                    return
                }
            }

            try Task.checkCancellation()
            continuation.yield(.completed(.maxHopsReached))
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

private extension DarwinTracerouteClient {
    struct ReceivedResponse {
        let address: String
        let roundTripTimeMilliseconds: Double
        let kind: TracerouteResponseKind
    }

    enum ProbeOutcome {
        case response(ReceivedResponse)
        case timeout
    }

    static func setHopLimit(
        descriptor: Int32,
        endpoint: DarwinPingClient.ResolvedEndpoint,
        hop: Int
    ) throws {
        var value = Int32(hop)
        let result = withUnsafePointer(to: &value) { pointer in
            if endpoint.family == AF_INET {
                Darwin.setsockopt(
                    descriptor,
                    IPPROTO_IP,
                    IP_TTL,
                    pointer,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            } else {
                Darwin.setsockopt(
                    descriptor,
                    IPPROTO_IPV6,
                    IPV6_UNICAST_HOPS,
                    pointer,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
        }

        guard result == 0 else {
            throw DarwinPingClient.socketError(
                operation: "设置 TTL/Hop Limit"
            )
        }
    }

    static func probe(
        descriptor: Int32,
        endpoint: DarwinPingClient.ResolvedEndpoint,
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
            withUnsafePointer(to: &destination) {
                destinationPointer in
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
            throw DarwinPingClient.socketError(
                operation: "发送 Traceroute ICMP 请求"
            )
        }
        guard sentCount == packet.count else {
            throw DarwinPingClient.ClientError.partialSend(
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
                throw DarwinPingClient.socketError(
                    operation: "等待 Traceroute ICMP 响应"
                )
            }
            if pollResult == 0 {
                continue
            }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else {
                throw DarwinPingClient.ClientError
                    .unexpectedPollEvents(
                        pollDescriptor.revents
                    )
            }

            guard let received = try DarwinPingClient.receive(
                descriptor: descriptor,
                family: endpoint.family
            ),
            let offset = DarwinPingClient.icmpOffset(
                in: received.bytes,
                family: endpoint.icmpAddressFamily
            ),
            let header = ICMPPacketCodec.parseHeader(
                from: received.bytes,
                offset: offset
            ) else {
                continue
            }

            let kind: TracerouteResponseKind
            if received.sourceAddress == endpoint.address,
               ICMPPacketCodec.isEchoReply(
                header,
                family: endpoint.icmpAddressFamily,
                identifier: identifier,
                sequence: sequence
            ) {
                kind = .destination
            } else if ICMPPacketCodec.isTimeExceededResponse(
                in: received.bytes,
                offset: offset,
                family: endpoint.icmpAddressFamily,
                identifier: identifier,
                sequence: sequence
            ) {
                kind = .hop
            } else {
                continue
            }

            let elapsedNanoseconds =
                DispatchTime.now().uptimeNanoseconds - startedAt
            return .response(
                ReceivedResponse(
                    address: received.sourceAddress,
                    roundTripTimeMilliseconds:
                        Double(elapsedNanoseconds) / 1_000_000,
                    kind: kind
                )
            )
        }

        return .timeout
    }
}
