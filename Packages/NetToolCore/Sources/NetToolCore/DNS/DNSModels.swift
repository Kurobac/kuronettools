import Foundation

public enum DNSTransport:
    String,
    CaseIterable,
    Equatable,
    Hashable,
    Identifiable,
    Sendable
{
    case udp
    case tcp
    case tls
    case https

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .udp:
            "UDP"
        case .tcp:
            "TCP"
        case .tls:
            "DoT"
        case .https:
            "DoH"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .udp, .tcp:
            53
        case .tls:
            853
        case .https:
            443
        }
    }

    public var usesHTTPSURL: Bool {
        self == .https
    }
}

public enum DNSRecordType:
    UInt16,
    CaseIterable,
    Equatable,
    Identifiable,
    Sendable
{
    case a = 1
    case ns = 2
    case cname = 5
    case soa = 6
    case ptr = 12
    case mx = 15
    case txt = 16
    case aaaa = 28
    case srv = 33
    case caa = 257

    public var id: UInt16 { rawValue }

    public var title: String {
        switch self {
        case .a:
            "A"
        case .ns:
            "NS"
        case .cname:
            "CNAME"
        case .soa:
            "SOA"
        case .ptr:
            "PTR"
        case .mx:
            "MX"
        case .txt:
            "TXT"
        case .aaaa:
            "AAAA"
        case .srv:
            "SRV"
        case .caa:
            "CAA"
        }
    }

    public static let pickerCases: [DNSRecordType] = [
        .a,
        .aaaa,
        .cname,
        .ns,
        .mx,
        .txt,
        .soa,
        .srv,
        .caa,
        .ptr
    ]
}

public struct DNSQueryConfiguration: Equatable, Sendable {
    public let name: String
    public let type: DNSRecordType
    public let transport: DNSTransport
    public let server: String
    public let port: Int
    public let timeoutSeconds: Double
    public let recursionDesired: Bool

    public init(
        name: String,
        type: DNSRecordType = .a,
        transport: DNSTransport = .udp,
        server: String = "1.1.1.1",
        port: Int = 53,
        timeoutSeconds: Double = 3,
        recursionDesired: Bool = true
    ) {
        self.name = name
        self.type = type
        self.transport = transport
        self.server = server
        self.port = port
        self.timeoutSeconds = timeoutSeconds
        self.recursionDesired = recursionDesired
    }

    public func validated() throws -> DNSQueryConfiguration {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedServer = server.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedName.isEmpty else {
            throw DNSConfigurationError.emptyName
        }
        guard !trimmedServer.isEmpty else {
            throw DNSConfigurationError.emptyServer
        }
        var validatedPort = port
        if transport.usesHTTPSURL {
            guard let url = URL(string: trimmedServer),
                  url.scheme?.lowercased() == "https",
                  let host = url.host,
                  !host.isEmpty else {
                throw DNSConfigurationError.invalidHTTPSURL
            }
            validatedPort = url.port ?? transport.defaultPort
        }
        guard (1 ... 65_535).contains(validatedPort) else {
            throw DNSConfigurationError.invalidPort
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 30).contains(timeoutSeconds) else {
            throw DNSConfigurationError.invalidTimeout
        }

        return DNSQueryConfiguration(
            name: trimmedName,
            type: type,
            transport: transport,
            server: trimmedServer,
            port: validatedPort,
            timeoutSeconds: timeoutSeconds,
            recursionDesired: recursionDesired
        )
    }
}

public enum DNSConfigurationError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyServer
    case invalidPort
    case invalidHTTPSURL
    case invalidTimeout

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "请输入要查询的域名。"
        case .emptyServer:
            "请输入 DNS 服务器。"
        case .invalidPort:
            "DNS 端口必须在 1 到 65535 之间。"
        case .invalidHTTPSURL:
            "DoH 端点必须是包含主机名的 HTTPS URL。"
        case .invalidTimeout:
            "超时时间必须在 0.1 到 30 秒之间。"
        }
    }
}

