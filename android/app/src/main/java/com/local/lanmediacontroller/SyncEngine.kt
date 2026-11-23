package com.local.lanmediacontroller

import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.ServerSocket
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.random.Random

object SyncEngine {
    const val UDP_PORT = 41234
    const val MULTICAST_GROUP = "239.255.42.99"
    const val RELAY_BASE = "https://ntfy.sh"

    private const val PREFS = "lmc_v2_prefs"

    private val lock = Any()
    private val ioExecutor = Executors.newCachedThreadPool()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()

    private val peersById = HashMap<String, DeviceRecord>()
    private val discoveredRooms = HashMap<String, Long>()
    private val executedCmdIds = ConcurrentHashMap.newKeySet<String>()
    private val listeners = ConcurrentHashMap.newKeySet<() -> Unit>()
    private val startupMs = System.currentTimeMillis()

    @Volatile private var started = false
    @Volatile private var appContext: Context? = null
    @Volatile private var udpSocket: MulticastSocket? = null
    @Volatile private var httpServer: ServerSocket? = null
    @Volatile private var relayThread: Thread? = null
    @Volatile private var relayRoomToken: String = ""
    @Volatile private var heartbeatFuture: ScheduledFuture<*>? = null
    @Volatile private var tickCount = 0

    @Volatile var deviceId: String = ""
        private set
    @Volatile var deviceName: String = ""
        private set
    @Volatile var currentRoomCode: String = ""
        private set
    @Volatile var displayedLanName: String = "正在检测局域网..."
        private set
    @Volatile var localPlayer: PlayerState = PlayerState()
        private set

    @Volatile private var localIp: String = ""
    @Volatile private var localSubnet: String = ""
    @Volatile private var resolvedRealSsid: String = ""
    @Volatile private var broadcastAddresses: List<String> = listOf("255.255.255.255")
    @Volatile private var httpPort: Int = 41235

    fun addListener(cb: () -> Unit) { listeners.add(cb) }
    fun removeListener(cb: () -> Unit) { listeners.remove(cb) }

    private fun notifyUpdated() {
        for (cb in listeners) {
            try { cb() } catch (_: Exception) {}
        }
    }

    fun start(context: Context) {
        if (started) return
        synchronized(this) {
            if (started) return
            started = true
            appContext = context.applicationContext
        }

        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        deviceId = prefs.getString("device_id", null)?.takeIf { it.isNotBlank() } ?: run {
            val id = "and-" + UUID.randomUUID().toString().replace("-", "").take(8)
            prefs.edit().putString("device_id", id).apply()
            id
        }
        deviceName = prefs.getString("device_name", null)?.takeIf { it.isNotBlank() } ?: run {
            val model = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifEmpty { "Android 设备" }
            prefs.edit().putString("device_name", model).apply()
            model
        }

        refreshNetworkInfo()
        startUdp()
        startHttpServer()

        AndroidMediaController.init(context.applicationContext) { state ->
            localPlayer = state
            notifyUpdated()
            ioExecutor.execute { broadcastPresence(includeRelay = currentRoomCode.isNotEmpty()) }
        }

        heartbeatFuture = scheduler.scheduleAtFixedRate({
            try {
                tickCount++
                if (tickCount % 10 == 0) refreshNetworkInfo()
                AndroidMediaController.refreshState()
                pruneStalePeers()
                broadcastPresence(includeRelay = currentRoomCode.isNotEmpty() && (tickCount % 2 == 0))
            } catch (_: Exception) {}
        }, 400, 1500, TimeUnit.MILLISECONDS)
    }

