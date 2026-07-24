import NetToolCore
import SwiftUI

@MainActor
struct TCPView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = TCPViewModel()

    var body: some View {
        @Bindable var model = model

        Form {
            Section("目标") {
                EditableTargetComboBox(
                    prompt: "主机名或 IP 地址",
                    suggestions: Self.commonTargets,
                    value: $model.host
                )

                TCPPortField(port: $model.port)

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
                        "连接超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }
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
                            "开始连接",
                            systemImage: "cable.connector"
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
                Section("结果") {
                    LabeledContent("远端地址") {
                        Text(result.address)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent(
                        "远端端口",
                        value: String(result.port)
                    )
                    LabeledContent(
                        "地址族",
                        value: result.addressFamily.title
                    )
                    LabeledContent(
                        "连接耗时",
                        value: milliseconds(
                            result.connectionTimeMilliseconds
                        )
                    )
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
        .navigationTitle("TCP 连接")
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

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.3f ms", value)
    }

    private func actionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct TCPPortField: View {
    @Binding var port: Int

    var body: some View {
        TextField(
            "端口",
            value: $port,
            format: .number
        )
        .keyboardType(.numberPad)
        .padding(.trailing, 28)
        .overlay(alignment: .trailing) {
            Menu {
                ForEach(Self.commonPorts, id: \.self) { commonPort in
                    Button {
                        port = commonPort
                    } label: {
                        HStack {
                            Text(String(commonPort))
                            if commonPort == port {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择常用端口")
            .offset(x: 30)
        }
    }

    private static let commonPorts = [
        22,
        53,
        80,
        443,
        853,
        8080,
        8443
    ]
}
