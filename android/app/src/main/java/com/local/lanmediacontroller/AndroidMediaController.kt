package com.local.lanmediacontroller

import android.content.ComponentName
import android.content.Context
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.KeyEvent
import kotlin.math.max
import kotlin.math.min

class MediaNotificationListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        AndroidMediaController.onNotificationListenerBound(applicationContext)
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        AndroidMediaController.onNotificationListenerUnbound()
    }
}

object AndroidMediaController {
    @Volatile
    private var appContext: Context? = null
    @Volatile
    private var activeController: MediaController? = null
    @Volatile
    private var sessionManager: MediaSessionManager? = null
    @Volatile
    private var listenerBound = false

    private var stateCallback: ((PlayerState) -> Unit)? = null

    private val controllerCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) {
            refreshState()
        }

        override fun onMetadataChanged(metadata: MediaMetadata?) {
            refreshState()
        }
    }

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        attachBestController(controllers)
        refreshState()
    }

    fun init(context: Context, onState: (PlayerState) -> Unit) {
        appContext = context.applicationContext
        stateCallback = onState
        tryBindSessions(context.applicationContext)
    }

    fun isNotificationAccessGranted(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
        return enabled.contains(context.packageName)
    }

    fun onNotificationListenerBound(context: Context) {
        listenerBound = true
        appContext = context.applicationContext
        tryBindSessions(context.applicationContext)
    }

    fun onNotificationListenerUnbound() {
        listenerBound = false
    }

    fun tryBindSessions(context: Context) {
        if (!isNotificationAccessGranted(context)) return
        try {
            val mgr = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager ?: return
            sessionManager = mgr
            val comp = ComponentName(context, MediaNotificationListenerService::class.java)
            try { mgr.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
            mgr.addOnActiveSessionsChangedListener(sessionsListener, comp)
            val list = mgr.getActiveSessions(comp)
            attachBestController(list)
            refreshState()
        } catch (_: Exception) {}
    }

    private fun attachBestController(controllers: List<MediaController>?) {
        val best = pickBestController(controllers)
        if (best === activeController) return
        try { activeController?.unregisterCallback(controllerCallback) } catch (_: Exception) {}
        activeController = best
        try { activeController?.registerCallback(controllerCallback) } catch (_: Exception) {}
    }

    private fun pickBestController(controllers: List<MediaController>?): MediaController? {
        if (controllers.isNullOrEmpty()) return null
        val playing = controllers.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
        if (playing != null) return playing
        return controllers.firstOrNull { it.metadata != null } ?: controllers.firstOrNull()
    }

    fun refreshState() {
        val ctx = appContext ?: return
        if (activeController == null && isNotificationAccessGranted(ctx)) {
            tryBindSessions(ctx)
        }
        val ctrl = activeController
        if (ctrl == null) {
            stateCallback?.invoke(PlayerState(hasMedia = false, updatedAt = System.currentTimeMillis()))
            return
        }

        try {
            val pkg = ctrl.packageName ?: ""
            val appName = friendlyAppName(ctx, pkg)
            val meta = ctrl.metadata
            val pb = ctrl.playbackState

            val title = (meta?.getString(MediaMetadata.METADATA_KEY_TITLE)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: "").trim()
            val artist = (meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: "").trim()
            val durationMs = meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
            val durationSec = max(0.0, durationMs / 1000.0)

            val isPlaying = pb?.state == PlaybackState.STATE_PLAYING
            var posSec = max(0.0, (pb?.position ?: 0L) / 1000.0)
            if (isPlaying && pb != null && pb.lastPositionUpdateTime > 0) {
                val deltaSec = max(0.0, (SystemClock.elapsedRealtime() - pb.lastPositionUpdateTime) / 1000.0)
                val speed = if (pb.playbackSpeed > 0f) pb.playbackSpeed.toDouble() else 1.0
                posSec += deltaSec * speed
                if (durationSec > 0.0) posSec = min(durationSec, posSec)
            }

            val st = PlayerState(
                appName = appName,
                title = title,
                artist = artist,
                isPlaying = isPlaying,
                position = posSec,
                duration = durationSec,
                hasMedia = title.isNotEmpty() || appName.isNotEmpty() || durationSec > 0.0 || isPlaying,
                updatedAt = System.currentTimeMillis()
            )
            stateCallback?.invoke(st)
        } catch (_: Exception) {}
    }

    fun executeCommand(action: String, positionSeconds: Double = 0.0) {
        val ctx = appContext ?: return
        if (activeController == null && isNotificationAccessGranted(ctx)) {
            tryBindSessions(ctx)
        }
        val ctrl = activeController
        if (ctrl != null) {
            try {
                val tc = ctrl.transportControls
                when (action) {
                    "play" -> tc.play()
                    "pause" -> tc.pause()
                    "toggle" -> {
                        if (ctrl.playbackState?.state == PlaybackState.STATE_PLAYING) tc.pause() else tc.play()
                    }
                    "prev" -> tc.skipToPrevious()
                    "next" -> tc.skipToNext()
                    "seek" -> {
                        tc.seekTo(max(0L, (positionSeconds * 1000.0).toLong()))
                        tc.play()
                    }
                }
                return
            } catch (_: Exception) {}
        }

        // Fallback via AudioManager hardware media key injection
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val keyCode = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "toggle" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "prev" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            else -> return
        }
        val now = SystemClock.uptimeMillis()
        am.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        am.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, keyCode, 0))
    }

    private fun friendlyAppName(context: Context, pkg: String): String {
        val lower = pkg.lowercase()
        if (lower.contains("qqmusic")) return "QQ音乐"
        if (lower.contains("netease.cloudmusic")) return "网易云音乐"
        if (lower.contains("spotify")) return "Spotify"
        if (lower.contains("kugou")) return "酷狗音乐"
        if (lower.contains("kuwo")) return "酷我音乐"
        if (lower.contains("luna.music") || lower.contains("soda")) return "汽水音乐"
        if (lower.contains("bili")) return "哔哩哔哩"
        if (lower.contains("youtube")) return "YouTube"
        if (lower.contains("apple.android.music")) return "Apple Music"
        return try {
            val pm = context.packageManager
            val ai = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(ai).toString()
        } catch (_: Exception) {
            pkg
        }
    }
}
