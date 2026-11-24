import Foundation
import AVFoundation
import MediaPlayer
import Network
import CryptoKit
import UIKit
import Darwin

// MARK: - Unified LMC v2.1 Models (Byte-for-byte compatible with macOS / Windows / Android)

enum IOSPlatformType: String, Codable {
    case windows, macos, ios, android

    var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .macos: return "macOS"
        case .ios: return "iOS"
        case .android: return "Android"
        }
    }
}

enum IOSConnectionMode: String {
    case local = "本机"
    case lan = "局域网直连"
    case relay = "网络同步"
}

struct IOSPlayerState: Codable, Equatable {
    var appName: String = ""
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var position: Double = 0
    var duration: Double = 0
    var hasMedia: Bool = false
    var updatedAt: Int64 = iosNowMillis()

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

struct IOSDeviceRecord: Identifiable, Equatable {
    var id: String
    var deviceName: String
    var platform: IOSPlatformType
    var roomId: String
    var roomName: String
    var lanName: String
    var ip: String
    var subnet: String
    var httpPort: Int
    var lastSeen: Int64
    var lastPacketTs: Int64
    var connectionMode: IOSConnectionMode
    var player: IOSPlayerState
}

struct IOSAvailableRoom: Identifiable, Equatable {
    var id: String
    var roomName: String
    var hostPlatform: IOSPlatformType
    var memberCount: Int
    var isLanDirect: Bool
}

struct IOSPresencePacket: Codable {
    var v: Int = 2
    var type: String = "presence"
    var deviceId: String
    var deviceName: String
    var platform: String
    var roomId: String
    var roomName: String
    var lanName: String
    var ip: String
    var subnet: String
    var httpPort: Int
    var ts: Int64
    var player: IOSPlayerState
}

struct IOSLeavePacket: Codable {
    var v: Int = 2
    var type: String = "leave"
    var deviceId: String
    var roomId: String
    var ts: Int64
}

struct IOSCommandPacket: Codable {
    var v: Int = 2
    var type: String = "command"
    var cmdId: String
    var roomId: String
    var targetDeviceId: String
    var action: String
    var position: Double
    var ts: Int64
}

func iosNowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func iosFormatSeconds(_ seconds: Double) -> String {
    let clamped = max(0, Int(seconds.rounded(.down)))
    let h = clamped / 3600
    let m = (clamped % 3600) / 60
    let s = clamped % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - Dynamic MediaRemote Protocol (used if device has entitlements; safely no-ops on sandboxed iOS)

@objc private protocol MRDynamicObjC {
    @objc optional func localIsPlaying() -> Bool
    @objc optional func localNowPlayingItem() -> AnyObject?
    @objc optional func localNowPlayingPlayerPath() -> AnyObject?
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

// MARK: - iOS Local Media Detector & Controller (Apple Music + 喜马拉雅 / 外部音频)

final class IOSLocalMediaController {
    private typealias MRSendCmdFunc = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
    private typealias MRSetElapsedFunc = @convention(c) (Double) -> Void

    private var sendCmdPtr: MRSendCmdFunc?
    private var setElapsedPtr: MRSetElapsedFunc?

    // Tracks AVAudioSession detection & exclusive interruption for 喜马拉雅 / third-party audio
    private var silentKeepAlivePlayer: AVAudioPlayer?
    private var holdingExclusiveInterrupt = false
    private var everSawExternalAudio = false
    private var externalAudioRunning = false
    private var externalElapsedAnchor: Double = 0
    private var externalUpdatedAt: Int64 = iosNowMillis()
    private var ximalayaInstalled = false

    var onStateChanged: ((IOSPlayerState) -> Void)?

    init() {
        loadOptionalMediaRemote()
        configurePassiveKeepAliveSession()
        if let url = URL(string: "iting://") {
            ximalayaInstalled = UIApplication.shared.canOpenURL(url)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
    }

    deinit {
        silentKeepAlivePlayer?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    private func loadOptionalMediaRemote() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCmdPtr = unsafeBitCast(sym, to: MRSendCmdFunc.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedPtr = unsafeBitCast(sym, to: MRSetElapsedFunc.self)
        }
    }

    /// Uses `.playback` + `[.mixWithOthers]` with a 0-volume silent PCM loop so iOS keeps
    /// LAN sync & 喜马拉雅 detection alive in the background without ever interrupting other apps.
    private func configurePassiveKeepAliveSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            startSilentKeepAliveIfNeeded()
        } catch {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }

    private func startSilentKeepAliveIfNeeded() {
        if let p = silentKeepAlivePlayer, p.isPlaying { return }
        let wavData = Self.makeSilentWavData()
        if let player = try? AVAudioPlayer(data: wavData) {
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            silentKeepAlivePlayer = player
        }
    }

    private static func makeSilentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000 // 1 second of silence
        let dataSize: UInt32 = numSamples * 2
        let fileSize: UInt32 = 36 + dataSize
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // Mono
        d.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        d.append(contentsOf: "data".utf8)
        d.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        d.append(Data(count: Int(dataSize)))
        return d
    }

    @objc private func handleSecondaryAudioHint(_ note: Notification) {
        pollAndEmit()
    }

    func pollAndEmit() {
        let state = readCurrentState()
        onStateChanged?(state)
    }

    func readCurrentState() -> IOSPlayerState {
        let now = iosNowMillis()
        let session = AVAudioSession.sharedInstance()
        let otherPlaying = session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint

        // 1. Check native Apple Music first (when actively playing or holding an item while no other app overrides)
        let mp = MPMusicPlayerController.systemMusicPlayer
        if let item = mp.nowPlayingItem, (mp.playbackState == .playing || !otherPlaying) {
            let isPlaying = mp.playbackState == .playing
            if isPlaying || (!everSawExternalAudio && !otherPlaying) {
                return IOSPlayerState(
                    appName: "Apple Music",
                    title: (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    isPlaying: isPlaying,
                    position: max(0, mp.currentPlaybackTime),
                    duration: max(0, item.playbackDuration),
                    hasMedia: true,
                    updatedAt: now
                )
            }
        }

        // 2. Probe MediaRemote if entitled (e.g. TrollStore / jailbreak / entitled builds)
        if let mrState = probeEntitledMediaRemote(nowMs: now) {
            return mrState
        }

        // 3. Standard non-jailbroken iOS detection via AVAudioSession (works for 喜马拉雅 / QQ音乐 / 网易云 / 小宇宙!)
        if otherPlaying {
            holdingExclusiveInterrupt = false
            everSawExternalAudio = true
            if !externalAudioRunning {
                externalAudioRunning = true
                externalUpdatedAt = now
            }
            let appLabel = ximalayaInstalled ? "喜马拉雅 / 外部音频" : "外部音频"
            return IOSPlayerState(
                appName: appLabel,
                title: "正在播放音频",
                artist: "iOS 沙盒仅允许检测播放状态与暂停恢复",
                isPlaying: true,
                position: externalElapsedAnchor,
                duration: 0,
                hasMedia: true,
                updatedAt: externalUpdatedAt
            )
        } else if everSawExternalAudio || holdingExclusiveInterrupt {
            if externalAudioRunning {
                let delta = max(0, Double(now - externalUpdatedAt) / 1000.0)
                externalElapsedAnchor += delta
                externalAudioRunning = false
                externalUpdatedAt = now
            }
            let appLabel = ximalayaInstalled ? "喜马拉雅 / 外部音频" : "外部音频"
            return IOSPlayerState(
                appName: appLabel,
                title: "音频已暂停",
                artist: holdingExclusiveInterrupt ? "点击播放可尝试恢复" : "",
                isPlaying: false,
                position: externalElapsedAnchor,
                duration: 0,
                hasMedia: true,
                updatedAt: now
            )
        }

        return IOSPlayerState(hasMedia: false, updatedAt: now)
    }

    func executeCommand(action: String, position: Double = 0) {
        let mp = MPMusicPlayerController.systemMusicPlayer
        let session = AVAudioSession.sharedInstance()
        let otherPlaying = session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint

        // If Apple Music is the active player (and no third-party app like 喜马拉雅 is playing)
        if mp.nowPlayingItem != nil && !otherPlaying && !holdingExclusiveInterrupt {
            switch action {
            case "play": mp.play()
            case "pause": mp.pause()
            case "toggle": mp.playbackState == .playing ? mp.pause() : mp.play()
            case "prev": mp.skipToPreviousItem()
            case "next": mp.skipToNextItem()
            case "seek":
                mp.currentPlaybackTime = max(0, position)
                mp.play()
            default: break
            }
            pollAndEmit()
            return
        }

        // Third-party audio app on iOS (喜马拉雅 / QQ音乐 / 网易云音乐 / 小宇宙):
        switch action {
        case "pause":
            _ = sendCmdPtr?(1, nil)
            interruptExternalAudioToPause()
        case "play":
            _ = sendCmdPtr?(0, nil)
            releaseInterruptToResumeExternalAudio()
        case "toggle":
            if otherPlaying {
                _ = sendCmdPtr?(1, nil)
                interruptExternalAudioToPause()
            } else {
                _ = sendCmdPtr?(0, nil)
                releaseInterruptToResumeExternalAudio()
            }
        case "prev":
            _ = sendCmdPtr?(5, nil)
        case "next":
            _ = sendCmdPtr?(4, nil)
        case "seek":
            setElapsedPtr?(max(0, position))
            _ = sendCmdPtr?(0, nil)
            if holdingExclusiveInterrupt {
                releaseInterruptToResumeExternalAudio()
            }
        default:
            break
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollAndEmit()
        }
    }

    /// Activates an exclusive non-mixing AVAudioSession so iOS sends `.interruptionNotification (.began)` to 喜马拉雅 (pausing it!)
    private func interruptExternalAudioToPause() {
        silentKeepAlivePlayer?.stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            holdingExclusiveInterrupt = true
            everSawExternalAudio = true
        } catch {
            configurePassiveKeepAliveSession()
        }
    }

    /// Deactivates the exclusive session with `.notifyOthersOnDeactivation` so iOS sends `.shouldResume` to 喜马拉雅!
    private func releaseInterruptToResumeExternalAudio() {
        silentKeepAlivePlayer?.stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {}
        holdingExclusiveInterrupt = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.configurePassiveKeepAliveSession()
            self?.pollAndEmit()
        }
    }

    private func probeEntitledMediaRemote(nowMs: Int64) -> IOSPlayerState? {
        guard let reqCls = NSClassFromString("MRNowPlayingRequest") as AnyObject? else { return nil }
        var title = ""
        var artist = ""
        var appName = ""
        var duration: Double = 0
        var position: Double = 0
        var isPlaying = false

        if let playing = reqCls.localIsPlaying?() {
            isPlaying = playing
        }
        if let ppath = reqCls.localNowPlayingPlayerPath?(),
           let client = ppath.client?() {
            if let bid = client.bundleIdentifier?() as String?, !bid.isEmpty {
                appName = friendlyIOSAppName(bid)
            } else if let dn = client.displayName?() as String?, !dn.isEmpty {
                appName = dn
            }
        }
        if let item = reqCls.localNowPlayingItem?(),
           let meta = item.metadata?() {
            if let t = meta.title?() as String? { title = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let a = meta.trackArtistName?() as String? { artist = a.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let d = meta.duration?(), d > 0 { duration = d }
            if let cp = meta.calculatedPlaybackPosition?(), cp >= 0 { position = cp }
            else if let ep = meta.elapsedTime?(), ep >= 0 { position = ep }
        }

        guard !title.isEmpty || !appName.isEmpty else { return nil }
        return IOSPlayerState(
            appName: appName,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            position: position,
            duration: duration,
            hasMedia: true,
            updatedAt: nowMs
        )
    }

    private func friendlyIOSAppName(_ bundleId: String) -> String {
        let lower = bundleId.lowercased()
        if lower.contains("gemd.iting") || lower.contains("ximalaya") { return "喜马拉雅" }
        if lower.contains("qqmusic") { return "QQ音乐" }
        if lower.contains("163music") || lower.contains("netease") { return "网易云音乐" }
        if lower.contains("spotify") { return "Spotify" }
        if lower.contains("cosmos") || lower.contains("xiaoyuzhou") { return "小宇宙" }
        if lower.contains("bili") { return "哔哩哔哩" }
        if lower == "com.apple.music" { return "Apple Music" }
        return bundleId
    }
}

// MARK: - iOS Network Helper (IPv4, Subnet & Directed Broadcast)

private struct IOSNetworkSnapshot {
    let ip: String
    let subnet: String
    let broadcastAddresses: [String]
}

private enum IOSNetworkInfo {
    static func isValidSSID(_ candidate: String) -> Bool {
        let s = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "<redacted>" || s == "redacted" { return false }
        if s.hasPrefix("Wi-Fi · ") || s.hasPrefix("局域网 · ") { return false }
        return true
    }

    static func readSnapshot() -> IOSNetworkSnapshot {
        var primaryIP = ""
        var primarySubnet = ""
        var broadcasts = Set<String>(["255.255.255.255"])

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return IOSNetworkSnapshot(ip: "", subnet: "", broadcastAddresses: Array(broadcasts))
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let iface = current.pointee
            let flags = Int32(iface.ifa_flags)
            if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0,
               let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ipStr = String(cString: ipBuf)
                if !ipStr.hasPrefix("169.254.") && !ipStr.hasPrefix("127.") {
                    if primaryIP.isEmpty || name == "en0" {
                        primaryIP = ipStr
                        let parts = ipStr.split(separator: ".")
                        if parts.count == 4 { primarySubnet = "\(parts[0]).\(parts[1]).\(parts[2])" }
                    }
                    if let maskAddr = iface.ifa_netmask, maskAddr.pointee.sa_family == UInt8(AF_INET) {
                        let maskSin = maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        var bcastAddr = in_addr(s_addr: sin.sin_addr.s_addr | ~maskSin.sin_addr.s_addr)
                        var bcastBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &bcastAddr, &bcastBuf, socklen_t(INET_ADDRSTRLEN))
                        let bcastStr = String(cString: bcastBuf)
                        if !bcastStr.isEmpty { broadcasts.insert(bcastStr) }
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return IOSNetworkSnapshot(ip: primaryIP, subnet: primarySubnet, broadcastAddresses: Array(broadcasts))
    }
}

// MARK: - Unified v2.1 iOS Sync Engine (Auto-Host Room + LAN UDP 41234 + HTTP 41235 + Home Relay)

@MainActor
final class MediaRemoteBridge: ObservableObject {
    static let shared = MediaRemoteBridge()
    static let udpPort: UInt16 = 41234
    static let multicastGroup = "239.255.42.99"
    static let relayBase = "https://ntfy.sh"

    @Published var deviceName: String
    @Published var currentRoomId: String
    @Published var currentRoomName: String
    @Published var displayedLanName: String = "正在检测局域网..."
    @Published var localPlayer = IOSPlayerState()
    @Published var roomPeers: [IOSDeviceRecord] = []
    @Published var availableRooms: [IOSAvailableRoom] = []
    @Published var uiTick: Int64 = iosNowMillis()

    let deviceId: String
    var isHostingOwnRoom: Bool { currentRoomId == deviceId }

    private let mediaController = IOSLocalMediaController()
    private let netQueue = DispatchQueue(label: "com.liangyu.lanmediacontroller.iosnet", qos: .utility)

    private var localIP = ""
    private var localSubnet = ""
    private var resolvedRealSSID = ""
    private var broadcastAddresses = ["255.255.255.255"]
    private var httpPort = 41235
    private var homeRelayTopic = ""

    private var udpSocket: Int32 = -1
    private var udpRunning = false
    private var started = false
    private var httpListener: NWListener?
    private var relayTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var uiTimer: Timer?
    private var tickCounter = 0

    private var allPeersById: [String: IOSDeviceRecord] = [:]
    private var executedCmdIds: Set<String> = []
    private let startupMs = iosNowMillis()

    private init() {
        let d = UserDefaults.standard
        let resolvedId: String
        if let saved = d.string(forKey: "lmc_v2_ios_id"), !saved.isEmpty {
            resolvedId = saved
        } else {
            let id = "ios-" + UUID().uuidString.prefix(8).lowercased()
            d.set(id, forKey: "lmc_v2_ios_id")
            resolvedId = id
        }
        let resolvedName = d.string(forKey: "lmc_v2_ios_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (resolvedName?.isEmpty == false) ? resolvedName! : UIDevice.current.name

        self.deviceId = resolvedId
        self.deviceName = finalName
        self.currentRoomId = resolvedId
        self.currentRoomName = "\(finalName)的房间"
    }

    func start() {
        guard !started else { return }
        started = true

        refreshNetworkInfo()
        startUDP()
        startHTTPServer(startingPort: 41235)
        resolveHomeRelayAndConnect()

        mediaController.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = (state.isPlaying != self.localPlayer.isPlaying
                               || state.title != self.localPlayer.title
                               || state.appName != self.localPlayer.appName)
                self.localPlayer = state
                if changed {
                    self.broadcastPresence(includeRelay: true)
                }
            }
        }
        mediaController.pollAndEmit()

        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onHeartbeat() }
        }

        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uiTick = iosNowMillis()
                self.mediaController.pollAndEmit()
            }
        }
    }

    func saveDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "lmc_v2_ios_name")
        if currentRoomId == deviceId {
            currentRoomName = "\(trimmed)的房间"
        }
        broadcastPresence(includeRelay: true)
    }

    func joinRoom(_ room: IOSAvailableRoom) {
        guard room.id != currentRoomId else { return }
        let old = currentRoomId
        sendLeave(roomId: old)
        currentRoomId = room.id
        currentRoomName = room.roomName
        rebuildDerivedLists()
        broadcastPresence(includeRelay: true)
    }

    func returnToOwnRoom() {
        guard currentRoomId != deviceId else { return }
        let old = currentRoomId
        sendLeave(roomId: old)
        currentRoomId = deviceId
        currentRoomName = "\(deviceName)的房间"
        rebuildDerivedLists()
        broadcastPresence(includeRelay: true)
    }

    func sendCommand(to targetDeviceId: String, action: String, position: Double = 0) {
        if targetDeviceId == deviceId {
            applyOptimistic(player: &localPlayer, action: action, position: position)
            mediaController.executeCommand(action: action, position: position)
            broadcastPresence(includeRelay: true)
            return
        }

        let cmd = IOSCommandPacket(
            cmdId: "cmd-\(UUID().uuidString.prefix(8).lowercased())",
            roomId: currentRoomId,
            targetDeviceId: targetDeviceId,
            action: action,
            position: position,
            ts: iosNowMillis()
        )
        executedCmdIds.insert(cmd.cmdId)

        if var peer = allPeersById[targetDeviceId] {
            applyOptimistic(player: &peer.player, action: action, position: position)
            allPeersById[targetDeviceId] = peer
            rebuildDerivedLists()

            if !peer.ip.isEmpty && peer.httpPort > 0 {
                sendHTTPCommand(cmd, ip: peer.ip, port: peer.httpPort)
                sendUDPDirect(cmd, ip: peer.ip)
            }
        }

        if !homeRelayTopic.isEmpty {
            publishToHomeRelay(payload: cmd)
        }
    }

    // MARK: - Heartbeat & Network Info

    private func onHeartbeat() {
        tickCounter += 1
        if tickCounter % 10 == 0 { refreshNetworkInfo() }
        pruneStalePeers()
        broadcastPresence(includeRelay: tickCounter % 5 == 0)
    }

    private func refreshNetworkInfo() {
        netQueue.async { [weak self] in
            let snap = IOSNetworkInfo.readSnapshot()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localIP = snap.ip
                self.localSubnet = snap.subnet
                self.broadcastAddresses = snap.broadcastAddresses
                self.updateDisplayedLanName()
            }
        }
    }

    private func updateDisplayedLanName() {
        if IOSNetworkInfo.isValidSSID(resolvedRealSSID) {
            displayedLanName = resolvedRealSSID
        } else if !localIP.isEmpty {
            displayedLanName = "Wi-Fi · \(localIP)"
        } else {
            displayedLanName = "本地局域网"
        }
    }

    private func applyOptimistic(player: inout IOSPlayerState, action: String, position: Double) {
        let now = iosNowMillis()
        switch action {
        case "play":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying = true
            player.updatedAt = now
        case "pause":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying = false
            player.updatedAt = now
        case "toggle":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying.toggle()
            player.updatedAt = now
        case "seek":
            player.position = max(0, position)
            player.isPlaying = true
            player.updatedAt = now
        case "next", "prev":
            player.position = 0
            player.isPlaying = true
            player.updatedAt = now
        default:
            break
        }
    }

    // MARK: - Home NAT Discovery Channel

    private func resolveHomeRelayAndConnect() {
        Task { [weak self] in
            let endpoints = ["https://api4.ipify.org", "https://ipv4.icanhazip.com"]
            var publicIP = ""
            for ep in endpoints {
                guard let url = URL(string: ep) else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 3.0
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   str.split(separator: ".").count == 4 {
                    publicIP = str
                    break
                }
            }
            guard !publicIP.isEmpty else { return }
            let digest = SHA256.hash(data: Data("lmc-v2-home:\(publicIP)".utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let topic = "lmc_v2_home_\(hex.prefix(16))"
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.homeRelayTopic = topic
                self.startRelaySubscription(topic: topic)
                self.broadcastPresence(includeRelay: true)
            }
        }
    }

    private func startRelaySubscription(topic: String) {
        relayTask?.cancel()
        guard let url = URL(string: "\(Self.relayBase)/\(topic)/sse?since=1m") else { return }
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 300
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let jsonPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let outerData = jsonPart.data(using: .utf8),
                              let outer = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any],
                              (outer["event"] as? String) == "message",
                              let msgStr = outer["message"] as? String,
                              let msgData = msgStr.data(using: .utf8) else { continue }
                        await MainActor.run { [weak self] in
                            self?.handleIncomingPacket(data: msgData, source: .relay, senderIP: "")
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func publishToHomeRelay<T: Encodable>(payload: T) {
        guard !homeRelayTopic.isEmpty,
              let url = URL(string: "\(Self.relayBase)/\(homeRelayTopic)"),
              let body = try? JSONEncoder().encode(payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - UDP Discovery (41234) & Direct HTTP Control (41235)

    private func startUDP() {
        netQueue.async { [weak self] in
            guard let self else { return }
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

            var bindAddr = sockaddr_in()
            bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_port = Self.udpPort.bigEndian
            bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY)

            let bindRes = withUnsafePointer(to: &bindAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes != 0 {
                Darwin.close(fd)
                return
            }

            var mreq = ip_mreq()
            inet_pton(AF_INET, Self.multicastGroup, &mreq.imr_multiaddr)
            mreq.imr_interface = in_addr(s_addr: INADDR_ANY)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

            self.udpSocket = fd
            self.udpRunning = true

            var buf = [UInt8](repeating: 0, count: 8192)
            while self.udpRunning {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &srcLen)
                    }
                }
                if n > 0 {
                    let data = Data(buf[0..<n])
                    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addrCopy = srcAddr.sin_addr
                    inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                    let senderIP = String(cString: ipBuf)
                    Task { @MainActor [weak self] in
                        self?.handleIncomingPacket(data: data, source: .lan, senderIP: senderIP)
                    }
                } else if !self.udpRunning {
                    break
                }
            }
        }
    }

    private func broadcastPresence(includeRelay: Bool) {
        let packet = IOSPresencePacket(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: IOSPlatformType.ios.rawValue,
            roomId: currentRoomId,
            roomName: currentRoomName,
            lanName: resolvedRealSSID,
            ip: localIP,
            subnet: localSubnet,
            httpPort: httpPort,
            ts: iosNowMillis(),
            player: localPlayer
        )
        guard let data = try? JSONEncoder().encode(packet) else { return }

        var targets = Set(broadcastAddresses)
        targets.insert(Self.multicastGroup)
        targets.insert("255.255.255.255")

        var knownPeerEndpoints: [(ip: String, port: Int)] = []
        for peer in allPeersById.values where !peer.ip.isEmpty {
            targets.insert(peer.ip)
            if peer.httpPort > 0 {
                knownPeerEndpoints.append((peer.ip, peer.httpPort))
            }
        }

        let fd = udpSocket
        if fd >= 0 {
            netQueue.async {
                for host in targets {
                    Self.sendUDPData(fd: fd, data: data, host: host, port: Self.udpPort)
                }
            }
        }

        // Push presence directly over TCP HTTP to known LAN peers (works even if router drops Wi-Fi UDP broadcast!)
        for ep in knownPeerEndpoints {
            if let url = URL(string: "http://\(ep.ip):\(ep.port)/api/presence") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 1.5
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                URLSession.shared.dataTask(with: req).resume()
            }
        }

        if includeRelay && !homeRelayTopic.isEmpty {
            publishToHomeRelay(payload: packet)
        }
    }

    private func sendLeave(roomId: String) {
        let packet = IOSLeavePacket(deviceId: deviceId, roomId: roomId, ts: iosNowMillis())
        guard let data = try? JSONEncoder().encode(packet) else { return }
        var targets = Set(broadcastAddresses)
        targets.insert(Self.multicastGroup)
        let fd = udpSocket
        if fd >= 0 {
            netQueue.async {
                for host in targets {
                    Self.sendUDPData(fd: fd, data: data, host: host, port: Self.udpPort)
                }
            }
        }
        publishToHomeRelay(payload: packet)
    }

    private func sendUDPDirect(_ cmd: IOSCommandPacket, ip: String) {
        guard let data = try? JSONEncoder().encode(cmd), udpSocket >= 0 else { return }
        let fd = udpSocket
        netQueue.async { Self.sendUDPData(fd: fd, data: data, host: ip, port: Self.udpPort) }
    }

    private nonisolated static func sendUDPData(fd: Int32, data: Data, host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = Darwin.sendto(fd, ptr, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func startHTTPServer(startingPort: Int) {
        guard startingPort <= 41245, let nwPort = NWEndpoint.Port(rawValue: UInt16(startingPort)) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                if case .failed = state {
                    listener?.cancel()
                    Task { @MainActor [weak self] in
                        self?.startHTTPServer(startingPort: startingPort + 1)
                    }
                } else if case .ready = state {
                    Task { @MainActor [weak self] in self?.httpPort = startingPort }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleHTTPConnection(conn)
            }
            listener.start(queue: netQueue)
            self.httpListener = listener
        } catch {
            startHTTPServer(startingPort: startingPort + 1)
        }
    }

    private nonisolated func handleHTTPConnection(_ conn: NWConnection) {
        conn.start(queue: netQueue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            if let data, let raw = String(data: data, encoding: .utf8),
               let sep = raw.range(of: "\r\n\r\n") {
                let bodyStr = String(raw[sep.upperBound...])
                if let bodyData = bodyStr.data(using: .utf8), !bodyData.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleIncomingPacket(data: bodyData, source: .lan, senderIP: "")
                    }
                }
            }
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func sendHTTPCommand(_ cmd: IOSCommandPacket, ip: String, port: Int) {
        guard let url = URL(string: "http://\(ip):\(port)/api/command"),
              let body = try? JSONEncoder().encode(cmd) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Unified Incoming Packet Processing

    private func handleIncomingPacket(data: Data, source: IOSConnectionMode, senderIP: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let now = iosNowMillis()

        if type == "presence", let pkt = try? JSONDecoder().decode(IOSPresencePacket.self, from: data) {
            guard !pkt.deviceId.isEmpty && pkt.deviceId != deviceId else { return }

            if !IOSNetworkInfo.isValidSSID(resolvedRealSSID)
                && !localSubnet.isEmpty && pkt.subnet == localSubnet
                && IOSNetworkInfo.isValidSSID(pkt.lanName) {
                resolvedRealSSID = pkt.lanName
                updateDisplayedLanName()
            }

            let effIP = !senderIP.isEmpty ? senderIP : pkt.ip
            let roomId = pkt.roomId.isEmpty ? pkt.deviceId : pkt.roomId
            let roomName = pkt.roomName.isEmpty ? "\(pkt.deviceName)的房间" : pkt.roomName

            if roomId == currentRoomId && pkt.deviceId == roomId && !roomName.isEmpty {
                currentRoomName = roomName
            }

            let isNew = allPeersById[pkt.deviceId] == nil
            if let existing = allPeersById[pkt.deviceId] {
                if pkt.ts < existing.lastPacketTs { return }
                let mode: IOSConnectionMode = (source == .lan || existing.connectionMode == .lan) ? .lan : .relay
                allPeersById[pkt.deviceId] = IOSDeviceRecord(
                    id: pkt.deviceId,
                    deviceName: pkt.deviceName,
                    platform: IOSPlatformType(rawValue: pkt.platform) ?? .windows,
                    roomId: roomId,
                    roomName: roomName,
                    lanName: pkt.lanName,
                    ip: effIP.isEmpty ? existing.ip : effIP,
                    subnet: pkt.subnet,
                    httpPort: pkt.httpPort > 0 ? pkt.httpPort : existing.httpPort,
                    lastSeen: now,
                    lastPacketTs: pkt.ts,
                    connectionMode: mode,
                    player: pkt.player
                )
            } else {
                allPeersById[pkt.deviceId] = IOSDeviceRecord(
                    id: pkt.deviceId,
                    deviceName: pkt.deviceName,
                    platform: IOSPlatformType(rawValue: pkt.platform) ?? .windows,
                    roomId: roomId,
                    roomName: roomName,
                    lanName: pkt.lanName,
                    ip: effIP,
                    subnet: pkt.subnet,
                    httpPort: pkt.httpPort,
                    lastSeen: now,
                    lastPacketTs: pkt.ts,
                    connectionMode: source,
                    player: pkt.player
                )
            }
            rebuildDerivedLists()
            if isNew { broadcastPresence(includeRelay: true) }
        } else if type == "leave", let pkt = try? JSONDecoder().decode(IOSLeavePacket.self, from: data) {
            if var existing = allPeersById[pkt.deviceId], pkt.ts >= existing.lastPacketTs, existing.roomId == pkt.roomId {
                existing.roomId = existing.id
                existing.roomName = "\(existing.deviceName)的房间"
                existing.lastPacketTs = pkt.ts
                allPeersById[pkt.deviceId] = existing
                rebuildDerivedLists()
            }
        } else if type == "command", let cmd = try? JSONDecoder().decode(IOSCommandPacket.self, from: data) {
            guard !executedCmdIds.contains(cmd.cmdId), cmd.ts >= startupMs - 5000, cmd.roomId == currentRoomId else { return }
            executedCmdIds.insert(cmd.cmdId)
            if cmd.targetDeviceId == deviceId {
                applyOptimistic(player: &localPlayer, action: cmd.action, position: cmd.position)
                mediaController.executeCommand(action: cmd.action, position: cmd.position)
                broadcastPresence(includeRelay: true)
            }
        }
    }

    private func pruneStalePeers() {
        let now = iosNowMillis()
        let before = allPeersById.count
        allPeersById = allPeersById.filter { now - $0.value.lastSeen < 25_000 }
        if allPeersById.count != before { rebuildDerivedLists() }
    }

    private func rebuildDerivedLists() {
        roomPeers = allPeersById.values
            .filter { $0.roomId == currentRoomId }
            .sorted { $0.deviceName.localizedCompare($1.deviceName) == .orderedAscending }

        var grouped: [String: [IOSDeviceRecord]] = [:]
        for p in allPeersById.values where p.roomId != currentRoomId {
            grouped[p.roomId, default: []].append(p)
        }
        availableRooms = grouped.map { (rId, members) in
            let host = members.first(where: { $0.id == rId }) ?? members[0]
            return IOSAvailableRoom(
                id: rId,
                roomName: host.roomName.isEmpty ? "\(host.deviceName)的房间" : host.roomName,
                hostPlatform: host.platform,
                memberCount: members.count,
                isLanDirect: members.contains(where: { $0.connectionMode == .lan })
            )
        }.sorted { $0.roomName.localizedCompare($1.roomName) == .orderedAscending }
    }
}
