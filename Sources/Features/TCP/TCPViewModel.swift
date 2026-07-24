import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class TCPViewModel {
    var host = "1.1.1.1"
    var port = 443
    var addressFamily = TCPAddressFamily.automatic
    var timeoutSeconds = 3.0

    private(set) var result: TCPConnectionResult?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = TCPConnectionClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResult()

        let configuration: TCPConnectionConfiguration
        do {
            configuration = try TCPConnectionConfiguration(
                host: host,
                port: port,
                addressFamily: addressFamily,
                timeoutSeconds: timeoutSeconds
            ).validated()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        isRunning = true
        isStopping = false
        statusMessage = "正在连接…"
        logStore.append(
            level: .info,
            message: "开始 TCP 连接："
                + "\(configuration.host):\(configuration.port)"
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

            do {
                let result = try await client.connect(
                    configuration: configuration
                )
                try Task.checkCancellation()

                self.result = result
                self.statusMessage = "连接成功"
                logStore.append(
                    level: .info,
                    message: "TCP 连接成功："
                        + "\(result.address):\(result.port)，"
                        + "\(format(result.connectionTimeMilliseconds)) ms"
                )
            } catch is CancellationError {
                self.statusMessage = "已停止"
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "失败"
                let diagnosticContext =
                    (error as? TCPConnectionClientError)?
                        .timeoutOriginDescription
                        .map { "（来源：\($0)）" }
                    ?? ""
                logStore.append(
                    level: .error,
                    message: "TCP 连接失败："
                        + error.localizedDescription
                        + diagnosticContext
                )
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
            message: "取消 TCP 连接：\(host):\(port)"
        )
    }

    var exportText: String {
        if let result {
            return [
                "TCP CONNECT \(result.host):\(result.port)",
                "Status: connected",
                "Remote address: \(result.address)",
                "Address family: \(result.addressFamily.title)",
                "Connect time: "
                    + "\(format(result.connectionTimeMilliseconds)) ms"
            ].joined(separator: "\n")
        }

        if let errorMessage {
            return [
                "TCP CONNECT \(host):\(port)",
                "Status: failed",
                "Error: \(errorMessage)"
            ].joined(separator: "\n")
        }

        return ""
    }

    private func resetResult() {
        result = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
