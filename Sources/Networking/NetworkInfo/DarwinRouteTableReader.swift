import Darwin
import Foundation
import NetToolCore

struct DarwinRouteTableReader: Sendable {
    func read() -> NetworkRouteTableSnapshot {
        let ipv4 = readFamily(
            systemFamily: AF_INET,
            family: .ipv4
        )
        let ipv6 = readFamily(
            systemFamily: AF_INET6,
            family: .ipv6
        )

        return NetworkRouteTableSnapshot(
            ipv4: ipv4.entries,
            ipv6: ipv6.entries,
            ipv4Error: ipv4.error,
            ipv6Error: ipv6.error
        )
    }

    private func readFamily(
        systemFamily: Int32,
        family: RouteAddressFamily
    ) -> FamilyResult {
        do {
            let data = try routeData(family: systemFamily)
            return FamilyResult(
                entries: try parse(
                    data,
                    expectedSystemFamily: systemFamily,
                    family: family
                ),
                error: nil
            )
        } catch {
            return FamilyResult(
                entries: [],
                error: error.localizedDescription
            )
        }
    }

    private func routeData(
        family: Int32
    ) throws -> Data {
        var mib: [Int32] = [
            4, // CTL_NET
            PF_ROUTE,
            0,
            family,
            RouteLayout.netRTDump2,
            0
        ]

        for _ in 0 ..< 3 {
            var requiredLength = 0
            let estimateResult = mib.withUnsafeMutableBufferPointer {
                sysctl(
                    $0.baseAddress,
                    u_int($0.count),
                    nil,
                    &requiredLength,
                    nil,
                    0
                )
            }
            guard estimateResult == 0 else {
                throw NetworkInformationSystemError(
                    operation: "sysctl(PF_ROUTE) estimate",
                    code: errno
                )
            }

            guard requiredLength > 0 else {
                return Data()
            }

            requiredLength += requiredLength / 2
            var bytes = [UInt8](
                repeating: 0,
                count: requiredLength
            )
            let readResult = bytes.withUnsafeMutableBytes { buffer in
                mib.withUnsafeMutableBufferPointer {
                    sysctl(
                        $0.baseAddress,
                        u_int($0.count),
                        buffer.baseAddress,
                        &requiredLength,
                        nil,
                        0
                    )
                }
            }

            if readResult == 0 {
                return Data(bytes.prefix(requiredLength))
            }
            if errno != ENOMEM {
                throw NetworkInformationSystemError(
                    operation: "sysctl(PF_ROUTE, NET_RT_DUMP2)",
                    code: errno
                )
            }
        }

        throw NetworkInformationSystemError(
            operation: "sysctl(PF_ROUTE, NET_RT_DUMP2)",
            code: ENOMEM
        )
    }

