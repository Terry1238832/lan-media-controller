package com.local.lanmediacontroller

import android.content.Context
import android.net.wifi.WifiManager
import java.net.Inet4Address
import java.net.NetworkInterface

data class AndroidNetworkSnapshot(
    val ssid: String,
    val ip: String,
    val subnet: String,
    val broadcastAddresses: List<String>
)

object AndroidNetworkInfo {
    fun isValidSsid(candidate: String?): Boolean {
        val s = candidate?.trim()?.removeSurrounding("\"") ?: ""
        if (s.isEmpty()) return false
        if (s.equals("<unknown ssid>", ignoreCase = true) || s.equals("<redacted>", ignoreCase = true)) return false
        if (s.startsWith("Wi-Fi · ") || s.startsWith("局域网 · ")) return false
        return true
    }

    @Suppress("DEPRECATION")
    fun readSnapshot(context: Context): AndroidNetworkSnapshot {
        var ssid = ""
        try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val raw = wm?.connectionInfo?.ssid?.removeSurrounding("\"")
            if (isValidSsid(raw)) ssid = raw!!
        } catch (_: Exception) {}

        var primaryIp = ""
        var primarySubnet = ""
        val broadcasts = linkedSetOf("255.255.255.255")

        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces != null && ifaces.hasMoreElements()) {
                val nif = ifaces.nextElement()
                if (!nif.isUp || nif.isLoopback) continue
                for (ia in nif.interfaceAddresses) {
                    val addr = ia.address
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val ipStr = addr.hostAddress ?: continue
                    if (ipStr.startsWith("169.254.")) continue
                    if (primaryIp.isEmpty() || nif.name.startsWith("wlan")) {
                        primaryIp = ipStr
                        val parts = ipStr.split(".")
                        if (parts.size == 4) primarySubnet = "${parts[0]}.${parts[1]}.${parts[2]}"
                    }
                    ia.broadcast?.hostAddress?.let { if (it.isNotBlank()) broadcasts.add(it) }
                }
            }
        } catch (_: Exception) {}

        return AndroidNetworkSnapshot(
            ssid = ssid,
            ip = primaryIp,
            subnet = primarySubnet,
            broadcastAddresses = broadcasts.toList()
        )
    }
}
