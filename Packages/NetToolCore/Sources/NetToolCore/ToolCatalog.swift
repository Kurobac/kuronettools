public enum ToolCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case diagnostics
    case dns
    case web
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .diagnostics:
            "诊断"
        case .dns:
            "DNS"
        case .web:
            "Web 与安全"
        case .network:
            "当前网络"
        }
    }
}

public enum ToolAvailability: String, Hashable, Sendable {
    case available
    case planned
}

public struct ToolDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let systemImage: String
    public let category: ToolCategory
    public let availability: ToolAvailability

    public init(
        id: String,
        title: String,
        summary: String,
        systemImage: String,
        category: ToolCategory,
        availability: ToolAvailability = .planned
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.category = category
        self.availability = availability
    }
}

public enum ToolCatalog {
    public static let all: [ToolDescriptor] = [
        ToolDescriptor(
            id: "ping",
            title: "Ping",
            summary: "ICMP 连通性与时延",
            systemImage: "dot.radiowaves.left.and.right",
            category: .diagnostics,
            availability: .available
        ),
        ToolDescriptor(
            id: "traceroute",
            title: "Traceroute",
            summary: "逐跳检查网络路径",
            systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
            category: .diagnostics,
            availability: .available
        ),
        ToolDescriptor(
            id: "tcp",
            title: "TCP 连接",
            summary: "测试端口与连接耗时",
            systemImage: "cable.connector",
            category: .diagnostics,
            availability: .available
        ),
        ToolDescriptor(
            id: "port-scan",
            title: "端口扫描",
            summary: "TCP Connect Scan",
            systemImage: "square.grid.3x3.square",
            category: .diagnostics,
            availability: .available
        ),
        ToolDescriptor(
            id: "dns",
            title: "DNS 查询",
            summary: "UDP、TCP、DoT 与 DoH",
            systemImage: "network",
            category: .dns,
            availability: .available
        ),
        ToolDescriptor(
            id: "tls",
            title: "TLS 检查",
            summary: "握手、协议与证书链",
            systemImage: "checkmark.shield",
            category: .web,
            availability: .available
        ),
        ToolDescriptor(
            id: "http",
            title: "HTTP 信息",
            summary: "状态、响应头与请求耗时",
            systemImage: "globe",
            category: .web,
            availability: .available
        ),
        ToolDescriptor(
            id: "network-info",
            title: "网络信息",
            summary: "接口、地址、路由与 Resolver",
            systemImage: "wifi",
            category: .network
        )
    ]

    public static func tools(in category: ToolCategory) -> [ToolDescriptor] {
        all.filter { $0.category == category }
    }
}
