import Foundation
import NetToolCore

struct DoHDNSClient: Sendable {
    func exchange(
        configuration: DNSQueryConfiguration,
        queryBytes: [UInt8]
    ) async throws -> DNSExchange {
        try Task.checkCancellation()

        guard let url = URL(string: configuration.server) else {
            throw DNSConfigurationError.invalidHTTPSURL
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeoutSeconds
        )
        request.httpMethod = "POST"
        request.httpBody = Data(queryBytes)
        request.setValue(
            "application/dns-message",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "application/dns-message",
            forHTTPHeaderField: "Content-Type"
        )

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

        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.invalidateAndCancel()
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                  let finalURL = httpResponse.url else {
                throw DNSClientError.invalidHTTPResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw DNSClientError.httpStatus(httpResponse.statusCode)
            }

            let contentType = httpResponse.value(
                forHTTPHeaderField: "Content-Type"
            )
            let mediaType: String?
            if let contentType,
               let firstComponent = contentType.split(
                    separator: ";",
                    maxSplits: 1
               ).first {
                mediaType = String(firstComponent)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            } else {
                mediaType = nil
            }
            guard mediaType == "application/dns-message" else {
                throw DNSClientError.invalidContentType(contentType)
            }
            guard !data.isEmpty else {
                throw DNSClientError.emptyResponse(transport: .https)
            }

            let elapsed =
                DispatchTime.now().uptimeNanoseconds - startedAt
            return DNSExchange(
                responseBytes: Array(data),
                endpoint: finalURL.absoluteString,
                roundTripTimeMilliseconds:
                    Double(elapsed) / 1_000_000,
                httpStatusCode: httpResponse.statusCode
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            if error.code == .timedOut {
                throw DNSClientError.timeout(
                    transport: .https,
                    seconds: configuration.timeoutSeconds
                )
            }
            throw DNSClientError.network(
                transport: .https,
                message: error.localizedDescription
            )
        }
    }
}
