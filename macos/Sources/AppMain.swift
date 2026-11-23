import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let icnsPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: icnsPath) {
            NSApp.applicationIconImage = icon
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "四端媒体控制器")
            btn.action = #selector(showMainWindow)
            btn.target = self
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 四端媒体控制器", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for win in NSApp.windows {
            if win.canBecomeMain {
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
struct LanMediaControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = SyncEngine()

    var body: some Scene {
        WindowGroup("四端局域网媒体控制器") {
            ContentView(engine: engine)
                .onAppear {
                    engine.start()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
