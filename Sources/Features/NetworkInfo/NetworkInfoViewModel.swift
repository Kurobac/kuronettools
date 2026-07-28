import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class NetworkInfoViewModel {
    private(set) var path: NetworkPathSnapshot?
    private(set) var interfaces: [NetworkInterfaceSnapshot] = []
    private(set) var interfacesError: String?
    private(set) var routes = NetworkRouteTableSnapshot()
    private(set) var ipv6Autoconfiguration =
        IPv6AutoconfigurationSnapshot()
    private(set) var neighbors = NeighborCacheSnapshot()
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored
    private let pathObserver = NetworkPathObserver()

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var didStart = false

    func start(logStore: AppLogStore) {
        guard !didStart else {
            return
        }
        didStart = true

        pathObserver.start { [weak self] snapshot in
            self?.path = snapshot
        }
        refresh(logStore: logStore)
    }

    func refresh(logStore: AppLogStore) {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await Task.detached(
                priority: .userInitiated
            ) {
                NetworkInfoCollectionResult.collect()
            }.value

            guard !Task.isCancelled else {
                self.isRefreshing = false
                self.refreshTask = nil
                return
            }

            self.interfaces = result.interfaces
            self.interfacesError = result.interfacesError
            self.routes = result.routes
            self.ipv6Autoconfiguration =
                result.ipv6Autoconfiguration
            self.neighbors = result.neighbors
            self.lastUpdated = result.generatedAt
            self.isRefreshing = false
            self.refreshTask = nil

            let neighborCount = result.neighbors.entries.count
            let routeCount = result.routes.entries.count
            let routerCount =
                result.ipv6Autoconfiguration.defaultRouters.count
            let prefixCount =
                result.ipv6Autoconfiguration.prefixes.count
            logStore.append(
                level: .info,
                message: "刷新网络信息："
                    + "\(result.interfaces.count) 个接口，"
                    + "\(routeCount) 条路由，"
                    + "\(neighborCount) 条 Neighbor 缓存，"
                    + "\(routerCount) 个 IPv6 默认路由器，"
                    + "\(prefixCount) 个 IPv6 前缀"
            )

            if let error = result.interfacesError {
                logStore.append(
                    level: .error,
                    message: "读取网络接口失败：\(error)"
                )
            }
            if let error = result.neighbors.ipv4Error {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv4 Neighbor 失败：\(error)"
                )
            }
            if let error = result.neighbors.ipv6Error {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv6 Neighbor 失败：\(error)"
                )
            }
            if let error = result.routes.ipv4Error {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv4 路由失败：\(error)"
                )
            }
            if let error = result.routes.ipv6Error {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv6 路由失败：\(error)"
                )
            }
            if let error =
                result.ipv6Autoconfiguration.defaultRoutersError
            {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv6 默认路由器失败：\(error)"
                )
            }
            if let error =
                result.ipv6Autoconfiguration.prefixesError
            {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv6 RA 前缀失败：\(error)"
                )
            }
            if let error =
                result.ipv6Autoconfiguration.interfacesError
            {
                logStore.append(
                    level: .warning,
                    message: "读取 IPv6 ND 接口参数失败：\(error)"
                )
            }
            for error in
                result.ipv6Autoconfiguration.interfaceErrors
            {
                logStore.append(
                    level: .warning,
                    message: "读取 \(error.interfaceName) "
                        + "IPv6 ND 参数失败：\(error.message)"
                )
            }
        }
    }

    func stop() {
        pathObserver.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    var exportText: String {
        guard let lastUpdated else {
            return ""
        }

        return NetworkInfoTextFormatter.format(
            NetworkInfoSnapshot(
                generatedAt: lastUpdated,
                path: path,
                interfaces: interfaces,
                interfacesError: interfacesError,
                routes: routes,
                ipv6Autoconfiguration: ipv6Autoconfiguration,
                neighbors: neighbors
            )
        )
    }
}

private struct NetworkInfoCollectionResult: Sendable {
    let generatedAt: Date
    let interfaces: [NetworkInterfaceSnapshot]
    let interfacesError: String?
    let routes: NetworkRouteTableSnapshot
    let ipv6Autoconfiguration: IPv6AutoconfigurationSnapshot
    let neighbors: NeighborCacheSnapshot

    static func collect() -> NetworkInfoCollectionResult {
        let interfaces: [NetworkInterfaceSnapshot]
        let interfacesError: String?

        do {
            interfaces = try NetworkInterfaceReader().read()
            interfacesError = nil
        } catch {
            interfaces = []
            interfacesError = error.localizedDescription
        }

        let ipv6InterfaceNames = interfaces
            .filter {
                let supportsNeighborDiscovery =
                    $0.kind == .wifi
                    || $0.kind == .cellular
                    || $0.kind == .wiredEthernet
                return supportsNeighborDiscovery
                    && $0.addresses.contains {
                        $0.family == .ipv6
                    }
            }
            .map(\.name)

        return NetworkInfoCollectionResult(
            generatedAt: Date(),
            interfaces: interfaces,
            interfacesError: interfacesError,
            routes: DarwinRouteTableReader().read(),
            ipv6Autoconfiguration:
                DarwinIPv6AutoconfigurationReader().read(
                    interfaceNames: ipv6InterfaceNames
                ),
            neighbors: DarwinNeighborCacheReader().read()
        )
    }
}
