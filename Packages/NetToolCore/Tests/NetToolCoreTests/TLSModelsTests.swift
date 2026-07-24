import Foundation
import Testing

@testable import NetToolCore

@Suite("TLS models")
struct TLSModelsTests {
    @Test("Configuration trims and preserves valid settings")
    func validatesConfiguration() throws {
        let configuration = try TLSConfiguration(
            host: " example.com ",
            port: 8443,
            serverName: " sni.example.com ",
            addressFamily: .ipv6,
            timeoutSeconds: 7,
            allowsUntrustedCertificates: true,
            applicationProtocols: [" h2 ", "http/1.1"]
        ).validated()

        #expect(configuration.host == "example.com")
        #expect(configuration.port == 8443)
        #expect(configuration.serverName == "sni.example.com")
        #expect(configuration.effectiveServerName == "sni.example.com")
        #expect(configuration.addressFamily == .ipv6)
        #expect(configuration.timeoutSeconds == 7)
        #expect(configuration.allowsUntrustedCertificates)
        #expect(
            configuration.applicationProtocols == ["h2", "http/1.1"]
        )
    }

    @Test("An empty server name follows the connection host")
    func defaultsServerNameToHost() throws {
        let configuration = try TLSConfiguration(
            host: "example.com",
            serverName: " "
        ).validated()

        #expect(configuration.serverName == nil)
        #expect(configuration.effectiveServerName == "example.com")
    }

    @Test("Literal IP addresses obey the selected family")
    func rejectsMismatchedAddressFamily() {
        #expect(throws: TCPConfigurationError.self) {
            try TLSConfiguration(
                host: "192.0.2.1",
                addressFamily: .ipv6
            ).validated()
        }
    }

    @Test(
        "Invalid ALPN identifiers are rejected",
        arguments: ["", "h2 value", "协议"]
    )
    func rejectsInvalidApplicationProtocol(_ value: String) {
        #expect(throws: TLSConfigurationError.self) {
            try TLSConfiguration(
                host: "example.com",
                applicationProtocols: [value]
            ).validated()
        }
    }

    @Test("DER certificate details are parsed")
    func parsesCertificate() throws {
        let data = try #require(
            Data(base64Encoded: Self.certificateDERBase64)
        )
        let certificates = try TLSCertificateParser.parse(
            derCertificates: [data]
        )
        let certificate = try #require(certificates.first)

        #expect(certificate.index == 0)
        #expect(certificate.subject.contains("CN=tls.example.test"))
        #expect(certificate.issuer == certificate.subject)
        #expect(certificate.serialNumber == "01:02:03:04:05:06:07:08")
        #expect(certificate.publicKey == "RSA2048.PublicKey")
        #expect(
            certificate.signatureAlgorithm
                == "sha256WithRSAEncryption"
        )
        #expect(
            certificate.subjectAlternativeNames.contains(
                "DNS:tls.example.test"
            )
        )
        #expect(
            certificate.subjectAlternativeNames.contains(
                "IP:192.0.2.10"
            )
        )
        #expect(
            certificate.subjectAlternativeNames.contains(
                "IP:2001:0DB8:0000:0000:0000:0000:0000:0010"
            )
        )
        #expect(
            certificate.sha256Fingerprint
                == "D9:5F:12:07:58:7B:10:BB:"
                    + "4B:81:05:2F:CC:AB:27:E6:"
                    + "D7:7D:42:A5:7F:CA:12:47:"
                    + "DC:9D:A6:23:BF:84:9E:C9"
        )
    }

    @Test("Malformed DER is rejected explicitly")
    func rejectsMalformedCertificate() {
        #expect(throws: TLSCertificateParserError.self) {
            try TLSCertificateParser.parse(
                derCertificates: [Data([0x30, 0x00])]
            )
        }
    }

    private static let certificateDERBase64 =
        "MIIDnjCCAoagAwIBAgIIAQIDBAUGBwgwDQYJKoZIhvcNAQEL"
        + "BQAwQDELMAkGA1UEBhMCQ04xFjAUBgNVBAoMDU5ldFRvb2wg"
        + "VGVzdHMxGTAXBgNVBAMMEHRscy5leGFtcGxlLnRlc3QwHhcN"
        + "MjYwNzI0MDUyMjU5WhcNMzYwNzIxMDUyMjU5WjBAMQswCQYD"
        + "VQQGEwJDTjEWMBQGA1UECgwNTmV0VG9vbCBUZXN0czEZMBcG"
        + "A1UEAwwQdGxzLmV4YW1wbGUudGVzdDCCASIwDQYJKoZIhvcN"
        + "AQEBBQADggEPADCCAQoCggEBAN6HHBbCyrISuhYghgHM6zDW"
        + "tEvv4HuNEW+sOdb6qx354sthRrDforJSqN6vduBy4TLDq+Ow"
        + "MocJxplTredvqiR9gEbBszF0b5YIj95jD3sPXyFaRP3nFZs"
        + "3FA6e6kCEJPtiawCocXGOQqR6el1aAejzjIj7gT6BRKe/4L"
        + "xdlFenBbqjCRucWPYnITc8rJ0RFUVK9afilonrYx8Mwwl94h"
        + "vabtRA3cdZzhWR42v+XoccL/S4/yKUrdUmFwOU99EVGooIO2"
        + "rspWui9iGVoV+XDryP2EyQArf5TWmoAXepkvivbJQtg0PL8S"
        + "kpcl+twAqC0eH1okTa5hXU4QviWN7KVh0CAwEAAaOBmzCBmD"
        + "AdBgNVHQ4EFgQUyK/PCcXqQiJqvFeZ6E1LUVtKcUYwHwYDVR"
        + "0jBBgwFoAUyK/PCcXqQiJqvFeZ6E1LUVtKcUYwDwYDVR0TAQ"
        + "H/BAUwAwEB/zBFBgNVHREEPjA8ghB0bHMuZXhhbXBsZS50ZX"
        + "N0ghBhbHQuZXhhbXBsZS50ZXN0hwTAAAIKhxAgAQ24AAAAAAAA"
        + "AAAAAAAQMA0GCSqGSIb3DQEBCwUAA4IBAQAh8guF5t0OlY1Z"
        + "hGC1KUljRUmLolNg//dZSA8n9SJePEyO9q0BSkbWOXdbSaxG"
        + "lVpUA+6i+MKRRGrAJqsC4MoNAJDmL3BplPtw96rky63BGhPz"
        + "iBcJWYlQh29M04OOMg1EOjv3jRdOoTafN1g+A1Yj2T+qH3H"
        + "LqHzq9HGqzdCR8KJrVc5qU8lYcYzskFUDSHwJr0pNSgR5UV"
        + "hjnLG73I4I8zR1J88HpGeSalh5Qmz6Cg3+VBfVb6i9WEEDa"
        + "xXrtBi9s9Ine/eB7IOsITSn+SNFjMyeoiSWRvI6BwSYEV6p"
        + "dkQGvHIeaXqlXcgAOCVspPDVGHW0lJ7FVW6PrJfi0N0C"
}
