import Foundation

public enum TCPPortExpressionParser {
    public static func parse(
        _ expression: String
    ) throws -> [Int] {
        let trimmedExpression = expression.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedExpression.isEmpty else {
            throw TCPPortExpressionError.emptyExpression
        }

        var ports = Set<Int>()
        let tokens = trimmedExpression.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        for rawToken in tokens {
            let token = String(rawToken).trimmingCharacters(
                in: .whitespaces
            )
            guard !token.isEmpty else {
                throw TCPPortExpressionError.emptyToken
            }

            let rangeParts = token.split(
                separator: "-",
                omittingEmptySubsequences: false
            )
            switch rangeParts.count {
            case 1:
                let port = try parsePort(
                    String(rangeParts[0]),
                    token: token
                )
                ports.insert(port)
            case 2:
                let lowerBound = try parsePort(
                    String(rangeParts[0]),
                    token: token
                )
                let upperBound = try parsePort(
                    String(rangeParts[1]),
                    token: token
                )
                guard lowerBound <= upperBound else {
                    throw TCPPortExpressionError.invalidRange(
                        token
                    )
                }
                for port in lowerBound ... upperBound {
                    ports.insert(port)
                }
            default:
                throw TCPPortExpressionError.invalidToken(token)
            }
        }

        return ports.sorted()
    }

    private static func parsePort(
        _ value: String,
        token: String
    ) throws -> Int {
        let trimmedValue = value.trimmingCharacters(
            in: .whitespaces
        )
        guard let port = Int(trimmedValue) else {
            throw TCPPortExpressionError.invalidToken(token)
        }
        guard (1 ... 65_535).contains(port) else {
            throw TCPPortExpressionError.portOutOfRange(port)
        }
        return port
    }
}

public enum TCPPortExpressionError:
    Error,
    Equatable,
    LocalizedError
{
    case emptyExpression
    case emptyToken
    case invalidToken(String)
    case invalidRange(String)
    case portOutOfRange(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyExpression:
            "请输入端口或端口范围。"
        case .emptyToken:
            "端口表达式中存在空项目。"
        case .invalidToken(let token):
            "无法识别端口项目：\(token)"
        case .invalidRange(let range):
            "端口范围起点不能大于终点：\(range)"
        case .portOutOfRange(let port):
            "端口 \(port) 不在 1 到 65535 范围内。"
        }
    }
}

public struct TCPPortScanConfiguration: Equatable, Sendable {
    public let host: String
    public let ports: [Int]
    public let addressFamily: TCPAddressFamily
    public let timeoutSeconds: Double
    public let maxConcurrency: Int
    public let maxStartRate: Int
    public let maxRetries: Int

    public init(
        host: String,
        ports: [Int],
        addressFamily: TCPAddressFamily = .automatic,
        timeoutSeconds: Double = 2,
        maxConcurrency: Int = 32,
        maxStartRate: Int = 100,
        maxRetries: Int = 2
    ) {
        self.host = host
        self.ports = ports
        self.addressFamily = addressFamily
        self.timeoutSeconds = timeoutSeconds
        self.maxConcurrency = maxConcurrency
        self.maxStartRate = maxStartRate
        self.maxRetries = maxRetries
    }

    public func validated() throws -> TCPPortScanConfiguration {
        guard !ports.isEmpty else {
            throw TCPPortScanConfigurationError.emptyPorts
        }
        guard ports.allSatisfy({
            (1 ... 65_535).contains($0)
        }) else {
            throw TCPPortScanConfigurationError.invalidPort
        }
        guard (1 ... 128).contains(maxConcurrency) else {
            throw TCPPortScanConfigurationError.invalidConcurrency
        }
        guard (10 ... 1_000).contains(maxStartRate) else {
            throw TCPPortScanConfigurationError.invalidStartRate
        }
        guard (0 ... 2).contains(maxRetries) else {
            throw TCPPortScanConfigurationError.invalidRetryLimit
        }

        let normalizedPorts = Array(Set(ports)).sorted()
        let tcpConfiguration = try TCPConnectionConfiguration(
            host: host,
            port: normalizedPorts[0],
            addressFamily: addressFamily,
            timeoutSeconds: timeoutSeconds
        ).validated()

        return TCPPortScanConfiguration(
            host: tcpConfiguration.host,
            ports: normalizedPorts,
            addressFamily: tcpConfiguration.addressFamily,
            timeoutSeconds: tcpConfiguration.timeoutSeconds,
            maxConcurrency: maxConcurrency,
            maxStartRate: maxStartRate,
            maxRetries: maxRetries
        )
    }
}

