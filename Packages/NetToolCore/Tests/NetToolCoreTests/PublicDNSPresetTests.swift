import Testing

@testable import NetToolCore

@Suite("Public DNS presets")
struct PublicDNSPresetTests {
    @Test("Preset identifiers and addresses are unique")
    func presetsAreUnique() {
        let identifiers = PublicDNSPreset.all.map(\.id)
        let addresses = PublicDNSPreset.all.map(\.address)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(Set(addresses).count == addresses.count)
    }

    @Test("Mainland China and global groups are populated")
    func groupsArePopulated() {
        #expect(!PublicDNSPreset.mainlandChina.isEmpty)
        #expect(!PublicDNSPreset.global.isEmpty)
        #expect(
            PublicDNSPreset.all.count
                == PublicDNSPreset.mainlandChina.count
                    + PublicDNSPreset.global.count
        )
    }

    @Test("Encrypted transports only expose configured endpoints")
    func encryptedEndpointsAreExplicit() throws {
        let aliDNS = try #require(
            PublicDNSPreset.all.first { $0.address == "223.5.5.5" }
        )
        let dns114 = try #require(
            PublicDNSPreset.all.first {
                $0.address == "114.114.114.114"
            }
        )

        #expect(aliDNS.endpoint(for: .udp) == "223.5.5.5")
        #expect(aliDNS.endpoint(for: .tls) == "dns.alidns.com")
        #expect(
            aliDNS.endpoint(for: .https)
                == "https://dns.alidns.com/dns-query"
        )
        #expect(dns114.endpoint(for: .tls) == nil)
        #expect(dns114.endpoint(for: .https) == nil)
    }
}
