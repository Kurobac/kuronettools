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

    @Test("DoH configuration overrides the URL port")
    func validatesHTTPSConfiguration() throws {
        let configuration = try DNSQueryConfiguration(
            name: "example.com",
            transport: .https,
            server: " https://dns.example:8443/dns-query ",
            port: 4443
        ).validated()

        #expect(
            configuration.server
                == "https://dns.example:4443/dns-query"
        )
        #expect(configuration.port == 4443)
    }

    @Test("DoH configuration defaults to port 443")
    func defaultsHTTPSPort() throws {
        let configuration = try DNSQueryConfiguration(
            name: "example.com",
            transport: .https,
            server: "https://dns.example/dns-query"
        ).validated()

        #expect(
            configuration.server
                == "https://dns.example:443/dns-query"
        )
        #expect(configuration.port == 443)
    }

    @Test("DoT configuration trims its TLS server name")
    func validatesTLSConfiguration() throws {
        let configuration = try DNSQueryConfiguration(
            name: "example.com",
            transport: .tls,
            server: " 1.1.1.1 ",
            tlsServerName: " one.one.one.one ",
            port: 853
        ).validated()

        #expect(configuration.server == "1.1.1.1")
        #expect(configuration.tlsServerName == "one.one.one.one")
    }

    @Test("TLS server name is discarded for plaintext transports")
    func discardsIrrelevantTLSServerName() throws {
        let configuration = try DNSQueryConfiguration(
            name: "example.com",
            tlsServerName: "one.one.one.one"
        ).validated()

        #expect(configuration.tlsServerName == nil)
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
            ),
            DNSQueryConfiguration(
                name: "example.com",
                transport: .https,
                server: "https://dns.example/dns-query",
                port: 0
            ),
            DNSQueryConfiguration(
                name: "example.com",
                transport: .https,
                server: "http://dns.example/dns-query"
            ),
            DNSQueryConfiguration(
                name: "example.com",
                transport: .https,
                server: "not a URL"
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

    @Test("Transports expose their standard ports")
    func exposesTransportPorts() {
        #expect(DNSTransport.udp.defaultPort == 53)
        #expect(DNSTransport.tcp.defaultPort == 53)
        #expect(DNSTransport.tls.defaultPort == 853)
        #expect(DNSTransport.https.defaultPort == 443)
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
