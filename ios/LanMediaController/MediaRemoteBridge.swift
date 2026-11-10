import Foundation
import AVFoundation
import MediaPlayer
import NetworkExtension
import UIKit

/// 房间内单个设备播放器数据模型
struct PlayerItem: Identifiable, Codable, Equatable {
    var id: String { deviceId }
    var deviceId: String
    var deviceName: String
    var platform: String
    var roomCode: String
    var title: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var ip: String
    var httpPort: Int

    static func == (lhs: PlayerItem, rhs: PlayerItem) -> Bool {
        return lhs.deviceId == rhs.deviceId &&
               lhs.deviceName == rhs.deviceName &&
               lhs.platform == rhs.platform &&
               lhs.roomCode == rhs.roomCode &&
               lhs.title == rhs.title &&
               lhs.isPlaying == rhs.isPlaying &&
               abs(lhs.position - rhs.position) < 1.0 &&
               abs(lhs.duration - rhs.duration) < 1.0
    }
}

/// iOS 后台保活 + 4位数房间匹配系统 + 双通道实时同步 (ntfy.sh Relay + LAN UDP) + 系统媒体控制
final class MediaRemoteBridge: ObservableObject {
    static let shared = MediaRemoteBridge()

    @Published var lanName: String = "正在获取局域网..."
    @Published var deviceName: String = UIDevice.current.name
    @Published var currentRoomCode: String = ""
    @Published var roomPlayers: [PlayerItem] = []

    private let deviceId = "ios-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "device")"
    private let udpPort: UInt16 = 19888
    private var udpSock: Int32 = -1
    private var audioEngine: AVAudioEngine?
    private var tickTimer: Timer?
    private var relayPollTimer: Timer?

    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
    private typealias MRMediaRemoteSetElapsedTimeFunc = @convention(c) (Double) -> Void

    private var sendCommandPtr: MRMediaRemoteSendCommandFunc?
    private var setElapsedTimePtr: MRMediaRemoteSetElapsedTimeFunc?

    private let kMRPlay: UInt32 = 0
    private let kMRPause: UInt32 = 1
    private let kMRTogglePlayPause: UInt32 = 2
    private let kMRNextTrack: UInt32 = 4
    private let kMRPreviousTrack: UInt32 = 5

    private var localIsPlaying: Bool = false
    private var localPosition: Double = 0
    private var localDuration: Double = 300
    private var localTitle: String = "第 1 章"
    private var remoteMap: [String: PlayerItem] = [:]
    private var peerLastTsMap: [String: Double] = [:]
    private var executedCmdIds = Set<String>()
    private var lastPollTimestamp: Double = 0
    private var isPollingRelay: Bool = false

    private let relayBase = "https://ntfy.sh"
    private let lobbyTopic = "lmc_sync_lobby_v3_global"

