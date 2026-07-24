import SwiftUI

@MainActor
struct RunActionButton: View {
    let isRunning: Bool
    let isStopping: Bool
    let startTitle: String
    let startSystemImage: String
    let startAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button(role: isRunning ? .destructive : nil) {
            if isRunning {
                stopAction()
            } else {
                startAction()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .disabled(isStopping)
    }

    private var title: String {
        if isStopping {
            return "正在停止…"
        }
        return isRunning ? "停止" : startTitle
    }

    private var systemImage: String {
        isRunning ? "stop.fill" : startSystemImage
    }
}
