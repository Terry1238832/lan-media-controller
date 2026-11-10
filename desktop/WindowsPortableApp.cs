using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LanMediaController
{
    public class PlayerState
    {
        public string title = "\u7b2c 1 \u7ae0";
        public bool isPlaying = false;
        public double position = 0;
        public double duration = 300;
        public int chapterIndex = 1;
    }

    public class DeviceRecord
    {
        public string deviceId;
        public string deviceName;
        public string platform;
        public string roomCode = "";
        public bool isNativeHost = false;
        public string ip;
        public int httpPort = 19889;
        public PlayerState player = new PlayerState();
        public long lastSeen;
    }

    static class Program
    {
        private const int UDP_PORT = 19888;
        private static int HTTP_PORT = 8889;

        private static readonly string HostDeviceId = "win-" + Environment.MachineName.ToLowerInvariant();
        private static readonly ConcurrentDictionary<string, DeviceRecord> DevicesMap = new ConcurrentDictionary<string, DeviceRecord>();
        private static readonly ConcurrentDictionary<string, DeviceRecord> RemoteLanDevices = new ConcurrentDictionary<string, DeviceRecord>();
        private static readonly ConcurrentDictionary<string, bool> ActiveRooms = new ConcurrentDictionary<string, bool>();
        private static readonly ConcurrentDictionary<string, bool> KnownPeerIps = new ConcurrentDictionary<string, bool>();
        private static readonly ConcurrentQueue<Dictionary<string, object>> PendingPeerCommands = new ConcurrentQueue<Dictionary<string, object>>();

        private static string LocalLanName = "Rogers4808";
        private static string EmbeddedHtml = "";
        private static Process WinBridgeProc = null;
        private static UdpClient UdpServer = null;
        private static TcpListener HttpTcpServer = null;
        private static NotifyIcon TrayIcon = null;
        private static volatile bool Running = true;
        private static readonly Random Rng = new Random();

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const byte VK_MEDIA_NEXT_TRACK = 0xB0;
        private const byte VK_MEDIA_PREV_TRACK = 0xB1;
        private const byte VK_MEDIA_PLAY_PAUSE = 0xB3;

        private static void TapMediaKey(byte vk)
        {
            try
            {
                keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
                keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
            catch { }
        }

        private static void DetectNetworkProfileFromRegistry()
        {
            try
            {
                using (var profilesKey = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"))
                {
                    if (profilesKey != null)
                    {
                        foreach (var subName in profilesKey.GetSubKeyNames())
                        {
                            using (var sub = profilesKey.OpenSubKey(subName))
                            {
                                if (sub != null)
                                {
                                    string pName = Convert.ToString(sub.GetValue("ProfileName"));
                                    if (!string.IsNullOrWhiteSpace(pName) && !pName.StartsWith("Network") && !pName.StartsWith("\u7f51\u7edc"))
                                    {
                                        LocalLanName = pName.Trim();
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            catch { }
        }

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            DetectNetworkProfileFromRegistry();
            KillPreviousListener(HTTP_PORT);

            LoadEmbeddedResources();
            StartWinBridgeProcess();
            StartHttpServer();
            StartUdpServer();
            StartBackgroundTimers();

            TrayIcon = new NotifyIcon();
            try
            {
                TrayIcon.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
            }
            catch
            {
                TrayIcon.Icon = SystemIcons.Application;
            }
            TrayIcon.Text = "\u56db\u7aef\u5c40\u57df\u7f51\u5a92\u4f53\u63a7\u5236\u5668";
            TrayIcon.Visible = true;

            var menu = new ContextMenuStrip();
            var openItem = new ToolStripMenuItem("\u6253\u5f00\u63a7\u5236\u9762\u677f");
            openItem.Click += (s, e) => OpenControlWindow();
            var exitItem = new ToolStripMenuItem("\u9000\u51fa\u540e\u53f0\u670d\u52a1");
            exitItem.Click += (s, e) => ShutdownApp();
            menu.Items.Add(openItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            TrayIcon.ContextMenuStrip = menu;
            TrayIcon.DoubleClick += (s, e) => OpenControlWindow();

            OpenControlWindow();
            Application.Run();
        }

        private static bool IsPortInUse(int port)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start();
                listener.Stop();
                return false;
            }
            catch
            {
                return true;
            }
        }

        private static void KillPreviousListener(int port)
        {
            try
            {
                var cur = Process.GetCurrentProcess();
                foreach (var p in Process.GetProcessesByName(cur.ProcessName))
                {
                    try
                    {
                        if (p.Id != cur.Id)
                        {
                            p.Kill();
                        }
                    }
                    catch { }
                }
            }
            catch { }
        }

        private static void LoadEmbeddedResources()
        {
            var asm = Assembly.GetExecutingAssembly();
            using (var stream = asm.GetManifestResourceStream("index.html"))
            {
                if (stream != null)
                {
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        EmbeddedHtml = reader.ReadToEnd();
                    }
                }
            }

            try
            {
                string tempBridge = Path.Combine(Path.GetTempPath(), "lan_media_win_bridge.ps1");
                using (var stream = asm.GetManifestResourceStream("win-media-bridge.ps1"))
                {
                    if (stream != null)
                    {
                        using (var fs = new FileStream(tempBridge, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
                        {
                            stream.CopyTo(fs);
                        }
                    }
                }
            }
            catch { }
        }

        private static void StartWinBridgeProcess()
        {
            var t = new Thread(() =>
            {
                try
                {
                    string tempBridge = Path.Combine(Path.GetTempPath(), "lan_media_win_bridge.ps1");
                    if (!File.Exists(tempBridge)) return;

                    var psi = new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + tempBridge + "\"",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardInput = true,
                        RedirectStandardOutput = true,
                        StandardOutputEncoding = Encoding.UTF8
                    };
                    WinBridgeProc = Process.Start(psi);
                    if (WinBridgeProc != null)
                    {
                        WinBridgeProc.StandardInput.WriteLine("{\"op\":\"state\"}");
                        string line;
                        var jss = new JavaScriptSerializer();
                        while (Running && (line = WinBridgeProc.StandardOutput.ReadLine()) != null)
                        {
                            try
                            {
                                var dict = jss.Deserialize<Dictionary<string, object>>(line);
                                if (dict != null)
                                {
                                    if (dict.ContainsKey("lanName"))
                                    {
                                        string ln = Convert.ToString(dict["lanName"]);
                                        if (!string.IsNullOrWhiteSpace(ln) && ln != "Local Network")
                                        {
                                            LocalLanName = ln;
                                        }
                                    }
                                    if (dict.ContainsKey("players") && dict["players"] is System.Collections.IEnumerable)
                                    {
                                        Dictionary<string, object> bestP = null;
                                        foreach (var item in (System.Collections.IEnumerable)dict["players"])
                                        {
                                            var pDict = item as Dictionary<string, object>;
                                            if (pDict == null) continue;
                                            string pId = pDict.ContainsKey("playerId") ? Convert.ToString(pDict["playerId"]) : "";
                                            if (pId == "system" && string.IsNullOrEmpty(Convert.ToString(pDict.ContainsKey("title") ? pDict["title"] : ""))) continue;
                                            bool playing = pDict.ContainsKey("isPlaying") && Convert.ToBoolean(pDict["isPlaying"]);
                                            if (bestP == null || playing)
                                            {
                                                bestP = pDict;
                                                if (playing) break;
                                            }
                                        }
                                        if (bestP != null)
                                        {
                                            string appName = bestP.ContainsKey("appName") ? Convert.ToString(bestP["appName"]) : "";
                                            string title = bestP.ContainsKey("title") ? Convert.ToString(bestP["title"]) : "";
                                            string artist = bestP.ContainsKey("artist") ? Convert.ToString(bestP["artist"]) : "";
                                            bool isPlaying = bestP.ContainsKey("isPlaying") && Convert.ToBoolean(bestP["isPlaying"]);
                                            double pos = bestP.ContainsKey("position") ? Convert.ToDouble(bestP["position"]) : 0;
                                            double dur = bestP.ContainsKey("duration") ? Convert.ToDouble(bestP["duration"]) : 300;
                                            if (dur <= 0) dur = 300;

                                            string fullTitle = title;
                                            if (!string.IsNullOrEmpty(artist)) fullTitle = fullTitle + " - " + artist;
                                            if (!string.IsNullOrEmpty(appName) && !fullTitle.Contains(appName))
                                            {
                                                fullTitle = string.IsNullOrEmpty(fullTitle) ? appName : (appName + " \u00b7 " + fullTitle);
                                            }

                                            foreach (var d in DevicesMap.Values)
                                            {
                                                if (d.isNativeHost && d.player != null)
                                                {
                                                    if (!string.IsNullOrEmpty(fullTitle)) d.player.title = fullTitle;
                                                    d.player.isPlaying = isPlaying;
                                                    if (pos > 0 || !isPlaying) d.player.position = Math.Round(pos);
                                                    d.player.duration = Math.Round(dur);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            catch { }
                        }
                    }
                }
                catch { }
            });
            t.IsBackground = true;
            t.Start();
        }

        private static void SendToWinBridge(string action, double pos)
        {
            try
            {
                if (WinBridgeProc != null && !WinBridgeProc.HasExited)
                {
                    var jss = new JavaScriptSerializer();
                    string json = jss.Serialize(new Dictionary<string, object>
                    {
                        { "op", "cmd" },
                        { "playerId", "system" },
                        { "action", action },
                        { "position", pos }
                    });
                    WinBridgeProc.StandardInput.WriteLine(json);
                    return;
                }
            }
            catch { }

            if (action == "prev") TapMediaKey(VK_MEDIA_PREV_TRACK);
            else if (action == "next") TapMediaKey(VK_MEDIA_NEXT_TRACK);
            else TapMediaKey(VK_MEDIA_PLAY_PAUSE);
        }

        private static string GetPrimaryLanIp(out List<string> broadcasts)
        {
            broadcasts = new List<string> { "255.255.255.255" };
            string bestIp = "127.0.0.1";
            int bestScore = -999;

            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                    string name = (ni.Name + " " + ni.Description).ToLowerInvariant();
                    bool isVirtual = name.Contains("radmin") || name.Contains("vmware") || name.Contains("virtualbox") ||
                                     name.Contains("vethernet") || name.Contains("wsl") || name.Contains("hyper-v") ||
                                     name.Contains("tailscale") || name.Contains("zerotier") || name.Contains("tap");
                    bool isPreferred = name.Contains("wi-fi") || name.Contains("wlan") || name.Contains("wireless") || name.Contains("ethernet");

                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily == AddressFamily.InterNetwork)
                        {
                            string ip = ua.Address.ToString();
                            int score = 0;
                            if (isPreferred) score += 50;
                            if (isVirtual) score -= 100;
                            if (ip.StartsWith("192.168.") || ip.StartsWith("10.") || ip.StartsWith("172.")) score += 20;

                            if (score > bestScore)
                            {
                                bestScore = score;
                                bestIp = ip;
                            }

                            if (!isVirtual && ua.IPv4Mask != null)
                            {
                                byte[] ipBytes = ua.Address.GetAddressBytes();
                                byte[] maskBytes = ua.IPv4Mask.GetAddressBytes();
                                if (ipBytes.Length == 4 && maskBytes.Length == 4)
                                {
                                    byte[] bcast = new byte[4];
                                    for (int i = 0; i < 4; i++) bcast[i] = (byte)(ipBytes[i] | (~maskBytes[i] & 0xFF));
                                    string bcastStr = string.Join(".", bcast);
                                    if (!broadcasts.Contains(bcastStr)) broadcasts.Add(bcastStr);
                                }
                            }
                        }
                    }
                }
            }
            catch { }
            return bestIp;
        }

        private static DeviceRecord EnsureDevice(string deviceId, string deviceName, string platform, bool isHost)
        {
            List<string> dummy;
            string ip = GetPrimaryLanIp(out dummy);
            var dev = DevicesMap.GetOrAdd(deviceId, id => new DeviceRecord
            {
                deviceId = id,
                deviceName = !string.IsNullOrWhiteSpace(deviceName) ? deviceName.Trim() : "Windows \u8bbe\u5907",
                platform = !string.IsNullOrWhiteSpace(platform) ? platform : "windows",
                roomCode = "",
                isNativeHost = isHost,
                ip = ip,
                httpPort = HTTP_PORT,
                lastSeen = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            });

            dev.lastSeen = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            dev.ip = ip;
            if (!string.IsNullOrWhiteSpace(deviceName)) dev.deviceName = deviceName.Trim();
            if (!string.IsNullOrWhiteSpace(platform)) dev.platform = platform;
            if (isHost) dev.isNativeHost = true;
            return dev;
        }

        private static void ApplyActionToPlayer(PlayerState p, string action, double pos)
        {
            if (p == null) return;
            if (action == "play") p.isPlaying = true;
            else if (action == "pause") p.isPlaying = false;
            else if (action == "toggle") p.isPlaying = !p.isPlaying;
            else if (action == "seek")
            {
                p.position = Math.Max(0, Math.Min(p.duration, Math.Round(pos)));
                p.isPlaying = true;
            }
            else if (action == "next")
            {
                p.chapterIndex++;
                if (string.IsNullOrEmpty(p.title) || p.title.StartsWith("\u7b2c "))
                {
                    p.title = "\u7b2c " + p.chapterIndex + " \u7ae0";
                }
                p.position = 0;
                p.isPlaying = true;
            }
            else if (action == "prev")
            {
                p.chapterIndex = Math.Max(1, p.chapterIndex - 1);
                if (string.IsNullOrEmpty(p.title) || p.title.StartsWith("\u7b2c "))
                {
                    p.title = "\u7b2c " + p.chapterIndex + " \u7ae0";
                }
                p.position = 0;
                p.isPlaying = true;
            }
        }

        // ============================================================================
        // HTTP Server (Port 19889)
        // ============================================================================
        private static void StartHttpServer()
        {
            int[] candidatePorts = new int[] { 8889, 9889, 18889, 17889, 0 };
            bool bound = false;
            foreach (int p in candidatePorts)
            {
                try
                {
                    var srv = new TcpListener(IPAddress.Any, p);
                    srv.Start();
                    HttpTcpServer = srv;
                    HTTP_PORT = ((IPEndPoint)srv.LocalEndpoint).Port;
                    bound = true;
                    break;
                }
                catch { }
            }
            if (!bound)
            {
                try
                {
                    var srv = new TcpListener(IPAddress.Loopback, 0);
                    srv.Start();
                    HttpTcpServer = srv;
                    HTTP_PORT = ((IPEndPoint)srv.LocalEndpoint).Port;
                    bound = true;
                }
                catch { return; }
            }

            var t = new Thread(() =>
            {
                try
                {
                    while (Running)
                    {
                        var client = HttpTcpServer.AcceptTcpClient();
                        ThreadPool.QueueUserWorkItem(HandleHttpClient, client);
                    }
                }
                catch { }
            });
            t.IsBackground = true;
            t.Start();
        }

        private static void HandleHttpClient(object obj)
        {
            using (var client = (TcpClient)obj)
            {
                try
                {
                    client.ReceiveTimeout = 3000;
                    client.SendTimeout = 3000;
                    using (var stream = client.GetStream())
                    {
                        byte[] buf = new byte[16384];
                        int read = stream.Read(buf, 0, buf.Length);
                        if (read <= 0) return;

                        string rawReq = Encoding.UTF8.GetString(buf, 0, read);
                        int headerEnd = rawReq.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                        if (headerEnd < 0) return;

                        string headerPart = rawReq.Substring(0, headerEnd);
                        string[] lines = headerPart.Split(new[] { "\r\n" }, StringSplitOptions.None);
                        if (lines.Length == 0) return;

                        string[] firstLine = lines[0].Split(' ');
                        if (firstLine.Length < 2) return;
                        string method = firstLine[0].ToUpperInvariant();
                        string fullUrl = firstLine[1];

                        int contentLength = 0;
                        foreach (var l in lines)
                        {
                            if (l.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                            {
                                int.TryParse(l.Substring(15).Trim(), out contentLength);
                            }
                        }

                        int bodyStartByte = Encoding.UTF8.GetByteCount(headerPart + "\r\n\r\n");
                        int bodyBytesAlreadyRead = read - bodyStartByte;
                        string body = "";
                        if (contentLength > 0)
                        {
                            byte[] bodyBuf = new byte[contentLength];
                            if (bodyBytesAlreadyRead > 0)
                            {
                                Array.Copy(buf, bodyStartByte, bodyBuf, 0, Math.Min(bodyBytesAlreadyRead, contentLength));
                            }
                            int offset = bodyBytesAlreadyRead;
                            while (offset < contentLength)
                            {
                                int n = stream.Read(bodyBuf, offset, contentLength - offset);
                                if (n <= 0) break;
                                offset += n;
                            }
                            body = Encoding.UTF8.GetString(bodyBuf, 0, contentLength);
                        }

                        if (method == "OPTIONS")
                        {
                            WriteHttpResponse(stream, "204 No Content", "text/plain", "");
                            return;
                        }

                        string path = fullUrl;
                        string query = "";
                        int qIdx = fullUrl.IndexOf('?');
                        if (qIdx >= 0)
                        {
                            path = fullUrl.Substring(0, qIdx);
                            query = fullUrl.Substring(qIdx + 1);
                        }

                        var jss = new JavaScriptSerializer();

                        if (method == "GET" && path == "/api/state")
                        {
                            var qParams = ParseQueryString(query);
                            string devId = qParams.ContainsKey("deviceId") ? qParams["deviceId"] : HostDeviceId;
                            string plat = qParams.ContainsKey("platform") ? qParams["platform"] : "windows";
                            string devName = qParams.ContainsKey("deviceName") ? qParams["deviceName"] : "";

                            bool isLocal = ((IPEndPoint)client.Client.RemoteEndPoint).Address.Equals(IPAddress.Loopback);
                            var selfDev = EnsureDevice(devId, devName, plat, isLocal);

                            var roomDevs = new List<DeviceRecord>();
                            if (!string.IsNullOrEmpty(selfDev.roomCode))
                            {
                                foreach (var d in DevicesMap.Values)
                                    if (d.roomCode == selfDev.roomCode) roomDevs.Add(d);
                                foreach (var d in RemoteLanDevices.Values)
                                    if (d.roomCode == selfDev.roomCode && roomDevs.All(x => x.deviceId != d.deviceId)) roomDevs.Add(d);
                            }

                            var rooms = new HashSet<string>(ActiveRooms.Keys);
                            foreach (var d in DevicesMap.Values) if (!string.IsNullOrEmpty(d.roomCode)) rooms.Add(d.roomCode);
                            foreach (var d in RemoteLanDevices.Values) if (!string.IsNullOrEmpty(d.roomCode)) rooms.Add(d.roomCode);

                            List<string> bcasts;
                            string primaryIp = GetPrimaryLanIp(out bcasts);

                            string json = jss.Serialize(new Dictionary<string, object>
                            {
                                { "lanName", LocalLanName },
                                { "localIp", primaryIp },
                                { "httpPort", HTTP_PORT },
                                { "selfDevice", selfDev },
                                { "roomDevices", roomDevs },
                                { "activeRooms", rooms.ToList() }
                            });
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", json);
                            return;
                        }

                        if (method == "POST" && path == "/api/device/update")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body) ?? new Dictionary<string, object>();
                            string devId = data.ContainsKey("deviceId") ? Convert.ToString(data["deviceId"]) : HostDeviceId;
                            string devName = data.ContainsKey("deviceName") ? Convert.ToString(data["deviceName"]) : "";
                            string plat = data.ContainsKey("platform") ? Convert.ToString(data["platform"]) : "windows";
                            var dev = EnsureDevice(devId, devName, plat, false);
                            BroadcastUdpState();
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", jss.Serialize(new { ok = true, selfDevice = dev }));
                            return;
                        }

                        if (method == "POST" && path == "/api/room/create")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body) ?? new Dictionary<string, object>();
                            string devId = data.ContainsKey("deviceId") ? Convert.ToString(data["deviceId"]) : HostDeviceId;
                            string devName = data.ContainsKey("deviceName") ? Convert.ToString(data["deviceName"]) : "";
                            string plat = data.ContainsKey("platform") ? Convert.ToString(data["platform"]) : "windows";
                            var dev = EnsureDevice(devId, devName, plat, false);
                            string code;
                            lock (Rng) { code = Rng.Next(1000, 10000).ToString(); }
                            ActiveRooms[code] = true;
                            dev.roomCode = code;
                            BroadcastUdpState();
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", jss.Serialize(new { ok = true, roomCode = code, selfDevice = dev }));
                            return;
                        }

                        if (method == "POST" && path == "/api/room/join")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body) ?? new Dictionary<string, object>();
                            string devId = data.ContainsKey("deviceId") ? Convert.ToString(data["deviceId"]) : HostDeviceId;
                            string devName = data.ContainsKey("deviceName") ? Convert.ToString(data["deviceName"]) : "";
                            string plat = data.ContainsKey("platform") ? Convert.ToString(data["platform"]) : "windows";
                            string code = data.ContainsKey("roomCode") ? Convert.ToString(data["roomCode"]).Trim() : "";
                            var dev = EnsureDevice(devId, devName, plat, false);
                            ActiveRooms[code] = true;
                            dev.roomCode = code;
                            BroadcastUdpState();
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", jss.Serialize(new { ok = true, roomCode = code, selfDevice = dev }));
                            return;
                        }

                        if (method == "POST" && path == "/api/room/leave")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body) ?? new Dictionary<string, object>();
                            string devId = data.ContainsKey("deviceId") ? Convert.ToString(data["deviceId"]) : HostDeviceId;
                            var dev = EnsureDevice(devId, "", "", false);
                            dev.roomCode = "";
                            BroadcastUdpState();
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", jss.Serialize(new { ok = true, selfDevice = dev }));
                            return;
                        }

                        if (method == "POST" && path == "/api/control")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body) ?? new Dictionary<string, object>();
                            string targetId = data.ContainsKey("targetDeviceId") ? Convert.ToString(data["targetDeviceId"]) : "";
                            string action = data.ContainsKey("action") ? Convert.ToString(data["action"]) : "toggle";
                            double pos = data.ContainsKey("position") && data["position"] != null ? Convert.ToDouble(data["position"]) : 0;

                            DeviceRecord localTarget;
                            if (DevicesMap.TryGetValue(targetId, out localTarget))
                            {
                                ApplyActionToPlayer(localTarget.player, action, pos);
                                if (localTarget.isNativeHost) SendToWinBridge(action, pos);
                                BroadcastUdpState();
                            }
                            else
                            {
                                DeviceRecord remoteTarget;
                                if (RemoteLanDevices.TryGetValue(targetId, out remoteTarget))
                                {
                                    ApplyActionToPlayer(remoteTarget.player, action, pos);
                                    PendingPeerCommands.Enqueue(new Dictionary<string, object>
                                    {
                                        { "ip", remoteTarget.ip },
                                        { "targetDeviceId", targetId },
                                        { "action", action },
                                        { "position", pos }
                                    });
                                    SendUdpCommand(remoteTarget.ip, targetId, action, pos);
                                    ThreadPool.QueueUserWorkItem(_ => SyncWithHttpPeer(remoteTarget.ip));
                                }
                            }
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", "{\"ok\":true}");
                            return;
                        }

                        if (method == "POST" && path == "/api/lan-sync")
                        {
                            var data = jss.Deserialize<Dictionary<string, object>>(body);
                            string remoteIp = ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString();
                            if (data != null && data.ContainsKey("ip"))
                            {
                                string bodyIp = Convert.ToString(data["ip"]);
                                if (!string.IsNullOrEmpty(bodyIp)) remoteIp = bodyIp;
                            }
                            IngestRemoteSyncPayload(data, remoteIp);
                            string replyJson = BuildLocalSyncJson(remoteIp);
                            WriteHttpResponse(stream, "200 OK", "application/json; charset=utf-8", replyJson);
                            return;
                        }

                        WriteHttpResponse(stream, "200 OK", "text/html; charset=utf-8", EmbeddedHtml);
                    }
                }
                catch { }
            }
        }

        private static Dictionary<string, string> ParseQueryString(string query)
        {
            var dict = new Dictionary<string, string>();
            if (string.IsNullOrEmpty(query)) return dict;
            foreach (var part in query.Split('&'))
            {
                int eq = part.IndexOf('=');
                if (eq > 0)
                {
                    string k = Uri.UnescapeDataString(part.Substring(0, eq));
                    string v = Uri.UnescapeDataString(part.Substring(eq + 1));
                    dict[k] = v;
                }
            }
            return dict;
        }

        private static void WriteHttpResponse(NetworkStream stream, string status, string contentType, string body)
        {
            byte[] bodyBytes = Encoding.UTF8.GetBytes(body ?? "");
            string headers = "HTTP/1.1 " + status + "\r\n" +
                             "Content-Type: " + contentType + "\r\n" +
                             "Access-Control-Allow-Origin: *\r\n" +
                             "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                             "Access-Control-Allow-Headers: Content-Type\r\n" +
                             "Content-Length: " + bodyBytes.Length + "\r\n" +
                             "Connection: close\r\n\r\n";
            byte[] headerBytes = Encoding.UTF8.GetBytes(headers);
            stream.Write(headerBytes, 0, headerBytes.Length);
            if (bodyBytes.Length > 0)
            {
                stream.Write(bodyBytes, 0, bodyBytes.Length);
            }
        }

        // ============================================================================
        // UDP LAN Sync (Port 19888) + HTTP /api/lan-sync Active Subnet Discovery
        // ============================================================================
        private static void IngestRemoteSyncPayload(Dictionary<string, object> dict, string senderIp)
        {
            if (dict == null) return;
            string senderHost = dict.ContainsKey("senderHostId") ? Convert.ToString(dict["senderHostId"]) : "";
            if (senderHost == HostDeviceId) return;

            if (!string.IsNullOrEmpty(senderIp) && senderIp != "127.0.0.1" && senderIp != "::1")
            {
                KnownPeerIps[senderIp] = true;
            }

            if (dict.ContainsKey("rooms"))
            {
                var roomList = dict["rooms"] as System.Collections.ArrayList;
                if (roomList != null)
                {
                    foreach (var r in roomList)
                    {
                        string rs = Convert.ToString(r);
                        if (!string.IsNullOrEmpty(rs)) ActiveRooms[rs] = true;
                    }
                }
            }

            if (dict.ContainsKey("devices"))
            {
                var devList = dict["devices"] as System.Collections.ArrayList;
                if (devList != null)
                {
                    foreach (var item in devList)
                    {
                        var d = item as Dictionary<string, object>;
                        if (d != null)
                        {
                            string id = d.ContainsKey("deviceId") ? Convert.ToString(d["deviceId"]) : "";
                            if (string.IsNullOrEmpty(id) || DevicesMap.ContainsKey(id)) continue;

                            var rec = RemoteLanDevices.GetOrAdd(id, _id => new DeviceRecord { deviceId = _id });
                            rec.deviceName = d.ContainsKey("deviceName") ? Convert.ToString(d["deviceName"]) : "Device";
                            rec.platform = d.ContainsKey("platform") ? Convert.ToString(d["platform"]) : "windows";
                            rec.roomCode = d.ContainsKey("roomCode") ? Convert.ToString(d["roomCode"]) : "";
                            rec.ip = d.ContainsKey("ip") && !string.IsNullOrEmpty(Convert.ToString(d["ip"])) ? Convert.ToString(d["ip"]) : senderIp;
                            if (d.ContainsKey("httpPort") && d["httpPort"] != null)
                            {
                                int hp;
                                if (int.TryParse(Convert.ToString(d["httpPort"]), out hp) && hp > 0) rec.httpPort = hp;
                            }
                            else if (dict.ContainsKey("httpPort") && dict["httpPort"] != null)
                            {
                                int hp2;
                                if (int.TryParse(Convert.ToString(dict["httpPort"]), out hp2) && hp2 > 0) rec.httpPort = hp2;
                            }
                            rec.lastSeen = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                            if (!string.IsNullOrEmpty(rec.roomCode)) ActiveRooms[rec.roomCode] = true;

                            if (d.ContainsKey("player"))
                            {
                                var pDict = d["player"] as Dictionary<string, object>;
                                if (pDict != null)
                                {
                                    if (rec.player == null) rec.player = new PlayerState();
                                    if (pDict.ContainsKey("title")) rec.player.title = Convert.ToString(pDict["title"]);
                                    if (pDict.ContainsKey("isPlaying")) rec.player.isPlaying = Convert.ToBoolean(pDict["isPlaying"]);
                                    if (pDict.ContainsKey("position")) rec.player.position = Convert.ToDouble(pDict["position"]);
                                    if (pDict.ContainsKey("duration")) rec.player.duration = Convert.ToDouble(pDict["duration"]);
                                    if (pDict.ContainsKey("chapterIndex")) rec.player.chapterIndex = Convert.ToInt32(pDict["chapterIndex"]);
                                }
                            }
                        }
                    }
                }
            }

            if (dict.ContainsKey("pendingCommands"))
            {
                var cmdList = dict["pendingCommands"] as System.Collections.ArrayList;
                if (cmdList != null)
                {
                    foreach (var cItem in cmdList)
                    {
                        var c = cItem as Dictionary<string, object>;
                        if (c != null)
                        {
                            string tid = c.ContainsKey("targetDeviceId") ? Convert.ToString(c["targetDeviceId"]) : "";
                            string act = c.ContainsKey("action") ? Convert.ToString(c["action"]) : "toggle";
                            double pos = c.ContainsKey("position") && c["position"] != null ? Convert.ToDouble(c["position"]) : 0;
                            DeviceRecord localTarget;
                            if (DevicesMap.TryGetValue(tid, out localTarget))
                            {
                                ApplyActionToPlayer(localTarget.player, act, pos);
                                if (localTarget.isNativeHost) SendToWinBridge(act, pos);
                            }
                        }
                    }
                }
            }
        }

        private static string BuildLocalSyncJson(string targetPeerIp)
        {
            List<string> bcasts;
            string primaryIp = GetPrimaryLanIp(out bcasts);
            var cmds = new List<Dictionary<string, object>>();
            if (!string.IsNullOrEmpty(targetPeerIp))
            {
                int count = PendingPeerCommands.Count;
                for (int i = 0; i < count; i++)
                {
                    Dictionary<string, object> item;
                    if (PendingPeerCommands.TryDequeue(out item))
                    {
                        if (Convert.ToString(item["ip"]) == targetPeerIp) cmds.Add(item);
                        else PendingPeerCommands.Enqueue(item);
                    }
                }
            }
            var jss = new JavaScriptSerializer();
            return jss.Serialize(new Dictionary<string, object>
            {
                { "type", "lan_sync" },
                { "senderHostId", HostDeviceId },
                { "lanName", LocalLanName },
                { "ip", primaryIp },
                { "httpPort", HTTP_PORT },
                { "rooms", ActiveRooms.Keys.ToList() },
                { "devices", DevicesMap.Values.ToList() },
                { "pendingCommands", cmds }
            });
        }

        private static void SyncWithHttpPeer(string peerIp)
        {
            List<string> bcasts;
            string primaryIp = GetPrimaryLanIp(out bcasts);
            if (string.IsNullOrEmpty(peerIp) || peerIp == primaryIp || peerIp == "127.0.0.1") return;

            byte[] payload = Encoding.UTF8.GetBytes(BuildLocalSyncJson(peerIp));
            int[] portsToTry = new int[] { 19889, 8889 };
            foreach (int targetPort in portsToTry)
            {
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create("http://" + peerIp + ":" + targetPort + "/api/lan-sync");
                    req.Method = "POST";
                    req.ContentType = "application/json";
                    req.Timeout = 700;
                    req.ReadWriteTimeout = 700;
                    req.ContentLength = payload.Length;
                    using (var reqStream = req.GetRequestStream())
                    {
                        reqStream.Write(payload, 0, payload.Length);
                    }

                    using (var resp = (HttpWebResponse)req.GetResponse())
                    using (var reader = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                    {
                        string replyJson = reader.ReadToEnd();
                        var jss = new JavaScriptSerializer();
                        var replyDict = jss.Deserialize<Dictionary<string, object>>(replyJson);
                        IngestRemoteSyncPayload(replyDict, peerIp);
                        break;
                    }
                }
                catch { }
            }
        }

        private static void StartUdpServer()
        {
            var t = new Thread(() =>
            {
                try
                {
                    UdpServer = new UdpClient();
                    UdpServer.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                    UdpServer.EnableBroadcast = true;
                    UdpServer.Client.Bind(new IPEndPoint(IPAddress.Any, UDP_PORT));

                    var jss = new JavaScriptSerializer();
                    while (Running)
                    {
                        IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                        byte[] data = UdpServer.Receive(ref ep);
                        string json = Encoding.UTF8.GetString(data);
                        var dict = jss.Deserialize<Dictionary<string, object>>(json);
                        if (dict == null || !dict.ContainsKey("type")) continue;

                        string type = Convert.ToString(dict["type"]);
                        if (type == "lan_sync")
                        {
                            IngestRemoteSyncPayload(dict, ep.Address.ToString());
                        }
                        else if (type == "state" && dict.ContainsKey("deviceId"))
                        {
                            string id = Convert.ToString(dict["deviceId"]);
                            if (!string.IsNullOrEmpty(id) && !DevicesMap.ContainsKey(id))
                            {
                                var rec = RemoteLanDevices.GetOrAdd(id, _id => new DeviceRecord { deviceId = _id });
                                rec.deviceName = dict.ContainsKey("deviceName") ? Convert.ToString(dict["deviceName"]) : "iOS 设备";
                                rec.platform = dict.ContainsKey("platform") ? Convert.ToString(dict["platform"]) : "ios";
                                rec.roomCode = dict.ContainsKey("roomCode") ? Convert.ToString(dict["roomCode"]) : "";
                                if (!string.IsNullOrEmpty(rec.roomCode)) ActiveRooms.TryAdd(rec.roomCode, true);
                                rec.ip = ep.Address.ToString();
                                rec.httpPort = 19889;
                                rec.lastSeen = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

                                var pDict = dict.ContainsKey("player") ? dict["player"] as Dictionary<string, object> : null;
                                if (pDict != null)
                                {
                                    if (rec.player == null) rec.player = new PlayerState();
                                    if (pDict.ContainsKey("title")) rec.player.title = Convert.ToString(pDict["title"]);
                                    if (pDict.ContainsKey("isPlaying")) rec.player.isPlaying = Convert.ToBoolean(pDict["isPlaying"]);
                                    if (pDict.ContainsKey("position")) rec.player.position = Convert.ToDouble(pDict["position"]);
                                    if (pDict.ContainsKey("duration")) rec.player.duration = Convert.ToDouble(pDict["duration"]);
                                }
                            }
                        }
                        else if (type == "command")
                        {
                            string targetId = dict.ContainsKey("targetDeviceId") ? Convert.ToString(dict["targetDeviceId"]) : "";
                            string action = dict.ContainsKey("action") ? Convert.ToString(dict["action"]) : "toggle";
                            double pos = dict.ContainsKey("position") && dict["position"] != null ? Convert.ToDouble(dict["position"]) : 0;

                            DeviceRecord localTarget;
                            if (DevicesMap.TryGetValue(targetId, out localTarget))
                            {
                                ApplyActionToPlayer(localTarget.player, action, pos);
                                if (localTarget.isNativeHost) SendToWinBridge(action, pos);
                            }
                        }
                    }
                }
                catch { }
            });
            t.IsBackground = true;
            t.Start();
        }

        private static void BroadcastUdpState()
        {
            try
            {
                List<string> bcasts;
                string primaryIp = GetPrimaryLanIp(out bcasts);
                string json = BuildLocalSyncJson(null);
                byte[] bytes = Encoding.UTF8.GetBytes(json);

                if (UdpServer != null)
                {
                    foreach (var b in bcasts)
                    {
                        UdpServer.Send(bytes, bytes.Length, new IPEndPoint(IPAddress.Parse(b), UDP_PORT));
                    }
                }

                // 同时通过绑定在真实 WLAN 网卡 IP 上的 socket 发送广播，防止被 Radmin VPN / VMware 抢占路由
                if (primaryIp != "127.0.0.1")
                {
                    try
                    {
                        using (var nicUdp = new UdpClient(new IPEndPoint(IPAddress.Parse(primaryIp), 0)))
                        {
                            nicUdp.EnableBroadcast = true;
                            foreach (var b in bcasts)
                            {
                                nicUdp.Send(bytes, bytes.Length, new IPEndPoint(IPAddress.Parse(b), UDP_PORT));
                            }
                        }
                    }
                    catch { }
                }

                foreach (var peerIp in KnownPeerIps.Keys)
                {
                    string ipCopy = peerIp;
                    ThreadPool.QueueUserWorkItem(_ => SyncWithHttpPeer(ipCopy));
                }
            }
            catch { }
        }

        private static void SendUdpCommand(string targetIp, string targetDeviceId, string action, double pos)
        {
            try
            {
                if (UdpServer == null) return;
                var jss = new JavaScriptSerializer();
                string json = jss.Serialize(new Dictionary<string, object>
                {
                    { "type", "command" },
                    { "targetDeviceId", targetDeviceId },
                    { "action", action },
                    { "position", pos }
                });
                byte[] bytes = Encoding.UTF8.GetBytes(json);
                UdpServer.Send(bytes, bytes.Length, new IPEndPoint(IPAddress.Parse(targetIp), UDP_PORT));
            }
            catch { }
        }

        private static void StartBackgroundTimers()
        {
            var t = new Thread(() =>
            {
                while (Running)
                {
                    Thread.Sleep(1000);
                    foreach (var d in DevicesMap.Values)
                    {
                        if (d.player != null && d.player.isPlaying)
                        {
                            d.player.position = Math.Min(d.player.duration, d.player.position + 1);
                            if (d.player.position >= d.player.duration) d.player.position = 0;
                        }
                    }
                    try
                    {
                        if (WinBridgeProc != null && !WinBridgeProc.HasExited)
                        {
                            WinBridgeProc.StandardInput.WriteLine("{\"op\":\"state\"}");
                        }
                    }
                    catch { }
                    BroadcastUdpState();
                }
            });
            t.IsBackground = true;
            t.Start();
        }

        private static void OpenControlWindow()
        {
            string url = "http://127.0.0.1:" + HTTP_PORT;
            string[] edgePaths = {
                @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                @"C:\Program Files\Microsoft\Edge\Application\msedge.exe"
            };
            foreach (var p in edgePaths)
            {
                if (File.Exists(p))
                {
                    try
                    {
                        Process.Start(new ProcessStartInfo
                        {
                            FileName = p,
                            Arguments = "--app=" + url + " --window-size=520,780",
                            UseShellExecute = true
                        });
                        return;
                    }
                    catch { }
                }
            }
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            }
            catch { }
        }

        private static void ShutdownApp()
        {
            Running = false;
            try { if (TrayIcon != null) TrayIcon.Visible = false; } catch { }
            try { if (WinBridgeProc != null && !WinBridgeProc.HasExited) WinBridgeProc.Kill(); } catch { }
            try { if (HttpTcpServer != null) HttpTcpServer.Stop(); } catch { }
            try { if (UdpServer != null) UdpServer.Close(); } catch { }
            Application.Exit();
            Environment.Exit(0);
        }
    }
}
