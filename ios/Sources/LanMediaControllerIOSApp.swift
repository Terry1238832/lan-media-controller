import SwiftUI
import MediaPlayer
import Network
import Darwin

// iOS SwiftUI client implementing the exact same LMC v2 protocol as macOS, Windows, and Android.
// Open in Xcode (iOS 16+ SwiftUI App target) to build & deploy to iPhone/iPad.

struct IOSPlayerState: Codable, Equatable {
    var appName: String = ""
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var position: Double = 0
    var duration: Double = 0
    var hasMedia: Bool = false
    var updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    func livePosition(nowMs: Int64) -> Double {
        guard hasMedia || duration > 0 else { return 0 }
        let base = max(0, position)
        guard isPlaying else { return duration > 0 ? min(duration, base) : base }
        let cur = base + max(0, Double(nowMs - updatedAt) / 1000.0)
        return duration > 0 ? min(duration, cur) : cur
    }

    var displayTrackLine: String {
        if !hasMedia && title.isEmpty && appName.isEmpty { return "暂无正在播放的媒体" }
        var main = title
        if !artist.isEmpty { main = main.isEmpty ? artist : "\(main) - \(artist)" }
        return main.isEmpty ? (isPlaying ? "正在播放" : "已暂停") : main
    }
}

struct IOSDeviceRecord: Identifiable {
    var id: String
    var deviceName: String
    var platform: String
    var roomCode: String
    var ip: String
    var httpPort: Int
    var lastSeen: Int64
    var lastPacketTs: Int64
    var connectionMode: String
    var player: IOSPlayerState
}

@MainActor
final class IOSSyncEngine: ObservableObject {
    static let udpPort: UInt16 = 41234
    static let multicastGroup = "239.255.42.99"
    static let relayBase = "https://ntfy.sh"

    @Published var deviceName: String
    @Published var currentRoomCode: String = ""
    @Published var displayedLanName: String = "局域网"
    @Published var localPlayer = IOSPlayerState()
    @Published var roomPeers: [IOSDeviceRecord] = []
    @Published var uiTick: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    let deviceId: String
    private var peersById: [String: IOSDeviceRecord] = [:]
    private var executedCmdIds: Set<String> = []
    private var relayTask: Task<Void, Never>?
    private var timer: Timer?
    private let startupMs = Int64(Date().timeIntervalSince1970 * 1000)

