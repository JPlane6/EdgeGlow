using System;
using System.Collections.Generic;

namespace EdgeGlow;

/// <summary>Plain sRGB color, cheap to lerp every frame and easy to persist (port of RGBColor).</summary>
public readonly record struct RgbColor(double R, double G, double B)
{
    public static readonly RgbColor NeonCyan = new(0.0, 0.90, 1.0);
    public static readonly RgbColor NeonMagenta = new(1.0, 0.16, 0.85);
    public static readonly RgbColor White = new(1, 1, 1);

    /// <summary>Relative luminance (Rec. 709), used to find the brightest part of a gradient.</summary>
    public double Luminance => 0.2126 * R + 0.7152 * G + 0.0722 * B;

    public static byte ToByte(double v) =>
        (byte)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);

    public string Hex => $"#{ToByte(R):X2}{ToByte(G):X2}{ToByte(B):X2}";

    public RgbColor Lerp(RgbColor to, double t) =>
        new(R + (to.R - R) * t, G + (to.G - G) * t, B + (to.B - B) * t);

    public double[] ToArray() => new[] { R, G, B };

    public static RgbColor? FromArray(double[]? a) =>
        a is { Length: 3 } ? new RgbColor(a[0], a[1], a[2]) : null;
}

public enum PlaybackState { Playing, Paused, Stopped }

public enum AnimationStyle
{
    /// <summary>Rotating dual-color rim pulsing with the bass (the original look).</summary>
    Breathing,
    /// <summary>Two comets with bright heads and fading tails racing clockwise around a dark bezel.</summary>
    Chasing,
    /// <summary>Mirrored comets running down both sides to merge at bottom-center, then back up.</summary>
    Symmetry,
    /// <summary>No rim at all: only the kinetic sparks fired inward by hard bass transients.</summary>
    SparksOnly,
}

public static class AnimationStyleExtensions
{
    public static string Title(this AnimationStyle s) => s switch
    {
        AnimationStyle.Breathing => "Breathing",
        AnimationStyle.Chasing => "Chasing",
        AnimationStyle.Symmetry => "Symmetry",
        _ => "Sparks Only",
    };

    public static string Glyph(this AnimationStyle s) => s switch
    {
        AnimationStyle.Breathing => "≋",
        AnimationStyle.Chasing => "↻",
        AnimationStyle.Symmetry => "⇅",
        _ => "✦",
    };

    public static string Caption(this AnimationStyle s) => s switch
    {
        AnimationStyle.Breathing => "Rotating two-color rim that pulses with the kick",
        AnimationStyle.Chasing => "Comets chase the bezel, faster on vocals, fuller on bass",
        AnimationStyle.Symmetry => "Mirrored comets sweep both sides, alternating top-to-bottom and back",
        _ => "Dark edges. Only hard bass hits throw sparks inward",
    };

    /// <summary>Styles that draw comets, and so use the Comet Length setting.</summary>
    public static bool UsesComets(this AnimationStyle s) => s is AnimationStyle.Chasing or AnimationStyle.Symmetry;

    public static string Key(this AnimationStyle s) => s switch
    {
        AnimationStyle.Breathing => "breathing",
        AnimationStyle.Chasing => "chasing",
        AnimationStyle.Symmetry => "symmetry",
        _ => "sparksOnly",
    };

    public static AnimationStyle FromKey(string? key) => key switch
    {
        "chasing" => AnimationStyle.Chasing,
        "symmetry" => AnimationStyle.Symmetry,
        "sparksOnly" => AnimationStyle.SparksOnly,
        _ => AnimationStyle.Breathing,
    };
}

/// <summary>Where the current music (and its metadata) comes from, in detection priority order.</summary>
public enum MediaSource { Spotify, AppleMusic, Browser, SystemAudio }

public static class MediaSourceExtensions
{
    public static string DisplayName(this MediaSource s) => s switch
    {
        MediaSource.Spotify => "Spotify",
        MediaSource.AppleMusic => "Apple Music",
        MediaSource.Browser => "Browser",
        _ => "System Audio",
    };

    public static string Glyph(this MediaSource s) => s switch
    {
        MediaSource.Spotify or MediaSource.AppleMusic => "♪",
        MediaSource.Browser => "◎",
        _ => "♫",
    };

    /// <summary>Native players report a trustworthy track position, which Cloud Sync needs.</summary>
    public static bool ReportsPosition(this MediaSource s) => s is MediaSource.Spotify or MediaSource.AppleMusic;
}

/// <summary>Track metadata as reported by one provider.</summary>
public sealed record NowPlayingInfo(string Title, string Artist, string? ArtworkUrl, double? Position, double? Duration);

/// <summary>Which signal is driving the glow's bass/vocal energies.</summary>
public enum LevelSource { None, Live, CloudSync }

public enum AudioCaptureStatus { Off, Starting, Live, Failed }

/// <summary>A connected display as shown in the flyout's display picker.</summary>
public sealed record DisplayInfo(string Id, string Name, bool IsBuiltIn);
