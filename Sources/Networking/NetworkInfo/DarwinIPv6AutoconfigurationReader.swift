import Darwin
import Foundation
import NetToolCore

struct DarwinIPv6AutoconfigurationReader: Sendable {
    func read(
        interfaceNames: [String]
    ) -> IPv6AutoconfigurationSnapshot {
        let routers = readDefaultRouters()
        let prefixes = readPrefixes()
        let interfaces = readInterfaces(
            names: interfaceNames
        )

        return IPv6AutoconfigurationSnapshot(
            defaultRouters: routers.entries,
            prefixes: prefixes.entries,
            interfaces: interfaces.entries,
            defaultRoutersError: routers.error,
            prefixesError: prefixes.error,
            interfacesError: interfaces.error,
            interfaceErrors: interfaces.interfaceErrors
        )
    }

    private func readDefaultRouters() -> RouterResult {
        do {
            let data = try sysctlData(
                node: ND6Layout.defaultRouterListNode,
                operation: "sysctl(ICMPV6CTL_ND6_DRLIST)"
            )
            return RouterResult(
                entries: try parseDefaultRouters(data),
                error: nil
            )
        } catch {
            return RouterResult(
                entries: [],
                error: error.localizedDescription
            )
        }
    }

    private func readPrefixes() -> PrefixResult {
        do {
            let data = try sysctlData(
                node: ND6Layout.prefixListNode,
                operation: "sysctl(ICMPV6CTL_ND6_PRLIST)"
            )
            return PrefixResult(
                entries: try parsePrefixes(data),
                error: nil
            )
        } catch {
            return PrefixResult(
                entries: [],
                error: error.localizedDescription
            )
        }
    }