public struct DNSMessageFlags: Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public var isResponse: Bool { rawValue & 0x8000 != 0 }
    public var opcode: UInt8 { UInt8((rawValue >> 11) & 0x0f) }
    public var isAuthoritative: Bool { rawValue & 0x0400 != 0 }
    public var isTruncated: Bool { rawValue & 0x0200 != 0 }
    public var recursionDesired: Bool { rawValue & 0x0100 != 0 }
    public var recursionAvailable: Bool { rawValue & 0x0080 != 0 }
    public var authenticatedData: Bool { rawValue & 0x0020 != 0 }
    public var checkingDisabled: Bool { rawValue & 0x0010 != 0 }
    public var responseCode: UInt8 { UInt8(rawValue & 0x000f) }

    public var responseCodeName: String {
        switch responseCode {
        case 0:
            "NOERROR"
        case 1:
            "FORMERR"
        case 2:
            "SERVFAIL"
        case 3:
            "NXDOMAIN"
        case 4:
            "NOTIMP"
        case 5:
            "REFUSED"
        case 6:
            "YXDOMAIN"
        case 7:
            "YXRRSET"
        case 8:
            "NXRRSET"
        case 9:
            "NOTAUTH"
        case 10:
            "NOTZONE"
        default:
            "RCODE\(responseCode)"
        }
    }

    public var activeNames: [String] {
        var names: [String] = []

        if isResponse {
            names.append("qr")
        }
        if isAuthoritative {
            names.append("aa")
        }
        if isTruncated {
            names.append("tc")
        }
        if recursionDesired {
            names.append("rd")
        }
        if recursionAvailable {
            names.append("ra")
        }
        if authenticatedData {
            names.append("ad")
        }
        if checkingDisabled {
            names.append("cd")
        }

        return names
    }
}

public struct DNSQuestion: Equatable, Sendable {
    public let name: String
    public let typeCode: UInt16
    public let classCode: UInt16

    public init(
        name: String,
        typeCode: UInt16,
        classCode: UInt16
    ) {
        self.name = name
        self.typeCode = typeCode
        self.classCode = classCode
    }

    public var typeName: String {
        DNSRecordType(rawValue: typeCode)?.title ?? "TYPE\(typeCode)"
    }

    public var className: String {
        classCode == 1 ? "IN" : "CLASS\(classCode)"
    }
}

public enum DNSRecordData: Equatable, Sendable {
    case a(String)
    case aaaa(String)
    case domainName(String)
    case mx(preference: UInt16, exchange: String)
    case txt([String])
    case soa(
        primaryNameServer: String,
        responsibleMailbox: String,
        serial: UInt32,
        refresh: UInt32,
        retry: UInt32,
        expire: UInt32,
        minimum: UInt32
    )
    case srv(
        priority: UInt16,
        weight: UInt16,
        port: UInt16,
        target: String
    )
    case caa(flags: UInt8, tag: String, value: String)
    case raw([UInt8])

    public var displayValue: String {
        switch self {
        case .a(let address), .aaaa(let address):
            address
        case .domainName(let name):
            name
        case .mx(let preference, let exchange):
            "\(preference) \(exchange)"
        case .txt(let strings):
            strings.map { "\"\($0)\"" }.joined(separator: " ")
        case .soa(
            let primaryNameServer,
            let responsibleMailbox,
            let serial,
            let refresh,
            let retry,
            let expire,
            let minimum
        ):
            "\(primaryNameServer) \(responsibleMailbox) "
                + "\(serial) \(refresh) \(retry) \(expire) \(minimum)"
        case .srv(let priority, let weight, let port, let target):
            "\(priority) \(weight) \(port) \(target)"
        case .caa(let flags, let tag, let value):
            "\(flags) \(tag) \"\(value)\""
        case .raw(let bytes):
            bytes.map {
                String(format: "%02x", Int($0))
            }.joined(separator: " ")
        }
    }
}

public struct DNSResourceRecord: Equatable, Sendable {
    public let name: String
    public let typeCode: UInt16
    public let classCode: UInt16
    public let timeToLive: UInt32
    public let data: DNSRecordData

    public init(
        name: String,
        typeCode: UInt16,
        classCode: UInt16,
        timeToLive: UInt32,
        data: DNSRecordData
    ) {
        self.name = name
        self.typeCode = typeCode
        self.classCode = classCode
        self.timeToLive = timeToLive
        self.data = data
    }

    public var typeName: String {
        DNSRecordType(rawValue: typeCode)?.title ?? "TYPE\(typeCode)"
    }

    public var className: String {
        classCode == 1 ? "IN" : "CLASS\(classCode)"
    }
}

public struct DNSMessage: Equatable, Sendable {
    public let identifier: UInt16
    public let flags: DNSMessageFlags
    public let questions: [DNSQuestion]
    public let answers: [DNSResourceRecord]
    public let authorities: [DNSResourceRecord]
    public let additionals: [DNSResourceRecord]

    public init(
        identifier: UInt16,
        flags: DNSMessageFlags,
        questions: [DNSQuestion],
        answers: [DNSResourceRecord],
        authorities: [DNSResourceRecord],
        additionals: [DNSResourceRecord]
    ) {
        self.identifier = identifier
        self.flags = flags
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }
}
