using System;
using System.Collections.Generic;
using System.Numerics;
using SkiaSharp;

namespace EdgeGlow.Lyrics;

/// <summary>The 11 lyric styles (same set and order as macOS).</summary>
public enum LyricStyle { Ship, Visual, Fisheye, FisheyeVisual, Constellation, Branches, Web, CodestyleVisual, Constellation3D, HyperShip3D, OrbitalWeb3D }

public static class LyricStyleInfo
{
    public static string Title(this LyricStyle s) => s switch
    {
        LyricStyle.Ship => "Ship", LyricStyle.Visual => "Visual", LyricStyle.Fisheye => "Fisheye", LyricStyle.FisheyeVisual => "Fisheye Visual",
        LyricStyle.Constellation => "Constellation", LyricStyle.Branches => "Branches", LyricStyle.Web => "Web",
        LyricStyle.CodestyleVisual => "Codestyle Visual", LyricStyle.Constellation3D => "Constellation 3D",
        LyricStyle.HyperShip3D => "HyperShip 3D", LyricStyle.OrbitalWeb3D => "Orbital Web 3D", _ => s.ToString(),
    };

    public static bool ShowsIcons(this LyricStyle s) =>
        s is LyricStyle.Visual or LyricStyle.FisheyeVisual or LyricStyle.CodestyleVisual or LyricStyle.HyperShip3D;

    public static string Key(this LyricStyle s) => s.ToString();
    public static LyricStyle FromKey(string? key) => Enum.TryParse<LyricStyle>(key, out var v) ? v : LyricStyle.Constellation;
}

/// <summary>The 7 fonts. Each maps a macOS face to its closest Windows face.</summary>
public enum LyricFont { SfPro, Rounded, Serif, Helvetica, Avenir, Futura, Didot }

public static class LyricFontInfo
{
    public static string Title(this LyricFont f) => f switch
    {
        LyricFont.SfPro => "SF Pro / Segoe UI Variable", LyricFont.Rounded => "Rounded", LyricFont.Serif => "Serif / Georgia",
        LyricFont.Helvetica => "Helvetica / Arial Bold", LyricFont.Avenir => "Avenir / Century Gothic",
        LyricFont.Futura => "Futura / Bahnschrift", LyricFont.Didot => "Didot / Bodoni", _ => f.ToString(),
    };
    public static LyricFont FromKey(string? key) => Enum.TryParse<LyricFont>(key, out var v) ? v : LyricFont.SfPro;
}

public sealed record LyricTheme(LyricFont Font, Vector4 Highlight, Vector4 Secondary, double Scale);

/// <summary>Everything a scene needs to draw one frame.</summary>
public sealed class SceneInput
{
    public required TimedLyrics Lyrics { get; init; }
    public required double Pos { get; init; }
    public required LyricTheme Theme { get; init; }
    /// <summary>Drawable size in pixels.</summary>
    public required float Width { get; init; }
    public required float Height { get; init; }
    public double Bass { get; init; }
    public double Vocal { get; init; }
    /// <summary>Onset velocity 0..1 (spikes on each vocal onset).</summary>
    public double Velocity { get; init; }
    public double Time { get; init; }
    public double FocusY { get; init; } = 0.5;

    private LineCursor? _cursor;
    public LineCursor Cursor => _cursor ??= Lyrics.Cursor(Pos);

    public double Progress(TimedWord w)
    {
        if (w.Duration <= 0.001) return Pos >= w.Start ? 1 : 0;
        return Math.Clamp((Pos - w.Start) / w.Duration, 0, 1);
    }

    private int? _active; private bool _activeDone;
    public int? ActiveWord
    {
        get
        {
            if (_activeDone) return _active;
            _activeDone = true;
            var words = Lyrics.Words;
            int lo = 0, hi = words.Count - 1, found = -1;
            while (lo <= hi)
            {
                var mid = (lo + hi) / 2;
                if (words[mid].Start <= Pos) { found = mid; lo = mid + 1; } else hi = mid - 1;
            }
            _active = found >= 0 ? found : null;
            return _active;
        }
    }
}

public static class CanvasKit
{
    public static double Spring(double t) => t <= 0 ? 0 : 1 - Math.Exp(-9 * t) * Math.Cos(16 * t);
    public static double Smoothstep(double x) { var t = Math.Clamp(x, 0, 1); return t * t * (3 - 2 * t); }
    public static double Hash(int seed)
    {
        var x = unchecked((ulong)((long)seed * unchecked((long)0x9E3779B97F4A7C15UL)));
        x ^= x >> 30; x = unchecked(x * 0xBF58476D1CE4E5B9UL);
        x ^= x >> 27; x = unchecked(x * 0x94D049BB133111EBUL);
        x ^= x >> 31;
        return (x % 1_000_000UL) / 1_000_000.0;
    }
}

/// <summary>A laid-out run of text at a fixed raster size, with the tight -0.03em tracking.</summary>
public sealed class TextRun
{
    public const float RasterSize = 100;
    public SKTextBlob? Blob { get; init; }
    public float Width { get; init; }
    public float Ascent { get; init; }      // negative, as Skia reports it
    public float Height { get; init; }
}

