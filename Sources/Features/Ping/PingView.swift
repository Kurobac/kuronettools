import NetToolCore
import SwiftUI

@MainActor
struct PingView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = PingViewModel()
    @State private var scrollPosition: PingScrollSection?

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
            .id(PingScrollSection.target)

            Section("参数") {
                Stepper(
                    "请求次数：\(model.count)",
                    value: $model.count,
                    in: 1 ... 100
                )

                Stepper(
                    value: $model.intervalSeconds,
                    in: 0.1 ... 10,
                    step: 0.1
                ) {
                    LabeledContent(
                        "发送间隔",
                        value: seconds(model.intervalSeconds)
                    )
                }

                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.1 ... 30,
                    step: 0.1
                ) {
                    LabeledContent(
                        "单次超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }

                Stepper(
                    "Payload：\(model.payloadSize) 字节",
                    value: $model.payloadSize,
                    in: 0 ... 1_400,
                    step: 8
                )
            }
            .disabled(model.isRunning)
            .id(PingScrollSection.parameters)

            Section {
                RunActionButton(
                    isRunning: model.isRunning,
                    isStopping: model.isStopping,
                    startTitle: "开始 Ping",
                    startSystemImage: "play.fill"
                ) {
                    model.start(logStore: logStore)
                } stopAction: {
                    model.stop(logStore: logStore)
                }

                if let statusMessage = model.statusMessage {
                    LabeledContent("状态") {
                        Text(statusMessage)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .id(PingScrollSection.action)

            if !model.results.isEmpty {
                Section("响应") {
                    ForEach(model.results) { item in
                        PingResultRow(item: item)
                    }
                }
                .id(PingScrollSection.responses)
            }

            if let summary = model.summary {
                Section("统计") {
                    PingSummaryView(summary: summary)
                }
                .id(PingScrollSection.summary)
            }

            if let errorMessage = model.errorMessage {
                Section("错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .id(PingScrollSection.error)
            }
        }
        .scrollPosition(id: $scrollPosition)
        .navigationTitle("Ping")
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

private enum PingScrollSection: Hashable {
    case target
    case parameters
    case action
    case responses
    case summary
    case error
}

private struct PingResultRow: View {
    let item: PingResultItem

    var body: some View {
        switch item.result {
        case .reply(let reply):
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.address)
                        .font(.callout)
                        .textSelection(.enabled)

                    Text(
                        "\(reply.byteCount) bytes · seq \(reply.sequence) "
                            + "· ttl \(reply.hopLimit)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(
                    "\(reply.roundTripTimeMilliseconds, specifier: "%.3f") ms"
                )
                .font(.callout.monospacedDigit())
            }
        case .timeout(let sequence):
            Label(
                "icmp_seq \(sequence) 请求超时",
                systemImage: "clock.badge.exclamationmark"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }
}

private struct PingSummaryView: View {
    let summary: PingSummary

    var body: some View {
        LabeledContent(
            "数据包",
            value: "\(summary.transmitted) 发 / \(summary.received) 收"
        )
        LabeledContent(
            "丢包率",
            value: String(format: "%.1f%%", summary.lossPercentage)
        )

        if let minimum = summary.minimumMilliseconds,
           let average = summary.averageMilliseconds,
           let maximum = summary.maximumMilliseconds,
           let deviation = summary.meanDeviationMilliseconds {
            LabeledContent(
                "最小 / 平均",
                value: String(
                    format: "%.3f / %.3f ms",
                    minimum,
                    average
                )
            )
            LabeledContent(
                "最大 / mdev",
                value: String(
                    format: "%.3f / %.3f ms",
                    maximum,
                    deviation
                )
            )
        }
    }
}
