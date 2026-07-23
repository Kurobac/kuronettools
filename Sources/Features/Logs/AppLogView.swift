import SwiftUI

@MainActor
struct AppLogView: View {
    @Environment(AppLogStore.self) private var logStore

    var body: some View {
        Group {
            if logStore.entries.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "text.document",
                    description: Text("应用运行信息会显示在这里。")
                )
            } else {
                List(logStore.entries) { entry in
                    LogEntryRow(entry: entry)
                }
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: logStore.exportText) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(logStore.entries.isEmpty)

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Label("清除", systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)
            }
        }
    }
}

private struct LogEntryRow: View {
    let entry: AppLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.level.rawValue)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(levelColor)

                Spacer()

                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:
            .secondary
        case .info:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}