    fun saveDeviceName(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        deviceName = trimmed
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.edit()?.putString("device_name", trimmed)?.apply()
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = currentRoomCode.isNotEmpty()) }
    }

    fun createRoom() {
        val code = Random.nextInt(1000, 10000).toString()
        joinRoom(code)
    }

    fun joinRoom(code: String) {
        val clean = code.trim()
        if (clean.length != 4 || !clean.all { it.isDigit() }) return
        val old = currentRoomCode
        if (old.isNotEmpty() && old != clean) {
            ioExecutor.execute { sendLeave(old) }
        }
        synchronized(lock) {
            currentRoomCode = clean
            peersById.clear()
        }
        startRelaySubscription(clean)
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = true) }
    }

    fun leaveRoom() {
        val old = currentRoomCode
        stopRelaySubscription()
        synchronized(lock) {
            currentRoomCode = ""
            peersById.clear()
        }
        if (old.isNotEmpty()) {
            ioExecutor.execute { sendLeave(old) }
        }
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = false) }
    }

    fun getRoomPeersSnapshot(): List<DeviceRecord> = synchronized(lock) {
        peersById.values.sortedBy { it.deviceName.lowercase() }
    }

    fun getDiscoveredRoomsSnapshot(): List<String> = synchronized(lock) {
        discoveredRooms.keys.sorted()
    }

    fun sendCommand(targetDeviceId: String, action: String, position: Double = 0.0) {
        if (targetDeviceId == deviceId) {
            localPlayer = applyOptimistic(localPlayer, action, position)
            notifyUpdated()
            ioExecutor.execute {
                AndroidMediaController.executeCommand(action, position)
                Thread.sleep(220)
                AndroidMediaController.refreshState()
                broadcastPresence(includeRelay = currentRoomCode.isNotEmpty())
            }
            return
        }

        val cmdId = "cmd-" + UUID.randomUUID().toString().replace("-", "").take(8)
        executedCmdIds.add(cmdId)
        val cmdJson = JSONObject().apply {
            put("v", 2)
            put("type", "command")
            put("cmdId", cmdId)
            put("roomCode", currentRoomCode)
            put("targetDeviceId", targetDeviceId)
            put("action", action)
            put("position", position)
            put("ts", System.currentTimeMillis())
        }.toString()

        var peerIp = ""
        var peerPort = 0
        synchronized(lock) {
            val peer = peersById[targetDeviceId]
            if (peer != null) {
                peersById[targetDeviceId] = peer.copy(player = applyOptimistic(peer.player, action, position))
                peerIp = peer.ip
                peerPort = peer.httpPort
            }
        }
        notifyUpdated()

        ioExecutor.execute {
            if (peerIp.isNotEmpty() && peerPort > 0) {
                sendHttpPost("http://$peerIp:$peerPort/api/command", cmdJson)
                sendUdpString(cmdJson, peerIp)
            }
            val room = currentRoomCode
            if (room.isNotEmpty()) {
                sendHttpPost("$RELAY_BASE/lmc_v2_r_$room", cmdJson)
            }
        }
    }

    private fun applyOptimistic(p: PlayerState, action: String, position: Double): PlayerState {
        val now = System.currentTimeMillis()
        return when (action) {
            "play" -> p.copy(position = p.livePosition(now), isPlaying = true, updatedAt = now)
            "pause" -> p.copy(position = p.livePosition(now), isPlaying = false, updatedAt = now)
            "toggle" -> p.copy(position = p.livePosition(now), isPlaying = !p.isPlaying, updatedAt = now)
            "seek" -> p.copy(position = max(0.0, position), isPlaying = true, updatedAt = now)
            "next", "prev" -> p.copy(position = 0.0, isPlaying = true, updatedAt = now)
            else -> p
        }
    }

    private fun refreshNetworkInfo() {
        val ctx = appContext ?: return
        val snap = AndroidNetworkInfo.readSnapshot(ctx)
        localIp = snap.ip
        localSubnet = snap.subnet
        broadcastAddresses = snap.broadcastAddresses
        if (AndroidNetworkInfo.isValidSsid(snap.ssid)) {
            resolvedRealSsid = snap.ssid
        }
        updateDisplayedLanName()
    }

    private fun updateDisplayedLanName() {
        val next = when {
            AndroidNetworkInfo.isValidSsid(resolvedRealSsid) -> resolvedRealSsid
            localIp.isNotEmpty() -> "Wi-Fi · $localIp"
            else -> "本地局域网"
        }
        if (displayedLanName != next) {
            displayedLanName = next
            notifyUpdated()
        }
    }

    private fun startUdp() {
        ioExecutor.execute {
            try {
                val sock = MulticastSocket(null)
                sock.reuseAddress = true
                sock.broadcast = true
                sock.bind(InetSocketAddress(UDP_PORT))
                try {
                    sock.joinGroup(InetAddress.getByName(MULTICAST_GROUP))
                } catch (_: Exception) {}
                udpSocket = sock

                val buf = ByteArray(8192)
                while (started && !sock.isClosed) {
                    val pkt = DatagramPacket(buf, buf.size)
                    sock.receive(pkt)
                    val msg = String(pkt.data, 0, pkt.length, Charsets.UTF_8)
                    val senderIp = pkt.address?.hostAddress ?: ""
                    handleIncomingJson(msg, "局域网直连", senderIp)
                }
            } catch (_: Exception) {}
        }
    }

    private fun startHttpServer() {
        ioExecutor.execute {
            var server: ServerSocket? = null
            for (port in 41235..41245) {
                try {
                    server = ServerSocket(port)
                    httpPort = port
                    httpServer = server
                    break
                } catch (_: Exception) {}
            }
            val srv = server ?: return@execute
            while (started && !srv.isClosed) {
                try {
                    val client = srv.accept()
                    ioExecutor.execute {
                        try {
                            client.soTimeout = 2000
                            val inp = client.getInputStream()
                            val buf = ByteArray(16384)
                            val read = inp.read(buf)
                            if (read > 0) {
                                val raw = String(buf, 0, read, Charsets.UTF_8)
                                val sep = raw.indexOf("\r\n\r\n")
                                if (sep >= 0) {
                                    val body = raw.substring(sep + 4)
                                    if (body.isNotBlank()) {
                                        handleIncomingJson(body, "局域网直连", client.inetAddress?.hostAddress ?: "")
                                    }
                                }
                            }
                            val resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
                            client.getOutputStream().write(resp.toByteArray(Charsets.UTF_8))
                            client.getOutputStream().flush()
                        } catch (_: Exception) {
                        } finally {
                            try { client.close() } catch (_: Exception) {}
                        }
                    }
                } catch (_: Exception) {}
            }
        }
    }

    private fun broadcastPresence(includeRelay: Boolean) {
        val room = currentRoomCode
        val json = JSONObject().apply {
            put("v", 2)
            put("type", "presence")
            put("deviceId", deviceId)
            put("deviceName", deviceName)
            put("platform", "android")
            put("roomCode", room)
            put("lanName", resolvedRealSsid)
            put("ip", localIp)
            put("subnet", localSubnet)
            put("httpPort", httpPort)
            put("ts", System.currentTimeMillis())
            put("player", localPlayer.toJson())
        }.toString()

        val targets = linkedSetOf<String>()
        targets.addAll(broadcastAddresses)
        targets.add(MULTICAST_GROUP)
        targets.add("255.255.255.255")
        for (host in targets) sendUdpString(json, host)

        if (includeRelay && room.isNotEmpty()) {
            sendHttpPost("$RELAY_BASE/lmc_v2_r_$room", json)
        }
    }

    private fun sendLeave(roomCode: String) {
        val json = JSONObject().apply {
            put("v", 2)
            put("type", "leave")
            put("deviceId", deviceId)
            put("roomCode", roomCode)
            put("ts", System.currentTimeMillis())
        }.toString()
        val targets = linkedSetOf<String>()
        targets.addAll(broadcastAddresses)
        targets.add(MULTICAST_GROUP)
        for (host in targets) sendUdpString(json, host)
        sendHttpPost("$RELAY_BASE/lmc_v2_r_$roomCode", json)
    }

    private fun sendUdpString(payload: String, host: String) {
        try {
            val bytes = payload.toByteArray(Charsets.UTF_8)
            val addr = InetAddress.getByName(host)
            val pkt = DatagramPacket(bytes, bytes.size, addr, UDP_PORT)
            val sock = udpSocket
            if (sock != null && !sock.isClosed) {
                sock.send(pkt)
            } else {
                DatagramSocket().use { it.broadcast = true; it.send(pkt) }
            }
        } catch (_: Exception) {}
    }

    private fun sendHttpPost(urlStr: String, body: String) {
        try {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 2000
                readTimeout = 2000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            conn.responseCode
            conn.disconnect()
        } catch (_: Exception) {}
    }

    private fun startRelaySubscription(roomCode: String) {
        stopRelaySubscription()
        relayRoomToken = roomCode
        val t = Thread {
            val urlStr = "$RELAY_BASE/lmc_v2_r_$roomCode/sse?since=2m"
            while (started && relayRoomToken == roomCode && !Thread.currentThread().isInterrupted) {
                var conn: HttpURLConnection? = null
                try {
                    conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 5000
                        readTimeout = 60000
                    }
                    BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                        while (started && relayRoomToken == roomCode) {
                            val line = reader.readLine() ?: break
                            if (!line.startsWith("data:")) continue
                            val raw = line.substring(5).trim()
                            try {
                                val outer = JSONObject(raw)
                                if (outer.optString("event") == "message") {
                                    val inner = outer.optString("message", "")
                                    if (inner.isNotBlank()) {
                                        handleIncomingJson(inner, "中继同步", "")
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }
                } catch (_: Exception) {
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
                } finally {
                    try { conn?.disconnect() } catch (_: Exception) {}
                }
            }
        }
        t.isDaemon = true
        t.start()
        relayThread = t
    }

    private fun stopRelaySubscription() {
        relayRoomToken = ""
        try { relayThread?.interrupt() } catch (_: Exception) {}
        relayThread = null
    }

    private fun handleIncomingJson(raw: String, sourceMode: String, senderIp: String) {
        try {
            val obj = JSONObject(raw)
            val type = obj.optString("type", "")
            val now = System.currentTimeMillis()

            when (type) {
                "presence" -> {
                    val devId = obj.optString("deviceId", "")
                    if (devId.isEmpty() || devId == deviceId) return

                    val peerSubnet = obj.optString("subnet", "")
                    val peerLanName = obj.optString("lanName", "")
                    if (!AndroidNetworkInfo.isValidSsid(resolvedRealSsid)
                        && localSubnet.isNotEmpty()
                        && peerSubnet == localSubnet
                        && AndroidNetworkInfo.isValidSsid(peerLanName)) {
                        resolvedRealSsid = peerLanName.trim()
                        updateDisplayedLanName()
                    }

                    val roomCode = obj.optString("roomCode", "")
                    val pktTs = obj.optLong("ts", now)
                    val effIp = senderIp.ifEmpty { obj.optString("ip", "") }
                    val player = PlayerState.fromJson(obj.optJSONObject("player"))

                    var changed = false
                    var shouldReply = false
                    synchronized(lock) {
                        if (sourceMode == "局域网直连" && roomCode.length == 4 && roomCode.all { it.isDigit() }) {
                            if (!discoveredRooms.containsKey(roomCode)) changed = true
                            discoveredRooms[roomCode] = now
                        }
                        if (currentRoomCode.isNotEmpty() && roomCode == currentRoomCode) {
                            val existing = peersById[devId]
                            if (existing != null) {
                                if (pktTs < existing.lastPacketTs) return
                                val mode = if (sourceMode == "局域网直连" || existing.connectionMode == "局域网直连") "局域网直连" else "中继同步"
                                peersById[devId] = existing.copy(
                                    deviceName = obj.optString("deviceName", existing.deviceName),
                                    platform = obj.optString("platform", existing.platform),
                                    lanName = peerLanName,
                                    ip = effIp.ifEmpty { existing.ip },
                                    subnet = peerSubnet,
                                    httpPort = obj.optInt("httpPort", existing.httpPort),
                                    lastSeen = now,
                                    lastPacketTs = pktTs,
                                    connectionMode = mode,
                                    player = player
                                )
                                changed = true
                            } else {
                                peersById[devId] = DeviceRecord(
                                    deviceId = devId,
                                    deviceName = obj.optString("deviceName", "设备"),
                                    platform = obj.optString("platform", "windows"),
                                    roomCode = roomCode,
                                    lanName = peerLanName,
                                    ip = effIp,
                                    subnet = peerSubnet,
                                    httpPort = obj.optInt("httpPort", 41235),
                                    lastSeen = now,
                                    lastPacketTs = pktTs,
                                    connectionMode = sourceMode,
                                    player = player
                                )
                                shouldReply = true
                                changed = true
                            }
                        }
                    }
                    if (changed) notifyUpdated()
                    if (shouldReply) ioExecutor.execute { broadcastPresence(includeRelay = true) }
                }

                "leave" -> {
                    val devId = obj.optString("deviceId", "")
                    val pktTs = obj.optLong("ts", now)
                    var removed = false
                    synchronized(lock) {
                        val existing = peersById[devId]
                        if (existing != null && pktTs >= existing.lastPacketTs) {
                            peersById.remove(devId)
                            removed = true
                        }
                    }
                    if (removed) notifyUpdated()
                }

                "command" -> {
                    val cmdId = obj.optString("cmdId", "")
                    val pktTs = obj.optLong("ts", now)
                    if (cmdId.isEmpty() || pktTs < startupMs - 5000) return
                    if (!executedCmdIds.add(cmdId)) return

                    val targetId = obj.optString("targetDeviceId", "")
                    if (targetId == deviceId) {
                        val action = obj.optString("action", "toggle")
                        val pos = obj.optDouble("position", 0.0).takeIf { !it.isNaN() } ?: 0.0
                        localPlayer = applyOptimistic(localPlayer, action, pos)
                        notifyUpdated()
                        ioExecutor.execute {
                            AndroidMediaController.executeCommand(action, pos)
                            Thread.sleep(220)
                            AndroidMediaController.refreshState()
                            broadcastPresence(includeRelay = currentRoomCode.isNotEmpty())
                        }
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun pruneStalePeers() {
        val now = System.currentTimeMillis()
        var changed = false
        synchronized(lock) {
            val stalePeers = peersById.filterValues { now - it.lastSeen > 14_000 }.keys.toList()
            for (id in stalePeers) { peersById.remove(id); changed = true }
            val staleRooms = discoveredRooms.filterValues { now - it > 15_000 }.keys.toList()
            for (r in staleRooms) { discoveredRooms.remove(r); changed = true }
        }
        if (changed) notifyUpdated()
    }
}
