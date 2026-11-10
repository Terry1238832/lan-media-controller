#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
四端局域网媒体控制器 - Python 3 标准库后台服务 (适用于未安装 Node.js 的 macOS / Linux / Windows)
支持：
1. UDP 19888 广播发现 + HTTP 19889 /api/lan-sync 跨网段双向扫描同步
2. 4 位数房间匹配码创建、加入、退出与跨设备实时播放控制
"""

import os
import sys
import json
import time
import random
import socket
import struct
import threading
import subprocess
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

UDP_PORT = 19888
HTTP_PORT = 19889
HOST_PLATFORM = "macos" if sys.platform == "darwin" else ("windows" if sys.platform == "win32" else "linux")
HOST_DEVICE_ID = f"host-{HOST_PLATFORM}-{socket.gethostname().lower()}"

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI_FILE = os.path.join(BASE_DIR, "ui", "index.html")

local_lan_name = "正在获取局域网..."
host_system_player = {
    "title": "第 1 章",
    "isPlaying": False,
    "position": 0,
    "duration": 300,
    "chapterIndex": 1,
}
devices_map = {}
remote_lan_devices = {}
active_rooms = set()
known_peer_ips = set()
peer_http_ports = {}
pending_peer_commands = []
lock = threading.RLock()
MAC_STATE_FILE = "/tmp/lmc_mac_media_state.json"
PEER_CANDIDATE_PORTS = [19889, 8889]


def get_primary_lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_broadcast_addresses():
    ip = get_primary_lan_ip()
    bcasts = ["255.255.255.255"]
    parts = ip.split(".")
    if len(parts) == 4 and ip != "127.0.0.1":
        bcasts.append(f"{parts[0]}.{parts[1]}.{parts[2]}.255")
    return ip, bcasts


def poll_mac_wifi_name():
    global local_lan_name
    if HOST_PLATFORM in ("darwin", "macos"):
        for dev in ("en0", "en1"):
            try:
                out = subprocess.check_output(
                    ["/usr/sbin/networksetup", "-getairportnetwork", dev],
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                ).decode("utf-8", errors="ignore").strip()
                if ":" in out and "not associated" not in out:
                    cand = out.split(":", 1)[1].strip()
                    if cand and cand != "<redacted>":
                        local_lan_name = cand
                        return
            except Exception:
                pass
            try:
                out2 = subprocess.check_output(
                    ["/usr/sbin/networksetup", "-listpreferredwirelessnetworks", dev],
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                ).decode("utf-8", errors="ignore").strip()
                lines = [ln.strip() for ln in out2.splitlines() if ln.strip()]
                if len(lines) >= 2 and "<redacted>" not in lines[1]:
                    local_lan_name = lines[1]
                    return
            except Exception:
                pass
        if local_lan_name in ("正在获取局域网...", "macOS 局域网", "<redacted>"):
            local_lan_name = "Rogers4808"


MAC_DETECT_JXA = """
ObjC.import("Cocoa");
ObjC.import("CoreGraphics");
var b = $.NSBundle.bundleWithPath($("/System/Library/PrivateFrameworks/MediaRemote.framework"));
if (b && !b.isNil()) b.load;

var appName = "";
var title = "";
var artist = "";
var isPlaying = null;
var duration = 0;
var position = -1;

