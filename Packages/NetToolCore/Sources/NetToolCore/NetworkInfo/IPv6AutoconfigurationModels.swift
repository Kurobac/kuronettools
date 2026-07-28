import Foundation

public enum IPv6RouterPreference: String, Equatable, Sendable {
    case high
    case medium
    case low
    case reserved

    public var title: String {
        switch self {
        case .high:
            "高"
        case .medium:
            "中"
        case .low:
            "低"
        case .reserved:
            "保留值"
        }
    }
}

public struct IPv6DefaultRouterEntry: Equatable, Sendable {
    public let address: String
    public let interfaceName: String
    public let managedConfiguration: Bool
    public let otherConfiguration: Bool
    public let homeAgent: Bool
    public let preference: IPv6RouterPreference
    public let advertisedLifetimeSeconds: UInt16
    public let expiration: Date?
    public let stateFlags: [String]

    public init(
        address: String,
        interfaceName: String,
        managedConfiguration: Bool,
        otherConfiguration: Bool,
        homeAgent: Bool,
        preference: IPv6RouterPreference,
        advertisedLifetimeSeconds: UInt16,
        expiration: Date?,
        stateFlags: [String]
    ) {
        self.address = address
        self.interfaceName = interfaceName
        self.managedConfiguration = managedConfiguration
        self.otherConfiguration = otherConfiguration
        self.homeAgent = homeAgent
        self.preference = preference
        self.advertisedLifetimeSeconds = advertisedLifetimeSeconds
        self.expiration = expiration
        self.stateFlags = stateFlags
    }

    public var raFlags: [String] {
        var flags: [String] = []
        if managedConfiguration {
            flags.append("M")
        }
        if otherConfiguration {
            flags.append("O")
        }
        if homeAgent {
            flags.append("HA")
        }
        return flags
    }
}

public struct IPv6PrefixEntry: Equatable, Sendable {
    public static let infiniteLifetime = UInt64(UInt32.max)

    public let address: String
    public let prefixLength: UInt8
    public let interfaceName: String
    public let onLink: Bool
    public let autonomous: Bool
    public let validLifetimeSeconds: UInt64
    public let preferredLifetimeSeconds: UInt64
    public let expiration: Date?
    public let stateFlags: [String]
    public let advertisingRouters: [String]

    public init(
        address: String,
        prefixLength: UInt8,
        interfaceName: String,
        onLink: Bool,
        autonomous: Bool,
        validLifetimeSeconds: UInt64,
        preferredLifetimeSeconds: UInt64,
        expiration: Date?,
        stateFlags: [String],
        advertisingRouters: [String]
    ) {
        self.address = address
        self.prefixLength = prefixLength
        self.interfaceName = interfaceName
        self.onLink = onLink
        self.autonomous = autonomous
        self.validLifetimeSeconds = validLifetimeSeconds
        self.preferredLifetimeSeconds = preferredLifetimeSeconds
        self.expiration = expiration
        self.stateFlags = stateFlags
        self.advertisingRouters = advertisingRouters
    }

    public var cidrDescription: String {
        "\(address)/\(prefixLength)"
    }

    public var raFlags: [String] {
        var flags: [String] = []
        if onLink {
            flags.append("L")
        }
        if autonomous {
            flags.append("A")
        }
        return flags
    }
}

public struct IPv6NDInterfaceSnapshot: Equatable, Sendable {
    public let interfaceName: String
    public let linkMTU: UInt32
    public let maximumMTU: UInt32
    public let baseReachableTimeMilliseconds: UInt32
    public let reachableTimeSeconds: UInt32
    public let retransmitTimerMilliseconds: UInt32
    public let currentHopLimit: UInt8
    public let learnedRouterCount: UInt8
    public let flags: [String]

    public init(
        interfaceName: String,
        linkMTU: UInt32,
        maximumMTU: UInt32,
        baseReachableTimeMilliseconds: UInt32,
        reachableTimeSeconds: UInt32,
        retransmitTimerMilliseconds: UInt32,
        currentHopLimit: UInt8,
        learnedRouterCount: UInt8,
        flags: [String]
    ) {
        self.interfaceName = interfaceName
        self.linkMTU = linkMTU
        self.maximumMTU = maximumMTU
        self.baseReachableTimeMilliseconds =
            baseReachableTimeMilliseconds
        self.reachableTimeSeconds = reachableTimeSeconds
        self.retransmitTimerMilliseconds =
            retransmitTimerMilliseconds
        self.currentHopLimit = currentHopLimit
        self.learnedRouterCount = learnedRouterCount
        self.flags = flags
    }
}

public struct IPv6NDInterfaceError: Equatable, Sendable {
    public let interfaceName: String
    public let message: String

    public init(
        interfaceName: String,
        message: String
    ) {
        self.interfaceName = interfaceName
        self.message = message
    }
}

public struct IPv6AutoconfigurationSnapshot: Equatable, Sendable {
    public let defaultRouters: [IPv6DefaultRouterEntry]
    public let prefixes: [IPv6PrefixEntry]
    public let interfaces: [IPv6NDInterfaceSnapshot]
    public let defaultRoutersError: String?
    public let prefixesError: String?
    public let interfacesError: String?
    public let interfaceErrors: [IPv6NDInterfaceError]

    public init(
        defaultRouters: [IPv6DefaultRouterEntry] = [],
        prefixes: [IPv6PrefixEntry] = [],
        interfaces: [IPv6NDInterfaceSnapshot] = [],
        defaultRoutersError: String? = nil,
        prefixesError: String? = nil,
        interfacesError: String? = nil,
        interfaceErrors: [IPv6NDInterfaceError] = []
    ) {
        self.defaultRouters = defaultRouters
        self.prefixes = prefixes
        self.interfaces = interfaces
        self.defaultRoutersError = defaultRoutersError
        self.prefixesError = prefixesError
        self.interfacesError = interfacesError
        self.interfaceErrors = interfaceErrors
    }

    public var hasErrors: Bool {
        defaultRoutersError != nil
            || prefixesError != nil
            || interfacesError != nil
            || !interfaceErrors.isEmpty
    }
}
