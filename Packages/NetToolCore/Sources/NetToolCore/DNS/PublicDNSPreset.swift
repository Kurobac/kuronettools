public struct PublicDNSPreset: Identifiable, Hashable, Sendable {
    public let name: String
    public let address: String

    public var id: String { address }

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    public static let mainlandChina: [PublicDNSPreset] = [
        PublicDNSPreset(name: "阿里 AliDNS", address: "223.5.5.5"),
        PublicDNSPreset(name: "腾讯 DNSPod", address: "119.29.29.29"),
        PublicDNSPreset(name: "114DNS", address: "114.114.114.114"),
        PublicDNSPreset(name: "百度 DNS", address: "180.76.76.76")
    ]

    public static let global: [PublicDNSPreset] = [
        PublicDNSPreset(name: "Cloudflare", address: "1.1.1.1"),
        PublicDNSPreset(name: "Google", address: "8.8.8.8"),
        PublicDNSPreset(name: "Quad9", address: "9.9.9.9")
    ]

    public static let all = mainlandChina + global
}
