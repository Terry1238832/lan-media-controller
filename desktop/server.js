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

// 局域网 UDP 发现的远端设备表: Map<deviceId, DeviceRecord>
const remoteLanDevices = new Map();

// 已创建的有效房间号集合: Set<string>
const activeRooms = new Set();

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
// 2. macOS 媒体与网络桥接 (AppleScript + networksetup)
// ============================================================================
function execPromise(cmd, args, timeout = 2000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout }, (err, stdout) => {
      if (err) return resolve('');
      resolve(stdout ? stdout.toString('utf8').trim() : '');
    });
  });
}

async function pollMacState() {
  const wifiOut = await execPromise('/usr/sbin/networksetup', ['-getairportnetwork', 'en0']);
  if (wifiOut && wifiOut.includes(':')) {
    localLanName = wifiOut.split(':').slice(1).join(':').trim();
  } else if (localLanName === '正在获取局域网...') {
    localLanName = 'macOS 局域网';
  }
}

async function executeMacCommand(cmdObj) {
  const action = cmdObj.action;
  const pos = Number(cmdObj.position) || 0;
  let script = '';
  if (action === 'play') script = 'tell application "Music" to play';
  else if (action === 'pause') script = 'tell application "Music" to pause';
  else if (action === 'toggle') script = 'tell application "Music" to playpause';
  else if (action === 'next') script = 'tell application "Music" to next track';
  else if (action === 'prev') script = 'tell application "Music" to previous track';
  else if (action === 'seek') {
    script = `tell application "Music"
      set player position to ${pos}
      play
    end tell`;
  }
  if (script) {
    await execPromise('/usr/bin/osascript', ['-e', script]);
  }
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
      player: {
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
    player.title = `第 ${player.chapterIndex} 章`;
    player.position = 0;
    player.isPlaying = true;
  } else if (cmd.action === 'prev') {
    player.chapterIndex = Math.max(1, player.chapterIndex - 1);
    player.title = `第 ${player.chapterIndex} 章`;
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
      if (p.position >= (p.duration || 300)) {
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
  const { primaryIp, broadcasts } = getNetworkAddresses();
  const localList = Array.from(devicesMap.values()).map(d => ({
    deviceId: d.deviceId,
    deviceName: d.deviceName,
    platform: d.platform,
    roomCode: d.roomCode,
    ip: primaryIp,
    httpPort: HTTP_PORT,
    player: d.player
  }));

  const packet = Buffer.from(JSON.stringify({
    type: 'lan_sync',
    senderHostId: HOST_DEVICE_ID,
    lanName: localLanName,
    ip: primaryIp,
    httpPort: HTTP_PORT,
    rooms: Array.from(activeRooms),
    devices: localList,
    timestamp: Date.now()
  }), 'utf8');

  for (const bcastAddr of broadcasts) {
    udpSocket.send(packet, 0, packet.length, UDP_PORT, bcastAddr, () => {});
  }
}

udpSocket.on('message', (msg, rinfo) => {
  try {
    const data = JSON.parse(msg.toString('utf8'));
    if (!data || !data.type) return;

    // 兼容多节点房间同步包
    if (data.type === 'lan_sync' && data.senderHostId !== HOST_DEVICE_ID) {
      if (Array.isArray(data.rooms)) {
        for (const r of data.rooms) {
          if (/^\d{4}$/.test(String(r))) activeRooms.add(String(r));
        }
      }
      if (Array.isArray(data.devices)) {
        for (const dev of data.devices) {
          if (dev.deviceId && !devicesMap.has(dev.deviceId)) {
            remoteLanDevices.set(dev.deviceId, {
              ...dev,
              ip: dev.ip || rinfo.address,
              lastSeen: Date.now()
            });
            if (dev.roomCode && /^\d{4}$/.test(dev.roomCode)) {
              activeRooms.add(dev.roomCode);
            }
          }
        }
      }
    } else if (data.type === 'state' && data.deviceId && !devicesMap.has(data.deviceId)) {
      // 兼容 iOS / Android 原生端直接广播的单设备数据包
      const p0 = (Array.isArray(data.players) && data.players[0]) || data.player || {};
      const roomCode = String(data.roomCode || '');
      if (/^\d{4}$/.test(roomCode)) activeRooms.add(roomCode);
      remoteLanDevices.set(data.deviceId, {
        deviceId: data.deviceId,
        deviceName: data.deviceName || data.platform || '移动设备',
        platform: data.platform || 'ios',
        roomCode: roomCode,
        ip: data.ip || rinfo.address,
        httpPort: data.httpPort || HTTP_PORT,
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

// 清理离线远端设备
setInterval(() => {
  const now = Date.now();
  for (const [id, dev] of remoteLanDevices.entries()) {
    if (now - (dev.lastSeen || 0) > 15000) {
      remoteLanDevices.delete(id);
    }
  }
}, 5000);

// ============================================================================
// 5. 控制指令分发 (支持房间内任意设备互控)
// ============================================================================
async function dispatchControlCommand(cmd) {
  const targetId = cmd.targetDeviceId;
  const localDev = devicesMap.get(targetId);

  if (localDev) {
    applyActionToPlayer(localDev.player, cmd);
    if (localDev.isNativeHost) {
      await triggerHostOSMedia(cmd);
    }
    broadcastStateNow();
    return { ok: true, target: 'local' };
  }

  const remoteDev = remoteLanDevices.get(targetId);
  if (remoteDev) {
    applyActionToPlayer(remoteDev.player, cmd);
    const udpPayload = Buffer.from(JSON.stringify({
      type: 'command',
      targetDeviceId: targetId,
      action: cmd.action,
      position: cmd.position
    }), 'utf8');
    udpSocket.send(udpPayload, 0, udpPayload.length, UDP_PORT, remoteDev.ip, () => {});

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
