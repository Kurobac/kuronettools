import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class HTTPViewModel {
    var url = "https://www.apple.com"
    var followsRedirects = false
    var timeoutSeconds = 10.0

    private(set) var result: HTTPInspectionResult?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = HTTPInspectionClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    var finalTransaction: HTTPTransaction? {
        result?.transactions.last
    }

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResult()

        let configuration: HTTPInspectionConfiguration
        do {
            configuration = try HTTPInspectionConfiguration(
                url: url,
                followsRedirects: followsRedirects,
                timeoutSeconds: timeoutSeconds
            ).validated()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        isRunning = true
        isStopping = false
        statusMessage = "正在发送 HEAD 请求…"
        logStore.append(
            level: .info,
            message: "开始 HTTP HEAD：\(configuration.url)"
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
                let result = try await client.inspect(
                    configuration: configuration
                )
                try Task.checkCancellation()

                self.result = result
                if let transaction = result.transactions.last {
                    self.statusMessage =
                        "\(transaction.protocolTitle) · "
                        + "\(transaction.statusCode)"
                    logStore.append(
                        level: .info,
                        message: "HTTP HEAD 完成："
                            + "\(transaction.statusCode)，"
                            + "\(format(result.totalMilliseconds)) ms，"
                            + "\(result.redirectCount) 次重定向"
                    )
                } else {
                    self.statusMessage = "已完成"
                }
            } catch is CancellationError {
                self.statusMessage = "已停止"
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "失败"
                logStore.append(
                    level: .error,
                    message: "HTTP HEAD 失败："
                        + error.localizedDescription
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
            message: "取消 HTTP HEAD：\(url)"
        )
    }

    func headerBlock(for transaction: HTTPTransaction) -> String {
        var lines = [
            "\(transaction.protocolTitle) \(transaction.statusCode)"
        ]
        lines.append(
            contentsOf: transaction.headers.map {
                "\($0.name): \($0.value)"
            }
        )
        return lines.joined(separator: "\n")
    }

    func headerBlocks(
        for result: HTTPInspectionResult
    ) -> String {
        result.transactions
            .map { headerBlock(for: $0) }
            .joined(separator: "\n\n")
    }

    var exportText: String {
        guard let result else {
            if let errorMessage {
                return [
                    "HEAD \(url)",
                    "Error: \(errorMessage)"
                ].joined(separator: "\n")
            }
            return ""
        }

        var lines = ["HEAD \(result.originalURL)"]
        if result.finalURL != result.originalURL {
            lines.append("Final URL: \(result.finalURL)")
        }
        lines.append("Redirects: \(result.redirectCount)")

        for transaction in result.transactions {
            lines.append("")
            lines.append(headerBlock(for: transaction))
        }

        lines.append("")
        lines.append("Timing:")
        lines.append(
            "  DNS: \(milliseconds(result.dnsMilliseconds))"
        )
        lines.append(
            "  TCP: \(milliseconds(result.tcpMilliseconds))"
        )
        lines.append(
            "  TLS: \(milliseconds(result.tlsMilliseconds))"
        )
        lines.append(
            "  Time to first byte: "
                + milliseconds(result.timeToFirstByteMilliseconds)
        )
        lines.append(
            "  Total: \(milliseconds(result.totalMilliseconds))"
        )

        if let transaction = result.transactions.last {
            let connection = transaction.connection
            lines.append("")
            lines.append(
                "Remote: "
                    + endpoint(
                        address: connection.remoteAddress,
                        port: connection.remotePort
                    )
            )
            lines.append(
                "Local: "
                    + endpoint(
                        address: connection.localAddress,
                        port: connection.localPort
                    )
            )
            lines.append(
                "Connection reused: "
                    + yesNo(connection.isReusedConnection)
            )
            lines.append(
                "Proxy: \(yesNo(connection.isProxyConnection))"
            )
        }

        return lines.joined(separator: "\n")
    }

    private func resetResult() {
        result = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        return String(format: "%.3f ms", value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func endpoint(
        address: String?,
        port: Int?
    ) -> String {
        guard let address else {
            return "—"
        }
        guard let port else {
            return address
        }
        if address.contains(":") {
            return "[\(address)]:\(port)"
        }
        return "\(address):\(port)"
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
