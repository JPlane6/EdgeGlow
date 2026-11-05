using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace EdgeGlow.Lyrics;

public enum FetchOutcome { Found, NotFound, Retry }

public sealed record FetchResult(FetchOutcome Outcome, TimedLyrics? Lyrics = null);

/// <summary>
/// The multi-provider lyric cascade: LRCLIB exact match, then ranked LRCLIB fuzzy search (synced beats plain,
/// plain is spread over the song), then NetEase LRC with a strict title check so unrelated tracks are rejected.
/// </summary>
public sealed class LyricsFetcher
{
    private static readonly HttpClient Http = CreateClient();
    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("EdgeGlow/1.2.5 (https://github.com/JPlane6/EdgeGlow)");
        return c;
    }

    private sealed class Record
    {
        public string? trackName { get; set; }
        public string? artistName { get; set; }
        public double? duration { get; set; }
        public bool? instrumental { get; set; }
        public string? plainLyrics { get; set; }
        public string? syncedLyrics { get; set; }
    }

    public static string CacheDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EdgeGlow", "Lyrics");

    private static string CacheKey(string title, string artist, double duration)
    {
        var raw = $"{artist.ToLowerInvariant()}|{title.ToLowerInvariant()}|{(int)Math.Round(duration)}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(raw))).ToLowerInvariant();
    }

    public async Task<FetchResult> FetchAsync(string title, string artist, double duration, CancellationToken ct = default)
    {
        var (t, a) = LyricSanitizer.Sanitize(title, artist);
        if (t.Length == 0) return new FetchResult(FetchOutcome.NotFound);
        var key = CacheKey(t, a, duration);
        var cachePath = Path.Combine(CacheDirectory, key + ".lrc");
        try
        {
            if (File.Exists(cachePath))
            {
                var cached = File.ReadAllText(cachePath);
                var nl = cached.IndexOf('\n');
                if (nl > 0 && LrcParser.Interpolate(cached[(nl + 1)..], duration, cached[..nl]) is { } hit)
                    return new FetchResult(FetchOutcome.Found, hit);
            }
        }
        catch { /* a bad cache entry is just a miss */ }

        var failed = false;

        // Stage 1: LRCLIB exact match (+/- 4 s on the duration).
        var exact = await LrclibGet(t, a, duration, ct);
        if (exact.failed) failed = true;
        if (exact.record is { } r1 && Accept(r1, duration, 4, out var lrc1)) return Done(lrc1, "LRCLIB", t, a, duration, cachePath);

        // Stage 2: LRCLIB fuzzy search, ranked by title similarity and duration proximity (+/- 8 s).
        var (best, searchFailed) = await LrclibSearch(t, a, duration, ct);
        if (searchFailed && best == null) failed = true;
        if (best != null)
        {
            if (!string.IsNullOrEmpty(best.syncedLyrics)) return Done(best.syncedLyrics!, "LRCLIB", t, a, duration, cachePath);
            if (!string.IsNullOrEmpty(best.plainLyrics) &&
                LyricSanitizer.SpreadPlain(best.plainLyrics!, duration > 0 ? duration : best.duration ?? 0) is { } spread)
                return Done(spread, "LRCLIB (plain)", t, a, duration, cachePath);
        }

        // Stage 3: NetEase LRC (large Hindi / Punjabi / anime catalogues), with a strict title check.
        var (netease, neteaseFailed) = await NetEaseLrc(t, a, duration, ct);
        if (neteaseFailed) failed = true;
        if (netease != null) return Done(netease, "NetEase", t, a, duration, cachePath);

        return new FetchResult(failed ? FetchOutcome.Retry : FetchOutcome.NotFound);
    }

    private static FetchResult Done(string lrc, string source, string title, string artist, double duration, string cachePath)
    {
        var parsed = LrcParser.Interpolate(lrc, duration, source);
        if (parsed == null) return new FetchResult(FetchOutcome.NotFound);
        try
        {
            Directory.CreateDirectory(CacheDirectory);
            File.WriteAllText(cachePath, source + "\n" + lrc);
        }
        catch { /* cache is a convenience */ }
        return new FetchResult(FetchOutcome.Found, parsed);
    }

    private static bool Accept(Record r, double duration, double tolerance, out string lrc)
    {
        lrc = r.syncedLyrics ?? "";
        if (r.instrumental == true || lrc.Length == 0) return false;
        return duration <= 0 || r.duration is null || Math.Abs(r.duration.Value - duration) <= tolerance;
    }

    private static async Task<(Record? record, bool failed)> LrclibGet(string title, string artist, double duration, CancellationToken ct)
    {
        var url = "https://lrclib.net/api/get?track_name=" + Uri.EscapeDataString(title) + "&artist_name=" + Uri.EscapeDataString(artist) +
                  (duration > 0 ? "&duration=" + (int)Math.Round(duration) : "");
        try
        {
            using var res = await Http.GetAsync(url, ct);
            if (res.StatusCode == System.Net.HttpStatusCode.NotFound || res.StatusCode == System.Net.HttpStatusCode.BadRequest) return (null, false);
            if (!res.IsSuccessStatusCode) return (null, true);
            return (JsonSerializer.Deserialize<Record>(await res.Content.ReadAsStringAsync(ct)), false);
        }
        catch { return (null, true); }
    }

    private static async Task<(Record? best, bool failed)> LrclibSearch(string title, string artist, double duration, CancellationToken ct)
    {
        var queries = new[]
        {
            "q=" + Uri.EscapeDataString($"{title} {artist}".Trim()),
            "track_name=" + Uri.EscapeDataString(title) + "&artist_name=" + Uri.EscapeDataString(artist),
            "q=" + Uri.EscapeDataString(title),
        };
        Record? best = null; var bestScore = double.NegativeInfinity; var failed = false;
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        foreach (var q in queries)
        {
            try
            {
                using var res = await Http.GetAsync("https://lrclib.net/api/search?" + q, ct);
                if (!res.IsSuccessStatusCode) { failed |= (int)res.StatusCode >= 500; continue; }
                var list = JsonSerializer.Deserialize<List<Record>>(await res.Content.ReadAsStringAsync(ct), opts) ?? new();
                foreach (var rec in list)
                {
                    if (rec.instrumental == true) continue;
                    var synced = !string.IsNullOrEmpty(rec.syncedLyrics);
                    if (!synced && string.IsNullOrEmpty(rec.plainLyrics)) continue;
                    var score = LyricSanitizer.Score(title, artist, rec.trackName ?? "", rec.artistName ?? "", duration, rec.duration ?? 0, 8);
                    if (score is null) continue;
                    var s = score.Value - (synced ? 0 : 2.5);     // synced always beats plain
                    if (s > bestScore) { bestScore = s; best = rec; }
                }
                if (best != null && bestScore > (duration > 0 ? 14.2 : 4.2) && !string.IsNullOrEmpty(best.syncedLyrics)) break;
            }
            catch { failed = true; }
        }
        return (best, failed);
    }

    private static async Task<(string? lrc, bool failed)> NetEaseLrc(string title, string artist, double duration, CancellationToken ct)
    {
        try
        {
            var search = "https://music.163.com/api/search/get?type=1&limit=10&s=" + Uri.EscapeDataString($"{title} {artist}".Trim());
            using var req = new HttpRequestMessage(HttpMethod.Get, search);
            req.Headers.Referrer = new Uri("https://music.163.com/");
            using var res = await Http.SendAsync(req, ct);
            if (!res.IsSuccessStatusCode) return (null, true);
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            if (!doc.RootElement.TryGetProperty("result", out var result) || !result.TryGetProperty("songs", out var songs)) return (null, false);

            var candidates = new List<(long id, double score)>();
            foreach (var s in songs.EnumerateArray())
            {
                if (!s.TryGetProperty("id", out var idEl)) continue;
                var name = s.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                var artists = s.TryGetProperty("artists", out var ar)
                    ? string.Join(" ", ar.EnumerateArray().Select(x => x.TryGetProperty("name", out var nm) ? nm.GetString() ?? "" : ""))
                    : "";
                // Fuzzy search returns unrelated (often Chinese) songs: demand a real title match.
                var titleScore = LyricSanitizer.Similarity(title, name);
                var artistMatch = artist.Length > 0 && LyricSanitizer.Similarity(artist, artists) > 0;
                if (titleScore < 0.5 || (artist.Length > 0 && !artistMatch && titleScore < 1)) continue;
                var ms = s.TryGetProperty("duration", out var d) && d.TryGetInt64(out var dm) ? dm : 0;
                if (duration > 0 && ms > 0 && Math.Abs(ms - duration * 1000) > 2500) continue;
                candidates.Add((idEl.GetInt64(), (duration > 0 && ms > 0 ? Math.Abs(ms - duration * 1000) : 1000) - titleScore * 300 - (artistMatch ? 600 : 0)));
            }
            foreach (var (id, _) in candidates.OrderBy(c => c.score).Take(4))
            {
                using var lres = await Http.SendAsync(new HttpRequestMessage(HttpMethod.Get, $"https://music.163.com/api/song/lyric?id={id}&lv=1")
                    { Headers = { Referrer = new Uri("https://music.163.com/") } }, ct);
                if (!lres.IsSuccessStatusCode) continue;
                using var ldoc = JsonDocument.Parse(await lres.Content.ReadAsStringAsync(ct));
                if (ldoc.RootElement.TryGetProperty("lrc", out var lrc) && lrc.TryGetProperty("lyric", out var text) && text.GetString() is { Length: > 20 } l)
                    return (l, false);
            }
            return (null, false);
        }
        catch { return (null, true); }
    }
}
