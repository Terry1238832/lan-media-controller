using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using LanMediaController.Models;

namespace LanMediaController.Services;

public sealed class SyncEngine : IDisposable
{
    public const int UdpPort = 41234;
    public const string MulticastGroup = "239.255.42.99";
    public const string RelayBase = "https://ntfy.sh";

    private readonly WindowsMediaController _media = new();
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(3) };
    private readonly HttpClient _sseClient = new() { Timeout = Timeout.InfiniteTimeSpan };
    private readonly object _stateLock = new();

    private readonly Dictionary<string, DeviceRecord> _peersById = new();
    private readonly Dictionary<string, long> _discoveredRooms = new();
    private readonly ConcurrentDictionary<string, byte> _executedCmdIds = new();
    private readonly long _startupMs = ProtocolJson.NowMillis();

    private UdpClient? _udpClient;
    private TcpListener? _tcpListener;
    private CancellationTokenSource _cts = new();
    private CancellationTokenSource? _relayCts;
    private System.Threading.Timer? _heartbeatTimer;
    private int _heartbeatTick;

    private string _localIp = "";
    private string _localSubnet = "";
    private string _interfaceLabel = "";
    private string _resolvedRealSsid = "";
    private List<string> _broadcastAddresses = new() { "255.255.255.255" };
    private int _httpPort = 41235;

    public string DeviceId { get; private set; } = "";
    public string DeviceName { get; private set; } = "";
    public string CurrentRoomCode { get; private set; } = "";
    public string DisplayedLanName { get; private set; } = "正在检测局域网...";
    public PlayerState LocalPlayer { get; private set; } = new();

    public event Action? StateUpdated;

    private static string ConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LanMediaController", "config.json");

    public SyncEngine()
    {
        LoadOrCreateConfig();
    }

    private void LoadOrCreateConfig()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var cfg = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath), ProtocolJson.Options);
                if (cfg != null)
                {
                    if (!string.IsNullOrWhiteSpace(cfg.DeviceId)) DeviceId = cfg.DeviceId.Trim();
                    if (!string.IsNullOrWhiteSpace(cfg.DeviceName)) DeviceName = cfg.DeviceName.Trim();
                }
            }
        }
        catch { }

        if (string.IsNullOrWhiteSpace(DeviceId))
            DeviceId = "win-" + Guid.NewGuid().ToString("N")[..8];
        if (string.IsNullOrWhiteSpace(DeviceName))
            DeviceName = Environment.MachineName;

        SaveConfig();
    }

    private void SaveConfig()
    {
        try
        {
            var dir = Path.GetDirectoryName(ConfigPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(new AppConfig { DeviceId = DeviceId, DeviceName = DeviceName }, ProtocolJson.Options);
            File.WriteAllText(ConfigPath, json, Encoding.UTF8);
        }
        catch { }
    }

    public async Task StartAsync()
    {
        RefreshNetworkInfo();
        StartUdp();
        StartTcpHttpServer();

        _media.StateChanged += state =>
        {
            lock (_stateLock) { LocalPlayer = state; }
            NotifyUpdated();
            BroadcastPresence(includeRelay: !string.IsNullOrEmpty(CurrentRoomCode));
        };
        await _media.StartAsync();

        _heartbeatTimer = new System.Threading.Timer(_ => OnHeartbeat(), null, TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(1500));
    }

    public void SaveDeviceName(string name)
    {
        var trimmed = (name ?? "").Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        DeviceName = trimmed;
        SaveConfig();
        NotifyUpdated();
        BroadcastPresence(includeRelay: !string.IsNullOrEmpty(CurrentRoomCode));
    }

    public void CreateRoom()
    {
        var code = Random.Shared.Next(1000, 10000).ToString();
        JoinRoom(code);
    }

    public void JoinRoom(string code)
    {
        var cleaned = (code ?? "").Trim();
        if (cleaned.Length != 4 || !cleaned.All(char.IsDigit)) return;

        var prev = CurrentRoomCode;
        if (!string.IsNullOrEmpty(prev) && prev != cleaned)
            SendLeave(prev);

        lock (_stateLock)
        {
            CurrentRoomCode = cleaned;
            _peersById.Clear();
        }
        StartRelaySubscription(cleaned);
        NotifyUpdated();
        BroadcastPresence(includeRelay: true);
    }

    public void LeaveRoom()
    {
        var old = CurrentRoomCode;
        StopRelaySubscription();
        lock (_stateLock)
        {
            CurrentRoomCode = "";
            _peersById.Clear();
        }
        if (!string.IsNullOrEmpty(old))
            SendLeave(old);
        NotifyUpdated();
        BroadcastPresence(includeRelay: false);
    }

    public List<DeviceRecord> GetRoomPeersSnapshot()
    {
        lock (_stateLock)
        {
            return _peersById.Values
                .OrderBy(p => p.DeviceName, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }
    }

    public List<string> GetDiscoveredRoomsSnapshot()
    {
        lock (_stateLock)
        {
            return _discoveredRooms.Keys.OrderBy(k => k).ToList();
        }
    }

    public PlayerState GetLocalPlayerSnapshot()
    {
        lock (_stateLock) { return LocalPlayer.Clone(); }
    }

    public void SendCommand(string targetDeviceId, string action, double position = 0)
    {
        if (targetDeviceId == DeviceId)
        {
            lock (_stateLock) { ApplyOptimistic(LocalPlayer, action, position); }
            NotifyUpdated();
            _ = _media.ExecuteCommandAsync(action, position);
            BroadcastPresence(includeRelay: !string.IsNullOrEmpty(CurrentRoomCode));
            return;
        }

        var cmd = new CommandPacket
        {
            CmdId = "cmd-" + Guid.NewGuid().ToString("N")[..8],
            RoomCode = CurrentRoomCode,
            TargetDeviceId = targetDeviceId,
            Action = action,
            Position = position,
            Ts = ProtocolJson.NowMillis()
        };
        _executedCmdIds.TryAdd(cmd.CmdId, 1);

        string peerIp = "";
        int peerPort = 0;
        lock (_stateLock)
        {
            if (_peersById.TryGetValue(targetDeviceId, out var peer))
            {
                ApplyOptimistic(peer.Player, action, position);
                peerIp = peer.Ip;
                peerPort = peer.HttpPort;
            }
        }
        NotifyUpdated();

        if (!string.IsNullOrEmpty(peerIp) && peerPort > 0)
        {
            _ = SendHttpCommandAsync(cmd, peerIp, peerPort);
            SendUdpPacket(cmd, peerIp);
        }

        if (!string.IsNullOrEmpty(CurrentRoomCode))
        {
            _ = PublishToRelayAsync(CurrentRoomCode, cmd);
        }
    }

    private void OnHeartbeat()
    {
        _heartbeatTick++;
        if (_heartbeatTick % 10 == 0) RefreshNetworkInfo();
        PruneStalePeers();
        BroadcastPresence(includeRelay: !string.IsNullOrEmpty(CurrentRoomCode) && (_heartbeatTick % 2 == 0));
    }

    private void RefreshNetworkInfo()
    {
        var snap = WindowsNetworkInfo.ReadSnapshot();
        _localIp = snap.Ip;
        _localSubnet = snap.Subnet;
        _interfaceLabel = snap.InterfaceLabel;
        _broadcastAddresses = snap.BroadcastAddresses;
        if (WindowsNetworkInfo.IsValidSsid(snap.Ssid))
            _resolvedRealSsid = snap.Ssid;

        UpdateDisplayedLanName();
    }

    private void UpdateDisplayedLanName()
    {
        string next;
        if (WindowsNetworkInfo.IsValidSsid(_resolvedRealSsid))
            next = _resolvedRealSsid;
        else if (!string.IsNullOrEmpty(_localIp))
            next = $"{(string.IsNullOrEmpty(_interfaceLabel) ? "局域网" : _interfaceLabel)} · {_localIp}";
        else
            next = "本地局域网";

        if (DisplayedLanName != next)
        {
            DisplayedLanName = next;
            NotifyUpdated();
        }
    }

    private static void ApplyOptimistic(PlayerState player, string action, double position)
    {
        var now = ProtocolJson.NowMillis();
        switch (action)
        {
            case "play":
                player.Position = player.LivePosition(now);
                player.IsPlaying = true;
                player.UpdatedAt = now;
                break;
            case "pause":
                player.Position = player.LivePosition(now);
                player.IsPlaying = false;
                player.UpdatedAt = now;
                break;
            case "toggle":
                player.Position = player.LivePosition(now);
                player.IsPlaying = !player.IsPlaying;
                player.UpdatedAt = now;
                break;
            case "seek":
                player.Position = Math.Max(0, position);
                player.IsPlaying = true;
                player.UpdatedAt = now;
                break;
            case "next":
            case "prev":
                player.Position = 0;
                player.IsPlaying = true;
                player.UpdatedAt = now;
                break;
        }
    }

    // ==================== UDP Discovery & Presence (41234) ====================

    private void StartUdp()
    {
        try
        {
            var udp = new UdpClient();
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, UdpPort));
            udp.EnableBroadcast = true;
            try
            {
                udp.JoinMulticastGroup(IPAddress.Parse(MulticastGroup));
            }
            catch { }

            _udpClient = udp;
            _ = Task.Run(() => UdpReceiveLoopAsync(udp, _cts.Token));
        }
        catch
        {
            // Fallback: send-only UDP socket if bind failed
            try
            {
                var udp = new UdpClient(0) { EnableBroadcast = true };
                _udpClient = udp;
            }
            catch { }
        }
    }

    private async Task UdpReceiveLoopAsync(UdpClient udp, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var res = await udp.ReceiveAsync(ct);
                var json = Encoding.UTF8.GetString(res.Buffer);
                HandleIncomingJson(json, "局域网直连", res.RemoteEndPoint.Address.ToString());
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                await Task.Delay(100, ct);
            }
        }
    }

    private void BroadcastPresence(bool includeRelay)
    {
        PlayerState playerSnap;
        string room;
        lock (_stateLock)
        {
            playerSnap = LocalPlayer.Clone();
            room = CurrentRoomCode;
        }

        var packet = new PresencePacket
        {
            DeviceId = DeviceId,
            DeviceName = DeviceName,
            Platform = "windows",
            RoomCode = room,
            LanName = _resolvedRealSsid,
            Ip = _localIp,
            Subnet = _localSubnet,
            HttpPort = _httpPort,
            Ts = ProtocolJson.NowMillis(),
            Player = playerSnap
        };

        var targets = new HashSet<string>(_broadcastAddresses) { MulticastGroup, "255.255.255.255" };
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(packet, ProtocolJson.Options));
        foreach (var host in targets)
            SendUdpBytes(bytes, host);

        if (includeRelay && !string.IsNullOrEmpty(room))
            _ = PublishToRelayAsync(room, packet);
    }

    private void SendLeave(string roomCode)
    {
        var packet = new LeavePacket
        {
            DeviceId = DeviceId,
            RoomCode = roomCode,
            Ts = ProtocolJson.NowMillis()
        };
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(packet, ProtocolJson.Options));
        var targets = new HashSet<string>(_broadcastAddresses) { MulticastGroup, "255.255.255.255" };
        foreach (var host in targets)
            SendUdpBytes(bytes, host);
        _ = PublishToRelayAsync(roomCode, packet);
    }

    private void SendUdpPacket<T>(T payload, string host)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, ProtocolJson.Options));
        SendUdpBytes(bytes, host);
    }

    private void SendUdpBytes(byte[] bytes, string host)
    {
        if (_udpClient == null) return;
        try
        {
            _udpClient.Send(bytes, bytes.Length, host, UdpPort);
        }
        catch { }
    }

    // ==================== Raw TCP HTTP Control Server (No Admin UAC Needed!) ====================

    private void StartTcpHttpServer()
    {
        for (int port = 41235; port <= 41245; port++)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
                _tcpListener = listener;
                _httpPort = port;
                _ = Task.Run(() => TcpAcceptLoopAsync(listener, _cts.Token));
                break;
            }
            catch { }
        }
    }

    private async Task TcpAcceptLoopAsync(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var client = await listener.AcceptTcpClientAsync(ct);
                _ = Task.Run(() => HandleTcpClientAsync(client, ct), ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                await Task.Delay(100, ct);
            }
        }
    }

    private async Task HandleTcpClientAsync(TcpClient client, CancellationToken ct)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 2000;
                client.SendTimeout = 2000;
                using var stream = client.GetStream();
                var buffer = new byte[16384];
                int totalRead = 0;
                int contentLength = 0;
                int headerEnd = -1;

                while (totalRead < buffer.Length)
                {
                    int n = await stream.ReadAsync(buffer.AsMemory(totalRead, buffer.Length - totalRead), ct);
                    if (n <= 0) break;
                    totalRead += n;

                    if (headerEnd < 0)
                    {
                        var textSoFar = Encoding.UTF8.GetString(buffer, 0, totalRead);
                        int idx = textSoFar.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                        if (idx >= 0)
                        {
                            var headerStr = textSoFar[..idx];
                            headerEnd = Encoding.UTF8.GetByteCount(headerStr) + 4;
                            foreach (var line in headerStr.Split("\r\n"))
                            {
                                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                                    int.TryParse(line["Content-Length:".Length..].Trim(), out contentLength);
                            }
                        }
                    }

                    if (headerEnd >= 0 && totalRead >= headerEnd + contentLength)
                        break;
                }

                if (headerEnd >= 0 && totalRead > headerEnd)
                {
                    var body = Encoding.UTF8.GetString(buffer, headerEnd, totalRead - headerEnd);
                    HandleIncomingJson(body, "局域网直连", ((IPEndPoint?)client.Client.RemoteEndPoint)?.Address.ToString() ?? "");
                }

                var resp = Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}");
                await stream.WriteAsync(resp, ct);
            }
            catch { }
        }
    }

    private async Task SendHttpCommandAsync(CommandPacket cmd, string ip, int port)
    {
        try
        {
            var json = JsonSerializer.Serialize(cmd, ProtocolJson.Options);
            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            await _httpClient.PostAsync($"http://{ip}:{port}/api/command", content);
        }
        catch { }
    }

    // ==================== Automatic Room Relay Fallback ====================

    private void StartRelaySubscription(string roomCode)
    {
        StopRelaySubscription();
        _relayCts = new CancellationTokenSource();
        var ct = _relayCts.Token;
        _ = Task.Run(() => RelayLoopAsync(roomCode, ct), ct);
    }

    private void StopRelaySubscription()
    {
        try { _relayCts?.Cancel(); } catch { }
        _relayCts?.Dispose();
        _relayCts = null;
    }

    private async Task RelayLoopAsync(string roomCode, CancellationToken ct)
    {
        var url = $"{RelayBase}/lmc_v2_r_{roomCode}/sse?since=2m";
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                using var resp = await _sseClient.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                using var stream = await resp.Content.ReadAsStreamAsync(ct);
                using var reader = new StreamReader(stream, Encoding.UTF8);

                while (!ct.IsCancellationRequested)
                {
                    var line = await reader.ReadLineAsync(ct);
                    if (line == null) break;
                    if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
                    var raw = line[5..].Trim();
                    try
                    {
                        using var doc = JsonDocument.Parse(raw);
                        if (doc.RootElement.TryGetProperty("event", out var ev) && ev.GetString() == "message"
                            && doc.RootElement.TryGetProperty("message", out var msg))
                        {
                            var inner = msg.GetString();
                            if (!string.IsNullOrEmpty(inner))
                                HandleIncomingJson(inner, "中继同步", "");
                        }
                    }
                    catch { }
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                try { await Task.Delay(2000, ct); } catch { break; }
            }
        }
    }

    private async Task PublishToRelayAsync<T>(string roomCode, T payload)
    {
        try
        {
            var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);
            using var content = new StringContent(json, Encoding.UTF8, "text/plain");
            await _httpClient.PostAsync($"{RelayBase}/lmc_v2_r_{roomCode}", content);
        }
        catch { }
    }

    // ==================== Unified Packet Processing ====================

    private void HandleIncomingJson(string json, string sourceMode, string senderIp)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("type", out var typeProp)) return;
            var type = typeProp.GetString();
            var now = ProtocolJson.NowMillis();

            if (type == "presence")
            {
                var pkt = JsonSerializer.Deserialize<PresencePacket>(json, ProtocolJson.Options);
                if (pkt == null || string.IsNullOrEmpty(pkt.DeviceId) || pkt.DeviceId == DeviceId) return;

                if (!WindowsNetworkInfo.IsValidSsid(_resolvedRealSsid)
                    && !string.IsNullOrEmpty(_localSubnet)
                    && pkt.Subnet == _localSubnet
                    && WindowsNetworkInfo.IsValidSsid(pkt.LanName))
                {
                    _resolvedRealSsid = pkt.LanName.Trim();
                    UpdateDisplayedLanName();
                }

                bool shouldReply = false;
                bool changed = false;

                lock (_stateLock)
                {
                    if (sourceMode == "局域网直连" && pkt.RoomCode.Length == 4 && pkt.RoomCode.All(char.IsDigit))
                    {
                        if (!_discoveredRooms.ContainsKey(pkt.RoomCode)) changed = true;
                        _discoveredRooms[pkt.RoomCode] = now;
                    }

                    if (!string.IsNullOrEmpty(CurrentRoomCode) && pkt.RoomCode == CurrentRoomCode)
                    {
                        var effIp = !string.IsNullOrEmpty(senderIp) ? senderIp : pkt.Ip;
                        if (_peersById.TryGetValue(pkt.DeviceId, out var existing))
                        {
                            if (pkt.Ts < existing.LastPacketTs) return;
                            existing.DeviceName = pkt.DeviceName;
                            existing.Platform = pkt.Platform;
                            existing.LanName = pkt.LanName;
                            if (!string.IsNullOrEmpty(effIp)) existing.Ip = effIp;
                            if (pkt.HttpPort > 0) existing.HttpPort = pkt.HttpPort;
                            existing.LastSeen = now;
                            existing.LastPacketTs = pkt.Ts;
                            if (sourceMode == "局域网直连") existing.ConnectionMode = "局域网直连";
                            existing.Player = pkt.Player ?? new PlayerState();
                            changed = true;
                        }
                        else
                        {
                            _peersById[pkt.DeviceId] = new DeviceRecord
                            {
                                DeviceId = pkt.DeviceId,
                                DeviceName = pkt.DeviceName,
                                Platform = pkt.Platform,
                                RoomCode = pkt.RoomCode,
                                LanName = pkt.LanName,
                                Ip = effIp,
                                Subnet = pkt.Subnet,
                                HttpPort = pkt.HttpPort,
                                LastSeen = now,
                                LastPacketTs = pkt.Ts,
                                ConnectionMode = sourceMode,
                                Player = pkt.Player ?? new PlayerState()
                            };
                            shouldReply = true;
                            changed = true;
                        }
                    }
                }

                if (changed) NotifyUpdated();
                if (shouldReply) BroadcastPresence(includeRelay: true);
            }
            else if (type == "leave")
            {
                var pkt = JsonSerializer.Deserialize<LeavePacket>(json, ProtocolJson.Options);
                if (pkt == null || string.IsNullOrEmpty(pkt.DeviceId) || pkt.DeviceId == DeviceId) return;
                bool removed = false;
                lock (_stateLock)
                {
                    if (_peersById.TryGetValue(pkt.DeviceId, out var existing) && pkt.Ts >= existing.LastPacketTs)
                        removed = _peersById.Remove(pkt.DeviceId);
                }
                if (removed) NotifyUpdated();
            }
            else if (type == "command")
            {
                var cmd = JsonSerializer.Deserialize<CommandPacket>(json, ProtocolJson.Options);
                if (cmd == null || string.IsNullOrEmpty(cmd.CmdId)) return;
                if (cmd.Ts < _startupMs - 5000) return;
                if (!_executedCmdIds.TryAdd(cmd.CmdId, 1)) return;

                if (cmd.TargetDeviceId == DeviceId)
                {
                    lock (_stateLock) { ApplyOptimistic(LocalPlayer, cmd.Action, cmd.Position); }
                    NotifyUpdated();
                    _ = _media.ExecuteCommandAsync(cmd.Action, cmd.Position);
                    BroadcastPresence(includeRelay: !string.IsNullOrEmpty(CurrentRoomCode));
                }
            }
        }
        catch { }
    }

    private void PruneStalePeers()
    {
        var now = ProtocolJson.NowMillis();
        bool changed = false;
        lock (_stateLock)
        {
            var stalePeers = _peersById.Where(kv => now - kv.Value.LastSeen > 14000).Select(kv => kv.Key).ToList();
            foreach (var id in stalePeers) { _peersById.Remove(id); changed = true; }

            var staleRooms = _discoveredRooms.Where(kv => now - kv.Value > 15000).Select(kv => kv.Key).ToList();
            foreach (var r in staleRooms) { _discoveredRooms.Remove(r); changed = true; }
        }
        if (changed) NotifyUpdated();
    }

    private void NotifyUpdated()
    {
        StateUpdated?.Invoke();
    }

    public void Dispose()
    {
        _cts.Cancel();
        StopRelaySubscription();
        _heartbeatTimer?.Dispose();
        _media.Dispose();
        try { _udpClient?.Close(); } catch { }
        try { _tcpListener?.Stop(); } catch { }
        _httpClient.Dispose();
        _sseClient.Dispose();
    }
}
