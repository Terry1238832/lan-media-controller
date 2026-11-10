import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = MediaRemoteBridge.shared
    @State private var inputRoomCode: String = ""

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.09, blue: 0.16)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    // 1. 页面最上方：显示当前局域网名称
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前局域网")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(bridge.lanName)
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(red: 0.12, green: 0.16, blue: 0.23))
                    .cornerRadius(16)

                    // 2. 输入设备名 + 独立开房间/加入房间/退出房间
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当前设备名称 (iOS)")
                            .font(.caption.bold())
                            .foregroundColor(.gray)

                        TextField("输入设备名称", text: $bridge.deviceName)
                            .padding(10)
                            .background(Color(red: 0.06, green: 0.09, blue: 0.16))
                            .foregroundColor(.white)
                            .cornerRadius(10)

                        if bridge.currentRoomCode.isEmpty {
                            Button(action: { bridge.createRoom() }) {
                                Text("+ 独立开房间 (生成4位匹配码)")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }

                            HStack(spacing: 10) {
                                TextField("4位码", text: $inputRoomCode)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 100, height: 42)
                                    .background(Color(red: 0.06, green: 0.09, blue: 0.16))
                                    .foregroundColor(.white)
                                    .cornerRadius(10)

                                Button(action: {
                                    bridge.joinRoom(code: inputRoomCode)
                                    inputRoomCode = ""
                                }) {
                                    Text("加入房间")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                }
                            }
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("房间匹配码")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text(bridge.currentRoomCode)
                                        .font(.title2.bold())
                                        .foregroundColor(.blue)
                                }
                                Spacer()
                                Button(action: { bridge.leaveRoom() }) {
                                    Text("退出房间")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(Color.red.opacity(0.2))
                                        .foregroundColor(.red)
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(red: 0.12, green: 0.16, blue: 0.23))
                    .cornerRadius(16)

                    // 3. 房间内播放器卡片列表（显示设备类型和设备名称）
                    ForEach(bridge.roomPlayers) { item in
                        PlayerCardView(item: item) { action, pos in
                            bridge.sendControl(to: item, action: action, position: pos)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

struct PlayerCardView: View {
    let item: PlayerItem
    let onCommand: (String, Double?) -> Void

    @State private var dragValue: Double = 0
    @State private var isDragging: Bool = false

    private func formatTime(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(item.platform.uppercased())
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(6)

                Text(item.deviceName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                Text(item.title)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            // 拖动进度条开始播放
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isDragging ? dragValue : item.position },
                        set: { newVal in dragValue = newVal }
                    ),
                    in: 0...max(1, item.duration),
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            onCommand("seek", dragValue)
                        }
                    }
                )
                .accentColor(.blue)

                HStack {
                    Text(formatTime(isDragging ? dragValue : item.position))
                    Spacer()
                    Text(formatTime(item.duration))
                }
                .font(.caption2)
                .foregroundColor(.gray)
            }

            // 仅保留：上一章、播放/暂停、下一章
            HStack(spacing: 10) {
                Button(action: { onCommand("prev", nil) }) {
                    Text("⏮ 上一章")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(action: { onCommand("toggle", nil) }) {
                    Text(item.isPlaying ? "⏸ 暂停" : "▶ 播放")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(item.isPlaying ? Color.green : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(action: { onCommand("next", nil) }) {
                    Text("⏭ 下一章")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(16)
    }
}

@main
struct LanMediaControllerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
