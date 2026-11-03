using System;
using Microsoft.Win32;

namespace EdgeGlow;

/// <summary>Per-user "launch at sign-in" through HKCU\...\Run (no admin rights, removable from Task Manager > Startup).</summary>
public static class LaunchAtStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "EdgeGlow";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string;
            }
            catch
            {
                return false;
            }
        }
        set
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true) ?? Registry.CurrentUser.CreateSubKey(RunKey);
                if (value)
                {
                    var exe = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exe)) key.SetValue(ValueName, $"\"{exe}\"");
                }
                else
                {
                    key.DeleteValue(ValueName, throwOnMissingValue: false);
                }
            }
            catch
            {
                // Group policy can lock the Run key; the toggle simply won't stick.
            }
        }
    }
}
