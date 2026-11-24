import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var engine: SyncEngine
    @State private var nameInput: String = ""

    private let bgColor = Color(red: 0.043, green: 0.067, blue: 0.125)
    private let cardBg = Color(red: 0.086, green: 0.125, blue: 0.212)
    private let borderColor = Color.white.opacity(0.08)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    headerBar
                    identityAndRoomCard
                    playersSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 680, idealHeight: 740)
        .onAppear {
            nameInput = engine.deviceName
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("四端局域网媒体控制器")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Native macOS · 启动自动开房")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Image(systemName: "wifi")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.38, green: 0.65, blue: 0.98))
                Text(engine.displayedLanName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(cardBg)
            .overlay(Capsule().stroke(borderColor, lineWidth: 1))
            .clipShape(Capsule())
        }
    }

    private var identityAndRoomCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("本机设备名称")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    PlatformBadge(platform: .macos)
                }

                HStack(spacing: 8) {
                    TextField("输入设备名称（如：书房 MacBook）", text: $nameInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.32))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
                        .onSubmit { engine.saveDeviceName(nameInput) }

                    Button(action: { engine.saveDeviceName(nameInput) }) {
                        Text("保存名称")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(borderColor)

            // Current Room Banner (always active!)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("当前所在房间")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.55))
                        Text(engine.isHostingOwnRoom ? "默认已开房" : "已加入对方房间")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(engine.isHostingOwnRoom ? Color.green : Color(red: 0.38, green: 0.65, blue: 0.98))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((engine.isHostingOwnRoom ? Color.green : Color.blue).opacity(0.18))
                            .cornerRadius(6)
                    }
                    Text(engine.currentRoomName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Spacer()

                if !engine.isHostingOwnRoom {
                    Button(action: { engine.returnToOwnRoom() }) {
                        Text("回到我的房间")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Nearby Discoverable Rooms (One-Click Join, No Code!)
            VStack(alignment: .leading, spacing: 8) {
                Text("可加入的其他设备房间")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.6))

                if engine.availableRooms.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.4))
                        Text("正在自动发现其他设备房间，对方打开软件后可直接点击加入")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(engine.availableRooms) { room in
                            HStack(spacing: 10) {
                                PlatformBadge(platform: room.hostPlatform)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(room.roomName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text("\(room.memberCount) 台设备 · \(room.isLanDirect ? "局域网直连" : "网络发现")")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.5))
                                }
                                Spacer()
                                Button(action: { engine.joinRoom(room) }) {
                                    Text("加入")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Color.blue)
                                        .cornerRadius(9)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color.black.opacity(0.24))
                            .cornerRadius(11)
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(borderColor, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(cardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
    }

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("房间内设备播放器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                Spacer()
                Text("共 \(1 + engine.roomPeers.count) 台设备在线")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 4)

            PlayerCardView(
                deviceName: engine.deviceName,
                platform: .macos,
                connectionMode: .local,
                player: engine.localPlayer,
                nowMs: engine.uiTick,
                onCommand: { action, pos in
                    engine.sendCommand(to: engine.deviceId, action: action, position: pos)
                }
            )

            ForEach(engine.roomPeers) { peer in
                PlayerCardView(
                    deviceName: peer.deviceName,
                    platform: peer.platform,
                    connectionMode: peer.connectionMode,
                    player: peer.player,
                    nowMs: engine.uiTick,
                    onCommand: { action, pos in
                        engine.sendCommand(to: peer.id, action: action, position: pos)
                    }
                )
            }
        }
    }
}

struct PlatformBadge: View {
    let platform: PlatformType

    var body: some View {
        Text(platform.displayName)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(fgColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fgColor.opacity(0.18))
            .cornerRadius(7)
    }

    private var fgColor: Color {
        switch platform {
        case .windows: return Color(red: 0.38, green: 0.65, blue: 0.98)
        case .macos: return Color(red: 0.75, green: 0.52, blue: 0.99)
        case .ios: return Color(red: 0.96, green: 0.45, blue: 0.71)
        case .android: return Color(red: 0.20, green: 0.83, blue: 0.60)
        }
    }
}

struct PlayerCardView: View {
    let deviceName: String
    let platform: PlatformType
    let connectionMode: ConnectionMode
    let player: PlayerState
    let nowMs: Int64
    let onCommand: (String, Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private let cardBg = Color(red: 0.086, green: 0.125, blue: 0.212)

    var body: some View {
        let maxDur = max(1.0, player.duration > 0 ? player.duration : 300.0)
        let displayedPos = isDragging ? dragValue : min(maxDur, player.livePosition(nowMs: nowMs))

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PlatformBadge(platform: platform)
                Text(deviceName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(connectionMode.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(connectionMode == .lan ? Color.green : Color.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(connectionMode == .lan ? Color.green.opacity(0.16) : Color.white.opacity(0.08))
                    .cornerRadius(6)

                Spacer()

                if !player.appName.isEmpty {
                    Text(player.appName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.14))
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(player.isPlaying ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(player.displayTrackLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(player.hasMedia ? Color.white.opacity(0.9) : Color.white.opacity(0.45))
                    .lineLimit(1)
            }

            // Control 1: Draggable progress bar (seeks & starts playback on release)
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayedPos },
                        set: { newVal in
                            dragValue = newVal
                            isDragging = true
                        }
                    ),
                    in: 0...maxDur,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            onCommand("seek", dragValue)
                        }
                    }
                )
                .tint(player.isPlaying ? Color(red: 0.06, green: 0.72, blue: 0.5) : Color.blue)

                HStack {
                    Text(formatSeconds(displayedPos))
                    Spacer()
                    Text(player.duration > 0 ? formatSeconds(player.duration) : "--:--")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
            }

            // Controls 2, 3, 4: Previous, Play/Pause, Next (ONLY these 4 controls total!)
            HStack(spacing: 10) {
                Button(action: { onCommand("prev", 0) }) {
                    Label("上一章", systemImage: "backward.end.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.09))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Button(action: { onCommand("toggle", 0) }) {
                    Label(player.isPlaying ? "暂停" : "播放", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(player.isPlaying ? Color(red: 0.06, green: 0.72, blue: 0.5) : Color.blue)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Button(action: { onCommand("next", 0) }) {
                    Label("下一章", systemImage: "forward.end.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.09))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(cardBg)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(player.isPlaying ? Color.green.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1.2)
        )
    }
}
