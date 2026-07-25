import NetToolCore
import SwiftUI

@MainActor
struct HTTPView: View {
    @Environment(AppLogStore.self) private var logStore
    @State private var model = HTTPViewModel()

    var body: some View {
        @Bindable var model = model

        Form {
            Section("请求") {
                HTTPURLInputField(
                    scheme: $model.scheme,
                    target: $model.target,
                    suggestions: Self.commonTargets
                )

                LabeledContent("方法", value: "HEAD")
            }
            .disabled(model.isRunning)

            Section("参数") {
                Toggle(
                    "跟随重定向",
                    isOn: $model.followsRedirects
                )

                Stepper(
                    value: $model.timeoutSeconds,
                    in: 0.5 ... 60,
                    step: 0.5
                ) {
                    LabeledContent(
                        "请求超时",
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
                    startTitle: "发送 HEAD",
                    startSystemImage: "paperplane.fill"
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

            if let result = model.result,
               let transaction = model.finalTransaction {
                HTTPResultView(
                    result: result,
                    transaction: transaction,
                    headerBlock: model.headerBlocks(for: result)
                )
            }

            if let errorMessage = model.errorMessage {
                Section("错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("HTTP 信息")
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
        "www.cloudflare.com",
        "www.google.com",
        "www.baidu.com",
        "example.com"
    ]

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }
}

private struct HTTPURLInputField: View {
    @Binding var scheme: HTTPURLScheme
    @Binding var target: String
    let suggestions: [String]

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(HTTPURLScheme.allCases) { option in
                    Button {
                        scheme = option
                    } label: {
                        HStack {
                            Text(option.title)
                            if option == scheme {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                menuLabel(scheme.title)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("选择 HTTP 协议")

            Divider()
                .frame(height: 28)

            TextField("URL", text: $target)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .layoutPriority(1)

            Divider()
                .frame(height: 28)

            Menu {
                ForEach(availableTargets, id: \.self) { target in
                    Button {
                        self.target = target
                    } label: {
                        HStack {
                            Text(target)
                            if target == normalizedTarget {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 72,
                        height: 44
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("选择常用目标")
        }
    }

    private func menuLabel(
        _ title: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var normalizedTarget: String {
        target.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var availableTargets: [String] {
        var seen = Set<String>()
        return suggestions.filter {
            seen.insert($0).inserted
        }
    }
}

private struct HTTPResultView: View {
    let result: HTTPInspectionResult
    let transaction: HTTPTransaction
    let headerBlock: String

    var body: some View {
        Section("响应") {
            LabeledContent("状态码") {
                Text(String(transaction.statusCode))
                    .foregroundStyle(statusColor)
            }
            LabeledContent(
                "协议",
                value: transaction.protocolTitle
            )
            LabeledContent(
                "重定向",
                value: String(result.redirectCount)
            )
            detail("最终 URL", result.finalURL)

            if let server = headerValue("Server") {
                LabeledContent("Server", value: server)
            }
            if let contentType = headerValue("Content-Type") {
                LabeledContent("Content-Type", value: contentType)
            }
            if let contentLength = headerValue("Content-Length") {
                LabeledContent(
                    "Content-Length",
                    value: contentLength
                )
            }

            LabeledContent(
                "请求头大小",
                value: bytes(transaction.requestHeaderBytesSent)
            )
            LabeledContent(
                "响应头大小",
                value: bytes(
                    transaction.responseHeaderBytesReceived
                )
            )
        }

        if result.redirectCount > 0 {
            HTTPRedirectSection(
                transactions: Array(
                    result.transactions.prefix(
                        result.redirectCount
                    )
                )
            )
        }

        Section("耗时") {
            timingRow("DNS", result.dnsMilliseconds)
            timingRow("TCP", result.tcpMilliseconds)
            timingRow("TLS", result.tlsMilliseconds)
            timingRow(
                "首字节",
                result.timeToFirstByteMilliseconds
            )
            timingRow("总耗时", result.totalMilliseconds)
        }

        HTTPConnectionSection(
            connection: transaction.connection,
            allowsUntrustedCertificates:
                result.allowsUntrustedCertificates,
            isHTTPS: result.finalURL.lowercased()
                .hasPrefix("https://")
        )

        Section("响应头") {
            if transaction.headers.isEmpty {
                Text("没有响应头")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    transaction.headers.indices,
                    id: \.self
                ) { index in
                    headerRow(transaction.headers[index])
                }
            }
        }

        Section("curl -I") {
            Text(headerBlock)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var statusColor: Color {
        switch transaction.statusCode {
        case 200 ... 299:
            .green
        case 300 ... 399:
            .orange
        case 400 ... 599:
            .red
        default:
            .primary
        }
    }

    private func headerValue(_ name: String) -> String? {
        transaction.headers.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
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

    private func timingRow(
        _ title: String,
        _ value: Double?
    ) -> some View {
        LabeledContent(title, value: milliseconds(value))
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        return String(format: "%.3f ms", value)
    }

    private func bytes(_ value: Int64) -> String {
        guard value >= 0 else {
            return "—"
        }
        return "\(value) 字节"
    }

    private func headerRow(
        _ header: HTTPHeaderField
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header.name)
            Text(header.value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct HTTPRedirectSection: View {
    let transactions: [HTTPTransaction]

    var body: some View {
        Section("重定向链") {
            ForEach(transactions) { transaction in
                DisclosureGroup {
                    detail("URL", transaction.responseURL)
                    timingRows(transaction.timing)

                    ForEach(
                        transaction.headers.indices,
                        id: \.self
                    ) { index in
                        let header = transaction.headers[index]
                        detail(header.name, header.value)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            "\(transaction.protocolTitle) "
                                + "\(transaction.statusCode)"
                        )
                        .foregroundStyle(.orange)

                        Text(transaction.responseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timingRows(
        _ timing: HTTPTransactionTiming
    ) -> some View {
        LabeledContent(
            "DNS",
            value: milliseconds(timing.dnsMilliseconds)
        )
        LabeledContent(
            "TCP",
            value: milliseconds(timing.tcpMilliseconds)
        )
        LabeledContent(
            "TLS",
            value: milliseconds(timing.tlsMilliseconds)
        )
        LabeledContent(
            "首字节",
            value: milliseconds(
                timing.timeToFirstByteMilliseconds
            )
        )
        LabeledContent(
            "该跳总计",
            value: milliseconds(timing.totalMilliseconds)
        )
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

    private func milliseconds(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        return String(format: "%.3f ms", value)
    }
}

private struct HTTPConnectionSection: View {
    let connection: HTTPConnectionInfo
    let allowsUntrustedCertificates: Bool
    let isHTTPS: Bool

    var body: some View {
        Section("连接") {
            if let remoteAddress = connection.remoteAddress {
                LabeledContent(
                    "远端地址",
                    value: remoteAddress
                )
            }
            if let remotePort = connection.remotePort {
                LabeledContent(
                    "远端端口",
                    value: String(remotePort)
                )
            }
            if let localAddress = connection.localAddress {
                LabeledContent(
                    "本地地址",
                    value: localAddress
                )
            }
            if let localPort = connection.localPort {
                LabeledContent(
                    "本地端口",
                    value: String(localPort)
                )
            }
            if let tlsVersion = connection.tlsProtocolVersion {
                LabeledContent("TLS", value: tlsVersion)
            }
            if let cipherSuite = connection.tlsCipherSuite {
                LabeledContent(
                    "密码套件",
                    value: cipherSuite
                )
            }
            if isHTTPS {
                LabeledContent(
                    "证书校验",
                    value: allowsUntrustedCertificates
                        ? "允许不受信任"
                        : "系统信任"
                )
            }

            LabeledContent(
                "数据来源",
                value: connection.resourceSource.title
            )
            LabeledContent(
                "连接复用",
                value: yesNo(connection.isReusedConnection)
            )
            LabeledContent(
                "代理连接",
                value: yesNo(connection.isProxyConnection)
            )
            LabeledContent(
                "蜂窝网络",
                value: yesNo(connection.isCellular)
            )
            LabeledContent(
                "高成本路径",
                value: yesNo(connection.isExpensive)
            )
            LabeledContent(
                "低数据模式",
                value: yesNo(connection.isConstrained)
            )
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "是" : "否"
    }
}
