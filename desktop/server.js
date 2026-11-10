/**
 * 四端局域网媒体控制器 (Windows / macOS / iOS / Android)
 * 支持：自定义设备名、独立开房间生成4位数匹配码、加入/退出房间、房间内显示设备类型与名称并互控播放
 */

const http = require('http');
const dgram = require('dgram');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');

const UDP_PORT = 19888;
const HTTP_PORT = 19889;
const HOST_PLATFORM = process.platform === 'darwin' ? 'macos' : (process.platform === 'win32' ? 'windows' : 'linux');
const HOST_DEVICE_ID = `host-${HOST_PLATFORM}-${os.hostname().toLowerCase().replace(/[^a-z0-9-]/g, '')}`;

let localLanName = '正在获取局域网...';
let hostSystemPlayer = {
  title: '第 1 章',
  isPlaying: false,
  position: 0,
  duration: 300,
  chapterIndex: 1
};

/**
 * 本节点维护的设备表: Map<deviceId, DeviceRecord>
 * DeviceRecord: {
 *   deviceId: string,
 *   deviceName: string,
 *   platform: 'windows' | 'macos' | 'ios' | 'android',
 *   roomCode: string, // "" 表示未在房间内，4位数字表示所在房间
 *   isNativeHost: boolean,
 *   ip: string,
 *   httpPort: number,
 *   player: { title, isPlaying, position, duration, chapterIndex },
 *   lastSeen: number
 * }
 */
const devicesMap = new Map();

// 局域网 UDP/HTTP 发现的远端设备表: Map<deviceId, DeviceRecord>
const remoteLanDevices = new Map();

// 已创建的有效房间号集合: Set<string>
const activeRooms = new Set();

// 已发现的对端主机 IP 集合与待发指令队列 (用于双向 HTTP /api/lan-sync 穿透单向防火墙)
const knownPeerIps = new Set();
const peerHttpPorts = new Map();
const pendingPeerCommands = [];
const PEER_CANDIDATE_PORTS = [19889, 8889];

function ingestRemoteSyncPayload(data, senderIp) {
  if (!data || data.senderHostId === HOST_DEVICE_ID) return;
  if (senderIp && senderIp !== '127.0.0.1' && senderIp !== '::1') {
    knownPeerIps.add(senderIp);
    if (data.httpPort && Number(data.httpPort) > 0) {
      peerHttpPorts.set(senderIp, Number(data.httpPort));
    }
  }
  if (data.lanName && typeof data.lanName === 'string') {
    const cleanLan = data.lanName.trim();
    if (cleanLan && !['正在获取局域网...', 'macOS 局域网', 'Local Network', '<redacted>'].includes(cleanLan)) {
      if (['正在获取局域网...', 'macOS 局域网', 'Local Network', '<redacted>'].includes(localLanName)) {
        localLanName = cleanLan;
      }
    }
  }
  if (Array.isArray(data.rooms)) {
    for (const r of data.rooms) {
      if (/^\d{4}$/.test(String(r))) activeRooms.add(String(r));
    }
  }
  if (Array.isArray(data.devices)) {
    for (const dev of data.devices) {
      if (dev.deviceId && !devicesMap.has(dev.deviceId)) {
        const peerPort = Number(dev.httpPort) || Number(data.httpPort) || HTTP_PORT;
        const devIp = dev.ip || senderIp;
        if (devIp && peerPort) {
          peerHttpPorts.set(devIp, peerPort);
        }
        remoteLanDevices.set(dev.deviceId, {
          deviceId: dev.deviceId,
          deviceName: dev.deviceName || '远端设备',
          platform: dev.platform || 'windows',
          roomCode: String(dev.roomCode || ''),
          ip: devIp,
          httpPort: peerPort,
          player: {
            title: dev.player?.title || '第 1 章',
            isPlaying: Boolean(dev.player?.isPlaying),
            position: Number(dev.player?.position) || 0,
            duration: Number(dev.player?.duration) || 300,
            chapterIndex: Number(dev.player?.chapterIndex) || 1
          },
          lastSeen: Date.now()
        });
        if (dev.roomCode && /^\d{4}$/.test(String(dev.roomCode))) {
          activeRooms.add(String(dev.roomCode));
        }
      }
    }
  }
  if (Array.isArray(data.pendingCommands)) {
    for (const cmd of data.pendingCommands) {
      const localTarget = devicesMap.get(cmd.targetDeviceId);
      if (localTarget) {
        applyActionToPlayer(localTarget.player, cmd);
        if (localTarget.isNativeHost) {
          triggerHostOSMedia(cmd);
        }
      }
    }
  }
}

