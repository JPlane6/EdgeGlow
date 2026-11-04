namespace EdgeGlow;

/// <summary>What EdgeGlow shows: the rim glow, the lyrics, both, or nothing (standby: overlays, capture and polling stop).</summary>
public enum DisplayMode { Both, GlowOnly, LyricsOnly, Off }

public static class DisplayModeExtensions
{
    public static bool GlowOn(this DisplayMode m) => m is DisplayMode.Both or DisplayMode.GlowOnly;
    public static bool LyricsOn(this DisplayMode m) => m is DisplayMode.Both or DisplayMode.LyricsOnly;
    public static string Title(this DisplayMode m) => m switch
    {
        DisplayMode.Both => "Both", DisplayMode.GlowOnly => "Glow Only", DisplayMode.LyricsOnly => "Lyrics Only", _ => "Off",
    };
    public static DisplayMode FromKey(string? key) => System.Enum.TryParse<DisplayMode>(key, out var v) ? v : DisplayMode.Both;
}

/// <summary>The output route the lyrics are synced to (read-only in the UI: there is no manual offset).</summary>
public sealed record AudioRoute(string Name, bool IsBluetooth, double LatencyMs)
{
    public static readonly AudioRoute Unknown = new("Speakers", false, 15);
    public string Pill => $"Audio Sync: {Name} (Auto -{(int)System.Math.Round(LatencyMs)}ms)";
}
