# 四端局域网媒体控制器 (Windows / macOS / iOS / Android)

极简局域网跨设备播放器后台控制工具：
- **页面最上方**：实时显示当前连接的**局域网名称 (Wi-Fi SSID / 网络名称)** 与本机局域网 IP。
- **播放器卡片列表**：涵盖 **Windows、macOS、iOS、Android** 四端播放器。
- **每个播放器仅保留 4 项核心操作**：
  1. **拖动进度条开始**：拖拽滑块松手后，跳转到目标进度并自动开始播放。
  2. **⏮ 上一章**：切换到上一曲/上一章。
  3. **▶ 播放 / ⏸ 暂停**：控制当前播放器开始或暂停。
  4. **⏭ 下一章**：切换到下一曲/下一章。

---

## 目录结构

- `ui/index.html`：统一控制端单页面（自适应桌面与移动端）
- `desktop/server.js`：Windows & macOS 桌面后台常驻服务（UDP `19888` 自动发现 + HTTP `19889` 控制服务）
- `desktop/win-media-bridge.ps1`：Windows 原生 WinRT `GlobalSystemMediaTransportControlsSessionManager` + 硬件媒体键桥接
- `ios/LanMediaController/`：iOS 原生 SwiftUI 工程源码（内置无声混音 `.mixWithOthers` 后台保活 + `MediaRemote` / `MPMusicPlayerController` 控制）
- `android/app/`：Android 原生 Kotlin 工程源码（内置 `ForegroundService` 后台常驻 + `MediaSessionManager` 全局播放控制）

---

## 快速启动方式

### 1. Windows 端
- 双击运行 `start-windows.bat`（或完全无黑框后台运行 `start-windows-background.vbs`）。
- 也可以在终端执行：
  ```powershell
  node desktop/server.js
  ```

### 2. macOS 端
- 双击运行 `start-macos.command`，或在终端执行：
  ```bash
  node desktop/server.js
  ```

### 3. iOS 端与 Android 端
- **免编译即刻使用**：手机连入同一 Wi-Fi 后，直接用浏览器访问电脑端显示的局域网地址（例如 `http://192.168.x.x:19889`），添加到主屏幕即可作为全屏控制器使用。
- **原生后台被控端编译**：
  - **iOS**：使用 Xcode 打开 `ios/LanMediaController` 目录下的源码签名安装到手机，即可实现 iOS 后台无声保活与系统播放器被控。
  - **Android**：使用 Android Studio 打开 `android/` 目录编译安装，并在系统设置中授予“通知使用权”以允许控制第三方播放器。
