import Darwin
import Foundation
import NetToolCore

enum DarwinTCPPortScanSocket {
    struct Endpoint: @unchecked Sendable {
        let storage: sockaddr_storage
        let length: socklen_t
        let family: Int32
        let address: String

        var addressFamily: TCPAddressFamily {
            family == AF_INET ? .ipv4 : .ipv6
        }
    }

    struct PendingConnection {
        let descriptor: Int32
        let port: Int
        let startedAt: UInt64
        let deadline: UInt64
    }

    struct ConnectionResult {
        let port: Int
        let outcome: TCPPortScanOutcome
        let timeoutOrigin: TCPPortScanTimeoutOrigin?
    }

    enum StartResult {
        case completed(ConnectionResult)
        case pending(PendingConnection)
    }

    enum SocketError: Error, LocalizedError {
        case resolutionFailed(
            host: String,
            code: Int32,
            message: String
        )
        case noAddress(host: String)
        case resourceExhausted(
            operation: String,
            code: Int32,
            message: String
        )
        case socketFailure(
            operation: String,
            code: Int32,
            message: String
        )
        case invalidNumericAddress

        var errorDescription: String? {
            switch self {
            case .resolutionFailed(
                let host,
                let code,
                let message
            ):
                "无法解析 \(host)：\(message)（\(code)）"
            case .noAddress(let host):
                "没有找到符合地址族要求的地址：\(host)"
            case .resourceExhausted(
                let operation,
                let code,
                let message
            ):
                "\(operation) 时本机 socket 资源不足："
                    + "\(message)（errno \(code)）"
            case .socketFailure(
                let operation,
                let code,
                let message
            ):
                "\(operation) 失败：\(message)（errno \(code)）"
            case .invalidNumericAddress:
                "无法读取扫描目标的数字地址。"
            }
        }
    }

    static func resolve(
        host: String,
        addressFamily: TCPAddressFamily
    ) throws -> Endpoint {
        var hints = addrinfo()
        hints.ai_family = {
            switch addressFamily {
            case .automatic:
                AF_UNSPEC
            case .ipv4:
                AF_INET
            case .ipv6:
                AF_INET6
            }
        }()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)

        guard status == 0 else {
            let message = gai_strerror(status).map {
                String(cString: $0)
            } ?? "Unknown resolver error"
            throw SocketError.resolutionFailed(
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

            guard info.ai_family == AF_INET
                    || info.ai_family == AF_INET6,
                  let source = info.ai_addr else {
                continue
            }

            var storage = sockaddr_storage()
            _ = withUnsafeMutablePointer(to: &storage) { destination in
                memcpy(destination, source, Int(info.ai_addrlen))
            }

            return Endpoint(
                storage: storage,
                length: info.ai_addrlen,
                family: info.ai_family,
                address: try numericAddress(
                    storage: storage,
                    length: info.ai_addrlen
                )
            )
        }

        throw SocketError.noAddress(host: host)
    }

