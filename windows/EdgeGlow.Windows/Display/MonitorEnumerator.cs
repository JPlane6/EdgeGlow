using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.Win32;

namespace EdgeGlow;

/// <summary>One physical monitor, in physical pixels.</summary>
public sealed record MonitorInfo(string Id, string Name, bool IsBuiltIn, bool IsPrimary,
                                 int X, int Y, int Width, int Height, double DpiScale);

/// <summary>
/// Enumerates displays with EnumDisplayMonitors and derives a stable hardware ID per monitor from the
/// device interface name (e.g. DELA0F3 + instance UID), so the per-display toggle survives reboots and
/// replugging, and two identical monitors stay distinct. The friendly name comes from the EDID.
/// </summary>
public static class MonitorEnumerator
{
    // Vendor codes that essentially only ship internal laptop panels.
    private static readonly string[] InternalPanelVendors = { "LGD", "BOE", "AUO", "SDC", "CMN", "IVO", "CSO", "HSD", "NCP", "TMX", "MEI", "SHP", "LEN", "ATNA" };

    public static List<MonitorInfo> Enumerate()
    {
        var raw = new List<(IntPtr Handle, Native.MONITORINFOEX Info)>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr hdc, ref Native.RECT rect, IntPtr data) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(hMonitor, ref info)) raw.Add((hMonitor, info));
            return true;
        }, IntPtr.Zero);

        var result = new List<MonitorInfo>();
        var fallbackIndex = 0;
        foreach (var (handle, info) in raw.OrderByDescending(r => (r.Info.dwFlags & Native.MONITORINFOF_PRIMARY) != 0))
        {
            fallbackIndex++;
            var (hardwareId, instance, devicePath) = HardwareId(info.szDevice);
            var edidName = ReadEdidName(hardwareId, instance);
            var id = hardwareId != null ? $"{hardwareId}|{instance}" : info.szDevice;
            var vendor = hardwareId is { Length: >= 3 } ? hardwareId.Substring(0, 3) : "";
            var isPrimary = (info.dwFlags & Native.MONITORINFOF_PRIMARY) != 0;
            var builtIn = InternalPanelVendors.Contains(vendor) && edidName == null
                          || (devicePath != null && devicePath.Contains("DISPLAY#LEN", StringComparison.OrdinalIgnoreCase));
            var name = edidName ?? (hardwareId != null ? $"Display {fallbackIndex} ({hardwareId})" : $"Display {fallbackIndex}");
            uint dpi = 96;
            try { if (Native.GetDpiForMonitor(handle, Native.MDT_EFFECTIVE_DPI, out var dx, out _) == 0 && dx > 0) dpi = dx; } catch { }
            result.Add(new MonitorInfo(id, name, builtIn, isPrimary,
                info.rcMonitor.Left, info.rcMonitor.Top,
                info.rcMonitor.Right - info.rcMonitor.Left, info.rcMonitor.Bottom - info.rcMonitor.Top, dpi / 96.0));
        }
        return result;
    }

    /// <summary>Splits "\\?\DISPLAY#DELA0F3#5&amp;1a2b3c&amp;0&amp;UID4352#{guid}" into hardware ID and instance.</summary>
    private static (string? HardwareId, string? Instance, string? Path) HardwareId(string gdiDeviceName)
    {
        var device = new Native.DISPLAY_DEVICE { cb = System.Runtime.InteropServices.Marshal.SizeOf<Native.DISPLAY_DEVICE>() };
        if (!Native.EnumDisplayDevices(gdiDeviceName, 0, ref device, Native.EDD_GET_DEVICE_INTERFACE_NAME)) return (null, null, null);
        var path = device.DeviceID;
        var parts = path.Split('#');
        return parts.Length >= 3 ? (parts[1], parts[2], path) : (null, null, path);
    }

    private static string? ReadEdidName(string? hardwareId, string? instance)
    {
        if (hardwareId == null || instance == null) return null;
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{hardwareId}\{instance}\Device Parameters");
            if (key?.GetValue("EDID") is not byte[] edid || edid.Length < 128) return null;
            // Four 18-byte descriptors start at offset 54; tag 0xFC is the monitor name.
            for (var offset = 54; offset <= 108; offset += 18)
            {
                if (edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 2] == 0 && edid[offset + 3] == 0xFC)
                {
                    var text = Encoding.ASCII.GetString(edid, offset + 5, 13);
                    var end = text.IndexOf('\n');
                    if (end >= 0) text = text.Substring(0, end);
                    text = text.Trim();
                    return text.Length > 0 ? text : null;
                }
            }
        }
        catch
        {
            // Registry access can be restricted; the generic name is fine.
        }
        return null;
    }
}
