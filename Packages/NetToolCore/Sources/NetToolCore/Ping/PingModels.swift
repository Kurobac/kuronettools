import Foundation

public enum PingAddressFamily:
    String,
    CaseIterable,
    Equatable,
    Identifiable,
    Sendable
{
    case automatic
    case ipv4
    case ipv6

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic:
            "自动"
        case .ipv4:
            "IPv4"
        case .ipv6:
            "IPv6"
        }
    }
}

public struct PingConfiguration: Equatable, Sendable {
    public let host: String
    public let addressFamily: PingAddressFamily
    public let count: Int
    public let intervalSeconds: Double
    public let timeoutSeconds: Double
    public let payloadSize: Int

    public init(
        host: String,
        addressFamily: PingAddressFamily = .automatic,
        count: Int = 4,
        intervalSeconds: Double = 1,
        timeoutSeconds: Double = 2,
        payloadSize: Int = 56
    ) {
        self.host = host
        self.addressFamily = addressFamily
        self.count = count
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.payloadSize = payloadSize
    }

    public func validated() throws -> PingConfiguration {
        let trimmedHost = host.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedHost.isEmpty else {
            throw PingConfigurationError.emptyHost
        }
        guard (1 ... 100).contains(count) else {
            throw PingConfigurationError.invalidCount
        }
        guard intervalSeconds.isFinite,
              (0.1 ... 10).contains(intervalSeconds) else {
            throw PingConfigurationError.invalidInterval
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 30).contains(timeoutSeconds) else {
            throw PingConfigurationError.invalidTimeout
        }
        guard (0 ... 1_400).contains(payloadSize) else {
            throw PingConfigurationError.invalidPayloadSize
        }

        return PingConfiguration(
            host: trimmedHost,
            addressFamily: addressFamily,
            count: count,
            intervalSeconds: intervalSeconds,
            timeoutSeconds: timeoutSeconds,
            payloadSize: payloadSize
        )
    }
}

public enum PingConfigurationError: Error, Equatable, LocalizedError {
    case emptyHost
    case invalidCount
    case invalidInterval
    case invalidTimeout
    case invalidPayloadSize

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            "请输入主机名或 IP 地址。"
        case .invalidCount:
            "请求次数必须在 1 到 100 之间。"
        case .invalidInterval:
            "发送间隔必须在 0.1 到 10 秒之间。"
        case .invalidTimeout:
            "超时时间必须在 0.1 到 30 秒之间。"
        case .invalidPayloadSize:
            "Payload 大小必须在 0 到 1400 字节之间。"
        }
    }
}

public struct PingResolvedTarget: Equatable, Sendable {
    public let host: String
    public let address: String
    public let family: PingAddressFamily

    public init(
        host: String,
        address: String,
        family: PingAddressFamily
    ) {
        self.host = host
        self.address = address
        self.family = family
    }
}

public struct PingReply: Equatable, Sendable {
    public let sequence: UInt16
    public let address: String
    public let byteCount: Int
    public let hopLimit: Int
    public let roundTripTimeMilliseconds: Double

    public init(
        sequence: UInt16,
        address: String,
        byteCount: Int,
        hopLimit: Int,
        roundTripTimeMilliseconds: Double
    ) {
        self.sequence = sequence
        self.address = address
        self.byteCount = byteCount
        self.hopLimit = hopLimit
        self.roundTripTimeMilliseconds = roundTripTimeMilliseconds
    }
}

public struct PingSummary: Equatable, Sendable {
    public let transmitted: Int
    public let received: Int
    public let lost: Int
    public let lossPercentage: Double
    public let minimumMilliseconds: Double?
    public let averageMilliseconds: Double?
    public let maximumMilliseconds: Double?
    public let meanDeviationMilliseconds: Double?

    public init(
        transmitted: Int,
        roundTripTimesMilliseconds: [Double]
    ) {
        self.transmitted = transmitted
        self.received = roundTripTimesMilliseconds.count
        self.lost = transmitted - received

        if transmitted == 0 {
            self.lossPercentage = 0
        } else {
            self.lossPercentage = Double(lost) / Double(transmitted) * 100
        }

        guard !roundTripTimesMilliseconds.isEmpty else {
            self.minimumMilliseconds = nil
            self.averageMilliseconds = nil
            self.maximumMilliseconds = nil
            self.meanDeviationMilliseconds = nil
            return
        }

        let average = roundTripTimesMilliseconds.reduce(0, +)
            / Double(roundTripTimesMilliseconds.count)
        let variance = roundTripTimesMilliseconds.reduce(0) { result, value in
            let difference = value - average
            return result + difference * difference
        } / Double(roundTripTimesMilliseconds.count)

        self.minimumMilliseconds = roundTripTimesMilliseconds.min()
        self.averageMilliseconds = average
        self.maximumMilliseconds = roundTripTimesMilliseconds.max()
        self.meanDeviationMilliseconds = sqrt(variance)
    }
}

public enum PingEvent: Equatable, Sendable {
    case started(PingResolvedTarget)
    case reply(PingReply)
    case timeout(sequence: UInt16)
    case failed(message: String)
    case completed(PingSummary)
}
