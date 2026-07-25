import Foundation

public enum NetworkPathStatus: String, Equatable, Sendable {
    case satisfied
    case requiresConnection
    case unsatisfied

    public var title: String {
        switch self {
        case .satisfied:
            "可用"
        case .requiresConnection:
            "需要建立连接"
        case .unsatisfied:
            "不可用"
        }
    }
}

public enum NetworkInterfaceKind: String, Equatable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case tunnel
    case other

    public var title: String {
        switch self {
        case .wifi:
            "Wi-Fi"
        case .cellular:
            "蜂窝网络"
        case .wiredEthernet:
            "有线网络"
        case .loopback:
            "回环"
        case .tunnel:
            "隧道"
        case .other:
            "其他"
        }
    }
}

public enum NetworkLinkQuality: String, Equatable, Sendable {
    case unknown
    case minimal
    case moderate
    case good

    public var title: String {
        switch self {
        case .unknown:
            "未知"
        case .minimal:
            "最低"
        case .moderate:
            "中等"
        case .good:
            "良好"
        }
    }
}

public struct NetworkPathInterface: Equatable, Sendable {
    public let name: String
    public let kind: NetworkInterfaceKind

    public init(
        name: String,
        kind: NetworkInterfaceKind
    ) {
        self.name = name
        self.kind = kind
    }
}

public struct NetworkPathSnapshot: Equatable, Sendable {
    public let status: NetworkPathStatus
    public let unsatisfiedReason: String?
    public let interfaces: [NetworkPathInterface]
    public let gateways: [String]
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let isUltraConstrained: Bool
    public let linkQuality: NetworkLinkQuality

    public init(
        status: NetworkPathStatus,
        unsatisfiedReason: String? = nil,
        interfaces: [NetworkPathInterface],
        gateways: [String],
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        supportsDNS: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isUltraConstrained: Bool,
        linkQuality: NetworkLinkQuality
    ) {
        self.status = status
        self.unsatisfiedReason = unsatisfiedReason
        self.interfaces = interfaces
        self.gateways = gateways
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isUltraConstrained = isUltraConstrained
        self.linkQuality = linkQuality
    }
}

public enum InterfaceAddressFamily: String, Equatable, Sendable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

public struct NetworkInterfaceAddress: Equatable, Sendable {
    public let family: InterfaceAddressFamily
    public let address: String
    public let prefixLength: Int?
    public let classification: String
    public let relatedAddressLabel: String?
    public let relatedAddress: String?

    public init(
        family: InterfaceAddressFamily,
        address: String,
        prefixLength: Int?,
        classification: String,
        relatedAddressLabel: String? = nil,
        relatedAddress: String? = nil
    ) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
        self.classification = classification
        self.relatedAddressLabel = relatedAddressLabel
        self.relatedAddress = relatedAddress
    }

    public var cidrDescription: String {
        guard let prefixLength else {
            return address
        }
        return "\(address)/\(prefixLength)"
    }
}

public struct NetworkInterfaceStatistics: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedPackets: UInt64
    public let sentPackets: UInt64
    public let inputErrors: UInt64
    public let outputErrors: UInt64

    public init(
        receivedBytes: UInt64,
        sentBytes: UInt64,
        receivedPackets: UInt64,
        sentPackets: UInt64,
        inputErrors: UInt64,
        outputErrors: UInt64
    ) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedPackets = receivedPackets
        self.sentPackets = sentPackets
        self.inputErrors = inputErrors
        self.outputErrors = outputErrors
    }
}

public struct NetworkInterfaceSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let index: UInt32
    public let kind: NetworkInterfaceKind
    public let flags: [String]
    public let mtu: Int?
    public let linkLayerAddress: String?
    public let addresses: [NetworkInterfaceAddress]
    public let statistics: NetworkInterfaceStatistics?

    public init(
        name: String,
        index: UInt32,
        kind: NetworkInterfaceKind,
        flags: [String],
        mtu: Int?,
        linkLayerAddress: String?,
        addresses: [NetworkInterfaceAddress],
        statistics: NetworkInterfaceStatistics?
    ) {
        self.name = name
        self.index = index
        self.kind = kind
        self.flags = flags
        self.mtu = mtu
        self.linkLayerAddress = linkLayerAddress
        self.addresses = addresses
        self.statistics = statistics
    }
}

public enum NeighborAddressFamily: String, Equatable, Sendable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

public struct NeighborEntry: Identifiable, Equatable, Sendable {
    public var id: String {
        "\(family.rawValue)|\(interfaceName)|\(address)"
    }

    public let family: NeighborAddressFamily
    public let address: String
    public let linkLayerAddress: String?
    public let interfaceName: String
    public let flags: [String]
    public let expiration: Date?
    public let isPermanent: Bool

    public init(
        family: NeighborAddressFamily,
        address: String,
        linkLayerAddress: String?,
        interfaceName: String,
        flags: [String],
        expiration: Date?,
        isPermanent: Bool
    ) {
        self.family = family
        self.address = address
        self.linkLayerAddress = linkLayerAddress
        self.interfaceName = interfaceName
        self.flags = flags
        self.expiration = expiration
        self.isPermanent = isPermanent
    }
}

