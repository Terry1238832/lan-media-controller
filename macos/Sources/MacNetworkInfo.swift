import Foundation
import CoreWLAN
import Darwin

struct LocalNetworkSnapshot {
    let ssid: String
    let ip: String
    let subnet: String
    let broadcastAddresses: [String]
}

enum MacNetworkInfo {
    static func readSnapshot() -> LocalNetworkSnapshot {
        let (ip, subnet, broadcasts) = readIPv4Interfaces()
        let ssid = readWifiSSID()
        return LocalNetworkSnapshot(
            ssid: ssid,
            ip: ip,
            subnet: subnet,
            broadcastAddresses: broadcasts
        )
    }

    private static func readWifiSSID() -> String {
        if let iface = CWWiFiClient.shared().interface(),
           let raw = iface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidSSID(raw) {
            return raw
        }

        for dev in ["en0", "en1"] {
            let summary = runShell("/usr/sbin/ipconfig", ["getsummary", dev])
            for line in summary.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("SSID : ") {
                    let candidate = String(trimmed.dropFirst("SSID : ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidSSID(candidate) {
                        return candidate
                    }
                }
            }
        }

        for dev in ["en0", "en1"] {
            let out = runShell("/usr/sbin/networksetup", ["-getairportnetwork", dev])
            if let range = out.range(of: "Current Wi-Fi Network: ") {
                let candidate = String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidSSID(candidate) {
                    return candidate
                }
            }
        }

        return ""
    }

    static func isValidSSID(_ candidate: String) -> Bool {
        let s = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        let blocked: Set<String> = [
            "<redacted>", "redacted", "(null)", "null",
            "You are not associated with an AirPort network."
        ]
        if blocked.contains(s) { return false }
        if s.hasPrefix("Wi-Fi · ") || s.hasPrefix("局域网 · ") { return false }
        return true
    }

    private static func readIPv4Interfaces() -> (String, String, [String]) {
        var primaryIP = ""
        var primarySubnet = ""
        var broadcasts = Set<String>(["255.255.255.255"])

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return ("", "", Array(broadcasts))
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let iface = current.pointee
            let flags = Int32(iface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && !isLoopback, let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ipStr = String(cString: ipBuf)

                if !ipStr.hasPrefix("169.254.") && !ipStr.hasPrefix("127.") {
                    if primaryIP.isEmpty || name == "en0" {
                        primaryIP = ipStr
                        let parts = ipStr.split(separator: ".")
                        if parts.count == 4 {
                            primarySubnet = "\(parts[0]).\(parts[1]).\(parts[2])"
                        }
                    }

                    if let maskAddr = iface.ifa_netmask, maskAddr.pointee.sa_family == UInt8(AF_INET) {
                        let maskSin = maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let ipVal = sin.sin_addr.s_addr
                        let maskVal = maskSin.sin_addr.s_addr
                        var bcastAddr = in_addr(s_addr: ipVal | ~maskVal)
                        var bcastBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &bcastAddr, &bcastBuf, socklen_t(INET_ADDRSTRLEN))
                        let bcastStr = String(cString: bcastBuf)
                        if !bcastStr.isEmpty {
                            broadcasts.insert(bcastStr)
                        }
                    }
                }
            }
            ptr = iface.ifa_next
        }

        return (primaryIP, primarySubnet, Array(broadcasts))
    }

    private static func runShell(_ launchPath: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
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
}
