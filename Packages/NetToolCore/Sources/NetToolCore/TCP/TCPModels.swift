import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("TCP IP address validation requires Darwin or Glibc.")
#endif

public enum TCPAddressFamily:
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

public struct TCPConnectionConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let addressFamily: TCPAddressFamily
    public let timeoutSeconds: Double

    public init(
        host: String,
        port: Int = 443,
        addressFamily: TCPAddressFamily = .automatic,
        timeoutSeconds: Double = 3
    ) {
        self.host = host
        self.port = port
        self.addressFamily = addressFamily
        self.timeoutSeconds = timeoutSeconds
    }

    public func validated() throws -> TCPConnectionConfiguration {
        let trimmedHost = host.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedHost.isEmpty else {
            throw TCPConfigurationError.emptyHost
        }
        guard (1 ... 65_535).contains(port) else {
            throw TCPConfigurationError.invalidPort
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 30).contains(timeoutSeconds) else {
            throw TCPConfigurationError.invalidTimeout
        }
        if addressFamily != .automatic,
           let literalFamily = Self.literalAddressFamily(
               of: trimmedHost
           ),
           literalFamily != addressFamily {
            throw TCPConfigurationError.addressFamilyMismatch(
                address: trimmedHost,
                actual: literalFamily,
                selected: addressFamily
            )
        }

        return TCPConnectionConfiguration(
            host: trimmedHost,
            port: port,
            addressFamily: addressFamily,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func literalAddressFamily(
        of address: String
    ) -> TCPAddressFamily? {
        var ipv4 = in_addr()
        if address.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return .ipv4
        }

        let unscopedAddress = address.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? address
        var ipv6 = in6_addr()
        if unscopedAddress.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1 {
            return .ipv6
        }

        return nil
    }
}

public enum TCPConfigurationError: Error, Equatable, LocalizedError {
    case emptyHost
    case invalidPort
    case invalidTimeout
    case addressFamilyMismatch(
        address: String,
        actual: TCPAddressFamily,
        selected: TCPAddressFamily
    )

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            "请输入主机名或 IP 地址。"
        case .invalidPort:
            "端口必须在 1 到 65535 之间。"
        case .invalidTimeout:
            "超时时间必须在 0.1 到 30 秒之间。"
        case .addressFamilyMismatch(
            let address,
            let actual,
            let selected
        ):
            "\(address) 是 \(actual.title) 地址，"
                + "与所选的 \(selected.title) 地址族不一致。"
        }
    }
}

public struct TCPConnectionResult: Equatable, Sendable {
    public let host: String
    public let address: String
    public let port: Int
    public let addressFamily: TCPAddressFamily
    public let connectionTimeMilliseconds: Double

    public init(
        host: String,
        address: String,
        port: Int,
        addressFamily: TCPAddressFamily,
        connectionTimeMilliseconds: Double
    ) {
        self.host = host
        self.address = address
        self.port = port
        self.addressFamily = addressFamily
        self.connectionTimeMilliseconds = connectionTimeMilliseconds
    }
}
