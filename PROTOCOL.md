# LanMediaController v2.1 Auto-Host Room Protocol

All 4 native clients (`macOS`, `Windows`, `Android`, `iOS`) implement this unified JSON protocol with **zero matching codes**:

## Room Behavior

1. **Auto-Host on Startup**:
   - Every device automatically opens and hosts its own room upon launch:
     - `roomId = deviceId`
     - `roomName = "<deviceName>的房间"`
   - Renaming the device updates `roomName` automatically when hosting its own room.
2. **One-Click Join**:
   - Devices discover all other active rooms on the same network and display them in **"可加入的其他设备房间"**.
   - Clicking **加入** switches `currentRoomId` and `currentRoomName` to the selected room.
   - Clicking **回到我的房间** sends a `leave` packet and returns to hosting `"<deviceName>的房间"`.

## Dual-Layer Transport

1. **Primary — Direct LAN (< 5ms, works offline)**:
   - UDP Discovery & Presence on port `41234` (directed subnet broadcasts + `255.255.255.255` + multicast `239.255.42.99:41234`).
   - Direct LAN HTTP control endpoint on port `41235` (`41235..41245` auto-fallback): `POST /api/command`.
2. **Secondary — Automatic Same-Network Discovery Relay**:
   - Computes `SHA-256("lmc-v2-home:" + publicIPv4)[0..16]` via `https://api4.ipify.org` (fallback `https://ipv4.icanhazip.com`).
   - Ensures devices behind the same home router immediately see each other's rooms and control each other even when Windows Firewall or router AP isolation blocks inbound LAN UDP/TCP packets.
   - Deduplicated via `cmdId` and monotonic `ts`.

## Message Schemas

### Presence (`type: "presence"`)
```json
{
  "v": 2,
  "type": "presence",
  "deviceId": "mac-a1b2c3d4",
  "deviceName": "MacBook Air",
  "platform": "macos",
  "roomId": "mac-a1b2c3d4",
  "roomName": "MacBook Air的房间",
  "lanName": "HomeWiFi",
  "ip": "192.168.1.25",
  "subnet": "192.168.1",
  "httpPort": 41235,
  "ts": 1732400000000,
  "player": {
    "appName": "QQ音乐",
    "title": "晴天",
    "artist": "周杰伦",
    "isPlaying": true,
    "position": 45.2,
    "duration": 269.0,
    "hasMedia": true,
    "updatedAt": 1732400000000
  }
}
```

### Command (`type: "command"`)
```json
{
  "v": 2,
  "type": "command",
  "cmdId": "cmd-9f8e7d6c",
  "roomId": "mac-a1b2c3d4",
  "targetDeviceId": "mac-a1b2c3d4",
  "action": "seek",
  "position": 90.0,
  "ts": 1732400000000
}
```
Supported `action` values: `"seek"` (seek + play), `"prev"`, `"toggle"`, `"play"`, `"pause"`, `"next"`.

### Leave (`type: "leave"`)
```json
{
  "v": 2,
  "type": "leave",
  "deviceId": "win-2dbac610",
  "roomId": "mac-a1b2c3d4",
  "ts": 1732400000000
}
```
