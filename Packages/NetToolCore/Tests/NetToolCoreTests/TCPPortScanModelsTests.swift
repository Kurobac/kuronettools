import Testing

@testable import NetToolCore

@Suite("TCP port scan models")
struct TCPPortScanModelsTests {
    @Test("Port expressions expand, sort, and deduplicate")
    func parsesPortExpression() throws {
        let ports = try TCPPortExpressionParser.parse(
            "443, 80, 8000-8002, 80"
        )

        #expect(ports == [80, 443, 8_000, 8_001, 8_002])
    }

    @Test("The complete TCP port range is accepted")
    func parsesCompleteRange() throws {
        let ports = try TCPPortExpressionParser.parse("1-65535")

        #expect(ports.count == 65_535)
        #expect(ports.first == 1)
        #expect(ports.last == 65_535)
    }

    @Test(
        "Invalid port expressions are rejected",
        arguments: [
            "",
            "80,",
            "abc",
            "90-80",
            "1-2-3",
            "0",
            "65536"
        ]
    )
    func rejectsInvalidExpression(
        _ expression: String
    ) {
        #expect(throws: TCPPortExpressionError.self) {
            try TCPPortExpressionParser.parse(expression)
        }
    }

    @Test("Scan configuration normalizes its target and ports")
    func validatesConfiguration() throws {
        let configuration = try TCPPortScanConfiguration(
            host: "  example.com  ",
            ports: [443, 80, 443],
            addressFamily: .ipv4,
            timeoutSeconds: 2,
            maxConcurrency: 16,
            maxRetries: 2
        ).validated()

        #expect(configuration.host == "example.com")
        #expect(configuration.ports == [80, 443])
        #expect(configuration.addressFamily == .ipv4)
        #expect(configuration.timeoutSeconds == 2)
        #expect(configuration.maxConcurrency == 16)
        #expect(configuration.maxRetries == 2)
    }

    @Test("Scan defaults favor reliable connect results")
    func scanDefaults() throws {
        let configuration = try TCPPortScanConfiguration(
            host: "example.com",
            ports: [443]
        ).validated()

        #expect(configuration.timeoutSeconds == 2)
        #expect(configuration.maxConcurrency == 32)
        #expect(configuration.maxRetries == 2)
    }

    @Test(
        "Invalid scan configuration is rejected",
        arguments: [
            TCPPortScanConfiguration(host: "host", ports: []),
            TCPPortScanConfiguration(host: "host", ports: [0]),
            TCPPortScanConfiguration(
                host: "host",
                ports: [80],
                maxConcurrency: 0
            ),
            TCPPortScanConfiguration(
                host: "host",
                ports: [80],
                maxConcurrency: 129
            ),
            TCPPortScanConfiguration(
                host: "host",
                ports: [80],
                maxRetries: -1
            ),
            TCPPortScanConfiguration(
                host: "host",
                ports: [80],
                maxRetries: 3
            )
        ]
    )
    func rejectsInvalidConfiguration(
        _ configuration: TCPPortScanConfiguration
    ) {
        #expect(throws: TCPPortScanConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test("Summary records every result category")
    func recordsSummary() {
        var summary = TCPPortScanSummary(total: 5)
        summary.record(
            TCPPortScanResult(
                port: 22,
                outcome: .open(
                    address: "192.0.2.1",
                    addressFamily: .ipv4,
                    connectionTimeMilliseconds: 2
                )
            )
        )
        summary.record(
            TCPPortScanResult(port: 23, outcome: .closed)
        )
        summary.record(
            TCPPortScanResult(port: 24, outcome: .timedOut)
        )
        summary.record(
            TCPPortScanResult(port: 25, outcome: .unreachable)
        )
        summary.record(
            TCPPortScanResult(
                port: 26,
                outcome: .failed(message: "reset")
            )
        )

        #expect(summary.scanned == 5)
        #expect(summary.open == 1)
        #expect(summary.closed == 1)
        #expect(summary.timedOut == 1)
        #expect(summary.unreachable == 1)
        #expect(summary.failed == 1)
    }

    @Test("Responsive results rapidly grow the congestion window")
    func timingControllerSlowStarts() {
        var timing = TCPPortScanTimingController(
            maxParallelism: 32
        )

        #expect(timing.snapshot.currentParallelism == 8)
        for _ in 0 ..< 8 {
            timing.recordResponsiveResult()
        }
        #expect(timing.snapshot.currentParallelism == 16)
        for _ in 0 ..< 16 {
            timing.recordResponsiveResult()
        }
        #expect(timing.snapshot.currentParallelism == 32)
        #expect(timing.snapshot.peakParallelism == 32)
    }

    @Test("Path probe timeouts halve the window without dropping below four")
    func timingControllerBacksOff() {
        var timing = TCPPortScanTimingController(
            maxParallelism: 32
        )
        for _ in 0 ..< 24 {
            timing.recordResponsiveResult()
        }

        timing.recordPathTimeout()
        #expect(timing.snapshot.currentParallelism == 16)
        timing.recordPathTimeout()
        #expect(timing.snapshot.currentParallelism == 8)
        timing.recordPathTimeout()
        #expect(timing.snapshot.currentParallelism == 4)
        #expect(timing.snapshot.peakParallelism == 32)
        timing.recordPathTimeout()
        #expect(timing.snapshot.currentParallelism == 4)
    }

    @Test("The user maximum also bounds the initial window")
    func timingControllerHonorsSmallMaximum() {
        var timing = TCPPortScanTimingController(
            maxParallelism: 3
        )

        #expect(timing.snapshot.currentParallelism == 3)
        timing.recordResponsiveResult()
        #expect(timing.snapshot.currentParallelism == 3)
        timing.recordPathTimeout()
        #expect(timing.snapshot.currentParallelism == 3)
    }

    @Test("Only timed out ports receive a bounded retry")
    func retryPolicyIsBounded() {
        #expect(
            TCPPortScanRetryPolicy.shouldRetry(
                outcome: .timedOut,
                completedRetries: 0,
                maxRetries: 1
            )
        )
        #expect(
            !TCPPortScanRetryPolicy.shouldRetry(
                outcome: .timedOut,
                completedRetries: 1,
                maxRetries: 1
            )
        )
        #expect(
            !TCPPortScanRetryPolicy.shouldRetry(
                outcome: .closed,
                completedRetries: 0,
                maxRetries: 1
            )
        )
    }

    @Test("Retry attempts are included in timing snapshots")
    func timingControllerCountsRetries() {
        var timing = TCPPortScanTimingController(
            maxParallelism: 32
        )

        timing.recordRetries(2)

        #expect(timing.snapshot.retryAttempts == 2)
    }
}
