import Foundation

public struct TracerouteConfiguration: Equatable, Sendable {
    public let host: String
    public let addressFamily: PingAddressFamily
    public let maxHops: Int
    public let probesPerHop: Int
    public let timeoutSeconds: Double
    public let payloadSize: Int

    public init(
        host: String,
        addressFamily: PingAddressFamily = .automatic,
        maxHops: Int = 30,
        probesPerHop: Int = 3,
        timeoutSeconds: Double = 1,
        payloadSize: Int = 32
    ) {
        self.host = host
        self.addressFamily = addressFamily
        self.maxHops = maxHops
        self.probesPerHop = probesPerHop
        self.timeoutSeconds = timeoutSeconds
        self.payloadSize = payloadSize
    }

    public func validated() throws -> TracerouteConfiguration {
        let trimmedHost = host.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedHost.isEmpty else {
            throw TracerouteConfigurationError.emptyHost
        }
        guard (1 ... 64).contains(maxHops) else {
            throw TracerouteConfigurationError.invalidMaxHops
        }
        guard (1 ... 5).contains(probesPerHop) else {
            throw TracerouteConfigurationError.invalidProbesPerHop
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 10).contains(timeoutSeconds) else {
            throw TracerouteConfigurationError.invalidTimeout
        }
        guard (0 ... 1_400).contains(payloadSize) else {
            throw TracerouteConfigurationError.invalidPayloadSize
        }

        return TracerouteConfiguration(
            host: trimmedHost,
            addressFamily: addressFamily,
            maxHops: maxHops,
            probesPerHop: probesPerHop,
            timeoutSeconds: timeoutSeconds,
            payloadSize: payloadSize
        )
    }
}

public enum TracerouteConfigurationError:
    Error,
    Equatable,
    LocalizedError
{
    case emptyHost
    case invalidMaxHops
    case invalidProbesPerHop
    case invalidTimeout
    case invalidPayloadSize

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            "请输入主机名或 IP 地址。"
        case .invalidMaxHops:
            "最大跳数必须在 1 到 64 之间。"
        case .invalidProbesPerHop:
            "每跳探测次数必须在 1 到 5 之间。"
        case .invalidTimeout:
            "单次超时必须在 0.1 到 10 秒之间。"
        case .invalidPayloadSize:
            "Payload 大小必须在 0 到 1400 字节之间。"
        }
    }
}

public enum TracerouteResponseKind:
    Equatable,
    Sendable
{
    case hop
    case destination
}

public struct TracerouteResponse: Equatable, Sendable {
    public let hop: Int
    public let probeIndex: Int
    public let sequence: UInt16
    public let address: String
    public let roundTripTimeMilliseconds: Double
    public let kind: TracerouteResponseKind

    public init(
        hop: Int,
        probeIndex: Int,
        sequence: UInt16,
        address: String,
        roundTripTimeMilliseconds: Double,
        kind: TracerouteResponseKind
    ) {
        self.hop = hop
        self.probeIndex = probeIndex
        self.sequence = sequence
        self.address = address
        self.roundTripTimeMilliseconds =
            roundTripTimeMilliseconds
        self.kind = kind
    }
}

public enum TracerouteProbeResult: Equatable, Sendable {
    case response(TracerouteResponse)
    case timeout(
        hop: Int,
        probeIndex: Int,
        sequence: UInt16
    )
}

public enum TracerouteCompletionStatus:
    Equatable,
    Sendable
{
    case reachedDestination(hop: Int)
    case maxHopsReached

    public var title: String {
        switch self {
        case .reachedDestination(let hop):
            "已在第 \(hop) 跳到达目标"
        case .maxHopsReached:
            "已达到最大跳数"
        }
    }
}

public enum TracerouteEvent: Equatable, Sendable {
    case started(PingResolvedTarget)
    case probe(TracerouteProbeResult)
    case failed(message: String)
    case completed(TracerouteCompletionStatus)
}
