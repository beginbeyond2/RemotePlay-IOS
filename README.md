# RemotePlay iOS

iOS 客户端 for Micsig 示波器远程控制。

<!--BEGIN_BUILD_BADGE-->
<sub>📦 Latest build: <b>vios-latest</b> · commit <code>5633a54</code> · 2026-06-25 05:58 UTC · ✅ passing</sub>
<!--END_BUILD_BADGE-->

---

## 状态

| 项 | 状态 |
|---|---|
| CI Build | ![Build](https://github.com/beginbeyond2/RemotePlay-IOS/actions/workflows/build.yml/badge.svg) |
| 最新版本 | vios-latest |
| 平台 | iOS 16+ |
| 架构 | arm64 |
| 适配设备 | iPhone 11 ~ iPhone 17 Pro Max |

---

## 快速开始

### 1. 下载 .ipa

去 [Releases 页面](https://github.com/beginbeyond2/RemotePlay-IOS/releases) 下载最新的 `RemotePlay.ipa`。
（如果 release 缺失，去 [Actions](https://github.com/beginbeyond2/RemotePlay-IOS/actions) → 最新绿色 build → 底部 Artifacts → 下载 `RemotePlay-ipa`。）

### 2. 装签名工具（Windows）

推荐 [3uTools](https://www.3u.com)（中文界面，iOS 26 兼容好）：
- 下载安装
- 顶部 **iDevice** 标签：插 iPhone 自动识别

### 3. 签名 + 安装

1. 3uTools → **工具箱** → **IPA 签名** → 选 `RemotePlay.ipa`
2. 选 **Apple ID 签名** → 输入 Apple ID + 密码
3. 签名完成后 → 顶部 **应用** → **安装** → 选签名后的 IPA

### 4. iPhone 信任 + 启用开发者模式

1. **设置** → **通用** → **VPN 与设备管理** → 信任您 Apple ID
2. **设置** → **隐私与安全性** → **开发者模式** → 开启
3. 重启 iPhone

### 5. 启动 App

- 主屏找 **RemotePlay**（蓝色方块图标）
- 启动后**强制横屏**
- 看到 **Micsig** logo + 7 控制按钮
- 底部 IP 输入框输入示波器 IP → 提交

---

## 功能

### 7 个控制按钮

| 按钮 | 协议 ID | 作用 |
|---|---|---|
| **RUN/STOP** | 0x08 | 启动/停止采集 |
| **SEQ** | 0x09 | 单次触发 |
| **AUTO** | 0x30 | 自动设置 |
| **50%** | 0x31 | 垂直档位归位 |
| **HOME** | 0x61 | 返回主菜单 |
| **MENU** | 0x6f | 菜单键（向下） |
| **UP** | 0x51 | 上方向键 |

### 实时视频

- H.264 硬解码（`VideoToolbox`）
- 25 fps 流畅播放
- 自动接管屏幕

### 触摸同步

- 单击 = 示波器点击
- iOS 端坐标 → 示波器坐标自动映射

### 状态指示灯

按钮颜色变化反映示波器状态（`RUN` / `SEQ` / `AUTO`）。

### 响应式 UI

控制栏自适应屏幕高度，覆盖 iPhone 11 (414pt) ~ iPhone 17 Pro Max (430pt)。

---

## 协议

### 12 字节控制指令（iOS → 示波器）

| 字节 | 含义 | 值 |
|---|---|---|
| 0 | 命令类型 | `0x01`=触摸, `0x02`=按钮 |
| 1 | 动作 | `0x00`=松开, `0x01`=按下 |
| 2-3 | 保留 | `0x0000` |
| 4-7 | 参数 A | 按钮 ID / 触摸 X |
| 8-11 | 参数 B | 触摸 Y / 0 |

### 下行状态位（示波器 → iOS）

| Bit | 含义 |
|---|---|
| 7 | RUN 状态 |
| 5 | SEQ 状态 |
| 2 | AUTO 状态 |

---

## 项目结构

```
RemotePlay-iOS/
├── .github/workflows/      # CI/CD 配置
│   └── build.yml
├── RemotePlay/             # 源代码
│   ├── App/                # App 入口
│   ├── Decoder/            # H.264 硬解码
│   ├── Networking/         # TCP 客户端 + 协议
│   ├── Resources/          # Info.plist + 资源
│   ├── ViewModel/          # 状态管理
│   └── Views/              # SwiftUI 视图
├── project.yml             # XcodeGen 配置
├── README.md               # 本文件
└── CHANGELOG.md            # 变更日志
```

---

## 开发

### 本地编译（需 Mac + Xcode 15+）

```bash
brew install xcodegen
xcodegen generate
open RemotePlay.xcodeproj
# Xcode 选 iPhone → ⌘R
```

### CI 编译

每次 push → GitHub Actions 自动跑 macOS + Xcode 15.0 编译：
- 编译未签名 `.app`
- 打包成 `.ipa`（保留 Unix 权限）
- 上传为 GitHub Release（`ios-latest` 标签）
- **自动更新本 README 的 build 信息**

---

## 变更历史

详见 [CHANGELOG.md](CHANGELOG.md)。

---

## 许可证

待定。
