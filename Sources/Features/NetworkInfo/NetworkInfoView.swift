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
        Section("Neighbor") {
            NavigationLink {
                NeighborCacheView(
                    snapshot: model.neighbors,
                    isRefreshing: model.isRefreshing
                )
            } label: {
                HStack {
                    Text("Neighbor 缓存")
                    Spacer()
                    if model.isRefreshing,
                       model.neighbors.entries.isEmpty
                    {
                        ProgressView()
                    } else if neighborReadFailed {
                        Text(neighborSummary)
                            .foregroundStyle(.red)
                    } else {
                        Text(neighborSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var neighborSummary: String {
        if neighborReadFailed, model.neighbors.entries.isEmpty {
            return "读取失败"
        }
        return "IPv4 \(model.neighbors.ipv4.count) · "
            + "IPv6 \(model.neighbors.ipv6.count)"
    }

    private var neighborReadFailed: Bool {
        model.neighbors.ipv4Error != nil
            || model.neighbors.ipv6Error != nil
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

private struct NeighborCacheView: View {
    let snapshot: NeighborCacheSnapshot
    let isRefreshing: Bool

    var body: some View {
        Form {
            neighborSection(
                .ipv4,
                entries: snapshot.ipv4,
                error: snapshot.ipv4Error
            )
            neighborSection(
                .ipv6,
                entries: snapshot.ipv6,
                error: snapshot.ipv6Error
            )
        }
        .navigationTitle("Neighbor 缓存")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func neighborSection(
        _ family: NeighborAddressFamily,
        entries: [NeighborEntry],
        error: String?
    ) -> some View {
        Section(family.rawValue) {
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if entries.isEmpty {
                Text(isRefreshing ? "正在读取…" : "缓存为空")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    NeighborRow(entry: entry)
                }
            }
        }
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
                Text(entry.interfaceName)
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
