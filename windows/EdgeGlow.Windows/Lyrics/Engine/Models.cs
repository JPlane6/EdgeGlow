using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace EdgeGlow.Lyrics;

public enum LyricTier { WordLevel, Interpolated }

public sealed record TimedWord(int Id, string Text, double Start, double End, int Line)
{
    public double Duration => Math.Max(0, End - Start);
}

public readonly record struct LineCursor(int? Index, int? Next);

/// <summary>Timed lyrics: every word with its time, plus the words grouped into lines.</summary>
public sealed class TimedLyrics
{
    public LyricTier Tier { get; init; }
    public List<TimedWord> Words { get; init; } = new();
    public List<List<TimedWord>> Groups { get; init; } = new();
    public string Source { get; init; } = "";

    public bool IsEmpty => Groups.Count == 0;
    public double FirstOnset => Words.Count > 0 ? Words[0].Start : 0;
    public double LastEnd => Words.Count > 0 ? Words[^1].End : 0;

    public string LineText(int index) =>
        index >= 0 && index < Groups.Count ? string.Join(" ", Groups[index].Select(w => w.Text)) : "";

    /// <summary>Which line should be on screen at <paramref name="pos"/>.</summary>
    public LineCursor Cursor(double pos)
    {
        if (Groups.Count == 0) return new LineCursor(null, null);
        int lo = 0, hi = Groups.Count - 1, found = -1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            var first = Groups[mid].Count > 0 ? Groups[mid][0].Start : double.PositiveInfinity;
            if (first - 0.35 <= pos) { found = mid; lo = mid + 1; } else hi = mid - 1;
        }
        if (found < 0) return new LineCursor(null, 0);
        int? next = found + 1 < Groups.Count ? found + 1 : null;
        var end = Groups[found].Count > 0 ? Groups[found][^1].End : 0;
        if (pos > end + 2.5) return new LineCursor(null, next);
        return new LineCursor(found, next);
    }

    /// <summary>Same timings with every word's text replaced (used for romanization).</summary>
    public TimedLyrics Map(Func<string, string> transform)
    {
        var words = Words.Select(w => w with { Text = transform(w.Text) }).ToList();
        var groups = Groups.Select(g => g.Select(w => words[w.Id]).ToList()).ToList();
        return new TimedLyrics { Tier = Tier, Words = words, Groups = groups, Source = Source };
    }
}

/// <summary>LRC parsing and syllable-weighted word timing (a port of the macOS LyricsProvider math).</summary>
public static class LrcParser
{
    private static readonly Regex Stamp = new(@"\[(\d+):(\d+(?:[.:]\d+)?)\]", RegexOptions.Compiled);
    private static readonly Regex Credit = new(
        @"(producer|produced|composed|composer|lyrics by|lyricist|written by|arranged|arrangement|作词|作曲|编曲|制作|监制|混音|母带)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex Bracket = new(@"^\s*\[[^\]]*\]\s*$", RegexOptions.Compiled);

