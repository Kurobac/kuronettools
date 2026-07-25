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
            var timing = TCPPortScanTimingController(
                maxParallelism: configuration.maxConcurrency
            )
            continuation.yield(
                .started(
                    totalPorts: configuration.ports.count,
                    timing: timing.snapshot
                )
            )

            var workQueue = TCPPortScanWorkQueue(
                ports: configuration.ports
            )
            var activeAttempts = 0
            try await withThrowingTaskGroup(
                of: TCPPortScanAttemptResult.self
            ) { group in
                while true {
                    while activeAttempts
                            < timing.snapshot.currentParallelism,
                          let attempt = workQueue.next() {
                        activeAttempts += 1
                        group.addTask {
                            try await scan(
                                attempt: attempt,
                                configuration: configuration
                            )
                        }
                    }

                    guard activeAttempts > 0,
                          let attemptResult = try await group.next()
                    else {
                        break
                    }
                    activeAttempts -= 1
                    try Task.checkCancellation()

                    let result = attemptResult.result
                    switch result.outcome {
                    case .open, .closed:
                        timing.recordResponsiveResult()
                    case .timedOut:
                        timing.recordTimeout()
                    case .unreachable, .failed:
                        break
                    }

                    if TCPPortScanRetryPolicy.shouldRetry(
                        outcome: result.outcome,
                        completedRetries:
                            attemptResult.attempt.completedRetries,
                        maxRetries: configuration.maxRetries
                    ) {
                        let retryNumber =
                            attemptResult.attempt.completedRetries + 1
                        timing.recordRetry()
                        workQueue.appendRetry(
                            TCPPortScanAttempt(
                                port: result.port,
                                completedRetries: retryNumber
                            )
                        )
                        continuation.yield(
                            .retryScheduled(
                                port: result.port,
                                retryNumber: retryNumber,
                                timing: timing.snapshot
                            )
                        )
                    } else {
                        continuation.yield(
                            .result(
                                result,
                                timing: timing.snapshot
                            )
                        )
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
        attempt: TCPPortScanAttempt,
        configuration: TCPPortScanConfiguration
    ) async throws -> TCPPortScanAttemptResult {
        do {
            let result = try await TCPConnectionClient().connect(
                configuration: TCPConnectionConfiguration(
                    host: configuration.host,
                    port: attempt.port,
                    addressFamily: configuration.addressFamily,
                    timeoutSeconds: configuration.timeoutSeconds
                )
            )
            return TCPPortScanAttemptResult(
                attempt: attempt,
                result: TCPPortScanResult(
                    port: attempt.port,
                    outcome: .open(
                        address: result.address,
                        addressFamily: result.addressFamily,
                        connectionTimeMilliseconds:
                            result.connectionTimeMilliseconds
                    )
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TCPConnectionClientError {
            return TCPPortScanAttemptResult(
                attempt: attempt,
                result: try result(
                    port: attempt.port,
                    for: error
                )
            )
        } catch {
            return TCPPortScanAttemptResult(
                attempt: attempt,
                result: TCPPortScanResult(
                    port: attempt.port,
                    outcome: .failed(
                        message: error.localizedDescription
                    )
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

private struct TCPPortScanAttempt: Sendable {
    let port: Int
    let completedRetries: Int
}

private struct TCPPortScanAttemptResult: Sendable {
    let attempt: TCPPortScanAttempt
    let result: TCPPortScanResult
}

private struct TCPPortScanWorkQueue {
    private let ports: [Int]
    private var nextPortIndex = 0
    private var retries: [TCPPortScanAttempt] = []
    private var nextRetryIndex = 0

    init(ports: [Int]) {
        self.ports = ports
    }

    mutating func next() -> TCPPortScanAttempt? {
        if nextRetryIndex < retries.count {
            defer {
                nextRetryIndex += 1
            }
            return retries[nextRetryIndex]
        }

        guard nextPortIndex < ports.count else {
            return nil
        }
        defer {
            nextPortIndex += 1
        }
        return TCPPortScanAttempt(
            port: ports[nextPortIndex],
            completedRetries: 0
        )
    }

    mutating func appendRetry(
        _ retry: TCPPortScanAttempt
    ) {
        retries.append(retry)
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
