import Foundation
import NetToolCore
import Network

struct UDPDNSResult: Sendable {
    let message: DNSMessage
    let queryBytes: [UInt8]
    let responseBytes: [UInt8]
    let server: String
    let port: Int
    let roundTripTimeMilliseconds: Double
}

struct UDPDNSClient: Sendable {
    func query(
        configuration: DNSQueryConfiguration
    ) async throws -> UDPDNSResult {
        try Task.checkCancellation()

        let configuration = try configuration.validated()
        let identifier = UInt16.random(in: UInt16.min ... UInt16.max)
        let queryBytes = try DNSMessageCodec.makeQuery(
            identifier: identifier,
            name: configuration.name,
            type: configuration.type,
            recursionDesired: configuration.recursionDesired
        )
        guard let port = NWEndpoint.Port(
            rawValue: UInt16(configuration.port)
        ) else {
            throw ClientError.invalidPort
        }

        let operation = UDPQueryOperation(
            configuration: configuration,
            identifier: identifier,
            queryBytes: queryBytes,
            port: port
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private extension UDPDNSClient {
    enum ClientError: Error, LocalizedError {
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                "DNS 端口无效。"
            }
        }
    }
}

private final class UDPQueryOperation: @unchecked Sendable {
    private enum OperationError: Error, LocalizedError {
        case timeout(seconds: Double)
        case network(String)
        case emptyResponse
        case unexpectedIdentifier(expected: UInt16, actual: UInt16)
        case notAResponse

        var errorDescription: String? {
            switch self {
            case .timeout(let seconds):
                "UDP DNS 查询在 \(seconds) 秒后超时。"
            case .network(let message):
                "UDP DNS 网络错误：\(message)"
            case .emptyResponse:
                "DNS 服务器返回了空 UDP 数据报。"
            case .unexpectedIdentifier(let expected, let actual):
                "DNS 响应 ID 不匹配：期望 \(expected)，实际 \(actual)。"
            case .notAResponse:
                "收到的 DNS 报文未设置响应标志。"
            }
        }
    }

    private let configuration: DNSQueryConfiguration
    private let identifier: UInt16
    private let queryBytes: [UInt8]
    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "dev.kurobac.NetTool.UDPDNS"
    )
    private let stateLock = NSLock()

    private var continuation:
        CheckedContinuation<UDPDNSResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRequested = false
    private var didFinish = false
    private var didSend = false
    private var startedAt: UInt64 = 0

    init(
        configuration: DNSQueryConfiguration,
        identifier: UInt16,
        queryBytes: [UInt8],
        port: NWEndpoint.Port
    ) {
        self.configuration = configuration
        self.identifier = identifier
        self.queryBytes = queryBytes
        self.connection = NWConnection(
            host: NWEndpoint.Host(configuration.server),
            port: port,
            using: .udp
        )
    }

    func start(
        continuation: CheckedContinuation<UDPDNSResult, Error>
    ) {
        stateLock.lock()
        if cancellationRequested {
            stateLock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        stateLock.unlock()

        startedAt = DispatchTime.now().uptimeNanoseconds
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            finish(
                throwing: OperationError.timeout(
                    seconds: configuration.timeoutSeconds
                )
            )
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(
            deadline: .now() + configuration.timeoutSeconds,
            execute: timeoutWorkItem
        )
        connection.start(queue: queue)
    }

    func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let shouldFinish = continuation != nil && !didFinish
        stateLock.unlock()

        if shouldFinish {
            finish(throwing: CancellationError())
        } else {
            connection.cancel()
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            sendQueryIfNeeded()
        case .waiting(let error), .failed(let error):
            finish(
                throwing: OperationError.network(
                    error.localizedDescription
                )
            )
        case .cancelled:
            finish(throwing: CancellationError())
        case .setup, .preparing:
            break
        @unknown default:
            finish(
                throwing: OperationError.network(
                    "未知的 Network.framework 状态。"
                )
            )
        }
    }

    private func sendQueryIfNeeded() {
        guard !didSend else {
            return
        }
        didSend = true

        connection.send(
            content: Data(queryBytes),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if let error {
                    finish(
                        throwing: OperationError.network(
                            error.localizedDescription
                        )
                    )
                    return
                }
                receiveResponse()
            }
        )
    }

    private func receiveResponse() {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else {
                return
            }
            if let error {
                finish(
                    throwing: OperationError.network(
                        error.localizedDescription
                    )
                )
                return
            }
            guard let content, !content.isEmpty else {
                finish(throwing: OperationError.emptyResponse)
                return
            }

            do {
                let responseBytes = Array(content)
                let message = try DNSMessageCodec.parse(responseBytes)
                guard message.identifier == identifier else {
                    throw OperationError.unexpectedIdentifier(
                        expected: identifier,
                        actual: message.identifier
                    )
                }
                guard message.flags.isResponse else {
                    throw OperationError.notAResponse
                }

                let elapsed =
                    DispatchTime.now().uptimeNanoseconds - startedAt
                finish(
                    returning: UDPDNSResult(
                        message: message,
                        queryBytes: queryBytes,
                        responseBytes: responseBytes,
                        server: configuration.server,
                        port: configuration.port,
                        roundTripTimeMilliseconds:
                            Double(elapsed) / 1_000_000
                    )
                )
            } catch {
                finish(throwing: error)
            }
        }
    }

    private func finish(returning result: UDPDNSResult) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(
        with result: Result<UDPDNSResult, Error>
    ) {
        stateLock.lock()
        guard !didFinish, let continuation else {
            stateLock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        stateLock.unlock()

        timeoutWorkItem?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
