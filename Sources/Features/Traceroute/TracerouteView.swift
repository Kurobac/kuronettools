import NetToolCore
import SwiftUI

@MainActor
struct TracerouteView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = TracerouteViewModel()

    var body: some View {
        @Bindable var model = model

        Form {
            Section("目标") {
                EditableTargetComboBox(
                    prompt: "主机名或 IP 地址",
                    suggestions: Self.commonTargets,
                    value: $model.host
                )

                Picker("地址族", selection: $model.addressFamily) {
                    ForEach(PingAddressFamily.allCases) { family in
                        Text(family.title)
                            .tag(family)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.isRunning)

            Section("参数") {
                Stepper(
                    "最大跳数：\(model.maxHops)",
                    value: $model.maxHops,
                    in: 1 ... 64
                )

                Stepper(
                    "每跳探测：\(model.probesPerHop) 次",
                    value: $model.probesPerHop,
                    in: 1 ... 5
                )

                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.1 ... 10,
                    step: 0.1
                ) {
                    LabeledContent(
                        "单次超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }
            }
            .disabled(model.isRunning)

            Section {
                RunActionButton(
                    isRunning: model.isRunning,
                    isStopping: model.isStopping,
                    startTitle: "开始 Traceroute",
                    startSystemImage:
                        "point.bottomleft.forward.to.point.topright.scurvepath"
                ) {
                    model.start(logStore: logStore)
                } stopAction: {
                    model.stop(logStore: logStore)
                }
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if !model.hops.isEmpty {
                Section("路径") {
                    ForEach(model.hops) { hop in
                        TracerouteHopRow(hop: hop)
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section("错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Traceroute")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.exportText) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.exportText.isEmpty)
            }
        }
        .onDisappear {
            if model.isRunning {
                model.stop(logStore: logStore)
            }
        }
    }

    private static let commonTargets = [
        "1.1.1.1",
        "8.8.8.8",
        "223.5.5.5",
        "119.29.29.29",
        "one.one.one.one",
        "dns.google",
        "www.baidu.com",
        "www.apple.com"
    ]

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }
}

private struct TracerouteHopRow: View {
    let hop: TracerouteHopItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(hop.hop))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(
                    width: 24,
                    alignment: .trailing
                )

            VStack(alignment: .leading, spacing: 6) {
                ForEach(hop.probes.indices, id: \.self) { index in
                    probeView(hop.probes[index])
                }
            }
        }
    }

    @ViewBuilder
    private func probeView(
        _ probe: TracerouteProbeResult
    ) -> some View {
        switch probe {
        case .response(let response):
            HStack(alignment: .firstTextBaseline) {
                Text(response.address)
                    .font(.callout)
                    .foregroundStyle(
                        response.kind == .destination
                            ? Color.green
                            : Color.primary
                    )
                    .textSelection(.enabled)

                Spacer()

                Text(
                    String(
                        format: "%.3f ms",
                        response.roundTripTimeMilliseconds
                    )
                )
                .font(.callout.monospacedDigit())
            }
        case .timeout:
            HStack {
                Text("*")
                    .font(.callout.monospaced())
                Spacer()
                Text("超时")
                    .font(.caption)
            }
            .foregroundStyle(.orange)
        }
    }
}
