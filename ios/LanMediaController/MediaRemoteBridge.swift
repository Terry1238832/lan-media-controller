import Foundation
import AVFoundation
import MediaPlayer
import NetworkExtension
import UIKit

/// Objective-C 动态选择器桥接协议 (用于零头文件调用 MediaRemote.framework 私有类)
@objc private protocol MRDynamicObjC {
    @objc optional func localOrigin() -> AnyObject?
    @objc optional func defaultPlayer() -> AnyObject?
    @objc optional func defaultPlaybackQueueRequest() -> AnyObject?
    @objc optional func proactiveDestination() -> AnyObject?
    @objc optional func localDestination() -> AnyObject?
    @objc optional func localIsPlaying() -> Bool
    @objc optional func localNowPlayingItem() -> AnyObject?
    @objc optional func localNowPlayingPlayerPath() -> AnyObject?

    @objc optional func initWithBundleIdentifier(_ bundleId: NSString) -> AnyObject?
    @objc optional func initWithOrigin(_ origin: AnyObject?, client: AnyObject?, player: AnyObject?) -> AnyObject?
    @objc optional func initWithPlayerPath(_ playerPath: AnyObject?) -> AnyObject?
    @objc optional func initWithDestination(_ destination: AnyObject?) -> AnyObject?
    @objc optional func initWithConfiguration(_ configuration: AnyObject?) -> AnyObject?
    @objc optional func beginLoadingUpdates()

    @objc optional func setRequestPlaybackState(_ flag: Bool)
    @objc optional func setRequestPlaybackQueue(_ flag: Bool)
    @objc optional func setRequestClientProperties(_ flag: Bool)
    @objc optional func setIncludeMetadata(_ flag: Bool)
    @objc optional func setPlaybackQueueRequest(_ req: AnyObject?)
    @objc optional func setSingleShot(_ flag: Bool)

    @objc optional func response() -> AnyObject?
    @objc optional func playerPath() -> AnyObject?
    @objc optional func playbackState() -> Int32
    @objc optional func _mostRelevantItem() -> AnyObject?
    @objc optional func metadata() -> AnyObject?
    @objc optional func title() -> NSString?
    @objc optional func trackArtistName() -> NSString?
    @objc optional func duration() -> Double
    @objc optional func elapsedTime() -> Double
    @objc optional func calculatedPlaybackPosition() -> Double
    @objc optional func client() -> AnyObject?
    @objc optional func displayName() -> NSString?
    @objc optional func bundleIdentifier() -> NSString?
}

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

/// iOS 原生局域网媒体控制与房间同步引擎 (纯局域网 UDP 广播 + HTTP /api/lan-sync 双向互连)
final class MediaRemoteBridge: ObservableObject {
    static let shared = MediaRemoteBridge()

    @Published var lanName: String = "Rogers4808"
    @Published var deviceName: String = UIDevice.current.name
    @Published var currentRoomCode: String = ""
    @Published var roomPlayers: [PlayerItem] = []

    private let deviceId = "ios-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "device")"
    private let udpPort: UInt16 = 19888
    private var udpSock: Int32 = -1
    private var tickTimer: Timer?
    private var peerScanTimer: Timer?

    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
    private typealias MRMediaRemoteSetElapsedTimeFunc = @convention(c) (Double) -> Void
    private typealias MRMediaRemoteGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias MRMediaRemoteGetNowPlayingAppIsPlayingFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    private var sendCommandPtr: MRMediaRemoteSendCommandFunc?
    private var setElapsedTimePtr: MRMediaRemoteSetElapsedTimeFunc?
    private var getNowPlayingInfoPtr: MRMediaRemoteGetNowPlayingInfoFunc?
    private var getNowPlayingIsPlayingPtr: MRMediaRemoteGetNowPlayingAppIsPlayingFunc?

    private var mrControllers: [(label: String, ctrl: AnyObject)] = []

    private let kMRPlay: UInt32 = 0
    private let kMRPause: UInt32 = 1
    private let kMRTogglePlayPause: UInt32 = 2
    private let kMRNextTrack: UInt32 = 4
    private let kMRPreviousTrack: UInt32 = 5

    private var localIsPlaying: Bool = false
    private var localPosition: Double = 0
    private var localDuration: Double = 300
    private var localTitle: String = "第 1 章"
    private var lastManualCmdTime: TimeInterval = 0

