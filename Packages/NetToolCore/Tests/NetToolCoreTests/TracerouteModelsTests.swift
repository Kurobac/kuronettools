import Testing

@testable import NetToolCore

@Suite("Traceroute models")
struct TracerouteModelsTests {
    @Test("Validation trims a valid target")
    func validatesConfiguration() throws {
        let configuration = try TracerouteConfiguration(
            host: "  example.com  ",
            addressFamily: .ipv6,
            maxHops: 20,
            probesPerHop: 2,
            timeoutSeconds: 1.5
        ).validated()

        #expect(configuration.host == "example.com")
        #expect(configuration.addressFamily == .ipv6)
        #expect(configuration.maxHops == 20)
        #expect(configuration.probesPerHop == 2)
        #expect(configuration.timeoutSeconds == 1.5)
        #expect(configuration.payloadSize == 32)
    }

    @Test(
        "Invalid values are rejected",
        arguments: [
            TracerouteConfiguration(host: ""),
            TracerouteConfiguration(host: "host", maxHops: 0),
            TracerouteConfiguration(host: "host", maxHops: 65),
            TracerouteConfiguration(
                host: "host",
                probesPerHop: 0
            ),
            TracerouteConfiguration(
                host: "host",
                probesPerHop: 6
            ),
            TracerouteConfiguration(
                host: "host",
                timeoutSeconds: 0
            ),
            TracerouteConfiguration(
                host: "host",
                timeoutSeconds: 11
            ),
            TracerouteConfiguration(
                host: "host",
                payloadSize: 1_401
            )
        ]
    )
    func rejectsInvalidConfiguration(
        _ configuration: TracerouteConfiguration
    ) {
        #expect(throws: TracerouteConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test("Completion status exposes the reached hop")
    func describesCompletion() {
        let status = TracerouteCompletionStatus
            .reachedDestination(hop: 12)

        #expect(status.title == "已在第 12 跳到达目标")
        #expect(
            TracerouteCompletionStatus.maxHopsReached.title
                == "已达到最大跳数"
        )
    }
}
