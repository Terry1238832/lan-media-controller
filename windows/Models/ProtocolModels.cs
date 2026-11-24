using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanMediaController.Models;

public static class ProtocolJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static long NowMillis() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public static string FormatSeconds(double seconds)
    {
        var clamped = Math.Max(0, (int)Math.Floor(seconds));
        var hours = clamped / 3600;
        var mins = (clamped % 3600) / 60;
        var secs = clamped % 60;
        return hours > 0 ? $"{hours}:{mins:D2}:{secs:D2}" : $"{mins:D2}:{secs:D2}";
    }

    public static string PlatformDisplayName(string platform) => platform.ToLowerInvariant() switch
    {
        "windows" => "Windows",
        "macos" => "macOS",
        "ios" => "iOS",
        "android" => "Android",
        _ => platform
    };
}

public sealed class PlayerState
{
    public string AppName { get; set; } = "";
    public string Title { get; set; } = "";
    public string Artist { get; set; } = "";
    public bool IsPlaying { get; set; }
    public double Position { get; set; }
    public double Duration { get; set; }
    public bool HasMedia { get; set; }
    public long UpdatedAt { get; set; } = ProtocolJson.NowMillis();

    public double LivePosition(long nowMs)
    {
        if (!HasMedia && Duration <= 0) return 0;
        var basePos = Math.Max(0, Position);
        if (!IsPlaying)
            return Duration > 0 ? Math.Min(Duration, basePos) : basePos;

        var elapsed = Math.Max(0, (nowMs - UpdatedAt) / 1000.0);
        var current = basePos + elapsed;
        return Duration > 0 ? Math.Min(Duration, current) : current;
    }

    public string DisplayTrackLine()
    {
        if (!HasMedia && string.IsNullOrWhiteSpace(Title) && string.IsNullOrWhiteSpace(AppName))
            return "暂无正在播放的媒体";
        var main = Title.Trim();
        if (!string.IsNullOrWhiteSpace(Artist))
            main = string.IsNullOrEmpty(main) ? Artist.Trim() : $"{main} - {Artist.Trim()}";
        if (string.IsNullOrEmpty(main))
            return IsPlaying ? "正在播放" : "已暂停";
        return main;
    }

    public PlayerState Clone() => new()
    {
        AppName = AppName,
        Title = Title,
        Artist = Artist,
        IsPlaying = IsPlaying,
        Position = Position,
        Duration = Duration,
        HasMedia = HasMedia,
        UpdatedAt = UpdatedAt
    };
}

public sealed class DeviceRecord
{
    public string DeviceId { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public string Platform { get; set; } = "windows";
    public string RoomId { get; set; } = "";
    public string RoomName { get; set; } = "";
    public string LanName { get; set; } = "";
    public string Ip { get; set; } = "";
    public string Subnet { get; set; } = "";
    public int HttpPort { get; set; }
    public long LastSeen { get; set; }
    public long LastPacketTs { get; set; }
    public string ConnectionMode { get; set; } = "局域网直连";
    public PlayerState Player { get; set; } = new();
}

public sealed class AvailableRoom
{
    public string RoomId { get; set; } = "";
    public string RoomName { get; set; } = "";
    public string HostPlatform { get; set; } = "windows";
    public int MemberCount { get; set; }
    public bool IsLanDirect { get; set; }
}

public sealed class PresencePacket
{
    public int V { get; set; } = 2;
    public string Type { get; set; } = "presence";
    public string DeviceId { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public string Platform { get; set; } = "windows";
    public string RoomId { get; set; } = "";
    public string RoomName { get; set; } = "";
    public string LanName { get; set; } = "";
    public string Ip { get; set; } = "";
    public string Subnet { get; set; } = "";
    public int HttpPort { get; set; } = 41235;
    public long Ts { get; set; }
    public PlayerState Player { get; set; } = new();
}

public sealed class LeavePacket
{
    public int V { get; set; } = 2;
    public string Type { get; set; } = "leave";
    public string DeviceId { get; set; } = "";
    public string RoomId { get; set; } = "";
    public long Ts { get; set; }
}

public sealed class CommandPacket
{
    public int V { get; set; } = 2;
    public string Type { get; set; } = "command";
    public string CmdId { get; set; } = "";
    public string RoomId { get; set; } = "";
    public string TargetDeviceId { get; set; } = "";
    public string Action { get; set; } = "toggle";
    public double Position { get; set; }
    public long Ts { get; set; }
}

public sealed class AppConfig
{
    public string DeviceId { get; set; } = "";
    public string DeviceName { get; set; } = "";
}