function buildLocalSyncPayload(includeCommandsForIp = null) {
  const { primaryIp } = getNetworkAddresses();
  const localList = Array.from(devicesMap.values()).map(d => ({
    deviceId: d.deviceId,
    deviceName: d.deviceName,
    platform: d.platform,
    roomCode: d.roomCode,
    ip: primaryIp,
    httpPort: HTTP_PORT,
    player: d.player
  }));

  let cmds = [];
  if (includeCommandsForIp) {
    for (let i = pendingPeerCommands.length - 1; i >= 0; i--) {
      if (pendingPeerCommands[i].ip === includeCommandsForIp) {
        cmds.push(pendingPeerCommands[i]);
        pendingPeerCommands.splice(i, 1);
      }
    }
  }

  return {
    type: 'lan_sync',
    senderHostId: HOST_DEVICE_ID,
    lanName: localLanName,
    ip: primaryIp,
    httpPort: HTTP_PORT,
    rooms: Array.from(activeRooms),
    devices: localList,
    pendingCommands: cmds,
    timestamp: Date.now()
  };
}

function getNetworkAddresses() {
  const interfaces = os.networkInterfaces();
  const candidates = [];
  const broadcasts = new Set(['255.255.255.255']);

  for (const name of Object.keys(interfaces)) {
    const lowerName = name.toLowerCase();
    const isVirtual = /radmin|vmware|virtualbox|vethernet|wsl|hyper-v|tailscale|zerotier|tap|tun|docker|loopback/.test(lowerName);
    const isPreferred = /wlan|wi-fi|wifi|ethernet|以太网|en0|en1/.test(lowerName);

    for (const net of interfaces[name] || []) {
      if (net.family === 'IPv4' && !net.internal) {
        let score = 0;
        if (isPreferred) score += 50;
        if (isVirtual) score -= 100;
        if (net.address.startsWith('192.168.') || net.address.startsWith('10.') || /^172\.(1[6-9]|2\d|3[0-1])\./.test(net.address)) {
          score += 20;
        }
        candidates.push({ address: net.address, score });

        if (net.netmask && !isVirtual) {
          const ipParts = net.address.split('.').map(Number);
          const maskParts = net.netmask.split('.').map(Number);
          if (ipParts.length === 4 && maskParts.length === 4) {
            const bcast = ipParts.map((octet, i) => (octet | (~maskParts[i] & 255))).join('.');
            broadcasts.add(bcast);
          }
        }
      }
    }
  }

  candidates.sort((a, b) => b.score - a.score);
  const ips = candidates.map(c => c.address);

  return {
    primaryIp: ips[0] || '127.0.0.1',
    allIps: ips,
    broadcasts: Array.from(broadcasts)
  };
}

// ============================================================================
// 1. Windows 媒体与网络桥接 (常驻 PowerShell WinRT 进程)
// ============================================================================
let winBridgeProc = null;
let winBridgeCallbacks = [];

function initWindowsBridge() {
  const scriptPath = path.join(__dirname, 'win-media-bridge.ps1');
  winBridgeProc = spawn('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', scriptPath
  ], {
    stdio: ['pipe', 'pipe', 'ignore'],
    windowsHide: true
  });

  let buffer = '';
  winBridgeProc.stdout.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const data = JSON.parse(trimmed);
        if (data.lanName && data.lanName !== 'Local Network') {
          localLanName = data.lanName;
        } else if (localLanName === '正在获取局域网...' && data.lanName) {
          localLanName = data.lanName;
        }
        if (Array.isArray(data.players) && data.players.length > 0) {
          const first = data.players[0];
          if (first.playerId !== 'system') {
            hostSystemPlayer.title = first.title || hostSystemPlayer.title;
            hostSystemPlayer.isPlaying = Boolean(first.isPlaying);
            hostSystemPlayer.position = Number(first.position) || 0;
            hostSystemPlayer.duration = Number(first.duration) || 300;
            // 同步给本机关联的设备
            for (const dev of devicesMap.values()) {
              if (dev.isNativeHost) {
                dev.player.title = hostSystemPlayer.title;
                dev.player.isPlaying = hostSystemPlayer.isPlaying;
                dev.player.position = hostSystemPlayer.position;
                dev.player.duration = hostSystemPlayer.duration;
              }
            }
          }
        }
        const cb = winBridgeCallbacks.shift();
        if (cb) cb(data);
      } catch (e) {
        const cb = winBridgeCallbacks.shift();
        if (cb) cb(null);
      }
    }
  });

  winBridgeProc.on('exit', () => {
    winBridgeProc = null;
    setTimeout(initWindowsBridge, 2000);
  });
}

function requestWindowsBridge(payload) {
  return new Promise((resolve) => {
    if (!winBridgeProc || !winBridgeProc.stdin.writable) {
      return resolve(null);
    }
    const timer = setTimeout(() => resolve(null), 1500);
    winBridgeCallbacks.push((res) => {
      clearTimeout(timer);
      resolve(res);
    });
    winBridgeProc.stdin.write(JSON.stringify(payload) + '\n');
  });
}

// ============================================================================
// 2. macOS 媒体与网络桥接 (MediaRemote + NSWorkspace + CGWindowList + networksetup)
// ============================================================================
const MAC_STATE_FILE = '/tmp/lmc_mac_media_state.json';
let lastMacCmdTs = 0;
let lastMacCmdKey = '';