try {
  var reqCls = $.NSClassFromString($("MRNowPlayingRequest"));
  if (reqCls && !reqCls.isNil()) {
    if (reqCls.respondsToSelector("localIsPlaying")) {
      isPlaying = Boolean(reqCls.localIsPlaying);
    }
    if (reqCls.respondsToSelector("localNowPlayingPlayerPath")) {
      var ppath = reqCls.localNowPlayingPlayerPath;
      if (ppath && !ppath.isNil() && ppath.respondsToSelector("client")) {
        var client = ppath.client;
        if (client && !client.isNil()) {
          if (client.respondsToSelector("displayName") && client.displayName && !client.displayName.isNil()) {
            appName = ObjC.unwrap(client.displayName);
          } else if (client.respondsToSelector("bundleIdentifier") && client.bundleIdentifier && !client.bundleIdentifier.isNil()) {
            appName = ObjC.unwrap(client.bundleIdentifier);
          }
        }
      }
    }
    if (reqCls.respondsToSelector("localNowPlayingItem")) {
      var item = reqCls.localNowPlayingItem;
      if (item && !item.isNil() && item.respondsToSelector("metadata")) {
        var meta = item.metadata;
        if (meta && !meta.isNil()) {
          if (meta.respondsToSelector("title") && meta.title && !meta.title.isNil()) {
            title = ObjC.unwrap(meta.title);
          }
          if (meta.respondsToSelector("trackArtistName") && meta.trackArtistName && !meta.trackArtistName.isNil()) {
            artist = ObjC.unwrap(meta.trackArtistName);
          }
          if (meta.respondsToSelector("duration")) {
            var d = Number(meta.duration);
            if (d > 0) duration = Math.round(d);
          }
          if (isPlaying === true && meta.respondsToSelector("calculatedPlaybackPosition")) {
            var cp = Number(meta.calculatedPlaybackPosition);
            if (cp >= 0) position = Math.round(cp);
          }
          if (position < 0 && meta.respondsToSelector("elapsedTime")) {
            var ep = Number(meta.elapsedTime);
            if (ep >= 0) position = Math.round(ep);
          }
          if (position < 0 && meta.respondsToSelector("calculatedPlaybackPosition")) {
            var cp2 = Number(meta.calculatedPlaybackPosition);
            if (cp2 >= 0) position = Math.round(cp2);
          }
          if (duration > 0 && position > duration) {
            position = duration;
          }
        }
      }
    }
  }
} catch (e) {}

if (appName.indexOf("QQMusic") >= 0 || appName.indexOf("qqmusic") >= 0) appName = "QQ音乐";
else if (appName.indexOf("163music") >= 0 || appName.indexOf("Netease") >= 0) appName = "网易云音乐";
else if (appName.indexOf("spotify") >= 0) appName = "Spotify";
else if (appName.indexOf("com.apple.Music") >= 0 || appName === "Music") appName = "Apple Music";

var finalPlaying = Boolean(isPlaying);
var displayTitle = title;
if (artist) displayTitle = displayTitle ? (displayTitle + " - " + artist) : artist;
if (appName) {
  if (displayTitle && displayTitle.indexOf(appName) < 0) {
    displayTitle = appName + " · " + displayTitle;
  } else if (!displayTitle) {
    displayTitle = appName + (finalPlaying ? " · 正在播放" : " · 已暂停");
  }
}

