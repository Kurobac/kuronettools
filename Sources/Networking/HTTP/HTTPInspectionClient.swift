import Foundation
import NetToolCore
import Security

struct HTTPInspectionClient: Sendable {
    func inspect(
        configuration: HTTPInspectionConfiguration
    ) async throws -> HTTPInspectionResult {
        try Task.checkCancellation()

        let configuration = try configuration.validated()
        guard let url = URL(string: configuration.url) else {
            throw HTTPInspectionClientError.invalidURL
        }

        let operation = HTTPInspectionOperation(
            configuration: configuration,
            url: url
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

enum HTTPInspectionClientError:
    Error,
    LocalizedError,
    Sendable
{
    case invalidURL
    case missingHTTPResponse
    case missingMetrics
    case missingTransactions
    case timeout(seconds: Double)
    case network(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "URL 格式无效。"
        case .missingHTTPResponse:
            "服务器没有返回有效的 HTTP 响应。"
        case .missingMetrics:
            "请求已结束，但系统没有提供任务性能指标。"
        case .missingTransactions:
            "系统指标中没有完整的 HTTP 请求与响应事务。"
        case .timeout(let seconds):
            "HTTP HEAD 请求在 \(seconds.formatted()) 秒后超时。"
        case .network(let message):
            "HTTP HEAD 请求失败：\(message)"
        }
    }
}

private final class HTTPInspectionOperation:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let configuration: HTTPInspectionConfiguration
    private let url: URL
    private let stateLock = NSLock()

    private var continuation:
        CheckedContinuation<HTTPInspectionResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var metrics: URLSessionTaskMetrics?
    private var cancellationRequested = false
    private var didFinish = false

    private func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest =
            configuration.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource =
            configuration.timeoutSeconds
        sessionConfiguration.requestCachePolicy =
            .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false

        let queue = OperationQueue()
        queue.name = "dev.kurobac.NetTool.HTTPInspection"
        queue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: queue
        )
    }

    init(
        configuration: HTTPInspectionConfiguration,
        url: URL
    ) {
        self.configuration = configuration
        self.url = url
    }

    func start(
        continuation:
            CheckedContinuation<HTTPInspectionResult, Error>
    ) {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeoutSeconds
        )
        request.httpMethod = "HEAD"
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let session = makeSession()
        let task = session.dataTask(with: request)

        stateLock.lock()
        if cancellationRequested {
            stateLock.unlock()
            session.invalidateAndCancel()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.session = session
        self.task = task
        stateLock.unlock()

        task.resume()
    }

    func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let task = task
        stateLock.unlock()

        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard configuration.followsRedirects else {
            completionHandler(nil)
            return
        }

        var headRequest = request
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        completionHandler(headRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        stateLock.lock()
        self.metrics = metrics
        stateLock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(throwing: clientError(from: error))
            return
        }

        guard let response = task.response as? HTTPURLResponse,
              let finalURL = response.url else {
            finish(
                throwing:
                    HTTPInspectionClientError.missingHTTPResponse
            )
            return
        }

        stateLock.lock()
        let metrics = metrics
        stateLock.unlock()

        guard let metrics else {
            finish(
                throwing: HTTPInspectionClientError.missingMetrics
            )
            return
        }

        do {
            finish(
                returning: try Self.makeResult(
                    configuration: configuration,
                    finalURL: finalURL,
                    metrics: metrics
                )
            )
        } catch {
            finish(throwing: error)
        }
    }

    private func clientError(from error: Error) -> Error {
        stateLock.lock()
        let cancellationRequested = self.cancellationRequested
        stateLock.unlock()

        if cancellationRequested {
            return CancellationError()
        }
        guard let urlError = error as? URLError else {
            return HTTPInspectionClientError.network(
                message: error.localizedDescription
            )
        }
        if urlError.code == .cancelled, Task.isCancelled {
            return CancellationError()
        }
        if urlError.code == .timedOut {
            return HTTPInspectionClientError.timeout(
                seconds: configuration.timeoutSeconds
            )
        }
        return HTTPInspectionClientError.network(
            message: urlError.localizedDescription
        )
    }

    private static func makeResult(
        configuration: HTTPInspectionConfiguration,
        finalURL: URL,
        metrics: URLSessionTaskMetrics
    ) throws -> HTTPInspectionResult {
        let transactions = metrics.transactionMetrics
            .enumerated()
            .compactMap { index, metrics in
                makeTransaction(index: index, metrics: metrics)
            }
        guard !transactions.isEmpty else {
            throw HTTPInspectionClientError.missingTransactions
        }
        let finalResponseStart = metrics.transactionMetrics
            .last {
                $0.response is HTTPURLResponse
            }?
            .responseStartDate

        return HTTPInspectionResult(
            originalURL: configuration.url,
            finalURL: finalURL.absoluteString,
            redirectCount: metrics.redirectCount,
            timeToFirstByteMilliseconds: milliseconds(
                from: metrics.taskInterval.start,
                to: finalResponseStart
            ),
            totalMilliseconds:
                metrics.taskInterval.duration * 1_000,
            transactions: transactions
        )
    }

    private static func makeTransaction(
        index: Int,
        metrics: URLSessionTaskTransactionMetrics
    ) -> HTTPTransaction? {
        guard let requestURL = metrics.request.url,
              let response = metrics.response as? HTTPURLResponse,
              let responseURL = response.url else {
            return nil
        }

        let headers = response.allHeaderFields.compactMap {
            key,
            value -> HTTPHeaderField? in
            guard let name = key as? String else {
                return nil
            }
            return HTTPHeaderField(
                name: name,
                value: String(describing: value)
            )
        }.sorted {
            let left = $0.name.lowercased()
            let right = $1.name.lowercased()
            if left == right {
                return $0.value < $1.value
            }
            return left < right
        }

        let tcpEnd = metrics.secureConnectionStartDate
            ?? metrics.connectEndDate
        let timing = HTTPTransactionTiming(
            dnsMilliseconds: milliseconds(
                from: metrics.domainLookupStartDate,
                to: metrics.domainLookupEndDate
            ),
            tcpMilliseconds: milliseconds(
                from: metrics.connectStartDate,
                to: tcpEnd
            ),
            tlsMilliseconds: milliseconds(
                from: metrics.secureConnectionStartDate,
                to: metrics.secureConnectionEndDate
            ),
            timeToFirstByteMilliseconds: milliseconds(
                from: metrics.fetchStartDate,
                to: metrics.responseStartDate
            ),
            totalMilliseconds: milliseconds(
                from: metrics.fetchStartDate,
                to: metrics.responseEndDate
            )
        )

        return HTTPTransaction(
            index: index,
            requestURL: requestURL.absoluteString,
            responseURL: responseURL.absoluteString,
            statusCode: response.statusCode,
            networkProtocolName: metrics.networkProtocolName,
            headers: headers,
            requestHeaderBytesSent:
                metrics.countOfRequestHeaderBytesSent,
            responseHeaderBytesReceived:
                metrics.countOfResponseHeaderBytesReceived,
            timing: timing,
            connection: HTTPConnectionInfo(
                localAddress: metrics.localAddress,
                localPort: metrics.localPort,
                remoteAddress: metrics.remoteAddress,
                remotePort: metrics.remotePort,
                tlsProtocolVersion: metrics
                    .negotiatedTLSProtocolVersion
                    .map { tlsVersionDescription($0) },
                tlsCipherSuite: metrics.negotiatedTLSCipherSuite
                    .map { tlsCipherSuiteDescription($0) },
                isReusedConnection: metrics.isReusedConnection,
                isProxyConnection: metrics.isProxyConnection,
                isCellular: metrics.isCellular,
                isExpensive: metrics.isExpensive,
                isConstrained: metrics.isConstrained,
                resourceSource: resourceSource(
                    for: metrics.resourceFetchType
                )
            )
        )
    }

    private static func milliseconds(
        from start: Date?,
        to end: Date?
    ) -> Double? {
        guard let start, let end, end >= start else {
            return nil
        }
        return end.timeIntervalSince(start) * 1_000
    }

    private static func milliseconds(
        from start: Date,
        to end: Date?
    ) -> Double? {
        milliseconds(from: Optional(start), to: end)
    }

    private static func resourceSource(
        for type: URLSessionTaskMetrics.ResourceFetchType
    ) -> HTTPResourceSource {
        switch type {
        case .networkLoad:
            .network
        case .serverPush:
            .serverPush
        case .localCache:
            .localCache
        case .unknown:
            .unknown
        @unknown default:
            .unknown
        }
    }

    private static func tlsVersionDescription(
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
                format: "0x%04X",
                UInt16(truncatingIfNeeded: version.rawValue)
            )
        }
    }

    private static func tlsCipherSuiteDescription(
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

        return names[rawValue] ?? String(
            format: "0x%04X",
            rawValue
        )
    }

    private func finish(
        returning result: HTTPInspectionResult
    ) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(
        with result: Result<HTTPInspectionResult, Error>
    ) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        self.task = nil
        stateLock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
