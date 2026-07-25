# NetTool

NetTool 是一个面向 iPhone 和 iPad 的个人网络诊断工具箱。项目以原生 SwiftUI
界面承载结构化网络工具，不启动子进程，也不依赖 Network Extension。

## 当前状态

Step 5A 已包含：

- iOS 26 SwiftUI 应用骨架；
- 可选择 IPv4、IPv6 或自动解析的 Ping；
- IPv4/IPv6 ICMP Traceroute，每跳多次探测、超时显示、停止与文本导出；
- Ping 次数、发送间隔、超时与 payload 参数；
- 实时响应、TTL、RTT、丢包与 min/avg/max/mdev 统计；
- 运行取消、文本结果分享与运行日志；
- UDP、TCP、DoT 和 DoH DNS 查询；
- 普通 DNS 可自定义服务器与端口，DoT 可自定义主机与端口；
- DoH 使用 RFC 8484 POST，可自定义 HTTPS URL 与端口；
- 常用公共 DNS 预置，并按传输方式显示可用端点；
- A、AAAA、CNAME、NS、MX、TXT、SOA、SRV、CAA 和 PTR；
- DNS Header、Flags、RCODE、Answer、Authority、Additional 与原始报文；
- TCP Connect，可选择自动、IPv4 或 IPv6；
- TCP 目标、端口和超时设置，以及常用目标与端口预置；
- TCP 实际远端地址、连接耗时与失败原因分类；
- TCP Connect 端口扫描，支持单端口、范围与混合表达式；
- 可调整单端口超时、最大并发和超时重试次数；
- 默认单端口超时为 2 秒，默认最多重试 2 次；
- 扫描使用慢启动并发窗口，明确响应时增长，并记录实际峰值；
- 超时端口在首次扫描结束后分轮重试，每轮之间冷却 500ms；
- 已知响应端口会作为路径健康参考，仅在参考探测也失败时缩小并发窗口；
- 扫描统计开放、关闭、超时、不可达与失败端口，以及实际重试次数；
- 扫描结果仅保留开放端口明细，包含实际远端地址与连接耗时；
- TLS 直连检查，可设置 SNI、IPv4/IPv6、超时、端口和 ALPN；
- 默认使用系统信任链校验，并可显式允许不受信任的证书继续握手；
- TLS 版本、密码套件、ALPN、握手耗时、信任状态和实际远端地址；
- 系统构建的完整证书链，以及 Subject、Issuer、有效期、序列号、SAN、公钥、
  签名算法和 SHA-256 指纹；
- HTTP HEAD 信息，可分开选择 HTTP/HTTPS、输入目标、设置超时与是否跟随重定向；
- HTTP 状态、协议、完整响应头、重定向链与 curl 风格文本导出；
- HTTP DNS、TCP、TLS、首字节和总耗时，以及本地/远端地址和连接属性；
- HTTPS 默认使用系统信任链，也可按次允许不受信任证书；
- 当前路径状态、可用接口、IPv4/IPv6/DNS 支持、链路质量与网关；
- 接口名称、类型、索引、标志、MTU、链路地址和流量统计；
- 接口 IPv4/IPv6 地址、前缀、广播或点对点地址以及地址分类；
- IPv4 ARP 与 IPv6 NDP Neighbor 缓存的只读快照；
- 网络信息文本报告导出，并明确区分空缓存与底层读取错误；
- 应用版本与运行环境页面；
- 独立的 `NetToolCore` Swift Package 与基础测试；
- GitHub Actions 无签名 IPA 构建。

除 Ping、Traceroute、端口扫描、DNS、TCP 连接、TLS 检查、HTTP 信息和当前
网络信息外的网络工具会在后续步骤逐项实现。

UDP 查询直接向指定服务器发送数据报；TCP 与 DoT 使用两字节长度前缀承载 DNS
报文；DoH 仅接受 HTTPS 与 `application/dns-message`。DoT 使用系统信任链严格
验证证书。若响应设置了 `TC` 标志，应用会明确提示截断，不会自动切换协议。

域名输入目前要求 ASCII。IDNA、EDNS、自定义数字 QTYPE 和 DNSSEC 记录解析暂缓
实现。

HTTP 信息使用 HEAD 请求且不会在服务器拒绝 HEAD 时自动退回 GET；请求关闭缓存，
因此不会下载响应正文。系统网络栈会规范化响应头的名称、顺序和重复字段，所以
“curl -I”区块用于可读与导出，不表示线上字节完全原样。URL 输入将协议与目标
分开，粘贴完整的 HTTP/HTTPS URL 时也会自动同步协议选择。

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
3. TCP、TLS 与 HTTP（已完成）
4. Traceroute 与 TCP 端口扫描（已完成）
5. 当前网络
   - 路径、接口、地址、网关与 Neighbor 缓存（已完成）
   - 完整路由与 IPv6 RA 内核状态（待真机验证后继续）

## 开源致谢

Ping 与 Traceroute 的 Darwin socket 实现借鉴了 MIT 许可的
[NetDiagnosis](https://github.com/453jerry/NetDiagnosis)。项目保留了对应的许可证文本：
`Vendor/Licenses/NetDiagnosis-MIT.txt`。

TCP 端口扫描使用一次解析、非阻塞 `connect()` 和 `poll()` 管理实际活动
socket；动态并发窗口与有限分轮重试策略参考了 Nmap 公开说明的慢启动、
拥塞退让、发起速率限制和自适应重传思路。默认首轮最多发起 100 个连接/秒，
两个重试轮依次降为 50 和 25 个连接/秒；扫描会单独显示重试轮进度和
App/系统超时来源。项目没有复制或链接 Nmap 源码。

证书字段解析使用 Apache 2.0 许可的
[swift-certificates 1.19.3](https://github.com/apple/swift-certificates/tree/1.19.3)。

Neighbor 缓存读取方式参考 Apple 开源的
[network_cmds/ndp](https://github.com/apple-oss-distributions/network_cmds/blob/main/ndp.tproj/ndp.c)
和 XNU 路由消息 ABI。应用只读取 `PF_ROUTE` 的 `RTF_LLINFO` 快照，不会为了
填充列表而主动探测局域网。
