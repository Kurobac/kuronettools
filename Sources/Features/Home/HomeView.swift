import NetToolCore
import SwiftUI

@MainActor
struct HomeView: View {
    private var metadata: AppMetadata {
        AppMetadata.current
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("开发阶段") {
                        Text("Step 0")
                            .foregroundStyle(.secondary)
                    }

                    Text("工程骨架已经就绪。下面列出的网络工具会在后续阶段逐项启用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(ToolCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(ToolCatalog.tools(in: category)) { tool in
                            NavigationLink {
                                ToolPlaceholderView(tool: tool)
                            } label: {
                                ToolRow(tool: tool)
                            }
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("NetTool \(metadata.versionDescription)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("NetTool")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        AppLogView()
                    } label: {
                        Label("运行日志", systemImage: "text.document")
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title)
                    .font(.body.weight(.medium))

                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("规划中")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
