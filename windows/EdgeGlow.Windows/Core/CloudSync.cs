using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace EdgeGlow;

// Cloud Sync: when a track plays on a remote speaker (Spotify Connect, ...) this PC hears nothing, so the
// glow is driven by the track's tempo and synced lyrics instead. Public web APIs plus pure math.

/// <summary>One sung lyric line with its estimated vocal cadence.</summary>
public sealed record LyricLine(double Start, double End, double SyllablesPerSecond, double Cadence);

public static class LyricsParser
{
    /// <summary>Parses LRC text ([mm:ss.xx] line, several timestamps per line allowed) into timed lines.</summary>
    public static List<LyricLine> Parse(string lrc)
    {
        var entries = new List<(double Time, string Text)>();
        foreach (var raw in lrc.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None))
        {
            var rest = raw;
            var times = new List<double>();
            while (rest.StartsWith('['))
            {
                var close = rest.IndexOf(']');
                if (close < 0) break;
                var tag = rest.Substring(1, close - 1);
                rest = rest.Substring(close + 1);
                var t = Timestamp(tag);
                if (t.HasValue) times.Add(t.Value);
            }
            var text = rest.Trim(' ', '\t');
            foreach (var time in times) entries.Add((time, text));
        }
        entries = entries.OrderBy(e => e.Time).ToList(); // stable