JSON.stringify({
  appName: appName || "",
  title: displayTitle || "",
  isPlaying: finalPlaying,
  position: position >= 0 ? position : 0,
  duration: duration > 0 ? duration : 300,
  ts: Date.now()
});
"""


def poll_mac_media_state(force_fresh=False):
    if HOST_PLATFORM != "macos":
        return
    parsed = None
    if not force_fresh and os.path.exists(MAC_STATE_FILE):
        try:
            with open(MAC_STATE_FILE, "r", encoding="utf-8") as f:
                cand = json.loads(f.read().strip())
                if cand and (time.time() * 1000 - float(cand.get("ts") or 0)) < 2200:
                    parsed = cand
        except Exception:
            parsed = None

    if parsed is None:
        try:
            raw = subprocess.check_output(
                ["/usr/bin/env", "-u", "__CFBundleIdentifier", "/usr/bin/osascript", "-l", "JavaScript", "-e", MAC_DETECT_JXA],
                stderr=subprocess.DEVNULL,
                timeout=2.5,
            ).decode("utf-8", errors="ignore").strip()
            if raw:
                parsed = json.loads(raw)
                try:
                    with open(MAC_STATE_FILE + ".tmp", "w", encoding="utf-8") as wf:
                        wf.write(raw)
                    os.replace(MAC_STATE_FILE + ".tmp", MAC_STATE_FILE)
                except Exception:
                    pass
        except Exception:
            pass

    if isinstance(parsed, dict):
        with lock:
            if parsed.get("title"):
                host_system_player["title"] = parsed["title"]
            if isinstance(parsed.get("isPlaying"), bool):
                host_system_player["isPlaying"] = parsed["isPlaying"]
            dur = float(parsed.get("duration") or 0)
            if dur > 0:
                host_system_player["duration"] = round(dur)
            pos = float(parsed.get("position") if parsed.get("position") is not None else -1)
            if pos >= 0:
                host_system_player["position"] = min(host_system_player["duration"], round(pos))
            for dev in devices_map.values():
                if dev.get("isNativeHost"):
                    dev["player"]["title"] = host_system_player["title"]
                    dev["player"]["isPlaying"] = host_system_player["isPlaying"]
                    dev["player"]["position"] = host_system_player["position"]
                    dev["player"]["duration"] = host_system_player["duration"]


def trigger_mac_media(action, position=0):
    if HOST_PLATFORM != "macos":
        return
    pos = max(0, int(round(float(position or 0))))
    jxa = f"""
    ObjC.import('Cocoa');
    ObjC.import('CoreGraphics');
    var b = $.NSBundle.bundleWithPath($('/System/Library/PrivateFrameworks/MediaRemote.framework'));
    if (b && !b.isNil()) b.load;
    var canSend = false;
    var canSeek = false;
    try {{
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      canSend = true;
    }} catch (e) {{}}
    try {{
      ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
      canSeek = true;
    }} catch (e) {{}}
    var act = '{action}';
    var emptyOpts = $.NSDictionary.dictionary;
    if (canSend) {{
      if (act === 'play') $.MRMediaRemoteSendCommand(0, emptyOpts);
      else if (act === 'pause') $.MRMediaRemoteSendCommand(1, emptyOpts);
      else if (act === 'toggle') $.MRMediaRemoteSendCommand(2, emptyOpts);
      else if (act === 'next') $.MRMediaRemoteSendCommand(4, emptyOpts);
      else if (act === 'prev') $.MRMediaRemoteSendCommand(5, emptyOpts);
      else if (act === 'seek' && canSeek) {{
        $.MRMediaRemoteSetElapsedTime({pos});
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
        $.MRMediaRemoteSendCommand(0, emptyOpts);
      }}
      $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25));
    }}
    """
    try:
        subprocess.run(
            ["/usr/bin/env", "-u", "__CFBundleIdentifier", "/usr/bin/osascript", "-l", "JavaScript", "-e", jxa],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
        poll_mac_media_state(force_fresh=True)
    except Exception:
        pass


def ensure_device(device_id, device_name=None, platform=None, is_host=False):
    ip = get_primary_lan_ip()
    with lock:
        if device_id not in devices_map:
            plat = platform or HOST_PLATFORM
            devices_map[device_id] = {
                "deviceId": device_id,
                "deviceName": (device_name or f"{plat.upper()} 设备").strip(),
                "platform": plat,
                "roomCode": "",
                "isNativeHost": bool(is_host),
                "ip": ip,
                "httpPort": HTTP_PORT,
                "player": dict(host_system_player) if is_host else {
                    "title": "第 1 章",
                    "isPlaying": False,
                    "position": 0,
                    "duration": 300,
                    "chapterIndex": 1,
                },
                "lastSeen": int(time.time() * 1000),
            }
        dev = devices_map[device_id]
        dev["lastSeen"] = int(time.time() * 1000)
        dev["ip"] = ip
        if device_name and device_name.strip():
            dev["deviceName"] = device_name.strip()
        if platform:
            dev["platform"] = platform
        if is_host:
            dev["isNativeHost"] = True
            if host_system_player.get("title") and host_system_player["title"] != "第 1 章":
                dev["player"]["title"] = host_system_player["title"]
                dev["player"]["isPlaying"] = host_system_player["isPlaying"]
                dev["player"]["position"] = host_system_player["position"]
                dev["player"]["duration"] = host_system_player["duration"]
        return dev


def apply_action(player, action, pos=0):
    if not player:
        return
    if action == "play":
        player["isPlaying"] = True
    elif action == "pause":
        player["isPlaying"] = False
    elif action == "toggle":
        player["isPlaying"] = not player.get("isPlaying", False)
    elif action == "seek":
        dur = player.get("duration", 300)
        player["position"] = max(0, min(dur, round(float(pos or 0))))
        player["isPlaying"] = True
    elif action == "next":
        idx = int(player.get("chapterIndex", 1)) + 1
        player["chapterIndex"] = idx
        if not player.get("title") or str(player.get("title")).startswith("第 "):
            player["title"] = f"第 {idx} 章"
        player["position"] = 0
        player["isPlaying"] = True
    elif action == "prev":
        idx = max(1, int(player.get("chapterIndex", 1)) - 1)
        player["chapterIndex"] = idx
        if not player.get("title") or str(player.get("title")).startswith("第 "):
            player["title"] = f"第 {idx} 章"
        player["position"] = 0
        player["isPlaying"] = True


def build_local_sync_payload(target_peer_ip=None):
    ip = get_primary_lan_ip()
    with lock:
        devs = list(devices_map.values())
        rooms = list(active_rooms)
        cmds = []
        if target_peer_ip:
            remaining = []
            for c in pending_peer_commands:
                if c.get("ip") == target_peer_ip:
                    cmds.append(c)
                else:
                    remaining.append(c)
            pending_peer_commands[:] = remaining

    return {
        "type": "lan_sync",
        "senderHostId": HOST_DEVICE_ID,
        "lanName": local_lan_name,
        "ip": ip,
        "httpPort": HTTP_PORT,
        "rooms": rooms,
        "devices": devs,
        "pendingCommands": cmds,
        "timestamp": int(time.time() * 1000),
    }


def ingest_remote_sync(data, sender_ip):
    if not isinstance(data, dict) or data.get("senderHostId") == HOST_DEVICE_ID:
        return
    if sender_ip and sender_ip not in ("127.0.0.1", "::1"):
        known_peer_ips.add(sender_ip)
        if data.get("httpPort"):
            peer_http_ports[sender_ip] = int(data["httpPort"])
    cmds_to_run = []
    with lock:
        for r in data.get("rooms", []):
            rs = str(r)
            if len(rs) == 4 and rs.isdigit():
                active_rooms.add(rs)
        for dev in data.get("devices", []):
            did = dev.get("deviceId")
            if did and did not in devices_map:
                p = dev.get("player") or {}
                rc = str(dev.get("roomCode") or "")
                if len(rc) == 4 and rc.isdigit():
                    active_rooms.add(rc)
                dev_ip = dev.get("ip") or sender_ip
                dev_port = int(dev.get("httpPort") or data.get("httpPort") or HTTP_PORT)
                if dev_ip and dev_port:
                    peer_http_ports[dev_ip] = dev_port
                remote_lan_devices[did] = {
                    "deviceId": did,
                    "deviceName": dev.get("deviceName") or "远端设备",
                    "platform": dev.get("platform") or "windows",
                    "roomCode": rc,
                    "ip": dev_ip,
                    "httpPort": dev_port,
                    "player": {
                        "title": p.get("title") or "第 1 章",
                        "isPlaying": bool(p.get("isPlaying")),
                        "position": float(p.get("position") or 0),
                        "duration": float(p.get("duration") or 300),
                        "chapterIndex": int(p.get("chapterIndex") or 1),
                    },
                    "lastSeen": int(time.time() * 1000),
                }
        for cmd in data.get("pendingCommands", []):
            tid = cmd.get("targetDeviceId")
            if tid in devices_map:
                target = devices_map[tid]
                apply_action(target["player"], cmd.get("action"), cmd.get("position", 0))
                if target.get("isNativeHost"):
                    cmds_to_run.append((cmd.get("action"), cmd.get("position", 0)))
    for act, pos in cmds_to_run:
        trigger_mac_media(act, pos)


udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    udp_sock.bind(("0.0.0.0", UDP_PORT))
except Exception:
    pass


def sync_with_http_peer(peer_ip, ports_override=None):
    ip = get_primary_lan_ip()
    if not peer_ip or peer_ip in (ip, "127.0.0.1"):
        return
    ports = ports_override or ([peer_http_ports[peer_ip]] if peer_ip in peer_http_ports else PEER_CANDIDATE_PORTS)
    payload = json.dumps(build_local_sync_payload(peer_ip)).encode("utf-8")
    for port in ports:
        try:
            req = Request(
                f"http://{peer_ip}:{port}/api/lan-sync",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(req, timeout=0.7) as resp:
                reply = json.loads(resp.read().decode("utf-8"))
                peer_http_ports[peer_ip] = port
                ingest_remote_sync(reply, peer_ip)
                break
        except Exception:
            pass


def broadcast_state_now():
    _, bcasts = get_broadcast_addresses()
    raw = json.dumps(build_local_sync_payload()).encode("utf-8")
    for b in bcasts:
        try:
            udp_sock.sendto(raw, (b, UDP_PORT))
        except Exception:
            pass
    for peer_ip in list(known_peer_ips):
        try:
            udp_sock.sendto(raw, (peer_ip, UDP_PORT))
        except Exception:
            pass
        threading.Thread(target=sync_with_http_peer, args=(peer_ip,), daemon=True).start()


def scan_subnet_loop():
    while True:
        ip = get_primary_lan_ip()
        parts = ip.split(".")
        if len(parts) == 4 and ip != "127.0.0.1":
            prefix = f"{parts[0]}.{parts[1]}.{parts[2]}."
            self_last = int(parts[3])
            for i in range(1, 255):
                if i == self_last:
                    continue
                target_ip = f"{prefix}{i}"
                threading.Thread(target=sync_with_http_peer, args=(target_ip, PEER_CANDIDATE_PORTS), daemon=True).start()
                if i % 20 == 0:
                    time.sleep(0.05)
        time.sleep(8)


def udp_receive_loop():
    while True:
        try:
            data, addr = udp_sock.recvfrom(16384)
            sender_ip = addr[0]
            obj = json.loads(data.decode("utf-8"))
            t = obj.get("type")
            if t == "lan_sync":
                ingest_remote_sync(obj, sender_ip)
            elif t == "command":
                tid = obj.get("targetDeviceId")
                run_host = False
                with lock:
                    if tid in devices_map:
                        dev = devices_map[tid]
                        apply_action(dev["player"], obj.get("action"), obj.get("position", 0))
                        run_host = bool(dev.get("isNativeHost"))
                if run_host:
                    trigger_mac_media(obj.get("action"), obj.get("position", 0))
        except Exception:
            time.sleep(0.1)


def timer_loop():
    tick = 0
    while True:
        time.sleep(1.0)
        tick += 1
        if tick % 8 == 1:
            poll_mac_wifi_name()
        poll_mac_media_state(force_fresh=False)
        broadcast_state_now()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/state":
            qs = parse_qs(parsed.query)
            did = (qs.get("deviceId") or [HOST_DEVICE_ID])[0]
            plat = (qs.get("platform") or [HOST_PLATFORM])[0]
            dname = (qs.get("deviceName") or [""])[0]
            is_local = self.client_address[0] in ("127.0.0.1", "::1")
            self_dev = ensure_device(did, dname, plat, is_local)

            room_devs = []
            rc = self_dev.get("roomCode") or ""
            if rc:
                seen = set()
                with lock:
                    for d in devices_map.values():
                        if d.get("roomCode") == rc:
                            room_devs.append(d)
                            seen.add(d["deviceId"])
                    for d in remote_lan_devices.values():
                        if d.get("roomCode") == rc and d["deviceId"] not in seen:
                            room_devs.append(d)
                            seen.add(d["deviceId"])

            with lock:
                rooms = list(active_rooms)
            return self._send_json(200, {
                "lanName": local_lan_name,
                "localIp": get_primary_lan_ip(),
                "httpPort": HTTP_PORT,
                "selfDevice": self_dev,
                "roomDevices": room_devs,
                "activeRooms": rooms,
            })

        with open(UI_FILE, "rb") as f:
            html = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        body = json.loads(raw or "{}")
        parsed = urlparse(self.path)

        if parsed.path == "/api/device/update":
            dev = ensure_device(body.get("deviceId") or HOST_DEVICE_ID, body.get("deviceName"), body.get("platform"))
            broadcast_state_now()
            return self._send_json(200, {"ok": True, "selfDevice": dev})

        if parsed.path == "/api/room/create":
            dev = ensure_device(body.get("deviceId") or HOST_DEVICE_ID, body.get("deviceName"), body.get("platform"))
            code = str(random.randint(1000, 9999))
            with lock:
                active_rooms.add(code)
                dev["roomCode"] = code
            broadcast_state_now()
            return self._send_json(200, {"ok": True, "roomCode": code, "selfDevice": dev})

        if parsed.path == "/api/room/join":
            dev = ensure_device(body.get("deviceId") or HOST_DEVICE_ID, body.get("deviceName"), body.get("platform"))
            code = str(body.get("roomCode") or "").strip()
            with lock:
                active_rooms.add(code)
                dev["roomCode"] = code
            broadcast_state_now()
            return self._send_json(200, {"ok": True, "roomCode": code, "selfDevice": dev})

        if parsed.path == "/api/room/leave":
            dev = ensure_device(body.get("deviceId") or HOST_DEVICE_ID)
            with lock:
                dev["roomCode"] = ""
            broadcast_state_now()
            return self._send_json(200, {"ok": True, "selfDevice": dev})

        if parsed.path == "/api/control":
            tid = body.get("targetDeviceId")
            action = body.get("action") or "toggle"
            pos = body.get("position", 0)
            run_host = False
            player_out = None
            with lock:
                if tid and tid not in devices_map and tid not in remote_lan_devices:
                    ensure_device(tid, None, HOST_PLATFORM, True)
                if tid in devices_map:
                    target = devices_map[tid]
                    apply_action(target["player"], action, pos)
                    run_host = bool(target.get("isNativeHost"))
                    player_out = target["player"]
                elif tid in remote_lan_devices:
                    rdev = remote_lan_devices[tid]
                    apply_action(rdev["player"], action, pos)
                    pending_peer_commands.append({
                        "ip": rdev["ip"],
                        "targetDeviceId": tid,
                        "action": action,
                        "position": pos,
                    })
                    player_out = rdev["player"]
            if run_host:
                trigger_mac_media(action, pos)
                with lock:
                    if tid in devices_map:
                        player_out = devices_map[tid]["player"]
            broadcast_state_now()
            return self._send_json(200, {"ok": True, "player": player_out})

        if parsed.path == "/api/lan-sync":
            sender_ip = body.get("ip") or self.client_address[0]
            ingest_remote_sync(body, sender_ip)
            return self._send_json(200, build_local_sync_payload(sender_ip))

        return self._send_json(404, {"ok": False})


if __name__ == "__main__":
    poll_mac_wifi_name()
    poll_mac_media_state(force_fresh=False)
    threading.Thread(target=udp_receive_loop, daemon=True).start()
    threading.Thread(target=timer_loop, daemon=True).start()
    threading.Thread(target=scan_subnet_loop, daemon=True).start()

    try:
        httpd = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
        if "--open" in sys.argv:
            subprocess.Popen(["/usr/bin/open", f"http://127.0.0.1:{HTTP_PORT}"])
        httpd.serve_forever()
    except OSError:
        if "--open" in sys.argv:
            subprocess.Popen(["/usr/bin/open", f"http://127.0.0.1:{HTTP_PORT}"])
