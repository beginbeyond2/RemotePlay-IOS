# RemotePlay iOS

Micsig 示波器远程控制 App 的 iOS 版本（v2.0.2），由 Android 原生项目转换而来。

> 原 Android 项目位于 `../RemotePlay/app/`，对应版本 v1.4.0（versionCode 4）。
> 协议、行协议与按钮码完全保持兼容，示波器端不需要任何改动。

## 1. 环境要求

| 工具 | 版本 | 说明 |
|------|------|------|
| Xcode | 14.0+ | 必需（iOS 16 SDK） |
| iOS Deployment Target | 16.0 | 最低支持系统 |
| iOS 兼容 | 16.x / 17.x | 已适配两条主线 |
| Swift | 5.0+ | 已包含在 Xcode |
| macOS | 12+ | 编译主机的操作系统 |
| XcodeGen（可选） | 2.32+ | 用于从 `project.yml` 一键生成 `.xcodeproj` |

## 2. 项目结构

```
RemotePlay-iOS/                          # 仓库位置：与 Android RemotePlay/ 同级
├── project.yml                          # XcodeGen 配置
├── README.md                            # 本文档
└── RemotePlay/
    ├── App/
    │   └── RemotePlayApp.swift          # @main 入口
    ├── Views/
    │   ├── ContentView.swift            # 根视图：HStack(视频区 + 控制栏)
    │   ├── VideoDisplayView.swift       # AVSampleBufferDisplayLayer 包装
    │   └── ControlPanelView.swift       # 右侧 7 按钮 + IP 输入
    ├── Networking/
    │   ├── RemoteClient.swift           # TCP（NWConnection）客户端
    │   └── CommandBuilder.swift         # 12 字节上行控制指令
    ├── Decoder/
    │   └── H264Decoder.swift            # VideoToolbox H.264 硬解
    ├── ViewModel/
    │   └── RemotePlayViewModel.swift    # 状态机与业务中枢
    └── Resources/
        ├── Info.plist                   # iOS 应用清单
        ├── Assets.xcassets/             # 图标 / 颜色集
        ├── en.lproj/Localizable.strings # 英文
        └── zh-Hans.lproj/Localizable.strings # 简体中文
```

> 注：本工程在 v2.0.1 起从 `arm/RemotePlay/iOS/` 移到 `arm/RemotePlay-iOS/`，
> 旧路径下的工程可通过 `arm/RemotePlay/snapshots/v2.0.0-ios-released.zip` 还原。

## 3. 生成 Xcode 工程

### 方式 A：使用 XcodeGen（推荐）

```bash
# 安装（仅一次）
brew install xcodegen

# 在 macOS 上执行（v2.0.1 起的路径）
cd ../RemotePlay-iOS
xcodegen generate
open RemotePlay.xcodeproj
```

### 方式 B：手动创建

如果无法安装 XcodeGen，可按下列步骤手动建立工程：

1. 打开 Xcode → **File → New → Project → iOS → App**。
2. 配置：
   - Product Name: `RemotePlay`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Bundle Identifier: `com.micsig.tbook.remoteplay`
   - Minimum Deployments: **iOS 16.0**
3. 删除模板自动生成的 `ContentView.swift` 与 `RemotePlayApp.swift`。
4. 把整个 `RemotePlay/` 目录（除 `Resources/Info.plist`）拖入项目左侧导航栏，勾选 **Copy items if needed** 与 **Create groups**。
5. **Project → Info → Localizations**：点击 `+` 添加 `English` 与 `Chinese (Simplified)`。
6. 把 `Resources/Assets.xcassets`、`Resources/en.lproj/`、`Resources/zh-Hans.lproj/` 加入 **Build Phases → Copy Bundle Resources**。
7. 设置 `INFOPLIST_FILE = RemotePlay/Resources/Info.plist`。
8. **Signing & Capabilities** → 勾选 **Automatic**，选择自己的 Team（或留空用模拟器跑）。

## 4. 运行

- 真机/模拟器：选择 `iPhone 13/14/15` 等横屏设备，⌘R 运行。
- 真机调试：需在 **设置 → 通用 → VPN 与设备管理** 信任证书。
- 局域网：在底部 IP 框输入示波器 IP（默认端口 8888），回车即连。