        var lines = new List<LyricLine>();
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            var syllables = SyllableCount(entry.Text);
            if (syllables <= 0) continue;
            var next = index + 1 < entries.Count ? entries[index + 1].Time : entry.Time + 6;
            // Back-to-back lines are sung across the whole gap; before an instrumental break assume a
            // typical ~3 syllables per second instead of stretching the line over the break.
            var gap = Math.Max(next - entry.Time, 0.3);
            var duration = Math.Min(gap, Math.Max(1.2, syllables / 3.0));
            var rate = syllables / duration;
            var cadence = Math.Min(Math.Max((rate - 2) / 4, 0), 1);
            lines.Add(new LyricLine(entry.Time, entry.Time + duration, rate, cadence));
        }
        return lines;
    }

    /// <summary>mm:ss, mm:ss.xx or mm:ss:xx; null for metadata tags like [ar:Artist].</summary>
    private static double? Timestamp(string tag)
    {
        var colon = tag.IndexOf(':');
        if (colon < 0) return null;
        if (!double.TryParse(tag.AsSpan(0, colon), NumberStyles.Float, CultureInfo.InvariantCulture, out var minutes)) return null;
        var seconds = tag.Substring(colon + 1).Replace(':', '.');
        if (!double.TryParse(seconds, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return null;
        return minutes * 60 + value;
    }

    private static readonly HashSet<char> Vowels = new("aeiouyàáâãäåèéêëìíîïòóôõöùúûüýÿæœ");

    /// <summary>Vowel groups per Latin word; one per character for scripts without spaces between syllables (CJK).</summary>
    public static int SyllableCount(string text)
    {
        var count = 0;
        foreach (var word in SplitWords(text.ToLowerInvariant()))
        {
            if (word.Any(c => c < 128))
            {
                var groups = 0;
                var inVowel = false;
                foreach (var c in word)
                {
                    var isVowel = Vowels.Contains(c);
                    if (isVowel && !inVowel) groups++;
                    inVowel = isVowel;
                }
                if (groups > 1 && word.EndsWith('e') && !word.EndsWith("le", StringComparison.Ordinal)) groups--;
                count += Math.Max(groups, 1);
            }
            else
            {
                count += word.Length;
            }
        }
        return count;
    }

    private static IEnumerable<string> SplitWords(string text)
    {
        var start = -1;
        for (var i = 0; i <= text.Length; i++)
        {
            var isWordChar = i < text.Length && (char.IsLetter(text[i]) || text[i] == '\'');
            if (isWordChar)
            {
                if (start < 0) start = i;
            }
            else if (start >= 0)
            {
                yield return text.Substring(start, i - start);
                start = -1;
            }
        }
    }
}

/// <summary>Public, keyless web APIs used to fill in what a player doesn't report.</summary>
public static class MediaMetadataService
{
    private static readonly HttpClient Http = CreateClient();
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("EdgeGlow/1.0 (Windows ambient lighting app)");
        return client;
    }

    /// <summary>Downloads raw bytes (cover art).</summary>
    public static async Task<byte[]?> DownloadAsync(string url)
    {
        try
        {
            using var response = await Http.GetAsync(url).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            return await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>600x600 cover from the iTunes Search API, falling back to Deezer's large cover.</summary>
    public static async Task<string?> ArtworkUrlAsync(string title, string artist)
    {
        var term = $"{PrimaryArtist(artist)} {CleanTitle(title)}".Trim();
        var response = await Fetch<ITunesSearch>("https://itunes.apple.com/search",
            new() { ["term"] = term, ["entity"] = "song", ["limit"] = "1" }).ConfigureAwait(false);
        var small = response?.Results?.FirstOrDefault()?.ArtworkUrl100;
        if (small != null) return small.Replace("100x100bb", "600x600bb");
        return (await DeezerTrackAsync(title, artist).ConfigureAwait(false))?.Album?.CoverXl;
    }

    /// <summary>Tempo from Deezer's track details. Deezer reports 0 for tracks it hasn't analyzed.</summary>
    public static async Task<double?> BpmAsync(string title, string artist)
    {
        var track = await DeezerTrackAsync(title, artist).ConfigureAwait(false);
        if (track == null) return null;
        var detail = await Fetch<DeezerTrackDetail>($"https://api.deezer.com/track/{track.Id}", new()).ConfigureAwait(false);
        var bpm = detail?.Bpm;
        return bpm is > 40 and < 250 ? bpm : null;
    }

    /// <summary>Synced lyrics from LRCLIB: the exact-match endpoint first, then its search.</summary>
    public static async Task<List<LyricLine>?> SyncedLyricsAsync(string title, string artist, double? duration)
    {
        var track = CleanTitle(title);
        var artistName = PrimaryArtist(artist);
        var query = new Dictionary<string, string> { ["track_name"] = track, ["artist_name"] = artistName };
        if (duration is > 0) query["duration"] = ((int)Math.Round(duration.Value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);

        var exact = await Fetch<LrclibRecord>("https://lrclib.net/api/get", query).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(exact?.SyncedLyrics))
        {
            var lines = LyricsParser.Parse(exact!.SyncedLyrics!);
            if (lines.Count > 0) return lines;
        }

        var results = await Fetch<LrclibRecord[]>("https://lrclib.net/api/search",
            new() { ["track_name"] = track, ["artist_name"] = artistName }).ConfigureAwait(false);
        if (results == null) return null;
        // Prefer the synced result whose length is closest to the playing track.
        var best = results
            .Where(r => !string.IsNullOrEmpty(r.SyncedLyrics))
            .OrderBy(r => Math.Abs((r.Duration ?? 0) - (duration ?? 0)))
            .FirstOrDefault();
        if (best?.SyncedLyrics == null) return null;
        var parsed = LyricsParser.Parse(best.SyncedLyrics);
        return parsed.Count == 0 ? null : parsed;
    }

    private static async Task<DeezerTrack?> DeezerTrackAsync(string title, string artist)
    {
        var track = CleanTitle(title);
        var artistName = PrimaryArtist(artist);
        var strict = await Fetch<DeezerSearch>("https://api.deezer.com/search",
            new() { ["q"] = $"artist:\"{artistName}\" track:\"{track}\"" }).ConfigureAwait(false);
        var first = strict?.Data?.FirstOrDefault();
        if (first != null) return first;
        var loose = await Fetch<DeezerSearch>("https://api.deezer.com/search",
            new() { ["q"] = $"{artistName} {track}" }).ConfigureAwait(false);
        return loose?.Data?.FirstOrDefault();
    }

    private static async Task<T?> Fetch<T>(string baseUrl, Dictionary<string, string> query) where T : class
    {
        var qs = string.Join("&", query.OrderBy(k => k.Key, StringComparer.Ordinal)
            .Select(k => $"{Uri.EscapeDataString(k.Key)}={Uri.EscapeDataString(k.Value)}"));
        var url = qs.Length > 0 ? $"{baseUrl}?{qs}" : baseUrl;
        try
        {
            using var response = await Http.GetAsync(url).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            await using var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Drops "- Remastered 2011", "(feat. X)" and similar decorations that break exact-match lookups.</summary>
    public static string CleanTitle(string title)
    {
        var result = title;
        var dash = result.IndexOf(" - ", StringComparison.Ordinal);
        if (dash >= 0) result = result.Substring(0, dash);
        var markers = new[] { "feat", "ft.", "with ", "remaster", "version", "edit" };
        foreach (var (open, close) in new[] { ('(', ')'), ('[', ']') })
        {
            while (true)
            {
                var start = result.IndexOf(open);
                if (start < 0) break;
                var end = result.IndexOf(close, start + 1);
                if (end < 0) break;
                var inner = result.Substring(start + 1, end - start - 1).ToLowerInvariant();
                if (!markers.Any(m => inner.Contains(m, StringComparison.Ordinal))) break;
                result = result.Remove(start, end - start + 1);
            }
        }
        return result.Trim();
    }

    public static string PrimaryArtist(string artist)
    {
        var result = artist;
        foreach (var separator in new[] { ", ", " & ", " feat. ", " x " })
        {
            var index = result.IndexOf(separator, StringComparison.Ordinal);
            if (index >= 0) result = result.Substring(0, index);
        }
        return result.Trim();
    }

    // Response shapes (only the fields EdgeGlow reads).
    private sealed class ITunesSearch
    {
        public List<ITunesResult>? Results { get; set; }
    }
    private sealed class ITunesResult
    {
        [JsonPropertyName("artworkUrl100")] public string? ArtworkUrl100 { get; set; }
    }
    private sealed class DeezerSearch
    {
        [JsonPropertyName("data")] public List<DeezerTrack>? Data { get; set; }
    }
    private sealed class DeezerTrack
    {
        [JsonPropertyName("id")] public long Id { get; set; }
        [JsonPropertyName("album")] public DeezerAlbum? Album { get; set; }
    }
    private sealed class DeezerAlbum
    {
        [JsonPropertyName("cover_xl")] public string? CoverXl { get; set; }
    }
    private sealed class DeezerTrackDetail
    {
        [JsonPropertyName("bpm")] public double? Bpm { get; set; }
    }
    private sealed class LrclibRecord
    {
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; set; }
        [JsonPropertyName("duration")] public double? Duration { get; set; }
    }
}

/// <summary>
/// Turns a track's tempo and lyric timing into bass/vocal energies shaped like the live FFT output, so the
/// renderer's pulse, transient detection, sparks and comet speed all behave the same.
/// </summary>
public sealed class CloudSyncEngine
{
    public const double DefaultBpm = 122.0;

    private readonly object _lock = new();
    private string _trackKey = "";
    private double _bpm = DefaultBpm;
    private List<LyricLine> _lines = new();
    private bool _nativePlaying;
    private double _vocalEnvelope = 0.08;

    /// <summary>True while a native player (Spotify, Apple Music) reports playback with a usable position.</summary>
    public bool NativePlaybackActive { get { lock (_lock) return _nativePlaying; } }

    public void SetNativePlaybackActive(bool active) { lock (_lock) _nativePlaying = active; }

    /// <summary>Forgets the previous track's tempo and lyrics; lookups for <paramref name="key"/> fill them back in.</summary>
    public void BeginTrack(string key)
    {
        lock (_lock) { _trackKey = key; _bpm = DefaultBpm; _lines = new List<LyricLine>(); }
    }

    /// <summary>Ignored when the track has already changed again.</summary>
    public void Update(string key, double? bpm = null, List<LyricLine>? lines = null)
    {
        lock (_lock)
        {
            if (key != _trackKey) return;
            if (bpm.HasValue) _bpm = bpm.Value;
            if (lines != null) _lines = lines;
        }
    }

    /// <summary>Energies at <paramref name="trackTime"/> seconds into the song; <paramref name="dt"/> is the time since the previous call.</summary>
    public (double Bass, double Vocal) Levels(double trackTime, double dt)
    {
        lock (_lock)
        {
            var beat = 60 / _bpm;
            var t = Math.Max(trackTime, 0);

            // Bass: a kick on every beat (accented downbeat), sharp 12 ms attack and ~130 ms decay, which
            // trips the renderer's transient detector just like a real kick does.
            var beatIndex = Math.Floor(t / beat);
            var sinceBeat = t - beatIndex * beat;
            const double attack = 0.012;
            var kick = sinceBeat < attack ? sinceBeat / attack : Math.Exp(-(sinceBeat - attack) / 0.13);
            var accent = (long)beatIndex % 4 == 0 ? 1.0 : 0.82;
            var bass = 0.06 + 0.94 * accent * kick;

            // Vocals: the active line's cadence (slow ~0.4, fast 0.85-1.0, with a slight syllable-rate
            // shimmer), easing down to 0.08 in the gaps. Without lyrics, swell over 4-bar phrases.
            double target;
            if (_lines.Count == 0)
            {
                var phrase = 16 * beat;
                var progress = (t % phrase) / phrase;
                target = 0.3 + 0.4 * (0.5 - 0.5 * Math.Cos(2 * Math.PI * progress)) + 0.08 * kick;
            }
            else
            {
                var line = ActiveLine(t);
                if (line != null)
                {
                    var shimmer = 0.92 + 0.08 * Math.Sin(2 * Math.PI * line.SyllablesPerSecond * (t - line.Start));
                    target = (0.4 + 0.6 * line.Cadence) * shimmer;
                }
                else
                {
                    target = 0.08;
                }
            }
            var tau = target > _vocalEnvelope ? 0.06 : 0.5;
            _vocalEnvelope += (target - _vocalEnvelope) * (1 - Math.Exp(-Math.Max(dt, 0) / tau));
            return (bass, Math.Min(Math.Max(_vocalEnvelope, 0), 1));
        }
    }

    /// <summary>Binary search for the line being sung at <paramref name="t"/>.</summary>
    private LyricLine? ActiveLine(double t)
    {
        var low = 0;
        var high = _lines.Count - 1;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (_lines[mid].Start <= t) low = mid + 1; else high = mid - 1;
        }
        if (high < 0) return null;
        var line = _lines[high];
        return t < line.End ? line : null;
    }
}