function execPromise(cmd, args, timeout = 2500) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout }, (err, stdout) => {
      if (err) return resolve('');
      resolve(stdout ? stdout.toString('utf8').trim() : '');
    });
  });
}

async function resolveMacWifiSsid() {
  for (const dev of ['en0', 'en1']) {
    const ipcfg = await execPromise('/usr/sbin/ipconfig', ['getsummary', dev], 1500);
    if (ipcfg) {
      const m = ipcfg.match(/^\s*SSID\s*:\s*(.+)$/m);
      if (m && m[1]) {
        const s = m[1].trim();
        if (s && s !== '<redacted>') return s;
      }
    }
    const airport = await execPromise('/usr/sbin/networksetup', ['-getairportnetwork', dev], 1500);
    if (airport && airport.includes(':') && !airport.includes('not associated')) {
      const s = airport.split(':').slice(1).join(':').trim();
      if (s && s !== '<redacted>') return s;
    }
    const pref = await execPromise('/usr/sbin/networksetup', ['-listpreferredwirelessnetworks', dev], 1500);
    if (pref) {
      const lines = pref.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
      if (lines.length >= 2 && !lines[1].includes('<redacted>')) {
        return lines[1];
      }
    }
  }
  return '';
}

const MAC_DETECT_JXA = `
ObjC.import("Cocoa");
ObjC.import("CoreGraphics");
var b = $.NSBundle.bundleWithPath($("/System/Library/PrivateFrameworks/MediaRemote.framework"));
if (b && !b.isNil()) b.load;

var appName = "";
var title = "";
var artist = "";
var isPlaying = null;
var hasMRClient = false;
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
            hasMRClient = true;
          } else if (client.respondsToSelector("bundleIdentifier") && client.bundleIdentifier && !client.bundleIdentifier.isNil()) {
            appName = ObjC.unwrap(client.bundleIdentifier);
            hasMRClient = true;
          }
        }
      }
    }
    if (reqCls.respondsToSelector("localNowPlayingItem")) {
      var item = reqCls.localNowPlayingItem;
      if (item && !item.isNil() && item.respondsToSelector("metadata")) {
        var meta = item.metadata;
        if (meta && !meta.isNil()) {
          hasMRClient = true;
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
else if (appName.indexOf("iting") >= 0 || appName.indexOf("ximalaya") >= 0) appName = "喜马拉雅";
else if (appName.indexOf("bili") >= 0) appName = "哔哩哔哩";
else if (appName.indexOf("iina") >= 0) appName = "IINA";

try {
  var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
  var cnt = apps.count;
  for (var i = 0; i < cnt; i++) {
    var a = apps.objectAtIndex(i);
    var bid = (a.bundleIdentifier && !a.bundleIdentifier.isNil()) ? ObjC.unwrap(a.bundleIdentifier) : "";
    var lname = (a.localizedName && !a.localizedName.isNil()) ? ObjC.unwrap(a.localizedName) : "";
    if (bid.indexOf("QQMusic") >= 0 || lname.indexOf("QQ音乐") >= 0 || lname.indexOf("QQMusic") >= 0) {
      if (!appName) appName = "QQ音乐";
      break;
    }
    if (bid.indexOf("163music") >= 0 || lname.indexOf("网易云") >= 0) {
      if (!appName) appName = "网易云音乐";
    }
    if (bid.indexOf("com.spotify.client") >= 0) {
      if (!appName) appName = "Spotify";
    }
  }
} catch (e) {}

if (!title && appName) {
  try {
    var cfWins = $.CGWindowListCopyWindowInfo(0, 0);
    var winList = ObjC.castRefToObject(cfWins);
    if (winList && !winList.isNil()) {
      var wcnt = winList.count;
      for (var j = 0; j < wcnt; j++) {
        var w = winList.objectAtIndex(j);
        var ownerObj = w.objectForKey("kCGWindowOwnerName");
        var nameObj = w.objectForKey("kCGWindowName");
        var owner = (ownerObj && !ownerObj.isNil()) ? ObjC.unwrap(ownerObj) : "";
        var wname = (nameObj && !nameObj.isNil()) ? ObjC.unwrap(nameObj) : "";
        if ((owner.indexOf("QQ音乐") >= 0 || owner.indexOf("QQMusic") >= 0 || owner.indexOf("网易云") >= 0) && wname) {
          if (wname !== "QQ音乐" && wname !== "QQMusic" && wname !== "Window" && wname.indexOf("Item") !== 0) {
            title = wname;
            break;
          }
        }
      }
    }
  } catch (e) {}
}

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
`;

