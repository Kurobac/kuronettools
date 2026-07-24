import Foundation
import NetToolCore

struct DNSQueryResult: Sendable {
    let message: DNSMessage
    let queryBytes: [UInt8]
    let responseBytes: [UInt8]
    let transport: DNSTransport
    let endpoint: String
    let roundTripTimeMilliseconds: Double
    let httpStatusCode: Int?
}

struct DNSExchange: Sendable {
    let responseBytes: [UInt8]
    let endpoint: String
    let roundTripTimeMilliseconds: Double
    let httpStatusCode: Int?
}

enum DNSClientError: Error, LocalizedError, Sendable {
    case invalidPort
    case timeout(transport: DNSTransport, seconds: Double)
    case network(transport: DNSTransport, message: String)
    case emptyResponse(transport: DNSTransport)
    case streamClosed
    case unexpectedIdentifier(expected: UInt16, actual: UInt16)
    case notAResponse
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidContentType(String?)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "DNS 端口无效。"
        case .timeout(let transport, let seconds):
            "\(transport.title) DNS 查询在 \(seconds) 秒后超时。"
        case .network(let transport, let message):
            "\(transport.title) DNS 网络错误：\(message)"
        case .emptyResponse(let transport):
            "\(transport.title) DNS 服务器返回了空响应。"
        case .streamClosed:
            "TCP DNS 流在完整响应到达前关闭。"
        case .unexpectedIdentifier(let expected, let actual):
            "DNS 响应 ID 不匹配：期望 \(expected)，实际 \(actual)。"
        case .notAResponse:
            "收到的 DNS 报文未设置响应标志。"
        case .invalidHTTPResponse:
            "DoH 端点没有返回有效的 HTTP 响应。"
        case .httpStatus(let statusCode):
            "DoH 端点返回 HTTP \(statusCode)。"
        case .invalidContentType(let contentType):
            if let contentType {
                "DoH 响应 Content-Type 无效：\(contentType)。"
            } else {
                "DoH 响应缺少 Content-Type。"
            }
        }
    }
}

struct DNSQueryClient: Sendable {
    func query(
        configuration: DNSQueryConfiguration
    ) async throws -> DNSQueryResult {
        try Task.checkCancellation()

        let configuration = try configuration.validated()
        let identifier: UInt16 = configuration.transport == .https
            ? 0
            : UInt16.random(in: UInt16.min ... UInt16.max)
        let queryBytes = try DNSMessageCodec.makeQuery(
            identifier: identifier,
            name: configuration.name,
            type: configuration.type,
            recursionDesired: configuration.recursionDesired
        )

        let exchange: DNSExchange
        switch configuration.transport {
        case .udp:
            exchange = try await UDPDNSClient().exchange(
                configuration: configuration,
                queryBytes: queryBytes
            )
        case .tcp:
            exchange = try await StreamDNSClient(
                usesTLS: false
            ).exchange(
                configuration: configuration,
                queryBytes: queryBytes
            )
        case .tls:
            exchange = try await StreamDNSClient(
                usesTLS: true
            ).exchange(
                configuration: configuration,
                queryBytes: queryBytes
            )
        case .https:
            exchange = try await DoHDNSClient().exchange(
                configuration: configuration,
                queryBytes: queryBytes
            )
        }

        let message = try DNSMessageCodec.parse(exchange.responseBytes)
        guard message.identifier == identifier else {
            throw DNSClientError.unexpectedIdentifier(
                expected: identifier,
                actual: message.identifier
            )
        }
        guard message.flags.isResponse else {
            throw DNSClientError.notAResponse
        }

        return DNSQueryResult(
            message: message,
            queryBytes: queryBytes,
            responseBytes: exchange.responseBytes,
            transport: configuration.transport,
            endpoint: exchange.endpoint,
            roundTripTimeMilliseconds:
                exchange.roundTripTimeMilliseconds,
            httpStatusCode: exchange.httpStatusCode
        )
    }
}

func dnsHostPortDescription(host: String, port: Int) -> String {
    if host.contains(":"),
       !host.hasPrefix("["),
       !host.hasSuffix("]") {
        return "[\(host)]:\(port)"
    }
    return "\(host):\(port)"
}
