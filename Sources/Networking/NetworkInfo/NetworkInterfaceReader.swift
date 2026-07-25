import Darwin
import Foundation
import NetToolCore

struct NetworkInterfaceReader: Sendable {
    func read() throws -> [NetworkInterfaceSnapshot] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0 else {
            throw NetworkInformationSystemError(
                operation: "getifaddrs",
                code: errno
            )
        }
        defer {
            freeifaddrs(firstAddress)
        }

        var builders: [String: InterfaceBuilder] = [:]
        var current = firstAddress

        while let addressPointer = current {
            let record = addressPointer.pointee
            current = record.ifa_next

            guard let namePointer = record.ifa_name else {
                continue
            }
            let name = String(cString: namePointer)
            var builder = builders[name] ?? InterfaceBuilder(
                name: name,
                index: name.withCString(if_nametoindex),
                flagsValue: UInt32(record.ifa_flags)
            )

            guard let socketAddress = record.ifa_addr else {
                builders[name] = builder
                continue
            }

            let family = Int32(socketAddress.pointee.sa_family)
            switch family {
            case AF_LINK:
                builder.linkLayerAddress = linkLayerAddress(
                    socketAddress
                )
                if let dataPointer = record.ifa_data {
                    let data = dataPointer
                        .assumingMemoryBound(to: if_data.self)
                        .pointee
                    builder.mtu = Int(data.ifi_mtu)
                    builder.statistics = NetworkInterfaceStatistics(
                        receivedBytes: UInt64(data.ifi_ibytes),
                        sentBytes: UInt64(data.ifi_obytes),
                        receivedPackets: UInt64(data.ifi_ipackets),
                        sentPackets: UInt64(data.ifi_opackets),
                        inputErrors: UInt64(data.ifi_ierrors),
                        outputErrors: UInt64(data.ifi_oerrors)
                    )
                }
            case AF_INET, AF_INET6:
                if let address = interfaceAddress(
                    record,
                    family: family
                ) {
                    builder.addresses.append(address)
                }
            default:
                break
            }

            builders[name] = builder
        }

