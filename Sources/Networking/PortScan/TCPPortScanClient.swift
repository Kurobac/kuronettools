import Foundation
import NetToolCore

struct TCPPortScanClient: Sendable {
    func events(
        for configuration: TCPPortScanConfiguration
    ) -> AsyncStream<TCPPortScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TCPPortScanEvent.self
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
        configuration: TCPPortScanConfiguration,
        continuation: AsyncStream<TCPPortScanEvent>.Continuation
    ) async {
        do {
            let configuration = try configuration.validated()
            continuation.yield(
                .started(totalPorts: configuration.ports.count)
            )

            var portIterator = configuration.ports.makeIterator()
            try await withThrowingTaskGroup(
                of: TCPPortScanResult.self
            ) { group in
                for _ in 0 ..< min(
                    configuration.concurrency,
                    configuration.ports.count
                ) {
                    guard let port = portIterator.next() else {
                        break
                    }
                    group.addTask {
                        try await scan(
                            port: port,
                            configuration: configuration
                        )
                    }
                }

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    continuation.yield(.result(result))

                    if let port = portIterator.next() {
                        group.addTask {
                            try await scan(
                                port: port,
                                configuration: configuration
                            )
                        }
                    }
                }
            }

            try Task.checkCancellation()
            continuation.yield(.completed)
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

    private static func scan(
        port: Int,
        configuration: TCPPortScanConfiguration
    ) async throws -> TCPPortScanResult {
        do {
            let result = try await TCPConnectionClient().connect(
                configuration: TCPConnectionConfiguration(
                    host: configuration.host,
                    port: port,
                    addressFamily: configuration.addressFamily,
                    timeoutSeconds: configuration.timeoutSeconds
                )
            )
            return TCPPortScanResult(
                port: port,
                outcome: .open(
                    address: result.address,
                    addressFamily: result.addressFamily,
                    connectionTimeMilliseconds:
                        result.connectionTimeMilliseconds
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TCPConnectionClientError {
            return try result(
                port: port,
                for: error
            )
        } catch {
            return TCPPortScanResult(
                port: port,
                outcome: .failed(
                    message: error.localizedDescription
                )
            )
        }
    }

    private static func result(
        port: Int,
        for error: TCPConnectionClientError
    ) throws -> TCPPortScanResult {
        let outcome: TCPPortScanOutcome
        switch error {
        case .connectionRefused:
            outcome = .closed
        case .timeout:
            outcome = .timedOut
        case .unreachable:
            outcome = .unreachable
        case .network(let message):
            outcome = .failed(message: message)
        case .dnsFailure(let message):
            throw TCPPortScanClientError.dnsFailure(
                message: message
            )
        case .invalidPort:
            throw TCPPortScanClientError.setup(
                message: "端口无效。"
            )
        case .unexpectedAddressFamily(let expected, let actual):
            throw TCPPortScanClientError.setup(
                message: "实际使用 \(actual.title)，"
                    + "与所选的 \(expected.title) 不一致。"
            )
        case .missingIPOptions:
            throw TCPPortScanClientError.setup(
                message: "系统没有提供所需的 IP 协议选项。"
            )
        case .missingRemoteEndpoint:
            throw TCPPortScanClientError.setup(
                message: "系统没有提供实际远端地址。"
            )
        }
        return TCPPortScanResult(
            port: port,
            outcome: outcome
        )
    }
}

private enum TCPPortScanClientError:
    Error,
    LocalizedError,
    Sendable
{
    case dnsFailure(message: String)
    case setup(message: String)

    var errorDescription: String? {
        switch self {
        case .dnsFailure(let message):
            "DNS 解析失败：\(message)"
        case .setup(let message):
            "端口扫描无法继续：\(message)"
        }
    }
}
