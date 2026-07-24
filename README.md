# NetTool

NetTool 是一个面向 iPhone 和 iPad 的个人网络诊断工具箱。项目以原生 SwiftUI
界面承载结构化网络工具，不启动子进程，也不依赖 Network Extension。

## 当前状态

Step 2 已包含：

- iOS 26 SwiftUI 应用骨架；
- 可选择 IPv4、IPv6 或自动解析的 Ping；
- Ping 次数、发送间隔、超时与 payload 参数；
- 实时响应、TTL、RTT、丢包与 min/avg/max/mdev 统计；
- 运行取消、文本结果分享与运行日志；
- UDP、TCP、DoT 和 DoH DNS 查询；
- 普通 DNS 可自定义服务器与端口，DoT 可自定义主机与端口；
- DoH 使用 RFC 8484 POST，可自定义 HTTPS URL；
- 常用大陆与国际公共 DNS 预置，并按传输方式显示可用端点；
- A、AAAA、CNAME、NS、MX、TXT、SOA、SRV、CAA 和 PTR；
- DNS Header、Flags、RCODE、Answer、Authority、Additional 与原始报文；
- TCP、TLS、HTTP、Traceroute、端口扫描和网络信息入口；
- 应用版本与运行环境页面；
- 独立的 `NetToolCore` Swift Package 与基础测试；
- GitHub Actions 无签名 IPA 构建。

除 Ping 和 DNS 外的网络工具目前显示“规划中”，会在后续步骤逐项实现。

UDP 查询直接向指定服务器发送数据报；TCP 与 DoT 使用两字节长度前缀承载 DNS
报文；DoH 仅接受 HTTPS 与 `application/dns-message`。DoT 使用系统信任链严格
验证证书。若响应设置了 `TC` 标志，应用会明确提示截断，不会自动切换协议。

域名输入目前要求 ASCII。IDNA、EDNS、自定义数字 QTYPE 和 DNSSEC 记录解析暂缓
实现。

## 工程布局

```text
Config/                 App 配置与 Info.plist
Packages/NetToolCore/   可独立测试的纯 Swift 核心
Sources/App/            App 入口、元数据和日志
Sources/Features/       SwiftUI 功能页面
Sources/Networking/     iOS 网络实现
Vendor/Licenses/        借鉴的开源项目许可证
project.yml             XcodeGen 工程描述
.github/workflows/      CI 测试与 IPA 构建
```

`NetTool.xcodeproj` 由 XcodeGen 生成，不纳入版本控制。

## 在 macOS 构建

需要：

- macOS 26；
- Xcode 26.5；
- XcodeGen 2.45.4 或更高版本。

```bash
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild \
  -project NetTool.xcodeproj \
  -scheme NetTool \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

核心包可以单独测试：

```bash
swift test --package-path Packages/NetToolCore
```

Linux 环境可以编辑和审查源码，但 iOS App 必须使用 Apple 工具链完成最终编译。

## 获取 IPA

推送到 GitHub 后，`Build unsigned IPA` 工作流会：

1. 运行 `NetToolCore` 测试；
2. 使用 XcodeGen 生成工程；
3. 使用 Xcode 26.5 构建未签名 App；
4. 根据最近的 Git tag 和提交生成 Arch VCS 风格版本；
5. 上传带版本号的 IPA artifact。

下载 artifact 并解压后，可将 IPA 导入 LiveContainer。若要直接安装，则需要由
SideStore、AltStore 或其他签名工具重新签名。

例如，tag `v0.0.1` 后第 3 个提交会生成：

```text
NetTool-0.0.1.r3.gabcdef0.ipa
```

构建要求仓库至少存在一个 Git tag，不会在缺少 tag 时生成猜测版本。

在具备 Apple 工具链的 macOS 上，也可以直接运行：

```bash
bash scripts/build_unsigned_ipa.sh
```

## 计划

1. Ping（已完成）
2. DNS（UDP、TCP、DoT、DoH 已完成）
3. TCP、TLS 与 HTTP
4. Traceroute 与 TCP 端口扫描
5. 接口、地址、路由和 Resolver 信息

## 开源致谢

Ping 的 Darwin socket 实现借鉴了 MIT 许可的
[NetDiagnosis](https://github.com/453jerry/NetDiagnosis)。项目保留了对应的许可证文本：
`Vendor/Licenses/NetDiagnosis-MIT.txt`。
