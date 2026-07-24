import Testing

@testable import NetToolCore

@Suite("TCP models")
struct TCPModelsTests {
    @Test("Configuration trims valid input")
    func validatesConfiguration() throws {
        let configuration = try TCPConnectionConfiguration(
            host: " example.com ",
            port: 8443,
            addressFamily: .ipv6,
            timeoutSeconds: 4
        ).validated()

        #expect(configuration.host == "example.com")
        #expect(configuration.port == 8443)
        #expect(configuration.addressFamily == .ipv6)
        #expect(configuration.timeoutSeconds == 4)
    }

    @Test(
        "Invalid configuration is rejected",
        arguments: [
            TCPConnectionConfiguration(host: ""),
            TCPConnectionConfiguration(host: "example.com", port: 0),
            TCPConnectionConfiguration(
                host: "example.com",
                port: 65_536
            ),
            TCPConnectionConfiguration(
                host: "example.com",
                timeoutSeconds: 0
            ),
            TCPConnectionConfiguration(
                host: "example.com",
                timeoutSeconds: 31
            )
        ]
    )
    func rejectsInvalidConfiguration(
        _ configuration: TCPConnectionConfiguration
    ) {
        #expect(throws: TCPConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test(
        "Literal IP addresses must match the selected family",
        arguments: [
            TCPConnectionConfiguration(
                host: "192.0.2.1",
                addressFamily: .ipv6
            ),
            TCPConnectionConfiguration(
                host: "2001:db8::1",
                addressFamily: .ipv4
            ),
            TCPConnectionConfiguration(
                host: "fe80::1%en0",
                addressFamily: .ipv4
            )
        ]
    )
    func rejectsMismatchedLiteralAddressFamily(
        _ configuration: TCPConnectionConfiguration
    ) {
        #expect(throws: TCPConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test(
        "Matching, automatic, and hostname families remain valid",
        arguments: [
            TCPConnectionConfiguration(
                host: "192.0.2.1",
                addressFamily: .ipv4
            ),
            TCPConnectionConfiguration(
                host: "2001:db8::1",
                addressFamily: .ipv6
            ),
            TCPConnectionConfiguration(
                host: "192.0.2.1",
                addressFamily: .automatic
            ),
            TCPConnectionConfiguration(
                host: "example.com",
                addressFamily: .ipv6
            )
        ]
    )
    func acceptsCompatibleAddressFamily(
        _ configuration: TCPConnectionConfiguration
    ) throws {
        let validated = try configuration.validated()
        #expect(validated == configuration)
    }

    @Test("Address families expose user-facing titles")
    func exposesAddressFamilyTitles() {
        #expect(TCPAddressFamily.automatic.title == "自动")
        #expect(TCPAddressFamily.ipv4.title == "IPv4")
        #expect(TCPAddressFamily.ipv6.title == "IPv6")
    }
}
