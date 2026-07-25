import Foundation
import NetToolCore
import Network

final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "dev.kurobac.NetTool.network-path"
    )

    func start(
        handler: @escaping @MainActor @Sendable (
            NetworkPathSnapshot
        ) -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            let snapshot = Self.snapshot(from: path)
            Task { @MainActor in
                handler(snapshot)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private static func snapshot(
        from path: NWPath
    ) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: status(path.status),
            unsatisfiedReason: unsatisfiedReason(path),
            interfaces: path.availableInterfaces.map {
                NetworkPathInterface(
                    name: $0.name,
                    kind: interfaceKind(
                        name: $0.name,
                        type: $0.type
                    )
                )
            },
            gateways: path.gateways.map(gatewayDescription),
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            isUltraConstrained: path.isUltraConstrained,
            linkQuality: linkQuality(path.linkQuality)
        )
    }

    private static func status(
        _ status: NWPath.Status
    ) -> NetworkPathStatus {
        switch status {
        case .satisfied:
            .satisfied
        case .requiresConnection:
            .requiresConnection
        case .unsatisfied:
            .unsatisfied
        @unknown default:
            .unsatisfied
        }
    }

    private static func unsatisfiedReason(
        _ path: NWPath
    ) -> String? {
        guard path.status != .satisfied else {
            return nil
        }

        return switch path.unsatisfiedReason {
        case .cellularDenied:
            "蜂窝网络被禁用"
        case .wifiDenied:
            "Wi-Fi 被禁用"
        case .localNetworkDenied:
            "本地网络访问被拒绝"
        case .vpnInactive:
            "VPN 未激活"
        case .notAvailable:
            "没有可用网络"
        @unknown default:
            "未知原因"
        }
    }

    private static func interfaceKind(
        name: String,
        type: NWInterface.InterfaceType
    ) -> NetworkInterfaceKind {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") {
            return .tunnel
        }

        switch type {
        case .wifi:
            return .wifi
        case .cellular:
            return .cellular
        case .wiredEthernet:
            return .wiredEthernet
        case .loopback:
            return .loopback
        case .other:
            return .other
        @unknown default:
            return .other
        }
    }

    private static func linkQuality(
        _ quality: NWPath.LinkQuality
    ) -> NetworkLinkQuality {
        switch quality {
        case .unknown:
            .unknown
        case .minimal:
            .minimal
        case .moderate:
            .moderate
        case .good:
            .good
        @unknown default:
            .unknown
        }
    }

    private static func gatewayDescription(
        _ endpoint: NWEndpoint
    ) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            "\(host)"
        default:
            "\(endpoint)"
        }
    }
}
