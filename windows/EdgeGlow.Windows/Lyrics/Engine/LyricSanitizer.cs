using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace EdgeGlow.Lyrics;

/// <summary>Metadata cleanup and candidate ranking (a 1:1 port of the macOS LyricSanitizer).</summary>
public static class LyricSanitizer
{
    private static readonly Regex[] Noise = new[]
    {
        @"[\[\(]\s*(from|theme from|music from)\s*[:\-]?\s*[“""'‘][^\]\)]*[\]\)]",
        @"\s[-–—]\s*from\s*[“""'‘].*$",
        @"[\[\(]\s*from\s+[^\]\)]*[\]\)]",
        @"[\[\(][^\]\)]*original motion picture soundtrack[^\]\)]*[\]\)]",
        @"[\[\(][^\]\)]*(official|lyrical|lyric|full|music|audio|video|visuali[sz]er|hd|4k|hq|mv)[^\]\)]*(video|audio|song|visuali[sz]er|version)?[^\]\)]*[\]\)]",
        @"[\[\(][^\]\)]*(slowed|reverb|lofi|lo-fi|flip|sped up|nightcore|8d|bass boosted)[^\]\)]*[\]\)]",
        @"\b(full\s+video|full\s+song|lyrical\s+video|official\s+video|official\s+audio)\b",
        @"\s[-–—|]\s*(t-series|sony music( india)?|yrf|zee music( company)?|saregama( music)?|tips( official| music)?|speed records|white hill music|times music|desi melodies|jio ?saavn|think music|lahari music|aditya music|eros now music|venus|universal music( india)?|warner music( india)?)\s*$",
        @"\s*\|\s.*$",
        @"\s*-\s*Topic$",
        @"\bVEVO\b",
    }.Select(p => new Regex(p, RegexOptions.IgnoreCase | RegexOptions.Compiled)).ToArray();

    public static string Clean(string s)
    {
        var o = s;
        foreach (var re in Noise) o = re.Replace(o, "");
        while (o.Contains("  ")) o = o.Replace("  ", " ");
        return o.Trim(' ', '-', '–', '—', '|', '\t', '\n', '\r');
    }

    private static readonly string[] ArtistSeparators =
        { " feat.", " ft.", " featuring ", " & ", ", ", " x ", " × ", " with ", " and ", ";", "/", " , " };

    /// <summary>"Artist 1, Artist 2 &amp; Composer feat. X" gives "Artist 1".</summary>
    public static string PrimaryArtist(string artist)
    {
        var a = Clean(artist);
        foreach (var sep in ArtistSeparators)
        {
            var i = a.IndexOf(sep, StringComparison.OrdinalIgnoreCase);
            if (i >= 0) a = a[..i];
        }
        return a.Trim();
    }

    public static (string Title, string Artist) Sanitize(string title, string artist)
    {
        string t = title, a = artist;
        var lowered = a.ToLowerInvariant();
        var dash = t.IndexOf(" - ", StringComparison.Ordinal);
        if (dash >= 0 && (a.Length == 0 || lowered.Contains("topic") || lowered.Contains("vevo") || t.ToLowerInvariant().StartsWith(lowered + " - ")))
        {
            a = t[..dash];
            t = t[(dash + 3)..];
        }
        return (Clean(t), PrimaryArtist(a));
    }

    private static HashSet<string> Tokens(string s)
    {
        var folded = s.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder();
        foreach (var c in folded)
            if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark) sb.Append(char.IsLetterOrDigit(c) ? c : ' ');
        return new HashSet<string>(sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary>Jaccard similarity of word sets, 0 to 1.</summary>
    public static double Similarity(string a, string b)
    {
        var x = Tokens(a); var y = Tokens(b);
        if (x.Count == 0 || y.Count == 0) return 0;
        return (double)x.Intersect(y).Count() / x.Union(y).Count();
    }

    /// <summary>Candidate score for the fuzzy-search stage; null when the duration is out of tolerance.</summary>
    public static double? Score(string title, string artist, string candidateTitle, string candidateArtist,
                                double duration, double candidateDuration, double tolerance = 8)
    {
        if (duration > 0 && candidateDuration > 0 && Math.Abs(duration - candidateDuration) > tolerance) return null;
        var t = Similarity(title, candidateTitle);
        if (t < 0.34) return null;
        var a = artist.Length == 0 ? 0.5 : Math.Max(Similarity(artist, candidateArtist), Tokens(candidateArtist).IsSupersetOf(Tokens(artist)) ? 1 : 0);
        var d = duration > 0 && candidateDuration > 0 ? 1 - Math.Abs(duration - candidateDuration) / tolerance : 0.5;
        return t * 3 + a * 1.5 + d;
    }

    /// <summary>No synced lyrics exist: spread plain lines across the song in proportion to their length.</summary>
    public static string? SpreadPlain(string plain, double duration)
    {
        var lines = plain.Split('\n', '\r').Select(l => l.Trim()).Where(l => l.Length > 0 && !(l.StartsWith('[') && l.EndsWith(']'))).ToList();
        if (lines.Count < 4 || duration <= 20) return null;
        var start = Math.Min(18, duration * 0.08); var end = duration * 0.94;
        var weights = lines.Select(l => (double)Math.Max(l.Length, 6)).ToList();
        var total = weights.Sum();
        var t = start;
        var rows = new List<string>();
        for (var i = 0; i < lines.Count; i++)
        {
            rows.Add(string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[{(int)t / 60:00}:{t % 60:00.00}]{lines[i]}"));
            t += (end - start) * weights[i] / total;
        }
        return string.Join("\n", rows);
    }
}
