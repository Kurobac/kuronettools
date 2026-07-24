import Testing

@testable import NetToolCore

@Suite("HTTP models")
struct HTTPModelsTests {
    @Test("Configuration normalizes a valid HTTP URL")
    func validatesConfiguration() throws {
        let configuration = try HTTPInspectionConfiguration(
            scheme: .http,
            target:
                " HTTPS://example.com:8443/path?q=1#fragment ",
            followsRedirects: true,
            timeoutSeconds: 15,
            allowsUntrustedCertificates: true
        ).validated()

        #expect(configuration.scheme == .https)
        #expect(configuration.target == "example.com:8443/path?q=1")
        #expect(
            configuration.url
                == "https://example.com:8443/path?q=1"
        )
        #expect(configuration.followsRedirects)
        #expect(configuration.timeoutSeconds == 15)
        #expect(configuration.allowsUntrustedCertificates)
    }

    @Test("Selected scheme composes with a scheme-free target")
    func composesSelectedScheme() throws {
        let configuration = try HTTPInspectionConfiguration(
            scheme: .http,
            target:
                "192.168.1.1:8080/status?next=https://example.com"
        ).validated()

        #expect(configuration.scheme == .http)
        #expect(
            configuration.target
                == "192.168.1.1:8080/status"
                    + "?next=https://example.com"
        )
        #expect(
            configuration.url
                == "http://192.168.1.1:8080/status"
                    + "?next=https://example.com"
        )
    }

    @Test(
        "Invalid configuration is rejected",
        arguments: [
            HTTPInspectionConfiguration(target: ""),
            HTTPInspectionConfiguration(target: "/path"),
            HTTPInspectionConfiguration(
                target: "ftp://example.com"
            ),
            HTTPInspectionConfiguration(target: "https:///path"),
            HTTPInspectionConfiguration(
                target: "https://user:pass@example.com"
            ),
            HTTPInspectionConfiguration(
                target: "example.com",
                timeoutSeconds: 0
            ),
            HTTPInspectionConfiguration(
                target: "example.com",
                timeoutSeconds: 61
            )
        ]
    )
    func rejectsInvalidConfiguration(
        _ configuration: HTTPInspectionConfiguration
    ) {
        #expect(throws: HTTPConfigurationError.self) {
            try configuration.validated()
        }
    }

    @Test("Protocol names expose HTTP titles")
    func exposesProtocolTitles() {
        #expect(transaction(protocolName: "http/1.1").protocolTitle == "HTTP/1.1")
        #expect(transaction(protocolName: "h2").protocolTitle == "HTTP/2")
        #expect(transaction(protocolName: "h3").protocolTitle == "HTTP/3")
        #expect(transaction(protocolName: nil).protocolTitle == "HTTP")
    }

    @Test("Resource sources expose user-facing titles")
    func exposesResourceSourceTitles() {
        #expect(HTTPResourceSource.network.title == "网络")
        #expect(HTTPResourceSource.serverPush.title == "服务器推送")
        #expect(HTTPResourceSource.localCache.title == "本地缓存")
        #expect(HTTPResourceSource.unknown.title == "未知")
    }

    @Test("Result aggregates connection phase timings")
    func aggregatesTimings() {
        let result = HTTPInspectionResult(
            originalURL: "https://example.com",
            finalURL: "https://www.example.com",
            redirectCount: 1,
            allowsUntrustedCertificates: false,
            timeToFirstByteMilliseconds: 42,
            totalMilliseconds: 50,
            transactions: [
                transaction(
                    protocolName: "h2",
                    timing: HTTPTransactionTiming(
                        dnsMilliseconds: 2,
                        tcpMilliseconds: 3,
                        tlsMilliseconds: 4,
                        timeToFirstByteMilliseconds: 10,
                        totalMilliseconds: 12
                    )
                ),
                transaction(
                    protocolName: "h2",
                    timing: HTTPTransactionTiming(
                        dnsMilliseconds: 5,
                        tcpMilliseconds: nil,
                        tlsMilliseconds: nil,
                        timeToFirstByteMilliseconds: 20,
                        totalMilliseconds: 25
                    )
                )
            ]
        )

        #expect(result.dnsMilliseconds == 7)
        #expect(result.tcpMilliseconds == 3)
        #expect(result.tlsMilliseconds == 4)
        #expect(result.timeToFirstByteMilliseconds == 42)
        #expect(result.totalMilliseconds == 50)
    }

    private func transaction(
        protocolName: String?,
        timing: HTTPTransactionTiming = HTTPTransactionTiming(
            dnsMilliseconds: nil,
            tcpMilliseconds: nil,
            tlsMilliseconds: nil,
            timeToFirstByteMilliseconds: nil,
            totalMilliseconds: nil
        )
    ) -> HTTPTransaction {
        HTTPTransaction(
            index: 0,
            requestURL: "https://example.com",
            responseURL: "https://example.com",
            statusCode: 200,
            networkProtocolName: protocolName,
            headers: [],
            requestHeaderBytesSent: 0,
            responseHeaderBytesReceived: 0,
            timing: timing,
            connection: HTTPConnectionInfo(
                localAddress: nil,
                localPort: nil,
                remoteAddress: nil,
                remotePort: nil,
                tlsProtocolVersion: nil,
                tlsCipherSuite: nil,
                isReusedConnection: false,
                isProxyConnection: false,
                isCellular: false,
                isExpensive: false,
                isConstrained: false,
                resourceSource: .unknown
            )
        )
    }
}
