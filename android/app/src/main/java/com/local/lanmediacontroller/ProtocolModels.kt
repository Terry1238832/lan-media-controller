package com.local.lanmediacontroller

import org.json.JSONObject
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

data class PlayerState(
    val appName: String = "",
    val title: String = "",
    val artist: String = "",
    val isPlaying: Boolean = false,
    val position: Double = 0.0,
    val duration: Double = 0.0,
    val hasMedia: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis()
) {
    fun livePosition(nowMs: Long): Double {
        if (!hasMedia && duration <= 0.0) return 0.0
        val base = max(0.0, position)
        if (!isPlaying) return if (duration > 0.0) min(duration, base) else base
        val elapsed = max(0.0, (nowMs - updatedAt) / 1000.0)
        val cur = base + elapsed
        return if (duration > 0.0) min(duration, cur) else cur
    }

    fun displayTrackLine(): String {
        if (!hasMedia && title.isBlank() && appName.isBlank()) return "暂无正在播放的媒体"
        val t = title.trim()
        val a = artist.trim()
        val main = when {
            t.isNotEmpty() && a.isNotEmpty() -> "$t - $a"
            t.isNotEmpty() -> t
            a.isNotEmpty() -> a
            else -> ""
        }
        return if (main.isNotEmpty()) main else if (isPlaying) "正在播放" else "已暂停"
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("appName", appName)
        put("title", title)
        put("artist", artist)
        put("isPlaying", isPlaying)
        put("position", position)
        put("duration", duration)
        put("hasMedia", hasMedia)
        put("updatedAt", updatedAt)
    }

    companion object {
        fun fromJson(obj: JSONObject?): PlayerState {
            if (obj == null) return PlayerState()
            return PlayerState(
                appName = obj.optString("appName", ""),
                title = obj.optString("title", ""),
                artist = obj.optString("artist", ""),
                isPlaying = obj.optBoolean("isPlaying", false),
                position = obj.optDouble("position", 0.0).takeIf { !it.isNaN() } ?: 0.0,
                duration = obj.optDouble("duration", 0.0).takeIf { !it.isNaN() } ?: 0.0,
                hasMedia = obj.optBoolean("hasMedia", false),
                updatedAt = obj.optLong("updatedAt", System.currentTimeMillis())
            )
        }
    }
}

data class DeviceRecord(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val roomId: String,
    val roomName: String,
    val lanName: String,
    val ip: String,
    val subnet: String,
    val httpPort: Int,
    val lastSeen: Long,
    val lastPacketTs: Long,
    val connectionMode: String,
    val player: PlayerState
)

data class AvailableRoom(
    val roomId: String,
    val roomName: String,
    val hostPlatform: String,
    val memberCount: Int,
    val isLanDirect: Boolean
)

object FormatUtil {
    fun formatSeconds(seconds: Double): String {
        val clamped = max(0, floor(seconds).toInt())
        val h = clamped / 3600
        val m = (clamped % 3600) / 60
        val s = clamped % 60
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s) else String.format("%02d:%02d", m, s)
    }

    fun platformDisplayName(platform: String): String = when (platform.lowercase()) {
        "windows" -> "Windows"
        "macos" -> "macOS"
        "ios" -> "iOS"
        "android" -> "Android"
        else -> platform
    }
}
