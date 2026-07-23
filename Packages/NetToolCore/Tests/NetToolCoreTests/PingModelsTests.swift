import Testing

@testable import NetToolCore

@Suite("Ping models")
struct PingModelsTests {
    @Test("Validation trims a valid host")
    func validatesConfiguration() throws {
        let configuration = PingConfiguration(
            host: "  example.com  "
        )

        let validated = try configuration.validated()

        #expect(validated.host == "example.com")
        #expect(validated.payloadSize == 56)
    }

    @Test(
        "Invalid values are rejected",
        arguments: [
            PingConfiguration(host: ""),
            PingConfiguration(host: "host", count: 0),
            PingConfiguration(host: "host", intervalSeconds: 0),
            PingConfiguration(host: "host", timeoutSeconds: 31),
            PingConfiguration(host: "host", payloadSize: 1_401)
        ]
    )
    func rejectsInvalidConfiguration(_ configuration: PingConfiguration) {
        #expect(throws: PingConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test("Summary calculates loss and population deviation")
    func calculatesSummary() {
        let summary = PingSummary(
            transmitted: 4,
            roundTripTimesMilliseconds: [10, 20, 30]
        )

        #expect(summary.received == 3)
        #expect(summary.lost == 1)
        #expect(summary.lossPercentage == 25)
        #expect(summary.minimumMilliseconds == 10)
        #expect(summary.averageMilliseconds == 20)
        #expect(summary.maximumMilliseconds == 30)
        #expect(
            abs((summary.meanDeviationMilliseconds ?? 0) - 8.164_965) < 0.001
        )
    }

    @Test("Summary has no RTT values when every request times out")
    func calculatesEmptySummary() {
        let summary = PingSummary(
            transmitted: 3,
            roundTripTimesMilliseconds: []
        )

        #expect(summary.lossPercentage == 100)
        #expect(summary.averageMilliseconds == nil)
    }
}
