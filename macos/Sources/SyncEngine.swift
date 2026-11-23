import Foundation
import Network
import Darwin

@MainActor
final class SyncEngine: ObservableObject {
    static let udpPort: UInt16 = 41234
    static let multicastGroup = "239.255.42.99"
    static let relayBase = "https://ntfy.sh"

    @Published var deviceName: String
    @Published var currentRoomCode: String = ""
    @Published var displayedLanName: String = "正在检测局域网..."
    @Published var localIP: String = ""
    @Published var localPlayer: PlayerState = PlayerState()
    @Published var roomPeers: [DeviceRecord] = []
    @Published var discoveredRooms: [String] = []
    @Published var uiTick: Int64 = nowMillis()

    let deviceId: String
    private var localSubnet: String = ""
    private var resolvedRealSSID: String = ""
    private var broadcastAddresses: [String] = ["255.255.255.255"]
    private var httpPort: Int = 41235

    private let mediaController = MacMediaController()
    private let netQueue = DispatchQueue(label: "com.local.lanmediacontroller.net", qos: .utility)

    private var udpSocket: Int32 = -1
    private var udpRunning = false
    private var started = false
    private var httpListener: NWListener?
    private var relayTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var uiTickerTimer: Timer?
    private var netRefreshCounter = 0

    private var peersById: [String: DeviceRecord] = [:]
    private var discoveredRoomsMap: [String: Int64] = [:]
    private var executedCmdIds: Set<String> = []
    private var startupMs: Int64 = nowMillis()