    init() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "lmc_v2_ios_id"), !saved.isEmpty {
            deviceId = saved
        } else {
            let id = "ios-" + UUID().uuidString.prefix(8).lowercased()
            d.set(id, forKey: "lmc_v2_ios_id")
            deviceId = id
        }
        deviceName = d.string(forKey: "lmc_v2_ios_name") ?? UIDevice.current.name
    }

    func start() {
        refreshSystemMusic()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uiTick = Int64(Date().timeIntervalSince1970 * 1000)
                self.refreshSystemMusic()
                if !self.currentRoomCode.isEmpty {
                    self.publishPresence()
                }
                self.prunePeers()
            }
        }
    }

    func saveDeviceName(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        deviceName = t
        UserDefaults.standard.set(t, forKey: "lmc_v2_ios_name")
        if !currentRoomCode.isEmpty { publishPresence() }
    }

    func createRoom() {
        joinRoom(code: String(format: "%04d", Int.random(in: 1000...9999)))
    }

    func joinRoom(code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 4, clean.allSatisfy({ $0.isNumber }) else { return }
        currentRoomCode = clean
        peersById.removeAll()
        roomPeers = []
        startRelay(roomCode: clean)
        publishPresence()
    }

    func leaveRoom() {
        let old = currentRoomCode
        currentRoomCode = ""
        relayTask?.cancel()
        peersById.removeAll()
        roomPeers = []
        if !old.isEmpty {
            let payload: [String: Any] = ["v": 2, "type": "leave", "deviceId": deviceId, "roomCode": old, "ts": Int64(Date().timeIntervalSince1970 * 1000)]
            postRelay(roomCode: old, obj: payload)
        }
    }

    func sendCommand(to targetId: String, action: String, position: Double = 0) {
        if targetId == deviceId {
            executeLocalMusicCommand(action: action, position: position)
            return
        }
        guard !currentRoomCode.isEmpty else { return }
        let cmdId = "cmd-\(UUID().uuidString.prefix(8).lowercased())"
        executedCmdIds.insert(cmdId)
        let cmd: [String: Any] = [
            "v": 2, "type": "command", "cmdId": cmdId, "roomCode": currentRoomCode,
            "targetDeviceId": targetId, "action": action, "position": position,
            "ts": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let peer = peersById[targetId], !peer.ip.isEmpty, peer.httpPort > 0,
           let url = URL(string: "http://\(peer.ip):\(peer.httpPort)/api/command"),
           let data = try? JSONSerialization.data(withJSONObject: cmd) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            URLSession.shared.dataTask(with: req).resume()
        }
        postRelay(roomCode: currentRoomCode, obj: cmd)
    }

    private func refreshSystemMusic() {
        let mp = MPMusicPlayerController.systemMusicPlayer
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let item = mp.nowPlayingItem {
            localPlayer = IOSPlayerState(
                appName: "Apple Music",
                title: item.title ?? "",
                artist: item.artist ?? "",
                isPlaying: mp.playbackState == .playing,
                position: max(0, mp.currentPlaybackTime),
                duration: max(0, item.playbackDuration),
                hasMedia: true,
                updatedAt: now
            )
        } else {
            localPlayer.isPlaying = mp.playbackState == .playing
            localPlayer.updatedAt = now
        }
    }

    private func executeLocalMusicCommand(action: String, position: Double) {
        let mp = MPMusicPlayerController.systemMusicPlayer
        switch action {
        case "play": mp.play()
        case "pause": mp.pause()
        case "toggle": mp.playbackState == .playing ? mp.pause() : mp.play()
        case "next": mp.skipToNextItem()
        case "prev": mp.skipToPreviousItem()
        case "seek":
            mp.currentPlaybackTime = max(0, position)
            mp.play()
        default: break
        }
        refreshSystemMusic()
        if !currentRoomCode.isEmpty { publishPresence() }
    }

    private func publishPresence() {
        guard !currentRoomCode.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let obj: [String: Any] = [
            "v": 2, "type": "presence", "deviceId": deviceId, "deviceName": deviceName,
            "platform": "ios", "roomCode": currentRoomCode, "lanName": "",
            "ip": "", "subnet": "", "httpPort": 0, "ts": now,
            "player": [
                "appName": localPlayer.appName, "title": localPlayer.title, "artist": localPlayer.artist,
                "isPlaying": localPlayer.isPlaying, "position": localPlayer.position,
                "duration": localPlayer.duration, "hasMedia": localPlayer.hasMedia, "updatedAt": localPlayer.updatedAt
            ]
        ]
        postRelay(roomCode: currentRoomCode, obj: obj)
    }

    private func startRelay(roomCode: String) {
        relayTask?.cancel()
        guard let url = URL(string: "\(IOSSyncEngine.relayBase)/lmc_v2_r_\(roomCode)/sse?since=2m") else { return }
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let d = raw.data(using: .utf8),
                              let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              (outer["event"] as? String) == "message",
                              let inner = (outer["message"] as? String)?.data(using: .utf8) else { continue }
                        await MainActor.run { [weak self] in self?.handlePacket(inner) }
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func postRelay(roomCode: String, obj: [String: Any]) {
        guard let url = URL(string: "\(IOSSyncEngine.relayBase)/lmc_v2_r_\(roomCode)"),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    private func handlePacket(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if type == "presence" {
            let devId = (obj["deviceId"] as? String) ?? ""
            guard !devId.isEmpty && devId != deviceId else { return }
            let room = (obj["roomCode"] as? String) ?? ""
            guard room == currentRoomCode else { return }
            let ts = (obj["ts"] as? NSNumber)?.int64Value ?? now
            if let existing = peersById[devId], ts < existing.lastPacketTs { return }
            let pObj = obj["player"] as? [String: Any]
            let player = IOSPlayerState(
                appName: (pObj?["appName"] as? String) ?? "",
                title: (pObj?["title"] as? String) ?? "",
                artist: (pObj?["artist"] as? String) ?? "",
                isPlaying: (pObj?["isPlaying"] as? Bool) ?? false,
                position: (pObj?["position"] as? NSNumber)?.doubleValue ?? 0,
                duration: (pObj?["duration"] as? NSNumber)?.doubleValue ?? 0,
                hasMedia: (pObj?["hasMedia"] as? Bool) ?? false,
                updatedAt: (pObj?["updatedAt"] as? NSNumber)?.int64Value ?? now
            )
            peersById[devId] = IOSDeviceRecord(
                id: devId,
                deviceName: (obj["deviceName"] as? String) ?? "设备",
                platform: (obj["platform"] as? String) ?? "windows",
                roomCode: room,
                ip: (obj["ip"] as? String) ?? "",
                httpPort: (obj["httpPort"] as? Int) ?? 41235,
                lastSeen: now,
                lastPacketTs: ts,
                connectionMode: "同步中",
                player: player
            )
            roomPeers = peersById.values.sorted { $0.deviceName < $1.deviceName }
        } else if type == "leave" {
            if let devId = obj["deviceId"] as? String {
                peersById.removeValue(forKey: devId)
                roomPeers = peersById.values.sorted { $0.deviceName < $1.deviceName }
            }
        } else if type == "command" {
            let cmdId = (obj["cmdId"] as? String) ?? ""
            let ts = (obj["ts"] as? NSNumber)?.int64Value ?? 0
            guard !cmdId.isEmpty, !executedCmdIds.contains(cmdId), ts >= startupMs - 5000 else { return }
            executedCmdIds.insert(cmdId)
            if (obj["targetDeviceId"] as? String) == deviceId {
                executeLocalMusicCommand(
                    action: (obj["action"] as? String) ?? "toggle",
                    position: (obj["position"] as? NSNumber)?.doubleValue ?? 0
                )
            }
        }
    }

    private func prunePeers() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        peersById = peersById.filter { now - $0.value.lastSeen < 14_000 }
        roomPeers = peersById.values.sorted { $0.deviceName < $1.deviceName }
    }
}

