import Foundation
import AppKit

final class MacMediaController {
    private let queue = DispatchQueue(label: "com.local.lanmediacontroller.macmedia", qos: .userInitiated)
    private var streamProcess: Process?
    private var lineBuffer = Data()
    private var stopped = false
    private var currentState = PlayerState()

    var onStateChanged: ((PlayerState) -> Void)?

    private var adapterScriptPath: String? {
        guard let resURL = Bundle.main.resourceURL else { return nil }
        let path = resURL.appendingPathComponent("mediaremote-adapter/mediaremote-adapter.pl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private var adapterFrameworkPath: String? {
        guard let resURL = Bundle.main.resourceURL else { return nil }
        let path = resURL.appendingPathComponent("mediaremote-adapter/MediaRemoteAdapter.framework").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.fetchInitialSnapshot()
            self.launchStreamProcess()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.streamProcess?.terminate()
            self.streamProcess = nil
        }
    }

    func execute(action: String, position: Double = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.runAdapterCommand(action: action, position: position)
            if !ok {
                self.sendFallbackMediaKey(action: action)
            }
            // Fetch fresh snapshot shortly after command so UI & peers converge immediately
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.fetchInitialSnapshot()
            }
        }
    }

    private func fetchInitialSnapshot() {
        guard let script = adapterScriptPath, let fw = adapterFrameworkPath else { return }
        let output = runPerl(args: [script, fw, "get", "--now"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let data = trimmed.data(using: .utf8) {
            parseAdapterJSON(data: data, isStreamEnvelope: false)
        }
    }

    private func launchStreamProcess() {
        guard !stopped else { return }
        guard let script = adapterScriptPath, let fw = adapterFrameworkPath else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [script, fw, "stream", "--no-diff"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consumeStreamData(chunk)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2.0) {
                if !self.stopped {
                    self.launchStreamProcess()
                }
            }
        }

        do {
            try proc.run()
            self.streamProcess = proc
        } catch {
            self.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if let self, !self.stopped {
                    self.launchStreamProcess()
                }
            }
        }
    }

    private func consumeStreamData(_ chunk: Data) {
        lineBuffer.append(chunk)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.subdata(in: 0..<idx)
            lineBuffer.removeSubrange(0...idx)
            if !lineData.isEmpty {
                parseAdapterJSON(data: lineData, isStreamEnvelope: true)
            }
        }
    }

    private func parseAdapterJSON(data: Data, isStreamEnvelope: Bool) {
        guard let rawObj = try? JSONSerialization.jsonObject(with: data) else { return }
        guard let dict = rawObj as? [String: Any] else { return }

        let payload: [String: Any]
        if isStreamEnvelope {
            if let p = dict["payload"] as? [String: Any] {
                payload = p
            } else {
                // Stream sent null/empty payload -> player closed or idle
                let emptyState = PlayerState(
                    appName: "",
                    title: "",
                    artist: "",
                    isPlaying: false,
                    position: 0,
                    duration: 0,
                    hasMedia: false,
                    updatedAt: nowMillis()
                )
                publishIfChanged(emptyState)
                return
            }
        } else {
            payload = dict
        }

        if payload.isEmpty {
            let emptyState = PlayerState(
                appName: "",
                title: "",
                artist: "",
                isPlaying: false,
                position: 0,
                duration: 0,
                hasMedia: false,
                updatedAt: nowMillis()
            )
            publishIfChanged(emptyState)
            return
        }

        let bundleId = (payload["bundleIdentifier"] as? String) ?? (payload["parentApplicationBundleIdentifier"] as? String) ?? ""
        let title = ((payload["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = ((payload["artist"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = friendlyAppName(for: bundleId)

        var isPlaying = false
        if let b = payload["playing"] as? Bool {
            isPlaying = b
        } else if let n = payload["playing"] as? NSNumber {
            isPlaying = n.boolValue
        } else if let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue {
            isPlaying = rate > 0.01
        }

        let duration = max(0, (payload["duration"] as? NSNumber)?.doubleValue ?? 0)
        var elapsed = max(0, (payload["elapsedTimeNow"] as? NSNumber)?.doubleValue ?? (payload["elapsedTime"] as? NSNumber)?.doubleValue ?? 0)
        var updatedMs = nowMillis()

        // If adapter gave elapsedTime (not elapsedTimeNow) + ISO8601 timestamp, adjust accurately
        if payload["elapsedTimeNow"] == nil,
           let tsStr = payload["timestamp"] as? String,
           let tsDate = parseISO8601(tsStr) {
            let tsMs = Int64(tsDate.timeIntervalSince1970 * 1000)
            if isPlaying {
                let delta = max(0, Double(updatedMs - tsMs) / 1000.0)
                elapsed = duration > 0 ? min(duration, elapsed + delta) : (elapsed + delta)
            }
        }

        let hasMedia = !title.isEmpty || !appName.isEmpty || duration > 0 || isPlaying
        let newState = PlayerState(
            appName: appName,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            position: elapsed,
            duration: duration,
            hasMedia: hasMedia,
            updatedAt: updatedMs
        )
        publishIfChanged(newState)
    }

    private func publishIfChanged(_ state: PlayerState) {
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(state)
        }
    }

    private func runAdapterCommand(action: String, position: Double) -> Bool {
        guard let script = adapterScriptPath, let fw = adapterFrameworkPath else { return false }

        switch action {
        case "play":
            return runPerlExitCode(args: [script, fw, "send", "0"]) == 0
        case "pause":
            return runPerlExitCode(args: [script, fw, "send", "1"]) == 0
        case "toggle":
            return runPerlExitCode(args: [script, fw, "send", "2"]) == 0
        case "next":
            return runPerlExitCode(args: [script, fw, "send", "4"]) == 0
        case "prev":
            return runPerlExitCode(args: [script, fw, "send", "5"]) == 0
        case "seek":
            let micros = Int64(max(0, position) * 1_000_000.0)
            let seekOk = runPerlExitCode(args: [script, fw, "seek", String(micros)]) == 0
            // Per requirement: dragging progress bar seeks AND starts playback
            _ = runPerlExitCode(args: [script, fw, "send", "0"])
            return seekOk
        default:
            return false
        }
    }

    private func runPerl(args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func runPerlExitCode(args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private func sendFallbackMediaKey(action: String) {
        let keyCode: Int
        switch action {
        case "play", "pause", "toggle": keyCode = 16 // NX_KEYTYPE_PLAY
        case "next": keyCode = 17                    // NX_KEYTYPE_NEXT
        case "prev": keyCode = 18                    // NX_KEYTYPE_PREVIOUS
        default: return
        }
        DispatchQueue.main.async {
            if let down = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (keyCode << 16) | (0xa << 8),
                data2: -1
            )?.cgEvent {
                down.post(tap: .cghidEventTap)
            }
            if let up = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (keyCode << 16) | (0xb << 8),
                data2: -1
            )?.cgEvent {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func friendlyAppName(for bundleId: String) -> String {
        let lower = bundleId.lowercased()
        if lower.contains("qqmusic") { return "QQ音乐" }
        if lower.contains("163music") || lower.contains("netease") { return "网易云音乐" }
        if lower.contains("spotify") { return "Spotify" }
        if lower == "com.apple.music" { return "Apple Music" }
        if lower.contains("kugou") { return "酷狗音乐" }
        if lower.contains("kuwo") { return "酷我音乐" }
        if lower.contains("soda") || lower.contains("luna") { return "汽水音乐" }
        if lower.contains("bilibili") || lower.contains("bili") { return "哔哩哔哩" }
        if lower.contains("chrome") { return "Chrome" }
        if lower.contains("safari") { return "Safari" }
        if lower.contains("edgemac") { return "Edge" }
        if lower.contains("firefox") { return "Firefox" }
        if lower.contains("iina") { return "IINA" }
        if lower.contains("vlc") { return "VLC" }

        if !bundleId.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return bundleId
    }

    private func parseISO8601(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }
}