public enum TCPPortScanConfigurationError:
    Error,
    Equatable,
    LocalizedError
{
    case emptyPorts
    case invalidPort
    case invalidConcurrency
    case invalidStartRate
    case invalidRetryLimit

    public var errorDescription: String? {
        switch self {
        case .emptyPorts:
            "端口列表不能为空。"
        case .invalidPort:
            "所有端口都必须在 1 到 65535 范围内。"
        case .invalidConcurrency:
            "最大并发连接数必须在 1 到 128 之间。"
        case .invalidStartRate:
            "最大发起速率必须在每秒 10 到 1000 次之间。"
        case .invalidRetryLimit:
            "超时重试次数必须在 0 到 2 之间。"
        }
    }
}

public enum TCPPortScanOutcome: Equatable, Sendable {
    case open(
        address: String,
        addressFamily: TCPAddressFamily,
        connectionTimeMilliseconds: Double
    )
    case closed
    case timedOut
    case unreachable
    case failed(message: String)
}

public struct TCPPortScanResult: Equatable, Sendable {
    public let port: Int
    public let outcome: TCPPortScanOutcome

    public init(
        port: Int,
        outcome: TCPPortScanOutcome
    ) {
        self.port = port
        self.outcome = outcome
    }
}

public struct TCPPortScanSummary: Equatable, Sendable {
    public let total: Int
    public private(set) var scanned: Int
    public private(set) var open: Int
    public private(set) var closed: Int
    public private(set) var timedOut: Int
    public private(set) var unreachable: Int
    public private(set) var failed: Int

    public init(total: Int) {
        self.total = total
        self.scanned = 0
        self.open = 0
        self.closed = 0
        self.timedOut = 0
        self.unreachable = 0
        self.failed = 0
    }

    public mutating func record(
        _ result: TCPPortScanResult
    ) {
        scanned += 1
        switch result.outcome {
        case .open:
            open += 1
        case .closed:
            closed += 1
        case .timedOut:
            timedOut += 1
        case .unreachable:
            unreachable += 1
        case .failed:
            failed += 1
        }
    }
}

public struct TCPPortScanTimingSnapshot: Equatable, Sendable {
    public let currentParallelism: Int
    public let peakParallelism: Int
    public let maxParallelism: Int
    public let startRateLimit: Int
    public let retryAttempts: Int
    public let activeConnections: Int
    public let peakActiveConnections: Int
    public let appDeadlineTimeouts: Int
    public let systemTimeouts: Int

    public init(
        currentParallelism: Int,
        peakParallelism: Int,
        maxParallelism: Int,
        startRateLimit: Int,
        retryAttempts: Int,
        activeConnections: Int,
        peakActiveConnections: Int,
        appDeadlineTimeouts: Int,
        systemTimeouts: Int
    ) {
        self.currentParallelism = currentParallelism
        self.peakParallelism = peakParallelism
        self.maxParallelism = maxParallelism
        self.startRateLimit = startRateLimit
        self.retryAttempts = retryAttempts
        self.activeConnections = activeConnections
        self.peakActiveConnections = peakActiveConnections
        self.appDeadlineTimeouts = appDeadlineTimeouts
        self.systemTimeouts = systemTimeouts
    }

    public var timeoutAttempts: Int {
        appDeadlineTimeouts + systemTimeouts
    }
}

public enum TCPPortScanTimeoutOrigin: Equatable, Sendable {
    case appDeadline
    case system
}

public struct TCPPortScanTimingController: Equatable, Sendable {
    private let minimumWindow: Double
    private let maximumWindow: Double
    private var congestionWindow: Double
    private var slowStartThreshold: Double
    private var peakParallelism: Int
    private var startRateLimit: Int
    private var retryAttempts = 0
    private var activeConnections = 0
    private var peakActiveConnections = 0
    private var appDeadlineTimeouts = 0
    private var systemTimeouts = 0

