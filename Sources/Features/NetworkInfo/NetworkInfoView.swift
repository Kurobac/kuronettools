import NetToolCore
import SwiftUI

@MainActor
struct NetworkInfoView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = NetworkInfoViewModel()

    var body: some View {
        Form {
            pathSection
            gatewaySection
            routeSection
            ipv6AutoconfigurationSection
            interfaceSection
            neighborSection
        }
        .navigationTitle("网络信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: model.exportText) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.exportText.isEmpty)

                Button {
                    model.refresh(logStore: logStore)
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
            }
        }
        .task {
            model.start(logStore: logStore)
        }
        .onDisappear {
            model.stop()
        }
    }

    @ViewBuilder
    private var pathSection: some View {
        Section("当前路径") {
            if let path = model.path {
                LabeledContent("状态") {
                    Text(path.status.title)
                        .foregroundStyle(pathStatusColor(path.status))
                }

                if let reason = path.unsatisfiedReason {
                    LabeledContent("原因", value: reason)
                }

                LabeledContent("接口") {
                    Text(
                        path.interfaces.isEmpty
                            ? "无"
                            : path.interfaces
                                .map {
                                    "\($0.name)（\($0.kind.title)）"
                                }
                                .joined(separator: "、")
                    )
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                }

                LabeledContent(
                    "链路质量",
                    value: path.linkQuality.title
                )

                capabilityRow(
                    title: "协议",
                    values: [
                        ("IPv4", path.supportsIPv4),
                        ("IPv6", path.supportsIPv6),
                        ("DNS", path.supportsDNS)
                    ]
                )

                if path.isExpensive
                    || path.isConstrained
                    || path.isUltraConstrained
                {
                    capabilityRow(
                        title: "限制",
                        values: [
                            ("按流量计费", path.isExpensive),
                            ("低数据模式", path.isConstrained),
                            ("超受限", path.isUltraConstrained)
                        ],
                        showsDisabled: false
                    )
                }
            } else {
                HStack {
                    ProgressView()
                    Text("正在读取路径…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var gatewaySection: some View {
        if let path = model.path {
            Section("网关") {
                if path.gateways.isEmpty {
                    Text("当前路径未报告网关")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(path.gateways, id: \.self) { gateway in
                        Text(gateway)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var routeSection: some View {
        Section("路由") {
            NavigationLink {
                NetworkRouteTableView(snapshot: model.routes)
            } label: {
                HStack {
                    Text("路由表")
                    Spacer()
                    if model.isRefreshing, model.routes.entries.isEmpty {
                        ProgressView()
                    } else if routeReadFailed {
                        Text(routeSummary)
                            .foregroundStyle(.red)
                    } else {
                        Text(routeSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var routeSummary: String {
        if routeReadFailed, model.routes.entries.isEmpty {
            return "读取失败"
        }
        return "IPv4 \(model.routes.ipv4.count) · "
            + "IPv6 \(model.routes.ipv6.count)"
    }

    private var routeReadFailed: Bool {
        model.routes.ipv4Error != nil || model.routes.ipv6Error != nil
    }

    private var ipv6AutoconfigurationSection: some View {
        Section("IPv6") {
            NavigationLink {
                IPv6AutoconfigurationView(
                    snapshot: model.ipv6Autoconfiguration
                )
            } label: {
                HStack {
                    Text("自动配置")
                    Spacer()
                    if model.isRefreshing,
                       !ipv6AutoconfigurationHasData
                    {
                        ProgressView()
                    } else if model.ipv6Autoconfiguration.hasErrors {
                        Text(ipv6AutoconfigurationSummary)
                            .foregroundStyle(.red)
                    } else {
                        Text(ipv6AutoconfigurationSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var ipv6AutoconfigurationSummary: String {
        if model.ipv6Autoconfiguration.hasErrors,
           !ipv6AutoconfigurationHasData
        {
            return "读取失败"
        }
        return "\(model.ipv6Autoconfiguration.defaultRouters.count) "
            + "路由器 · "
            + "\(model.ipv6Autoconfiguration.prefixes.count) 前缀"
    }

    private var ipv6AutoconfigurationHasData: Bool {
        !model.ipv6Autoconfiguration.defaultRouters.isEmpty
            || !model.ipv6Autoconfiguration.prefixes.isEmpty
            || !model.ipv6Autoconfiguration.interfaces.isEmpty
    }

    @ViewBuilder
    private var interfaceSection: some View {
        Section {
            if let error = model.interfacesError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if model.interfaces.isEmpty {
                if model.isRefreshing {
                    HStack {
                        ProgressView()
                        Text("正在读取接口…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("没有接口")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.interfaces) { interface in
                    NavigationLink {
                        NetworkInterfaceDetailView(
                            interface: interface
                        )
                    } label: {
                        NetworkInterfaceRow(interface: interface)
                    }
                }
            }
        } header: {
            Text("接口")
        } footer: {
            if let lastUpdated = model.lastUpdated {
                Text(
                    "更新于 "
                        + lastUpdated.formatted(
                            date: .omitted,
                            time: .standard
                        )
                )
            }
        }
    }

    @ViewBuilder
    private var neighborSection: some View {
        Section {
            neighborFamily(
                .ipv4,
                entries: model.neighbors.ipv4,
                error: model.neighbors.ipv4Error
            )
            neighborFamily(
                .ipv6,
                entries: model.neighbors.ipv6,
                error: model.neighbors.ipv6Error
            )
        } header: {
            Text("Neighbor")
        } footer: {
            Text(
                "这里只读取系统已有的 ARP/NDP 缓存；刷新不会主动探测局域网设备。"
            )
        }
    }

    @ViewBuilder
    private func neighborFamily(
        _ family: NeighborAddressFamily,
        entries: [NeighborEntry],
        error: String?
    ) -> some View {
        if let error {
            VStack(alignment: .leading, spacing: 5) {
                Text(family.rawValue)
                    .font(.callout.weight(.medium))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } else if entries.isEmpty {
            LabeledContent(family.rawValue) {
                Text(model.isRefreshing ? "正在读取…" : "缓存为空")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(entries) { entry in
                NeighborRow(entry: entry)
            }
        }
    }

    private func capabilityRow(
        title: String,
        values: [(String, Bool)],
        showsDisabled: Bool = true
    ) -> some View {
        LabeledContent(title) {
            Text(
                values
                    .filter { showsDisabled || $0.1 }
                    .map { "\($0.0) \($0.1 ? "✓" : "×")" }
                    .joined(separator: "  ")
            )
            .foregroundStyle(.secondary)
        }
    }

    private func pathStatusColor(
        _ status: NetworkPathStatus
    ) -> Color {
        switch status {
        case .satisfied:
            .green
        case .requiresConnection:
            .orange
        case .unsatisfied:
            .red
        }
    }
}

private struct IPv6AutoconfigurationView: View {
    let snapshot: IPv6AutoconfigurationSnapshot

    var body: some View {
        Form {
            defaultRoutersSection
            prefixesSection
            interfacesSection
        }
        .navigationTitle("IPv6 自动配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var defaultRoutersSection: some View {
        Section("默认路由器") {
            if let error = snapshot.defaultRoutersError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if snapshot.defaultRouters.isEmpty {
                Text("没有默认路由器")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(snapshot.defaultRouters.enumerated()),
                    id: \.offset
                ) { _, router in
                    defaultRouterRow(router)
                }
            }
        }
    }

    @ViewBuilder
    private var prefixesSection: some View {
        Section("前缀") {
            if let error = snapshot.prefixesError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if snapshot.prefixes.isEmpty {
                Text("没有 RA 前缀")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(snapshot.prefixes.enumerated()),
                    id: \.offset
                ) { _, prefix in
                    prefixRow(prefix)
                }
            }
        }
    }

    @ViewBuilder
    private var interfacesSection: some View {
        Section("接口 ND 参数") {
            if let error = snapshot.interfacesError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if snapshot.interfaces.isEmpty,
                      snapshot.interfaceErrors.isEmpty
            {
                Text("没有可用参数")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(snapshot.interfaces.enumerated()),
                    id: \.offset
                ) { _, interface in
                    interfaceRow(interface)
                }
                ForEach(
                    Array(snapshot.interfaceErrors.enumerated()),
                    id: \.offset
                ) { _, error in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error.interfaceName)
                            .font(.callout.weight(.medium))
                        Text(error.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func defaultRouterRow(
        _ router: IPv6DefaultRouterEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(router.address)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Text(router.interfaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                "优先级 \(router.preference.title) · "
                    + "通告生命周期 "
                    + duration(
                        seconds: UInt64(
                            router.advertisedLifetimeSeconds
                        )
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("剩余 \(remaining(router.expiration))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                flagSummary(
                    raFlags: router.raFlags,
                    stateFlags: router.stateFlags
                )
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func prefixRow(
        _ prefix: IPv6PrefixEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(prefix.cidrDescription)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Text(prefix.interfaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                "有效 \(lifetime(prefix.validLifetimeSeconds)) · "
                    + "首选 "
                    + lifetime(prefix.preferredLifetimeSeconds)
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("剩余 \(remaining(prefix.expiration))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                flagSummary(
                    raFlags: prefix.raFlags,
                    stateFlags: prefix.stateFlags
                )
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if !prefix.advertisingRouters.isEmpty {
                Text(
                    "通告路由器 "
                        + prefix.advertisingRouters
                            .joined(separator: "、")
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func interfaceRow(
        _ interface: IPv6NDInterfaceSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(interface.interfaceName)
                .font(.callout.weight(.medium))

            Text(
                "MTU \(interface.linkMTU) · "
                    + "最大 MTU \(interface.maximumMTU) · "
                    + "Hop Limit \(interface.currentHopLimit)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "Base Reachable "
                    + milliseconds(
                        interface.baseReachableTimeMilliseconds
                    )
                    + " · Reachable "
                    + duration(
                        seconds: UInt64(
                            interface.reachableTimeSeconds
                        )
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "Retrans "
                    + milliseconds(
                        interface.retransmitTimerMilliseconds
                    )
                    + " · 已学习路由器 "
                    + "\(interface.learnedRouterCount)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !interface.flags.isEmpty {
                Text(interface.flags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func flagSummary(
        raFlags: [String],
        stateFlags: [String]
    ) -> String {
        var groups = [
            "RA "
                + (
                    raFlags.isEmpty
                        ? "无"
                        : raFlags.joined(separator: " · ")
                )
        ]
        if !stateFlags.isEmpty {
            groups.append(stateFlags.joined(separator: " · "))
        }
        return groups.joined(separator: "  ")
    }

    private func remaining(_ expiration: Date?) -> String {
        guard let expiration else {
            return "永不过期"
        }
        let seconds = Int64(
            expiration.timeIntervalSinceNow.rounded(.down)
        )
        guard seconds > 0 else {
            return "已过期"
        }
        return duration(seconds: UInt64(seconds))
    }

    private func lifetime(_ seconds: UInt64) -> String {
        if seconds == IPv6PrefixEntry.infiniteLifetime {
            return "无限"
        }
        return duration(seconds: seconds)
    }

    private func milliseconds(_ value: UInt32) -> String {
        if value.isMultiple(of: 1000) {
            return duration(seconds: UInt64(value / 1000))
        }
        return "\(value) 毫秒"
    }

    private func duration(seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        let remainingSeconds = seconds % 60

        if days > 0 {
            return hours > 0
                ? "\(days) 天 \(hours) 小时"
                : "\(days) 天"
        }
        if hours > 0 {
            return minutes > 0
                ? "\(hours) 小时 \(minutes) 分钟"
                : "\(hours) 小时"
        }
        if minutes > 0 {
            return remainingSeconds > 0
                ? "\(minutes) 分钟 \(remainingSeconds) 秒"
                : "\(minutes) 分钟"
        }
        return "\(remainingSeconds) 秒"
    }
}

private struct NetworkRouteTableView: View {
    let snapshot: NetworkRouteTableSnapshot

    var body: some View {
        Form {
            routeSection(
                family: .ipv4,
                entries: snapshot.ipv4,
                error: snapshot.ipv4Error
            )
            routeSection(
                family: .ipv6,
                entries: snapshot.ipv6,
                error: snapshot.ipv6Error
            )
        }
        .navigationTitle("路由表")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func routeSection(
        family: RouteAddressFamily,
        entries: [NetworkRouteEntry],
        error: String?
    ) -> some View {
        Section(family.rawValue) {
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if entries.isEmpty {
                Text("没有路由")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(entries.enumerated()),
                    id: \.offset
                ) { _, entry in
                    NetworkRouteRow(entry: entry)
                }
            }
        }
    }
}

private struct NetworkRouteRow: View {
    let entry: NetworkRouteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.destinationDescription)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Text(entry.interfaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(entry.gateway.map { "via \($0)" } ?? "直连")
                Spacer()
                if let mtu = entry.mtu {
                    Text("MTU \(mtu)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !entry.flags.isEmpty {
                Text(entry.flags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NetworkInterfaceRow: View {
    let interface: NetworkInterfaceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(interface.name)
                    .font(.body.weight(.medium))
                Text(interface.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if interface.addresses.isEmpty {
                Text("无 IP 地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    interface.addresses
                        .prefix(2)
                        .map(\.cidrDescription)
                        .joined(separator: "\n")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NeighborRow: View {
    let entry: NeighborEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.address)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Text("\(entry.family.rawValue) · \(entry.interfaceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.isPermanent || entry.expiration != nil
                || !entry.flags.isEmpty
            {
                HStack {
                    if !entry.flags.isEmpty {
                        Text(entry.flags.joined(separator: " · "))
                    }
                    Spacer()
                    if entry.isPermanent {
                        Text("永久")
                    } else if let expiration = entry.expiration {
                        Text(
                            expiration > Date()
                                ? "过期于 "
                                    + expiration.formatted(
                                        date: .omitted,
                                        time: .standard
                                    )
                                : "已过期"
                        )
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NetworkInterfaceDetailView: View {
    let interface: NetworkInterfaceSnapshot

    var body: some View {
        Form {
            Section("接口") {
                LabeledContent("名称", value: interface.name)
                LabeledContent(
                    "类型",
                    value: interface.kind.title
                )
                LabeledContent(
                    "索引",
                    value: String(interface.index)
                )
                LabeledContent(
                    "MTU",
                    value: interface.mtu.map(String.init) ?? "未知"
                )
                LabeledContent("标志") {
                    Text(
                        interface.flags.isEmpty
                            ? "无"
                            : interface.flags.joined(separator: " · ")
                    )
                    .multilineTextAlignment(.trailing)
                }
                if let address = interface.linkLayerAddress {
                    LabeledContent("链路地址") {
                        Text(address)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("地址") {
                if interface.addresses.isEmpty {
                    Text("没有 IPv4/IPv6 地址")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        Array(interface.addresses.enumerated()),
                        id: \.offset
                    ) { _, address in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(address.family.rawValue)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(address.classification)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(address.cidrDescription)
                                .font(.callout)
                                .textSelection(.enabled)

                            if
                                let label = address.relatedAddressLabel,
                                let relatedAddress = address.relatedAddress
                            {
                                LabeledContent(label) {
                                    Text(relatedAddress)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let statistics = interface.statistics {
                Section("流量统计") {
                    LabeledContent(
                        "接收",
                        value: bytes(statistics.receivedBytes)
                    )
                    LabeledContent(
                        "发送",
                        value: bytes(statistics.sentBytes)
                    )
                    LabeledContent(
                        "接收包",
                        value: String(statistics.receivedPackets)
                    )
                    LabeledContent(
                        "发送包",
                        value: String(statistics.sentPackets)
                    )
                    LabeledContent(
                        "接收错误",
                        value: String(statistics.inputErrors)
                    )
                    LabeledContent(
                        "发送错误",
                        value: String(statistics.outputErrors)
                    )
                }
            }
        }
        .navigationTitle(interface.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .binary
        )
    }
}
