import Foundation
import Testing

@testable import NetToolCore

@Suite("Network information models")
struct NetworkInfoModelsTests {
    @Test("Interface address includes prefix")
    func addressCIDRDescription() {
        let address = NetworkInterfaceAddress(
            family: .ipv6,
            address: "2001:db8::1",
            prefixLength: 64,
            classification: "全局单播"
        )

        #expect(address.cidrDescription == "2001:db8::1/64")
    }

    @Test("Related addresses follow IP family semantics")
    func relatedAddressKind() {
        #expect(
            NetworkInterfaceRelatedAddressKind.resolve(
                family: .ipv4,
                isPointToPoint: false,
                supportsBroadcast: true
            ) == .broadcast
        )
        #expect(
            NetworkInterfaceRelatedAddressKind.resolve(
                family: .ipv6,
                isPointToPoint: false,
                supportsBroadcast: true
            ) == nil
        )
        #expect(
            NetworkInterfaceRelatedAddressKind.resolve(
                family: .ipv6,
                isPointToPoint: true,
                supportsBroadcast: true
            ) == .peer
        )
    }

    @Test("Neighbor identifiers separate families and interfaces")
    func neighborIdentifiers() {
        let ipv4 = NeighborEntry(
            family: .ipv4,
            address: "192.0.2.1",
            linkLayerAddress: "00:11:22:33:44:55",
            interfaceName: "en0",
            flags: [],
            expiration: nil,
            isPermanent: false
        )
        let ipv6 = NeighborEntry(
            family: .ipv6,
            address: "192.0.2.1",
            linkLayerAddress: "00:11:22:33:44:55",
            interfaceName: "en0",
            flags: [],
            expiration: nil,
            isPermanent: false
        )

        #expect(ipv4.id != ipv6.id)
    }

    @Test("Export distinguishes an empty cache from a read error")
    func exportDistinguishesEmptyAndError() {
        let snapshot = NetworkInfoSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            path: nil,
            interfaces: [],
            interfacesError: nil,
            neighbors: NeighborCacheSnapshot(
                ipv4: [],
                ipv6: [],
                ipv4Error: nil,
                ipv6Error: "sysctl: Operation not permitted (errno 1)"
            )
        )

        let text = NetworkInfoTextFormatter.format(snapshot)

        #expect(text.contains("IPv4\n(cache empty)"))
        #expect(
            text.contains(
                "IPv6\nError: sysctl: Operation not permitted (errno 1)"
            )
        )
    }
}