    private func parse(
        _ data: Data,
        expectedSystemFamily: Int32,
        family: RouteAddressFamily
    ) throws -> [NetworkRouteEntry] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return []
        }

        var offset = 0
        var entries: [NetworkRouteEntry] = []

        while offset < bytes.count {
            guard offset + RouteLayout.headerLength <= bytes.count else {
                throw RouteTableParseError(
                    description: "路由消息头被截断（offset \(offset)）"
                )
            }

            let messageLength = Int(readUInt16(bytes, at: offset))
            guard
                messageLength >= RouteLayout.headerLength,
                offset + messageLength <= bytes.count
            else {
                throw RouteTableParseError(
                    description: "无效路由消息长度 \(messageLength)"
                )
            }
            guard bytes[offset + 2] == RouteLayout.version else {
                throw RouteTableParseError(
                    description: "不支持的路由消息版本 "
                        + "\(bytes[offset + 2])"
                )
            }

            if let entry = parseMessage(
                bytes,
                offset: offset,
                length: messageLength,
                expectedSystemFamily: expectedSystemFamily,
                family: family
            ) {
                entries.append(entry)
            }
            offset += messageLength
        }

        return entries.sorted(by: routeSort)
    }

    private func parseMessage(
        _ bytes: [UInt8],
        offset: Int,
        length: Int,
        expectedSystemFamily: Int32,
        family: RouteAddressFamily
    ) -> NetworkRouteEntry? {
        let headerInterfaceIndex = UInt32(
            readUInt16(bytes, at: offset + 4)
        )
        let flags = readInt32(bytes, at: offset + 8)
        let addressMask = readInt32(bytes, at: offset + 12)
        var socketOffset = offset + RouteLayout.headerLength
        let limit = offset + length
        var socketAddresses: [Int: SocketAddress] = [:]

        for index in 0 ..< RouteLayout.addressCount {
            guard addressMask & (1 << index) != 0 else {
                continue
            }
            guard socketOffset + 2 <= limit else {
                return nil
            }

            let socketLength = Int(bytes[socketOffset])
            let storageLength = socketLength > 0 ? socketLength : 4
            let roundedLength = roundedSocketLength(socketLength)
            guard
                socketOffset + storageLength <= limit,
                socketOffset + roundedLength <= limit
            else {
                return nil
            }

            socketAddresses[index] = SocketAddress(
                offset: socketOffset,
                length: socketLength,
                family: Int32(bytes[socketOffset + 1])
            )
            socketOffset += roundedLength
        }

        guard
            let destinationSocket =
                socketAddresses[RouteAddressIndex.destination],
            destinationSocket.family == expectedSystemFamily,
            let destination = numericAddress(
                bytes,
                socketAddress: destinationSocket
            )
        else {
            return nil
        }

        let gatewaySocket =
            socketAddresses[RouteAddressIndex.gateway]
        let linkIndex = gatewaySocket.flatMap {
            $0.family == AF_LINK
                ? linkInterfaceIndex(bytes, socketAddress: $0)
                : nil
        }
        let resolvedInterfaceIndex = linkIndex.flatMap {
            $0 == 0 ? nil : $0
        } ?? headerInterfaceIndex
        let interfaceName = interfaceName(
            index: resolvedInterfaceIndex
        )

        let gateway: String? = gatewaySocket.flatMap {
            socketAddress -> String? in
            guard
                socketAddress.family == AF_INET
                    || socketAddress.family == AF_INET6
            else {
                return nil
            }
            guard let address = numericAddress(
                bytes,
                socketAddress: socketAddress
            ) else {
                return nil
            }
            return scopedAddress(
                address,
                systemFamily: socketAddress.family,
                interfaceName: interfaceName
            )
        }

        let prefixLength = prefixLength(
            bytes,
            netmask: socketAddresses[RouteAddressIndex.netmask],
            systemFamily: expectedSystemFamily,
            destination: destination,
            isHost: flags & RouteFlag.host != 0
        )
        let mtuValue = readUInt32(
            bytes,
            at: offset + RouteLayout.mtuOffset
        )

        let entry = NetworkRouteEntry(
            family: family,
            destination: scopedAddress(
                destination,
                systemFamily: expectedSystemFamily,
                interfaceName: interfaceName
            ),
            prefixLength: prefixLength,
            gateway: gateway,
            interfaceName: interfaceName,
            flags: flagNames(flags),
            mtu: mtuValue == 0 ? nil : mtuValue
        )
        return entry.isRoutingCacheEntry ? nil : entry
    }

    private func numericAddress(
        _ bytes: [UInt8],
        socketAddress: SocketAddress
    ) -> String? {
        guard
            socketAddress.length > 0,
            socketAddress.length
                <= MemoryLayout<sockaddr_storage>.size,
            socketAddress.offset + socketAddress.length <= bytes.count
        else {
            return nil
        }

        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(
                    from: source[
                        socketAddress.offset
                            ..< socketAddress.offset
                            + socketAddress.length
                    ]
                )
            }
        }

        var host = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                pointer in
                host.withUnsafeMutableBufferPointer { buffer in
                    getnameinfo(
                        pointer,
                        socklen_t(socketAddress.length),
                        buffer.baseAddress,
                        socklen_t(buffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
        }
        guard result == 0 else {
            return nil
        }
        return decodedCString(host)
    }

    private func prefixLength(
        _ bytes: [UInt8],
        netmask: SocketAddress?,
        systemFamily: Int32,
        destination: String,
        isHost: Bool
    ) -> Int? {
        let byteOffset: Int
        let byteCount: Int
        switch systemFamily {
        case AF_INET:
            byteOffset = 4
            byteCount = 4
        case AF_INET6:
            byteOffset = 8
            byteCount = 16
        default:
            return nil
        }

        if isHost {
            return byteCount * 8
        }
        guard let netmask else {
            return isUnspecified(
                destination,
                systemFamily: systemFamily
            ) ? 0 : nil
        }
        guard netmask.length > 0 else {
            return 0
        }

        var maskBytes = [UInt8](
            repeating: 0,
            count: byteCount
        )
        let sourceStart = netmask.offset + byteOffset
        let socketEnd = netmask.offset + netmask.length
        if sourceStart < socketEnd {
            let copyCount = min(
                byteCount,
                socketEnd - sourceStart
            )
            guard sourceStart + copyCount <= bytes.count else {
                return nil
            }
            maskBytes.replaceSubrange(
                0 ..< copyCount,
                with: bytes[sourceStart ..< sourceStart + copyCount]
            )
        }

        var prefix = 0
        var sawZero = false
        for byte in maskBytes {
            for bit in 0 ..< 8 {
                let bitMask = UInt8(0x80 >> bit)
                let isSet = byte & bitMask != 0
                if isSet {
                    guard !sawZero else {
                        return nil
                    }
                    prefix += 1
                } else {
                    sawZero = true
                }
            }
        }
        return prefix
    }

    private func linkInterfaceIndex(
        _ bytes: [UInt8],
        socketAddress: SocketAddress
    ) -> UInt32? {
        guard
            socketAddress.length >= 4,
            socketAddress.offset + 4 <= bytes.count
        else {
            return nil
        }
        return UInt32(
            readUInt16(
                bytes,
                at: socketAddress.offset + 2
            )
        )
    }

    private func interfaceName(index: UInt32) -> String {
        guard index != 0 else {
            return "未知"
        }

        var buffer = [CChar](
            repeating: 0,
            count: Int(IFNAMSIZ)
        )
        let result = buffer.withUnsafeMutableBufferPointer {
            if_indextoname(index, $0.baseAddress)
        }
        guard result != nil else {
            return "if\(index)"
        }
        return decodedCString(buffer)
    }

    private func scopedAddress(
        _ address: String,
        systemFamily: Int32,
        interfaceName: String
    ) -> String {
        guard
            systemFamily == AF_INET6,
            address.lowercased().hasPrefix("fe80:"),
            !address.contains("%"),
            interfaceName != "未知"
        else {
            return address
        }
        return "\(address)%\(interfaceName)"
    }

    private func isUnspecified(
        _ address: String,
        systemFamily: Int32
    ) -> Bool {
        if systemFamily == AF_INET {
            return address == "0.0.0.0"
        }
        return address == "::"
    }

    private func flagNames(_ flags: Int32) -> [String] {
        [
            (RouteFlag.up, "UP"),
            (RouteFlag.gateway, "GATEWAY"),
            (RouteFlag.host, "HOST"),
            (RouteFlag.reject, "REJECT"),
            (RouteFlag.dynamic, "DYNAMIC"),
            (RouteFlag.modified, "MODIFIED"),
            (RouteFlag.cloning, "CLONING"),
            (RouteFlag.linkLayerInfo, "LLINFO"),
            (RouteFlag.staticRoute, "STATIC"),
            (RouteFlag.blackhole, "BLACKHOLE"),
            (RouteFlag.wasCloned, "WASCLONED"),
            (RouteFlag.protocolCloning, "PRCLONING"),
            (RouteFlag.local, "LOCAL"),
            (RouteFlag.broadcast, "BROADCAST"),
            (RouteFlag.multicast, "MULTICAST"),
            (RouteFlag.interfaceScoped, "SCOPED"),
            (RouteFlag.interfaceReference, "IFREF"),
            (RouteFlag.proxy, "PROXY"),
            (RouteFlag.router, "ROUTER"),
            (RouteFlag.global, "GLOBAL")
        ]
        .compactMap { mask, name in
            flags & mask != 0 ? name : nil
        }
    }

    private func routeSort(
        _ lhs: NetworkRouteEntry,
        _ rhs: NetworkRouteEntry
    ) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault
        }
        if lhs.destination != rhs.destination {
            return lhs.destination.localizedStandardCompare(
                rhs.destination
            ) == .orderedAscending
        }
        if lhs.prefixLength != rhs.prefixLength {
            return (lhs.prefixLength ?? -1) < (rhs.prefixLength ?? -1)
        }
        return lhs.interfaceName.localizedStandardCompare(
            rhs.interfaceName
        ) == .orderedAscending
    }

    private func roundedSocketLength(_ length: Int) -> Int {
        guard length > 0 else {
            return 4
        }
        return (length + 3) & ~3
    }

    private func decodedCString(_ buffer: [CChar]) -> String {
        let bytes = buffer
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readUInt16(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset])
            | UInt16(bytes[offset + 1]) << 8
    }

    private func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func readInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> Int32 {
        Int32(bitPattern: readUInt32(bytes, at: offset))
    }
}

