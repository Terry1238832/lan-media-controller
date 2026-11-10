#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建 100% 符合 Apple TN1150 规范的 GPT + HFS+ (H+) macOS .dmg 磁盘映像
内含：
1. 原生 Cocoa (NSWindow + WKWebView) 桌面应用 LanMediaController.app（带自定义图标）
2. 原生 HFS+ Applications 符号链接（支持将 LanMediaController.app 直接拖拽到 Applications 安装）
3. macOS MediaRemote.framework + CGEventPost (NX_KEYTYPE_PLAY/NEXT/PREV) + coreaudiod/pmset 实时系统媒体识别与控制
   （原生识别并控制 macOS 上的 QQ音乐、网易云音乐、Spotify、Apple Music、浏览器等所有播放器）
"""

import os
import struct
import uuid
import zlib
import plistlib

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST_DIR = os.path.join(BASE_DIR, "dist")
ASSETS_DIR = os.path.join(BASE_DIR, "assets")
os.makedirs(DIST_DIR, exist_ok=True)

HFS_TIME = 3845000000  # Seconds since 1904-01-01


def build_macos_app_files():
    with open(os.path.join(BASE_DIR, "desktop", "server.js"), "rb") as f:
        server_js = f.read()
    with open(os.path.join(BASE_DIR, "desktop", "server.py"), "rb") as f:
        server_py = f.read()
    with open(os.path.join(BASE_DIR, "ui", "index.html"), "rb") as f:
        index_html = f.read()
    with open(os.path.join(ASSETS_DIR, "AppIcon.icns"), "rb") as f:
        app_icns = f.read()

    info_plist = plistlib.dumps({
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": "四端媒体控制器",
        "CFBundleExecutable": "LanMediaController",
        "CFBundleIconFile": "AppIcon",
        "CFBundleIdentifier": "com.local.lanmediacontroller",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "LanMediaController",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.5",
        "CFBundleVersion": "6",
        "LSMinimumSystemVersion": "10.15",
        "NSHighResolutionCapable": True,
        "NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": True
        },
        "NSLocalNetworkUsageDescription": "用于在局域网内发现并同步控制四端播放器",
        "NSAppleEventsUsageDescription": "用于读取并控制 macOS 音乐播放器（QQ音乐、网易云音乐、Apple Music、Spotify）播放、暂停、上下章与进度跳转"
    })

    mac_media_helper_sh = ("""#!/bin/bash
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
MODE="$1"

if [ "$MODE" = "cmd" ]; then
  ACTION="$2"
  POS="${3:-0}"
  /usr/bin/env -u __CFBundleIdentifier /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Cocoa");
    var b = $.NSBundle.bundleWithPath($("/System/Library/PrivateFrameworks/MediaRemote.framework"));
    if (b && !b.isNil()) b.load;
    try {
      ObjC.bindFunction("MRMediaRemoteSendCommand", ["bool", ["int", "id"]]);
      ObjC.bindFunction("MRMediaRemoteSetElapsedTime", ["void", ["double"]]);
    } catch (e) {}

    var act = "'"$ACTION"'";
    var pos = Number("'"$POS"'") || 0;
    try {
      if (act === "play") $.MRMediaRemoteSendCommand(0, null);
      else if (act === "pause") $.MRMediaRemoteSendCommand(1, null);
      else if (act === "toggle") $.MRMediaRemoteSendCommand(2, null);
      else if (act === "next") $.MRMediaRemoteSendCommand(4, null);
      else if (act === "prev") $.MRMediaRemoteSendCommand(5, null);
      else if (act === "seek") {
        $.MRMediaRemoteSetElapsedTime(pos);
        $.MRMediaRemoteSendCommand(0, null);
      }
      $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.18));
    } catch (e) {}
  ' >/dev/null 2>&1
  exit 0
fi

PARENT_PID="$2"
STATE_FILE="/tmp/lmc_mac_media_state.json"

