import Darwin
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
            let endpoint = try DarwinTCPPortScanSocket.resolve(
                host: configuration.host,
                addressFamily: configuration.addressFamily
            )
            var timing = TCPPortScanTimingController(
                maxParallelism: configuration.maxConcurrency,
                startRateLimit: configuration.maxStartRate
            )
            continuation.yield(
                .started(
                    totalPorts: configuration.ports.count,
                    timing: timing.snapshot
                )
            )

            var attempts = configuration.ports.map {
                TCPPortScanAttempt(port: $0)
            }
            var completedRetries = 0
            var anchor: TCPPortScanAnchor?

            while true {
                let round = try scanRound(
                    attempts: attempts,
                    endpoint: endpoint,
                    configuration: configuration,
                    retryNumber: completedRetries,
                    isFinalRound:
                        completedRetries == configuration.maxRetries,
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
                        .pathProbeStarted(timing: timing.snapshot)
                    )
                    if try isAnchorResponsive(
                        anchor,
                        endpoint: endpoint,
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
                    throw TCPPortScanClientError.unexpectedRetryState
                }

                completedRetries += 1
                timing.recordStartRateLimit(
                    TCPPortScanPacingPolicy.startRateLimit(
                        maximum: configuration.maxStartRate,
                        retryNumber: completedRetries
                    )
                )
                timing.recordRetries(round.timedOut.count)
                continuation.yield(
                    .retryRoundStarted(
                        retryNumber: completedRetries,
                        portCount: round.timedOut.count,
                        timing: timing.snapshot
                    )
                )

                try await Task.sleep(for: .milliseconds(500))
                attempts = round.timedOut.map {
                    TCPPortScanAttempt(port: $0.attempt.port)
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
        endpoint: DarwinTCPPortScanSocket.Endpoint,
        configuration: TCPPortScanConfiguration,
        retryNumber: Int,
        isFinalRound: Bool,
        timing initialTiming: TCPPortScanTimingController,
        anchor initialAnchor: TCPPortScanAnchor?,
        continuation: AsyncStream<TCPPortScanEvent>.Continuation
    ) throws -> TCPPortScanRoundResult {
        var workQueue = TCPPortScanRoundQueue(attempts: attempts)
        var active: [
            Int32: TCPPortScanActiveConnection
        ] = [:]
        var timing = initialTiming
        let startRateLimit =
            TCPPortScanPacingPolicy.startRateLimit(
                maximum: configuration.maxStartRate,
                retryNumber: retryNumber
            )
        timing.recordStartRateLimit(startRateLimit)
        let launchInterval =
            TCPPortScanPacingPolicy.launchIntervalNanoseconds(
                startRateLimit: startRateLimit
            )
        var nextLaunchAt =
            DispatchTime.now().uptimeNanoseconds
        var anchor = initialAnchor
        var timedOut: [TCPPortScanAttemptResult] = []
        var completedAttempts = 0

        defer {
            DarwinTCPPortScanSocket.close(
                active.values.map(\.pending)
            )
        }

        while true {
            try Task.checkCancellation()

            while active.count
                    < timing.snapshot.currentParallelism,
                  !workQueue.isEmpty {
                guard DispatchTime.now().uptimeNanoseconds
                        >= nextLaunchAt else {
                    break
                }
                guard let attempt = workQueue.next() else {
                    break
                }
                let startResult = try DarwinTCPPortScanSocket.start(
                    endpoint: endpoint,
                    port: attempt.port,
                    timeoutSeconds: configuration.timeoutSeconds
                )
                nextLaunchAt =
                    DispatchTime.now().uptimeNanoseconds
                    + launchInterval
                switch startResult {
                case .completed(let socketResult):
                    try record(
                        TCPPortScanAttemptResult(
                            attempt: attempt,
                            socketResult: socketResult
                        ),
                        retryNumber: retryNumber,
                        retryTotal: attempts.count,
                        isFinalRound: isFinalRound,
                        timing: &timing,
                        anchor: &anchor,
                        timedOut: &timedOut,
                        completedAttempts: &completedAttempts,
                        continuation: continuation
                    )
                case .pending(let pending):
                    active[pending.descriptor] =
                        TCPPortScanActiveConnection(
                            attempt: attempt,
                            pending: pending
                        )
                    timing.recordActiveConnections(active.count)
                }
            }

            if active.isEmpty && workQueue.isEmpty {
                break
            }

            var pollDescriptors = active.keys.map {
                pollfd(
                    fd: $0,
                    events: Int16(POLLOUT | POLLERR | POLLHUP),
                    revents: 0
                )
            }
            try DarwinTCPPortScanSocket.poll(
                &pollDescriptors,
                timeoutMilliseconds:
                    pollTimeoutMilliseconds(
                        for: active.values,
                        nextLaunchAt:
                            shouldWaitForLaunch(
                                workQueue: workQueue,
                                activeCount: active.count,
                                parallelism:
                                    timing.snapshot.currentParallelism
                            )
                            ? nextLaunchAt
                            : nil
                    )
            )
            try Task.checkCancellation()

            var completedResults: [TCPPortScanAttemptResult] = []
            for descriptor in pollDescriptors
            where descriptor.revents != 0 {
                guard let connection = active.removeValue(
                    forKey: descriptor.fd
                ) else {
                    continue
                }
                let socketResult = try DarwinTCPPortScanSocket.finish(
                    connection.pending,
                    endpoint: endpoint
                )
                completedResults.append(
                    TCPPortScanAttemptResult(
                        attempt: connection.attempt,
                        socketResult: socketResult
                    )
                )
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let expiredDescriptors = active.compactMap {
                descriptor,
                connection in
                connection.pending.deadline <= now
                    ? descriptor
                    : nil
            }
            for descriptor in expiredDescriptors {
                guard let connection = active.removeValue(
                    forKey: descriptor
                ) else {
                    continue
                }
                completedResults.append(
                    TCPPortScanAttemptResult(
                        attempt: connection.attempt,
                        socketResult:
                            DarwinTCPPortScanSocket.timeout(
                                connection.pending
                            )
                    )
                )
            }

            timing.recordActiveConnections(active.count)
            for attemptResult in completedResults {
                try record(
                    attemptResult,
                    retryNumber: retryNumber,
                    retryTotal: attempts.count,
                    isFinalRound: isFinalRound,
                    timing: &timing,
                    anchor: &anchor,
                    timedOut: &timedOut,
                    completedAttempts: &completedAttempts,
                    continuation: continuation
                )
            }
        }

        return TCPPortScanRoundResult(
            timing: timing,
            anchor: anchor,
            timedOut: timedOut
        )
    }

    private static func record(
        _ attemptResult: TCPPortScanAttemptResult,
        retryNumber: Int,
        retryTotal: Int,
        isFinalRound: Bool,
        timing: inout TCPPortScanTimingController,
        anchor: inout TCPPortScanAnchor?,
        timedOut: inout [TCPPortScanAttemptResult],
        completedAttempts: inout Int,
        continuation: AsyncStream<TCPPortScanEvent>.Continuation
    ) throws {
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
            guard let timeoutOrigin = attemptResult.timeoutOrigin else {
                throw TCPPortScanClientError.missingTimeoutOrigin
            }
            timing.recordTimeout(origin: timeoutOrigin)
            if !isFinalRound {
                timedOut.append(attemptResult)
            }
        case .unreachable, .failed:
            break
        }

        if isFinalRound
                || !attemptResult.result.outcome.isTimedOut {
            continuation.yield(
                .result(
                    attemptResult.result,
                    timing: timing.snapshot
                )
            )
        }

        completedAttempts += 1
        if retryNumber > 0 {
            continuation.yield(
                .retryRoundProgress(
                    retryNumber: retryNumber,
                    completed: completedAttempts,
                    total: retryTotal,
                    timing: timing.snapshot
                )
            )
        }
    }

    private static func isAnchorResponsive(
        _ anchor: TCPPortScanAnchor,
        endpoint: DarwinTCPPortScanSocket.Endpoint,
        configuration: TCPPortScanConfiguration
    ) throws -> Bool {
        let result = try scanSingle(
            port: anchor.port,
            endpoint: endpoint,
            timeoutSeconds: configuration.timeoutSeconds
        )
        switch result.outcome {
        case .open, .closed:
            return true
        case .timedOut, .unreachable, .failed:
            return false
        }
    }

    private static func scanSingle(
        port: Int,
        endpoint: DarwinTCPPortScanSocket.Endpoint,
        timeoutSeconds: Double
    ) throws -> DarwinTCPPortScanSocket.ConnectionResult {
        switch try DarwinTCPPortScanSocket.start(
            endpoint: endpoint,
            port: port,
            timeoutSeconds: timeoutSeconds
        ) {
        case .completed(let result):
            return result
        case .pending(let pending):
            while true {
                do {
                    try Task.checkCancellation()
                } catch {
                    DarwinTCPPortScanSocket.close([pending])
                    throw error
                }

                var descriptors = [
                    pollfd(
                        fd: pending.descriptor,
                        events: Int16(
                            POLLOUT | POLLERR | POLLHUP
                        ),
                        revents: 0
                    )
                ]
                do {
                    try DarwinTCPPortScanSocket.poll(
                        &descriptors,
                        timeoutMilliseconds:
                            pollTimeoutMilliseconds(
                                deadline: pending.deadline
                            )
                    )
                } catch {
                    DarwinTCPPortScanSocket.close([pending])
                    throw error
                }

                if descriptors[0].revents != 0 {
                    return try DarwinTCPPortScanSocket.finish(
                        pending,
                        endpoint: endpoint
                    )
                }
                if DispatchTime.now().uptimeNanoseconds
                        >= pending.deadline {
                    return DarwinTCPPortScanSocket.timeout(pending)
                }
            }
        }
    }

    private static func pollTimeoutMilliseconds(
        for connections:
            Dictionary<Int32, TCPPortScanActiveConnection>.Values,
        nextLaunchAt: UInt64?
    ) -> Int32 {
        let connectionDeadline = connections.lazy.map({
            $0.pending.deadline
        }).min()
        let deadline: UInt64?
        switch (connectionDeadline, nextLaunchAt) {
        case (.some(let connection), .some(let launch)):
            deadline = min(connection, launch)
        case (.some(let connection), .none):
            deadline = connection
        case (.none, .some(let launch)):
            deadline = launch
        case (.none, .none):
            deadline = nil
        }

        guard let deadline else {
            return 0
        }
        return pollTimeoutMilliseconds(deadline: deadline)
    }

    private static func shouldWaitForLaunch(
        workQueue: TCPPortScanRoundQueue,
        activeCount: Int,
        parallelism: Int
    ) -> Bool {
        !workQueue.isEmpty && activeCount < parallelism
    }

    private static func pollTimeoutMilliseconds(
        deadline: UInt64
    ) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            return 0
        }
        let remaining = deadline - now
        let roundedMilliseconds =
            (remaining + 999_999) / 1_000_000
        return Int32(min(100, roundedMilliseconds))
    }
}

