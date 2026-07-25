import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class NetworkInfoViewModel {
    private(set) var path: NetworkPathSnapshot?
    private(set) var interfaces: [NetworkInterfaceSnapshot] = []
    private(set) var interfacesError: String?
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
            self.neighbors = result.neighbors
            self.lastUpdated = result.generatedAt
            self.isRefreshing = false
            self.refreshTask = nil

            let neighborCount = result.neighbors.entries.count
            logStore.append(
                level: .info,
                message: "刷新网络信息："
                    + "\(result.interfaces.count) 个接口，"
                    + "\(neighborCount) 条 Neighbor 缓存"
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
                neighbors: neighbors
            )
        )
    }
}

private struct NetworkInfoCollectionResult: Sendable {
    let generatedAt: Date
    let interfaces: [NetworkInterfaceSnapshot]
    let interfacesError: String?
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

        return NetworkInfoCollectionResult(
            generatedAt: Date(),
            interfaces: interfaces,
            interfacesError: interfacesError,
            neighbors: DarwinNeighborCacheReader().read()
        )
    }
}
