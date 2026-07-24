import Foundation
import NetToolCore
import Observation

@MainActor
@Observable
final class DNSViewModel {
    var name = "example.com"
    var recordType = DNSRecordType.a
    var transport = DNSTransport.udp
    var standardServer = "1.1.1.1"
    var standardPort = 53
    var tlsServer = "one.one.one.one"
    var tlsPort = 853
    var httpsURL = "https://cloudflare-dns.com/dns-query"
    var timeoutSeconds = 3.0
    var recursionDesired = true

    private(set) var result: DNSQueryResult?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var isStopping = false

    @ObservationIgnored
    private let client = DNSQueryClient()

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    var activeServer: String {
        switch transport {
        case .udp, .tcp:
            standardServer
        case .tls:
            tlsServer
        case .https:
            httpsURL
        }
    }

    var activePort: Int {
        switch transport {
        case .udp, .tcp:
            standardPort
        case .tls:
            tlsPort
        case .https:
            transport.defaultPort
        }
    }

    func start(logStore: AppLogStore) {
        guard !isRunning else {
            return
        }

        resetResult()

        let configuration: DNSQueryConfiguration
        do {
            configuration = try DNSQueryConfiguration(
                name: name,
                type: recordType,
                transport: transport,
                server: activeServer,
                port: activePort,
                timeoutSeconds: timeoutSeconds,
                recursionDesired: recursionDesired
            ).validated()

            _ = try DNSMessageCodec.makeQuery(
                identifier: 0,
                name: configuration.name,
                type: configuration.type,
                recursionDesired: configuration.recursionDesired
            )
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "参数错误"
            return
        }

        isRunning = true
        isStopping = false
        statusMessage = "正在查询…"
        logStore.append(
            level: .info,
            message: "开始 \(configuration.transport.title) DNS："
                + "\(configuration.name) "
                + "\(configuration.type.title) "
                + "@\(configuration.server)"
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
                let result = try await client.query(
                    configuration: configuration
                )
                try Task.checkCancellation()

                self.result = result
                self.statusMessage = result.message.flags.responseCodeName
                logStore.append(
                    level: .info,
                    message: "\(result.transport.title) DNS 完成："
                        + "\(result.message.flags.responseCodeName)，"
                        + "\(format(result.roundTripTimeMilliseconds)) ms，"
                        + "\(result.responseBytes.count) 字节"
                )
            } catch is CancellationError {
                self.statusMessage = "已取消"
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "失败"
                logStore.append(
                    level: .error,
                    message: "\(configuration.transport.title) DNS 失败："
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
            message: "取消 \(transport.title) DNS：\(name)"
        )
    }

    var exportText: String {
        guard let result else {
            if let errorMessage {
                return "Error: \(errorMessage)"
            }
            return ""
        }

        let message = result.message
        let flags = message.flags.activeNames.joined(separator: " ")
        var lines: [String] = [
            ";; ->>HEADER<<- opcode: \(message.flags.opcode), "
                + "status: \(message.flags.responseCodeName), "
                + "id: \(message.identifier)",
            ";; flags: \(flags); "
                + "QUERY: \(message.questions.count), "
                + "ANSWER: \(message.answers.count), "
                + "AUTHORITY: \(message.authorities.count), "
                + "ADDITIONAL: \(message.additionals.count)"
        ]

        if message.flags.isTruncated, result.transport == .udp {
            lines.append(
                ";; WARNING: UDP response is truncated; "
                    + "select TCP to retry."
            )
        }

        appendQuestions(message.questions, to: &lines)
        appendRecords(
            message.answers,
            title: "ANSWER",
            to: &lines
        )
        appendRecords(
            message.authorities,
            title: "AUTHORITY",
            to: &lines
        )
        appendRecords(
            message.additionals,
            title: "ADDITIONAL",
            to: &lines
        )

        lines.append("")
        lines.append(
            ";; Query time: "
                + "\(format(result.roundTripTimeMilliseconds)) msec"
        )
        lines.append(
            ";; SERVER: \(result.endpoint) (\(result.transport.title))"
        )
        if let httpStatusCode = result.httpStatusCode {
            lines.append(";; HTTP status: \(httpStatusCode)")
        }
        lines.append(
            ";; MSG SIZE  sent: \(result.queryBytes.count), "
                + "rcvd: \(result.responseBytes.count)"
        )
        lines.append("")
        lines.append(";; RAW QUERY:")
        lines.append(
            DNSMessageCodec.hexadecimalString(for: result.queryBytes)
        )
        lines.append("")
        lines.append(";; RAW RESPONSE:")
        lines.append(
            DNSMessageCodec.hexadecimalString(for: result.responseBytes)
        )

        return lines.joined(separator: "\n")
    }

    private func resetResult() {
        result = nil
        errorMessage = nil
        statusMessage = nil
    }

    private func appendQuestions(
        _ questions: [DNSQuestion],
        to lines: inout [String]
    ) {
        guard !questions.isEmpty else {
            return
        }

        lines.append("")
        lines.append(";; QUESTION SECTION:")
        for question in questions {
            lines.append(
                ";\(question.name)\t\(question.className)\t"
                    + question.typeName
            )
        }
    }

    private func appendRecords(
        _ records: [DNSResourceRecord],
        title: String,
        to lines: inout [String]
    ) {
        guard !records.isEmpty else {
            return
        }

        lines.append("")
        lines.append(";; \(title) SECTION:")
        for record in records {
            lines.append(
                "\(record.name)\t\(record.timeToLive)\t"
                    + "\(record.className)\t\(record.typeName)\t"
                    + record.data.displayValue
            )
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
