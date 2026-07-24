import Darwin
import Foundation
import NetToolCore
import Network
import Security

struct TLSInspectionClient: Sendable {
    func inspect(
        configuration: TLSConfiguration
    ) async throws -> TLSHandshakeResult {
        try Task.checkCancellation()

        let configuration = try configuration.validated()
        guard let port = NWEndpoint.Port(
            rawValue: UInt16(configuration.port)
        ) else {
            throw TLSInspectionClientError.invalidPort
        }

        let operation = try TLSInspectionOperation(
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

enum TLSInspectionClientError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidPort
    case timeout(seconds: Double)
    case dnsFailure(message: String)
    case connectionRefused
    case unreachable
    case untrustedCertificate(message: String)
    case missingIPOptions
    case missingTLSMetadata
    case missingTrustResult
    case missingCertificateChain
    case unexpectedAddressFamily(
        expected: TCPAddressFamily,
        actual: TCPAddressFamily
    )
    case network(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "端口无效。"
        case .timeout(let seconds):
            "TLS 握手在 \(seconds.formatted()) 秒后超时。"
        case .dnsFailure(let message):
            "DNS 解析失败：\(message)"
        case .connectionRefused:
            "目标主机拒绝了 TCP 连接。"
        case .unreachable:
            "目标主机或网络不可达。"
        case .untrustedCertificate(let message):
            "证书不受系统信任：\(message)"
        case .missingIPOptions:
            "系统没有提供 TLS 连接所需的 IP 协议选项。"
        case .missingTLSMetadata:
            "TLS 握手已完成，但系统没有提供握手元数据。"
        case .missingTrustResult:
            "TLS 握手已完成，但系统没有提供证书信任结果。"
        case .missingCertificateChain:
            "TLS 握手已完成，但系统没有提供证书链。"
        case .unexpectedAddressFamily(let expected, let actual):
            "实际建立了 \(actual.title) 连接，"
                + "与所选的 \(expected.title) 地址族不一致。"
        case .network(let message):
            "TLS 连接失败：\(message)"
        }
    }
}

private final class TLSInspectionOperation: @unchecked Sendable {
    private let configuration: TLSConfiguration
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let verificationCapture: TLSVerificationCapture
    private let stateLock = NSLock()

    private var continuation:
        CheckedContinuation<TLSHandshakeResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRequested = false
    private var didFinish = false
    private var startedAt: UInt64 = 0

    init(
        configuration: TLSConfiguration,
        port: NWEndpoint.Port
    ) throws {
        self.configuration = configuration

        let queue = DispatchQueue(
            label: "dev.kurobac.NetTool.TLSInspection"
        )
        self.queue = queue

        let verificationCapture = TLSVerificationCapture()
        self.verificationCapture = verificationCapture

        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(
            securityOptions,
            configuration.effectiveServerName
        )
        for applicationProtocol in
            configuration.applicationProtocols {
            sec_protocol_options_add_tls_application_protocol(
                securityOptions,
                applicationProtocol
            )
        }
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(
                    trust
                ).takeRetainedValue()
                let policy = SecPolicyCreateSSL(
                    true,
                    configuration.effectiveServerName as CFString
                )
                let policyStatus = SecTrustSetPolicies(
                    secTrust,
                    policy
                )

                guard policyStatus == errSecSuccess else {
                    let message =
                        SecCopyErrorMessageString(
                            policyStatus,
                            nil
                        ) as String?
                        ?? "OSStatus \(policyStatus)"
                    verificationCapture.store(
                        status: .untrusted(message: message),
                        trust: secTrust
                    )
                    complete(
                        configuration.allowsUntrustedCertificates
                    )
                    return
                }

                var trustError: CFError?
                let trusted = SecTrustEvaluateWithError(
                    secTrust,
                    &trustError
                )
                let trustStatus: TLSTrustStatus
                if trusted {
                    trustStatus = .trusted
                } else {
                    let message = trustError.map {
                        ($0 as Error).localizedDescription
                    } ?? "系统没有提供详细信任错误。"
                    trustStatus = .untrusted(message: message)
                }

                verificationCapture.store(
                    status: trustStatus,
                    trust: secTrust
                )
                complete(
                    trusted
                        || configuration
                            .allowsUntrustedCertificates
                )
            },
            queue
        )

        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        switch configuration.addressFamily {
        case .automatic:
            break
        case .ipv4, .ipv6:
            guard let ipOptions =
                    parameters.defaultProtocolStack.internetProtocol
                        as? NWProtocolIP.Options else {
                throw TLSInspectionClientError.missingIPOptions
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
        continuation:
            CheckedContinuation<TLSHandshakeResult, Error>
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
                throwing: TLSInspectionClientError.timeout(
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
                throwing: TLSInspectionClientError.network(
                    message: "未知的 Network.framework 状态。"
                )
            )
        }
    }

