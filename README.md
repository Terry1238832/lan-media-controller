# 四端局域网媒体控制器 (LanMediaController v2)

全平台**真正原生重构版**（Windows / macOS / Android / iOS），统一极简界面，实时同步并远程控制同一房间内各设备正在播放的媒体（支持 QQ音乐、网易云音乐、Spotify、Apple Music、浏览器、本地播放器等）。

## 核心特性

- **真实局域网 / Wi-Fi 名称显示**：通过各平台原生网络 API 获取当前 Wi-Fi 名称或真实局域网 IP，无硬编码假数据。
- **独立设备名与 4 位房间匹配码**：每台设备可自定义设备名称，随时独立开房间（生成 4 位数匹配码）、加入房间或退出房间，房间内清晰显示设备类型与名称。
- **极简 4 项媒体控制**：每个播放器仅保留 4 项核心控制：
  1. **拖动进度条并开始播放**
  2. **上一章 / 上一曲 (`⏮`)**
  3. **播放 / 暂停 (`▶ / ⏸`)**
  4. **下一章 / 下一曲 (`⏭`)**
- **局域网直连 + 自动兜底同步**：优先通过局域网 UDP (`41234`) + HTTP (`41235`) 毫秒级直连；若防火墙或路由器 AP 隔离拦截，自动通过房间专属中继通道无缝同步。

## 各平台原生实现

| 平台 | 技术栈 | 系统媒体识别与控制 | 打包产物 |
| :--- | :--- | :--- | :--- |
| **macOS** (`macos/`) | SwiftUI + AppKit (Universal arm64/x86_64) | `ungive/mediaremote-adapter` (`MediaRemoteAdapter.framework` + `/usr/bin/perl`)，支持 macOS 13–27 | `LanMediaController-macOS.dmg` (Apple `hdiutil` 拖拽安装) |
| **Windows** (`windows/`) | C# .NET 8 WPF + WinRT | 原生 WinRT `GlobalSystemMediaTransportControlsSessionManager` + `wlanapi.dll` | `LanMediaController-Windows-Portable.exe` (单文件便携版) |
| **Android** (`android/`) | Kotlin + Android SDK 34 (Gradle) | `NotificationListenerService` + `MediaSessionManager` + 前台同步服务 | `LanMediaController-Android.apk` (已签名) |
| **iOS** (`ios/`) | SwiftUI + MediaPlayer | 统一 LMC v2 同步协议 + `MPMusicPlayerController` | Xcode 工程 (`ios/`) |

## 协议文档

详见 [PROTOCOL.md](PROTOCOL.md)。