    public init(
        maxParallelism: Int,
        startRateLimit: Int = 100
    ) {
        precondition(maxParallelism > 0)
        precondition(startRateLimit > 0)
        let maximum = Double(maxParallelism)
        minimumWindow = min(4, maximum)
        maximumWindow = maximum
        congestionWindow = min(8, maximum)
        slowStartThreshold = maximum
        peakParallelism = Int(congestionWindow)
        self.startRateLimit = startRateLimit
    }

    public var snapshot: TCPPortScanTimingSnapshot {
        TCPPortScanTimingSnapshot(
            currentParallelism: currentParallelism,
            peakParallelism: peakParallelism,
            maxParallelism: Int(maximumWindow),
            startRateLimit: startRateLimit,
            retryAttempts: retryAttempts,
            activeConnections: activeConnections,
            peakActiveConnections: peakActiveConnections,
            appDeadlineTimeouts: appDeadlineTimeouts,
            systemTimeouts: systemTimeouts
        )
    }

    public mutating func recordResponsiveResult() {
        if congestionWindow < slowStartThreshold {
            congestionWindow += 1
        } else {
            congestionWindow += 1 / congestionWindow
        }
        congestionWindow = min(
            congestionWindow,
            maximumWindow
        )
        peakParallelism = max(
            peakParallelism,
            currentParallelism
        )
    }

    public mutating func recordPathTimeout() {
        let reducedWindow = max(
            minimumWindow,
            (congestionWindow / 2).rounded(.down)
        )
        slowStartThreshold = reducedWindow
        congestionWindow = reducedWindow
    }

    public mutating func recordRetries(_ count: Int) {
        precondition(count >= 0)
        retryAttempts += count
    }

    public mutating func recordStartRateLimit(_ value: Int) {
        precondition(value > 0)
        startRateLimit = value
    }

    public mutating func recordActiveConnections(_ count: Int) {
        precondition(count >= 0)
        activeConnections = count
        peakActiveConnections = max(peakActiveConnections, count)
    }

    public mutating func recordTimeout(
        origin: TCPPortScanTimeoutOrigin
    ) {
        switch origin {
        case .appDeadline:
            appDeadlineTimeouts += 1
        case .system:
            systemTimeouts += 1
        }
    }

    private var currentParallelism: Int {
        max(
            1,
            min(
                Int(congestionWindow.rounded(.down)),
                Int(maximumWindow)
            )
        )
    }
}

public enum TCPPortScanRetryPolicy {
    public static func shouldRetry(
        outcome: TCPPortScanOutcome,
        completedRetries: Int,
        maxRetries: Int
    ) -> Bool {
        guard case .timedOut = outcome else {
            return false
        }
        return completedRetries < maxRetries
    }
}

public enum TCPPortScanPacingPolicy {
    public static func startRateLimit(
        maximum: Int,
        retryNumber: Int
    ) -> Int {
        precondition(maximum > 0)
        precondition(retryNumber >= 0)

        let divisor = 1 << min(retryNumber, 30)
        return max(10, maximum / divisor)
    }

    public static func launchIntervalNanoseconds(
        startRateLimit: Int
    ) -> UInt64 {
        precondition(startRateLimit > 0)
        let rate = UInt64(startRateLimit)
        return (1_000_000_000 + rate - 1) / rate
    }
}

public enum TCPPortScanEvent: Equatable, Sendable {
    case started(
        totalPorts: Int,
        timing: TCPPortScanTimingSnapshot
    )
    case pathProbeStarted(
        timing: TCPPortScanTimingSnapshot
    )
    case retryRoundStarted(
        retryNumber: Int,
        portCount: Int,
        timing: TCPPortScanTimingSnapshot
    )
    case retryRoundProgress(
        retryNumber: Int,
        completed: Int,
        total: Int,
        timing: TCPPortScanTimingSnapshot
    )
    case result(
        TCPPortScanResult,
        timing: TCPPortScanTimingSnapshot
    )
    case failed(message: String)
    case completed
}