    private func makeResult() throws -> TLSHandshakeResult {
        guard let tlsMetadata = connection.metadata(
            definition: NWProtocolTLS.definition
        ) as? NWProtocolTLS.Metadata else {
            throw TLSInspectionClientError.missingTLSMetadata
        }
        guard let trustSnapshot = verificationCapture.snapshot else {
            throw TLSInspectionClientError.missingTrustResult
        }
        guard !trustSnapshot.derCertificates.isEmpty else {
            throw TLSInspectionClientError.missingCertificateChain
        }

        let remoteEndpoint = try makeRemoteEndpoint()
        if configuration.addressFamily != .automatic,
           configuration.addressFamily
                != remoteEndpoint.addressFamily {
            throw TLSInspectionClientError.unexpectedAddressFamily(
                expected: configuration.addressFamily,
                actual: remoteEndpoint.addressFamily
            )
        }

        let metadata = tlsMetadata.securityProtocolMetadata
        let protocolVersion = Self.protocolVersionDescription(
            sec_protocol_metadata_get_negotiated_tls_protocol_version(
                metadata
            )
        )
        let cipherSuite = Self.cipherSuiteDescription(
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(
                metadata
            )
        )
        let applicationProtocol = Self.copyCString(
            sec_protocol_metadata_copy_negotiated_protocol(metadata)
        )
        let certificates = try TLSCertificateParser.parse(
            derCertificates: trustSnapshot.derCertificates
        )
        let elapsed =
            DispatchTime.now().uptimeNanoseconds - startedAt

        return TLSHandshakeResult(
            host: configuration.host,
            address: remoteEndpoint.address,
            port: remoteEndpoint.port,
            addressFamily: remoteEndpoint.addressFamily,
            serverName: configuration.effectiveServerName,
            handshakeTimeMilliseconds:
                Double(elapsed) / 1_000_000,
            protocolVersion: protocolVersion,
            cipherSuite: cipherSuite,
            applicationProtocol: applicationProtocol,
            trustStatus: trustSnapshot.status,
            certificates: certificates
        )
    }

    private func makeRemoteEndpoint() throws -> (
        address: String,
        port: Int,
        addressFamily: TCPAddressFamily
    ) {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, let port) = endpoint else {
            throw TLSInspectionClientError.network(
                message: "系统没有提供实际远端地址。"
            )
        }

        switch host {
        case .ipv4(let address):
            return (
                address.debugDescription,
                Int(port.rawValue),
                .ipv4
            )
        case .ipv6(let address):
            return (
                address.debugDescription,
                Int(port.rawValue),
                .ipv6
            )
        case .name:
            throw TLSInspectionClientError.network(
                message: "实际远端地址仍是未解析的主机名。"
            )
        @unknown default:
            throw TLSInspectionClientError.network(
                message: "系统返回了未知的远端地址类型。"
            )
        }
    }

    private func clientError(
        from error: NWError
    ) -> TLSInspectionClientError {
        if let snapshot = verificationCapture.snapshot,
           case .untrusted(let message) = snapshot.status {
            return .untrustedCertificate(message: message)
        }

        return switch error {
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

    private static func protocolVersionDescription(
        _ version: tls_protocol_version_t
    ) -> String {
        switch UInt16(truncatingIfNeeded: version.rawValue) {
        case 0x0301:
            "TLS 1.0"
        case 0x0302:
            "TLS 1.1"
        case 0x0303:
            "TLS 1.2"
        case 0x0304:
            "TLS 1.3"
        default:
            String(
                format: "未知（0x%04X）",
                UInt16(truncatingIfNeeded: version.rawValue)
            )
        }
    }

    private static func cipherSuiteDescription(
        _ cipherSuite: tls_ciphersuite_t
    ) -> String {
        let rawValue = UInt16(
            truncatingIfNeeded: cipherSuite.rawValue
        )
        let names: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256",
            0x1302: "TLS_AES_256_GCM_SHA384",
            0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
            0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
        ]

        if let name = names[rawValue] {
            return "\(name)（0x\(String(format: "%04X", rawValue))）"
        }
        return String(format: "0x%04X", rawValue)
    }

    private static func copyCString(
        _ pointer: UnsafePointer<CChar>?
    ) -> String? {
        guard let pointer else {
            return nil
        }
        defer {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
        return String(cString: pointer)
    }

    private func finish(returning result: TLSHandshakeResult) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(
        with result: Result<TLSHandshakeResult, Error>
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

private final class TLSVerificationCapture: @unchecked Sendable {
    struct Snapshot: Sendable {
        let status: TLSTrustStatus
        let derCertificates: [Data]
    }

    private let lock = NSLock()
    private var storedSnapshot: Snapshot?

    var snapshot: Snapshot? {
        lock.withLock {
            storedSnapshot
        }
    }

    func store(
        status: TLSTrustStatus,
        trust: SecTrust
    ) {
        let certificates =
            SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            ?? []
        let derCertificates = certificates.map {
            SecCertificateCopyData($0) as Data
        }

        lock.withLock {
            storedSnapshot = Snapshot(
                status: status,
                derCertificates: derCertificates
            )
        }
    }
}
