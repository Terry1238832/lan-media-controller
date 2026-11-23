import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var engine: SyncEngine
    @State private var nameInput: String = ""
    @State private var joinCodeInput: String = ""
    @State private var copiedRoom = false

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
                Text("Native macOS · 实时媒体同步")
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
                    Text("本机设备信息")
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

            if engine.currentRoomCode.isEmpty {
                VStack(spacing: 10) {
                    Button(action: { engine.createRoom() }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("独立开房间（生成 4 位匹配码）")
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.06, green: 0.72, blue: 0.5))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        TextField("输入4位码", text: $joinCodeInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .frame(width: 120)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.32))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
                            .onChange(of: joinCodeInput) { val in
                                let filtered = String(val.filter { $0.isNumber }.prefix(4))
                                if filtered != val { joinCodeInput = filtered }
                            }
                            .onSubmit {
                                engine.joinRoom(code: joinCodeInput)
                                joinCodeInput = ""
                            }

                        Button(action: {
                            engine.joinRoom(code: joinCodeInput)
                            joinCodeInput = ""
                        }) {
                            Text("加入房间")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }

                    if !engine.discoveredRooms.isEmpty {
                        HStack(spacing: 6) {
                            Text("局域网房间：")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.55))
                            ForEach(engine.discoveredRooms, id: \.self) { code in
                                Button(action: { engine.joinRoom(code: code) }) {
                                    Text("#\(code)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(red: 0.38, green: 0.65, blue: 0.98))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.18))
                                        .cornerRadius(999)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前房间匹配码")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.6))
                        HStack(spacing: 8) {
                            Text(engine.currentRoomCode)
                                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(red: 0.38, green: 0.65, blue: 0.98))
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(engine.currentRoomCode, forType: .string)
                                copiedRoom = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedRoom = false }
                            }) {
                                Text(copiedRoom ? "已复制" : "复制")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    Button(action: { engine.leaveRoom() }) {
                        Text("退出房间")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
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
                Text(engine.currentRoomCode.isEmpty ? "本机媒体播放器" : "房间内设备播放器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                Spacer()
                let totalCount = 1 + engine.roomPeers.count
                Text(engine.currentRoomCode.isEmpty ? "未加入房间" : "共 \(totalCount) 台设备在线")
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