    init() {
        let defaults = UserDefaults.standard
        if let savedId = defaults.string(forKey: "lmc_v2_device_id"), !savedId.isEmpty {
            self.deviceId = savedId
        } else {
            let newId = "mac-" + UUID().uuidString.prefix(8).lowercased()
            defaults.set(newId, forKey: "lmc_v2_device_id")
            self.deviceId = newId
        }

        if let savedName = defaults.string(forKey: "lmc_v2_device_name"), !savedName.isEmpty {
            self.deviceName = savedName
        } else {
            let host = Host.current().localizedName ?? "Mac"
            self.deviceName = host
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshNetworkInfo()
        startUDP()
        startHTTPServer(startingPort: 41235)

        mediaController.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localPlayer = state
                self.broadcastPresence(includeRelay: !self.currentRoomCode.isEmpty)
            }
        }
        mediaController.start()

        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onHeartbeatTick()
            }
        }

        uiTickerTimer?.invalidate()
        uiTickerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.uiTick = nowMillis()
            }
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        uiTickerTimer?.invalidate()
        relayTask?.cancel()
        mediaController.stop()
        httpListener?.cancel()
        udpRunning = false
        if udpSocket >= 0 {
            Darwin.close(udpSocket)
            udpSocket = -1
        }
    }

    func saveDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "lmc_v2_device_name")
        broadcastPresence(includeRelay: !currentRoomCode.isEmpty)
    }

    func createRoom() {
        let code = String(format: "%04d", Int.random(in: 1000...9999))
        joinRoom(code: code)
    }

    func joinRoom(code: String) {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 4, cleaned.allSatisfy({ $0.isNumber }) else { return }
        if !currentRoomCode.isEmpty && currentRoomCode != cleaned {
            sendLeave(roomCode: currentRoomCode)
        }
        currentRoomCode = cleaned
        peersById.removeAll()
        roomPeers = []
        startRelaySubscription(for: cleaned)
        broadcastPresence(includeRelay: true)
    }

    func leaveRoom() {
        let old = currentRoomCode
        currentRoomCode = ""
        relayTask?.cancel()
        relayTask = nil
        peersById.removeAll()
        roomPeers = []
        if !old.isEmpty {
            sendLeave(roomCode: old)
        }
        broadcastPresence(includeRelay: false)
    }

    func sendCommand(to targetDeviceId: String, action: String, position: Double = 0) {
        if targetDeviceId == deviceId {
            applyOptimisticLocal(action: action, position: position)
            mediaController.execute(action: action, position: position)
            broadcastPresence(includeRelay: !currentRoomCode.isEmpty)
            return
        }

        let cmd = CommandPacket(
            cmdId: "cmd-\(UUID().uuidString.prefix(8).lowercased())",
            roomCode: currentRoomCode,
            targetDeviceId: targetDeviceId,
            action: action,
            position: position,
            ts: nowMillis()
        )
        executedCmdIds.insert(cmd.cmdId)

        if var peer = peersById[targetDeviceId] {
            applyOptimistic(player: &peer.player, action: action, position: position)
            peersById[targetDeviceId] = peer
            publishSortedPeers()

            if !peer.ip.isEmpty && peer.httpPort > 0 {
                sendHTTPCommand(cmd, ip: peer.ip, port: peer.httpPort)
                sendUDPDirect(cmd, ip: peer.ip)
            }
        }

        if !currentRoomCode.isEmpty {
            publishToRelay(roomCode: currentRoomCode, payload: cmd)
        }
    }

    // MARK: - Heartbeat & Network Info

    private func onHeartbeatTick() {
        netRefreshCounter += 1
        if netRefreshCounter % 10 == 0 {
            refreshNetworkInfo()
        }
        pruneStalePeers()
        broadcastPresence(includeRelay: !currentRoomCode.isEmpty && (netRefreshCounter % 2 == 0))
    }

    private func refreshNetworkInfo() {
        netQueue.async { [weak self] in
            let snap = MacNetworkInfo.readSnapshot()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localIP = snap.ip
                self.localSubnet = snap.subnet
                self.broadcastAddresses = snap.broadcastAddresses
                if MacNetworkInfo.isValidSSID(snap.ssid) {
                    self.resolvedRealSSID = snap.ssid
                }
                self.updateDisplayedLanName()
            }
        }
    }

    private func updateDisplayedLanName() {
        if MacNetworkInfo.isValidSSID(resolvedRealSSID) {
            displayedLanName = resolvedRealSSID
        } else if !localIP.isEmpty {
            displayedLanName = "Wi-Fi · \(localIP)"
        } else {
            displayedLanName = "本地局域网"
        }
    }

    private func adoptSubnetLanNameIfValid(_ candidate: String, peerSubnet: String) {
        guard !MacNetworkInfo.isValidSSID(resolvedRealSSID) else { return }
        guard !localSubnet.isEmpty && peerSubnet == localSubnet else { return }
        guard MacNetworkInfo.isValidSSID(candidate) else { return }
        resolvedRealSSID = candidate
        updateDisplayedLanName()
    }

    // MARK: - Optimistic Updates

    private func applyOptimisticLocal(action: String, position: Double) {
        applyOptimistic(player: &localPlayer, action: action, position: position)
    }

    private func applyOptimistic(player: inout PlayerState, action: String, position: Double) {
        let now = nowMillis()
        switch action {
        case "play":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying = true
            player.updatedAt = now
        case "pause":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying = false
            player.updatedAt = now
        case "toggle":
            player.position = player.livePosition(nowMs: now)
            player.isPlaying.toggle()
            player.updatedAt = now
        case "seek":
            player.position = max(0, position)
            player.isPlaying = true
            player.updatedAt = now
        case "next", "prev":
            player.position = 0
            player.isPlaying = true
            player.updatedAt = now
        default:
            break
        }
    }

    // MARK: - UDP Discovery & Presence (Port 41234)

    private func startUDP() {
        netQueue.async { [weak self] in
            guard let self else { return }
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

            var bindAddr = sockaddr_in()
            bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_port = SyncEngine.udpPort.bigEndian
            bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY)

            let bindRes = withUnsafePointer(to: &bindAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes != 0 {
                Darwin.close(fd)
                return
            }

            var mreq = ip_mreq()
            inet_pton(AF_INET, SyncEngine.multicastGroup, &mreq.imr_multiaddr)
            mreq.imr_interface = in_addr(s_addr: INADDR_ANY)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

            self.udpSocket = fd
            self.udpRunning = true

            var buf = [UInt8](repeating: 0, count: 8192)
            while self.udpRunning {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &srcLen)
                    }
                }
                if n > 0 {
                    let data = Data(buf[0..<n])
                    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addrCopy = srcAddr.sin_addr
                    inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                    let senderIP = String(cString: ipBuf)
                    Task { @MainActor [weak self] in
                        self?.handleIncomingPacket(data: data, source: .lan, senderIP: senderIP)
                    }
                } else if !self.udpRunning {
                    break
                }
            }
        }
    }

    private func broadcastPresence(includeRelay: Bool) {
        let packet = PresencePacket(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: PlatformType.macos.rawValue,
            roomCode: currentRoomCode,
            lanName: resolvedRealSSID,
            ip: localIP,
            subnet: localSubnet,
            httpPort: httpPort,
            ts: nowMillis(),
            player: localPlayer
        )
        guard let data = try? JSONEncoder().encode(packet) else { return }

        var targets = Set(broadcastAddresses)
        targets.insert(SyncEngine.multicastGroup)
        targets.insert("255.255.255.255")

        let fd = udpSocket
        if fd >= 0 {
            netQueue.async {
                for host in targets {
                    Self.sendUDPData(fd: fd, data: data, host: host, port: SyncEngine.udpPort)
                }
            }
        }

        if includeRelay && !currentRoomCode.isEmpty {
            publishToRelay(roomCode: currentRoomCode, payload: packet)
        }
    }

    private func sendLeave(roomCode: String) {
        let packet = LeavePacket(deviceId: deviceId, roomCode: roomCode, ts: nowMillis())
        guard let data = try? JSONEncoder().encode(packet) else { return }

        var targets = Set(broadcastAddresses)
        targets.insert(SyncEngine.multicastGroup)
        let fd = udpSocket
        if fd >= 0 {
            netQueue.async {
                for host in targets {
                    Self.sendUDPData(fd: fd, data: data, host: host, port: SyncEngine.udpPort)
                }
            }
        }
        publishToRelay(roomCode: roomCode, payload: packet)
    }

    private func sendUDPDirect(_ cmd: CommandPacket, ip: String) {
        guard let data = try? JSONEncoder().encode(cmd), udpSocket >= 0 else { return }
        let fd = udpSocket
        netQueue.async {
            Self.sendUDPData(fd: fd, data: data, host: ip, port: SyncEngine.udpPort)
        }
    }

    private nonisolated static func sendUDPData(fd: Int32, data: Data, host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = Darwin.sendto(fd, ptr, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Direct LAN HTTP Server (NWListener on 41235..41245)

    private func startHTTPServer(startingPort: Int) {
        guard startingPort <= 41245, let nwPort = NWEndpoint.Port(rawValue: UInt16(startingPort)) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                if case .failed = state {
                    listener?.cancel()
                    Task { @MainActor [weak self] in
                        self?.startHTTPServer(startingPort: startingPort + 1)
                    }
                } else if case .ready = state {
                    Task { @MainActor [weak self] in
                        self?.httpPort = startingPort
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleHTTPConnection(conn)
            }
            listener.start(queue: netQueue)
            self.httpListener = listener
        } catch {
            startHTTPServer(startingPort: startingPort + 1)
        }
    }

    private nonisolated func handleHTTPConnection(_ conn: NWConnection) {
        conn.start(queue: netQueue)
        receiveHTTPData(conn: conn, accumulated: Data())
    }

    private nonisolated func receiveHTTPData(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }

            let raw = String(data: buffer, encoding: .utf8) ?? ""
            if let sep = raw.range(of: "\r\n\r\n") {
                let headerPart = String(raw[..<sep.lowerBound])
                let bodyStr = String(raw[sep.upperBound...])
                var expectedLen = 0
                for line in headerPart.split(separator: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        expectedLen = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                let bodyByteCount = bodyStr.utf8.count
                if expectedLen > 0 && bodyByteCount < expectedLen && !isComplete && error == nil {
                    self?.receiveHTTPData(conn: conn, accumulated: buffer)
                    return
                }
                if let bodyData = bodyStr.data(using: .utf8), !bodyData.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleIncomingPacket(data: bodyData, source: .lan, senderIP: "")
                    }
                }
            } else if !isComplete && error == nil && buffer.count < 16384 {
                self?.receiveHTTPData(conn: conn, accumulated: buffer)
                return
            }

            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func sendHTTPCommand(_ cmd: CommandPacket, ip: String, port: Int) {
        guard let url = URL(string: "http://\(ip):\(port)/api/command"),
              let body = try? JSONEncoder().encode(cmd) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Room-Scoped Relay Fallback (Firewall / AP Isolation Traversal)

    private func startRelaySubscription(for roomCode: String) {
        relayTask?.cancel()
        let topic = "lmc_v2_r_\(roomCode)"
        guard let url = URL(string: "\(SyncEngine.relayBase)/\(topic)/sse?since=2m") else { return }

        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 300
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let jsonPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let outerData = jsonPart.data(using: .utf8),
                              let outer = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any],
                              (outer["event"] as? String) == "message",
                              let msgStr = outer["message"] as? String,
                              let msgData = msgStr.data(using: .utf8) else { continue }
                        await MainActor.run { [weak self] in
                            self?.handleIncomingPacket(data: msgData, source: .relay, senderIP: "")
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func publishToRelay<T: Encodable>(roomCode: String, payload: T) {
        let topic = "lmc_v2_r_\(roomCode)"
        guard let url = URL(string: "\(SyncEngine.relayBase)/\(topic)"),
              let body = try? JSONEncoder().encode(payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Unified Incoming Packet Handler

    private func handleIncomingPacket(data: Data, source: ConnectionMode, senderIP: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let now = nowMillis()

        if type == "presence", let pkt = try? JSONDecoder().decode(PresencePacket.self, from: data) {
            guard pkt.deviceId != deviceId else { return }

            adoptSubnetLanNameIfValid(pkt.lanName, peerSubnet: pkt.subnet)

            if source == .lan && pkt.roomCode.count == 4 && pkt.roomCode.allSatisfy({ $0.isNumber }) {
                discoveredRoomsMap[pkt.roomCode] = now
                publishDiscoveredRooms()
            }

            guard !currentRoomCode.isEmpty && pkt.roomCode == currentRoomCode else { return }

            let effectiveIP = !senderIP.isEmpty ? senderIP : pkt.ip
            if let existing = peersById[pkt.deviceId] {
                if pkt.ts < existing.lastPacketTs { return }
                let mode: ConnectionMode = (source == .lan || existing.connectionMode == .lan) ? .lan : .relay
                peersById[pkt.deviceId] = DeviceRecord(
                    id: pkt.deviceId,
                    deviceName: pkt.deviceName,
                    platform: PlatformType(rawValue: pkt.platform) ?? .windows,
                    roomCode: pkt.roomCode,
                    lanName: pkt.lanName,
                    ip: effectiveIP.isEmpty ? existing.ip : effectiveIP,
                    subnet: pkt.subnet,
                    httpPort: pkt.httpPort > 0 ? pkt.httpPort : existing.httpPort,
                    lastSeen: now,
                    lastPacketTs: pkt.ts,
                    connectionMode: mode,
                    player: pkt.player
                )
            } else {
                peersById[pkt.deviceId] = DeviceRecord(
                    id: pkt.deviceId,
                    deviceName: pkt.deviceName,
                    platform: PlatformType(rawValue: pkt.platform) ?? .windows,
                    roomCode: pkt.roomCode,
                    lanName: pkt.lanName,
                    ip: effectiveIP,
                    subnet: pkt.subnet,
                    httpPort: pkt.httpPort,
                    lastSeen: now,
                    lastPacketTs: pkt.ts,
                    connectionMode: source,
                    player: pkt.player
                )
                // Immediately reply with our presence so newly joined peers see us instantly
                broadcastPresence(includeRelay: true)
            }
            publishSortedPeers()
        } else if type == "leave", let pkt = try? JSONDecoder().decode(LeavePacket.self, from: data) {
            guard pkt.deviceId != deviceId else { return }
            if let existing = peersById[pkt.deviceId], pkt.ts >= existing.lastPacketTs {
                peersById.removeValue(forKey: pkt.deviceId)
                publishSortedPeers()
            }
        } else if type == "command", let cmd = try? JSONDecoder().decode(CommandPacket.self, from: data) {
            guard !executedCmdIds.contains(cmd.cmdId) else { return }
            guard cmd.ts >= startupMs - 5000 else { return }
            guard currentRoomCode.isEmpty || cmd.roomCode == currentRoomCode else { return }
            executedCmdIds.insert(cmd.cmdId)

            if cmd.targetDeviceId == deviceId {
                applyOptimisticLocal(action: cmd.action, position: cmd.position)
                mediaController.execute(action: cmd.action, position: cmd.position)
                broadcastPresence(includeRelay: !currentRoomCode.isEmpty)
            }
        }
    }

    private func pruneStalePeers() {
        let now = nowMillis()
        let beforePeers = peersById.count
        peersById = peersById.filter { now - $0.value.lastSeen < 14_000 }
        if peersById.count != beforePeers {
            publishSortedPeers()
        }

        let beforeRooms = discoveredRoomsMap.count
        discoveredRoomsMap = discoveredRoomsMap.filter { now - $0.value < 15_000 }
        if discoveredRoomsMap.count != beforeRooms {
            publishDiscoveredRooms()
        }
    }

    private func publishSortedPeers() {
        roomPeers = peersById.values.sorted { $0.deviceName.localizedCompare($1.deviceName) == .orderedAscending }
    }

    private func publishDiscoveredRooms() {
        discoveredRooms = discoveredRoomsMap.keys.sorted()
    }
}