## 5. 与 Android 端对应关系

| Android | iOS | 作用 |
|---------|-----|------|
| `MainActivity.java` | `RemotePlayApp.swift` + `ContentView.swift` + `RemotePlayViewModel.swift` | 应用入口、UI、状态机 |
| `Socket.java` | `RemoteClient.swift` | TCP 连接（Android 用 `java.net.Socket`，iOS 用 `Network.framework` 的 `NWConnection`） |
| `MediaCodec` H.264 解码 | `H264Decoder.swift` | H.264 硬解（iOS 用 `VideoToolbox`） |
| `SurfaceView` | `VideoDisplayView.swift` 中的 `AVSampleBufferDisplayLayer` | 视频帧显示 |
| `findViewById + OnClickListener` | SwiftUI `@StateObject` + `.onTapGesture` / `DragGesture` | UI 事件 |
| `SharedPreferences` | `UserDefaults.standard` | IP 持久化 |
| `Toast.makeText(...).show()` | 顶部状态条（`viewModel.toastMessage`） | 通知 |
| `layout/activity_main.xml` | `ContentView.swift` HStack + VStack | 布局 |
| `drawable/button.xml` | SwiftUI `RoundedRectangle` + `LinearGradient` | 按钮样式 |
| `drawable/ic_home/ic_up/ic_down` | SF Symbols `house.fill` / `arrow.up.circle.fill` / `arrow.down.circle.fill` | 矢量图标 |
| `mipmap/ic_launcher` | `Assets.xcassets/AppIcon` | App 图标 |
| `values/strings.xml` | `en.lproj/Localizable.strings` | 英文文案 |
| `values-zh/strings.xml` | `zh-Hans.lproj/Localizable.strings` | 中文文案 |
| `AndroidManifest.xml` `screenOrientation="sensorLandscape"` | `Info.plist` `UISupportedInterfaceOrientations` | 横屏锁定 |
| `AndroidManifest.xml` `INTERNET` 权限 | `NSLocalNetworkUsageDescription` | 局域网说明（iOS 14+ 必需） |
| `FLAG_KEEP_SCREEN_ON` | `UIApplication.shared.isIdleTimerDisabled = true` | 屏幕常亮 |

## 6. 通信协议

### 下行（示波器 → App）
```
[4 字节 frameType] [4 字节 frameLen] [frameLen 字节 H.264 帧]
```
- `frameType[1]` 第 7 位 = RUN/STOP（1=RUN, 0=STOP）
- `frameType[1]` 第 5 位 = SEQ 状态
- `frameType[1]` 第 2 位 = AUTO 状态
- 其余字节为 H.264 视频（含 `0x00 0x00 0x00 0x01` start code）

### 上行（App → 示波器，12 字节）
```
[0x01 触摸 / 0x02 按钮]
[0x01 按下 / 0x00 抬起]
[0x00][0x00]
[int32 小端 x 坐标 或 按钮编码]
[int32 小端 y 坐标 或 0x00/0x01]
```

按钮编码：
- `0x08` RUN/STOP
- `0x09` SEQ
- `0x30` AUTO
- `0x31` 50%
- `0x61` HOME
- `0x51` UP
- `down` 按钮 = 4 个连续的 `clickPoint(200/800, y/600, press)` 触摸指令

## 7. 常见问题

**Q: 编译报错 "Cannot find 'TouchCaptureView' in scope"**
A: 确认 `Views/ContentView.swift` 已加入编译目标（Target Membership）。

**Q: 模拟器无法连接真机示波器**
A: 模拟器共享宿主机的网络，可直接使用；如失败检查防火墙。

**Q: 视频黑屏**
A: 用 Xcode → Devices → Console 查看 `H264Decoder` 与 `RemoteClient` 的 NSLog，确认 SPS/PPS 是否到达。

**Q: 局域网弹窗不出现**
A: iOS 14+ 必须在 `Info.plist` 中配置 `NSLocalNetworkUsageDescription`，本工程已配置。

## 8. 版本与变更

参见仓库根目录 `CHANGELOG.md`。
当前 iOS 版本：**v2.0.2**（CFBundleShortVersionString=2.0.2，CFBundleVersion=3，最低 iOS 16.0，已适配 iOS 17）。
