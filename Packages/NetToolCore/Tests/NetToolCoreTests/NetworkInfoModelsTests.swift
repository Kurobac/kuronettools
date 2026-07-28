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

    @Test("Export includes IPv6 autoconfiguration details")
    func exportIncludesIPv6Autoconfiguration() {
        let router = IPv6DefaultRouterEntry(
            address: "fe80::1%en0",
            interfaceName: "en0",
            managedConfiguration: false,
            otherConfiguration: true,
            homeAgent: false,
            preference: .high,
            advertisedLifetimeSeconds: 1800,
            expiration: Date(timeIntervalSince1970: 3600),
            stateFlags: ["INSTALLED", "SCOPED"]
        )
        let prefix = IPv6PrefixEntry(
            address: "2001:db8::",
            prefixLength: 64,
            interfaceName: "en0",
            onLink: true,
            autonomous: true,
            validLifetimeSeconds: 86_400,
            preferredLifetimeSeconds: 14_400,
            expiration: Date(timeIntervalSince1970: 86_400),
            stateFlags: ["ONLINK"],
            advertisingRouters: ["fe80::1%en0"]
        )
        let interface = IPv6NDInterfaceSnapshot(
            interfaceName: "en0",
            linkMTU: 1500,
            maximumMTU: 1500,
            baseReachableTimeMilliseconds: 30_000,
            reachableTimeSeconds: 27,
            retransmitTimerMilliseconds: 1000,
            currentHopLimit: 64,
            learnedRouterCount: 1,
            flags: ["PERFORMNUD", "DAD"]
        )
        let snapshot = NetworkInfoSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            path: nil,
            interfaces: [],
            interfacesError: nil,
            ipv6Autoconfiguration: IPv6AutoconfigurationSnapshot(
                defaultRouters: [router],
                prefixes: [prefix],
                interfaces: [interface]
            ),
            neighbors: NeighborCacheSnapshot()
        )

        let text = NetworkInfoTextFormatter.format(snapshot)

        #expect(
            text.contains(
                "fe80::1%en0 dev en0 preference high "
                    + "lifetime 1800s RA [O] "
                    + "state [INSTALLED,SCOPED]"
            )
        )
        #expect(
            text.contains(
                "2001:db8::/64 dev en0 valid 86400s "
                    + "preferred 14400s RA [L,A]"
            )
        )
        #expect(
            text.contains(
                "en0 mtu 1500 max-mtu 1500 hop-limit 64 "
                    + "base-reachable 30000ms reachable 27s "
                    + "retrans 1000ms routers 1"
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
