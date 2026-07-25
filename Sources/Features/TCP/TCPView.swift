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

                EditablePortField(
                    port: $model.port,
                    commonPorts: Self.commonPorts
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
                    in: 0.5 ... 30,
                    step: 0.5
                ) {
                    LabeledContent(
                        "连接超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }
            }
            .disabled(model.isRunning)

            Section {
                RunActionButton(
                    isRunning: model.isRunning,
                    isStopping: model.isStopping,
                    startTitle: "开始连接",
                    startSystemImage: "cable.connector"
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

            if let result = model.result {
                Section("结果") {
                    LabeledContent("远端地址") {
                        Text(result.address)
                            .font(.callout)
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

    private static let commonPorts = [
        22,
        53,
        80,
        443,
        853,
        8080,
        8443
    ]

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.3f ms", value)
    }
}
