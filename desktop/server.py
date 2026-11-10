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
devices_map = {}
remote_lan_devices = {}
active_rooms = set()
known_peer_ips = set()
pending_peer_commands = []
lock = threading.Lock()


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
    if HOST_PLATFORM == "darwin" or HOST_PLATFORM == "macos":
        try:
            out = subprocess.check_output(
                ["/usr/sbin/networksetup", "-getairportnetwork", "en0"],
                stderr=subprocess.DEVNULL,
                timeout=2,
            ).decode("utf-8", errors="ignore").strip()
            if ":" in out:
                local_lan_name = out.split(":", 1)[1].strip()
                return
        except Exception:
            pass
        local_lan_name = "macOS 局域网"


def trigger_mac_media(action, position=0):
    if HOST_PLATFORM != "macos":
        return
    pos = max(0, int(round(float(position or 0))))
    jxa = f"""
    ObjC.import('Foundation');
    var b = $.NSBundle.bundleWithPath($('/System/Library/PrivateFrameworks/MediaRemote.framework'));
    if (b && !b.isNil()) b.load;
    ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
    ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
    var act = '{action}';
    if (act === 'play') $.MRMediaRemoteSendCommand(0, null);
    else if (act === 'pause') $.MRMediaRemoteSendCommand(1, null);
    else if (act === 'toggle') $.MRMediaRemoteSendCommand(2, null);
    else if (act === 'next') $.MRMediaRemoteSendCommand(4, null);
    else if (act === 'prev') $.MRMediaRemoteSendCommand(5, null);
    else if (act === 'seek') {{ $.MRMediaRemoteSetElapsedTime({pos}); $.MRMediaRemoteSendCommand(0, null); }}
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
    """
    try:
        subprocess.Popen(
            ["/usr/bin/env", "-u", "__CFBundleIdentifier", "/usr/bin/osascript", "-l", "JavaScript", "-e", jxa],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
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
                "player": {
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
        player["title"] = f"第 {idx} 章"
        player["position"] = 0
        player["isPlaying"] = True
    elif action == "prev":
        idx = max(1, int(player.get("chapterIndex", 1)) - 1)
        player["chapterIndex"] = idx
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
                remote_lan_devices[did] = {
                    "deviceId": did,
                    "deviceName": dev.get("deviceName") or "远端设备",
                    "platform": dev.get("platform") or "windows",
                    "roomCode": rc,
                    "ip": dev.get("ip") or sender_ip,
                    "httpPort": dev.get("httpPort") or HTTP_PORT,
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
                    trigger_mac_media(cmd.get("action"), cmd.get("position", 0))


udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    udp_sock.bind(("0.0.0.0", UDP_PORT))
except Exception:
    pass


def sync_with_http_peer(peer_ip):
    ip = get_primary_lan_ip()
    if not peer_ip or peer_ip in (ip, "127.0.0.1"):
        return
    try:
        payload = json.dumps(build_local_sync_payload(peer_ip)).encode("utf-8")
        req = Request(
            f"http://{peer_ip}:{HTTP_PORT}/api/lan-sync",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(req, timeout=0.7) as resp:
            reply = json.loads(resp.read().decode("utf-8"))
            ingest_remote_sync(reply, peer_ip)
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
                threading.Thread(target=sync_with_http_peer, args=(target_ip,), daemon=True).start()
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
                with lock:
                    if tid in devices_map:
                        dev = devices_map[tid]
                        apply_action(dev["player"], obj.get("action"), obj.get("position", 0))
                        if dev.get("isNativeHost"):
                            trigger_mac_media(obj.get("action"), obj.get("position", 0))
        except Exception:
            time.sleep(0.1)


def timer_loop():
    while True:
        time.sleep(1.0)
        poll_mac_wifi_name()
        with lock:
            for d in devices_map.values():
                p = d["player"]
                if p.get("isPlaying"):
                    p["position"] = min(p.get("duration", 300), p.get("position", 0) + 1)
                    if p["position"] >= p.get("duration", 300):
                        p["position"] = 0
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
            with lock:
                if tid in devices_map:
                    target = devices_map[tid]
                    apply_action(target["player"], action, pos)
                    if target.get("isNativeHost"):
                        trigger_mac_media(action, pos)
                elif tid in remote_lan_devices:
                    rdev = remote_lan_devices[tid]
                    apply_action(rdev["player"], action, pos)
                    pending_peer_commands.append({
                        "ip": rdev["ip"],
                        "targetDeviceId": tid,
                        "action": action,
                        "position": pos,
                    })
            broadcast_state_now()
            return self._send_json(200, {"ok": True})

        if parsed.path == "/api/lan-sync":
            sender_ip = body.get("ip") or self.client_address[0]
            ingest_remote_sync(body, sender_ip)
            return self._send_json(200, build_local_sync_payload(sender_ip))

        return self._send_json(404, {"ok": False})


if __name__ == "__main__":
    poll_mac_wifi_name()
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
