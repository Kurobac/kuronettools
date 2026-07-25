import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class PortScanViewModel {
    var host = "1.1.1.1"
    var portExpression = "22,53,80,443,853,8080,8443"
    var addressFamily = TCPAddressFamily.automatic
    var timeoutSeconds = 1.0
    var concurrency = 32

    private(set) var summary: TCPPortScanSummary?
    private(set) var openResults: [TCPPortScanResult] = []
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var didComplete = false

    @ObservationIgnored
    private let client = TCPPortScanClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeConfiguration: TCPPortScanConfiguration?

    @ObservationIgnored
    private var activePortExpression: String?

    var sortedOpenResults: [TCPPortScanResult] {
        openResults.sorted { $0.port < $1.port }
    }

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResults()

        let configuration: TCPPortScanConfiguration
        do {
            let ports = try TCPPortExpressionParser.parse(
                portExpression
            )
            configuration = try TCPPortScanConfiguration(
                host: host,
                ports: ports,
                addressFamily: addressFamily,
                timeoutSeconds: timeoutSeconds,
                concurrency: concurrency
            ).validated()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        host = configuration.host
        activeConfiguration = configuration
        activePortExpression = portExpression.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isRunning = true
        isStopping = false
        statusMessage = "正在准备扫描…"
        logStore.append(
            level: .info,
            message: "开始 TCP 端口扫描："
                + "\(configuration.host)，"
                + "\(configuration.ports.count) 个端口，"
                + "并发 \(configuration.concurrency)"
        )

        let client = client
        runTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.isStopping {
                    self.statusMessage = "已停止"
                }
                self.isRunning = false
                self.isStopping = false
                self.runTask = nil
            }

            for await event in client.events(
                for: configuration
            ) {
                guard !Task.isCancelled else {
                    return
                }
                self.handle(event, logStore: logStore)
            }
        }
    }

    func stop(logStore: AppLogStore) {
        guard isRunning, !isStopping else {
            return
        }

        isStopping = true
        statusMessage = "正在停止…"
        runTask?.cancel()
        logStore.append(
            level: .warning,
            message: "取消 TCP 端口扫描：\(host)"
        )
    }

    var exportText: String {
        guard let configuration = activeConfiguration else {
            if let errorMessage {
                return [
                    "TCP CONNECT SCAN \(host)",
                    "Ports: \(portExpression)",
                    "Error: \(errorMessage)"
                ].joined(separator: "\n")
            }
            return ""
        }

        var lines = [
            "TCP CONNECT SCAN \(configuration.host)",
            "Ports: \(activePortExpression ?? "")",
            "Address family: \(configuration.addressFamily.title)",
            "Timeout: \(format(configuration.timeoutSeconds)) s",
            "Concurrency: \(configuration.concurrency)"
        ]

        if let summary {
            lines.append("")
            lines.append(
                "Progress: \(summary.scanned)/\(summary.total)"
            )
            lines.append("Open: \(summary.open)")
            lines.append("Closed: \(summary.closed)")
            lines.append("Timed out: \(summary.timedOut)")
            lines.append("Unreachable: \(summary.unreachable)")
            lines.append("Failed: \(summary.failed)")
        }

        if !openResults.isEmpty {
            lines.append("")
            lines.append("Open ports:")
            for result in sortedOpenResults {
                guard case .open(
                    let address,
                    let family,
                    let milliseconds
                ) = result.outcome else {
                    continue
                }
                lines.append(
                    "  \(result.port)/tcp  open  "
                        + "\(address)  \(family.title)  "
                        + "\(format(milliseconds)) ms"
                )
            }
        }

        if let errorMessage {
            lines.append("")
            lines.append("Error: \(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }

    private func handle(
        _ event: TCPPortScanEvent,
        logStore: AppLogStore
    ) {
        switch event {
        case .started(let totalPorts):
            summary = TCPPortScanSummary(total: totalPorts)
            statusMessage = "正在扫描 0 / \(totalPorts)…"
        case .result(let result):
            guard var updatedSummary = summary else {
                return
            }
            updatedSummary.record(result)
            summary = updatedSummary
            if case .open = result.outcome {
                openResults.append(result)
            }
            statusMessage = "正在扫描 "
                + "\(updatedSummary.scanned) / "
                + "\(updatedSummary.total)…"
        case .failed(let message):
            errorMessage = message
            statusMessage = "失败"
            logStore.append(
                level: .error,
                message: "TCP 端口扫描失败：\(message)"
            )
        case .completed:
            didComplete = true
            statusMessage = "扫描完成"
            if let summary {
                logStore.append(
                    level: .info,
                    message: "TCP 端口扫描完成："
                        + "\(summary.scanned) 个端口，"
                        + "\(summary.open) 个开放"
                )
            }
        }
    }

    private func resetResults() {
        summary = nil
        openResults = []
        errorMessage = nil
        statusMessage = nil
        didComplete = false
        activeConfiguration = nil
        activePortExpression = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