    private var remoteMap: [String: PlayerItem] = [:]
    private var remoteLastSeenMap: [String: TimeInterval] = [:]
    private var knownPeerIps = Set<String>()
    private var peerHttpPorts: [String: Int] = [:]
    private var lastSubnetScanTime: TimeInterval = 0

    private init() {
        loadMediaRemoteSymbols()
        setupAudioSessionWithoutHijacking()
        requestMusicLibraryAccessIfNeeded()
        setupMediaRemoteControllers()
        fetchCurrentWiFiName()
        setupUDPSocket()

        // 默认将局域网常见主机加入已知 Peer，并启动局域网自动发现
        knownPeerIps.insert("10.0.0.94")
        peerHttpPorts["10.0.0.94"] = 19889

        pollLocalMediaState()
        refreshRoomPlayers()
        scanSubnetIfNeeded()

        // 1 秒心跳定时器
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        // 局域网 HTTP /api/lan-sync 双向同步定时器 (1.0 秒一次)
        peerScanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        pollLocalMediaState()
        refreshRoomPlayers()

        // 立即向局域网广播并同步进入房间
        broadcastUDPState()
        scanSubnetIfNeeded()
        syncWithKnownPeers()
    }

    /// 退出房间
    func leaveRoom() {
        currentRoomCode = ""
        remoteMap.removeAll()
        remoteLastSeenMap.removeAll()
        broadcastUDPState()
        syncWithKnownPeers()
        refreshRoomPlayers()
    }

    // ============================================================================
    // 局域网 HTTP /api/lan-sync 双向状态同步 (不污染对端本地设备表，直接同步歌曲名与进度)
    // ============================================================================

