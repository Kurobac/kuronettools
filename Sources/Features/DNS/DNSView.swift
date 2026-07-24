import NetToolCore
import SwiftUI

@MainActor
struct DNSView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = DNSViewModel()

    var body: some View {
        @Bindable var model = model

        Form {
            Section("查询") {
                TextField("域名", text: $model.name)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("记录类型", selection: $model.recordType) {
                    ForEach(DNSRecordType.pickerCases) { recordType in
                        Text(recordType.title)
                            .tag(recordType)
                    }
                }
            }
            .disabled(model.isRunning)

            Section("传输") {
                Picker("协议", selection: $model.transport) {
                    ForEach(DNSTransport.allCases) { transport in
                        Text(transport.title)
                            .tag(transport)
                    }
                }
                .pickerStyle(.segmented)

                switch model.transport {
                case .udp, .tcp:
                    EditableTargetComboBox(
                        prompt: "DNS 服务器",
                        transport: model.transport,
                        value: $model.standardServer
                    )

                    TextField(
                        "端口",
                        value: $model.standardPort,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                case .tls:
                    EditableTargetComboBox(
                        prompt: "DoT 服务器",
                        transport: .tls,
                        value: $model.tlsServer
                    )

                    TextField(
                        "端口",
                        value: $model.tlsPort,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                case .https:
                    EditableTargetComboBox(
                        prompt: "DoH URL",
                        transport: .https,
                        value: $model.httpsURL
                    )

                    TextField(
                        "端口",
                        value: $model.httpsPort,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                }

                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.1 ... 30,
                    step: 0.1
                ) {
                    LabeledContent(
                        "超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }

                Toggle(
                    "请求递归（RD）",
                    isOn: $model.recursionDesired
                )
            }
            .disabled(model.isRunning)

            Section {
                if model.isRunning {
                    Button(role: .destructive) {
                        model.stop(logStore: logStore)
                    } label: {
                        actionLabel(
                            model.isStopping ? "正在停止…" : "停止",
                            systemImage: "stop.fill"
                        )
                    }
                    .disabled(model.isStopping)
                } else {
                    Button {
                        model.start(logStore: logStore)
                    } label: {
                        actionLabel(
                            "查询",
                            systemImage: "paperplane.fill"
                        )
                    }
                }
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let result = model.result {
                DNSRecordSection(
                    title: "Answer",
                    records: result.message.answers,
                    showsEmptyState: true
                )

                DNSResponseOverview(result: result)

                DNSRecordSection(
                    title: "Authority",
                    records: result.message.authorities
                )
                DNSRecordSection(
                    title: "Additional",
                    records: result.message.additionals
                )

                Section("原始报文") {
                    DisclosureGroup("查询报文") {
                        rawText(result.queryBytes)
                    }
                    DisclosureGroup("响应报文") {
                        rawText(result.responseBytes)
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
        .navigationTitle("DNS 查询")
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

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    private func actionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
    }

    private func rawText(_ bytes: [UInt8]) -> some View {
        Text(DNSMessageCodec.hexadecimalString(for: bytes))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

private struct DNSResponseOverview: View {
    let result: DNSQueryResult

    var body: some View {
        let flags = result.message.flags

        Section("响应") {
            LabeledContent("状态", value: flags.responseCodeName)
            LabeledContent("协议", value: result.transport.title)
            LabeledContent(
                "Flags",
                value: flags.activeNames.joined(separator: " ")
            )
            LabeledContent(
                "端点",
                value: result.endpoint
            )
            if let httpStatusCode = result.httpStatusCode {
                LabeledContent(
                    "HTTP",
                    value: String(httpStatusCode)
                )
            }
            LabeledContent(
                "耗时",
                value: String(
                    format: "%.3f ms",
                    result.roundTripTimeMilliseconds
                )
            )
            LabeledContent(
                "报文大小",
                value: "\(result.responseBytes.count) 字节"
            )

            if flags.isTruncated {
                Label(
                    truncationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private var truncationMessage: String {
        if result.transport == .udp {
            return "UDP 响应设置了 TC 标志，结果可能不完整；"
                + "请选择 TCP 重试。"
        }
        return "\(result.transport.title) 响应仍设置了 TC 标志，"
            + "结果可能不完整。"
    }
}

private struct DNSRecordSection: View {
    let title: String
    let records: [DNSResourceRecord]
    var showsEmptyState = false

    var body: some View {
        if !records.isEmpty || showsEmptyState {
            Section(title) {
                if records.isEmpty {
                    Text("无记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records.indices, id: \.self) { index in
                        DNSRecordRow(record: records[index])
                    }
                }
            }
        }
    }
}

private struct DNSRecordRow: View {
    let record: DNSResourceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.typeName)
                    .font(.callout.weight(.semibold))

                Text(record.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("TTL \(record.timeToLive)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(record.data.displayValue)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
