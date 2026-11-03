using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace EdgeGlow;

/// <summary>
/// Windows edge of the media pipeline: reads the global "Now Playing" sessions through the WinRT
/// GlobalSystemMediaTransportControlsSessionManager (Spotify, Apple Music, Chrome, Edge, Arc, Brave...) and
/// publishes the winner into <see cref="AppState"/>. Everything downstream (PlaybackClock, Cloud Sync, the
/// renderer) is platform-neutral. Port of MediaBridge.swift, with SMTC replacing AppleScript.
/// </summary>
public sealed class MediaBridge : IDisposable
{
    private sealed record Reading(MediaSource Source, NowPlayingInfo Info, bool Playing, double PolledAt,
                                  GlobalSystemMediaTransportControlsSession Session);

    private static readonly string[] BrowserMarkers =
        { "chrome", "msedge", "edge", "brave", "firefox", "opera", "vivaldi", "thebrowser", "browser" };

    private readonly AppState _state;
    private readonly SemaphoreSlim _pollGate = new(1, 1);
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private Timer? _timer;
    private int _pollQueued;
    private bool _disposed;

    private string _currentTrackKey = "";
    private string _artworkKey = "";
    private CancellationTokenSource? _cloudCts;
    private CancellationTokenSource? _artworkCts;

    public MediaBridge(AppState state) => _state = state;