public struct NeighborCacheSnapshot: Equatable, Sendable {
    public let ipv4: [NeighborEntry]
    public let ipv6: [NeighborEntry]
    public let ipv4Error: String?
    public let ipv6Error: String?

    public init(
        ipv4: [NeighborEntry] = [],
        ipv6: [NeighborEntry] = [],
        ipv4Error: String? = nil,
        ipv6Error: String? = nil
    ) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.ipv4Error = ipv4Error
        self.ipv6Error = ipv6Error
    }

    public var entries: [NeighborEntry] {
        ipv4 + ipv6
    }
}

public struct NetworkInfoSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let path: NetworkPathSnapshot?
    public let interfaces: [NetworkInterfaceSnapshot]
    public let interfacesError: String?
    public let neighbors: NeighborCacheSnapshot

    public init(
        generatedAt: Date,
        path: NetworkPathSnapshot?,
        interfaces: [NetworkInterfaceSnapshot],
        interfacesError: String?,
        neighbors: NeighborCacheSnapshot
    ) {
        self.generatedAt = generatedAt
        self.path = path
        self.interfaces = interfaces
        self.interfacesError = interfacesError
        self.neighbors = neighbors
    }
}

public enum NetworkInfoTextFormatter {
    public static func format(
        _ snapshot: NetworkInfoSnapshot
    ) -> String {
        var lines = [
            "NETTOOL NETWORK INFO",
            "Generated: \(ISO8601DateFormatter().string(from: snapshot.generatedAt))",
            "",
            "PATH"
        ]

        if let path = snapshot.path {
            lines.append("Status: \(path.status.title)")
            if let reason = path.unsatisfiedReason {
                lines.append("Unsatisfied reason: \(reason)")
            }
            lines.append(
                "Interfaces: "
                    + list(
                        path.interfaces.map {
                            "\($0.name) (\($0.kind.title))"
                        }
                    )
            )
            lines.append("Gateways: \(list(path.gateways))")
            lines.append("IPv4: \(yesNo(path.supportsIPv4))")
            lines.append("IPv6: \(yesNo(path.supportsIPv6))")
            lines.append("DNS configured: \(yesNo(path.supportsDNS))")
            lines.append("Expensive: \(yesNo(path.isExpensive))")
            lines.append("Constrained: \(yesNo(path.isConstrained))")
            lines.append(
                "Ultra constrained: \(yesNo(path.isUltraConstrained))"
            )
            lines.append("Link quality: \(path.linkQuality.title)")
        } else {
            lines.append("Unavailable")
        }

        lines.append("")
        lines.append("INTERFACES")
        if let error = snapshot.interfacesError {
            lines.append("Error: \(error)")
        }
        if snapshot.interfaces.isEmpty, snapshot.interfacesError == nil {
            lines.append("(empty)")
        }

        for interface in snapshot.interfaces {
            lines.append("")
            lines.append(
                "\(interface.name) (index \(interface.index), "
                    + "\(interface.kind.title))"
            )
            lines.append("Flags: \(list(interface.flags))")
            lines.append(
                "MTU: \(interface.mtu.map(String.init) ?? "unknown")"
            )
            lines.append(
                "Link address: \(interface.linkLayerAddress ?? "unavailable")"
            )

            for address in interface.addresses {
                lines.append(
                    "\(address.family.rawValue): "
                        + "\(address.cidrDescription) "
                        + "(\(address.classification))"
                )
                if
                    let label = address.relatedAddressLabel,
                    let relatedAddress = address.relatedAddress
                {
                    lines.append("  \(label): \(relatedAddress)")
                }
            }

            if let statistics = interface.statistics {
                lines.append(
                    "RX: \(statistics.receivedBytes) bytes, "
                        + "\(statistics.receivedPackets) packets, "
                        + "\(statistics.inputErrors) errors"
                )
                lines.append(
                    "TX: \(statistics.sentBytes) bytes, "
                        + "\(statistics.sentPackets) packets, "
                        + "\(statistics.outputErrors) errors"
                )
            }
        }

        lines.append("")
        lines.append("NEIGHBORS")
        appendNeighbors(
            snapshot.neighbors.ipv4,
            family: .ipv4,
            error: snapshot.neighbors.ipv4Error,
            to: &lines
        )
        appendNeighbors(
            snapshot.neighbors.ipv6,
            family: .ipv6,
            error: snapshot.neighbors.ipv6Error,
            to: &lines
        )

        return lines.joined(separator: "\n")
    }

    private static func appendNeighbors(
        _ entries: [NeighborEntry],
        family: NeighborAddressFamily,
        error: String?,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append(family.rawValue)

        if let error {
            lines.append("Error: \(error)")
            return
        }
        if entries.isEmpty {
            lines.append("(cache empty)")
            return
        }

        for entry in entries {
            var details = [
                entry.address,
                entry.linkLayerAddress ?? "(incomplete)",
                "dev \(entry.interfaceName)"
            ]
            if !entry.flags.isEmpty {
                details.append("[\(entry.flags.joined(separator: ","))]")
            }
            if entry.isPermanent {
                details.append("permanent")
            } else if let expiration = entry.expiration {
                details.append(
                    "expires "
                        + ISO8601DateFormatter().string(from: expiration)
                )
            }
            lines.append(details.joined(separator: " "))
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "(none)" : values.joined(separator: ", ")
    }
}
