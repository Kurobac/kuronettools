import NetToolCore
import SwiftUI

@MainActor
struct ToolPlaceholderView: View {
    @Environment(AppLogStore.self) private var logStore

    let tool: ToolDescriptor

    var body: some View {
        ContentUnavailableView {
            Label(tool.title, systemImage: tool.systemImage)
        } description: {
            Text("\(tool.summary)\n该工具暂未提供。")
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            logStore.append(
                level: .debug,
                message: "打开未提供的工具：\(tool.title)"
            )
        }
    }
}
