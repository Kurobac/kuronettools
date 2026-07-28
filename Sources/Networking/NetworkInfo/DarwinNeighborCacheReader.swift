import Darwin
import Foundation
import NetToolCore

struct DarwinNeighborCacheReader: Sendable {
    func read() -> NeighborCacheSnapshot {
        let ipv4 = readFamily(
            systemFamily: AF_INET,
            family: .ipv4
        )
        let ipv6 = readFamily(
            systemFamily: AF_INET6,
            family: .ipv6
        )

        return NeighborCacheSnapshot(
            ipv4: ipv4.entries,
            ipv6: ipv6.entries,
            ipv4Error: ipv4.error,
            ipv6Error: ipv6.error
        )
    }

    private func readFamily(
        systemFamily: Int32,
        family: NeighborAddressFamily
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
            2, // NET_RT_FLAGS
            0x400 // RTF_LLINFO
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
                    operation: "sysctl(PF_ROUTE, NET_RT_FLAGS)",
                    code: errno
                )
            }
        }

        throw NetworkInformationSystemError(
            operation: "sysctl(PF_ROUTE, NET_RT_FLAGS)",
            code: ENOMEM
        )
    }

    private func parse(
        _ data: Data,
        expectedSystemFamily: Int32,
        family: NeighborAddressFamily
    ) throws -> [NeighborEntry] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return []
        }

        var offset = 0
        var entries: [NeighborEntry] = []

        while offset < bytes.count {
            guard offset + RouteLayout.headerLength <= bytes.count else {
                throw NeighborCacheParseError(
                    description: "路由消息头被截断（offset \(offset)）"
                )
            }

            let messageLength = Int(
                readUInt16(bytes, at: offset)
            )
            guard
                messageLength >= RouteLayout.headerLength,
                offset + messageLength <= bytes.count
            else {
                throw NeighborCacheParseError(
                    description: "无效路由消息长度 \(messageLength)"
                )
            }
            guard bytes[offset + 2] == 5 else {
                throw NeighborCacheParseError(
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

        var unique: [String: NeighborEntry] = [:]
        for entry in entries {
            unique[entry.id] = entry
        }
        return unique.values.sorted {
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName < $1.interfaceName
            }
            return $0.address.localizedStandardCompare($1.address)
                == .orderedAscending
        }
    }

    private func parseMessage(
        _ bytes: [UInt8],
        offset: Int,
        length: Int,
        expectedSystemFamily: Int32,
        family: NeighborAddressFamily
    ) -> NeighborEntry? {
        let interfaceIndex = UInt32(
            readUInt16(bytes, at: offset + 4)
        )
        let flags = readInt32(bytes, at: offset + 8)
        guard flags & RouteFlag.linkLayerInfo != 0 else {
            return nil
        }
        guard flags & RouteFlag.local == 0,
              flags & RouteFlag.broadcast == 0,
              flags & RouteFlag.multicast == 0
        else {
            return nil
        }

        let addressMask = readInt32(bytes, at: offset + 12)
        var socketOffset = offset + RouteLayout.headerLength
        let limit = offset + length
        var destination: SocketAddress?
        var gateway: SocketAddress?

        for index in 0 ..< 8 {
            guard addressMask & (1 << index) != 0 else {
                continue
            }
            guard socketOffset + 2 <= limit else {
                return nil
            }

            let socketLength = Int(bytes[socketOffset])
            let storageLength = socketLength > 0 ? socketLength : 4
            guard socketOffset + storageLength <= limit else {
                return nil
            }

            let socketAddress = SocketAddress(
                offset: socketOffset,
                length: socketLength,
                family: Int32(bytes[socketOffset + 1])
            )
            if index == 0 {
                destination = socketAddress
            } else if index == 1 {
                gateway = socketAddress
            }

            socketOffset += roundedSocketLength(socketLength)
        }

        guard
            let destination,
            destination.family == expectedSystemFamily,
            let address = numericAddress(
                bytes,
                socketAddress: destination
            ),
            let gateway,
            gateway.family == AF_LINK
        else {
            return nil
        }

        let gatewayInterfaceIndex = interfaceIndex(
            bytes,
            socketAddress: gateway
        )
        let resolvedInterfaceIndex =
            gatewayInterfaceIndex == 0
                ? interfaceIndex
                : gatewayInterfaceIndex
        let interfaceName = interfaceName(
            index: resolvedInterfaceIndex
        )

        let expirationValue = readInt32(
            bytes,
            at: offset + RouteLayout.expirationOffset
        )
        let isPermanent = expirationValue == 0
        let expiration = expirationValue > 0
            ? Date(timeIntervalSince1970: TimeInterval(expirationValue))
            : nil

        return NeighborEntry(
            family: family,
            address: scopedAddress(
                address,
                family: family,
                interfaceName: interfaceName
            ),
            interfaceName: interfaceName,
            flags: flagNames(flags),
            expiration: expiration,
            isPermanent: isPermanent
        )
    }

    private func numericAddress(
        _ bytes: [UInt8],
        socketAddress: SocketAddress
    ) -> String? {
        guard socketAddress.length > 0,
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

    private func interfaceIndex(
        _ bytes: [UInt8],
        socketAddress: SocketAddress
    ) -> UInt32 {
        guard
            socketAddress.length >= 4,
            socketAddress.offset + 4 <= bytes.count
        else {
            return 0
        }

        return UInt32(
            readUInt16(
                bytes,
                at: socketAddress.offset + 2
            )
        )
    }

    private func interfaceName(index: UInt32) -> String {
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
        family: NeighborAddressFamily,
        interfaceName: String
    ) -> String {
        guard
            family == .ipv6,
            address.lowercased().hasPrefix("fe80:"),
            !address.contains("%")
        else {
            return address
        }
        return "\(address)%\(interfaceName)"
    }

    private func flagNames(_ flags: Int32) -> [String] {
        [
            (RouteFlag.host, "HOST"),
            (RouteFlag.staticRoute, "STATIC"),
            (RouteFlag.router, "ROUTER"),
            (RouteFlag.proxy, "PROXY"),
            (RouteFlag.interfaceScoped, "SCOPED"),
            (RouteFlag.reject, "REJECT")
        ]
        .compactMap { mask, name in
            flags & mask != 0 ? name : nil
        }
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

    private func readInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> Int32 {
        let value =
            UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Int32(bitPattern: value)
    }
}

private struct FamilyResult {
    let entries: [NeighborEntry]
    let error: String?
}

private struct SocketAddress {
    let offset: Int
    let length: Int
    let family: Int32
}

private struct NeighborCacheParseError: LocalizedError {
    let description: String

    var errorDescription: String? {
        "解析 Neighbor 缓存失败：\(description)"
    }
}

private enum RouteLayout {
    static let headerLength = 92
    static let expirationOffset = 48
}

private enum RouteFlag {
    static let host: Int32 = 0x4
    static let reject: Int32 = 0x8
    static let linkLayerInfo: Int32 = 0x400
    static let staticRoute: Int32 = 0x800
    static let local: Int32 = 0x200000
    static let broadcast: Int32 = 0x400000
    static let multicast: Int32 = 0x800000
    static let interfaceScoped: Int32 = 0x1000000
    static let proxy: Int32 = 0x8000000
    static let router: Int32 = 0x10000000
}
