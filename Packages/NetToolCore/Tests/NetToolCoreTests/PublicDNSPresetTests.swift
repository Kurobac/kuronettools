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
}
