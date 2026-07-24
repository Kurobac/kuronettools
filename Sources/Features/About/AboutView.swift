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
                LabeledContent("里程碑", value: "Step 2")
                Text(
                    "Ping 与 UDP、TCP、DoT、DoH DNS 查询已可用。"
                        + "高级 DNS 选项暂缓实现。"
                )
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
