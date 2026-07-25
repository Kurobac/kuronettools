import SwiftUI

@MainActor
struct AboutView: View {
    private var metadata: AppMetadata {
        AppMetadata.current
    }

    var body: some View {
        Form {
            Section("应用") {
                LabeledContent("名称", value: metadata.name)
                LabeledContent("版本", value: metadata.versionDescription)
                LabeledContent("Bundle ID", value: metadata.bundleIdentifier)
            }

            Section("运行环境") {
                LabeledContent(
                    "最低系统",
                    value: "iOS \(metadata.minimumSystemVersion)"
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("当前系统")
                        .foregroundStyle(.secondary)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("当前阶段") {
                LabeledContent("里程碑", value: "Step 5A")
                Text(
                    "Ping、Traceroute、TCP 端口扫描、UDP/TCP/DoT/DoH DNS、"
                        + "TCP 连接测试、TLS 检查、HTTP HEAD 信息与当前网络信息"
                        + "已可用。"
                )
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
