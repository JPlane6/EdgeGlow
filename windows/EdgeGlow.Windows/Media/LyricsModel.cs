using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using EdgeGlow.Lyrics;

namespace EdgeGlow;

/// <summary>
/// The lyrics side of EdgeGlow. It owns no media detection: it follows <see cref="AppState"/> (the track the media
/// bridge found, the shared PlaybackClock) and turns it into timed lyrics and a per-frame playhead.
/// </summary>
public sealed class LyricsModel : IDisposable
{
    private readonly AppState _state;
    private readonly LyricsFetcher _fetcher = new();
    private readonly object _lock = new();
    private TimedLyrics? _raw, _shown;
    private string _key = "";
    private bool _lastRomanize = true;
    private CancellationTokenSource? _cts;
    private bool _disposed;

    public LyricsModel(AppState state) => _state = state;

    public void Start()
    {
        _lastRomanize = _state.RomanizeLyrics;
        _state.Changed += OnChanged;
        OnChanged();
    }

    public void Dispose()
    {
        _disposed = true;
        _state.Changed -= OnChanged;
        _cts?.Cancel();
    }

    public const string NotFoundStatus = "No synced lyrics found";

    /// <summary>The lyrics currently shown (romanized when the toggle is on), or null.</summary>
    public TimedLyrics? Lyrics { get { lock (_lock) return _shown; } }

    private void OnChanged()
    {
        if (_disposed) return;
        var lyricsOn = _state.DisplayMode.LyricsOn();
        var key = lyricsOn && _state.MediaSource != null && _state.TrackName.Length > 0
            ? $"{_state.MediaSource}\u001F{_state.TrackName}\u001F{_state.ArtistName}\u001F{(int)Math.Round(_state.TrackDuration)}" : "";
        string? statusIfEmpty = null;
        lock (_lock)
        {
            if (_lastRomanize != _state.RomanizeLyrics)
            {
                _lastRomanize = _state.RomanizeLyrics;
                if (_raw != null) _shown = Present(_raw);
            }
            if (key == _key) return;
            _key = key;
            _cts?.Cancel();
            _raw = null; _shown = null;
            _state.VocalLock.SetWordStarts(Array.Empty<double>());
            if (key.Length == 0) statusIfEmpty = !lyricsOn ? "Lyrics are off" : "Nothing playing";
        }
        if (statusIfEmpty != null) { _state.LyricsStatus = statusIfEmpty; return; }
        _state.LyricsStatus = "Finding lyrics...";
        var cts = _cts = new CancellationTokenSource();
        var title = _state.TrackName; var artist = _state.ArtistName; var duration = _state.TrackDuration; var thisKey = key;
        _ = Task.Run(() => FetchAsync(title, artist, duration, thisKey, cts.Token));
    }

    private async Task FetchAsync(string title, string artist, double duration, string key, CancellationToken ct)
    {
        FetchResult? result = null;
        for (var attempt = 0; attempt < 5 && !ct.IsCancellationRequested; attempt++)
        {
            var r = await _fetcher.FetchAsync(title, artist, duration, ct).ConfigureAwait(false);
            if (ct.IsCancellationRequested) return;
            if (r.Outcome != FetchOutcome.Retry) { result = r; break; }
            try { await Task.Delay((10 + attempt * 10) * 1000, ct).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
        }
        lock (_lock)
        {
            if (ct.IsCancellationRequested || key != _key) return;
            if (result?.Lyrics is { } found)
            {
                _raw = found; _shown = Present(found);
                _state.VocalLock.SetWordStarts(found.Words.Select(w => w.Start).OrderBy(x => x).ToArray());
                _state.LyricsStatus = $"Synced lyrics - {found.Source}";
            }
            else _state.LyricsStatus = NotFoundStatus;
        }
    }

    private TimedLyrics Present(TimedLyrics raw) =>
        _state.RomanizeLyrics && raw.Words.Any(w => LyricRomanizer.NeedsRomanizing(w.Text)) ? raw.Map(LyricRomanizer.Romanize) : raw;

    /// <summary>
    /// Where the listener is in the song right now, in seconds: the clock's last known player position plus the time
    /// elapsed since it was read (monotonic Stopwatch), minus the output route's measured latency, plus the small trim
    /// the vocal-onset lock has learned.
    /// </summary>
    public double Playhead(double now) =>
        Math.Max(0, _state.PlaybackClock.CurrentTrackTime(now) - _state.AudioRoute.LatencyMs / 1000.0 + _state.VocalLock.Correction(now));
}
