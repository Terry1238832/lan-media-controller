package com.local.lanmediacontroller

import android.app.*
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.*
import android.service.notification.NotificationListenerService
import android.view.KeyEvent
import android.media.AudioManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import org.json.JSONArray
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors

/**
 * 通知监听服务：用于获取 Android 系统当前活跃的音乐播放器 MediaSession
 */
class MediaListenerService : NotificationListenerService()

/**
 * Android 后台常驻服务：
 * 1. 获取当前连接的 Wi-Fi 局域网名称 (SSID)
 * 2. 通过 MediaSessionManager + AudioManager 控制本机播放器 (进度条拖动开始、上一章、下一章、播放暂停)
 * 3. 监听 UDP 19888 端口，与 Windows、macOS、iOS 实时互控
 */
class LanBackgroundService : Service() {
    private val udpPort = 19888
    private val deviceId = "android-${Build.MODEL.lowercase().replace(" ", "-")}"
    private val executor = Executors.newCachedThreadPool()
    @Volatile private var running = true
    private var udpSocket: DatagramSocket? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
        startUdpLoop()
        startBroadcastLoop()
    }

    private fun startForegroundNotification() {
        val channelId = "lan_media_ctrl"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "四端媒体后台控制",
                NotificationManager.IMPORTANCE_LOW
            )
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("四端媒体控制器运行中")
                .setContentText("正在局域网内同步播放控制")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("四端媒体控制器运行中")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .build()
        }
        startForeground(1001, notification)
    }

    private fun getWifiSsid(): String {
        return try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val ssid = wm.connectionInfo?.ssid?.replace("\"", "") ?: "Android 局域网"
            if (ssid == "<unknown ssid>" || ssid.isBlank()) "Android 局域网" else ssid
        } catch (e: Exception) {
            "Android 局域网"
        }
    }

    private fun getActiveControllers(): List<MediaController> {
        return try {
            val msm = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val comp = ComponentName(this, MediaListenerService::class.java)
            msm.getActiveSessions(comp)
        } catch (e: SecurityException) {
            emptyList()
        }
    }

    private fun executeLocalMediaCommand(action: String, playerId: String?, positionSec: Double) {
        val controllers = getActiveControllers()
        val target = controllers.firstOrNull { it.packageName == playerId } ?: controllers.firstOrNull()

        if (target != null) {
            val tc = target.transportControls
            when (action) {
                "play" -> tc.play()
                "pause" -> tc.pause()
                "toggle" -> {
                    val isPlaying = target.playbackState?.state == PlaybackState.STATE_PLAYING
                    if (isPlaying) tc.pause() else tc.play()
                }
                "prev" -> tc.skipToPrevious()
                "next" -> tc.skipToNext()
                "seek" -> {
                    tc.seekTo((positionSec * 1000).toLong())
                    tc.play() // 拖动进度条自动开始播放
                }
            }
            return
        }

        // 兜底方案：通过 AudioManager 派发系统硬件多媒体按键
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val keyCode = when (action) {
            "prev" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        }
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
    }

    private fun buildStateJson(): String {
        val controllers = getActiveControllers()
        val playersArr = JSONArray()

        if (controllers.isNotEmpty()) {
            for (c in controllers) {
                val meta = c.metadata
                val pb = c.playbackState
                val title = meta?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: "当前媒体章节"
                val durMs = meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 300000L
                val posMs = pb?.position ?: 0L
                val isPlaying = (pb?.state == PlaybackState.STATE_PLAYING)

                val pObj = JSONObject().apply {
                    put("playerId", c.packageName)
                    put("appName", "Android (${c.packageName.substringAfterLast('.')})")
                    put("title", title)
                    put("isPlaying", isPlaying)
                    put("position", posMs / 1000.0)
                    put("duration", (if (durMs > 0) durMs else 300000L) / 1000.0)
                }
                playersArr.put(pObj)
            }
        } else {
            playersArr.put(JSONObject().apply {
                put("playerId", "android-system")
                put("appName", "Android 播放器 (${Build.MODEL})")
                put("title", "系统媒体控制")
                put("isPlaying", false)
                put("position", 0)
                put("duration", 300)
            })
        }

        return JSONObject().apply {
            put("type", "state")
            put("deviceId", deviceId)
            put("deviceName", "Android (${Build.MODEL})")
            put("platform", "android")
            put("lanName", getWifiSsid())
            put("httpPort", 19889)
            put("players", playersArr)
            put("timestamp", System.currentTimeMillis())
        }.toString()
    }

    private fun startUdpLoop() {
        executor.execute {
            try {
                val sock = DatagramSocket(udpPort)
                sock.broadcast = true
                udpSocket = sock
                val buf = ByteArray(8192)
                while (running) {
                    val packet = DatagramPacket(buf, buf.size)
                    sock.receive(packet)
                    val msg = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    val json = JSONObject(msg)
                    if (json.optString("type") == "command") {
                        val targetId = json.optString("targetDeviceId")
                        if (targetId.isEmpty() || targetId == deviceId) {
                            val action = json.optString("action", "toggle")
                            val playerId = json.optString("playerId")
                            val pos = json.optDouble("position", 0.0)
                            Handler(Looper.getMainLooper()).post {
                                executeLocalMediaCommand(action, playerId, pos)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun startBroadcastLoop() {
        executor.execute {
            while (running) {
                try {
                    val data = buildStateJson().toByteArray(Charsets.UTF_8)
                    val bcast = InetAddress.getByName("255.255.255.255")
                    val packet = DatagramPacket(data, data.size, bcast, udpPort)
                    udpSocket?.send(packet)
                } catch (e: Exception) {}
                Thread.sleep(2000)
            }
        }
    }

    override fun onDestroy() {
        running = false
        udpSocket?.close()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

/**
 * 主界面 Activity：启动后台服务并加载统一四端控制页面
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val serviceIntent = Intent(this, LanBackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        val webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            webViewClient = WebViewClient()
            // 可加载本地打包的 ui/index.html 或局域网主机地址
            loadUrl("file:///android_asset/index.html")
        }
        setContentView(webView)
    }
}
