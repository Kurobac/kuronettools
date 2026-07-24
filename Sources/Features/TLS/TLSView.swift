import NetToolCore
import SwiftUI

@MainActor
struct TLSView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = TLSViewModel()
    @State private var alpnPreset = TLSALPNPreset.web

    var body: some View {
        @Bindable var model = model

        Form {
            Section("目标") {
                EditableTargetComboBox(
                    prompt: "主机名或 IP 地址",
                    suggestions: Self.commonTargets,
                    value: $model.host
                )

                EditablePortField(
                    port: $model.port,
                    commonPorts: Self.commonPorts
                )

                TextField(
                    "SNI（留空跟随目标）",
                    text: $model.serverName
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Picker("地址族", selection: $model.addressFamily) {
                    ForEach(TCPAddressFamily.allCases) { family in
                        Text(family.title)
                            .tag(family)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.isRunning)

            Section("参数") {
                Picker("ALPN", selection: $alpnPreset) {
                    ForEach(TLSALPNPreset.allCases) { preset in
                        Text(preset.title)
                            .tag(preset)
                    }
                }
                .onChange(of: alpnPreset) { _, preset in
                    if let protocols = preset.protocolString {
                        model.applicationProtocols = protocols
                    }
                }

                if alpnPreset == .custom {
                    TextField(
                        "ALPN（逗号分隔）",
                        text: $model.applicationProtocols
                    )
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.1 ... 30,
                    step: 0.1
                ) {
                    LabeledContent(
                        "握手超时",
                        value: seconds(model.timeoutSeconds)
                    )
                }

                Toggle(
                    "允许不受信任证书",
                    isOn: $model.allowsUntrustedCertificates
                )
            }
            .disabled(model.isRunning)

            Section {
                RunActionButton(
                    isRunning: model.isRunning,
                    isStopping: model.isStopping,
                    startTitle: "开始检查",
                    startSystemImage: "checkmark.shield"
                ) {
                    model.start(logStore: logStore)
                } stopAction: {
                    model.stop(logStore: logStore)
                }
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if let result = model.result {
                TLSResultView(result: result)
            }

            if let errorMessage = model.errorMessage {
                Section("错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("TLS 检查")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.exportText) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.exportText.isEmpty)
            }
        }
        .onDisappear {
            if model.isRunning {
                model.stop(logStore: logStore)
            }
        }
    }

    private static let commonTargets = [
        "www.apple.com",
        "www.google.com",
        "www.cloudflare.com",
        "one.one.one.one",
        "cloudflare-dns.com"
    ]

    private static let commonPorts = [
        443,
        465,
        636,
        853,
        993,
        995,
        8443
    ]

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }
}

private enum TLSALPNPreset:
    String,
    CaseIterable,
    Identifiable
{
    case web
    case http2
    case http1
    case none
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web:
            "Web（h2, http/1.1）"
        case .http2:
            "仅 HTTP/2（h2）"
        case .http1:
            "仅 HTTP/1.1"
        case .none:
            "不发送"
        case .custom:
            "自定义"
        }
    }

    var protocolString: String? {
        switch self {
        case .web:
            "h2,http/1.1"
        case .http2:
            "h2"
        case .http1:
            "http/1.1"
        case .none:
            ""
        case .custom:
            nil
        }
    }
}

@MainActor
private struct TLSResultView: View {
    let result: TLSHandshakeResult

    var body: some View {
        Section("连接") {
            LabeledContent("远端地址") {
                Text(result.address)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            LabeledContent("远端端口", value: String(result.port))
            LabeledContent(
                "地址族",
                value: result.addressFamily.title
            )
            LabeledContent("SNI", value: result.serverName)
            LabeledContent(
                "握手耗时",
                value: String(
                    format: "%.3f ms",
                    result.handshakeTimeMilliseconds
                )
            )
        }

        Section("TLS") {
            LabeledContent("信任状态") {
                Text(result.trustStatus.title)
                    .foregroundStyle(trustColor)
            }
            LabeledContent(
                "协议版本",
                value: result.protocolVersion
            )
            LabeledContent("Cipher Suite") {
                Text(result.cipherSuite)
                    .font(.callout)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent(
                "ALPN",
                value: result.applicationProtocol ?? "未协商"
            )

            if case .untrusted(let message) = result.trustStatus {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }

        Section("证书链") {
            ForEach(result.certificates) { certificate in
                NavigationLink {
                    TLSCertificateDetailView(
                        certificate: certificate
                    )
                } label: {
                    TLSCertificateRow(certificate: certificate)
                }
            }
        }
    }

    private var trustColor: Color {
        switch result.trustStatus {
        case .trusted:
            .green
        case .untrusted:
            .red
        }
    }
}

@MainActor
private struct TLSCertificateRow: View {
    let certificate: TLSCertificateInfo

    var body: some View {
        let validity = TLSCertificateValidity(certificate)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("证书 \(certificate.index + 1)")
                    .font(.body.weight(.medium))

                Spacer()

                Text(validity.shortTitle)
                    .font(.caption)
                    .foregroundStyle(validity.color)
            }

            Text(certificate.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private struct TLSCertificateDetailView: View {
    let certificate: TLSCertificateInfo

    var body: some View {
        let validity = TLSCertificateValidity(certificate)

        Form {
            Section("摘要") {
                detail("主体", certificate.subject)
                detail("签发者", certificate.issuer)

                LabeledContent("有效性") {
                    Text(validity.detailTitle)
                        .foregroundStyle(validity.color)
                }
            }

            Section("有效期") {
                detail(
                    "生效时间",
                    certificate.notValidBefore.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
                detail(
                    "失效时间",
                    certificate.notValidAfter.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
            }

            Section("标识") {
                detail("序列号", certificate.serialNumber)

                if certificate.subjectAlternativeNames.isEmpty {
                    Text("没有主体备用名称（SAN）")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("主体备用名称（SAN）")
                        ForEach(
                            certificate.subjectAlternativeNames,
                            id: \.self
                        ) { name in
                            Text(name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("密钥与签名") {
                detail("公钥", certificate.publicKey)
                detail(
                    "签名算法",
                    certificate.signatureAlgorithm
                )
                detail(
                    "SHA-256",
                    certificate.sha256Fingerprint
                )
            }
        }
        .navigationTitle("证书 \(certificate.index + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private enum TLSCertificateValidity {
    case valid(remainingDays: Int)
    case notYetValid
    case expired

    init(_ certificate: TLSCertificateInfo) {
        let now = Date()
        if now < certificate.notValidBefore {
            self = .notYetValid
        } else if now > certificate.notValidAfter {
            self = .expired
        } else {
            self = .valid(
                remainingDays: max(
                    0,
                    Int(
                        certificate.notValidAfter
                            .timeIntervalSince(now)
                            / 86_400
                    )
                )
            )
        }
    }

    var shortTitle: String {
        switch self {
        case .valid:
            "有效"
        case .notYetValid:
            "尚未生效"
        case .expired:
            "已过期"
        }
    }

    var detailTitle: String {
        switch self {
        case .valid(let remainingDays):
            "有效（剩余 \(remainingDays) 天）"
        case .notYetValid:
            "尚未生效"
        case .expired:
            "已过期"
        }
    }

    var color: Color {
        switch self {
        case .valid:
            .green
        case .notYetValid:
            .orange
        case .expired:
            .red
        }
    }
}