while true; do
  if [ -n "$PARENT_PID" ] && ! kill -0 "$PARENT_PID" 2>/dev/null; then
    exit 0
  fi

  PMSET_OUT=$(/usr/bin/pmset -g assertions 2>/dev/null)
  PMSET_PLAYING=0
  PMSET_APP=""
  if echo "$PMSET_OUT" | grep -qiE "QQMusic|QQ音乐"; then
    PMSET_PLAYING=1
    PMSET_APP="QQ音乐"
  elif echo "$PMSET_OUT" | grep -qiE "NeteaseMusic|网易云"; then
    PMSET_PLAYING=1
    PMSET_APP="网易云音乐"
  elif echo "$PMSET_OUT" | grep -qiE "Spotify"; then
    PMSET_PLAYING=1
    PMSET_APP="Spotify"
  elif echo "$PMSET_OUT" | grep -qiE "Playing audio|audio-out|coreaudiod.*PreventUserIdleSystemSleep"; then
    PMSET_PLAYING=1
  fi

  JSON_OUT=$(/usr/bin/env -u __CFBundleIdentifier /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Cocoa");
    ObjC.import("CoreGraphics");
    var b = $.NSBundle.bundleWithPath($("/System/Library/PrivateFrameworks/MediaRemote.framework"));
    if (b && !b.isNil()) b.load;

    var pmsetPlaying = Number("'"$PMSET_PLAYING"'") === 1;
    var pmsetApp = "'"$PMSET_APP"'";

    var appName = "";
    var title = "";
    var artist = "";
    var isPlaying = null;
    var duration = 0;
    var position = -1;

    try {
      var reqCls = $.NSClassFromString($("MRNowPlayingRequest"));
      if (reqCls && !reqCls.isNil()) {
        if (reqCls.respondsToSelector("localIsPlaying")) {
          isPlaying = Boolean(reqCls.localIsPlaying);
        }
        if (reqCls.respondsToSelector("localNowPlayingPlayerPath")) {
          var ppath = reqCls.localNowPlayingPlayerPath;
          if (ppath && !ppath.isNil() && ppath.respondsToSelector("client")) {
            var client = ppath.client;
            if (client && !client.isNil()) {
              if (client.respondsToSelector("displayName") && client.displayName && !client.displayName.isNil()) {
                appName = ObjC.unwrap(client.displayName);
              } else if (client.respondsToSelector("bundleIdentifier") && client.bundleIdentifier && !client.bundleIdentifier.isNil()) {
                appName = ObjC.unwrap(client.bundleIdentifier);
              }
            }
          }
        }
        if (reqCls.respondsToSelector("localNowPlayingItem")) {
          var item = reqCls.localNowPlayingItem;
          if (item && !item.isNil() && item.respondsToSelector("metadata")) {
            var meta = item.metadata;
            if (meta && !meta.isNil()) {
              if (meta.respondsToSelector("title") && meta.title && !meta.title.isNil()) {
                title = ObjC.unwrap(meta.title);
              }
              if (meta.respondsToSelector("trackArtistName") && meta.trackArtistName && !meta.trackArtistName.isNil()) {
                artist = ObjC.unwrap(meta.trackArtistName);
              }
              if (meta.respondsToSelector("duration")) {
                var d = Number(meta.duration);
                if (d > 0) duration = Math.round(d);
              }
              if (meta.respondsToSelector("calculatedPlaybackPosition")) {
                var cp = Number(meta.calculatedPlaybackPosition);
                if (cp >= 0) position = Math.round(cp);
              } else if (meta.respondsToSelector("elapsedTime")) {
                var ep = Number(meta.elapsedTime);
                if (ep >= 0) position = Math.round(ep);
              }
            }
          }
        }
      }
    } catch (e) {}

    if (appName.indexOf("QQMusic") >= 0 || appName.indexOf("qqmusic") >= 0) appName = "QQ音乐";
    else if (appName.indexOf("163music") >= 0 || appName.indexOf("Netease") >= 0) appName = "网易云音乐";
    else if (appName.indexOf("spotify") >= 0) appName = "Spotify";
    else if (appName.indexOf("com.apple.Music") >= 0) appName = "Apple Music";

    if (!appName && pmsetApp) appName = pmsetApp;

    try {
      var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
      var cnt = apps.count;
      for (var i = 0; i < cnt; i++) {
        var a = apps.objectAtIndex(i);
        var bid = (a.bundleIdentifier && !a.bundleIdentifier.isNil()) ? ObjC.unwrap(a.bundleIdentifier) : "";
        var lname = (a.localizedName && !a.localizedName.isNil()) ? ObjC.unwrap(a.localizedName) : "";
        if (bid.indexOf("QQMusic") >= 0 || lname.indexOf("QQ音乐") >= 0 || lname.indexOf("QQMusic") >= 0) {
          if (!appName) appName = "QQ音乐";
          break;
        }
        if (bid.indexOf("163music") >= 0 || lname.indexOf("网易云") >= 0) {
          if (!appName) appName = "网易云音乐";
        }
        if (bid.indexOf("com.spotify.client") >= 0) {
          if (!appName) appName = "Spotify";
        }
      }
    } catch (e) {}

    if (!title && appName) {
      try {
        var winList = $.CGWindowListCopyWindowInfo(0, 0);
        if (winList && !winList.isNil()) {
          var wcnt = winList.count;
          for (var j = 0; j < wcnt; j++) {
            var w = winList.objectAtIndex(j);
            var ownerObj = w.objectForKey("kCGWindowOwnerName");
            var nameObj = w.objectForKey("kCGWindowName");
            var owner = (ownerObj && !ownerObj.isNil()) ? ObjC.unwrap(ownerObj) : "";
            var wname = (nameObj && !nameObj.isNil()) ? ObjC.unwrap(nameObj) : "";
            if ((owner.indexOf("QQ音乐") >= 0 || owner.indexOf("QQMusic") >= 0 || owner.indexOf("网易云") >= 0) && wname) {
              if (wname !== "QQ音乐" && wname !== "QQMusic" && wname !== "Window" && wname.indexOf("Item") !== 0) {
                title = wname;
                break;
              }
            }
          }
        }
      } catch (e) {}
    }

    var finalPlaying = (isPlaying !== null) ? (isPlaying || pmsetPlaying) : pmsetPlaying;
    var displayTitle = title;
    if (artist) displayTitle = displayTitle ? (displayTitle + " - " + artist) : artist;
    if (appName) {
      if (displayTitle && displayTitle.indexOf(appName) < 0) {
        displayTitle = appName + " · " + displayTitle;
      } else if (!displayTitle) {
        displayTitle = appName + (finalPlaying ? " · 正在播放" : " · 已就绪");
      }
    }

    JSON.stringify({
      appName: appName || "",
      title: displayTitle || "",
      isPlaying: Boolean(finalPlaying),
      position: position,
      duration: duration > 0 ? duration : 300,
      ts: Date.now()
    });
  ' 2>/dev/null)

  if [ -n "$JSON_OUT" ]; then
    echo "$JSON_OUT" > "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
  fi

  sleep 1
done
""").encode("utf-8")

    mac_app_jxa = ("""ObjC.import('Cocoa');
ObjC.import('CoreGraphics');
ObjC.import('Quartz');
ObjC.import('WebKit');
ObjC.import('stdlib');

var mrBundle = $.NSBundle.bundleWithPath($('/System/Library/PrivateFrameworks/MediaRemote.framework'));
if (mrBundle && !mrBundle.isNil()) mrBundle.load;
try {
  ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
  ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
} catch (e) {}

var G = {
  win: null,
  webView: null,
  resDir: '',
  lastCmd: '',
  nativeIsPlaying: false
};

function sendMacMediaKey(keyCode) {
  try {
    var d = $.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(
      14, $.NSMakePoint(0, 0), 0xa00, 0, 0, null, 8, (keyCode << 16) | (0xa << 8), -1
    );
    $.CGEventPost(0, d.CGEvent);
    var u = $.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(
      14, $.NSMakePoint(0, 0), 0xb00, 0, 0, null, 8, (keyCode << 16) | (0xb << 8), -1
    );
    $.CGEventPost(0, u.CGEvent);
  } catch (e) {}
}

function triggerMacMedia(action, pos) {
  var p = Math.max(0, Math.round(Number(pos) || 0));
  var targetAct = String(action || 'toggle');
  if (targetAct === 'play' || targetAct === 'pause' || targetAct === 'toggle') {
    targetAct = G.nativeIsPlaying ? 'pause' : 'play';
    G.nativeIsPlaying = !G.nativeIsPlaying;
    sendMacMediaKey(16);
  } else if (targetAct === 'next') {
    G.nativeIsPlaying = true;
    sendMacMediaKey(17);
  } else if (targetAct === 'prev') {
    G.nativeIsPlaying = true;
    sendMacMediaKey(18);
  } else if (targetAct === 'seek') {
    G.nativeIsPlaying = true;
    try { $.MRMediaRemoteSetElapsedTime(p); } catch (e) {}
  }

  try {
    if (targetAct === 'play') $.MRMediaRemoteSendCommand(0, null);
    else if (targetAct === 'pause') $.MRMediaRemoteSendCommand(1, null);
  } catch (e) {}

  try {
    var task = $.NSTask.alloc.init;
    task.setLaunchPath($('/bin/bash'));
    task.setArguments($([G.resDir + '/desktop/mac_media_helper.sh', 'cmd', targetAct, String(p)]));
    task.launch;
  } catch (e) {}
}

ObjC.registerSubclass({
  name: 'LMCMainThreadRunner',
  superclass: 'NSObject',
  methods: {
    'startApp:': {
      types: ['void', ['id']],
      implementation: function(arg) {
        var env = $.NSProcessInfo.processInfo.environment;
        var resDirObj = env.objectForKey('LMC_RES_DIR');
        var ssidObj = env.objectForKey('LMC_WIFI_SSID');
        var resDir = (resDirObj && !resDirObj.isNil()) ? ObjC.unwrap(resDirObj) : '';
        var ssid = (ssidObj && !ssidObj.isNil()) ? ObjC.unwrap(ssidObj) : '';
        G.resDir = resDir;

        var app = $.NSApplication.sharedApplication;
        app.setActivationPolicy($.NSApplicationActivationPolicyRegular);

        var menubar = $.NSMenu.alloc.init;
        var appMenuItem = $.NSMenuItem.alloc.init;
        menubar.addItem(appMenuItem);
        var appMenu = $.NSMenu.alloc.init;
        appMenu.addItemWithTitleActionKeyEquivalent($('退出 四端媒体控制器'), 'terminate:', $('q'));
        appMenuItem.setSubmenu(appMenu);

        var editMenuItem = $.NSMenuItem.alloc.init;
        menubar.addItem(editMenuItem);
        var editMenu = $.NSMenu.alloc.initWithTitle($('编辑'));
        editMenu.addItemWithTitleActionKeyEquivalent($('剪切'), 'cut:', $('x'));
        editMenu.addItemWithTitleActionKeyEquivalent($('拷贝'), 'copy:', $('c'));
        editMenu.addItemWithTitleActionKeyEquivalent($('粘贴'), 'paste:', $('v'));
        editMenu.addItemWithTitleActionKeyEquivalent($('全选'), 'selectAll:', $('a'));
        editMenuItem.setSubmenu(editMenu);
        app.setMainMenu(menubar);

        var icnsPath = resDir + '/AppIcon.icns';
        var iconImg = $.NSImage.alloc.initWithContentsOfFile($(icnsPath));
        if (iconImg && !iconImg.isNil()) {
          app.setApplicationIconImage(iconImg);
        }

        var rect = $.NSMakeRect(0, 0, 560, 760);
        var styleMask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);
        var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(rect, styleMask, 2, false);
        win.setTitle($('四端局域网媒体控制器'));
        win.center;
        win.setDelegate(this);
        win.setReleasedWhenClosed(false);
        G.win = win;

        var cfg = $.WKWebViewConfiguration.alloc.init;
        var wv = $.WKWebView.alloc.initWithFrameConfiguration($.NSMakeRect(0, 0, 560, 760), cfg);
        wv.setAutoresizingMask(18);
        win.setContentView(wv);
        G.webView = wv;

        var htmlPath = resDir + '/ui/index.html';
        var nsHtml = $.NSString.stringWithContentsOfFileEncodingError($(htmlPath), $.NSUTF8StringEncoding, null);
        if (nsHtml && !nsHtml.isNil()) {
          var htmlStr = ObjC.unwrap(nsHtml);
          var inject = '<script>window.__INITIAL_PLATFORM__="macos";window.__INITIAL_LAN_NAME__=' + JSON.stringify(ssid || '') + ';</script></head>';
          htmlStr = htmlStr.replace('</head>', inject);
          wv.loadHTMLStringBaseURL($(htmlStr), $.NSURL.URLWithString($('https://ntfy.sh/')));
        }

        $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.08, this, 'pollTitle:', null, true);
        $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.6, this, 'pollMediaState:', null, true);

        win.makeKeyAndOrderFront(null);
        app.activateIgnoringOtherApps(true);
        app.run;
      }
    },
    'pollTitle:': {
      types: ['void', ['id']],
      implementation: function(timer) {
        if (!G.webView) return;
        var tObj = G.webView.title;
        if (tObj && !tObj.isNil()) {
          var t = ObjC.unwrap(tObj);
          if (t && t.indexOf('MAC_CMD:') === 0 && t !== G.lastCmd) {
            G.lastCmd = t;
            try {
              var cmd = JSON.parse(t.slice(8));
              triggerMacMedia(cmd.action, cmd.position);
            } catch (e) {}
          }
        }
      }
    },
    'pollMediaState:': {
      types: ['void', ['id']],
      implementation: function(timer) {
        if (!G.webView) return;
        try {
          var nsState = $.NSString.stringWithContentsOfFileEncodingError($('/tmp/lmc_mac_media_state.json'), $.NSUTF8StringEncoding, null);
          if (nsState && !nsState.isNil()) {
            var jsonStr = ObjC.unwrap(nsState).trim();
            if (jsonStr) {
              try {
                var parsed = JSON.parse(jsonStr);
                if (typeof parsed.isPlaying === 'boolean') G.nativeIsPlaying = parsed.isPlaying;
              } catch (e) {}
              var js = 'if (window.__onNativeMediaState) { window.__onNativeMediaState(' + jsonStr + '); }';
              G.webView.evaluateJavaScriptCompletionHandler($(js), null);
            }
          }
        } catch (e) {}
      }
    },
    'windowWillClose:': {
      types: ['void', ['id']],
      implementation: function(notification) {
        $.exit(0);
      }
    }
  }
});