@main
struct LanMediaControllerIOSApp: App {
    @StateObject private var engine = IOSSyncEngine()

    var body: some Scene {
        WindowGroup {
            IOSContentView(engine: engine)
                .onAppear { engine.start() }
        }
    }
}

struct IOSContentView: View {
    @ObservedObject var engine: IOSSyncEngine
    @State private var nameInput = ""
    @State private var joinCode = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Text("四端局域网媒体控制器")
                        .font(.headline).bold().foregroundColor(.white)
                    Spacer()
                    Text(engine.displayedLanName)
                        .font(.caption).bold().foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.1)).clipShape(Capsule())
                }

                VStack(spacing: 10) {
                    HStack {
                        TextField("设备名称", text: $nameInput)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") { engine.saveDeviceName(nameInput) }
                            .buttonStyle(.borderedProminent)
                    }
                    if engine.currentRoomCode.isEmpty {
                        Button("+ 独立开房间 (生成4位码)") { engine.createRoom() }
                            .buttonStyle(.borderedProminent).tint(.green)
                        HStack {
                            TextField("4位码", text: $joinCode)
                                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            Button("加入房间") { engine.joinRoom(code: joinCode); joinCode = "" }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        HStack {
                            Text("房间码：\(engine.currentRoomCode)")
                                .font(.title2).bold().monospaced().foregroundColor(.blue)
                            Spacer()
                            Button("退出房间") { engine.leaveRoom() }
                                .buttonStyle(.borderedProminent).tint(.red)
                        }
                    }
                }
                .padding().background(Color.white.opacity(0.08)).cornerRadius(14)

                ForEach(engine.roomPeers) { peer in
                    IOSPlayerCard(peer: peer, nowMs: engine.uiTick) { action, pos in
                        engine.sendCommand(to: peer.id, action: action, position: pos)
                    }
                }
            }
            .padding()
        }
        .background(Color(red: 0.043, green: 0.067, blue: 0.125).ignoresSafeArea())
        .onAppear { nameInput = engine.deviceName }
    }
}

struct IOSPlayerCard: View {
    let peer: IOSDeviceRecord
    let nowMs: Int64
    let onCommand: (String, Double) -> Void
    @State private var dragging = false
    @State private var dragVal: Double = 0

    var body: some View {
        let maxDur = max(1.0, peer.player.duration > 0 ? peer.player.duration : 300.0)
        let pos = dragging ? dragVal : min(maxDur, peer.player.livePosition(nowMs: nowMs))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(peer.platform.uppercased()).font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.25)).foregroundColor(.blue).cornerRadius(6)
                Text(peer.deviceName).font(.headline).foregroundColor(.white)
                Spacer()
                if !peer.player.appName.isEmpty {
                    Text(peer.player.appName).font(.caption).foregroundColor(.yellow)
                }
            }
            Text(peer.player.displayTrackLine).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            Slider(value: Binding(get: { pos }, set: { dragVal = $0; dragging = true }), in: 0...maxDur) { editing in
                dragging = editing
                if !editing { onCommand("seek", dragVal) }
            }
            HStack(spacing: 10) {
                Button("⏮ 上一章") { onCommand("prev", 0) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button(peer.player.isPlaying ? "⏸ 暂停" : "▶ 播放") { onCommand("toggle", 0) }
                    .buttonStyle(.borderedProminent).tint(peer.player.isPlaying ? .green : .blue).frame(maxWidth: .infinity)
                Button("⏭ 下一章") { onCommand("next", 0) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
        .padding().background(Color.white.opacity(0.08)).cornerRadius(14)
    }
}