    private func sysctlData(
        node: Int32,
        operation: String
    ) throws -> Data {
        var mib: [Int32] = [
            4, // CTL_NET
            PF_INET6,
            IPPROTO_ICMPV6,
            node
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
                    operation: "\(operation) estimate",
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
                    operation: operation,
                    code: errno
                )
            }
        }

        throw NetworkInformationSystemError(
            operation: operation,
            code: ENOMEM
        )
    }

    private func parseDefaultRouters(
        _ data: Data
    ) throws -> [IPv6DefaultRouterEntry] {
        let bytes = [UInt8](data)
        guard
            bytes.count.isMultiple(
                of: ND6Layout.defaultRouterLength
            )
        else {
            throw IPv6AutoconfigurationParseError(
                description: "默认路由器列表长度 \(bytes.count) "
                    + "不是 \(ND6Layout.defaultRouterLength) 的整数倍"
            )
        }

        var entries: [IPv6DefaultRouterEntry] = []
        for offset in stride(
            from: 0,
            to: bytes.count,
            by: ND6Layout.defaultRouterLength
        ) {
            let interfaceIndex = UInt32(
                readUInt16(
                    bytes,
                    at: offset + ND6Layout.routerInterfaceIndexOffset
                )
            )
            let interfaceName = interfaceName(
                index: interfaceIndex
            )
            let address = try ipv6Address(
                bytes,
                at: offset,
                interfaceName: interfaceName,
                context: "默认路由器"
            )
            let raFlags =
                bytes[offset + ND6Layout.routerRAFlagsOffset]
            let stateFlags =
                bytes[offset + ND6Layout.routerStateFlagsOffset]
            let expirationValue = readUInt64(
                bytes,
                at: offset + ND6Layout.routerExpirationOffset
            )

            entries.append(
                IPv6DefaultRouterEntry(
                    address: address,
                    interfaceName: interfaceName,
                    managedConfiguration:
                        raFlags & ND6RouterFlag.managed != 0,
                    otherConfiguration:
                        raFlags & ND6RouterFlag.other != 0,
                    homeAgent:
                        raFlags & ND6RouterFlag.homeAgent != 0,
                    preference: routerPreference(raFlags),
                    advertisedLifetimeSeconds: readUInt16(
                        bytes,
                        at: offset
                            + ND6Layout.routerLifetimeOffset
                    ),
                    expiration: dateOrNever(expirationValue),
                    stateFlags: routerStateFlagNames(stateFlags)
                )
            )
        }

        return entries.sorted {
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName.localizedStandardCompare(
                    $1.interfaceName
                ) == .orderedAscending
            }
            return $0.address.localizedStandardCompare($1.address)
                == .orderedAscending
        }
    }

    private func parsePrefixes(
        _ data: Data
    ) throws -> [IPv6PrefixEntry] {
        let bytes = [UInt8](data)
        var offset = 0
        var entries: [IPv6PrefixEntry] = []

        while offset < bytes.count {
            guard
                offset + ND6Layout.prefixHeaderLength <= bytes.count
            else {
                throw IPv6AutoconfigurationParseError(
                    description: "IPv6 前缀头被截断（offset \(offset)）"
                )
            }

            let prefixLength =
                bytes[offset + ND6Layout.prefixLengthOffset]
            guard prefixLength <= 128 else {
                throw IPv6AutoconfigurationParseError(
                    description: "无效 IPv6 前缀长度 \(prefixLength)"
                )
            }

            let advertisingRouterCount = Int(
                readUInt16(
                    bytes,
                    at: offset
                        + ND6Layout.prefixRouterCountOffset
                )
            )
            let routerBytes = advertisingRouterCount
                * ND6Layout.socketAddressIPv6Length
            let entryLength =
                ND6Layout.prefixHeaderLength + routerBytes
            guard offset + entryLength <= bytes.count else {
                throw IPv6AutoconfigurationParseError(
                    description: "IPv6 前缀的广告路由器列表被截断"
                )
            }

            let interfaceIndex = UInt32(
                readUInt16(
                    bytes,
                    at: offset
                        + ND6Layout.prefixInterfaceIndexOffset
                )
            )
            let interfaceName = interfaceName(
                index: interfaceIndex
            )
            let address = try ipv6Address(
                bytes,
                at: offset,
                interfaceName: interfaceName,
                context: "IPv6 前缀"
            )
            let raFlags =
                bytes[offset + ND6Layout.prefixRAFlagsOffset]
            var advertisingRouters: [String] = []
            for index in 0 ..< advertisingRouterCount {
                let routerOffset =
                    offset
                    + ND6Layout.prefixHeaderLength
                    + index * ND6Layout.socketAddressIPv6Length
                advertisingRouters.append(
                    try ipv6Address(
                        bytes,
                        at: routerOffset,
                        interfaceName: interfaceName,
                        context: "前缀广告路由器"
                    )
                )
            }

            let expirationValue = readUInt64(
                bytes,
                at: offset + ND6Layout.prefixExpirationOffset
            )
            entries.append(
                IPv6PrefixEntry(
                    address: address,
                    prefixLength: prefixLength,
                    interfaceName: interfaceName,
                    onLink:
                        raFlags & ND6PrefixRAFlag.onLink != 0,
                    autonomous:
                        raFlags & ND6PrefixRAFlag.autonomous != 0,
                    validLifetimeSeconds: readUInt64(
                        bytes,
                        at: offset
                            + ND6Layout.prefixValidLifetimeOffset
                    ),
                    preferredLifetimeSeconds: readUInt64(
                        bytes,
                        at: offset
                            + ND6Layout.prefixPreferredLifetimeOffset
                    ),
                    expiration: dateOrNever(expirationValue),
                    stateFlags: prefixStateFlagNames(
                        readUInt32(
                            bytes,
                            at: offset
                                + ND6Layout.prefixStateFlagsOffset
                        )
                    ),
                    advertisingRouters: advertisingRouters
                )
            )
            offset += entryLength
        }

        return entries.sorted {
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName.localizedStandardCompare(
                    $1.interfaceName
                ) == .orderedAscending
            }
            if $0.address != $1.address {
                return $0.address.localizedStandardCompare($1.address)
                    == .orderedAscending
            }
            return $0.prefixLength < $1.prefixLength
        }
    }

    private func readInterfaces(
        names: [String]
    ) -> InterfaceResult {
        let uniqueNames = Array(Set(names)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        guard !uniqueNames.isEmpty else {
            return InterfaceResult(
                entries: [],
                error: nil,
                interfaceErrors: []
            )
        }

        let descriptor = Darwin.socket(
            AF_INET6,
            SOCK_DGRAM,
            0
        )
        guard descriptor >= 0 else {
            let error = NetworkInformationSystemError(
                operation: "创建 IPv6 ND ioctl socket",
                code: errno
            )
            return InterfaceResult(
                entries: [],
                error: error.localizedDescription,
                interfaceErrors: []
            )
        }
        defer {
            Darwin.close(descriptor)
        }

        var entries: [IPv6NDInterfaceSnapshot] = []
        var interfaceErrors: [IPv6NDInterfaceError] = []
        for name in uniqueNames {
            do {
                entries.append(
                    try readInterface(
                        name: name,
                        descriptor: descriptor
                    )
                )
            } catch {
                interfaceErrors.append(
                    IPv6NDInterfaceError(
                        interfaceName: name,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return InterfaceResult(
            entries: entries,
            error: nil,
            interfaceErrors: interfaceErrors
        )
    }

    private func readInterface(
        name: String,
        descriptor: Int32
    ) throws -> IPv6NDInterfaceSnapshot {
        let nameBytes = Array(name.utf8)
        guard nameBytes.count < Int(IFNAMSIZ) else {
            throw IPv6AutoconfigurationParseError(
                description: "接口名称过长：\(name)"
            )
        }

        var bytes = [UInt8](
            repeating: 0,
            count: ND6Layout.interfaceRequestLength
        )
        bytes.replaceSubrange(
            0 ..< nameBytes.count,
            with: nameBytes
        )

        let result = bytes.withUnsafeMutableBytes { buffer in
            NetToolGetIPv6InterfaceInfo(
                descriptor,
                ND6Layout.getInterfaceInfoRequest,
                buffer.baseAddress
            )
        }
        guard result == 0 else {
            throw NetworkInformationSystemError(
                operation: "ioctl(SIOCGIFINFO_IN6, \(name))",
                code: errno
            )
        }

        let flags = readUInt32(
            bytes,
            at: ND6Layout.interfaceFlagsOffset
        )
        return IPv6NDInterfaceSnapshot(
            interfaceName: name,
            linkMTU: readUInt32(
                bytes,
                at: ND6Layout.interfaceLinkMTUOffset
            ),
            maximumMTU: readUInt32(
                bytes,
                at: ND6Layout.interfaceMaximumMTUOffset
            ),
            baseReachableTimeMilliseconds: readUInt32(
                bytes,
                at: ND6Layout.interfaceBaseReachableOffset
            ),
            reachableTimeSeconds: readUInt32(
                bytes,
                at: ND6Layout.interfaceReachableOffset
            ),
            retransmitTimerMilliseconds: readUInt32(
                bytes,
                at: ND6Layout.interfaceRetransmitOffset
            ),
            currentHopLimit:
                bytes[ND6Layout.interfaceHopLimitOffset],
            learnedRouterCount:
                bytes[ND6Layout.interfaceRouterCountOffset],
            flags: interfaceFlagNames(flags)
        )
    }

    private func ipv6Address(
        _ bytes: [UInt8],
        at offset: Int,
        interfaceName: String,
        context: String
    ) throws -> String {
        guard
            offset + ND6Layout.socketAddressIPv6Length <= bytes.count,
            Int(bytes[offset])
                == ND6Layout.socketAddressIPv6Length,
            Int32(bytes[offset + 1]) == AF_INET6
        else {
            throw IPv6AutoconfigurationParseError(
                description: "\(context)包含无效 sockaddr_in6"
            )
        }

        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(
                    from: source[
                        offset
                            ..< offset
                            + ND6Layout.socketAddressIPv6Length
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
                        socklen_t(
                            ND6Layout.socketAddressIPv6Length
                        ),
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
            let message = gai_strerror(result).map {
                String(cString: $0)
            } ?? "未知 getnameinfo 错误 \(result)"
            throw IPv6AutoconfigurationParseError(
                description: "\(context)地址解析失败："
                    + message
            )
        }

        let address = decodedCString(host)
        guard
            address.lowercased().hasPrefix("fe80:"),
            !address.contains("%"),
            interfaceName != "未知"
        else {
            return address
        }
        return "\(address)%\(interfaceName)"
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

    private func routerPreference(
        _ flags: UInt8
    ) -> IPv6RouterPreference {
        switch flags & ND6RouterFlag.preferenceMask {
        case ND6RouterFlag.preferenceHigh:
            .high
        case ND6RouterFlag.preferenceLow:
            .low
        case ND6RouterFlag.preferenceReserved:
            .reserved
        default:
            .medium
        }
    }

    private func routerStateFlagNames(
        _ flags: UInt8
    ) -> [String] {
        [
            (ND6RouterStateFlag.installed, "INSTALLED"),
            (ND6RouterStateFlag.interfaceScoped, "SCOPED"),
            (ND6RouterStateFlag.staticEntry, "STATIC"),
            (ND6RouterStateFlag.mapped, "MAPPED"),
            (ND6RouterStateFlag.ineligible, "INELIGIBLE"),
            (ND6RouterStateFlag.local, "LOCAL")
        ]
        .compactMap { mask, name in
            flags & mask != 0 ? name : nil
        }
    }

    private func prefixStateFlagNames(
        _ flags: UInt32
    ) -> [String] {
        [
            (ND6PrefixStateFlag.onLink, "ONLINK"),
            (ND6PrefixStateFlag.detached, "DETACHED"),
            (ND6PrefixStateFlag.staticEntry, "STATIC"),
            (ND6PrefixStateFlag.interfaceScoped, "SCOPED"),
            (ND6PrefixStateFlag.prefixProxy, "PREFIX-PROXY")
        ]
        .compactMap { mask, name in
            flags & mask != 0 ? name : nil
        }
    }

    private func interfaceFlagNames(
        _ flags: UInt32
    ) -> [String] {
        [
            (ND6InterfaceFlag.performNUD, "PERFORMNUD"),
            (ND6InterfaceFlag.disabled, "DISABLED"),
            (ND6InterfaceFlag.proxyPrefixes, "PROXY-PREFIXES"),
            (ND6InterfaceFlag.ignoreNeighborAdvertisement, "IGNORE-NA"),
            (ND6InterfaceFlag.insecure, "INSECURE"),
            (ND6InterfaceFlag.replicated, "REPLICATED"),
            (ND6InterfaceFlag.performDAD, "DAD")
        ]
        .compactMap { mask, name in
            flags & mask != 0 ? name : nil
        }
    }

    private func dateOrNever(_ value: UInt64) -> Date? {
        value == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(value))
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

    private func readUInt64(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt64 {
        UInt64(readUInt32(bytes, at: offset))
            | UInt64(readUInt32(bytes, at: offset + 4)) << 32
    }
}

private struct RouterResult {
    let entries: [IPv6DefaultRouterEntry]
    let error: String?
}

private struct PrefixResult {
    let entries: [IPv6PrefixEntry]
    let error: String?
}

private struct InterfaceResult {
    let entries: [IPv6NDInterfaceSnapshot]
    let error: String?
    let interfaceErrors: [IPv6NDInterfaceError]
}

private struct IPv6AutoconfigurationParseError: LocalizedError {
    let description: String

    var errorDescription: String? {
        "解析 IPv6 自动配置状态失败：\(description)"
    }
}

private enum ND6Layout {
    static let defaultRouterListNode: Int32 = 19
    static let prefixListNode: Int32 = 20

    static let socketAddressIPv6Length = 28
    static let defaultRouterLength = 48
    static let routerRAFlagsOffset = 28
    static let routerStateFlagsOffset = 29
    static let routerLifetimeOffset = 30
    static let routerExpirationOffset = 32
    static let routerInterfaceIndexOffset = 40

    static let prefixHeaderLength = 72
    static let prefixRAFlagsOffset = 28
    static let prefixLengthOffset = 29
    static let prefixValidLifetimeOffset = 32
    static let prefixPreferredLifetimeOffset = 40
    static let prefixExpirationOffset = 48
    static let prefixStateFlagsOffset = 56
    static let prefixInterfaceIndexOffset = 64
    static let prefixRouterCountOffset = 66

    static let interfaceRequestLength = 48
    static let interfaceLinkMTUOffset = 16
    static let interfaceMaximumMTUOffset = 20
    static let interfaceBaseReachableOffset = 24
    static let interfaceReachableOffset = 28
    static let interfaceRetransmitOffset = 32
    static let interfaceFlagsOffset = 36
    static let interfaceHopLimitOffset = 44
    static let interfaceRouterCountOffset = 45

    // _IOWR('i', 76, struct in6_ondireq), whose arm64 size is 48.
    static let getInterfaceInfoRequest: UInt = 0xC030_694C
}

private enum ND6RouterFlag {
    static let managed: UInt8 = 0x80
    static let other: UInt8 = 0x40
    static let homeAgent: UInt8 = 0x20
    static let preferenceMask: UInt8 = 0x18
    static let preferenceHigh: UInt8 = 0x08
    static let preferenceReserved: UInt8 = 0x10
    static let preferenceLow: UInt8 = 0x18
}

private enum ND6RouterStateFlag {
    static let installed: UInt8 = 0x01
    static let interfaceScoped: UInt8 = 0x02
    static let staticEntry: UInt8 = 0x04
    static let mapped: UInt8 = 0x08
    static let ineligible: UInt8 = 0x10
    static let local: UInt8 = 0x20
}

private enum ND6PrefixRAFlag {
    static let onLink: UInt8 = 0x01
    static let autonomous: UInt8 = 0x02
}

private enum ND6PrefixStateFlag {
    static let onLink: UInt32 = 0x01
    static let detached: UInt32 = 0x02
    static let staticEntry: UInt32 = 0x100
    static let interfaceScoped: UInt32 = 0x1000
    static let prefixProxy: UInt32 = 0x2000
}

private enum ND6InterfaceFlag {
    static let performNUD: UInt32 = 0x01
    static let disabled: UInt32 = 0x08
    static let proxyPrefixes: UInt32 = 0x20
    static let ignoreNeighborAdvertisement: UInt32 = 0x40
    static let insecure: UInt32 = 0x80
    static let replicated: UInt32 = 0x100
    static let performDAD: UInt32 = 0x200
}