var runner = $.LMCMainThreadRunner.alloc.init;
runner.performSelectorOnMainThreadWithObjectWaitUntilDone('startApp:', null, true);
""").encode("utf-8")

    launcher_sh = ("""#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SSID=""
for DEV in en0 en1; do
  if [ -z "$SSID" ]; then
    SSID=$(ipconfig getsummary "$DEV" 2>/dev/null | awk -F ' : ' '/^  SSID : / {print $2}' | tr -d '\\r\\n')
    if [ "$SSID" = "<redacted>" ]; then SSID=""; fi
  fi
  if [ -z "$SSID" ]; then
    SSID=$(networksetup -getairportnetwork "$DEV" 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p' | tr -d '\\r\\n')
    if [ "$SSID" = "<redacted>" ] || [ "$SSID" = "You are not associated with an AirPort network." ]; then SSID=""; fi
  fi
  if [ -z "$SSID" ]; then
    SSID=$(networksetup -listpreferredwirelessnetworks "$DEV" 2>/dev/null | sed -n '2p' | sed 's/^[[:space:]]*//' | tr -d '\\r\\n')
  fi
done
if [ -z "$SSID" ] || [ "$SSID" = "<redacted>" ]; then
  SSID="Rogers4808"
fi

export LMC_RES_DIR="$DIR"
export LMC_WIFI_SSID="$SSID"

pkill -f "mac_media_helper.sh" 2>/dev/null
nohup /bin/bash "$DIR/desktop/mac_media_helper.sh" daemon $$ >/dev/null 2>&1 &

OLD_PID=$(lsof -ti tcp:19889 2>/dev/null)
if [ -n "$OLD_PID" ]; then
  kill -9 $OLD_PID 2>/dev/null
fi

if command -v node >/dev/null 2>&1; then
  nohup node "$DIR/desktop/server.js" >/dev/null 2>&1 &
elif xcode-select -p >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  nohup python3 "$DIR/desktop/server.py" >/dev/null 2>&1 &
fi

exec /usr/bin/osascript -l JavaScript "$DIR/desktop/mac_app.jxa"
""").encode("utf-8")

    readme_txt = (
        "四端局域网媒体控制器 (macOS 原生桌面版)\n"
        "========================================\n\n"
        "安装与使用方法：\n"
        "1. 将磁盘映像内的 LanMediaController.app 直接拖拽到旁边的 Applications (应用程序) 文件夹中完成安装。\n"
        "2. 在「应用程序 (Applications)」中双击打开 LanMediaController.app（若首次打开提示未签名应用，请右键点击图标 -> 选择「打开」）。\n"
        "3. 原生支持识别并控制 macOS 上的 QQ音乐、网易云音乐、Apple Music、Spotify 等播放器。\n"
    ).encode("utf-8")

    return {
        "Applications": (b"/Applications", 0o120755),
        "LanMediaController.app/Contents/Info.plist": (info_plist, 0o100644),
        "LanMediaController.app/Contents/MacOS/LanMediaController": (launcher_sh, 0o100755),
        "LanMediaController.app/Contents/Resources/AppIcon.icns": (app_icns, 0o100644),
        "LanMediaController.app/Contents/Resources/desktop/mac_app.jxa": (mac_app_jxa, 0o100644),
        "LanMediaController.app/Contents/Resources/desktop/mac_media_helper.sh": (mac_media_helper_sh, 0o100755),
        "LanMediaController.app/Contents/Resources/desktop/server.js": (server_js, 0o100644),
        "LanMediaController.app/Contents/Resources/desktop/server.py": (server_py, 0o100755),
        "LanMediaController.app/Contents/Resources/ui/index.html": (index_html, 0o100644),
        "README.txt": (readme_txt, 0o100644),
    }


def make_fork_data(logical_size, clump_size, start_block, block_count):
    extents = bytearray(64)
    if block_count > 0:
        struct.pack_into(">II", extents, 0, start_block, block_count)
    res = struct.pack(">QII", logical_size, clump_size, block_count) + bytes(extents)
    assert len(res) == 80
    return res


def make_catalog_key(parent_id, name_str):
    utf16 = name_str.encode("utf-16-be")
    char_len = len(name_str)
    key_len = 6 + len(utf16)
    return struct.pack(">HIH", key_len, parent_id, char_len) + utf16


def make_unistr255(name_str):
    utf16 = name_str.encode("utf-16-be")
    return struct.pack(">H", len(name_str)) + utf16


def make_folder_record(folder_id, valence, mode=0o040755, is_bundle=False):
    flags = 0
    bsd = struct.pack(">IIBBHI", 0, 0, 0, 0, mode, 0)
    finder_flags = 0x2000 if is_bundle else 0
    user_info = struct.pack(">hhhhH6s", 0, 0, 0, 0, finder_flags, b"\x00" * 6)
    finder_info = b"\x00" * 16
    res = (
        struct.pack(
            ">hHIIIIIII",
            1,
            flags,
            valence,
            folder_id,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
        )
        + bsd
        + user_info
        + finder_info
        + struct.pack(">II", 0, 0)
    )
    assert len(res) == 88
    return res


def make_file_record(file_id, mode, logical_size, start_block, block_count):
    bsd = struct.pack(">IIBBHI", 0, 0, 0, 0, mode, 0)
    if (mode & 0o170000) == 0o120000:
        user_info = struct.pack(">4s4sHhhh", b"slnk", b"rhap", 0, 0, 0, 0)
    else:
        user_info = b"\x00" * 16
    finder_info = b"\x00" * 16
    data_fork = make_fork_data(logical_size, max(4096, block_count * 4096), start_block, block_count)
    rsrc_fork = make_fork_data(0, 0, 0, 0)
    res = (
        struct.pack(
            ">hHIIIIIII",
            2,
            2,
            0,
            file_id,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
            HFS_TIME,
        )
        + bsd
        + user_info
        + finder_info
        + struct.pack(">II", 0, 0)
        + data_fork
        + rsrc_fork
    )
    assert len(res) == 248
    return res


def make_thread_record(is_folder, parent_id, name_str):
    rec_type = 3 if is_folder else 4
    rec = struct.pack(">hhI", rec_type, 0, parent_id) + make_unistr255(name_str)
    if len(rec) % 2 == 1:
        rec += b"\x00"
    return rec


def pack_btree_node(kind, height, records, node_size):
    node = bytearray(node_size)
    num_recs = len(records)
    struct.pack_into(">IIbBHH", node, 0, 0, 0, kind, height, num_recs, 0)

    offsets = [14]
    cur = 14
    for r in records:
        node[cur : cur + len(r)] = r
        cur += len(r)
        if cur % 2 == 1:
            cur += 1
        offsets.append(cur)

    for i, off in enumerate(offsets):
        pos = node_size - 2 * (i + 1)
        struct.pack_into(">H", node, pos, off)

    return bytes(node)


def make_btree_header_node(tree_depth, root_node, leaf_records, first_leaf, last_leaf, node_size, max_key_len, total_nodes, free_nodes, key_compare_type, attributes, alloc_bitmap_byte0):
    header_rec = struct.pack(
        ">HIIIIHHIIHIBBI64s",
        tree_depth,
        root_node,
        leaf_records,
        first_leaf,
        last_leaf,
        node_size,
        max_key_len,
        total_nodes,
        free_nodes,
        0,
        node_size * total_nodes,
        0,
        key_compare_type,
        attributes,
        b"\x00" * 64,
    )
    assert len(header_rec) == 106
    user_data_rec = b"\x00" * 128
    map_rec = bytearray(node_size - 256)
    map_rec[0] = alloc_bitmap_byte0
    return pack_btree_node(1, 0, [header_rec, user_data_rec, bytes(map_rec)], node_size)


def build_hfsplus_volume(files_map, volume_name="LanMediaController"):
    block_size = 4096

    folders = {
        "": {"id": 2, "parent": 1, "name": volume_name, "children": []}
    }
    next_cnid = 16

    all_dir_paths = set()
    for rel_path in files_map.keys():
        parts = rel_path.split("/")
        for i in range(1, len(parts)):
            all_dir_paths.add("/".join(parts[:i]))

    for dpath in sorted(all_dir_paths, key=lambda x: (x.count("/"), x)):
        parent_path = "/".join(dpath.split("/")[:-1]) if "/" in dpath else ""
        dname = dpath.split("/")[-1]
        cid = next_cnid
        next_cnid += 1
        folders[dpath] = {
            "id": cid,
            "parent": folders[parent_path]["id"],
            "name": dname,
            "children": [],
        }
        folders[parent_path]["children"].append(dname)

    next_data_block = 7
    file_entries = []

    for rel_path in sorted(files_map.keys()):
        content, mode = files_map[rel_path]
        parent_path = "/".join(rel_path.split("/")[:-1]) if "/" in rel_path else ""
        fname = rel_path.split("/")[-1]
        fid = next_cnid
        next_cnid += 1
        folders[parent_path]["children"].append(fname)

        fblocks = max(1, (len(content) + block_size - 1) // block_size) if len(content) > 0 else 0
        start_blk = next_data_block if fblocks > 0 else 0
        next_data_block += fblocks

        file_entries.append({
            "id": fid,
            "parent": folders[parent_path]["id"],
            "name": fname,
            "mode": mode,
            "content": content,
            "start_block": start_blk,
            "block_count": fblocks,
        })

    catalog_items = []

    for dpath, fobj in folders.items():
        valence = len(fobj["children"])
        is_bundle = fobj["name"].endswith(".app")
        k_folder = (fobj["parent"], fobj["name"].lower(), make_catalog_key(fobj["parent"], fobj["name"]))
        v_folder = make_folder_record(fobj["id"], valence, 0o040755, is_bundle)
        catalog_items.append((k_folder[0], k_folder[1], k_folder[2] + v_folder))

        k_thread = (fobj["id"], "", make_catalog_key(fobj["id"], ""))
        v_thread = make_thread_record(True, fobj["parent"], fobj["name"])
        catalog_items.append((k_thread[0], k_thread[1], k_thread[2] + v_thread))

    for fe in file_entries:
        k_file = (fe["parent"], fe["name"].lower(), make_catalog_key(fe["parent"], fe["name"]))
        v_file = make_file_record(fe["id"], fe["mode"], len(fe["content"]), fe["start_block"], fe["block_count"])
        catalog_items.append((k_file[0], k_file[1], k_file[2] + v_file))

        k_thread = (fe["id"], "", make_catalog_key(fe["id"], ""))
        v_thread = make_thread_record(False, fe["parent"], fe["name"])
        catalog_items.append((k_thread[0], k_thread[1], k_thread[2] + v_thread))

    catalog_items.sort(key=lambda x: (x[0], x[1]))
    leaf_records = [item[2] for item in catalog_items]

    cat_node_size = 8192
    cat_node0 = make_btree_header_node(
        tree_depth=1,
        root_node=1,
        leaf_records=len(leaf_records),
        first_leaf=1,
        last_leaf=1,
        node_size=cat_node_size,
        max_key_len=516,
        total_nodes=2,
        free_nodes=0,
        key_compare_type=0,
        attributes=0x00000006,
        alloc_bitmap_byte0=0xC0,
    )
    cat_node1 = pack_btree_node(-1, 1, leaf_records, cat_node_size)
    catalog_btree_bytes = cat_node0 + cat_node1

    ext_node0 = make_btree_header_node(
        tree_depth=0,
        root_node=0,
        leaf_records=0,
        first_leaf=0,
        last_leaf=0,
        node_size=4096,
        max_key_len=10,
        total_nodes=1,
        free_nodes=0,
        key_compare_type=0,
        attributes=0x00000002,
        alloc_bitmap_byte0=0x80,
    )

    total_blocks = max(128, next_data_block + 16)
    used_blocks_count = next_data_block + 1
    free_blocks_count = total_blocks - used_blocks_count

    alloc_bitmap = bytearray(block_size)
    for b in range(next_data_block):
        alloc_bitmap[b // 8] |= 1 << (7 - (b % 8))
    last_blk = total_blocks - 1
    alloc_bitmap[last_blk // 8] |= 1 << (7 - (last_blk % 8))

    vh = bytearray(512)
    header_80 = struct.pack(
        ">2sHI4sIIIIIIIIIIIIIIIQ",
        b"H+",
        4,
        0x00000100,
        b"10.0",
        0,
        HFS_TIME,
        HFS_TIME,
        HFS_TIME,
        HFS_TIME,
        len(file_entries),
        len(folders) - 1,
        block_size,
        total_blocks,
        free_blocks_count,
        next_data_block,
        65536,
        65536,
        next_cnid,
        1,
        1,
    )
    assert len(header_80) == 80
    vh[0:80] = header_80
    vh[112:192] = make_fork_data(block_size, block_size, 1, 1)
    vh[192:272] = make_fork_data(block_size, block_size, 2, 1)
    vh[272:352] = make_fork_data(16384, 16384, 3, 4)

    vol = bytearray(total_blocks * block_size)
    vol[1024:1536] = vh
    vol[1 * block_size : 2 * block_size] = alloc_bitmap
    vol[2 * block_size : 3 * block_size] = ext_node0
    vol[3 * block_size : 7 * block_size] = catalog_btree_bytes

    for fe in file_entries:
        if fe["block_count"] > 0:
            start_off = fe["start_block"] * block_size
            vol[start_off : start_off + len(fe["content"])] = fe["content"]

    vol[len(vol) - 1024 : len(vol) - 512] = vh
    return bytes(vol)


def wrap_in_gpt_disk_image(hfs_volume_bytes, out_dmg_path):
    hfs_sectors = len(hfs_volume_bytes) // 512
    part_start_lba = 40
    part_end_lba = part_start_lba + hfs_sectors - 1
    total_sectors = part_start_lba + hfs_sectors + 40

    disk = bytearray(total_sectors * 512)

    mbr = bytearray(512)
    struct.pack_into("<BBBBBBBBII", mbr, 446, 0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF, 1, total_sectors - 1)
    mbr[510] = 0x55
    mbr[511] = 0xAA
    disk[0:512] = mbr

    entries = bytearray(128 * 128)
    apple_hfs_guid = uuid.UUID("48465300-0000-11aa-aa11-00306543ecac").bytes_le
    part_guid = uuid.uuid4().bytes_le
    part_name = "LanMediaController".encode("utf-16-le").ljust(72, b"\x00")
    struct.pack_into("<16s16sQQQ72s", entries, 0, apple_hfs_guid, part_guid, part_start_lba, part_end_lba, 0, part_name)
    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF

    disk[2 * 512 : 34 * 512] = entries
    backup_entries_lba = total_sectors - 33
    disk[backup_entries_lba * 512 : (backup_entries_lba + 32) * 512] = entries

    disk_guid = uuid.uuid4().bytes_le
    first_usable_lba = 34
    last_usable_lba = total_sectors - 34

    def make_gpt_header(my_lba, alt_lba, part_entry_lba):
        hdr = bytearray(92)
        struct.pack_into(
            "<8sIIIIQQQQ16sQIII",
            hdr,
            0,
            b"EFI PART",
            0x00010000,
            92,
            0,
            0,
            my_lba,
            alt_lba,
            first_usable_lba,
            last_usable_lba,
            disk_guid,
            part_entry_lba,
            128,
            128,
            entries_crc,
        )
        hdr_crc = zlib.crc32(hdr) & 0xFFFFFFFF
        struct.pack_into("<I", hdr, 16, hdr_crc)
        sec = bytearray(512)
        sec[0:92] = hdr
        return bytes(sec)

    disk[1 * 512 : 2 * 512] = make_gpt_header(1, total_sectors - 1, 2)
    disk[(total_sectors - 1) * 512 : total_sectors * 512] = make_gpt_header(total_sectors - 1, 1, backup_entries_lba)

    disk[part_start_lba * 512 : (part_start_lba + hfs_sectors) * 512] = hfs_volume_bytes

    with open(out_dmg_path, "wb") as f:
        f.write(disk)


if __name__ == "__main__":
    app_files = build_macos_app_files()
    hfs_bytes = build_hfsplus_volume(app_files)
    out_path = os.path.join(DIST_DIR, "LanMediaController-macOS.dmg")
    wrap_in_gpt_disk_image(hfs_bytes, out_path)
    print(f"Built GPT+HFS+ macOS DMG: {out_path} ({os.path.getsize(out_path)} bytes)")
