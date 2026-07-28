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
            interfaceName: "en0",
            flags: [],
            expiration: nil,
            isPermanent: false
        )
        let ipv6 = NeighborEntry(
            family: .ipv6,
            address: "192.0.2.1",
            interfaceName: "en0",
            flags: [],
            expiration: nil,
            isPermanent: false
        )

        #expect(ipv4.id != ipv6.id)
    }

    @Test("Neighbor expiration preserves active and permanent entries")
    func neighborExpiration() {
        let referenceDate = Date(timeIntervalSince1970: 100)
        let expired = NeighborEntry(
            family: .ipv4,
            address: "192.0.2.1",
            interfaceName: "en0",
            flags: ["HOST"],
            expiration: Date(timeIntervalSince1970: 99),
            isPermanent: false
        )
        let active = NeighborEntry(
            family: .ipv4,
            address: "192.0.2.2",
            interfaceName: "en0",
            flags: ["HOST"],
            expiration: Date(timeIntervalSince1970: 101),
            isPermanent: false
        )
        let permanent = NeighborEntry(
            family: .ipv4,
            address: "192.0.2.3",
            interfaceName: "en0",
            flags: ["HOST", "STATIC"],
            expiration: nil,
            isPermanent: true
        )

        #expect(expired.isExpired(at: referenceDate))
        #expect(!active.isExpired(at: referenceDate))
        #expect(!permanent.isExpired(at: referenceDate))
    }

    @Test("Route destinations format defaults and prefixes")
    func routeDestinationDescription() {
        let defaultRoute = NetworkRouteEntry(
            family: .ipv4,
            destination: "0.0.0.0",
            prefixLength: 0,
            gateway: "192.0.2.1",
            interfaceName: "en0",
            flags: ["UP", "GATEWAY"],
            mtu: 1500
        )
        let prefixRoute = NetworkRouteEntry(
            family: .ipv6,
            destination: "2001:db8::",
            prefixLength: 32,
            gateway: nil,
            interfaceName: "en0",
            flags: ["UP"],
            mtu: nil
        )

        #expect(defaultRoute.isDefault)
        #expect(defaultRoute.destinationDescription == "默认")
        #expect(prefixRoute.destinationDescription == "2001:db8::/32")
    }

    @Test("Route cache detection preserves configured host routes")
    func routeCacheDetection() {
        let connectedPrefix = NetworkRouteEntry(
            family: .ipv4,
            destination: "192.168.1.0",
            prefixLength: 24,
            gateway: nil,
            interfaceName: "en0",
            flags: ["UP", "CLONING"],
            mtu: 1500
        )
        let clonedHost = NetworkRouteEntry(
            family: .ipv4,
            destination: "192.168.1.42",
            prefixLength: 32,
            gateway: nil,
            interfaceName: "en0",
            flags: ["UP", "HOST", "WASCLONED"],
            mtu: 1500
        )
        let neighbor = NetworkRouteEntry(
            family: .ipv4,
            destination: "192.168.1.1",
            prefixLength: 32,
            gateway: nil,
            interfaceName: "en0",
            flags: ["UP", "HOST", "LLINFO"],
            mtu: 1500
        )
        let configuredHost = NetworkRouteEntry(
            family: .ipv4,
            destination: "192.0.2.10",
            prefixLength: 32,
            gateway: "192.168.1.1",
            interfaceName: "en0",
            flags: ["UP", "GATEWAY", "HOST", "STATIC"],
            mtu: 1500
        )

        #expect(!connectedPrefix.isRoutingCacheEntry)
        #expect(clonedHost.isRoutingCacheEntry)
        #expect(neighbor.isRoutingCacheEntry)
        #expect(!configuredHost.isRoutingCacheEntry)
    }

    @Test("Export includes route details")
    func exportIncludesRoutes() {
        let route = NetworkRouteEntry(
            family: .ipv4,
            destination: "0.0.0.0",
            prefixLength: 0,
            gateway: "192.0.2.1",
            interfaceName: "en0",
            flags: ["UP", "GATEWAY"],
            mtu: 1500
        )
        let snapshot = NetworkInfoSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            path: nil,
            interfaces: [],
            interfacesError: nil,
            routes: NetworkRouteTableSnapshot(ipv4: [route]),
            neighbors: NeighborCacheSnapshot()
        )

        let text = NetworkInfoTextFormatter.format(snapshot)

        #expect(
            text.contains(
                "默认 via 192.0.2.1 dev en0 [UP,GATEWAY] mtu 1500"
            )
        )
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