    private init() {
        loadMediaRemoteSymbols()
        setupSilentAudioKeepAlive()
        fetchCurrentWiFiName()
        setupUDPSocket()
        refreshRoomPlayers()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        // 定期向 Lobby 发送与拉取房间广播
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollLobbyRelay()
        }
        pollLobbyRelay()
    }

    // ============================================================================
    // 房间控制：创建、加入、退出
    // ============================================================================

    /// 独立开房间：生成 4 位数匹配码
    func createRoom() {
        let code = String(Int.random(in: 1000...9999))
        joinRoomInternal(code: code, isNewJoin: true)
    }

    /// 加入房间：输入 4 位数匹配码
    func joinRoom(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, Int(trimmed) != nil else { return }
        joinRoomInternal(code: trimmed, isNewJoin: true)
    }

    private func joinRoomInternal(code: String, isNewJoin: Bool) {
        currentRoomCode = code
        remoteMap.removeAll()
        peerLastTsMap.removeAll()
        lastPollTimestamp = Date().timeIntervalSince1970 - 120
        refreshRoomPlayers()

        // 1. 广播 Presence 到 Relay
        broadcastRoomPresence(isNewJoin: isNewJoin)
        // 2. 广播到 Lobby
        broadcastLobbyRelay()
        // 3. UDP 本地广播
        broadcastUDPState()

        // 4. 启动房间 Relay 轮询
        startRoomRelayPolling()
    }

    /// 退出房间
    func leaveRoom() {
        let oldRoom = currentRoomCode
        if !oldRoom.isEmpty {
            publishRelay(topic: "lmc_sync_room_v3_\(oldRoom)", payload: [
                "type": "leave",
                "roomCode": oldRoom,
                "deviceId": deviceId,
                "ts": Int(Date().timeIntervalSince1970 * 1000)
            ])
        }
        currentRoomCode = ""
        stopRoomRelayPolling()
        remoteMap.removeAll()
        peerLastTsMap.removeAll()
        broadcastUDPState()
        refreshRoomPlayers()
    }

    // ============================================================================
    // Relay 通道 (ntfy.sh) - 消除历史消息重放导致的界面闪烁
    // ============================================================================

    private func publishRelay(topic: String, payload: [String: Any]) {
        guard let url = URL(string: "\(relayBase)/\(topic)"),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    private func broadcastRoomPresence(isNewJoin: Bool = false) {
        guard !currentRoomCode.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "presence",
            "isNewJoin": isNewJoin,
            "roomCode": currentRoomCode,
            "lanName": lanName,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "device": [
                "deviceId": deviceId,
                "deviceName": deviceName,
                "platform": "ios",
                "roomCode": currentRoomCode,
                "player": [
                    "title": localTitle,
                    "isPlaying": localIsPlaying,
                    "position": localPosition,
                    "duration": localDuration
                ],
                "lastSeen": Int(Date().timeIntervalSince1970 * 1000)
            ]
        ]
        publishRelay(topic: "lmc_sync_room_v3_\(currentRoomCode)", payload: payload)
    }

    private func broadcastLobbyRelay() {
        let payload: [String: Any] = [
            "type": "lobby_announce",
            "senderId": deviceId,
            "lanName": lanName,
            "roomCode": currentRoomCode,
            "ts": Int(Date().timeIntervalSince1970 * 1000)
        ]
        publishRelay(topic: lobbyTopic, payload: payload)
    }

    private func pollLobbyRelay() {
        guard let url = URL(string: "\(relayBase)/\(lobbyTopic)/json?poll=1&since=2h") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let rawJson = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                   let msgStr = rawJson["message"] as? String,
                   let msg = try? JSONSerialization.jsonObject(with: Data(msgStr.utf8)) as? [String: Any] {
                    if let netLan = msg["lanName"] as? String, !netLan.isEmpty,
                       self.lanName == "正在获取局域网..." || self.lanName == "局域网 Wi-Fi" {
                        DispatchQueue.main.async { self.lanName = netLan }
                    }
                }
            }
        }.resume()
    }

    private func startRoomRelayPolling() {
        stopRoomRelayPolling()
        pollRoomRelayOnce()
        relayPollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.pollRoomRelayOnce()
        }
    }

    private func stopRoomRelayPolling() {
        relayPollTimer?.invalidate()
        relayPollTimer = nil
    }

    private func pollRoomRelayOnce() {
        guard !currentRoomCode.isEmpty, !isPollingRelay else { return }
        let code = currentRoomCode
        let sinceParam = lastPollTimestamp > 0 ? "\(Int(lastPollTimestamp))" : "2m"
        guard let url = URL(string: "\(relayBase)/lmc_sync_room_v3_\(code)/json?poll=1&since=\(sinceParam)") else { return }

        isPollingRelay = true
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            defer { self.isPollingRelay = false }
            guard let data = data, let text = String(data: data, encoding: .utf8) else { return }

            var hasChanges = false
            var shouldReplyPresence = false
            var maxTimestampSeen = self.lastPollTimestamp

            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                guard let outer = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                      let msgStr = outer["message"] as? String,
                      let msg = try? JSONSerialization.jsonObject(with: Data(msgStr.utf8)) as? [String: Any],
                      let room = msg["roomCode"] as? String, room == self.currentRoomCode,
                      let type = msg["type"] as? String else { continue }

                let outerTime = Double(outer["time"] as? Int ?? 0)
                let msgTs = Double(msg["ts"] as? Int ?? 0)
                let eventTs = msgTs > 0 ? msgTs : (outerTime * 1000)

                if outerTime > maxTimestampSeen {
                    maxTimestampSeen = outerTime
                }

                if let remoteLan = msg["lanName"] as? String, !remoteLan.isEmpty,
                   self.lanName == "正在获取局域网..." || self.lanName == "局域网 Wi-Fi" {
                    DispatchQueue.main.async { self.lanName = remoteLan }
                }

                if type == "presence", let dev = msg["device"] as? [String: Any],
                   let peerId = dev["deviceId"] as? String, peerId != self.deviceId {

                    // 时间戳防倒退检查：旧状态决不覆盖新状态
                    let prevTs = self.peerLastTsMap[peerId] ?? 0
                    if eventTs >= prevTs {
                        self.peerLastTsMap[peerId] = eventTs
                        let p = dev["player"] as? [String: Any] ?? [:]
                        let item = PlayerItem(
                            deviceId: peerId,
                            deviceName: dev["deviceName"] as? String ?? "设备",
                            platform: dev["platform"] as? String ?? "windows",
                            roomCode: room,
                            title: p["title"] as? String ?? "第 1 章",
                            isPlaying: p["isPlaying"] as? Bool ?? false,
                            position: p["position"] as? Double ?? 0,
                            duration: p["duration"] as? Double ?? 300,
                            ip: dev["ip"] as? String ?? "127.0.0.1",
                            httpPort: dev["httpPort"] as? Int ?? 19889
                        )
                        self.remoteMap[peerId] = item
                        hasChanges = true
                    }

                    if let isNew = msg["isNewJoin"] as? Bool, isNew {
                        let nowMs = Date().timeIntervalSince1970 * 1000
                        if nowMs - eventTs < 6000 {
                            shouldReplyPresence = true
                        }
                    }
                } else if type == "leave", let peerId = msg["deviceId"] as? String {
                    let prevTs = self.peerLastTsMap[peerId] ?? 0
                    // 只有当 leave 的时间戳晚于最后一次 presence 时，才执行移除！
                    if eventTs >= prevTs {
                        self.peerLastTsMap[peerId] = eventTs
                        self.remoteMap.removeValue(forKey: peerId)
                        hasChanges = true
                    }
                } else if type == "command" {
                    guard let target = msg["targetDeviceId"] as? String, target == self.deviceId else { continue }
                    let cmdId = msg["cmdId"] as? String ?? "\(target)_\(eventTs)"
                    if self.executedCmdIds.contains(cmdId) { continue }
                    self.executedCmdIds.insert(cmdId)

                    let act = msg["action"] as? String ?? "toggle"
                    let pos = msg["position"] as? Double
                    DispatchQueue.main.async {
                        self.executeLocalCommand(action: act, position: pos)
                    }
                }
            }

            if maxTimestampSeen > self.lastPollTimestamp {
                self.lastPollTimestamp = maxTimestampSeen
            }

            // 批量处理完毕后，只在主线程统一刷新一次 UI，彻底杜绝闪烁
            if hasChanges {
                DispatchQueue.main.async {
                    self.refreshRoomPlayers()
                }
            }

            if shouldReplyPresence {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.broadcastRoomPresence(isNewJoin: false)
                }
            }
        }.resume()
    }

    // ============================================================================
    // 系统媒体控制 (MediaRemote + MPMusicPlayerController)
    // ============================================================================

    private func loadMediaRemoteSymbols() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandPtr = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunc.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimePtr = unsafeBitCast(sym, to: MRMediaRemoteSetElapsedTimeFunc.self)
        }
    }

    private func setupSilentAudioKeepAlive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let mainMixer = engine.mainMixerNode
            let output = engine.outputNode
            let format = output.inputFormat(forBus: 0)

            let srcNode = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            engine.attach(srcNode)
            engine.connect(srcNode, to: mainMixer, format: format)
            engine.connect(mainMixer, to: output, format: format)
            mainMixer.outputVolume = 0.0
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("Silent keep-alive error: \(error)")
        }
    }

    func fetchCurrentWiFiName() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                if let ssid = network?.ssid, !ssid.isEmpty {
                    self?.lanName = ssid
                } else if self?.lanName == "正在获取局域网..." {
                    self?.lanName = "局域网 Wi-Fi"
                }
            }
        }
    }

    func executeLocalCommand(action: String, position: Double? = nil) {
        let sysPlayer = MPMusicPlayerController.systemMusicPlayer

        switch action {
        case "play":
            localIsPlaying = true
            _ = sendCommandPtr?(kMRPlay, nil)
            sysPlayer.play()
        case "pause":
            localIsPlaying = false
            _ = sendCommandPtr?(kMRPause, nil)
            sysPlayer.pause()
        case "toggle":
            localIsPlaying.toggle()
            _ = sendCommandPtr?(kMRTogglePlayPause, nil)
            if localIsPlaying { sysPlayer.play() } else { sysPlayer.pause() }
        case "prev":
            localPosition = 0
            localIsPlaying = true
            _ = sendCommandPtr?(kMRPreviousTrack, nil)
            sysPlayer.skipToPreviousItem()
        case "next":
            localPosition = 0
            localIsPlaying = true
            _ = sendCommandPtr?(kMRNextTrack, nil)
            sysPlayer.skipToNextItem()
        case "seek":
            if let pos = position {
                localPosition = pos
                localIsPlaying = true
                setElapsedTimePtr?(pos)
                sysPlayer.currentPlaybackTime = pos
                _ = sendCommandPtr?(kMRPlay, nil)
                sysPlayer.play()
            }
        default:
            break
        }
        broadcastRoomPresence(isNewJoin: false)
        broadcastUDPState()
        refreshRoomPlayers()
    }

    func sendControl(to item: PlayerItem, action: String, position: Double? = nil) {
        if item.deviceId == deviceId {
            executeLocalCommand(action: action, position: position)
            return
        }

        // 1. 本地立即乐观更新 UI
        if var peer = remoteMap[item.deviceId] {
            if action == "play" { peer.isPlaying = true }
            else if action == "pause" { peer.isPlaying = false }
            else if action == "toggle" { peer.isPlaying.toggle() }
            else if action == "seek", let p = position { peer.position = p; peer.isPlaying = true }
            remoteMap[item.deviceId] = peer
            refreshRoomPlayers()
        }

        // 2. 通过 Relay 发布控制命令（所有端同步执行）
        if !currentRoomCode.isEmpty {
            let cmdId = "cmd_\(deviceId)_\(Int(Date().timeIntervalSince1970 * 1000))"
            let cmd: [String: Any] = [
                "type": "command",
                "cmdId": cmdId,
                "ts": Int(Date().timeIntervalSince1970 * 1000),
                "roomCode": currentRoomCode,
                "targetDeviceId": item.deviceId,
                "action": action,
                "position": position ?? 0
            ]
            publishRelay(topic: "lmc_sync_room_v3_\(currentRoomCode)", payload: cmd)
        }

        // 3. 同时通过局域网 UDP / HTTP 直发备用
        let udpCmd: [String: Any] = [
            "type": "command",
            "targetDeviceId": item.deviceId,
            "action": action,
            "position": position ?? 0
        ]
        if let data = try? JSONSerialization.data(withJSONObject: udpCmd) {
            sendUDP(data: data, toIP: item.ip, port: udpPort)
            if item.ip != "127.0.0.1", let url = URL(string: "http://\(item.ip):\(item.httpPort)/api/control") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 1.0
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                URLSession.shared.dataTask(with: req).resume()
            }
        }
    }

    // ============================================================================
    // 局域网 UDP 广播与套接字支持 (防空房间号覆盖)
    // ============================================================================

    private func setupUDPSocket() {
        udpSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard udpSock >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(udpSock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(udpSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = udpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(udpSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while udpSock >= 0 {
            var srcAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &srcAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(udpSock, &buffer, buffer.count, 0, $0, &addrLen)
                }
            }
            guard count > 0 else { continue }
            let data = Data(buffer[0..<count])
            let senderIP = String(cString: inet_ntoa(srcAddr.sin_addr))
            handleIncomingPacket(data: data, senderIP: senderIP)
        }
    }

    private func handleIncomingPacket(data: Data, senderIP: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "command" {
            let target = json["targetDeviceId"] as? String
            if target == nil || target == deviceId {
                let action = json["action"] as? String ?? "toggle"
                let pos = json["position"] as? Double
                DispatchQueue.main.async {
                    self.executeLocalCommand(action: action, position: pos)
                }
            }
        } else if type == "lan_sync" {
            if let remoteLan = json["lanName"] as? String, !remoteLan.isEmpty,
               self.lanName == "正在获取局域网..." || self.lanName == "局域网 Wi-Fi" {
                DispatchQueue.main.async { self.lanName = remoteLan }
            }
            if let devArr = json["devices"] as? [[String: Any]] {
                var changed = false
                for d in devArr {
                    guard let devId = d["deviceId"] as? String, devId != self.deviceId else { continue }
                    // 关键检查：如果 UDP 里的设备没有在相同房间内，决不写入 remoteMap！
                    guard let rCode = d["roomCode"] as? String, !rCode.isEmpty, rCode == self.currentRoomCode else { continue }

                    let p = d["player"] as? [String: Any] ?? [:]
                    let item = PlayerItem(
                        deviceId: devId,
                        deviceName: d["deviceName"] as? String ?? "设备",
                        platform: d["platform"] as? String ?? "windows",
                        roomCode: rCode,
                        title: p["title"] as? String ?? "第 1 章",
                        isPlaying: p["isPlaying"] as? Bool ?? false,
                        position: p["position"] as? Double ?? 0,
                        duration: p["duration"] as? Double ?? 300,
                        ip: d["ip"] as? String ?? senderIP,
                        httpPort: d["httpPort"] as? Int ?? 19889
                    )
                    self.remoteMap[devId] = item
                    changed = true
                }
                if changed {
                    DispatchQueue.main.async {
                        self.refreshRoomPlayers()
                    }
                }
            }
        } else if type == "state" {
            guard let devId = json["deviceId"] as? String, devId != deviceId else { return }
            guard let rCode = json["roomCode"] as? String, !rCode.isEmpty, rCode == self.currentRoomCode else { return }
            let p = json["player"] as? [String: Any] ?? [:]
            let item = PlayerItem(
                deviceId: devId,
                deviceName: json["deviceName"] as? String ?? "设备",
                platform: json["platform"] as? String ?? "ios",
                roomCode: rCode,
                title: p["title"] as? String ?? "第 1 章",
                isPlaying: p["isPlaying"] as? Bool ?? false,
                position: p["position"] as? Double ?? 0,
                duration: p["duration"] as? Double ?? 300,
                ip: json["ip"] as? String ?? senderIP,
                httpPort: json["httpPort"] as? Int ?? 19889
            )
            DispatchQueue.main.async {
                self.remoteMap[devId] = item
                self.refreshRoomPlayers()
            }
        }
    }

    func broadcastUDPState() {
        let state: [String: Any] = [
            "type": "state",
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": "ios",
            "roomCode": currentRoomCode,
            "lanName": lanName,
            "httpPort": 19889,
            "player": [
                "title": localTitle,
                "isPlaying": localIsPlaying,
                "position": localPosition,
                "duration": localDuration
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            sendUDP(data: data, toIP: "255.255.255.255", port: udpPort)
        }
    }

    private func sendUDP(data: Data, toIP: String, port: UInt16) {
        guard udpSock >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(toIP)

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(udpSock, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func tick() {
        let sysPlayer = MPMusicPlayerController.systemMusicPlayer
        if let nowItem = sysPlayer.nowPlayingItem {
            localTitle = nowItem.title ?? localTitle
            localDuration = max(1, nowItem.playbackDuration)
            localPosition = sysPlayer.currentPlaybackTime
            localIsPlaying = (sysPlayer.playbackState == .playing)
        } else if localIsPlaying {
            localPosition = min(localDuration, localPosition + 1)
        }

        // 定期向 Relay 和 UDP 广播自身状态
        if !currentRoomCode.isEmpty {
            broadcastRoomPresence(isNewJoin: false)
        }
        broadcastUDPState()
        refreshRoomPlayers()
    }

    private func refreshRoomPlayers() {
        guard !currentRoomCode.isEmpty else {
            if !self.roomPlayers.isEmpty {
                self.roomPlayers = []
            }
            return
        }
        let selfItem = PlayerItem(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: "ios",
            roomCode: currentRoomCode,
            title: localTitle,
            isPlaying: localIsPlaying,
            position: localPosition,
            duration: localDuration,
            ip: "127.0.0.1",
            httpPort: 19889
        )
        var list = [selfItem]
        let matched = remoteMap.values.filter { $0.roomCode == currentRoomCode }
        list.append(contentsOf: matched.sorted(by: { $0.deviceName < $1.deviceName }))

        // 仅在列表内容确实发生变化时才更新 @Published，彻底杜绝 SwiftUI 重复刷新闪烁
        if self.roomPlayers != list {
            self.roomPlayers = list
        }
    }
}
