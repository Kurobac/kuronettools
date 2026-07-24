import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class TLSViewModel {
    var host = "www.apple.com"
    var port = 443
    var serverName = ""
    var addressFamily = TCPAddressFamily.automatic
    var timeoutSeconds = 5.0
    var allowsUntrustedCertificates = false
    var applicationProtocols = "h2,http/1.1"

    private(set) var result: TLSHandshakeResult?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = TLSInspectionClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResult()

        let configuration: TLSConfiguration
        do {
            configuration = try TLSConfiguration(
                host: host,
                port: port,
                serverName: serverName,
                addressFamily: addressFamily,
                timeoutSeconds: timeoutSeconds,
                allowsUntrustedCertificates:
                    allowsUntrustedCertificates,
                applicationProtocols: parsedApplicationProtocols
            ).validated()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        isRunning = true
        isStopping = false
        statusMessage = "正在进行 TLS 握手…"
        logStore.append(
            level: .info,
            message: "开始 TLS 检查："
                + "\(configuration.host):\(configuration.port)，"
                + "SNI \(configuration.effectiveServerName)"
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
                self.statusMessage = "握手成功"
                logStore.append(
                    level: .info,
                    message: "TLS 握手成功："
                        + "\(result.address):\(result.port)，"
                        + "\(result.protocolVersion)，"
                        + "\(format(result.handshakeTimeMilliseconds)) ms，"
                        + result.trustStatus.title
                )
            } catch is CancellationError {
                self.statusMessage = "已停止"
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "失败"
                logStore.append(
                    level: .error,
                    message: "TLS 检查失败："
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
            message: "取消 TLS 检查：\(host):\(port)"
        )
    }

    var exportText: String {
        if let result {
            var lines = [
                "TLS \(result.host):\(result.port)",
                "Status: connected",
                "Remote address: \(result.address)",
                "Address family: \(result.addressFamily.title)",
                "Server name: \(result.serverName)",
                "Handshake time: "
                    + "\(format(result.handshakeTimeMilliseconds)) ms",
                "TLS version: \(result.protocolVersion)",
                "Cipher suite: \(result.cipherSuite)",
                "ALPN: \(result.applicationProtocol ?? "none")",
                "Trust: \(trustDescription(result.trustStatus))"
            ]

            for certificate in result.certificates {
                lines.append("")
                lines.append("Certificate #\(certificate.index + 1)")
                lines.append("Subject: \(certificate.subject)")
                lines.append("Issuer: \(certificate.issuer)")
                lines.append(
                    "Not valid before: "
                        + certificate.notValidBefore.ISO8601Format()
                )
                lines.append(
                    "Not valid after: "
                        + certificate.notValidAfter.ISO8601Format()
                )
                lines.append("Serial: \(certificate.serialNumber)")
                lines.append("Public key: \(certificate.publicKey)")
                lines.append(
                    "Signature: \(certificate.signatureAlgorithm)"
                )
                lines.append(
                    "SHA-256: \(certificate.sha256Fingerprint)"
                )
                for name in certificate.subjectAlternativeNames {
                    lines.append("SAN: \(name)")
                }
            }

            return lines.joined(separator: "\n")
        }

        if let errorMessage {
            return [
                "TLS \(host):\(port)",
                "Status: failed",
                "Error: \(errorMessage)"
            ].joined(separator: "\n")
        }

        return ""
    }

    private var parsedApplicationProtocols: [String] {
        let value = applicationProtocols.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            return []
        }
        return value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private func resetResult() {
        result = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func trustDescription(
        _ status: TLSTrustStatus
    ) -> String {
        switch status {
        case .trusted:
            "trusted"
        case .untrusted(let message):
            "untrusted (\(message))"
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