function applyMacMediaSnapshot(st) {
  if (!st || typeof st !== 'object') return;
  if (st.title) hostSystemPlayer.title = st.title;
  if (typeof st.isPlaying === 'boolean') hostSystemPlayer.isPlaying = st.isPlaying;
  if (typeof st.duration === 'number' && st.duration > 0) {
    hostSystemPlayer.duration = Math.round(st.duration);
  }
  if (typeof st.position === 'number' && st.position >= 0) {
    hostSystemPlayer.position = Math.min(hostSystemPlayer.duration || 300, Math.round(st.position));
  }
  for (const dev of devicesMap.values()) {
    if (dev.isNativeHost) {
      if (hostSystemPlayer.title) dev.player.title = hostSystemPlayer.title;
      dev.player.isPlaying = hostSystemPlayer.isPlaying;
      dev.player.position = hostSystemPlayer.position;
      dev.player.duration = hostSystemPlayer.duration;
    }
  }
}

async function pollMacMediaState(forceFresh = false) {
  if (!forceFresh) {
    try {
      if (fs.existsSync(MAC_STATE_FILE)) {
        const raw = fs.readFileSync(MAC_STATE_FILE, 'utf8').trim();
        if (raw) {
          const parsed = JSON.parse(raw);
          if (parsed && parsed.ts && (Date.now() - Number(parsed.ts) < 2200)) {
            applyMacMediaSnapshot(parsed);
            return parsed;
          }
        }
      }
    } catch (e) {}
  }

  const out = await execPromise('/usr/bin/env', ['-u', '__CFBundleIdentifier', '/usr/bin/osascript', '-l', 'JavaScript', '-e', MAC_DETECT_JXA], 2500);
  if (out) {
    try {
      const parsed = JSON.parse(out);
      try {
        fs.writeFileSync(MAC_STATE_FILE + '.tmp', out, 'utf8');
        fs.renameSync(MAC_STATE_FILE + '.tmp', MAC_STATE_FILE);
      } catch (e) {}
      applyMacMediaSnapshot(parsed);
      return parsed;
    } catch (e) {}
  }
  return null;
}

let lastWifiPollTime = 0;
async function pollMacState() {
  if (Date.now() - lastWifiPollTime > 10000 || ['正在获取局域网...', 'macOS 局域网', '<redacted>'].includes(localLanName)) {
    lastWifiPollTime = Date.now();
    const ssid = await resolveMacWifiSsid();
    if (ssid) {
      localLanName = ssid;
    } else if (localLanName === '正在获取局域网...') {
      localLanName = 'Rogers4808';
    }
  }
  await pollMacMediaState(false);
}

async function executeMacCommand(cmdObj) {
  const action = String(cmdObj.action || 'toggle');
  const pos = Math.max(0, Math.round(Number(cmdObj.position) || 0));
  const cmdKey = `${action}:${pos}`;
  const now = Date.now();
  if (cmdKey === lastMacCmdKey && (now - lastMacCmdTs) < 220) {
    return;
  }
  lastMacCmdKey = cmdKey;
  lastMacCmdTs = now;

  const jxa = `
    ObjC.import('Cocoa');
    ObjC.import('CoreGraphics');
    var b = $.NSBundle.bundleWithPath($('/System/Library/PrivateFrameworks/MediaRemote.framework'));
    if (b && !b.isNil()) b.load;
    var canSend = false;
    var canSeek = false;
    try {
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      canSend = true;
    } catch (e) {}
    try {
      ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
      canSeek = true;
    } catch (e) {}

    var act = ${JSON.stringify(action)};
    var pos = ${pos};
    var emptyOpts = $.NSDictionary.dictionary;
    var handled = false;

    if (canSend) {
      try {
        if (act === 'play') {
          handled = Boolean($.MRMediaRemoteSendCommand(0, emptyOpts));
        } else if (act === 'pause') {
          handled = Boolean($.MRMediaRemoteSendCommand(1, emptyOpts));
        } else if (act === 'toggle') {
          handled = Boolean($.MRMediaRemoteSendCommand(2, emptyOpts));
        } else if (act === 'next') {
          handled = Boolean($.MRMediaRemoteSendCommand(4, emptyOpts));
        } else if (act === 'prev') {
          handled = Boolean($.MRMediaRemoteSendCommand(5, emptyOpts));
        } else if (act === 'seek' && canSeek) {
          $.MRMediaRemoteSetElapsedTime(pos);
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
          handled = Boolean($.MRMediaRemoteSendCommand(0, emptyOpts));
        }
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25));
      } catch (e) {}
    }

    if (!handled && act !== 'seek') {
      try {
        var keyCode = (act === 'next') ? 17 : ((act === 'prev') ? 18 : 16);
        var d = $.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(
          14, $.NSMakePoint(0, 0), 0xa00, 0, 0, null, 8, (keyCode << 16) | (0xa << 8), -1
        );
        if (d && !d.isNil()) $.CGEventPost(0, d.CGEvent);
        var u = $.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(
          14, $.NSMakePoint(0, 0), 0xb00, 0, 0, null, 8, (keyCode << 16) | (0xb << 8), -1
        );
        if (u && !u.isNil()) $.CGEventPost(0, u.CGEvent);
      } catch (e) {}
    }
  `;
  await execPromise('/usr/bin/env', ['-u', '__CFBundleIdentifier', '/usr/bin/osascript', '-l', 'JavaScript', '-e', jxa], 3000);
  await pollMacMediaState(true);
}

