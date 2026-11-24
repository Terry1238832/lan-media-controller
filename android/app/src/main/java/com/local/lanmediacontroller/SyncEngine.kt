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
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.max

object SyncEngine {
    const val UDP_PORT = 41234
    const val MULTICAST_GROUP = "239.255.42.99"
    const val RELAY_BASE = "https://ntfy.sh"

    private const val PREFS = "lmc_v2_prefs"

    private val lock = Any()
    private val ioExecutor = Executors.newCachedThreadPool()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()

    private val allPeersById = HashMap<String, DeviceRecord>()
    private val executedCmdIds = ConcurrentHashMap.newKeySet<String>()
    private val listeners = ConcurrentHashMap.newKeySet<() -> Unit>()
    private val startupMs = System.currentTimeMillis()

    @Volatile private var started = false
    @Volatile private var appContext: Context? = null
    @Volatile private var udpSocket: MulticastSocket? = null
    @Volatile private var httpServer: ServerSocket? = null
    @Volatile private var relayThread: Thread? = null
    @Volatile private var homeRelayTopic: String = ""
    @Volatile private var heartbeatFuture: ScheduledFuture<*>? = null
    @Volatile private var tickCount = 0

    @Volatile var deviceId: String = ""
        private set
    @Volatile var deviceName: String = ""
        private set
    @Volatile var currentRoomId: String = ""
        private set
    @Volatile var currentRoomName: String = ""
        private set
    @Volatile var displayedLanName: String = "正在检测局域网..."
        private set
    @Volatile var localPlayer: PlayerState = PlayerState()
        private set

    val isHostingOwnRoom: Boolean
        get() = currentRoomId == deviceId

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
        // Default on launch: immediately host our own room named "<deviceName>的房间"
        currentRoomId = deviceId
        currentRoomName = "${deviceName}的房间"

        refreshNetworkInfo()
        startUdp()
        startHttpServer()
        resolveHomeRelayAndConnect()

        AndroidMediaController.init(context.applicationContext) { state ->
            localPlayer = state
            notifyUpdated()
            ioExecutor.execute { broadcastPresence(includeRelay = true) }
        }