    public static List<(double Start, string Text)> Parse(string lrc)
    {
        var rows = new List<(double, string)>();
        foreach (var raw in lrc.Split('\n', '\r'))
        {
            var ms = Stamp.Matches(raw);
            if (ms.Count == 0) continue;
            var last = ms[^1];
            var text = raw[(last.Index + last.Length)..].Trim();
            foreach (Match m in ms)
            {
                double.TryParse(m.Groups[1].Value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var mins);
                double.TryParse(m.Groups[2].Value.Replace(':', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var secs);
                rows.Add((mins * 60 + secs, text));
            }
        }
        rows.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        var outRows = new List<(double, string)>();
        foreach (var r in rows)
        {
            if (outRows.Count > 0 && Math.Abs(outRows[^1].Item1 - r.Item1) < 0.001) continue;   // translation of the same line
            outRows.Add(r);
        }
        return outRows.Select(r => (r.Item1, r.Item2)).ToList();
    }

    public static bool IsCreditLine(string text, int position)
    {
        if (Bracket.IsMatch(text)) return true;
        return position < 10 && Credit.IsMatch(text);
    }

    public static TimedLyrics? Interpolate(string lrc, double trackDuration, string source) =>
        Interpolate(Parse(lrc), trackDuration, source);

    public static TimedLyrics? Interpolate(List<(double Start, string Text)> rows, double trackDuration, string source)
    {
        var lines = new List<List<(string Text, double Start, double End)>>();
        var kept = 0;
        for (var i = 0; i < rows.Count; i++)
        {
            var (start, text) = rows[i];
            if (text.Length == 0) continue;
            if (IsCreditLine(text, kept)) continue;
            kept++;
            var nextStart = i + 1 < rows.Count ? rows[i + 1].Start : (trackDuration > start ? trackDuration : start + 5);
            var tokenCount = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
            var letterCount = text.Count(char.IsLetterOrDigit);
            var sungEstimate = Math.Max(2.0, 0.55 * tokenCount + 0.08 * letterCount);
            var lineEnd = Math.Min(nextStart, start + Math.Min(9, sungEstimate));
            var words = WeightedWords(text, start, lineEnd);
            if (words.Count > 0) lines.Add(words);
        }
        if (lines.Count < 2) return null;
        return Build(lines, LyricTier.Interpolated, source);
    }

    public static bool IsCjk(int cp) =>
        (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3040 && cp <= 0x30FF) || (cp >= 0xAC00 && cp <= 0xD7AF) || (cp >= 0x3400 && cp <= 0x4DBF);

    private const string Vowels = "aeiouyAEIOUYàáâäæãåāèéêëēėęîïíīįìôöòóœøōõûüùúūÿ";

    public static List<(string Text, double Start, double End)> WeightedWords(string text, double start, double end)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in text)
        {
            if (char.IsWhiteSpace(ch)) { if (current.Length > 0) { tokens.Add(current.ToString()); current.Clear(); } }
            else if (IsCjk(ch)) { if (current.Length > 0) { tokens.Add(current.ToString()); current.Clear(); } tokens.Add(ch.ToString()); }
            else current.Append(ch);
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        if (tokens.Count == 0) return new();

        (double Sung, double Pause) Weight(string t)
        {
            var letters = t.Where(char.IsLetterOrDigit).ToArray();
            var v = letters.Count(c => Vowels.Contains(c));
            var cjk = IsCjk(t[0]);
            var w = cjk ? 1.6 : Math.Max(1, v) * 1.0 + letters.Length * 0.22;
            if (letters.Length == 0) w = 0.3;
            var p = 0.0;
            var last = t[^1];
            if (",;:–—".Contains(last)) p = 0.7;
            else if (".!?…。！？".Contains(last)) p = 1.3;
            return (w, p);
        }
        var ws = tokens.Select(Weight).ToList();
        var tail = Math.Min(0.2, (end - start) * 0.06);
        var avail = Math.Max(0.2, end - start - tail);
        var total = ws.Sum(x => x.Sung + x.Pause);
        var scale = avail / Math.Max(0.001, total);
        var result = new List<(string, double, double)>();
        var cursor = start;
        for (var i = 0; i < tokens.Count; i++)
        {
            var dur = ws[i].Sung * scale;
            result.Add((tokens[i], cursor, cursor + dur));
            cursor += dur + ws[i].Pause * scale;
        }
        return result;
    }

    public static TimedLyrics Build(List<List<(string Text, double Start, double End)>> lines, LyricTier tier, string source)
    {
        var words = new List<TimedWord>();
        var groups = new List<List<TimedWord>>();
        for (var li = 0; li < lines.Count; li++)
        {
            var g = new List<TimedWord>();
            foreach (var w in lines[li])
            {
                var tw = new TimedWord(words.Count, w.Text, w.Start, w.End, li);
                words.Add(tw); g.Add(tw);
            }
            groups.Add(g);
        }
        return new TimedLyrics { Tier = tier, Words = words, Groups = groups, Source = source };
    }
}