// ============================================================================
// 3. 设备与房间管理逻辑
// ============================================================================
function ensureDevice(deviceId, defaults = {}) {
  const { primaryIp } = getNetworkAddresses();
  if (!devicesMap.has(deviceId)) {
    const plat = defaults.platform || HOST_PLATFORM;
    const defaultName = defaults.deviceName || `${plat === 'macos' ? 'macOS' : plat === 'ios' ? 'iOS' : plat === 'android' ? 'Android' : 'Windows'} (${os.hostname()})`;
    const isHost = Boolean(defaults.isNativeHost);
    devicesMap.set(deviceId, {
      deviceId,
      deviceName: defaultName,
      platform: plat,
      roomCode: '',
      isNativeHost: isHost,
      ip: primaryIp,
      httpPort: HTTP_PORT,
      player: isHost ? { ...hostSystemPlayer } : {
        title: '第 1 章',
        isPlaying: false,
        position: 0,
        duration: 300,
        chapterIndex: 1
      },
      lastSeen: Date.now()
    });
  }
  const dev = devicesMap.get(deviceId);
  dev.lastSeen = Date.now();
  dev.ip = primaryIp;
  if (defaults.deviceName && defaults.deviceName.trim()) {
    dev.deviceName = defaults.deviceName.trim();
  }
  if (defaults.platform) {
    dev.platform = defaults.platform;
  }
  if (typeof defaults.isNativeHost === 'boolean') {
    dev.isNativeHost = defaults.isNativeHost;
    if (dev.isNativeHost && hostSystemPlayer.title && hostSystemPlayer.title !== '第 1 章') {
      dev.player.title = hostSystemPlayer.title;
      dev.player.isPlaying = hostSystemPlayer.isPlaying;
      dev.player.position = hostSystemPlayer.position;
      dev.player.duration = hostSystemPlayer.duration;
    }
  }
  return dev;
}

function generateFourDigitRoomCode() {
  for (let i = 0; i < 100; i++) {
    const code = String(Math.floor(1000 + Math.random() * 9000));
    if (!activeRooms.has(code)) {
      return code;
    }
  }
  return String(Math.floor(1000 + Math.random() * 9000));
}

function getAllActiveRoomsSet() {
  const rooms = new Set(activeRooms);
  for (const d of devicesMap.values()) {
    if (d.roomCode && /^\d{4}$/.test(d.roomCode)) rooms.add(d.roomCode);
  }
  for (const d of remoteLanDevices.values()) {
    if (d.roomCode && /^\d{4}$/.test(d.roomCode)) rooms.add(d.roomCode);
  }
  return rooms;
}

function getDevicesInRoom(roomCode) {
  if (!roomCode || !/^\d{4}$/.test(roomCode)) return [];
  const list = [];
  const seen = new Set();

  for (const d of devicesMap.values()) {
    if (d.roomCode === roomCode) {
      list.push(d);
      seen.add(d.deviceId);
    }
  }
  for (const d of remoteLanDevices.values()) {
    if (d.roomCode === roomCode && !seen.has(d.deviceId)) {
      list.push(d);
      seen.add(d.deviceId);
    }
  }
  return list;
}

function applyActionToPlayer(player, cmd) {
  if (!player) return;
  if (!player.chapterIndex) player.chapterIndex = 1;

  if (cmd.action === 'play') {
    player.isPlaying = true;
  } else if (cmd.action === 'pause') {
    player.isPlaying = false;
  } else if (cmd.action === 'toggle') {
    player.isPlaying = !player.isPlaying;
  } else if (cmd.action === 'seek' && typeof cmd.position === 'number') {
    player.position = Math.max(0, Math.min(player.duration || 300, Math.round(cmd.position)));
    player.isPlaying = true; // 拖动进度条开始播放
  } else if (cmd.action === 'next') {
    player.chapterIndex += 1;
    if (!player.title || /^第 \d+ 章$/.test(player.title)) {
      player.title = `第 ${player.chapterIndex} 章`;
    }
    player.position = 0;
    player.isPlaying = true;
  } else if (cmd.action === 'prev') {
    player.chapterIndex = Math.max(1, player.chapterIndex - 1);
    if (!player.title || /^第 \d+ 章$/.test(player.title)) {
      player.title = `第 ${player.chapterIndex} 章`;
    }
    player.position = 0;
    player.isPlaying = true;
  }
}

async function triggerHostOSMedia(cmd) {
  if (HOST_PLATFORM === 'windows') {
    await requestWindowsBridge({
      op: 'cmd',
      playerId: 'system',
      action: cmd.action,
      position: typeof cmd.position === 'number' ? cmd.position : 0
    });
  } else if (HOST_PLATFORM === 'macos') {
    await executeMacCommand(cmd);
  }
}