    static func start(
        endpoint: Endpoint,
        port: Int,
        timeoutSeconds: Double
    ) throws -> StartResult {
        let descriptor = Darwin.socket(
            endpoint.family,
            SOCK_STREAM,
            IPPROTO_TCP
        )
        guard descriptor >= 0 else {
            throw socketError(operation: "创建 TCP socket")
        }

        do {
            let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0 else {
                throw socketError(operation: "读取 TCP socket 标志")
            }
            guard Darwin.fcntl(
                descriptor,
                F_SETFL,
                flags | O_NONBLOCK
            ) == 0 else {
                throw socketError(operation: "启用非阻塞 TCP socket")
            }

            var destination = endpoint.storage
            setPort(port, in: &destination, family: endpoint.family)

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let connectResult = withUnsafePointer(to: &destination) {
                destinationPointer in
                destinationPointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { socketAddress in
                    Darwin.connect(
                        descriptor,
                        socketAddress,
                        endpoint.length
                    )
                }
            }

            if connectResult == 0 {
                Darwin.close(descriptor)
                return .completed(
                    ConnectionResult(
                        port: port,
                        outcome: openOutcome(
                            endpoint: endpoint,
                            startedAt: startedAt
                        ),
                        timeoutOrigin: nil
                    )
                )
            }

            let code = errno
            switch code {
            case EINPROGRESS, EALREADY, EINTR:
                let timeoutNanoseconds = UInt64(
                    timeoutSeconds * 1_000_000_000
                )
                return .pending(
                    PendingConnection(
                        descriptor: descriptor,
                        port: port,
                        startedAt: startedAt,
                        deadline: startedAt + timeoutNanoseconds
                    )
                )
            case EISCONN:
                Darwin.close(descriptor)
                return .completed(
                    ConnectionResult(
                        port: port,
                        outcome: openOutcome(
                            endpoint: endpoint,
                            startedAt: startedAt
                        ),
                        timeoutOrigin: nil
                    )
                )
            default:
                let result = try connectionResult(
                    port: port,
                    errorCode: code
                )
                Darwin.close(descriptor)
                return .completed(result)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func finish(
        _ pending: PendingConnection,
        endpoint: Endpoint
    ) throws -> ConnectionResult {
        defer {
            Darwin.close(pending.descriptor)
        }

        var errorCode: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        let status = withUnsafeMutablePointer(to: &errorCode) {
            Darwin.getsockopt(
                pending.descriptor,
                SOL_SOCKET,
                SO_ERROR,
                $0,
                &errorLength
            )
        }
        guard status == 0 else {
            throw socketError(operation: "读取 TCP 连接结果")
        }

        guard errorCode != 0 else {
            return ConnectionResult(
                port: pending.port,
                outcome: openOutcome(
                    endpoint: endpoint,
                    startedAt: pending.startedAt
                ),
                timeoutOrigin: nil
            )
        }
        return try connectionResult(
            port: pending.port,
            errorCode: errorCode
        )
    }

    static func timeout(
        _ pending: PendingConnection
    ) -> ConnectionResult {
        Darwin.close(pending.descriptor)
        return ConnectionResult(
            port: pending.port,
            outcome: .timedOut,
            timeoutOrigin: .appDeadline
        )
    }

    static func close(
        _ pendingConnections: [PendingConnection]
    ) {
        for pending in pendingConnections {
            Darwin.close(pending.descriptor)
        }
    }

    static func poll(
        _ descriptors: inout [pollfd],
        timeoutMilliseconds: Int32
    ) throws {
        let result = descriptors.withUnsafeMutableBufferPointer {
            Darwin.poll(
                $0.baseAddress,
                nfds_t($0.count),
                timeoutMilliseconds
            )
        }
        guard result >= 0 else {
            let code = errno
            if code == EINTR {
                return
            }
            throw socketError(
                operation: "轮询 TCP 连接",
                code: code
            )
        }
    }

    private static func connectionResult(
        port: Int,
        errorCode: Int32
    ) throws -> ConnectionResult {
        let outcome: TCPPortScanOutcome
        let timeoutOrigin: TCPPortScanTimeoutOrigin?

        switch errorCode {
        case ECONNREFUSED:
            outcome = .closed
            timeoutOrigin = nil
        case ETIMEDOUT:
            outcome = .timedOut
            timeoutOrigin = .system
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN:
            outcome = .unreachable
            timeoutOrigin = nil
        case ENOBUFS, ENOMEM, EADDRINUSE:
            throw socketError(
                operation: "发起 TCP 连接",
                code: errorCode
            )
        default:
            outcome = .failed(
                message: socketErrorMessage(errorCode)
            )
            timeoutOrigin = nil
        }

        return ConnectionResult(
            port: port,
            outcome: outcome,
            timeoutOrigin: timeoutOrigin
        )
    }

    private static func openOutcome(
        endpoint: Endpoint,
        startedAt: UInt64
    ) -> TCPPortScanOutcome {
        let elapsed =
            DispatchTime.now().uptimeNanoseconds - startedAt
        return .open(
            address: endpoint.address,
            addressFamily: endpoint.addressFamily,
            connectionTimeMilliseconds:
                Double(elapsed) / 1_000_000
        )
    }

    private static func setPort(
        _ port: Int,
        in storage: inout sockaddr_storage,
        family: Int32
    ) {
        withUnsafeMutablePointer(to: &storage) { pointer in
            if family == AF_INET {
                pointer.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) {
                    $0.pointee.sin_port =
                        in_port_t(UInt16(port).bigEndian)
                }
            } else {
                pointer.withMemoryRebound(
                    to: sockaddr_in6.self,
                    capacity: 1
                ) {
                    $0.pointee.sin6_port =
                        in_port_t(UInt16(port).bigEndian)
                }
            }
        }
    }

    private static func numericAddress(
        storage: sockaddr_storage,
        length: socklen_t
    ) throws -> String {
        var storage = storage
        var buffer = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getnameinfo(
                    $0,
                    length,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard status == 0 else {
            throw SocketError.invalidNumericAddress
        }
        let addressBytes = buffer.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        return String(decoding: addressBytes, as: UTF8.self)
    }

    private static func socketError(
        operation: String,
        code: Int32 = errno
    ) -> SocketError {
        let message = socketErrorMessage(code)
        switch code {
        case EMFILE, ENFILE, ENOBUFS, ENOMEM, EADDRINUSE:
            return .resourceExhausted(
                operation: operation,
                code: code,
                message: message
            )
        default:
            return .socketFailure(
                operation: operation,
                code: code,
                message: message
            )
        }
    }

    private static func socketErrorMessage(
        _ code: Int32
    ) -> String {
        strerror(code).map {
            String(cString: $0)
        } ?? "Unknown POSIX error"
    }
}
