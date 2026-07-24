import Foundation
import NetToolCore
import Network

struct TCPConnectionClient: Sendable {
    func connect(
        configuration: TCPConnectionConfiguration
    ) async throws -> TCPConnectionResult {
        try Task.checkCancellation()

        let configuration = try configuration.validated()
        guard let port = NWEndpoint.Port(
            rawValue: UInt16(configuration.port)
        ) else {
            throw TCPConnectionClientError.invalidPort
        }

        let operation = try TCPConnectionOperation(
            configuration: configuration,
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

enum TCPConnectionClientError: Error, Equatable, LocalizedError {
    case invalidPort
    case timeout(seconds: Double)
    case dnsFailure(message: String)
    case connectionRefused
    case unreachable
    case missingIPOptions
    case missingRemoteEndpoint
    case network(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "端口无效。"
        case .timeout(let seconds):
            "TCP 连接在 \(seconds.formatted()) 秒后超时。"
        case .dnsFailure(let message):
            "DNS 解析失败：\(message)"
        case .connectionRefused:
            "目标主机拒绝了 TCP 连接。"
        case .unreachable:
            "目标主机或网络不可达。"
        case .missingIPOptions:
            "系统没有提供 TCP 连接所需的 IP 协议选项。"
        case .missingRemoteEndpoint:
            "连接已建立，但系统没有提供实际远端地址。"
        case .network(let message):
            "TCP 连接失败：\(message)"
        }
    }
}

private final class TCPConnectionOperation: @unchecked Sendable {
    private let configuration: TCPConnectionConfiguration
    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "dev.kurobac.NetTool.TCPConnect"
    )
    private let stateLock = NSLock()

    private var continuation:
        CheckedContinuation<TCPConnectionResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRequested = false
    private var didFinish = false
    private var startedAt: UInt64 = 0

    init(
        configuration: TCPConnectionConfiguration,
        port: NWEndpoint.Port
    ) throws {
        self.configuration = configuration

        let parameters = NWParameters.tcp
        switch configuration.addressFamily {
        case .automatic:
            break
        case .ipv4, .ipv6:
            guard let ipOptions =
                    parameters.defaultProtocolStack.internetProtocol
                        as? NWProtocolIP.Options else {
                throw TCPConnectionClientError.missingIPOptions
            }
            ipOptions.version = configuration.addressFamily == .ipv4
                ? .v4
                : .v6
        }

        self.connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
    }

    func start(
        continuation: CheckedContinuation<TCPConnectionResult, Error>
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
                throwing: TCPConnectionClientError.timeout(
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
            do {
                finish(returning: try makeResult())
            } catch {
                finish(throwing: error)
            }
        case .waiting(let error), .failed(let error):
            finish(throwing: clientError(from: error))
        case .cancelled:
            finish(throwing: CancellationError())
        case .setup, .preparing:
            break
        @unknown default:
            finish(
                throwing: TCPConnectionClientError.network(
                    message: "未知的 Network.framework 状态。"
                )
            )
        }
    }

    private func makeResult() throws -> TCPConnectionResult {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, let port) = endpoint else {
            throw TCPConnectionClientError.missingRemoteEndpoint
        }

        let address: String
        let addressFamily: TCPAddressFamily
        switch host {
        case .ipv4(let ipv4Address):
            address = ipv4Address.debugDescription
            addressFamily = .ipv4
        case .ipv6(let ipv6Address):
            address = ipv6Address.debugDescription
            addressFamily = .ipv6
        case .name:
            throw TCPConnectionClientError.missingRemoteEndpoint
        @unknown default:
            throw TCPConnectionClientError.missingRemoteEndpoint
        }

        let elapsed =
            DispatchTime.now().uptimeNanoseconds - startedAt
        return TCPConnectionResult(
            host: configuration.host,
            address: address,
            port: Int(port.rawValue),
            addressFamily: addressFamily,
            connectionTimeMilliseconds:
                Double(elapsed) / 1_000_000
        )
    }

    private func clientError(
        from error: NWError
    ) -> TCPConnectionClientError {
        switch error {
        case .dns:
            .dnsFailure(message: error.localizedDescription)
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                .connectionRefused
            case .ETIMEDOUT:
                .timeout(seconds: configuration.timeoutSeconds)
            case .EHOSTUNREACH, .ENETUNREACH:
                .unreachable
            default:
                .network(message: error.localizedDescription)
            }
        case .tls:
            .network(message: error.localizedDescription)
        case .wifiAware:
            .network(message: error.localizedDescription)
        @unknown default:
            .network(message: error.localizedDescription)
        }
    }

    private func finish(returning result: TCPConnectionResult) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(
        with result: Result<TCPConnectionResult, Error>
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
