package com.local.lanmediacontroller

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import kotlin.math.max
import kotlin.math.min

class MainActivity : Activity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cards = LinkedHashMap<String, PlayerCardHolder>()

    private lateinit var lanNameText: TextView
    private lateinit var permissionBanner: LinearLayout
    private lateinit var deviceNameEdit: EditText
    private lateinit var roomRoleBadge: TextView
    private lateinit var currentRoomNameText: TextView
    private lateinit var returnOwnRoomBtn: Button
    private lateinit var emptyRoomsHint: TextView
    private lateinit var availableRoomsContainer: LinearLayout
    private lateinit var deviceCountText: TextView
    private lateinit var playersContainer: LinearLayout

    private val syncListener: () -> Unit = {
        mainHandler.post { refreshUI() }
    }

    private val ticker = object : Runnable {
        override fun run() {
            val now = System.currentTimeMillis()
            for (card in cards.values) card.tickTimeline(now)
            mainHandler.postDelayed(this, 500)
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun roundedBg(colorHex: String, radiusDp: Int, strokeHex: String? = null, strokeDp: Int = 1): GradientDrawable {
        return GradientDrawable().apply {
            setColor(Color.parseColor(colorHex))
            cornerRadius = dp(radiusDp).toFloat()
            if (strokeHex != null) setStroke(dp(strokeDp), Color.parseColor(strokeHex))
        }
    }

    private fun platformColors(platform: String): Pair<String, String> = when (platform.lowercase()) {
        "windows" -> "#1E3A5F" to "#60A5FA"
        "macos" -> "#332152" to "#C084FC"
        "ios" -> "#4C1D3D" to "#F472B6"
        "android" -> "#143C33" to "#34D399"
        else -> "#1E293B" to "#CBD5E1"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val svcIntent = Intent(this, LanSyncService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(svcIntent)
            else startService(svcIntent)
        } catch (_: Exception) {}
        SyncEngine.start(applicationContext)

        buildLayout()
        deviceNameEdit.setText(SyncEngine.deviceName)
        SyncEngine.addListener(syncListener)
        refreshUI()
        mainHandler.postDelayed(ticker, 500)
    }

    override fun onResume() {
        super.onResume()
        AndroidMediaController.tryBindSessions(applicationContext)
        refreshUI()
    }

    override fun onDestroy() {
        SyncEngine.removeListener(syncListener)
        mainHandler.removeCallbacks(ticker)
        super.onDestroy()
    }

    private fun buildLayout() {
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#0B1120"))
            isFillViewport = true
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(20), dp(16), dp(28))
        }
        scroll.addView(root)

        // Header
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(14)
            }
        }
        val titleCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        titleCol.addView(TextView(this).apply {
            text = "四端局域网媒体控制器"
            textSize = 17f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#F8FAFC"))
        })
        titleCol.addView(TextView(this).apply {
            text = "Native Android · 启动自动开房"
            textSize = 11f
            setTextColor(Color.parseColor("#94A3B8"))
        })
        header.addView(titleCol)

        lanNameText = TextView(this).apply {
            text = "正在检测局域网..."
            textSize = 12f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#E2E8F0"))
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = roundedBg("#162036", 16, "#24334F")
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        header.addView(lanNameText)
        root.addView(header)

        // Notification Listener Permission Banner
        permissionBanner = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = roundedBg("#2B1F0F", 12, "#D97706")
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(12)
            }
            addView(TextView(context).apply {
                text = "授权“通知使用权”后可实时读取 QQ音乐/网易云 歌名与进度条"
                textSize = 12f
                setTextColor(Color.parseColor("#FDE68A"))
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(Button(context).apply {
                text = "去开启"
                textSize = 12f
                setTextColor(Color.WHITE)
                background = roundedBg("#D97706", 8)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                setOnClickListener {
                    try { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) } catch (_: Exception) {}
                }
            })
        }
        root.addView(permissionBanner)

        // Identity & Auto-Host Room Panel
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = roundedBg("#162036", 16, "#24334F")
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(14)
            }
        }

        val idHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            }
            addView(TextView(context).apply {
                text = "本机设备名称"
                textSize = 12f
                setTextColor(Color.parseColor("#94A3B8"))
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(context).apply {
                text = "Android"
                textSize = 11f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#34D399"))
                setPadding(dp(9), dp(3), dp(9), dp(3))
                background = roundedBg("#143C33", 7)
            })
        }
        panel.addView(idHeader)

        val nameRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(12)
            }
        }
        deviceNameEdit = EditText(this).apply {
            hint = "输入设备名称"
            setHintTextColor(Color.parseColor("#64748B"))
            setTextColor(Color.parseColor("#F8FAFC"))
            textSize = 14f
            isSingleLine = true
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = roundedBg("#090E1A", 10, "#24334F")
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8)
            }
        }
        val saveBtn = Button(this).apply {
            text = "保存名称"
            textSize = 13f
            setTextColor(Color.WHITE)
            background = roundedBg("#26344E", 10)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            setOnClickListener {
                SyncEngine.saveDeviceName(deviceNameEdit.text.toString())
                Toast.makeText(this@MainActivity, "设备名称与房间名已更新", Toast.LENGTH_SHORT).show()
            }
        }
        nameRow.addView(deviceNameEdit)
        nameRow.addView(saveBtn)
        panel.addView(nameRow)

        // Divider
        panel.addView(View(this).apply {
            setBackgroundColor(Color.parseColor("#24334F"))
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)).apply {
                bottomMargin = dp(12)
            }
        })

        // Current Room Banner
        val curRoomRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(12)
            }
        }
        val curRoomCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val curLabelRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        curLabelRow.addView(TextView(this).apply {
            text = "当前所在房间"
            textSize = 11f
            setTextColor(Color.parseColor("#94A3B8"))
        })
        roomRoleBadge = TextView(this).apply {
            text = "默认已开房"
            textSize = 10f
            setTypeface(null, Typeface.BOLD)
            setPadding(dp(7), dp(2), dp(7), dp(2))
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(8)
            }
        }
        curLabelRow.addView(roomRoleBadge)
        curRoomCol.addView(curLabelRow)

        currentRoomNameText = TextView(this).apply {
            text = "我的房间"
            textSize = 18f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#F8FAFC"))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        curRoomCol.addView(currentRoomNameText)
        curRoomRow.addView(curRoomCol)

        returnOwnRoomBtn = Button(this).apply {
            text = "回到我的房间"
            textSize = 12f
            setTextColor(Color.WHITE)
            background = roundedBg("#DC2626", 9)
            setPadding(dp(12), dp(7), dp(12), dp(7))
            visibility = View.GONE
            setOnClickListener { SyncEngine.returnToOwnRoom() }
        }
        curRoomRow.addView(returnOwnRoomBtn)
        panel.addView(curRoomRow)

        // Discoverable Other Rooms (One-Click Join)
        panel.addView(TextView(this).apply {
            text = "可加入的其他设备房间"
            textSize = 12f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#94A3B8"))
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            }
        })
        emptyRoomsHint = TextView(this).apply {
            text = "正在自动发现其他设备房间，对方打开软件后可直接点击加入..."
            textSize = 12f
            setTextColor(Color.parseColor("#64748B"))
        }
        panel.addView(emptyRoomsHint)

        availableRoomsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        panel.addView(availableRoomsContainer)
        root.addView(panel)

        // Section Header
        val secRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(10)
            }
        }
        secRow.addView(TextView(this).apply {
            text = "房间内设备播放器"
            textSize = 13f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#94A3B8"))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        deviceCountText = TextView(this).apply {
            text = "共 1 台设备在线"
            textSize = 12f
            setTextColor(Color.parseColor("#64748B"))
        }
        secRow.addView(deviceCountText)
        root.addView(secRow)

        playersContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(playersContainer)

        setContentView(scroll)
    }

    private fun refreshUI() {
        lanNameText.text = SyncEngine.displayedLanName
        permissionBanner.visibility = if (AndroidMediaController.isNotificationAccessGranted(this)) View.GONE else View.VISIBLE

        currentRoomNameText.text = SyncEngine.currentRoomName
        val hostingOwn = SyncEngine.isHostingOwnRoom
        roomRoleBadge.text = if (hostingOwn) "默认已开房" else "已加入对方房间"
        roomRoleBadge.background = roundedBg(if (hostingOwn) "#143C33" else "#1E3A5F", 6)
        roomRoleBadge.setTextColor(Color.parseColor(if (hostingOwn) "#34D399" else "#60A5FA"))
        returnOwnRoomBtn.visibility = if (hostingOwn) View.GONE else View.VISIBLE

        val rooms = SyncEngine.getAvailableRoomsSnapshot()
        availableRoomsContainer.removeAllViews()
        if (rooms.isEmpty()) {
            emptyRoomsHint.visibility = View.VISIBLE
        } else {
            emptyRoomsHint.visibility = View.GONE
            for (room in rooms) {
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                    background = roundedBg("#0D1526", 11, "#24334F")
                    layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                        bottomMargin = dp(8)
                    }
                }
                val (pBg, pFg) = platformColors(room.hostPlatform)
                row.addView(TextView(this).apply {
                    text = FormatUtil.platformDisplayName(room.hostPlatform)
                    textSize = 11f
                    setTypeface(null, Typeface.BOLD)
                    setTextColor(Color.parseColor(pFg))
                    background = roundedBg(pBg, 7)
                    setPadding(dp(8), dp(3), dp(8), dp(3))
                })
                val infoCol = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                        marginStart = dp(10)
                        marginEnd = dp(8)
                    }
                }
                infoCol.addView(TextView(this).apply {
                    text = room.roomName
                    textSize = 14f
                    setTypeface(null, Typeface.BOLD)
                    setTextColor(Color.parseColor("#F8FAFC"))
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                })
                infoCol.addView(TextView(this).apply {
                    text = "${room.memberCount} 台设备 · ${if (room.isLanDirect) "局域网直连" else "网络发现"}"
                    textSize = 11f
                    setTextColor(Color.parseColor("#94A3B8"))
                })
                row.addView(infoCol)
                row.addView(Button(this).apply {
                    text = "加入"
                    textSize = 13f
                    setTypeface(null, Typeface.BOLD)
                    setTextColor(Color.WHITE)
                    background = roundedBg("#3B82F6", 9)
                    setPadding(dp(14), dp(6), dp(14), dp(6))
                    setOnClickListener { SyncEngine.joinRoom(room) }
                })
                availableRoomsContainer.addView(row)
            }
        }

        val peers = SyncEngine.getRoomPeersSnapshot()
        deviceCountText.text = "共 ${1 + peers.size} 台设备在线"

        val desired = ArrayList<CardData>()
        desired.add(CardData(SyncEngine.deviceId, SyncEngine.deviceName, "android", "本机", SyncEngine.localPlayer))
        for (p in peers) {
            desired.add(CardData(p.deviceId, p.deviceName, p.platform, p.connectionMode, p.player))
        }

        val desiredIds = desired.map { it.id }.toSet()
        val toRemove = cards.keys.filter { it !in desiredIds }
        for (id in toRemove) {
            cards.remove(id)?.let { playersContainer.removeView(it.root) }
        }

        val now = System.currentTimeMillis()
        for (item in desired) {
            val holder = cards.getOrPut(item.id) {
                val created = PlayerCardHolder(item.id)
                playersContainer.addView(created.root)
                created
            }
            holder.update(item, now)
        }
    }

    private data class CardData(
        val id: String,
        val name: String,
        val platform: String,
        val connMode: String,
        val player: PlayerState
    )

    private inner class PlayerCardHolder(private val targetId: String) {
        val root: LinearLayout
        private val platformBadge: TextView
        private val nameText: TextView
        private val connBadge: TextView
        private val appBadge: TextView
        private val trackText: TextView
        private val seekBar: SeekBar
        private val posText: TextView
        private val durText: TextView
        private val toggleBtn: Button

        private var lastPlayer = PlayerState()
        private var isDragging = false

        init {
            root = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), dp(14), dp(14), dp(14))
                background = roundedBg("#162036", 16, "#24334F")
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = dp(12)
                }
            }

            val topRow = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = dp(8)
                }
            }
            platformBadge = TextView(this@MainActivity).apply {
                textSize = 11f
                setTypeface(null, Typeface.BOLD)
                setPadding(dp(8), dp(3), dp(8), dp(3))
            }
            nameText = TextView(this@MainActivity).apply {
                textSize = 15f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#F8FAFC"))
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(8)
                    marginEnd = dp(6)
                }
            }
            connBadge = TextView(this@MainActivity).apply {
                textSize = 10f
                setPadding(dp(6), dp(2), dp(6), dp(2))
            }
            appBadge = TextView(this@MainActivity).apply {
                textSize = 11f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#FACC15"))
                background = roundedBg("#2E2A16", 6)
                setPadding(dp(8), dp(2), dp(8), dp(2))
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    marginStart = dp(6)
                }
            }
            topRow.addView(platformBadge)
            topRow.addView(nameText)
            topRow.addView(connBadge)
            topRow.addView(appBadge)
            root.addView(topRow)

            trackText = TextView(this@MainActivity).apply {
                textSize = 13f
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = dp(8)
                }
            }
            root.addView(trackText)

            // Control 1: Progress Bar (seek + play on release)
            seekBar = SeekBar(this@MainActivity).apply {
                max = 300
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(sb: SeekBar?, progress: Int, fromUser: Boolean) {
                        if (fromUser) posText.text = FormatUtil.formatSeconds(progress.toDouble())
                    }
                    override fun onStartTrackingTouch(sb: SeekBar?) { isDragging = true }
                    override fun onStopTrackingTouch(sb: SeekBar?) {
                        isDragging = false
                        val sec = (sb?.progress ?: 0).toDouble()
                        SyncEngine.sendCommand(targetId, "seek", sec)
                    }
                })
            }
            root.addView(seekBar)

            val timeRow = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = dp(10)
                }
            }
            posText = TextView(this@MainActivity).apply {
                textSize = 11f
                typeface = Typeface.MONOSPACE
                setTextColor(Color.parseColor("#94A3B8"))
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            durText = TextView(this@MainActivity).apply {
                textSize = 11f
                typeface = Typeface.MONOSPACE
                setTextColor(Color.parseColor("#94A3B8"))
            }
            timeRow.addView(posText)
            timeRow.addView(durText)
            root.addView(timeRow)

            // Controls 2, 3, 4: Previous, Play/Pause, Next (ONLY these 4 controls total!)
            val btnRow = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
            val prevBtn = Button(this@MainActivity).apply {
                text = "⏮ 上一章"
                textSize = 13f
                setTextColor(Color.WHITE)
                background = roundedBg("#24334E", 10)
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(8) }
                setOnClickListener { SyncEngine.sendCommand(targetId, "prev", 0.0) }
            }
            toggleBtn = Button(this@MainActivity).apply {
                text = "▶ 播放"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.WHITE)
                background = roundedBg("#3B82F6", 10)
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.15f).apply { marginEnd = dp(8) }
                setOnClickListener { SyncEngine.sendCommand(targetId, "toggle", 0.0) }
            }
            val nextBtn = Button(this@MainActivity).apply {
                text = "⏭ 下一章"
                textSize = 13f
                setTextColor(Color.WHITE)
                background = roundedBg("#24334E", 10)
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                setOnClickListener { SyncEngine.sendCommand(targetId, "next", 0.0) }
            }
            btnRow.addView(prevBtn)
            btnRow.addView(toggleBtn)
            btnRow.addView(nextBtn)
            root.addView(btnRow)
        }

        fun update(item: CardData, nowMs: Long) {
            lastPlayer = item.player
            platformBadge.text = FormatUtil.platformDisplayName(item.platform)
            val (bg, fg) = platformColors(item.platform)
            platformBadge.background = roundedBg(bg, 7)
            platformBadge.setTextColor(Color.parseColor(fg))

            nameText.text = item.name
            connBadge.text = item.connMode
            val isLan = item.connMode == "局域网直连"
            connBadge.background = roundedBg(if (isLan) "#143C33" else "#222E44", 6)
            connBadge.setTextColor(Color.parseColor(if (isLan) "#34D399" else "#94A3B8"))

            if (item.player.appName.isNotBlank()) {
                appBadge.text = item.player.appName
                appBadge.visibility = View.VISIBLE
            } else {
                appBadge.visibility = View.GONE
            }

            trackText.text = (if (item.player.isPlaying) "● " else "○ ") + item.player.displayTrackLine()
            trackText.setTextColor(Color.parseColor(if (item.player.hasMedia) "#E2E8F0" else "#64748B"))

            toggleBtn.text = if (item.player.isPlaying) "⏸ 暂停" else "▶ 播放"
            toggleBtn.background = roundedBg(if (item.player.isPlaying) "#10B981" else "#3B82F6", 10)
            root.background = roundedBg("#162036", 16, if (item.player.isPlaying) "#10B981" else "#24334F")

            tickTimeline(nowMs)
        }

        fun tickTimeline(nowMs: Long) {
            if (isDragging) return
            val maxDur = max(1, (if (lastPlayer.duration > 0) lastPlayer.duration else 300.0).toInt())
            val pos = min(maxDur, lastPlayer.livePosition(nowMs).toInt())
            seekBar.max = maxDur
            seekBar.progress = pos
            posText.text = FormatUtil.formatSeconds(pos.toDouble())
            durText.text = if (lastPlayer.duration > 0) FormatUtil.formatSeconds(lastPlayer.duration) else "--:--"
        }
    }
}