        return builders.values
            .map(\.snapshot)
            .sorted(by: interfaceSort)
    }

    private func interfaceAddress(
        _ record: ifaddrs,
        family: Int32
    ) -> NetworkInterfaceAddress? {
        guard
            let socketAddress = record.ifa_addr,
            let address = numericAddress(socketAddress)
        else {
            return nil
        }

        let isPointToPoint =
            UInt32(record.ifa_flags) & UInt32(IFF_POINTOPOINT) != 0
        let hasRelatedAddress =
            isPointToPoint
            || UInt32(record.ifa_flags) & UInt32(IFF_BROADCAST) != 0
        let relatedAddress = hasRelatedAddress
            ? numericAddress(record.ifa_dstaddr)
            : nil

        return NetworkInterfaceAddress(
            family: family == AF_INET ? .ipv4 : .ipv6,
            address: address,
            prefixLength: prefixLength(
                netmask: record.ifa_netmask,
                family: family
            ),
            classification: classification(
                address: address,
                family: family
            ),
            relatedAddressLabel: relatedAddress == nil
                ? nil
                : (isPointToPoint ? "对端" : "广播"),
            relatedAddress: relatedAddress
        )
    }

    private func numericAddress(
        _ address: UnsafePointer<sockaddr>
    ) -> String? {
        var host = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )
        let result = host.withUnsafeMutableBufferPointer { buffer in
            getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                buffer.baseAddress,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard result == 0 else {
            return nil
        }
        return decodedCString(host)
    }

    private func prefixLength(
        netmask: UnsafePointer<sockaddr>?,
        family: Int32
    ) -> Int? {
        guard let netmask else {
            return nil
        }

        let offset: Int
        let count: Int
        switch family {
        case AF_INET:
            offset = 4
            count = 4
        case AF_INET6:
            offset = 8
            count = 16
        default:
            return nil
        }

        guard Int(netmask.pointee.sa_len) >= offset + count else {
            return nil
        }

        let bytes = UnsafeRawPointer(netmask)
            .assumingMemoryBound(to: UInt8.self)
        return (offset ..< offset + count)
            .reduce(0) { $0 + bytes[$1].nonzeroBitCount }
    }

    private func linkLayerAddress(
        _ address: UnsafePointer<sockaddr>
    ) -> String? {
        let bytes = UnsafeRawPointer(address)
            .assumingMemoryBound(to: UInt8.self)
        let length = Int(bytes[0])
        guard length >= 8 else {
            return nil
        }

        let nameLength = Int(bytes[5])
        let addressLength = Int(bytes[6])
        let start = 8 + nameLength
        guard addressLength > 0, start + addressLength <= length else {
            return nil
        }

        return (start ..< start + addressLength)
            .map { String(format: "%02X", bytes[$0]) }
            .joined(separator: ":")
    }

    private func classification(
        address: String,
        family: Int32
    ) -> String {
        if family == AF_INET {
            if address.hasPrefix("127.") {
                return "回环"
            }
            if address.hasPrefix("169.254.") {
                return "链路本地"
            }
            if address.hasPrefix("10.")
                || address.hasPrefix("192.168.")
                || isPrivate172(address)
            {
                return "私有地址"
            }
            return "单播"
        }

        let unscoped = address
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased()
            ?? address.lowercased()

        if unscoped == "::1" {
            return "回环"
        }
        if unscoped.hasPrefix("fe8")
            || unscoped.hasPrefix("fe9")
            || unscoped.hasPrefix("fea")
            || unscoped.hasPrefix("feb")
        {
            return "链路本地"
        }
        if unscoped.hasPrefix("fc") || unscoped.hasPrefix("fd") {
            return "唯一本地地址"
        }
        if unscoped.hasPrefix("ff") {
            return "多播"
        }
        return "全局单播"
    }

    private func isPrivate172(_ address: String) -> Bool {
        let components = address.split(separator: ".")
        guard
            components.count == 4,
            components[0] == "172",
            let second = Int(components[1])
        else {
            return false
        }
        return (16 ... 31).contains(second)
    }

    private func decodedCString(_ buffer: [CChar]) -> String {
        let bytes = buffer
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func interfaceSort(
        _ lhs: NetworkInterfaceSnapshot,
        _ rhs: NetworkInterfaceSnapshot
    ) -> Bool {
        let left = sortRank(lhs)
        let right = sortRank(rhs)
        if left != right {
            return left < right
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func sortRank(
        _ interface: NetworkInterfaceSnapshot
    ) -> Int {
        let isUp = interface.flags.contains("UP")
        if isUp, !interface.addresses.isEmpty, interface.kind != .loopback {
            return 0
        }
        if isUp, interface.kind != .loopback {
            return 1
        }
        if interface.kind == .loopback {
            return 2
        }
        return 3
    }
}

private struct InterfaceBuilder {
    let name: String
    let index: UInt32
    let flagsValue: UInt32
    var mtu: Int?
    var linkLayerAddress: String?
    var addresses: [NetworkInterfaceAddress] = []
    var statistics: NetworkInterfaceStatistics?

    var snapshot: NetworkInterfaceSnapshot {
        NetworkInterfaceSnapshot(
            name: name,
            index: index,
            kind: interfaceKind,
            flags: flagNames,
            mtu: mtu,
            linkLayerAddress: linkLayerAddress,
            addresses: addresses.sorted {
                if $0.family != $1.family {
                    return $0.family == .ipv4
                }
                return $0.address < $1.address
            },
            statistics: statistics
        )
    }

    private var interfaceKind: NetworkInterfaceKind {
        if flagsValue & UInt32(IFF_LOOPBACK) != 0 || name == "lo0" {
            return .loopback
        }
        if name.hasPrefix("utun")
            || name.hasPrefix("ipsec")
            || name.hasPrefix("ppp")
        {
            return .tunnel
        }
        if name == "en0" || name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return .wifi
        }
        if name.hasPrefix("pdp_ip") {
            return .cellular
        }
        if name.hasPrefix("en") {
            return .wiredEthernet
        }
        return .other
    }

    private var flagNames: [String] {
        [
            (UInt32(IFF_UP), "UP"),
            (UInt32(IFF_RUNNING), "RUNNING"),
            (UInt32(IFF_LOOPBACK), "LOOPBACK"),
            (UInt32(IFF_POINTOPOINT), "POINTOPOINT"),
            (UInt32(IFF_BROADCAST), "BROADCAST"),
            (UInt32(IFF_MULTICAST), "MULTICAST"),
            (UInt32(IFF_NOARP), "NOARP"),
            (UInt32(IFF_PROMISC), "PROMISC")
        ]
        .compactMap { mask, name in
            flagsValue & mask != 0 ? name : nil
        }
    }
}

struct NetworkInformationSystemError: LocalizedError, Sendable {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        let message = String(cString: strerror(code))
        return "\(operation): \(message) (errno \(code))"
    }
}
