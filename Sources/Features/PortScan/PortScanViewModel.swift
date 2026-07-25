import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class PortScanViewModel {
    var host = "1.1.1.1"
    var portExpression = "22,53,80,443,853,8080,8443"
    var addressFamily = TCPAddressFamily.automatic
    var timeoutSeconds = 2.0
    var maxRetries = 2

    private(set) var summary: TCPPortScanSummary?
    private(set) var timing: TCPPortScanTimingSnapshot?
    private(set) var openResults: [TCPPortScanResult] = []
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var didComplete = false
    private(set) var retryRound = 0
    private(set) var retryRoundCompleted = 0
    private(set) var retryRoundTotal = 0

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
                maxRetries: maxRetries
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
                + "最大并发 \(configuration.maxConcurrency)，"
                + "最大发起速率 \(configuration.maxStartRate) 次/秒，"
                + "超时重试 \(configuration.maxRetries) 次"
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
            "Maximum concurrency: \(configuration.maxConcurrency)",
            "Maximum start rate: "
                + "\(configuration.maxStartRate) connections/s",
            "Timeout retries: \(configuration.maxRetries)"
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
        if let timing {
            lines.append(
                "Final concurrency window: "
                    + "\(timing.currentParallelism)"
            )
            lines.append(
                "Peak concurrency window: "
                    + "\(timing.peakParallelism)"
            )
            lines.append(
                "Current start rate limit: "
                    + "\(timing.startRateLimit) connections/s"
            )
            lines.append(
                "Active connections: \(timing.activeConnections)"
            )
            lines.append(
                "Peak active connections: "
                    + "\(timing.peakActiveConnections)"
            )
            lines.append(
                "Retry attempts: \(timing.retryAttempts)"
            )
            lines.append(
                "Timeout attempts: \(timing.timeoutAttempts)"
            )
            lines.append(
                "App deadline timeouts: "
                    + "\(timing.appDeadlineTimeouts)"
            )
            lines.append(
                "System TCP timeouts: \(timing.systemTimeouts)"
            )
        }
        if retryRound > 0 {
            lines.append(
                "Retry round progress: "
                    + "\(retryRoundCompleted)/\(retryRoundTotal)"
            )
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
        case .started(let totalPorts, let timing):
            summary = TCPPortScanSummary(total: totalPorts)
            self.timing = timing
            updateRunningStatus()
        case .pathProbeStarted(let timing):
            self.timing = timing
            statusMessage = "正在检查路径状态…"
        case .retryRoundStarted(
            let retryNumber,
            let portCount,
            let timing
        ):
            self.timing = timing
            retryRound = retryNumber
            retryRoundCompleted = 0
            retryRoundTotal = portCount
            statusMessage = "500ms 后进行第 "
                + "\(retryNumber) 轮重试"
                + "（\(portCount) 个端口）…"
        case .retryRoundProgress(
            let retryNumber,
            let completed,
            let total,
            let timing
        ):
            self.timing = timing
            retryRound = retryNumber
            retryRoundCompleted = completed
            retryRoundTotal = total
            updateRunningStatus()
        case .result(let result, let timing):
            guard var updatedSummary = summary else {
                return
            }
            updatedSummary.record(result)
            summary = updatedSummary
            self.timing = timing
            if case .open = result.outcome {
                openResults.append(result)
            }
            updateRunningStatus()
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
                        + "\(summary.open) 个开放，"
                        + "\(timing?.retryAttempts ?? 0) 次重试"
                )
            }
        }
    }

    private func resetResults() {
        summary = nil
        timing = nil
        openResults = []
        errorMessage = nil
        statusMessage = nil
        didComplete = false
        retryRound = 0
        retryRoundCompleted = 0
        retryRoundTotal = 0
        activeConfiguration = nil
        activePortExpression = nil
    }

    private func updateRunningStatus() {
        guard let summary else {
            statusMessage = "正在准备扫描…"
            return
        }
        if retryRound > 0 {
            statusMessage = "正在进行第 \(retryRound) 轮重试 · "
                + "\(retryRoundCompleted) / \(retryRoundTotal)…"
        } else {
            statusMessage = "正在扫描 "
                + "\(summary.scanned) / \(summary.total)…"
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