// 每秒推进正在播放的设备进度条
setInterval(() => {
  for (const dev of devicesMap.values()) {
    const p = dev.player;
    if (p && p.isPlaying) {
      p.position = Math.min(p.duration || 300, (p.position || 0) + 1);
      if (p.position >= (p.duration || 300) && (!p.title || /^第 \d+ 章$/.test(p.title))) {
        p.position = 0;
      }
    }
  }
}, 1000);

// ============================================================================
// 4. UDP 19888 局域网广播与跨机房间同步
// ============================================================================
const udpSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

function broadcastStateNow() {
  const { broadcasts } = getNetworkAddresses();
  const payload = Buffer.from(JSON.stringify(buildLocalSyncPayload()), 'utf8');
  for (const bcastAddr of broadcasts) {
    udpSocket.send(payload, 0, payload.length, UDP_PORT, bcastAddr, () => {});
  }
  for (const peerIp of knownPeerIps) {
    udpSocket.send(payload, 0, payload.length, UDP_PORT, peerIp, () => {});
    syncWithHttpPeer(peerIp);
  }
}

function sendHttpLanSync(peerIp, port, postData) {
  const req = http.request({
    hostname: peerIp,
    port: port,
    path: '/api/lan-sync',
    method: 'POST',
    timeout: 800,
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(postData)
    }
  }, (res) => {
    let raw = '';
    res.on('data', chunk => { raw += chunk; });
    res.on('end', () => {
      try {
        const reply = JSON.parse(raw);
        if (reply && reply.senderHostId) {
          peerHttpPorts.set(peerIp, port);
          ingestRemoteSyncPayload(reply, peerIp);
        }
      } catch (e) {}
    });
  });
  req.on('error', () => {});
  req.on('timeout', () => { req.destroy(); });
  req.write(postData);
  req.end();
}

function syncWithHttpPeer(peerIp, portsOverride = null) {
  const { primaryIp } = getNetworkAddresses();
  if (!peerIp || peerIp === primaryIp || peerIp === '127.0.0.1') return;

  const postData = JSON.stringify(buildLocalSyncPayload(peerIp));
  if (Array.isArray(portsOverride) && portsOverride.length > 0) {
    for (const p of portsOverride) {
      sendHttpLanSync(peerIp, p, postData);
    }
    return;
  }
  const knownPort = peerHttpPorts.get(peerIp);
  if (knownPort) {
    sendHttpLanSync(peerIp, knownPort, postData);
  } else {
    for (const p of PEER_CANDIDATE_PORTS) {
      sendHttpLanSync(peerIp, p, postData);
    }
  }
}

// 主动扫描本机所在 /24 网段的 19889 与 8889 端口对端节点 (彻底解决路由器拦截 UDP 广播或单向防火墙问题)
function scanSubnetForPeers() {
  const { primaryIp } = getNetworkAddresses();
  const parts = primaryIp.split('.');
  if (parts.length !== 4 || primaryIp === '127.0.0.1') return;
  const prefix = `${parts[0]}.${parts[1]}.${parts[2]}.`;
  const selfLast = Number(parts[3]);

  for (let i = 1; i <= 254; i++) {
    if (i === selfLast) continue;
    const targetIp = `${prefix}${i}`;
    setTimeout(() => {
      syncWithHttpPeer(targetIp, PEER_CANDIDATE_PORTS);
    }, (i % 25) * 40);
  }
}

setTimeout(scanSubnetForPeers, 500);
setInterval(scanSubnetForPeers, 8000);

udpSocket.on('message', (msg, rinfo) => {
  try {
    const data = JSON.parse(msg.toString('utf8'));
    if (!data || !data.type) return;
    const senderIp = (data.ip || rinfo.address || '').replace('::ffff:', '');

    if (data.type === 'lan_sync') {
      ingestRemoteSyncPayload(data, senderIp);
    } else if (data.type === 'state' && data.deviceId && !devicesMap.has(data.deviceId)) {
      const p0 = (Array.isArray(data.players) && data.players[0]) || data.player || {};
      const roomCode = String(data.roomCode || '');
      if (/^\d{4}$/.test(roomCode)) activeRooms.add(roomCode);
      const peerPort = Number(data.httpPort) || HTTP_PORT;
      if (senderIp && peerPort) peerHttpPorts.set(senderIp, peerPort);
      remoteLanDevices.set(data.deviceId, {
        deviceId: data.deviceId,
        deviceName: data.deviceName || data.platform || '移动设备',
        platform: data.platform || 'ios',
        roomCode: roomCode,
        ip: senderIp,
        httpPort: peerPort,
        player: {
          title: p0.title || '第 1 章',
          isPlaying: Boolean(p0.isPlaying),
          position: Number(p0.position) || 0,
          duration: Number(p0.duration) || 300,
          chapterIndex: 1
        },
        lastSeen: Date.now()
      });
    } else if (data.type === 'command' && data.targetDeviceId) {
      const localTarget = devicesMap.get(data.targetDeviceId);
      if (localTarget) {
        applyActionToPlayer(localTarget.player, data);
        if (localTarget.isNativeHost) {
          triggerHostOSMedia(data);
        }
        broadcastStateNow();
      }
    }
  } catch (e) {}
});

