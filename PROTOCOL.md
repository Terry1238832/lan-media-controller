# LanMediaController v2 Sync Protocol

All 4 native clients (`macOS`, `Windows`, `Android`, `iOS`) implement this unified JSON protocol.

## Transport Layers

1. **Primary (Direct LAN, < 5ms, works offline)**:
   - **UDP Discovery & Presence**: Port `41234`
     - Broadcasts to `255.255.255.255`, all active IPv4 subnet directed broadcast addresses (e.g. `192.168.x.255`), and multicast `239.255.42.99:41234`.
   - **Direct HTTP Control Server**: Port `41235` (auto-fallback `41235..41245`)
     - `POST /api/command` accepts a `CommandPacket` JSON body.
2. **Secondary (Automatic Room Relay Fallback)**:
   - Active only when joined to a 4-digit room (`lmc_v2_r_<roomCode>`).
   - Ensures Windows/macOS/Android/iOS still see and control each other even when Windows Firewall or router AP isolation blocks inbound LAN packets.
   - All messages are deduplicated via `cmdId` and monotonic `ts`.

## Message Schemas

### Presence (`type: "presence"`)
```json
{
  "v": 2,
  "type": "presence",
  "deviceId": "dev-a1b2c3d4",
  "deviceName": "MacBook Air",
  "platform": "macos",
  "roomCode": "3849",
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
  "roomCode": "3849",
  "targetDeviceId": "dev-a1b2c3d4",
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
  "deviceId": "dev-a1b2c3d4",
  "roomCode": "3849",
  "ts": 1732400000000
}
```