        heartbeatFuture = scheduler.scheduleAtFixedRate({
            try {
                tickCount++
                if (tickCount % 10 == 0) refreshNetworkInfo()
                AndroidMediaController.refreshState()
                pruneStalePeers()
                broadcastPresence(includeRelay = tickCount % 2 == 0)
            } catch (_: Exception) {}
        }, 400, 1500, TimeUnit.MILLISECONDS)
    }

    fun saveDeviceName(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        synchronized(lock) {
            deviceName = trimmed
            if (currentRoomId == deviceId) {
                currentRoomName = "${trimmed}的房间"
            }
        }
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.edit()?.putString("device_name", trimmed)?.apply()
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = true) }
    }

    fun joinRoom(room: AvailableRoom) {
        if (room.roomId.isEmpty() || room.roomId == currentRoomId) return
        val old = currentRoomId
        if (old.isNotEmpty()) {
            ioExecutor.execute { sendLeave(old) }
        }
        synchronized(lock) {
            currentRoomId = room.roomId
            currentRoomName = room.roomName
        }
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = true) }
    }

    fun returnToOwnRoom() {
        if (currentRoomId == deviceId) return
        val old = currentRoomId
        ioExecutor.execute { sendLeave(old) }
        synchronized(lock) {
            currentRoomId = deviceId
            currentRoomName = "${deviceName}的房间"
        }
        notifyUpdated()
        ioExecutor.execute { broadcastPresence(includeRelay = true) }
    }

    fun getRoomPeersSnapshot(): List<DeviceRecord> = synchronized(lock) {
        allPeersById.values
            .filter { it.roomId == currentRoomId }
            .sortedBy { it.deviceName.lowercase() }
    }

    fun getAvailableRoomsSnapshot(): List<AvailableRoom> = synchronized(lock) {
        allPeersById.values
            .filter { it.roomId != currentRoomId }
            .groupBy { it.roomId }
            .map { (rId, members) ->
                val host = members.firstOrNull { it.deviceId == rId } ?: members.first()
                AvailableRoom(
                    roomId = rId,
                    roomName = host.roomName.ifBlank { "${host.deviceName}的房间" },
                    hostPlatform = host.platform,
                    memberCount = members.size,
                    isLanDirect = members.any { it.connectionMode == "局域网直连" }
                )
            }
            .sortedBy { it.roomName.lowercase() }
    }

    fun sendCommand(targetDeviceId: String, action: String, position: Double = 0.0) {
        if (targetDeviceId == deviceId) {
            localPlayer = applyOptimistic(localPlayer, action, position)
            notifyUpdated()
            ioExecutor.execute {
                AndroidMediaController.executeCommand(action, position)
                Thread.sleep(220)
                AndroidMediaController.refreshState()
                broadcastPresence(includeRelay = true)
            }
            return
        }

        val cmdId = "cmd-" + UUID.randomUUID().toString().replace("-", "").take(8)
        executedCmdIds.add(cmdId)
        val cmdJson = JSONObject().apply {
            put("v", 2)
            put("type", "command")
            put("cmdId", cmdId)
            put("roomId", currentRoomId)
            put("targetDeviceId", targetDeviceId)
            put("action", action)
            put("position", position)
            put("ts", System.currentTimeMillis())
        }.toString()

        var peerIp = ""
        var peerPort = 0
        synchronized(lock) {
            val peer = allPeersById[targetDeviceId]
            if (peer != null) {
                allPeersById[targetDeviceId] = peer.copy(player = applyOptimistic(peer.player, action, position))
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
            val topic = homeRelayTopic
            if (topic.isNotEmpty()) {
                sendHttpPost("$RELAY_BASE/$topic", cmdJson)
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

    private fun resolveHomeRelayAndConnect() {
        ioExecutor.execute {
            val endpoints = listOf("https://api4.ipify.org", "https://ipv4.icanhazip.com")
            var publicIp = ""
            for (ep in endpoints) {
                try {
                    val conn = (URL(ep).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 3000
                        readTimeout = 3000
                    }
                    val str = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText().trim() }
                    conn.disconnect()
                    if (str.split(".").size == 4) {
                        publicIp = str
                        break
                    }
                } catch (_: Exception) {}
            }
            if (publicIp.isEmpty()) return@execute

            val digest = MessageDigest.getInstance("SHA-256").digest("lmc-v2-home:$publicIp".toByteArray(Charsets.UTF_8))
            val hex = digest.joinToString("") { "%02x".format(it) }.take(16)
            val topic = "lmc_v2_home_$hex"
            homeRelayTopic = topic
            startRelaySubscription(topic)
            broadcastPresence(includeRelay = true)
        }
    }

    private fun startRelaySubscription(topic: String) {
        try { relayThread?.interrupt() } catch (_: Exception) {}
        val t = Thread {
            val urlStr = "$RELAY_BASE/$topic/sse?since=1m"
            while (started && homeRelayTopic == topic && !Thread.currentThread().isInterrupted) {
                var conn: HttpURLConnection? = null
                try {
                    conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 5000
                        readTimeout = 60000
                    }
                    BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                        while (started && homeRelayTopic == topic) {
                            val line = reader.readLine() ?: break
                            if (!line.startsWith("data:")) continue
                            val raw = line.substring(5).trim()
                            try {
                                val outer = JSONObject(raw)
                                if (outer.optString("event") == "message") {
                                    val inner = outer.optString("message", "")
                                    if (inner.isNotBlank()) {
                                        handleIncomingJson(inner, "网络同步", "")
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

    private fun startUdp() {
        ioExecutor.execute {
            try {
                val sock = MulticastSocket(null)
                sock.reuseAddress = true
                sock.broadcast = true
                sock.bind(InetSocketAddress(UDP_PORT))
                try { sock.joinGroup(InetAddress.getByName(MULTICAST_GROUP)) } catch (_: Exception) {}
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
        val json = JSONObject().apply {
            put("v", 2)
            put("type", "presence")
            put("deviceId", deviceId)
            put("deviceName", deviceName)
            put("platform", "android")
            put("roomId", currentRoomId)
            put("roomName", currentRoomName)
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

        val topic = homeRelayTopic
        if (includeRelay && topic.isNotEmpty()) {
            sendHttpPost("$RELAY_BASE/$topic", json)
        }
    }

    private fun sendLeave(roomId: String) {
        val json = JSONObject().apply {
            put("v", 2)
            put("type", "leave")
            put("deviceId", deviceId)
            put("roomId", roomId)
            put("ts", System.currentTimeMillis())
        }.toString()
        val targets = linkedSetOf<String>()
        targets.addAll(broadcastAddresses)
        targets.add(MULTICAST_GROUP)
        for (host in targets) sendUdpString(json, host)
        val topic = homeRelayTopic
        if (topic.isNotEmpty()) {
            sendHttpPost("$RELAY_BASE/$topic", json)
        }
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

                    val devName = obj.optString("deviceName", "设备")
                    val roomId = obj.optString("roomId", "").ifBlank { devId }
                    val roomName = obj.optString("roomName", "").ifBlank { "${devName}的房间" }
                    val pktTs = obj.optLong("ts", now)
                    val effIp = senderIp.ifEmpty { obj.optString("ip", "") }
                    val player = PlayerState.fromJson(obj.optJSONObject("player"))

                    var shouldReply = false
                    synchronized(lock) {
                        if (roomId == currentRoomId && devId == roomId && roomName.isNotBlank()) {
                            currentRoomName = roomName
                        }

                        val existing = allPeersById[devId]
                        if (existing != null) {
                            if (pktTs < existing.lastPacketTs) return
                            val mode = if (sourceMode == "局域网直连" || existing.connectionMode == "局域网直连") "局域网直连" else "网络同步"
                            allPeersById[devId] = existing.copy(
                                deviceName = devName,
                                platform = obj.optString("platform", existing.platform),
                                roomId = roomId,
                                roomName = roomName,
                                lanName = peerLanName,
                                ip = effIp.ifEmpty { existing.ip },
                                subnet = peerSubnet,
                                httpPort = obj.optInt("httpPort", existing.httpPort),
                                lastSeen = now,
                                lastPacketTs = pktTs,
                                connectionMode = mode,
                                player = player
                            )
                        } else {
                            allPeersById[devId] = DeviceRecord(
                                deviceId = devId,
                                deviceName = devName,
                                platform = obj.optString("platform", "windows"),
                                roomId = roomId,
                                roomName = roomName,
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
                        }
                    }
                    notifyUpdated()
                    if (shouldReply) ioExecutor.execute { broadcastPresence(includeRelay = true) }
                }

                "leave" -> {
                    val devId = obj.optString("deviceId", "")
                    val leftRoom = obj.optString("roomId", "")
                    val pktTs = obj.optLong("ts", now)
                    var changed = false
                    synchronized(lock) {
                        val existing = allPeersById[devId]
                        if (existing != null && pktTs >= existing.lastPacketTs && existing.roomId == leftRoom) {
                            allPeersById[devId] = existing.copy(
                                roomId = existing.deviceId,
                                roomName = "${existing.deviceName}的房间",
                                lastPacketTs = pktTs
                            )
                            changed = true
                        }
                    }
                    if (changed) notifyUpdated()
                }

                "command" -> {
                    val cmdId = obj.optString("cmdId", "")
                    val pktTs = obj.optLong("ts", now)
                    val roomId = obj.optString("roomId", "")
                    if (cmdId.isEmpty() || pktTs < startupMs - 5000 || roomId != currentRoomId) return
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
                            broadcastPresence(includeRelay = true)
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
            val stale = allPeersById.filterValues { now - it.lastSeen > 14_000 }.keys.toList()
            for (id in stale) { allPeersById.remove(id); changed = true }
        }
        if (changed) notifyUpdated()
    }
}
