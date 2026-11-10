import Foundation
import AVFoundation
import MediaPlayer
import NetworkExtension
import UIKit

/// 房间内单个设备播放器数据模型
struct PlayerItem: Identifiable, Codable {
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
}

/// iOS 原生局域网媒体控制与房间同步引擎 (纯局域网 UDP 广播 + HTTP 互连，零外部依赖，毫秒级响应)
final class MediaRemoteBridge: ObservableObject {
    static let shared = MediaRemoteBridge()

    @Published var lanName: String = "Rogers4808"
    @Published var deviceName: String = UIDevice.current.name
    @Published var currentRoomCode: String = ""
    @Published var roomPlayers: [PlayerItem] = []

    private let deviceId = "ios-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "device")"
    private let udpPort: UInt16 = 19888
    private var udpSock: Int32 = -1
    private var audioEngine: AVAudioEngine?
    private var tickTimer: Timer?
    private var peerScanTimer: Timer?

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
    private var remoteLastSeenMap: [String: TimeInterval] = [:]
    private var knownPeerIps = Set<String>()
    private var peerHttpPorts: [String: Int] = [:]

    private init() {
        loadMediaRemoteSymbols()
        setupSilentAudioKeepAlive()
        fetchCurrentWiFiName()
        setupUDPSocket()
        refreshRoomPlayers()

        // 默认将 Mac 当前 IP 加入已知 Peer，实现秒级握手
        knownPeerIps.insert("10.0.0.94")
        peerHttpPorts["10.0.0.94"] = 19889

        // 1 秒心跳定时器
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        // 局域网 HTTP 同步定时器 (1.2 秒一次直接拉取对端状态)
        peerScanTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.syncWithKnownPeers()
        }
    }

    // ============================================================================
    // 房间控制：创建、加入、退出
    // ============================================================================

    /// 独立开房间：生成 4 位数匹配码
    func createRoom() {
        let code = String(Int.random(in: 1000...9999))
        joinRoom(code: code)
    }

    /// 加入房间：输入 4 位数匹配码
    func joinRoom(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, Int(trimmed) != nil else { return }
        currentRoomCode = trimmed
        remoteMap.removeAll()
        remoteLastSeenMap.removeAll()
        refreshRoomPlayers()

        // 立即向局域网广播进入房间
        broadcastUDPState()
        syncWithKnownPeers()
    }

    /// 退出房间
    func leaveRoom() {
        currentRoomCode = ""
        remoteMap.removeAll()
        remoteLastSeenMap.removeAll()
        broadcastUDPState()
        refreshRoomPlayers()
    }

    // ============================================================================
    // 局域网 HTTP 同步 (直接穿透 UDP 阻断，与 Mac/Windows 毫秒级稳定互通)
    // ============================================================================

    private func syncWithKnownPeers() {
        guard !currentRoomCode.isEmpty else { return }

        for ip in knownPeerIps {
            let port = peerHttpPorts[ip] ?? 19889
            guard let url = URL(string: "http://\(ip):\(port)/api/state?deviceId=\(deviceId)&roomCode=\(currentRoomCode)&platform=ios&deviceName=\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "iOS")") else { continue }

            var req = URLRequest(url: url)
            req.timeoutInterval = 1.0
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                DispatchQueue.main.async {
                    if let netLan = json["lanName"] as? String, !netLan.isEmpty,
                       self.lanName == "正在获取局域网..." || self.lanName == "局域网 Wi-Fi" {
                        self.lanName = netLan
                    }

                    // 1) 解析房内设备列表
                    if let roomDevs = json["roomDevices"] as? [[String: Any]] {
                        for d in roomDevs {
                            guard let devId = d["deviceId"] as? String, devId != self.deviceId else { continue }
                            let rCode = d["roomCode"] as? String ?? ""
                            if rCode == self.currentRoomCode {
                                let p = d["player"] as? [String: Any] ?? [:]
                                let item = PlayerItem(
                                    deviceId: devId,
                                    deviceName: d["deviceName"] as? String ?? "设备",
                                    platform: d["platform"] as? String ?? "macos",
                                    roomCode: rCode,
                                    title: p["title"] as? String ?? "第 1 章",
                                    isPlaying: p["isPlaying"] as? Bool ?? false,
                                    position: p["position"] as? Double ?? 0,
                                    duration: p["duration"] as? Double ?? 300,
                                    ip: d["ip"] as? String ?? ip,
                                    httpPort: d["httpPort"] as? Int ?? port
                                )
                                self.remoteMap[devId] = item
                                self.remoteLastSeenMap[devId] = Date().timeIntervalSince1970
                            }
                        }
                    }

                    // 2) 解析 selfDevice
                    if let selfDev = json["selfDevice"] as? [String: Any],
                       let devId = selfDev["deviceId"] as? String, devId != self.deviceId {
                        let rCode = selfDev["roomCode"] as? String ?? ""
                        if rCode == self.currentRoomCode {
                            let p = selfDev["player"] as? [String: Any] ?? [:]
                            let item = PlayerItem(
                                deviceId: devId,
                                deviceName: selfDev["deviceName"] as? String ?? "设备",
                                platform: selfDev["platform"] as? String ?? "macos",
                                roomCode: rCode,
                                title: p["title"] as? String ?? "第 1 章",
                                isPlaying: p["isPlaying"] as? Bool ?? false,
                                position: p["position"] as? Double ?? 0,
                                duration: p["duration"] as? Double ?? 300,
                                ip: selfDev["ip"] as? String ?? ip,
                                httpPort: selfDev["httpPort"] as? Int ?? port
                            )
                            self.remoteMap[devId] = item
                            self.remoteLastSeenMap[devId] = Date().timeIntervalSince1970
                        }
                    }

                    self.refreshRoomPlayers()
                }
            }.resume()
        }
    }

    // ============================================================================
    // 局域网 UDP 广播与消息处理 (19888 端口)
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

        if !senderIP.isEmpty && senderIP != "127.0.0.1" && senderIP != "0.0.0.0" {
            knownPeerIps.insert(senderIP)
            if let p = json["httpPort"] as? Int, p > 0 {
                peerHttpPorts[senderIP] = p
            }
        }

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
                DispatchQueue.main.async {
                    for d in devArr {
                        guard let devId = d["deviceId"] as? String, devId != self.deviceId else { continue }
                        let rCode = d["roomCode"] as? String ?? ""
                        if !self.currentRoomCode.isEmpty && rCode == self.currentRoomCode {
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
                                httpPort: d["httpPort"] as? Int ?? (self.peerHttpPorts[senderIP] ?? 19889)
                            )
                            self.remoteMap[devId] = item
                            self.remoteLastSeenMap[devId] = Date().timeIntervalSince1970
                        }
                    }
                    self.refreshRoomPlayers()
                }
            }
        } else if type == "state" {
            guard let devId = json["deviceId"] as? String, devId != deviceId else { return }
            let rCode = json["roomCode"] as? String ?? ""
            if !self.currentRoomCode.isEmpty && rCode == self.currentRoomCode {
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
                    self.remoteLastSeenMap[devId] = Date().timeIntervalSince1970
                    self.refreshRoomPlayers()
                }
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
            // 向全局广播 + 已知所有局域网对端单播发送
            sendUDP(data: data, toIP: "255.255.255.255", port: udpPort)
            for ip in knownPeerIps {
                sendUDP(data: data, toIP: ip, port: udpPort)
            }
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
        broadcastUDPState()
        refreshRoomPlayers()
    }

    func sendControl(to item: PlayerItem, action: String, position: Double? = nil) {
        if item.deviceId == deviceId {
            executeLocalCommand(action: action, position: position)
            return
        }

        // 1. 本地乐观更新 UI
        if var peer = remoteMap[item.deviceId] {
            if action == "play" { peer.isPlaying = true }
            else if action == "pause" { peer.isPlaying = false }
            else if action == "toggle" { peer.isPlaying.toggle() }
            else if action == "seek", let p = position { peer.position = p; peer.isPlaying = true }
            remoteMap[item.deviceId] = peer
            refreshRoomPlayers()
        }

        // 2. 局域网 HTTP POST 直接控制 (0 延迟，极速生效)
        let cmdObj: [String: Any] = [
            "targetDeviceId": item.deviceId,
            "action": action,
            "position": position ?? 0
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cmdObj),
           let url = URL(string: "http://\(item.ip):\(item.httpPort)/api/control") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 1.0
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            URLSession.shared.dataTask(with: req).resume()
        }

        // 3. 同时通过局域网 UDP 广播指令备用
        let udpCmd: [String: Any] = [
            "type": "command",
            "targetDeviceId": item.deviceId,
            "action": action,
            "position": position ?? 0
        ]
        if let data = try? JSONSerialization.data(withJSONObject: udpCmd) {
            sendUDP(data: data, toIP: item.ip, port: udpPort)
            sendUDP(data: data, toIP: "255.255.255.255", port: udpPort)
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

        // 清理超过 10 秒未响应的离线设备
        let now = Date().timeIntervalSince1970
        var cleaned = false
        for (id, lastSeen) in remoteLastSeenMap {
            if now - lastSeen > 10.0 {
                remoteMap.removeValue(forKey: id)
                remoteLastSeenMap.removeValue(forKey: id)
                cleaned = true
            }
        }

        broadcastUDPState()
        if cleaned {
            refreshRoomPlayers()
        }
    }

    private func refreshRoomPlayers() {
        guard !currentRoomCode.isEmpty else {
            self.roomPlayers = []
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
        self.roomPlayers = list
    }
}
