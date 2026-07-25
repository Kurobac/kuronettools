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

            var attempts = configuration.ports.map {
                TCPPortScanAttempt(
                    port: $0
                )
            }
            var completedRetries = 0
            var anchor: TCPPortScanAnchor?

            while true {
                let round = try await scanRound(
                    attempts: attempts,
                    configuration: configuration,
                    timing: timing,
                    anchor: anchor,
                    continuation: continuation
                )
                timing = round.timing
                anchor = round.anchor

                guard !round.timedOut.isEmpty else {
                    break
                }

                if let anchor {
                    continuation.yield(
                        .pathProbeStarted(
                            timing: timing.snapshot
                        )
                    )
                    if try await isAnchorResponsive(
                        anchor,
                        configuration: configuration
                    ) {
                        timing.recordResponsiveResult()
                    } else {
                        timing.recordPathTimeout()
                    }
                }

                guard TCPPortScanRetryPolicy.shouldRetry(
                    outcome: .timedOut,
                    completedRetries: completedRetries,
                    maxRetries: configuration.maxRetries
                ) else {
                    for attemptResult in round.timedOut {
                        continuation.yield(
                            .result(
                                attemptResult.result,
                                timing: timing.snapshot
                            )
                        )
                    }
                    break
                }

                completedRetries += 1
                timing.recordRetries(round.timedOut.count)
                continuation.yield(
                    .retryRoundStarted(
                        retryNumber: completedRetries,
                        portCount: round.timedOut.count,
                        timing: timing.snapshot
                    )
                )

                try await Task.sleep(
                    for: .milliseconds(500)
                )
                attempts = round.timedOut.map {
                    TCPPortScanAttempt(
                        port: $0.attempt.port
                    )
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

    private static func scanRound(
        attempts: [TCPPortScanAttempt],
        configuration: TCPPortScanConfiguration,
        timing initialTiming: TCPPortScanTimingController,
        anchor initialAnchor: TCPPortScanAnchor?,
        continuation: AsyncStream<TCPPortScanEvent>.Continuation
    ) async throws -> TCPPortScanRoundResult {
        var workQueue = TCPPortScanRoundQueue(
            attempts: attempts
        )
        var timing = initialTiming
        var anchor = initialAnchor
        var timedOut: [TCPPortScanAttemptResult] = []
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

                switch attemptResult.result.outcome {
                case .open:
                    timing.recordResponsiveResult()
                    if anchor == nil {
                        anchor = TCPPortScanAnchor(
                            port: attemptResult.attempt.port
                        )
                    }
                case .closed:
                    timing.recordResponsiveResult()
                    anchor = TCPPortScanAnchor(
                        port: attemptResult.attempt.port
                    )
                case .timedOut:
                    timedOut.append(attemptResult)
                case .unreachable, .failed:
                    break
                }

                if case .timedOut = attemptResult.result.outcome {
                    continue
                }
                continuation.yield(
                    .result(
                        attemptResult.result,
                        timing: timing.snapshot
                    )
                )
            }
        }

        return TCPPortScanRoundResult(
            timing: timing,
            anchor: anchor,
            timedOut: timedOut
        )
    }

    private static func isAnchorResponsive(
        _ anchor: TCPPortScanAnchor,
        configuration: TCPPortScanConfiguration
    ) async throws -> Bool {
        do {
            _ = try await TCPConnectionClient().connect(
                configuration: TCPConnectionConfiguration(
                    host: configuration.host,
                    port: anchor.port,
                    addressFamily: configuration.addressFamily,
                    timeoutSeconds: configuration.timeoutSeconds
                )
            )
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TCPConnectionClientError {
            let probeResult = try result(
                port: anchor.port,
                for: error
            )
            switch probeResult.outcome {
            case .open, .closed:
                return true
            case .timedOut, .unreachable, .failed:
                return false
            }
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
}

private struct TCPPortScanAttemptResult: Sendable {
    let attempt: TCPPortScanAttempt
    let result: TCPPortScanResult
}

private struct TCPPortScanRoundResult: Sendable {
    let timing: TCPPortScanTimingController
    let anchor: TCPPortScanAnchor?
    let timedOut: [TCPPortScanAttemptResult]
}

private struct TCPPortScanAnchor: Sendable {
    let port: Int
}

private struct TCPPortScanRoundQueue {
    private let attempts: [TCPPortScanAttempt]
    private var nextAttemptIndex = 0

    init(attempts: [TCPPortScanAttempt]) {
        self.attempts = attempts
    }

    mutating func next() -> TCPPortScanAttempt? {
        guard nextAttemptIndex < attempts.count else {
            return nil
        }
        defer {
            nextAttemptIndex += 1
        }
        return attempts[nextAttemptIndex]
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
