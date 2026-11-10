package com.local.lanmediacontroller;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.view.KeyEvent;
import org.json.JSONArray;
import org.json.JSONObject;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class LanBackgroundService extends Service {
    private static final int UDP_PORT = 19888;
    private final String deviceId = "android-" + Build.MODEL.toLowerCase().replace(" ", "-");
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private volatile boolean running = true;
    private DatagramSocket udpSocket;

    @Override
    public void onCreate() {
        super.onCreate();
        startForegroundNotification();
        startUdpLoop();
        startBroadcastLoop();
    }

    private void startForegroundNotification() {
        String channelId = "lan_media_ctrl";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                channelId,
                "LanMediaController",
                NotificationManager.IMPORTANCE_LOW
            );
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                nm.createNotificationChannel(channel);
            }
            Notification notification = new Notification.Builder(this, channelId)
                .setContentTitle("四端媒体控制器运行中")
                .setContentText("局域网房间同步与后台播放控制已开启")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .build();
            startForeground(1001, notification);
        }
    }

    private String getWifiSsid() {
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                WifiInfo info = wm.getConnectionInfo();
                if (info != null && info.getSSID() != null) {
                    String ssid = info.getSSID().replace("\"", "");
                    if (!ssid.isEmpty() && !"<unknown ssid>".equals(ssid)) {
                        return ssid;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return "Android 局域网";
    }

    private List<MediaController> getActiveControllers() {
        try {
            MediaSessionManager msm = (MediaSessionManager) getSystemService(Context.MEDIA_SESSION_SERVICE);
            if (msm != null) {
                ComponentName comp = new ComponentName(this, MediaListenerService.class);
                return msm.getActiveSessions(comp);
            }
        } catch (Exception ignored) {
        }
        return Collections.emptyList();
    }

    private void executeLocalMediaCommand(String action, double positionSec) {
        List<MediaController> controllers = getActiveControllers();
        if (!controllers.isEmpty()) {
            MediaController target = controllers.get(0);
            MediaController.TransportControls tc = target.getTransportControls();
            if ("play".equals(action)) {
                tc.play();
            } else if ("pause".equals(action)) {
                tc.pause();
            } else if ("toggle".equals(action)) {
                PlaybackState pb = target.getPlaybackState();
                boolean playing = (pb != null && pb.getState() == PlaybackState.STATE_PLAYING);
                if (playing) tc.pause(); else tc.play();
            } else if ("prev".equals(action)) {
                tc.skipToPrevious();
            } else if ("next".equals(action)) {
                tc.skipToNext();
            } else if ("seek".equals(action)) {
                tc.seekTo((long) (positionSec * 1000));
                tc.play();
            }
            return;
        }

        AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        if (am != null) {
            int keyCode = KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE;
            if ("prev".equals(action)) keyCode = KeyEvent.KEYCODE_MEDIA_PREVIOUS;
            else if ("next".equals(action)) keyCode = KeyEvent.KEYCODE_MEDIA_NEXT;
            else if ("pause".equals(action)) keyCode = KeyEvent.KEYCODE_MEDIA_PAUSE;
            else if ("play".equals(action)) keyCode = KeyEvent.KEYCODE_MEDIA_PLAY;

            am.dispatchMediaKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, keyCode));
            am.dispatchMediaKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, keyCode));
        }
    }

    private String buildStateJson() {
        try {
            JSONObject playerObj = new JSONObject();
            List<MediaController> controllers = getActiveControllers();
            if (!controllers.isEmpty()) {
                MediaController c = controllers.get(0);
                MediaMetadata meta = c.getMetadata();
                PlaybackState pb = c.getPlaybackState();
                String title = meta != null ? meta.getString(MediaMetadata.METADATA_KEY_TITLE) : "第 1 章";
                long durMs = meta != null ? meta.getLong(MediaMetadata.METADATA_KEY_DURATION) : 300000L;
                long posMs = pb != null ? pb.getPosition() : 0L;
                boolean isPlaying = pb != null && pb.getState() == PlaybackState.STATE_PLAYING;

                playerObj.put("title", title != null ? title : "第 1 章");
                playerObj.put("isPlaying", isPlaying);
                playerObj.put("position", posMs / 1000.0);
                playerObj.put("duration", (durMs > 0 ? durMs : 300000L) / 1000.0);
            } else {
                playerObj.put("title", "第 1 章");
                playerObj.put("isPlaying", false);
                playerObj.put("position", 0);
                playerObj.put("duration", 300);
            }

            JSONObject root = new JSONObject();
            root.put("type", "state");
            root.put("deviceId", deviceId);
            root.put("deviceName", "Android (" + Build.MODEL + ")");
            root.put("platform", "android");
            root.put("lanName", getWifiSsid());
            root.put("httpPort", 19889);
            root.put("player", playerObj);
            root.put("timestamp", System.currentTimeMillis());
            return root.toString();
        } catch (Exception e) {
            return "{}";
        }
    }

    private static class CommandTask implements Runnable {
        private final LanBackgroundService service;
        private final String action;
        private final double pos;

        CommandTask(LanBackgroundService service, String action, double pos) {
            this.service = service;
            this.action = action;
            this.pos = pos;
        }

        @Override
        public void run() {
            service.executeLocalMediaCommand(action, pos);
        }
    }

    private static class UdpWorker implements Runnable {
        private final LanBackgroundService service;

        UdpWorker(LanBackgroundService service) {
            this.service = service;
        }

        @Override
        public void run() {
            service.runUdpLoop();
        }
    }

    private static class BroadcastWorker implements Runnable {
        private final LanBackgroundService service;

        BroadcastWorker(LanBackgroundService service) {
            this.service = service;
        }

        @Override
        public void run() {
            service.runBroadcastLoop();
        }
    }

    private void startUdpLoop() {
        executor.execute(new UdpWorker(this));
    }

    void runUdpLoop() {
        try {
            DatagramSocket sock = new DatagramSocket(UDP_PORT);
            sock.setBroadcast(true);
            udpSocket = sock;
            byte[] buf = new byte[8192];
            while (running) {
                DatagramPacket packet = new DatagramPacket(buf, buf.length);
                sock.receive(packet);
                String msg = new String(packet.getData(), 0, packet.getLength(), StandardCharsets.UTF_8);
                JSONObject json = new JSONObject(msg);
                if ("command".equals(json.optString("type"))) {
                    String targetId = json.optString("targetDeviceId");
                    if (targetId.isEmpty() || targetId.equals(deviceId)) {
                        String action = json.optString("action", "toggle");
                        double pos = json.optDouble("position", 0.0);
                        new Handler(Looper.getMainLooper()).post(new CommandTask(this, action, pos));
                    }
                }
            }
        } catch (Exception ignored) {
        }
    }

    private void startBroadcastLoop() {
        executor.execute(new BroadcastWorker(this));
    }

    void runBroadcastLoop() {
        while (running) {
            try {
                if (udpSocket != null) {
                    byte[] data = buildStateJson().getBytes(StandardCharsets.UTF_8);
                    InetAddress bcast = InetAddress.getByName("255.255.255.255");
                    DatagramPacket packet = new DatagramPacket(data, data.length, bcast, UDP_PORT);
                    udpSocket.send(packet);
                }
            } catch (Exception ignored) {
            }
            try {
                Thread.sleep(2000);
            } catch (InterruptedException ignored) {
            }
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        if (udpSocket != null) {
            udpSocket.close();
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