    private func buildLanSyncPayload() -> [String: Any] {
        let localIp = getWiFiAddress() ?? "127.0.0.1"
        return [
            "type": "lan_sync",
            "senderHostId": deviceId,
            "lanName": lanName,
            "ip": localIp,
            "httpPort": 19889,
            "rooms": currentRoomCode.isEmpty ? [] : [currentRoomCode],
            "devices": [
                [
                    "deviceId": deviceId,
                    "deviceName": deviceName,
                    "platform": "ios",
                    "roomCode": currentRoomCode,
                    "ip": localIp,
                    "httpPort": 19889,
                    "player": [
                        "title": localTitle,
                        "isPlaying": localIsPlaying,
                        "position": round(localPosition),
                        "duration": round(localDuration),
                        "chapterIndex": 1
                    ]
                ]
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
    }

    private func syncWithKnownPeers() {
        let payload = buildLanSyncPayload()
        guard let postData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let selfIp = getWiFiAddress() ?? ""
        for ip in Array(knownPeerIps) {
            if ip.isEmpty || ip == "127.0.0.1" || ip == selfIp { continue }
            let ports: [Int]
            if let knownPort = peerHttpPorts[ip] {
                ports = [knownPort]
            } else {
                ports = [19889, 8889]
            }
            for port in ports {
                sendHttpLanSync(toIP: ip, port: port, postData: postData)
            }
        }
    }

    private func sendHttpLanSync(toIP ip: String, port: Int, postData: Data) {
        guard let url = URL(string: "http://\(ip):\(port)/api/lan-sync") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = postData

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            DispatchQueue.main.async {
                self.knownPeerIps.insert(ip)
                self.peerHttpPorts[ip] = port
                self.ingestSyncDictionary(json, senderIP: ip, defaultPort: port)
            }
        }.resume()
    }

    private func ingestSyncDictionary(_ json: [String: Any], senderIP: String, defaultPort: Int) {
        if let netLan = json["lanName"] as? String, !netLan.isEmpty,
           netLan != "正在获取局域网..." && netLan != "macOS 局域网" && netLan != "Local Network" && netLan != "<redacted>",
           (self.lanName == "正在获取局域网..." || self.lanName == "局域网 Wi-Fi" || self.lanName == "Rogers4808") {
            self.lanName = netLan
        }

        if let cmds = json["pendingCommands"] as? [[String: Any]] {
            for cmd in cmds {
                let target = cmd["targetDeviceId"] as? String
                if target == nil || target == self.deviceId {
                    let action = cmd["action"] as? String ?? "toggle"
                    let pos = (cmd["position"] as? NSNumber)?.doubleValue
                    self.executeLocalCommand(action: action, position: pos)
                }
            }
        }

        guard let devArr = json["devices"] as? [[String: Any]] else { return }
        var updated = false
        for d in devArr {
            guard let devId = d["deviceId"] as? String, devId != self.deviceId else { continue }
            let rCode = d["roomCode"] as? String ?? ""
            if !self.currentRoomCode.isEmpty && rCode == self.currentRoomCode {
                let p = d["player"] as? [String: Any] ?? [:]
                let title = (p["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "第 1 章"
                let isPlaying = p["isPlaying"] as? Bool ?? false
                let pos = (p["position"] as? NSNumber)?.doubleValue ?? 0
                let dur = max(1, (p["duration"] as? NSNumber)?.doubleValue ?? 300)
                let devIp = (d["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? senderIP
                let devPort = (d["httpPort"] as? NSNumber)?.intValue ?? defaultPort

                let item = PlayerItem(
                    deviceId: devId,
                    deviceName: d["deviceName"] as? String ?? "设备",
                    platform: d["platform"] as? String ?? "macos",
                    roomCode: rCode,
                    title: title,
                    isPlaying: isPlaying,
                    position: pos,
                    duration: dur,
                    ip: devIp,
                    httpPort: devPort
                )
                self.remoteMap[devId] = item
                self.remoteLastSeenMap[devId] = Date().timeIntervalSince1970
                updated = true
            } else if self.remoteMap[devId] != nil && rCode != self.currentRoomCode {
                self.remoteMap.removeValue(forKey: devId)
                self.remoteLastSeenMap.removeValue(forKey: devId)
                updated = true
            }
        }
        if updated {
            self.refreshRoomPlayers()
        }
    }

    private func scanSubnetIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastSubnetScanTime > 12.0 else { return }
        guard let selfIp = getWiFiAddress() else { return }
        let parts = selfIp.split(separator: ".")
        guard parts.count == 4, let selfLast = Int(parts[3]) else { return }
        lastSubnetScanTime = now

        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let payload = buildLanSyncPayload()
        guard let postData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        for i in 1...254 where i != selfLast {
            let targetIp = "\(prefix)\(i)"
            let delay = Double(i % 25) * 0.04
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendHttpLanSync(toIP: targetIp, port: 19889, postData: postData)
                self?.sendHttpLanSync(toIP: targetIp, port: 8889, postData: postData)
            }
        }
    }

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    if !ip.isEmpty && ip != "127.0.0.1" {
                        address = ip
                        if name == "en0" { break }
                    }
                }
            }
        }
        return address
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
        setsockopt(udpSock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

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
        var buffer = [UInt8](repeating: 0, count: 16384)
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

        let selfIp = getWiFiAddress() ?? ""
        if !senderIP.isEmpty && senderIP != "127.0.0.1" && senderIP != "0.0.0.0" && senderIP != selfIp {
            DispatchQueue.main.async {
                self.knownPeerIps.insert(senderIP)
                if let p = (json["httpPort"] as? NSNumber)?.intValue, p > 0 {
                    self.peerHttpPorts[senderIP] = p
                }
            }
        }

        if type == "command" {
            let target = json["targetDeviceId"] as? String
            if target == nil || target == deviceId {
                let action = json["action"] as? String ?? "toggle"
                let pos = (json["position"] as? NSNumber)?.doubleValue
                DispatchQueue.main.async {
                    self.executeLocalCommand(action: action, position: pos)
                }
            }
        } else if type == "lan_sync" {
            let port = (json["httpPort"] as? NSNumber)?.intValue ?? (peerHttpPorts[senderIP] ?? 19889)
            DispatchQueue.main.async {
                self.ingestSyncDictionary(json, senderIP: senderIP, defaultPort: port)
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
                    title: (p["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "第 1 章",
                    isPlaying: p["isPlaying"] as? Bool ?? false,
                    position: (p["position"] as? NSNumber)?.doubleValue ?? 0,
                    duration: max(1, (p["duration"] as? NSNumber)?.doubleValue ?? 300),
                    ip: json["ip"] as? String ?? senderIP,
                    httpPort: (json["httpPort"] as? NSNumber)?.intValue ?? 19889
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
        let syncPayload = buildLanSyncPayload()
        if let syncData = try? JSONSerialization.data(withJSONObject: syncPayload) {
            sendUDP(data: syncData, toIP: "255.255.255.255", port: udpPort)
            for ip in knownPeerIps {
                sendUDP(data: syncData, toIP: ip, port: udpPort)
            }
        }

        let statePayload: [String: Any] = [
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
                "position": round(localPosition),
                "duration": round(localDuration)
            ]
        ]
        if let stateData = try? JSONSerialization.data(withJSONObject: statePayload) {
            sendUDP(data: stateData, toIP: "255.255.255.255", port: udpPort)
            for ip in knownPeerIps {
                sendUDP(data: stateData, toIP: ip, port: udpPort)
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
    // 系统媒体识别与控制 (MediaRemote.framework + MPMusicPlayerController)
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
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfoPtr = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getNowPlayingIsPlayingPtr = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingAppIsPlayingFunc.self)
        }
    }

    /// 使用 .ambient + .mixWithOthers，绝不抢占系统 NowPlaying 会话，也不打断 QQ音乐 / Apple Music / 网易云音乐
    private func setupAudioSessionWithoutHijacking() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 忽略音频会话设置异常
        }
    }

    /// 请求系统音乐库权限，使 MPMusicPlayerController.systemMusicPlayer 可读取 Apple Music 当前曲目
    private func requestMusicLibraryAccessIfNeeded() {
        let status = MPMediaLibrary.authorizationStatus()
        if status == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in }
        }
    }

    private func allocObj(_ cls: AnyClass) -> AnyObject? {
        let allocSel = NSSelectorFromString("alloc")
        guard (cls as AnyObject).responds(to: allocSel) else { return nil }
        return (cls as AnyObject).perform(allocSel)?.takeUnretainedValue()
    }

    private func setupMediaRemoteControllers() {
        guard let origCls = NSClassFromString("MROrigin"),
              let clientCls = NSClassFromString("MRClient"),
              let playerCls = NSClassFromString("MRPlayer"),
              let pathCls = NSClassFromString("MRPlayerPath"),
              let destCls = NSClassFromString("MRDestination"),
              let cfgCls = NSClassFromString("MRNowPlayingControllerConfiguration"),
              let ctrlCls = NSClassFromString("MRNowPlayingController"),
              let pqReqCls = NSClassFromString("MRPlaybackQueueRequest") else {
            return
        }

        func addController(dest: AnyObject?, label: String) {
            guard let dest = dest,
                  let cfg = allocObj(cfgCls)?.initWithDestination?(dest) else { return }
            cfg.setRequestPlaybackState?(true)
            cfg.setRequestPlaybackQueue?(true)
            cfg.setRequestClientProperties?(true)
            if let pqr = (pqReqCls as AnyObject).defaultPlaybackQueueRequest?() {
                pqr.setIncludeMetadata?(true)
                cfg.setPlaybackQueueRequest?(pqr)
            }
            cfg.setSingleShot?(false)
            if let ctrl = allocObj(ctrlCls)?.initWithConfiguration?(cfg) {
                ctrl.beginLoadingUpdates?()
                mrControllers.append((label: label, ctrl: ctrl))
            }
        }

        addController(dest: (destCls as AnyObject).proactiveDestination?(), label: "")
        addController(dest: (destCls as AnyObject).localDestination?(), label: "")

        let localOrig = (origCls as AnyObject).localOrigin?()
        let defPlayer = (playerCls as AnyObject).defaultPlayer?()
        let candidateBundles: [(bid: String, name: String)] = [
            ("com.tencent.QQMusic", "QQ音乐"),
            ("com.tencent.QQMusicMac", "QQ音乐"),
            ("com.netease.163music", "网易云音乐"),
            ("com.apple.Music", "Apple Music"),
            ("com.spotify.client", "Spotify"),
            ("tv.danmaku.bili", "哔哩哔哩"),
            ("tv.danmaku.bilianime", "哔哩哔哩"),
            ("com.bilibili.bilibili", "哔哩哔哩"),
            ("com.apple.mobilesafari", "Safari")
        ]

        for entry in candidateBundles {
            if let client = allocObj(clientCls)?.initWithBundleIdentifier?(entry.bid as NSString),
               let ppath = allocObj(pathCls)?.initWithOrigin?(localOrig, client: client, player: defPlayer),
               let dest = allocObj(destCls)?.initWithPlayerPath?(ppath) {
                addController(dest: dest, label: entry.name)
            }
        }
    }

    private func normalizeAppName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("qqmusic") || lower.contains("qq音乐") { return "QQ音乐" }
        if lower.contains("163music") || lower.contains("netease") || lower.contains("网易云") { return "网易云音乐" }
        if lower.contains("spotify") { return "Spotify" }
        if lower.contains("com.apple.music") || raw == "Music" || raw == "音乐" { return "Apple Music" }
        if lower.contains("bili") || lower.contains("哔哩") { return "哔哩哔哩" }
        if lower.contains("safari") { return "Safari" }
        return raw
    }

    private func formatTrackDisplay(appName: String, title: String, artist: String) -> String {
        var display = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanArtist.isEmpty && !display.contains(cleanArtist) {
            display = display.isEmpty ? cleanArtist : "\(display) - \(cleanArtist)"
        }
        let cleanApp = normalizeAppName(appName.trimmingCharacters(in: .whitespacesAndNewlines))
        if !cleanApp.isEmpty && !display.isEmpty && !display.contains(cleanApp) {
            display = "\(cleanApp) · \(display)"
        }
        return display
    }

    /// 综合探测本机正在播放的曲目 (MediaRemote 控制器 + MRNowPlayingRequest + MPMusicPlayerController + AVAudioSession)
    private func pollLocalMediaState() {
        let inGrace = (Date().timeIntervalSince1970 - lastManualCmdTime) < 1.5
        var detectedTitle: String = ""
        var detectedDuration: Double = 0
        var detectedPosition: Double = -1
        var detectedPlaying: Bool? = nil

        // 1. 优先通过 MediaRemote MRNowPlayingRequest 直接读取
        if let reqCls = NSClassFromString("MRNowPlayingRequest") {
            let reqObj = reqCls as AnyObject
            let isPl = reqObj.localIsPlaying?()
            var appName = ""
            if let ppath = reqObj.localNowPlayingPlayerPath?(),
               let client = ppath.client?() {
                if let dn = client.displayName?() as String?, !dn.isEmpty {
                    appName = dn
                } else if let bid = client.bundleIdentifier?() as String?, !bid.isEmpty {
                    appName = bid
                }
            }
            if let item = reqObj.localNowPlayingItem?(),
               let meta = item.metadata?() {
                let rawTitle = (meta.title?() as String?) ?? ""
                let rawArtist = (meta.trackArtistName?() as String?) ?? ""
                if !rawTitle.isEmpty {
                    detectedTitle = formatTrackDisplay(appName: appName, title: rawTitle, artist: rawArtist)
                    detectedPlaying = isPl
                    let dur = meta.duration?() ?? 0
                    if dur > 0 { detectedDuration = dur }
                    let elapsed = meta.elapsedTime?() ?? -1
                    let calcPos = meta.calculatedPlaybackPosition?() ?? -1
                    if isPl == true && calcPos >= 0 && (dur <= 0 || calcPos <= dur + 2) {
                        detectedPosition = calcPos
                    } else if elapsed >= 0 {
                        detectedPosition = elapsed
                    }
                }
            }
        }

        // 2. 通过常驻 MRNowPlayingController 实例读取 (覆盖 QQ音乐 / 网易云 / Apple Music / Spotify)
        if detectedTitle.isEmpty {
            var bestFallback: (title: String, dur: Double, pos: Double, playing: Bool)? = nil
            for entry in mrControllers {
                guard let resp = entry.ctrl.response?(),
                      let item = resp._mostRelevantItem?(),
                      let meta = item.metadata?() else { continue }
                let rawTitle = (meta.title?() as String?) ?? ""
                guard !rawTitle.isEmpty else { continue }
                let rawArtist = (meta.trackArtistName?() as String?) ?? ""
                var appName = entry.label
                if appName.isEmpty,
                   let ppath = resp.playerPath?(),
                   let client = ppath.client?() {
                    if let dn = client.displayName?() as String?, !dn.isEmpty {
                        appName = dn
                    } else if let bid = client.bundleIdentifier?() as String?, !bid.isEmpty {
                        appName = bid
                    }
                }
                let formatted = formatTrackDisplay(appName: appName, title: rawTitle, artist: rawArtist)
                let state = resp.playbackState?() ?? 0
                let isPl = (state == 1)
                let dur = max(0, meta.duration?() ?? 0)
                let elapsed = max(0, meta.elapsedTime?() ?? 0)
                let calcPos = meta.calculatedPlaybackPosition?() ?? -1
                let pos: Double
                if isPl && calcPos >= 0 && (dur <= 0 || calcPos <= dur + 2) {
                    pos = calcPos
                } else {
                    pos = elapsed
                }

                if isPl {
                    detectedTitle = formatted
                    detectedDuration = dur
                    detectedPosition = pos
                    detectedPlaying = true
                    break
                } else if bestFallback == nil {
                    bestFallback = (formatted, dur, pos, false)
                }
            }
            if detectedTitle.isEmpty, let fb = bestFallback {
                detectedTitle = fb.title
                detectedDuration = fb.dur
                detectedPosition = fb.pos
                detectedPlaying = fb.playing
            }
        }

        // 3. 通过 MPMusicPlayerController.systemMusicPlayer 读取 iOS 系统音乐 (Apple Music)
        let sysPlayer = MPMusicPlayerController.systemMusicPlayer
        if detectedTitle.isEmpty, let nowItem = sysPlayer.nowPlayingItem {
            let rawTitle = nowItem.title ?? ""
            let rawArtist = nowItem.artist ?? ""
            if !rawTitle.isEmpty {
                detectedTitle = formatTrackDisplay(appName: "Apple Music", title: rawTitle, artist: rawArtist)
                detectedDuration = max(1, nowItem.playbackDuration)
                let curPos = sysPlayer.currentPlaybackTime
                if curPos.isFinite && curPos >= 0 {
                    detectedPosition = curPos
                }
                detectedPlaying = (sysPlayer.playbackState == .playing)
            }
        }

        // 4. 异步调用 MRMediaRemoteGetNowPlayingInfo 补充 (若 C 接口可用)
        if let getInfo = getNowPlayingInfoPtr {
            getInfo(DispatchQueue.main) { [weak self] dict in
                guard let self = self, let info = dict as? [String: Any] else { return }
                let rawTitle = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
                guard !rawTitle.isEmpty else { return }
                let rawArtist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
                let formatted = self.formatTrackDisplay(appName: "", title: rawTitle, artist: rawArtist)
                if !formatted.isEmpty {
                    self.localTitle = formatted
                }
                if let dur = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue, dur > 0 {
                    self.localDuration = dur
                }
                if let el = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue, el >= 0,
                   !self.localIsPlaying {
                    self.localPosition = min(self.localDuration, el)
                }
            }
        }

        // 5. 应用探测到的曲目信息与播放状态
        if !detectedTitle.isEmpty {
            localTitle = detectedTitle
        }
        if detectedDuration > 0 {
            localDuration = round(detectedDuration)
        }
        if !inGrace {
            if let isPl = detectedPlaying {
                localIsPlaying = isPl
            } else {
                // 若沙盒限制跨应用读取但 AVAudioSession 检测到其它音频正在输出
                let otherAudio = AVAudioSession.sharedInstance().isOtherAudioPlaying
                if otherAudio {
                    localIsPlaying = true
                    if localTitle == "第 1 章" || localTitle.hasSuffix("已暂停") {
                        localTitle = "iOS 媒体 · 正在播放"
                    }
                } else if localTitle == "iOS 媒体 · 正在播放" {
                    localIsPlaying = false
                    localTitle = "iOS 媒体 · 已暂停"
                }
            }

            if detectedPosition >= 0 {
                localPosition = min(localDuration, round(detectedPosition))
            } else if localIsPlaying {
                localPosition = min(localDuration, localPosition + 1)
            }
        } else if localIsPlaying {
            localPosition = min(localDuration, localPosition + 1)
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
        lastManualCmdTime = Date().timeIntervalSince1970
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
                localPosition = max(0, min(localDuration, round(pos)))
                localIsPlaying = true
                setElapsedTimePtr?(pos)
                sysPlayer.currentPlaybackTime = pos
                _ = sendCommandPtr?(kMRPlay, nil)
                sysPlayer.play()
            }
        default:
            break
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pollLocalMediaState()
            self?.refreshRoomPlayers()
            self?.broadcastUDPState()
            self?.syncWithKnownPeers()
        }

        broadcastUDPState()
        syncWithKnownPeers()
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
            req.timeoutInterval = 1.2
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.syncWithKnownPeers()
                }
            }.resume()
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
        pollLocalMediaState()

        // 对远端正在播放的设备平滑推进进度条
        for (id, var peer) in remoteMap {
            if peer.isPlaying {
                peer.position = min(peer.duration, peer.position + 1)
                remoteMap[id] = peer
            }
        }

        // 清理超过 12 秒未响应的离线设备
        let now = Date().timeIntervalSince1970
        for (id, lastSeen) in remoteLastSeenMap {
            if now - lastSeen > 12.0 {
                remoteMap.removeValue(forKey: id)
                remoteLastSeenMap.removeValue(forKey: id)
            }
        }

        broadcastUDPState()
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
            ip: getWiFiAddress() ?? "127.0.0.1",
            httpPort: 19889
        )
        var list = [selfItem]
        let matched = remoteMap.values.filter { $0.roomCode == currentRoomCode }
        list.append(contentsOf: matched.sorted(by: { $0.deviceName < $1.deviceName }))
        self.roomPlayers = list
    }
}
