import Foundation

public struct TLSConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let serverName: String?
    public let addressFamily: TCPAddressFamily
    public let timeoutSeconds: Double
    public let allowsUntrustedCertificates: Bool
    public let applicationProtocols: [String]

    public init(
        host: String,
        port: Int = 443,
        serverName: String? = nil,
        addressFamily: TCPAddressFamily = .automatic,
        timeoutSeconds: Double = 5,
        allowsUntrustedCertificates: Bool = false,
        applicationProtocols: [String] = []
    ) {
        self.host = host
        self.port = port
        self.serverName = serverName
        self.addressFamily = addressFamily
        self.timeoutSeconds = timeoutSeconds
        self.allowsUntrustedCertificates =
            allowsUntrustedCertificates
        self.applicationProtocols = applicationProtocols
    }

    public var effectiveServerName: String {
        serverName ?? host
    }

    public func validated() throws -> TLSConfiguration {
        let tcpConfiguration = try TCPConnectionConfiguration(
            host: host,
            port: port,
            addressFamily: addressFamily,
            timeoutSeconds: timeoutSeconds
        ).validated()
        let trimmedServerName = serverName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let validatedServerName = trimmedServerName.flatMap {
            $0.isEmpty ? nil : $0
        }
        let validatedProtocols = try applicationProtocols.map {
            let value = $0.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !value.isEmpty,
                  value.utf8.count <= 255,
                  value.utf8.allSatisfy({
                      (UInt8(0x21) ... UInt8(0x7E)).contains($0)
                  }) else {
                throw TLSConfigurationError.invalidApplicationProtocol(
                    $0
                )
            }
            return value
        }

        return TLSConfiguration(
            host: tcpConfiguration.host,
            port: tcpConfiguration.port,
            serverName: validatedServerName,
            addressFamily: tcpConfiguration.addressFamily,
            timeoutSeconds: tcpConfiguration.timeoutSeconds,
            allowsUntrustedCertificates:
                allowsUntrustedCertificates,
            applicationProtocols: validatedProtocols
        )
    }
}

public enum TLSConfigurationError:
    Error,
    Equatable,
    LocalizedError
{
    case invalidApplicationProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApplicationProtocol(let value):
            "ALPN 标识无效：\(value)"
        }
    }
}

public enum TLSTrustStatus: Equatable, Sendable {
    case trusted
    case untrusted(message: String)

    public var title: String {
        switch self {
        case .trusted:
            "系统信任"
        case .untrusted:
            "不受信任"
        }
    }
}

public struct TLSCertificateInfo:
    Equatable,
    Identifiable,
    Sendable
{
    public let index: Int
    public let subject: String
    public let issuer: String
    public let notValidBefore: Date
    public let notValidAfter: Date
    public let serialNumber: String
    public let subjectAlternativeNames: [String]
    public let publicKey: String
    public let signatureAlgorithm: String
    public let sha256Fingerprint: String

    public var id: Int { index }

    public init(
        index: Int,
        subject: String,
        issuer: String,
        notValidBefore: Date,
        notValidAfter: Date,
        serialNumber: String,
        subjectAlternativeNames: [String],
        publicKey: String,
        signatureAlgorithm: String,
        sha256Fingerprint: String
    ) {
        self.index = index
        self.subject = subject
        self.issuer = issuer
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.serialNumber = serialNumber
        self.subjectAlternativeNames = subjectAlternativeNames
        self.publicKey = publicKey
        self.signatureAlgorithm = signatureAlgorithm
        self.sha256Fingerprint = sha256Fingerprint
    }
}

public struct TLSHandshakeResult: Equatable, Sendable {
    public let host: String
    public let address: String
    public let port: Int
    public let addressFamily: TCPAddressFamily
    public let serverName: String
    public let handshakeTimeMilliseconds: Double
    public let protocolVersion: String
    public let cipherSuite: String
    public let applicationProtocol: String?
    public let trustStatus: TLSTrustStatus
    public let certificates: [TLSCertificateInfo]

    public init(
        host: String,
        address: String,
        port: Int,
        addressFamily: TCPAddressFamily,
        serverName: String,
        handshakeTimeMilliseconds: Double,
        protocolVersion: String,
        cipherSuite: String,
        applicationProtocol: String?,
        trustStatus: TLSTrustStatus,
        certificates: [TLSCertificateInfo]
    ) {
        self.host = host
        self.address = address
        self.port = port
        self.addressFamily = addressFamily
        self.serverName = serverName
        self.handshakeTimeMilliseconds =
            handshakeTimeMilliseconds
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.applicationProtocol = applicationProtocol
        self.trustStatus = trustStatus
        self.certificates = certificates
    }
}
