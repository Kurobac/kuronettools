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
                ForEach(ToolCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(ToolCatalog.tools(in: category)) { tool in
                            NavigationLink {
                                destination(for: tool)
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

    @ViewBuilder
    private func destination(
        for tool: ToolDescriptor
    ) -> some View {
        switch tool.id {
        case "ping":
            PingView()
        case "traceroute":
            TracerouteView()
        case "dns":
            DNSView()
        case "tcp":
            TCPView()
        case "port-scan":
            PortScanView()
        case "tls":
            TLSView()
        case "http":
            HTTPView()
        case "network-info":
            NetworkInfoView()
        default:
            ToolPlaceholderView(tool: tool)
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
        }
        .padding(.vertical, 3)
    }
}
