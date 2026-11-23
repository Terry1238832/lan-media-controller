using System.Diagnostics;
using System.Runtime.InteropServices;
using LanMediaController.Models;
using Windows.Media.Control;

namespace LanMediaController.Services;

public sealed class WindowsMediaController : IDisposable
{
    private const byte VkMediaNextTrack = 0xB0;
    private const byte VkMediaPrevTrack = 0xB1;
    private const byte VkMediaPlayPause = 0xB3;
    private const uint KeyEventFKeyUp = 0x0002;

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _attachedSession;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private System.Threading.Timer? _reconcileTimer;
    private bool _disposed;

    public event Action<PlayerState>? StateChanged;

    public async Task StartAsync()
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            if (_manager != null)
            {
                _manager.CurrentSessionChanged += OnSessionsChanged;
                _manager.SessionsChanged += OnSessionsChanged;
            }
        }
        catch
        {
            // Continue with periodic fallback detection even if WinRT SMTC fails to initialize
        }

        await RefreshNowAsync();

        _reconcileTimer = new System.Threading.Timer(
            _ => _ = RefreshNowAsync(),
            null,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
    }

    private void OnSessionsChanged(GlobalSystemMediaTransportControlsSessionManager sender, object args)
    {
        _ = RefreshNowAsync();
    }

    private void OnSessionPropertyChanged(GlobalSystemMediaTransportControlsSession sender, object args)
    {
        _ = RefreshNowAsync();
    }

    private GlobalSystemMediaTransportControlsSession? SelectActiveSession()
    {
        if (_manager == null) return null;
        try
        {
            var sessions = _manager.GetSessions();
            if (sessions != null && sessions.Count > 0)
            {
                // Prefer a session that is actively Playing right now
                foreach (var s in sessions)
                {
                    try
                    {
                        var info = s.GetPlaybackInfo();
                        if (info?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                            return s;
                    }
                    catch { }
                }
            }

            var current = _manager.GetCurrentSession();
            if (current != null) return current;
            if (sessions != null && sessions.Count > 0) return sessions[0];
        }
        catch { }
        return null;
    }

    private void AttachSessionEvents(GlobalSystemMediaTransportControlsSession? session)
    {
        if (ReferenceEquals(_attachedSession, session)) return;

        if (_attachedSession != null)
        {
            try
            {
                _attachedSession.MediaPropertiesChanged -= OnSessionPropertyChanged;
                _attachedSession.PlaybackInfoChanged -= OnSessionPropertyChanged;
                _attachedSession.TimelinePropertiesChanged -= OnSessionPropertyChanged;
            }
            catch { }
        }

        _attachedSession = session;
        if (_attachedSession != null)
        {
            try
            {
                _attachedSession.MediaPropertiesChanged += OnSessionPropertyChanged;
                _attachedSession.PlaybackInfoChanged += OnSessionPropertyChanged;
                _attachedSession.TimelinePropertiesChanged += OnSessionPropertyChanged;
            }
            catch { }
        }
    }

    public async Task RefreshNowAsync()
    {
        if (_disposed) return;
        if (!await _refreshLock.WaitAsync(0)) return;
        try
        {
            var session = SelectActiveSession();
            AttachSessionEvents(session);

            if (session != null)
            {
                var appName = FriendlyAppName(session.SourceAppUserModelId ?? "");
                var playback = session.GetPlaybackInfo();
                var timeline = session.GetTimelineProperties();
                var isPlaying = playback?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;

                string title = "";
                string artist = "";
                try
                {
                    var props = await session.TryGetMediaPropertiesAsync();
                    if (props != null)
                    {
                        title = (props.Title ?? "").Trim();
                        artist = (props.Artist ?? "").Trim();
                    }
                }
                catch { }

                double duration = 0;
                double position = 0;
                long updatedAt = ProtocolJson.NowMillis();

                if (timeline != null)
                {
                    duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
                    position = Math.Max(0, (timeline.Position - timeline.StartTime).TotalSeconds);
                    if (timeline.LastUpdatedTime != DateTimeOffset.MinValue)
                    {
                        var lastUpMs = timeline.LastUpdatedTime.ToUnixTimeMilliseconds();
                        if (lastUpMs > 1_600_000_000_000L && lastUpMs <= updatedAt + 5000)
                        {
                            if (isPlaying)
                            {
                                var delta = Math.Max(0, (updatedAt - lastUpMs) / 1000.0);
                                position = duration > 0 ? Math.Min(duration, position + delta) : (position + delta);
                            }
                        }
                    }
                }

                var state = new PlayerState
                {
                    AppName = appName,
                    Title = title,
                    Artist = artist,
                    IsPlaying = isPlaying,
                    Position = position,
                    Duration = duration,
                    HasMedia = !string.IsNullOrEmpty(title) || !string.IsNullOrEmpty(appName) || duration > 0 || isPlaying,
                    UpdatedAt = updatedAt
                };
                StateChanged?.Invoke(state);
                return;
            }

            // Fallback: inspect running music player windows if SMTC has no session
            var fallback = TryDetectPlayerProcessWindow();
            StateChanged?.Invoke(fallback);
        }
        catch
        {
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    public async Task ExecuteCommandAsync(string action, double positionSeconds = 0)
    {
        var session = SelectActiveSession();
        bool handled = false;

        if (session != null)
        {
            try
            {
                switch (action)
                {
                    case "play":
                        handled = await session.TryPlayAsync();
                        break;
                    case "pause":
                        handled = await session.TryPauseAsync();
                        break;
                    case "toggle":
                        handled = await session.TryTogglePlayPauseAsync();
                        break;
                    case "prev":
                        handled = await session.TrySkipPreviousAsync();
                        break;
                    case "next":
                        handled = await session.TrySkipNextAsync();
                        break;
                    case "seek":
                        var timeline = session.GetTimelineProperties();
                        var startOffset = timeline?.StartTime ?? TimeSpan.Zero;
                        var targetTicks = (startOffset + TimeSpan.FromSeconds(Math.Max(0, positionSeconds))).Ticks;
                        handled = await session.TryChangePlaybackPositionAsync(targetTicks);
                        // Per user requirement: start playing after dragging progress bar
                        await session.TryPlayAsync();
                        break;
                }
            }
            catch
            {
                handled = false;
            }
        }

        if (!handled)
        {
            SendFallbackMediaKey(action);
        }

        await Task.Delay(220);
        await RefreshNowAsync();
    }

    private static void SendFallbackMediaKey(string action)
    {
        byte vk = action switch
        {
            "play" or "pause" or "toggle" => VkMediaPlayPause,
            "next" => VkMediaNextTrack,
            "prev" => VkMediaPrevTrack,
            _ => 0
        };
        if (vk == 0) return;
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, KeyEventFKeyUp, UIntPtr.Zero);
    }

    private static PlayerState TryDetectPlayerProcessWindow()
    {
        var candidates = new (string procName, string label)[]
        {
            ("QQMusic", "QQ音乐"),
            ("cloudmusic", "网易云音乐"),
            ("Spotify", "Spotify"),
            ("KuGou", "酷狗音乐"),
            ("kwmusic", "酷我音乐"),
            ("PotPlayerMini64", "PotPlayer"),
            ("vlc", "VLC")
        };

        foreach (var (procName, label) in candidates)
        {
            try
            {
                var procs = Process.GetProcessesByName(procName);
                foreach (var p in procs)
                {
                    var winTitle = (p.MainWindowTitle ?? "").Trim();
                    if (!string.IsNullOrEmpty(winTitle))
                    {
                        var cleanTitle = winTitle.Equals(label, StringComparison.OrdinalIgnoreCase)
                                      || winTitle.Equals(procName, StringComparison.OrdinalIgnoreCase)
                            ? ""
                            : winTitle;
                        return new PlayerState
                        {
                            AppName = label,
                            Title = cleanTitle,
                            Artist = "",
                            IsPlaying = false,
                            Position = 0,
                            Duration = 0,
                            HasMedia = true,
                            UpdatedAt = ProtocolJson.NowMillis()
                        };
                    }
                }
            }
            catch { }
        }

        return new PlayerState { HasMedia = false, UpdatedAt = ProtocolJson.NowMillis() };
    }

    private static string FriendlyAppName(string aumid)
    {
        var lower = aumid.ToLowerInvariant();
        if (lower.Contains("qqmusic")) return "QQ音乐";
        if (lower.Contains("cloudmusic") || lower.Contains("netease")) return "网易云音乐";
        if (lower.Contains("spotify")) return "Spotify";
        if (lower.Contains("applemusic") || lower.Contains("itunes")) return "Apple Music";
        if (lower.Contains("kugou")) return "酷狗音乐";
        if (lower.Contains("kuwo") || lower.Contains("kwmusic")) return "酷我音乐";
        if (lower.Contains("soda")) return "汽水音乐";
        if (lower.Contains("bilibili")) return "哔哩哔哩";
        if (lower.Contains("msedge")) return "Edge";
        if (lower.Contains("chrome")) return "Chrome";
        if (lower.Contains("firefox")) return "Firefox";
        if (lower.Contains("potplayer")) return "PotPlayer";
        if (lower.Contains("vlc")) return "VLC";
        if (lower.Contains("foobar")) return "foobar2000";

        var clean = aumid;
        var bang = clean.IndexOf('!');
        if (bang > 0) clean = clean[..bang];
        if (clean.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            clean = clean[..^4];
        return clean;
    }

    public void Dispose()
    {
        _disposed = true;
        _reconcileTimer?.Dispose();
        AttachSessionEvents(null);
        if (_manager != null)
        {
            try
            {
                _manager.CurrentSessionChanged -= OnSessionsChanged;
                _manager.SessionsChanged -= OnSessionsChanged;
            }
            catch { }
        }
    }
}
