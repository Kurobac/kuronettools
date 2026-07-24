import Foundation

public struct HTTPInspectionConfiguration: Equatable, Sendable {
    public let url: String
    public let followsRedirects: Bool
    public let timeoutSeconds: Double

    public init(
        url: String,
        followsRedirects: Bool = false,
        timeoutSeconds: Double = 10
    ) {
        self.url = url
        self.followsRedirects = followsRedirects
        self.timeoutSeconds = timeoutSeconds
    }

    public func validated() throws -> HTTPInspectionConfiguration {
        let trimmedURL = url.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedURL.isEmpty else {
            throw HTTPConfigurationError.emptyURL
        }
        guard var components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased() else {
            throw HTTPConfigurationError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw HTTPConfigurationError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw HTTPConfigurationError.missingHost
        }
        if let port = components.port,
           !(1 ... 65_535).contains(port) {
            throw HTTPConfigurationError.invalidPort
        }
        guard components.user == nil, components.password == nil else {
            throw HTTPConfigurationError.embeddedCredentials
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 60).contains(timeoutSeconds) else {
            throw HTTPConfigurationError.invalidTimeout
        }

        components.scheme = scheme
        components.fragment = nil
        guard let normalizedURL = components.url else {
            throw HTTPConfigurationError.invalidURL
        }

        return HTTPInspectionConfiguration(
            url: normalizedURL.absoluteString,
            followsRedirects: followsRedirects,
            timeoutSeconds: timeoutSeconds
        )
    }
}

public enum HTTPConfigurationError:
    Error,
    Equatable,
    LocalizedError
{
    case emptyURL
    case invalidURL
    case unsupportedScheme
    case missingHost
    case invalidPort
    case embeddedCredentials
    case invalidTimeout

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            "请输入 URL。"
        case .invalidURL:
            "URL 格式无效。"
        case .unsupportedScheme:
            "仅支持 HTTP 和 HTTPS URL。"
        case .missingHost:
            "URL 必须包含主机名。"
        case .invalidPort:
            "URL 端口必须在 1 到 65535 之间。"
        case .embeddedCredentials:
            "不支持在 URL 中嵌入用户名或密码。"
        case .invalidTimeout:
            "超时时间必须在 0.1 到 60 秒之间。"
        }
    }
}

public struct HTTPHeaderField: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPTransactionTiming: Equatable, Sendable {
    public let dnsMilliseconds: Double?
    public let tcpMilliseconds: Double?
    public let tlsMilliseconds: Double?
    public let timeToFirstByteMilliseconds: Double?
    public let totalMilliseconds: Double?

    public init(
        dnsMilliseconds: Double?,
        tcpMilliseconds: Double?,
        tlsMilliseconds: Double?,
        timeToFirstByteMilliseconds: Double?,
        totalMilliseconds: Double?
    ) {
        self.dnsMilliseconds = dnsMilliseconds
        self.tcpMilliseconds = tcpMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.timeToFirstByteMilliseconds =
            timeToFirstByteMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public enum HTTPResourceSource:
    String,
    Equatable,
    Sendable
{
    case network
    case serverPush
    case localCache
    case unknown

    public var title: String {
        switch self {
        case .network:
            "网络"
        case .serverPush:
            "服务器推送"
        case .localCache:
            "本地缓存"
        case .unknown:
            "未知"
        }
    }
}

public struct HTTPConnectionInfo: Equatable, Sendable {
    public let localAddress: String?
    public let localPort: Int?
    public let remoteAddress: String?
    public let remotePort: Int?
    public let tlsProtocolVersion: String?
    public let tlsCipherSuite: String?
    public let isReusedConnection: Bool
    public let isProxyConnection: Bool
    public let isCellular: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let resourceSource: HTTPResourceSource

    public init(
        localAddress: String?,
        localPort: Int?,
        remoteAddress: String?,
        remotePort: Int?,
        tlsProtocolVersion: String?,
        tlsCipherSuite: String?,
        isReusedConnection: Bool,
        isProxyConnection: Bool,
        isCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        resourceSource: HTTPResourceSource
    ) {
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tlsProtocolVersion = tlsProtocolVersion
        self.tlsCipherSuite = tlsCipherSuite
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
        self.isCellular = isCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.resourceSource = resourceSource
    }
}

public struct HTTPTransaction:
    Equatable,
    Identifiable,
    Sendable
{
    public let index: Int
    public let requestURL: String
    public let responseURL: String
    public let statusCode: Int
    public let networkProtocolName: String?
    public let headers: [HTTPHeaderField]
    public let requestHeaderBytesSent: Int64
    public let responseHeaderBytesReceived: Int64
    public let timing: HTTPTransactionTiming
    public let connection: HTTPConnectionInfo

    public var id: Int { index }

    public var protocolTitle: String {
        switch networkProtocolName?.lowercased() {
        case "http/1.0":
            "HTTP/1.0"
        case "http/1.1":
            "HTTP/1.1"
        case "h2":
            "HTTP/2"
        case "h3":
            "HTTP/3"
        case .some(let value):
            value
        case nil:
            "HTTP"
        }
    }

    public init(
        index: Int,
        requestURL: String,
        responseURL: String,
        statusCode: Int,
        networkProtocolName: String?,
        headers: [HTTPHeaderField],
        requestHeaderBytesSent: Int64,
        responseHeaderBytesReceived: Int64,
        timing: HTTPTransactionTiming,
        connection: HTTPConnectionInfo
    ) {
        self.index = index
        self.requestURL = requestURL
        self.responseURL = responseURL
        self.statusCode = statusCode
        self.networkProtocolName = networkProtocolName
        self.headers = headers
        self.requestHeaderBytesSent = requestHeaderBytesSent
        self.responseHeaderBytesReceived =
            responseHeaderBytesReceived
        self.timing = timing
        self.connection = connection
    }
}

public struct HTTPInspectionResult: Equatable, Sendable {
    public let originalURL: String
    public let finalURL: String
    public let redirectCount: Int
    public let timeToFirstByteMilliseconds: Double?
    public let totalMilliseconds: Double
    public let transactions: [HTTPTransaction]

    public var dnsMilliseconds: Double? {
        aggregate(\.dnsMilliseconds)
    }

    public var tcpMilliseconds: Double? {
        aggregate(\.tcpMilliseconds)
    }

    public var tlsMilliseconds: Double? {
        aggregate(\.tlsMilliseconds)
    }

    public init(
        originalURL: String,
        finalURL: String,
        redirectCount: Int,
        timeToFirstByteMilliseconds: Double?,
        totalMilliseconds: Double,
        transactions: [HTTPTransaction]
    ) {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.redirectCount = redirectCount
        self.timeToFirstByteMilliseconds =
            timeToFirstByteMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.transactions = transactions
    }

    private func aggregate(
        _ keyPath: KeyPath<HTTPTransactionTiming, Double?>
    ) -> Double? {
        let values = transactions.compactMap {
            $0.timing[keyPath: keyPath]
        }
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +)
    }
}
