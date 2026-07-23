# NetTool

NetTool 是一个面向 iPhone 和 iPad 的个人网络诊断工具箱。项目以原生 SwiftUI
界面承载结构化网络工具，不启动子进程，也不依赖 Network Extension。

## 当前状态

Step 0 已包含：

- iOS 26 SwiftUI 应用骨架；
- Ping、DNS、TCP、TLS、HTTP、Traceroute、端口扫描和网络信息入口；
- 应用版本与运行环境页面；
- 内存运行日志、文本选择、清除和系统分享；
- 独立的 `NetToolCore` Swift Package 与基础测试；
- GitHub Actions 无签名 IPA 构建。

所有网络工具目前都会显示“规划中”。它们会从 Step 1 开始逐项实现。

## 工程布局

```text
Config/                 App 配置与 Info.plist
Packages/NetToolCore/   可独立测试的纯 Swift 核心
Sources/App/            App 入口、元数据和日志
Sources/Features/       SwiftUI 功能页面
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
4. 上传 `NetTool-unsigned.ipa` artifact。

下载 artifact 并解压后，可将 IPA 导入 LiveContainer。若要直接安装，则需要由
SideStore、AltStore 或其他签名工具重新签名。

在具备 Apple 工具链的 macOS 上，也可以直接运行：

```bash
bash scripts/build_unsigned_ipa.sh
```

## 计划

1. Ping
2. DNS（UDP、TCP、DoT、DoH）
3. TCP、TLS 与 HTTP
4. Traceroute 与 TCP 端口扫描
5. 接口、地址、路由和 Resolver 信息
