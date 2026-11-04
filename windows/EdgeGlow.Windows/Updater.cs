using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace EdgeGlow;

/// <summary>Self-updater: polls the latest GitHub release, downloads EdgeGlow-Windows-x64.zip to %TEMP%, and
/// extracts it over the install directory from a detached script after this process has exited.</summary>
public static class Updater
{
    private const string LatestUrl = "https://api.github.com/repos/JPlane6/EdgeGlow/releases/latest";
    private const string AssetName = "EdgeGlow-Windows-x64.zip";

    private static readonly HttpClient Http = CreateClient();
    private static int _busy;

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("EdgeGlow-Updater");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public static Version CurrentVersion
    {
        get
        {
            var info = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            return Parse(info ?? "0") ?? new Version(0, 0);
        }
    }

    /// <summary>Checks for a newer release and, if there is one, installs it and restarts the app.
    /// A silent (launch) check never reports anything; a manual one reports its outcome through <paramref name="notify"/>.</summary>
    public static async Task CheckAsync(bool userInitiated, Action<string> notify, Action quit)
    {
        // Only a published EdgeGlow.exe can replace itself (not `dotnet run`).
        var exePath = Environment.ProcessPath;
        if (exePath == null || !string.Equals(Path.GetFileName(exePath), "EdgeGlow.exe", StringComparison.OrdinalIgnoreCase))
        {
            if (userInitiated) notify("Updates are only available for the installed EdgeGlow.exe.");
            return;
        }
        if (System.Threading.Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            using var doc = JsonDocument.Parse(await Http.GetStringAsync(LatestUrl).ConfigureAwait(true));
            var root = doc.RootElement;
            var tag = root.GetProperty("tag_name").GetString() ?? "";
            var latest = Parse(tag);
            if (latest == null || latest <= CurrentVersion)
            {
                if (userInitiated) notify("EdgeGlow is up to date.");
                return;
            }

            var url = root.GetProperty("assets").EnumerateArray()
                .Where(a => a.GetProperty("name").GetString() == AssetName)
                .Select(a => a.GetProperty("browser_download_url").GetString())
                .FirstOrDefault();
            if (url == null)
            {
                if (userInitiated) notify($"{tag} has no {AssetName}.");
                return;
            }

            var installDir = Path.GetDirectoryName(exePath)!;
            if (!CanWrite(installDir))
            {
                if (userInitiated) notify($"Can't write to {installDir}. Move EdgeGlow to a user folder to enable updates.");
                return;
            }

            if (userInitiated) notify($"Downloading {tag}…");
            var zip = Path.Combine(Path.GetTempPath(), "EdgeGlow-update.zip");
            await using (var net = await Http.GetStreamAsync(url).ConfigureAwait(true))
            await using (var file = File.Create(zip))
                await net.CopyToAsync(file).ConfigureAwait(true);

            Launch(zip, installDir, exePath);
            quit();
            Environment.Exit(0);   // the script overwrites EdgeGlow.exe, so this process must be gone
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or IOException or KeyNotFoundException or InvalidOperationException)
        {
            if (userInitiated) notify("Update check failed. Please try again later.");
        }
        finally
        {
            System.Threading.Interlocked.Exchange(ref _busy, 0);
        }
    }

    private static void Launch(string zip, string installDir, string exePath)
    {
        var script = Path.Combine(Path.GetTempPath(), "EdgeGlow-update.bat");
        var pid = Environment.ProcessId;
        var bat = new StringBuilder()
            .AppendLine("@echo off")
            .AppendLine("setlocal")
            .AppendLine($"set \"PID={pid}\"")
            .AppendLine($"set \"ZIP={zip}\"")
            .AppendLine($"set \"DIR={installDir}\"")
            .AppendLine($"set \"EXE={exePath}\"")
            .AppendLine("rem Wait for EdgeGlow to exit (up to ~30 s).")
            .AppendLine("set /a n=0")
            .AppendLine(":wait")
            .AppendLine("tasklist /FI \"PID eq %PID%\" 2>NUL | find \"%PID%\" >NUL")
            .AppendLine("if errorlevel 1 goto extract")
            .AppendLine("set /a n+=1")
            .AppendLine("if %n% GEQ 30 goto launch")
            .AppendLine("ping -n 2 127.0.0.1 >NUL")
            .AppendLine("goto wait")
            .AppendLine(":extract")
            .AppendLine("set /a tries=0")
            .AppendLine(":retry")
            .AppendLine("powershell -NoProfile -ExecutionPolicy Bypass -Command \"Expand-Archive -LiteralPath $env:ZIP -DestinationPath $env:DIR -Force\"")
            .AppendLine("if not errorlevel 1 goto launch")
            .AppendLine("set /a tries+=1")
            .AppendLine("if %tries% GEQ 5 goto launch")
            .AppendLine("ping -n 3 127.0.0.1 >NUL")
            .AppendLine("goto retry")
            .AppendLine(":launch")
            .AppendLine("del \"%ZIP%\" 2>NUL")
            .AppendLine("start \"\" \"%EXE%\"")
            .AppendLine("(goto) 2>NUL & del \"%~f0\"")
            .ToString();
        File.WriteAllText(script, bat, Encoding.ASCII);

        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"\"{script}\"\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        });
    }

    private static bool CanWrite(string dir)
    {
        try
        {
            var probe = Path.Combine(dir, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllBytes(probe, Array.Empty<byte>());
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    /// <summary>"v1.2.10", "1.2.1+abc123" and "1.2.1-beta" parse to 1.2.10 / 1.2.1.</summary>
    private static Version? Parse(string tag)
    {
        var s = tag.Trim().TrimStart('v', 'V');
        var end = s.IndexOfAny(new[] { '+', '-', ' ' });
        if (end >= 0) s = s[..end];
        if (!Version.TryParse(s, out var v)) return null;
        return new Version(v.Major, v.Minor, Math.Max(v.Build, 0));
    }
}
