public struct PublicDNSPreset: Identifiable, Hashable, Sendable {
    public let name: String
    public let address: String
    public let tlsServer: String?
    public let tlsServerName: String?
    public let httpsURL: String?

    public var id: String { address }

    public init(
        name: String,
        address: String,
        tlsServer: String? = nil,
        tlsServerName: String? = nil,
        httpsURL: String? = nil
    ) {
        self.name = name
        self.address = address
        self.tlsServer = tlsServer
        self.tlsServerName = tlsServerName
        self.httpsURL = httpsURL
    }

    public func endpoint(for transport: DNSTransport) -> String? {
        switch transport {
        case .udp, .tcp:
            address
        case .tls:
            tlsServer
        case .https:
            httpsURL
        }
    }

    public static let mainlandChina: [PublicDNSPreset] = [
        PublicDNSPreset(
            name: "阿里 AliDNS",
            address: "223.5.5.5",
            tlsServer: "dns.alidns.com",
            httpsURL: "https://dns.alidns.com/dns-query"
        ),
        PublicDNSPreset(
            name: "腾讯 DNSPod",
            address: "119.29.29.29",
            tlsServer: "dot.pub",
            httpsURL: "https://doh.pub/dns-query"
        ),
        PublicDNSPreset(name: "114DNS", address: "114.114.114.114"),
        PublicDNSPreset(name: "百度 DNS", address: "180.76.76.76")
    ]

    public static let global: [PublicDNSPreset] = [
        PublicDNSPreset(
            name: "Cloudflare",
            address: "1.1.1.1",
            tlsServer: "1.1.1.1",
            tlsServerName: "one.one.one.one",
            httpsURL: "https://cloudflare-dns.com/dns-query"
        ),
        PublicDNSPreset(
            name: "Google",
            address: "8.8.8.8",
            tlsServer: "dns.google",
            httpsURL: "https://dns.google/dns-query"
        ),
        PublicDNSPreset(
            name: "Quad9",
            address: "9.9.9.9",
            tlsServer: "dns.quad9.net",
            httpsURL: "https://dns.quad9.net/dns-query"
        )
    ]

    public static let all = mainlandChina + global
}