    public async void Start()
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.SessionsChanged += (_, _) => RequestPoll();
            _manager.CurrentSessionChanged += (_, _) => RequestPoll();
        }
        catch
        {
            // SMTC unavailable (very old Windows build): fall through to system-audio-only mode.
        }

        // System audio starting or stopping can change the active source.
        var lastActive = _state.SystemAudioActive;
        _state.Changed += () =>
        {
            if (_state.SystemAudioActive != lastActive)
            {
                lastActive = _state.SystemAudioActive;
                RequestPoll();
            }
        };

        // Backup poll so we pick up a track that was already playing at launch and keep position fresh.
        _timer = new Timer(_ => RequestPoll(), null, 0, 2000);
    }

    public void Dispose()
    {
        _disposed = true;
        _timer?.Dispose();
        _cloudCts?.Cancel();
        _artworkCts?.Cancel();
    }

    private void RequestPoll()
    {
        if (_disposed) return;
        if (!_pollGate.Wait(0))
        {
            Interlocked.Exchange(ref _pollQueued, 1);
            return;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                do
                {
                    Interlocked.Exchange(ref _pollQueued, 0);
                    await PollAsync().ConfigureAwait(false);
                } while (Volatile.Read(ref _pollQueued) == 1 && !_disposed);
            }
            catch
            {
                // A failed poll is retried by the 2 s timer.
            }
            finally
            {
                _pollGate.Release();
            }
        });
    }

    // ---- Polling ----

    private static MediaSource Classify(string aumid)
    {
        var id = aumid.ToLowerInvariant();
        if (id.Contains("spotify")) return MediaSource.Spotify;
        if (id.Contains("applemusic") || id.Contains("itunes") || id.Contains("apple music")) return MediaSource.AppleMusic;
        if (BrowserMarkers.Any(id.Contains)) return MediaSource.Browser;
        return MediaSource.SystemAudio;
    }

    private async Task PollAsync()
    {
        if (_manager == null) { Apply(new List<Reading>()); return; }

        var readings = new List<Reading>();
        foreach (var session in _manager.GetSessions())
        {
            try
            {
                var playbackInfo = session.GetPlaybackInfo();
                var status = playbackInfo.PlaybackStatus;
                if (status != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing &&
                    status != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused) continue;

                var props = await session.TryGetMediaPropertiesAsync();
                var title = props.Title ?? "";
                if (title.Length == 0) continue;
                var timeline = session.GetTimelineProperties();
                var playing = status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;

                // SMTC reports the position as of LastUpdatedTime; extrapolate to now while playing.
                var polledAt = Clock.Now;
                double? position = null, duration = null;
                var span = timeline.EndTime - timeline.StartTime;
                if (span.TotalSeconds > 0) duration = span.TotalSeconds;
                if (timeline.LastUpdatedTime.Year > 2000)
                {
                    var p = (timeline.Position - timeline.StartTime).TotalSeconds;
                    if (playing) p += Math.Max((DateTimeOffset.UtcNow - timeline.LastUpdatedTime).TotalSeconds, 0);
                    position = Math.Max(p, 0);
                }

                var source = Classify(session.SourceAppUserModelId ?? "");
                var artist = props.Artist ?? "";
                if (source == MediaSource.Browser)
                {
                    // YouTube Music tab titles: "Song - Artist - YouTube Music" style decorations are tab-only,
                    // but the browser's MediaSession already supplies clean title/artist.
                    position = null;
                }
                readings.Add(new Reading(source, new NowPlayingInfo(title, artist, null, position, duration), playing, polledAt, session));
            }
            catch
            {
                // One misbehaving session must not hide the others.
            }
        }
        Apply(readings);
    }

    private void Apply(List<Reading> readings)
    {
        Reading? Find(MediaSource wanted, bool isPlaying) =>
            readings.FirstOrDefault(r => r.Source == wanted && r.Playing == isPlaying);

        // Priority: a playing native player, then live system audio (a playing browser/other app with
        // metadata, else plain system audio), then a paused native player.
        MediaSource? source = null;
        NowPlayingInfo? info = null;
        var playingNow = false;
        double? polledAt = null;
        GlobalSystemMediaTransportControlsSession? session = null;

        void Choose(Reading r)
        {
            source = r.Source; info = r.Info; playingNow = r.Playing; polledAt = r.PolledAt; session = r.Session;
        }

        var nativeSpotify = Find(MediaSource.Spotify, true);
        var nativeApple = Find(MediaSource.AppleMusic, true);
        var audible = _state.SystemAudioActive;
        if (nativeSpotify != null) Choose(nativeSpotify);
        else if (nativeApple != null) Choose(nativeApple);
        else if (audible)
        {
            var other = readings.FirstOrDefault(r => r.Playing && r.Source is MediaSource.Browser or MediaSource.SystemAudio);
            if (other != null) Choose(other);
            else { source = MediaSource.SystemAudio; playingNow = true; }
        }
        else
        {
            var paused = Find(MediaSource.Spotify, false) ?? Find(MediaSource.AppleMusic, false);
            if (paused != null) Choose(paused);
        }

        _state.MediaSource = source;
        _state.Playback = source == null ? PlaybackState.Stopped : (playingNow ? PlaybackState.Playing : PlaybackState.Paused);
        _state.TrackName = info?.Title ?? "";
        _state.ArtistName = info?.Artist ?? "";

        var key = source == null ? "" : $"{source}\u001F{info?.Title ?? ""}\u001F{info?.Artist ?? ""}";
        var trackChanged = key != _currentTrackKey;
        if (trackChanged)
        {
            _currentTrackKey = key;
            TrackDidChange(key, source, info);
        }

        UpdateClock(source, info, playingNow, polledAt, trackChanged);

        // Stopped: keep the last artwork and colors on screen.
        if (source == null) return;
        UpdateArtwork(key, session, info);
    }

    /// <summary>
    /// Re-anchor on track change, resume, or noticeable drift; otherwise keep extrapolating so SMTC
    /// update jitter does not wobble the beat phase.
    /// </summary>
    private void UpdateClock(MediaSource? source, NowPlayingInfo? info, bool playing, double? polledAt, bool trackChanged)
    {
        var clock = _state.PlaybackClock;
        var hasPosition = source?.ReportsPosition() == true;
        if (hasPosition && info?.Position is double position && polledAt is double at)
        {
            if (playing)
            {
                var drift = Math.Abs(clock.CurrentTrackTime(at) - position);
                if (trackChanged || !clock.IsPlaying || drift > 0.25) clock.Anchor(position, at);
                clock.SetPlaying(true, at);
            }
            else
            {
                clock.SetPlaying(false);
                clock.Anchor(position, at);
            }
        }
        else
        {
            clock.SetPlaying(false);
        }
        _state.CloudSync.SetNativePlaybackActive(hasPosition && playing);
    }

    // ---- Cloud Sync metadata ----

    /// <summary>Tempo and synced lyrics are fetched for every native-player track up front, so Cloud Sync is ready the moment the PC goes silent.</summary>
    private void TrackDidChange(string key, MediaSource? source, NowPlayingInfo? info)
    {
        _cloudCts?.Cancel();
        var cloudSync = _state.CloudSync;
        cloudSync.BeginTrack(key);
        if (source is not { } s || !s.ReportsPosition() || info == null || info.Title.Length == 0) return;

        var cts = _cloudCts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            var bpmTask = MediaMetadataService.BpmAsync(info.Title, info.Artist);
            var lyricsTask = MediaMetadataService.SyncedLyricsAsync(info.Title, info.Artist, info.Duration);
            await Task.WhenAll(bpmTask, lyricsTask).ConfigureAwait(false);
            if (cts.IsCancellationRequested) return;
            cloudSync.Update(key, bpmTask.Result, lyricsTask.Result);
        });
    }

    // ---- Artwork + colors ----

    private void UpdateArtwork(string key, GlobalSystemMediaTransportControlsSession? session, NowPlayingInfo? info)
    {
        if (info == null || info.Title.Length == 0)
        {
            // Plain system audio has no album: fall back to the default palette.
            ShowArtwork("", null);
            return;
        }
        if (key == _artworkKey) return;
        _artworkKey = key;
        _artworkCts?.Cancel();
        var cts = _artworkCts = new CancellationTokenSource();

        _ = Task.Run(async () =>
        {
            // 1) The player's own thumbnail (Spotify, Apple Music and browsers all provide one through SMTC).
            byte[]? bytes = null;
            if (session != null)
            {
                try
                {
                    var props = await session.TryGetMediaPropertiesAsync();
                    if (props.Thumbnail != null)
                    {
                        using IRandomAccessStreamWithContentType stream = await props.Thumbnail.OpenReadAsync();
                        using var managed = stream.AsStreamForRead();
                        using var ms = new MemoryStream();
                        await managed.CopyToAsync(ms);
                        if (ms.Length > 0) bytes = ms.ToArray();
                    }
                }
                catch
                {
                    // Fall through to the web lookup.
                }
            }
            // 2) Look the cover up by name (iTunes Search, then Deezer).
            if (bytes == null)
            {
                var url = await MediaMetadataService.ArtworkUrlAsync(info.Title, info.Artist);
                if (url != null) bytes = await MediaMetadataService.DownloadAsync(url);
            }
            if (cts.IsCancellationRequested || key != _artworkKey) return;
            ShowArtwork(key, bytes);
        });
    }

    private void ShowArtwork(string key, byte[]? bytes)
    {
        if (bytes == null)
        {
            _state.Artwork = null;
            _state.ExtractedPrimary = RgbColor.NeonCyan;
            _state.ExtractedSecondary = RgbColor.NeonMagenta;
            return;
        }
        (RgbColor Primary, RgbColor Secondary)? palette = null;
        try { palette = ColorExtractor.Palette(bytes); } catch { }
        _state.Artwork = bytes;
        // Grayscale covers have no usable hue, so fall back to the default neon pair.
        _state.ExtractedPrimary = palette?.Primary ?? RgbColor.NeonCyan;
        _state.ExtractedSecondary = palette?.Secondary ?? RgbColor.NeonMagenta;
    }
}
