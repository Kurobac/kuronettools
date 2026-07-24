import Foundation
import NetToolCore
import Observation

struct TracerouteHopItem: Equatable, Identifiable {
    let hop: Int
    var probes: [TracerouteProbeResult]

    var id: Int { hop }
}

@MainActor
@Observable
final class TracerouteViewModel {
    var host = "1.1.1.1"
    var addressFamily = PingAddressFamily.automatic
    var maxHops = 30
    var probesPerHop = 3
    var timeoutSeconds = 1.0

    private(set) var resolvedTarget: PingResolvedTarget?
    private(set) var hops: [TracerouteHopItem] = []
    private(set) var completionStatus:
        TracerouteCompletionStatus?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = DarwinTracerouteClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResults()

        let configuration: TracerouteConfiguration
        do {
            configuration = try TracerouteConfiguration(
                host: host,
                addressFamily: addressFamily,
                maxHops: maxHops,
                probesPerHop: probesPerHop,
                timeoutSeconds: timeoutSeconds
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
            message: "开始 Traceroute：\(configuration.host)"
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
        statusMessage = "正在停止…"
        runTask?.cancel()
        logStore.append(
            level: .warning,
            message: "取消 Traceroute：\(host)"
        )
    }

    var exportText: String {
        var lines: [String] = []
        if let resolvedTarget {
            lines.append(
                "traceroute to \(resolvedTarget.host) "
                    + "(\(resolvedTarget.address)), "
                    + "\(maxHops) hops max"
            )
        }

        for hop in hops {
            var parts = [String(format: "%2d", hop.hop)]
            var previousAddress: String?

            for probe in hop.probes {
                switch probe {
                case .response(let response):
                    if response.address != previousAddress {
                        parts.append(response.address)
                        previousAddress = response.address
                    }
                    parts.append(
                        "\(format(response.roundTripTimeMilliseconds)) ms"
                    )
                case .timeout:
                    parts.append("*")
                }
            }

            lines.append(parts.joined(separator: "  "))
        }

        if let completionStatus {
            lines.append("")
            lines.append(completionStatus.title)
        }
        if let errorMessage {
            lines.append("Error: \(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }

    private func handle(
        _ event: TracerouteEvent,
        logStore: AppLogStore
    ) {
        switch event {
        case .started(let target):
            resolvedTarget = target
            statusMessage = "\(target.family.title) · \(target.address)"
        case .probe(let result):
            append(result)
            statusMessage = "正在探测第 \(hopNumber(of: result)) 跳…"
        case .failed(let message):
            errorMessage = message
            statusMessage = "失败"
            logStore.append(
                level: .error,
                message: "Traceroute 失败：\(message)"
            )
        case .completed(let status):
            completionStatus = status
            statusMessage = status.title
            logStore.append(
                level: .info,
                message: "Traceroute 完成：\(status.title)"
            )
        }
    }

    private func append(
        _ result: TracerouteProbeResult
    ) {
        let hop = hopNumber(of: result)
        if let index = hops.firstIndex(where: { $0.hop == hop }) {
            hops[index].probes.append(result)
        } else {
            hops.append(
                TracerouteHopItem(
                    hop: hop,
                    probes: [result]
                )
            )
        }
    }

    private func hopNumber(
        of result: TracerouteProbeResult
    ) -> Int {
        switch result {
        case .response(let response):
            response.hop
        case .timeout(let hop, _, _):
            hop
        }
    }

    private func resetResults() {
        resolvedTarget = nil
        hops = []
        completionStatus = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
