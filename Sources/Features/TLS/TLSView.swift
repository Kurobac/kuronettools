import NetToolCore
import SwiftUI

@MainActor
struct TLSView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = TLSViewModel()

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
                TextField(
                    "ALPN（逗号分隔）",
                    text: $model.applicationProtocols
                )
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

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
                if model.isRunning {
                    Button(role: .destructive) {
                        model.stop(logStore: logStore)
                    } label: {
                        actionLabel(
                            model.isStopping ? "正在停止…" : "停止",
                            systemImage: "stop.fill"
                        )
                    }
                    .disabled(model.isStopping)
                } else {
                    Button {
                        model.start(logStore: logStore)
                    } label: {
                        actionLabel(
                            "开始检查",
                            systemImage: "checkmark.shield"
                        )
                    }
                }
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.callout.monospaced())
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

    private func actionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct TLSResultView: View {
    let result: TLSHandshakeResult

    var body: some View {
        Section("连接") {
            LabeledContent("远端地址") {
                Text(result.address)
                    .font(.callout.monospaced())
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
                    .font(.caption.monospaced())
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
                TLSCertificateDisclosure(certificate: certificate)
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
private struct TLSCertificateDisclosure: View {
    let certificate: TLSCertificateInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                detail("Subject", certificate.subject)
                detail("Issuer", certificate.issuer)
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
                detail("有效性", validityDescription)
                detail("序列号", certificate.serialNumber)
                detail("公钥", certificate.publicKey)
                detail(
                    "签名算法",
                    certificate.signatureAlgorithm
                )
                detail(
                    "SHA-256",
                    certificate.sha256Fingerprint
                )

                if !certificate.subjectAlternativeNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subject Alternative Name")
                            .foregroundStyle(.secondary)
                        ForEach(
                            certificate.subjectAlternativeNames,
                            id: \.self
                        ) { name in
                            Text(name)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("证书 \(certificate.index + 1)")
                    .font(.body.weight(.medium))
                Text(certificate.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var validityDescription: String {
        let now = Date()
        if now < certificate.notValidBefore {
            return "尚未生效"
        }
        if now > certificate.notValidAfter {
            return "已过期"
        }

        let remainingDays = max(
            0,
            Int(
                certificate.notValidAfter.timeIntervalSince(now)
                    / 86_400
            )
        )
        return "有效（剩余 \(remainingDays) 天）"
    }

    private func detail(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
