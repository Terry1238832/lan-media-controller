import Foundation

enum PlatformType: String, Codable, CaseIterable {
    case windows
    case macos
    case ios
    case android

    var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .macos: return "macOS"
        case .ios: return "iOS"
        case .android: return "Android"
        }
    }
}

enum ConnectionMode: String {
    case local = "本机"
    case lan = "局域网直连"
    case relay = "中继同步"
}

struct PlayerState: Codable, Equatable {
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
        guard isPlaying else {
            return duration > 0 ? min(duration, base) : base
        }
        let elapsed = max(0, Double(nowMs - updatedAt) / 1000.0)
        let current = base + elapsed
        return duration > 0 ? min(duration, current) : current
    }

    var displayTrackLine: String {
        if !hasMedia && title.isEmpty && appName.isEmpty {
            return "暂无正在播放的媒体"
        }
        var main = title
        if !artist.isEmpty {
            main = main.isEmpty ? artist : "\(main) - \(artist)"
        }
        if main.isEmpty {
            return isPlaying ? "正在播放" : "已暂停"
        }
        return main
    }
}

struct DeviceRecord: Identifiable, Equatable {
    var id: String
    var deviceName: String
    var platform: PlatformType
    var roomCode: String
    var lanName: String
    var ip: String
    var subnet: String
    var httpPort: Int
    var lastSeen: Int64
    var lastPacketTs: Int64
    var connectionMode: ConnectionMode
    var player: PlayerState
}

struct PresencePacket: Codable {
    var v: Int = 2
    var type: String = "presence"
    var deviceId: String
    var deviceName: String
    var platform: String
    var roomCode: String
    var lanName: String
    var ip: String
    var subnet: String
    var httpPort: Int
    var ts: Int64
    var player: PlayerState
}

struct LeavePacket: Codable {
    var v: Int = 2
    var type: String = "leave"
    var deviceId: String
    var roomCode: String
    var ts: Int64
}

struct CommandPacket: Codable {
    var v: Int = 2
    var type: String = "command"
    var cmdId: String
    var roomCode: String
    var targetDeviceId: String
    var action: String
    var position: Double
    var ts: Int64
}

func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func formatSeconds(_ seconds: Double) -> String {
    let clamped = max(0, Int(seconds.rounded(.down)))
    let hours = clamped / 3600
    let mins = (clamped % 3600) / 60
    let secs = clamped % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, mins, secs)
    }
    return String(format: "%02d:%02d", mins, secs)
}
