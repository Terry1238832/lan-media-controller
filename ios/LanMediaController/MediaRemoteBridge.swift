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

/// iOS 后台保活 + 4位数房间匹配系统 + 系统媒体控制 (MediaRemote + MPMusicPlayerController)
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
    private var timer: Timer?

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

    private init() {
        loadMediaRemoteSymbols()
        setupSilentAudioKeepAlive()
        fetchCurrentWiFiName()
        setupUDPSocket()
        refreshRoomPlayers()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 独立开房间：生成 4 位数匹配码
    func createRoom() {
        let code = String(Int.random(in: 1000...9999))
        currentRoomCode = code
        broadcastState()
        refreshRoomPlayers()
    }

    /// 加入房间：输入 4 位数匹配码
    func joinRoom(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, Int(trimmed) != nil else { return }
        currentRoomCode = trimmed
        broadcastState()
        refreshRoomPlayers()
    }

    /// 退出房间
    func leaveRoom() {
        currentRoomCode = ""
        broadcastState()
        refreshRoomPlayers()
    }

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
                } else {
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
        broadcastState()
        refreshRoomPlayers()
    }

    func sendControl(to item: PlayerItem, action: String, position: Double? = nil) {
        if item.deviceId == deviceId {
            executeLocalCommand(action: action, position: position)
            return
        }

        let cmd: [String: Any] = [
            "type": "command",
            "targetDeviceId": item.deviceId,
            "action": action,
            "position": position ?? 0
        ]

        if let data = try? JSONSerialization.data(withJSONObject: cmd) {
            sendUDP(data: data, toIP: item.ip, port: udpPort)
            if let url = URL(string: "http://\(item.ip):\(item.httpPort)/api/control") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                URLSession.shared.dataTask(with: req).resume()
            }
        }
    }

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
            if let remoteLan = json["lanName"] as? String, !remoteLan.isEmpty, lanName == "局域网 Wi-Fi" {
                DispatchQueue.main.async { self.lanName = remoteLan }
            }
            if let devArr = json["devices"] as? [[String: Any]] {
                DispatchQueue.main.async {
                    for d in devArr {
                        guard let devId = d["deviceId"] as? String, devId != self.deviceId else { continue }
                        let p = d["player"] as? [String: Any] ?? [:]
                        let item = PlayerItem(
                            deviceId: devId,
                            deviceName: d["deviceName"] as? String ?? "设备",
                            platform: d["platform"] as? String ?? "windows",
                            roomCode: d["roomCode"] as? String ?? "",
                            title: p["title"] as? String ?? "第 1 章",
                            isPlaying: p["isPlaying"] as? Bool ?? false,
                            position: p["position"] as? Double ?? 0,
                            duration: p["duration"] as? Double ?? 300,
                            ip: d["ip"] as? String ?? senderIP,
                            httpPort: d["httpPort"] as? Int ?? 19889
                        )
                        self.remoteMap[devId] = item
                    }
                    self.refreshRoomPlayers()
                }
            }
        } else if type == "state" {
            guard let devId = json["deviceId"] as? String, devId != deviceId else { return }
            let p = json["player"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                let item = PlayerItem(
                    deviceId: devId,
                    deviceName: json["deviceName"] as? String ?? "设备",
                    platform: json["platform"] as? String ?? "ios",
                    roomCode: json["roomCode"] as? String ?? "",
                    title: p["title"] as? String ?? "第 1 章",
                    isPlaying: p["isPlaying"] as? Bool ?? false,
                    position: p["position"] as? Double ?? 0,
                    duration: p["duration"] as? Double ?? 300,
                    ip: json["ip"] as? String ?? senderIP,
                    httpPort: json["httpPort"] as? Int ?? 19889
                )
                self.remoteMap[devId] = item
                self.refreshRoomPlayers()
            }
        }
    }

    func broadcastState() {
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
        broadcastState()
        refreshRoomPlayers()
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