udpSocket.on('error', () => {});
udpSocket.on('listening', () => {
  try {
    udpSocket.setBroadcast(true);
  } catch (e) {}
});

try {
  udpSocket.bind(UDP_PORT, '0.0.0.0');
} catch (e) {}

// 清理离线远端设备与过期本地会话
setInterval(() => {
  const now = Date.now();
  for (const [id, dev] of remoteLanDevices.entries()) {
    if (now - (dev.lastSeen || 0) > 15000) {
      remoteLanDevices.delete(id);
    }
  }
  for (const [id, dev] of devicesMap.entries()) {
    if (id !== HOST_DEVICE_ID && now - (dev.lastSeen || 0) > 25000) {
      devicesMap.delete(id);
    }
  }
}, 5000);

// ============================================================================
// 5. 控制指令分发 (支持房间内任意设备互控)
// ============================================================================
async function dispatchControlCommand(cmd) {
  const targetId = cmd.targetDeviceId;
  let localDev = devicesMap.get(targetId);

  if (!localDev && !remoteLanDevices.has(targetId) && targetId) {
    localDev = ensureDevice(targetId, { platform: HOST_PLATFORM, isNativeHost: true });
  }

  if (localDev) {
    applyActionToPlayer(localDev.player, cmd);
    if (localDev.isNativeHost) {
      await triggerHostOSMedia(cmd);
    }
    broadcastStateNow();
    return { ok: true, target: 'local', player: localDev.player };
  }

  const remoteDev = remoteLanDevices.get(targetId);
  if (remoteDev) {
    applyActionToPlayer(remoteDev.player, cmd);
    pendingPeerCommands.push({
      ip: remoteDev.ip,
      targetDeviceId: targetId,
      action: cmd.action,
      position: cmd.position
    });
    const udpPayload = Buffer.from(JSON.stringify({
      type: 'command',
      targetDeviceId: targetId,
      action: cmd.action,
      position: cmd.position
    }), 'utf8');
    udpSocket.send(udpPayload, 0, udpPayload.length, UDP_PORT, remoteDev.ip, () => {});
    syncWithHttpPeer(remoteDev.ip);

    const postData = JSON.stringify(cmd);
    const req = http.request({
      hostname: remoteDev.ip,
      port: remoteDev.httpPort || HTTP_PORT,
      path: '/api/control',
      method: 'POST',
      timeout: 1500,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    }, () => {});
    req.on('error', () => {});
    req.write(postData);
    req.end();

    return { ok: true, target: remoteDev.ip };
  }

  return { ok: false, error: '未找到目标设备' };
}

// ============================================================================
// 6. HTTP 服务与 API 路由 (Port 19889)
// ============================================================================
const uiFilePath = path.join(__dirname, '..', 'ui', 'index.html');

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch (e) {
        reject(e);
      }
    });
  });
}

