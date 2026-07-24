import Foundation
import NetToolCore
import Network
import Security

struct StreamDNSClient: Sendable {
    let usesTLS: Bool

    func exchange(
        configuration: DNSQueryConfiguration,
        queryBytes: [UInt8]
    ) async throws -> DNSExchange {
        try Task.checkCancellation()

        guard let port = NWEndpoint.Port(
            rawValue: UInt16(configuration.port)
        ) else {
            throw DNSClientError.invalidPort
        }

        let operation = StreamQueryOperation(
            configuration: configuration,
            framedQuery: try DNSStreamCodec.frame(queryBytes),
            port: port,
            usesTLS: usesTLS
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

private final class StreamQueryOperation: @unchecked Sendable {
    private let configuration: DNSQueryConfiguration
    private let framedQuery: [UInt8]
    private let transport: DNSTransport
    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "dev.kurobac.NetTool.StreamDNS"
    )
    private let stateLock = NSLock()

    private var continuation:
        CheckedContinuation<DNSExchange, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRequested = false
    private var didFinish = false
    private var didSend = false
    private var responseBuffer: [UInt8] = []
    private var startedAt: UInt64 = 0

    init(
        configuration: DNSQueryConfiguration,
        framedQuery: [UInt8],
        port: NWEndpoint.Port,
        usesTLS: Bool
    ) {
        self.configuration = configuration
        self.framedQuery = framedQuery
        self.transport = usesTLS ? .tls : .tcp

        let parameters: NWParameters
        if usesTLS {
            let tlsOptions = NWProtocolTLS.Options()
            if let tlsServerName = configuration.tlsServerName {
                sec_protocol_options_set_tls_server_name(
                    tlsOptions.securityProtocolOptions,
                    tlsServerName
                )
            }
            parameters = NWParameters(
                tls: tlsOptions,
                tcp: NWProtocolTCP.Options()
            )
        } else {
            parameters = .tcp
        }

        self.connection = NWConnection(
            host: NWEndpoint.Host(configuration.server),
            port: port,
            using: parameters
        )
    }

    func start(
        continuation: CheckedContinuation<DNSExchange, Error>
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
                throwing: DNSClientError.timeout(
                    transport: transport,
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
                throwing: DNSClientError.network(
                    transport: transport,
                    message: error.localizedDescription
                )
            )
        case .cancelled:
            finish(throwing: CancellationError())
        case .setup, .preparing:
            break
        @unknown default:
            finish(
                throwing: DNSClientError.network(
                    transport: transport,
                    message: "未知的 Network.framework 状态。"
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
            content: Data(framedQuery),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if let error {
                    finish(
                        throwing: DNSClientError.network(
                            transport: transport,
                            message: error.localizedDescription
                        )
                    )
                    return
                }
                receiveResponse()
            }
        )
    }

    private func receiveResponse() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Int(UInt16.max) + 2
        ) { [weak self] content, _, isComplete, error in
            guard let self else {
                return
            }
            if let error {
                finish(
                    throwing: DNSClientError.network(
                        transport: transport,
                        message: error.localizedDescription
                    )
                )
                return
            }
            if let content, !content.isEmpty {
                responseBuffer.append(contentsOf: content)
            }

            do {
                if let responseBytes =
                    try DNSStreamCodec.decodeSingleFrame(responseBuffer) {
                    let elapsed =
                        DispatchTime.now().uptimeNanoseconds - startedAt
                    finish(
                        returning: DNSExchange(
                            responseBytes: responseBytes,
                            endpoint: dnsHostPortDescription(
                                host: configuration.server,
                                port: configuration.port
                            ),
                            roundTripTimeMilliseconds:
                                Double(elapsed) / 1_000_000,
                            httpStatusCode: nil
                        )
                    )
                    return
                }
            } catch {
                finish(throwing: error)
                return
            }

            if isComplete {
                finish(throwing: DNSClientError.streamClosed)
            } else {
                receiveResponse()
            }
        }
    }

    private func finish(returning result: DNSExchange) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(
        with result: Result<DNSExchange, Error>
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