/// <summary>Resolves the 7 fonts to installed faces (Windows names first, macOS names so previews work there) and caches runs.</summary>
public static class TextMetrics
{
    private static readonly Dictionary<LyricFont, string[]> Families = new()
    {
        [LyricFont.SfPro] = new[] { "Segoe UI Variable Display", "Segoe UI Variable", "Segoe UI", "SF Pro Display", "Helvetica Neue" },
        [LyricFont.Rounded] = new[] { "Arial Rounded MT Bold", "Segoe UI Rounded", "Nirmala UI", "Varela Round", "SF Pro Rounded", "Avenir Next Rounded", "Arial" },
        [LyricFont.Serif] = new[] { "Georgia", "Cambria", "New York", "Times New Roman" },
        [LyricFont.Helvetica] = new[] { "Arial", "Helvetica Neue", "Helvetica" },
        [LyricFont.Avenir] = new[] { "Century Gothic", "Avenir Next", "Avenir", "Segoe UI" },
        [LyricFont.Futura] = new[] { "Bahnschrift", "Futura", "Century Gothic", "Segoe UI" },
        [LyricFont.Didot] = new[] { "Bodoni MT", "Didot", "Bodoni 72", "Georgia" },
    };
    private static readonly string[] MonoFamilies = { "Cascadia Mono", "Cascadia Code", "Consolas", "JetBrains Mono", "SF Mono", "Menlo", "Courier New" };
    private static readonly string[] EmojiFamilies = { "Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji" };

    private static HashSet<string>? _installed;
    private static readonly Dictionary<string, SKTypeface> TypefaceCache = new();
    private static readonly Dictionary<string, TextRun> RunCache = new();
    private static readonly Dictionary<string, SKFont> FontCache = new();

    private static bool Has(string family)
    {
        _installed ??= new HashSet<string>(SKFontManager.Default.FontFamilies, StringComparer.OrdinalIgnoreCase);
        return _installed.Contains(family);
    }

    public static SKTypeface Typeface(LyricFont font, bool mono, bool emoji = false)
    {
        var key = emoji ? "emoji" : mono ? "mono" : font.ToString();
        if (TypefaceCache.TryGetValue(key, out var hit)) return hit;
        var names = emoji ? EmojiFamilies : mono ? MonoFamilies : Families[font];
        var weight = font is LyricFont.Helvetica ? SKFontStyleWeight.Bold : SKFontStyleWeight.SemiBold;
        if (mono) weight = SKFontStyleWeight.Medium;
        SKTypeface? tf = null;
        foreach (var n in names)
            if (Has(n)) { tf = SKTypeface.FromFamilyName(n, weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright); break; }
        tf ??= SKTypeface.FromFamilyName(null, weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright) ?? SKTypeface.Default;
        return TypefaceCache[key] = tf;
    }

    public static SKFont Font(LyricFont font, bool mono, float size, bool emoji = false)
    {
        var key = $"{(emoji ? "e" : mono ? "m" : font.ToString())}|{size}";
        if (FontCache.TryGetValue(key, out var f)) return f;
        f = new SKFont(Typeface(font, mono, emoji), size) { Subpixel = true, Edging = SKFontEdging.SubpixelAntialias, Hinting = SKFontHinting.None };
        return FontCache[key] = f;
    }

    /// <summary>Width of <paramref name="text"/> at <paramref name="size"/>, with -0.03em tracking.</summary>
    public static float Width(string text, LyricFont font, float size, bool mono = false) =>
        Run(text, font, mono).Width * size / TextRun.RasterSize;

    public static TextRun Run(string text, LyricFont font, bool mono, bool emoji = false)
    {
        var key = $"{(emoji ? "e" : mono ? "m" : font.ToString())}|{text}";
        if (RunCache.TryGetValue(key, out var run)) return run;
        if (RunCache.Count > 5000) RunCache.Clear();
        var f = Font(font, mono, mono ? TextRun.RasterSize * 0.8f : TextRun.RasterSize, emoji);
        var m = f.Metrics;
        var glyphs = f.Typeface!.GetGlyphs(text);
        var widths = new float[glyphs.Length];
        f.GetGlyphWidths(glyphs, widths, Span<SKRect>.Empty, null);
        var track = emoji ? 0 : -0.03f * f.Size;
        var positions = new SKPoint[glyphs.Length];
        var x = 0f;
        for (var i = 0; i < glyphs.Length; i++) { positions[i] = new SKPoint(x, 0); x += widths[i] + track; }
        if (glyphs.Length > 0) x -= track;
        using var builder = new SKTextBlobBuilder();
        builder.AddPositionedRun(glyphs, f, positions);
        run = new TextRun { Blob = builder.Build(), Width = Math.Max(x, 1), Ascent = m.Ascent, Height = Math.Max(m.Descent - m.Ascent, 1) };
        return RunCache[key] = run;
    }
}