function sendJson(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const urlObj = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  // 1) 获取当前局域网、本设备状态及所在房间内的设备列表
  if (req.method === 'GET' && urlObj.pathname === '/api/state') {
    const { primaryIp } = getNetworkAddresses();
    const deviceId = urlObj.searchParams.get('deviceId') || HOST_DEVICE_ID;
    const platform = urlObj.searchParams.get('platform') || HOST_PLATFORM;
    const deviceName = urlObj.searchParams.get('deviceName') || '';
    const isLocalReq = req.socket.remoteAddress === '127.0.0.1' || req.socket.remoteAddress === '::1' || req.socket.remoteAddress === '::ffff:127.0.0.1';

    const selfDev = ensureDevice(deviceId, {
      platform,
      deviceName: deviceName || undefined,
      isNativeHost: isLocalReq ? true : undefined
    });

    const roomDevices = selfDev.roomCode ? getDevicesInRoom(selfDev.roomCode) : [];

    sendJson(res, 200, {
      lanName: localLanName,
      localIp: primaryIp,
      httpPort: HTTP_PORT,
      selfDevice: selfDev,
      roomDevices,
      activeRooms: Array.from(getAllActiveRoomsSet())
    });
    return;
  }

  // 2) 更新设备名称与设备类型
  if (req.method === 'POST' && urlObj.pathname === '/api/device/update') {
    try {
      const body = await readJsonBody(req);
      if (!body.deviceId) return sendJson(res, 400, { ok: false, error: '缺少 deviceId' });
      const dev = ensureDevice(body.deviceId, {
        deviceName: body.deviceName,
        platform: body.platform
      });
      broadcastStateNow();
      return sendJson(res, 200, { ok: true, selfDevice: dev });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 3) 独立开房间：生成 4 位数匹配码并进入房间
  if (req.method === 'POST' && urlObj.pathname === '/api/room/create') {
    try {
      const body = await readJsonBody(req);
      if (!body.deviceId) return sendJson(res, 400, { ok: false, error: '缺少 deviceId' });
      const dev = ensureDevice(body.deviceId, {
        deviceName: body.deviceName,
        platform: body.platform
      });
      const code = generateFourDigitRoomCode();
      activeRooms.add(code);
      dev.roomCode = code;
      broadcastStateNow();
      return sendJson(res, 200, {
        ok: true,
        roomCode: code,
        selfDevice: dev,
        roomDevices: getDevicesInRoom(code)
      });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 4) 加入房间：通过 4 位数匹配码加入房间
  if (req.method === 'POST' && urlObj.pathname === '/api/room/join') {
    try {
      const body = await readJsonBody(req);
      const code = String(body.roomCode || '').trim();
      if (!/^\d{4}$/.test(code)) {
        return sendJson(res, 400, { ok: false, error: '请输入 4 位数字匹配码' });
      }
      const dev = ensureDevice(body.deviceId, {
        deviceName: body.deviceName,
        platform: body.platform
      });
      activeRooms.add(code);
      dev.roomCode = code;
      broadcastStateNow();
      return sendJson(res, 200, {
        ok: true,
        roomCode: code,
        selfDevice: dev,
        roomDevices: getDevicesInRoom(code)
      });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 5) 退出房间
  if (req.method === 'POST' && urlObj.pathname === '/api/room/leave') {
    try {
      const body = await readJsonBody(req);
      if (!body.deviceId) return sendJson(res, 400, { ok: false, error: '缺少 deviceId' });
      const dev = ensureDevice(body.deviceId);
      dev.roomCode = '';
      broadcastStateNow();
      return sendJson(res, 200, { ok: true, selfDevice: dev });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 6) 播放器控制指令 (拖动进度条开始、上一章、下一章、播放暂停)
  if (req.method === 'POST' && urlObj.pathname === '/api/control') {
    try {
      const cmd = await readJsonBody(req);
      const result = await dispatchControlCommand(cmd);
      return sendJson(res, 200, result);
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 7) 跨主机 HTTP 双向状态与房间同步接口 (穿透路由器 UDP 广播隔离与单向防火墙)
  if (req.method === 'POST' && urlObj.pathname === '/api/lan-sync') {
    try {
      const body = await readJsonBody(req);
      const senderIp = (body.ip || req.socket.remoteAddress || '').replace('::ffff:', '');
      ingestRemoteSyncPayload(body, senderIp);
      return sendJson(res, 200, buildLocalSyncPayload(senderIp));
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: e.message });
    }
  }

  // 默认返回前端单页
  fs.readFile(uiFilePath, 'utf8', (err, html) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('UI file missing');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  });
});

function openControlWindow() {
  const targetUrl = `http://127.0.0.1:${HTTP_PORT}`;
  if (HOST_PLATFORM === 'windows') {
    const edgePaths = [
      'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
      'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'
    ];
    const edgeExe = edgePaths.find(p => fs.existsSync(p));
    if (edgeExe) {
      const child = spawn(edgeExe, [`--app=${targetUrl}`, '--window-size=500,800'], {
        detached: true,
        stdio: 'ignore'
      });
      child.unref();
    } else {
      const child = spawn('cmd.exe', ['/c', 'start', '', targetUrl], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true
      });
      child.unref();
    }
  } else if (HOST_PLATFORM === 'macos') {
    const child = spawn('/usr/bin/open', [targetUrl], {
      detached: true,
      stdio: 'ignore'
    });
    child.unref();
  }
}

async function refreshLocalState() {
  if (HOST_PLATFORM === 'windows') {
    await requestWindowsBridge({ op: 'state' });
  } else if (HOST_PLATFORM === 'macos') {
    await pollMacState();
  }
}

if (HOST_PLATFORM === 'windows') {
  initWindowsBridge();
}

setInterval(async () => {
  await refreshLocalState();
  broadcastStateNow();
}, 1500);

refreshLocalState().then(() => broadcastStateNow());

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    if (process.argv.includes('--open')) {
      openControlWindow();
    }
    setTimeout(() => process.exit(0), 300);
  }
});

server.listen(HTTP_PORT, () => {
  const { primaryIp } = getNetworkAddresses();
  console.log('====================================================');
  console.log(' 四端局域网媒体控制器已启动 (支持 4 位数房间匹配码)');
  console.log(` 本机地址: http://127.0.0.1:${HTTP_PORT}`);
  console.log(` 局域网访问: http://${primaryIp}:${HTTP_PORT}`);
  console.log('====================================================');
  if (process.argv.includes('--open')) {
    openControlWindow();
  }
});