private struct TCPPortScanAttempt {
    let port: Int
}

private struct TCPPortScanAttemptResult {
    let attempt: TCPPortScanAttempt
    let result: TCPPortScanResult
    let timeoutOrigin: TCPPortScanTimeoutOrigin?

    init(
        attempt: TCPPortScanAttempt,
        socketResult: DarwinTCPPortScanSocket.ConnectionResult
    ) {
        self.attempt = attempt
        self.result = TCPPortScanResult(
            port: socketResult.port,
            outcome: socketResult.outcome
        )
        self.timeoutOrigin = socketResult.timeoutOrigin
    }
}

private struct TCPPortScanActiveConnection {
    let attempt: TCPPortScanAttempt
    let pending: DarwinTCPPortScanSocket.PendingConnection
}

private struct TCPPortScanRoundResult {
    let timing: TCPPortScanTimingController
    let anchor: TCPPortScanAnchor?
    let timedOut: [TCPPortScanAttemptResult]
}

private struct TCPPortScanAnchor {
    let port: Int
}

private struct TCPPortScanRoundQueue {
    private let attempts: [TCPPortScanAttempt]
    private var nextAttemptIndex = 0

    init(attempts: [TCPPortScanAttempt]) {
        self.attempts = attempts
    }

    var isEmpty: Bool {
        nextAttemptIndex >= attempts.count
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

private extension TCPPortScanOutcome {
    var isTimedOut: Bool {
        if case .timedOut = self {
            return true
        }
        return false
    }
}

private enum TCPPortScanClientError:
    Error,
    LocalizedError
{
    case missingTimeoutOrigin
    case unexpectedRetryState

    var errorDescription: String? {
        switch self {
        case .missingTimeoutOrigin:
            "端口扫描收到超时结果，但缺少超时来源。"
        case .unexpectedRetryState:
            "端口扫描的重试轮状态不一致。"
        }
    }
}
