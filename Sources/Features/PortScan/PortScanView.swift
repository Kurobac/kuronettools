import NetToolCore
import SwiftUI

@MainActor
struct PortScanView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = PortScanViewModel()

    var body: some View {
        @Bindable var model = model

        Form {
            Section("目标") {
                EditableTargetComboBox(
                    prompt: "主机名或 IP 地址",
                    suggestions: Self.commonTargets,
                    value: $model.host
                )

                EditablePortExpressionField(
                    expression: $model.portExpression,
                    presets: Self.portPresets
                )

                Picker("地址族", selection: $model.addressFamily) {
                    ForEach(TCPAddressFamily.allCases) { family in
                        Text(family.title)
                            .tag(family)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.isRunning)

            Section("参数") {
                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.1 ... 30,
                    step: 0.1
                ) {
                    LabeledContent(
                        "单端口超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }

                Stepper(
                    "最大并发：\(model.maxConcurrency)",
                    value: $model.maxConcurrency,
                    in: 1 ... 128
                )

                Stepper(
                    value: $model.maxStartRate,
                    in: 10 ... 1_000,
                    step: 10
                ) {
                    LabeledContent(
                        "最大发起速率",
                        value: "\(model.maxStartRate) 次/秒"
                    )
                }

                Stepper(
                    "超时重试：\(model.maxRetries) 次",
                    value: $model.maxRetries,
                    in: 0 ... 2
                )
            }
            .disabled(model.isRunning)

            Section {
                RunActionButton(
                    isRunning: model.isRunning,
                    isStopping: model.isStopping,
                    startTitle: "开始扫描",
                    startSystemImage: "square.grid.3x3.square"
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

            if let summary = model.summary {
                Section("进度与统计") {
                    ProgressView(
                        value: Double(summary.scanned),
                        total: Double(summary.total)
                    )

                    LabeledContent(
                        "进度",
                        value: "\(summary.scanned) / \(summary.total)"
                    )
                    if model.retryRound > 0 {
                        LabeledContent(
                            "本轮重试",
                            value: "\(model.retryRoundCompleted) / "
                                + "\(model.retryRoundTotal)"
                        )
                    }
                    LabeledContent(
                        "开放",
                        value: String(summary.open)
                    )
                    LabeledContent(
                        "关闭",
                        value: String(summary.closed)
                    )
                    LabeledContent(
                        "超时",
                        value: String(summary.timedOut)
                    )
                    LabeledContent(
                        "不可达",
                        value: String(summary.unreachable)
                    )
                    LabeledContent(
                        "失败",
                        value: String(summary.failed)
                    )

                    if let timing = model.timing {
                        LabeledContent(
                            "当前并发窗口",
                            value: String(timing.currentParallelism)
                        )
                        LabeledContent(
                            "峰值并发窗口",
                            value: String(timing.peakParallelism)
                        )
                        LabeledContent(
                            "最大并发窗口",
                            value: String(timing.maxParallelism)
                        )
                        LabeledContent(
                            "当前发起速率",
                            value: "\(timing.startRateLimit) 次/秒"
                        )
                        LabeledContent(
                            "活动连接",
                            value: String(timing.activeConnections)
                        )
                        LabeledContent(
                            "峰值活动连接",
                            value: String(
                                timing.peakActiveConnections
                            )
                        )
                        LabeledContent(
                            "重试尝试",
                            value: String(timing.retryAttempts)
                        )
                        LabeledContent(
                            "超时尝试",
                            value: String(timing.timeoutAttempts)
                        )
                        LabeledContent(
                            "App 截止超时",
                            value: String(
                                timing.appDeadlineTimeouts
                            )
                        )
                        LabeledContent(
                            "系统 TCP 超时",
                            value: String(timing.systemTimeouts)
                        )
                    }
                }
            }

            if !model.openResults.isEmpty {
                Section("开放端口") {
                    ForEach(
                        model.sortedOpenResults,
                        id: \.port
                    ) { result in
                        OpenPortRow(result: result)
                    }
                }
            } else if model.didComplete {
                Section("开放端口") {
                    Text("没有发现开放端口。")
                        .foregroundStyle(.secondary)
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
        .navigationTitle("端口扫描")
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
        "one.one.one.one",
        "dns.google",
        "www.baidu.com",
        "www.apple.com"
    ]

    private static let portPresets = [
        "22,53,80,443,853,8080,8443",
        "80,443,8000,8080,8443,8888",
        "1-1024",
        "1-65535"
    ]

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }
}

@MainActor
private struct EditablePortExpressionField: View {
    @Binding var expression: String
    let presets: [String]

    var body: some View {
        TextField("端口或范围", text: $expression)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.trailing, 28)
            .overlay(alignment: .trailing) {
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            expression = preset
                        } label: {
                            HStack {
                                Text(preset)
                                if preset == normalizedExpression {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(
                        systemName: "chevron.up.chevron.down"
                    )
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择常用端口范围")
                .offset(x: 30)
            }
    }

    private var normalizedExpression: String {
        expression.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}

private struct OpenPortRow: View {
    let result: TCPPortScanResult

    var body: some View {
        if case .open(
            let address,
            let family,
            let connectionTimeMilliseconds
        ) = result.outcome {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        verbatim: String(result.port) + "/tcp"
                    )
                        .font(.body.weight(.medium).monospacedDigit())

                    Spacer()

                    Text(
                        String(
                            format: "%.3f ms",
                            connectionTimeMilliseconds
                        )
                    )
                    .font(.callout.monospacedDigit())
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(address)
                        .font(.callout)
                        .textSelection(.enabled)

                    Spacer()

                    Text(family.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
