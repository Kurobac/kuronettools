import Testing

@testable import NetToolCore

@Suite("DNS models")
struct DNSModelsTests {
    @Test("Configuration trims valid input")
    func validatesConfiguration() throws {
        let configuration = try DNSQueryConfiguration(
            name: " example.com ",
            server: " 1.1.1.1 "
        ).validated()

        #expect(configuration.name == "example.com")
        #expect(configuration.server == "1.1.1.1")
        #expect(configuration.port == 53)
    }

    @Test(
        "Invalid configuration is rejected",
        arguments: [
            DNSQueryConfiguration(name: ""),
            DNSQueryConfiguration(name: "example.com", server: ""),
            DNSQueryConfiguration(name: "example.com", port: 0),
            DNSQueryConfiguration(name: "example.com", port: 65_536),
            DNSQueryConfiguration(
                name: "example.com",
                timeoutSeconds: 31
            )
        ]
    )
    func rejectsInvalidConfiguration(
        _ configuration: DNSQueryConfiguration
    ) {
        #expect(throws: DNSConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test("Flags expose dig-style names and response code")
    func decodesFlags() {
        let flags = DNSMessageFlags(rawValue: 0x87b3)

        #expect(flags.isResponse)
        #expect(flags.isAuthoritative)
        #expect(flags.isTruncated)
        #expect(flags.recursionDesired)
        #expect(flags.recursionAvailable)
        #expect(flags.authenticatedData)
        #expect(flags.checkingDisabled)
        #expect(flags.responseCodeName == "NXDOMAIN")
        #expect(
            flags.activeNames == ["qr", "aa", "tc", "rd", "ra", "ad", "cd"]
        )
    }
}
