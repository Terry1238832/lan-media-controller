using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace LanMediaController.Services;

public sealed class NetworkSnapshot
{
    public string Ssid { get; init; } = "";
    public string Ip { get; init; } = "";
    public string Subnet { get; init; } = "";
    public string InterfaceLabel { get; init; } = "";
    public List<string> BroadcastAddresses { get; init; } = new() { "255.255.255.255" };
}

public static class WindowsNetworkInfo
{
    private const int WlanIntfOpcodeCurrentConnection = 7;

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanQueryInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid, int opCode, IntPtr pReserved, out uint pdwDataSize, out IntPtr ppData, IntPtr pWlanOpcodeValueType);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr pMemory);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WlanInterfaceInfo
    {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string InterfaceDescription;
        public int State;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Dot11Ssid
    {
        public uint SsidLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] Ssid;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WlanConnectionAttributes
    {
        public int State;
        public int ConnectionMode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string ProfileName;
        public WlanAssociationAttributes AssociationAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WlanAssociationAttributes
    {
        public Dot11Ssid Dot11Ssid;
        public int Dot11BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] Dot11Bssid;
        public int Dot11PhyType;
        public uint Dot11PhyIndex;
        public uint SignalQuality;
        public uint RxRate;
        public uint TxRate;
    }

    public static NetworkSnapshot ReadSnapshot()
    {
        var ssid = ReadNativeWifiSsid();
        var (ip, subnet, ifaceLabel, broadcasts) = ReadIPv4Interfaces();
        return new NetworkSnapshot
        {
            Ssid = ssid,
            Ip = ip,
            Subnet = subnet,
            InterfaceLabel = ifaceLabel,
            BroadcastAddresses = broadcasts
        };
    }

    public static bool IsValidSsid(string? candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate)) return false;
        var s = candidate.Trim();
        if (s.Equals("<redacted>", StringComparison.OrdinalIgnoreCase)) return false;
        if (s.StartsWith("Wi-Fi · ", StringComparison.Ordinal) || s.StartsWith("局域网 · ", StringComparison.Ordinal)) return false;
        return true;
    }

    private static string ReadNativeWifiSsid()
    {
        IntPtr clientHandle = IntPtr.Zero;
        IntPtr listPtr = IntPtr.Zero;
        try
        {
            if (WlanOpenHandle(2, IntPtr.Zero, out _, out clientHandle) != 0)
                return "";

            if (WlanEnumInterfaces(clientHandle, IntPtr.Zero, out listPtr) != 0 || listPtr == IntPtr.Zero)
                return "";

            int count = Marshal.ReadInt32(listPtr, 0);
            int itemSize = Marshal.SizeOf<WlanInterfaceInfo>();
            long baseOffset = listPtr.ToInt64() + 8;

            for (int i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<WlanInterfaceInfo>(new IntPtr(baseOffset + (long)i * itemSize));
                if (info.State != 1) continue; // wlan_interface_state_connected == 1

                IntPtr dataPtr = IntPtr.Zero;
                try
                {
                    var guid = info.InterfaceGuid;
                    if (WlanQueryInterface(clientHandle, ref guid, WlanIntfOpcodeCurrentConnection, IntPtr.Zero, out _, out dataPtr, IntPtr.Zero) == 0 && dataPtr != IntPtr.Zero)
                    {
                        var attrs = Marshal.PtrToStructure<WlanConnectionAttributes>(dataPtr);
                        var len = (int)Math.Min(32, attrs.AssociationAttributes.Dot11Ssid.SsidLength);
                        if (len > 0 && attrs.AssociationAttributes.Dot11Ssid.Ssid != null)
                        {
                            var ssid = Encoding.UTF8.GetString(attrs.AssociationAttributes.Dot11Ssid.Ssid, 0, len).Trim();
                            if (IsValidSsid(ssid)) return ssid;
                        }
                        if (IsValidSsid(attrs.ProfileName))
                            return attrs.ProfileName.Trim();
                    }
                }
                finally
                {
                    if (dataPtr != IntPtr.Zero) WlanFreeMemory(dataPtr);
                }
            }
        }
        catch
        {
            // Ignore WLAN service unavailable (e.g., desktop without Wi-Fi card)
        }
        finally
        {
            if (listPtr != IntPtr.Zero) WlanFreeMemory(listPtr);
            if (clientHandle != IntPtr.Zero) WlanCloseHandle(clientHandle, IntPtr.Zero);
        }
        return "";
    }

    private static (string ip, string subnet, string ifaceLabel, List<string> broadcasts) ReadIPv4Interfaces()
    {
        var primaryIp = "";
        var primarySubnet = "";
        var primaryLabel = "";
        var broadcasts = new HashSet<string> { "255.255.255.255" };

        try
        {
            var nics = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up
                         && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                         && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Count > 0)
                .ThenByDescending(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);

            foreach (var nic in nics)
            {
                var desc = nic.Description.ToLowerInvariant();
                if (desc.Contains("virtual") || desc.Contains("vmware") || desc.Contains("hyper-v") || desc.Contains("wsl") || desc.Contains("vethernet"))
                    continue;

                var props = nic.GetIPProperties();
                foreach (var uni in props.UnicastAddresses)
                {
                    if (uni.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var ipBytes = uni.Address.GetAddressBytes();
                    if (ipBytes[0] == 127 || (ipBytes[0] == 169 && ipBytes[1] == 254)) continue;

                    var ipStr = uni.Address.ToString();
                    if (string.IsNullOrEmpty(primaryIp))
                    {
                        primaryIp = ipStr;
                        primarySubnet = $"{ipBytes[0]}.{ipBytes[1]}.{ipBytes[2]}";
                        primaryLabel = nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? "Wi-Fi" : "局域网";
                    }

                    if (uni.IPv4Mask != null)
                    {
                        var maskBytes = uni.IPv4Mask.GetAddressBytes();
                        if (maskBytes.Length == 4)
                        {
                            var bcastBytes = new byte[4];
                            for (int i = 0; i < 4; i++)
                                bcastBytes[i] = (byte)(ipBytes[i] | ~maskBytes[i]);
                            broadcasts.Add(new IPAddress(bcastBytes).ToString());
                        }
                    }
                }
            }
        }
        catch
        {
        }

        return (primaryIp, primarySubnet, primaryLabel, broadcasts.ToList());
    }
}
