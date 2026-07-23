import Foundation
import NetToolCore
import Observation

struct PingResultItem: Identifiable, Equatable {
    enum Result: Equatable {
        case reply(PingReply)
        case timeout(sequence: UInt16)
    }

    let id = UUID()
    let result: Result
}

@MainActor
@Observable
final class PingViewModel {
    var host = "1.1.1.1"
    var addressFamily = PingAddressFamily.automatic
    var count = 4
    var intervalSeconds = 1.0
    var timeoutSeconds = 2.0
    var payloadSize = 56

    private(set) var resolvedTarget: PingResolvedTarget?
    private(set) var results: [PingResultItem] = []
    private(set) var summary: PingSummary?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = DarwinPingClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResults()

        let configuration: PingConfiguration
        do {
            configuration = try PingConfiguration(
                host: host,
                addressFamily: addressFamily,
                count: count,
                intervalSeconds: intervalSeconds,
                timeoutSeconds: timeoutSeconds,
                payloadSize: payloadSize
            ).validated()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        isRunning = true
        isStopping = false
        statusMessage = "正在解析目标…"
        logStore.append(
            level: .info,
            message: "开始 Ping：\(configuration.host)"
        )

        let client = client
        runTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.isRunning = false
                self.isStopping = false
                self.runTask = nil
            }

            for await event in client.events(for: configuration) {
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
        runTask?.cancel()
        statusMessage = "正在停止…"
        logStore.append(
            level: .warning,
            message: "取消 Ping：\(host)"
        )
    }

    var exportText: String {
        var lines: [String] = []

        if let resolvedTarget {
            lines.append(
                "PING \(resolvedTarget.host) (\(resolvedTarget.address)): "
                    + "\(payloadSize) data bytes"
            )
        }

        for item in results {
            switch item.result {
            case .reply(let reply):
                lines.append(
                    "\(reply.byteCount) bytes from \(reply.address): "
                        + "icmp_seq=\(reply.sequence) "
                        + "ttl=\(reply.hopLimit) "
                        + "time=\(format(reply.roundTripTimeMilliseconds)) ms"
                )
            case .timeout(let sequence):
                lines.append(
                    "Request timeout for icmp_seq \(sequence)"
                )
            }
        }

        if let summary {
            lines.append("")
            let targetHost = resolvedTarget?.host ?? host
            lines.append("--- \(targetHost) ping statistics ---")
            lines.append(
                "\(summary.transmitted) packets transmitted, "
                    + "\(summary.received) packets received, "
                    + "\(format(summary.lossPercentage))% packet loss"
            )

            if let minimum = summary.minimumMilliseconds,
               let average = summary.averageMilliseconds,
               let maximum = summary.maximumMilliseconds,
               let deviation = summary.meanDeviationMilliseconds {
                lines.append(
                    "round-trip min/avg/max/mdev = "
                        + "\(format(minimum))/\(format(average))/"
                        + "\(format(maximum))/\(format(deviation)) ms"
                )
            }
        }

        if let errorMessage {
            lines.append("Error: \(errorMessage)")
        }

        return lines.joined(separator: "\n")
    }

    private func handle(
        _ event: PingEvent,
        logStore: AppLogStore
    ) {
        switch event {
        case .started(let target):
            resolvedTarget = target
            statusMessage = "\(target.family.title) · \(target.address)"
        case .reply(let reply):
            results.append(
                PingResultItem(result: .reply(reply))
            )
        case .timeout(let sequence):
            results.append(
                PingResultItem(result: .timeout(sequence: sequence))
            )
        case .failed(let message):
            errorMessage = message
            statusMessage = "失败"
            logStore.append(
                level: .error,
                message: "Ping 失败：\(message)"
            )
        case .completed(let summary):
            self.summary = summary
            statusMessage = "已完成"
            logStore.append(
                level: .info,
                message: "Ping 完成：发送 \(summary.transmitted)，"
                    + "接收 \(summary.received)，"
                    + "丢包 \(format(summary.lossPercentage))%"
            )
        }
    }

    private func resetResults() {
        resolvedTarget = nil
        results = []
        summary = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