private struct FamilyResult {
    let entries: [NetworkRouteEntry]
    let error: String?
}

private struct SocketAddress {
    let offset: Int
    let length: Int
    let family: Int32
}

private struct RouteTableParseError: LocalizedError {
    let description: String

    var errorDescription: String? {
        "解析路由表失败：\(description)"
    }
}

private enum RouteLayout {
    static let netRTDump2: Int32 = 7
    static let version: UInt8 = 5
    static let headerLength = 92
    static let mtuOffset = 40
    static let addressCount = 8
}

private enum RouteAddressIndex {
    static let destination = 0
    static let gateway = 1
    static let netmask = 2
}

private enum RouteFlag {
    static let up: Int32 = 0x1
    static let gateway: Int32 = 0x2
    static let host: Int32 = 0x4
    static let reject: Int32 = 0x8
    static let dynamic: Int32 = 0x10
    static let modified: Int32 = 0x20
    static let cloning: Int32 = 0x100
    static let linkLayerInfo: Int32 = 0x400
    static let staticRoute: Int32 = 0x800
    static let blackhole: Int32 = 0x1000
    static let protocolCloning: Int32 = 0x10000
    static let wasCloned: Int32 = 0x20000
    static let local: Int32 = 0x200000
    static let broadcast: Int32 = 0x400000
    static let multicast: Int32 = 0x800000
    static let interfaceScoped: Int32 = 0x1000000
    static let interfaceReference: Int32 = 0x4000000
    static let proxy: Int32 = 0x8000000
    static let router: Int32 = 0x10000000
    static let global: Int32 = 0x40000000
}
