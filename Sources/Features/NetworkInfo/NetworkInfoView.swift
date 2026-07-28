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
