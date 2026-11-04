using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using EdgeGlow.Lyrics;

namespace EdgeGlow;

/// <summary>
/// Single source of truth shared by the media bridge, the audio pipeline, the overlay renderer and the
/// flyout UI. <see cref="Changed"/> fires (from any thread) whenever an observable value changes; the
/// renderer reads the fields directly every frame and never listens.
/// </summary>
public sealed class AppState
{
    public static AppState Shared { get; } = new();

    public event Action? Changed;
    private void Raise() => Changed?.Invoke();

    private bool Set<T>(ref T field, T value, bool persist = false)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        if (persist) ScheduleSave();
        Raise();
        return true;
    }

    // ---- Playback (driven by MediaBridge) ----
    private PlaybackState _playback = PlaybackState.Stopped;
    private MediaSource? _mediaSource;
    private string _trackName = "";
    private string _artistName = "";
    private byte[]? _artwork;
    private RgbColor _extractedPrimary = RgbColor.NeonCyan;
    private RgbColor _extractedSecondary = RgbColor.NeonMagenta;

    public PlaybackState Playback { get => _playback; set => Set(ref _playback, value); }
    /// <summary>The player (or plain system audio) the glow is following; null when nothing is playing or paused.</summary>
    public MediaSource? MediaSource { get => _mediaSource; set => Set(ref _mediaSource, value); }
    public string TrackName { get => _trackName; set => Set(ref _trackName, value); }
    public string ArtistName { get => _artistName; set => Set(ref _artistName, value); }
    /// <summary>Encoded image bytes (PNG/JPEG) of the current cover, or null.</summary>
    public byte[]? Artwork { get => _artwork; set => Set(ref _artwork, value); }
    public RgbColor ExtractedPrimary { get => _extractedPrimary; set => Set(ref _extractedPrimary, value); }
    public RgbColor ExtractedSecondary { get => _extractedSecondary; set => Set(ref _extractedSecondary, value); }

    /// <summary>Continuous track position for the current native player.</summary>
    public PlaybackClock PlaybackClock { get; } = new();
    /// <summary>Tempo and lyric timing for the current track, used when this PC itself is silent.</summary>
    public CloudSyncEngine CloudSync { get; } = new();

    // ---- Audio (driven by AudioCaptureManager) ----
    private AudioCaptureStatus _audioStatus = AudioCaptureStatus.Off;
    private string _audioError = "";
    private bool _systemAudioActive;
    private LevelSource _levelSource = LevelSource.None;

    public AudioCaptureStatus AudioStatus { get => _audioStatus; set => Set(ref _audioStatus, value); }
    public string AudioError { get => _audioError; set => Set(ref _audioError, value); }
    /// <summary>Sound above -68 dBFS is coming out of the PC; false after 1.5 s of digital silence.</summary>
    public bool SystemAudioActive { get => _systemAudioActive; set => Set(ref _systemAudioActive, value); }
    /// <summary>What is currently feeding <see cref="AudioLevels"/>.</summary>
    public LevelSource LevelSource { get => _levelSource; set => Set(ref _levelSource, value); }
    public AudioLevels AudioLevels { get; } = new();

    // ---- Displays (driven by DisplayManager) ----
    private IReadOnlyList<DisplayInfo> _availableDisplays = Array.Empty<DisplayInfo>();
    public IReadOnlyList<DisplayInfo> AvailableDisplays
    {
        get => _availableDisplays;
        set { if (!_availableDisplays.SequenceEqual(value)) { _availableDisplays = value; Raise(); } }
    }

    // ---- Lyrics / display mode (persisted unless noted) ----
    private DisplayMode _displayMode = DisplayMode.Both;
    private LyricStyle _lyricStyle = LyricStyle.Constellation;
    private LyricFont _lyricFont = LyricFont.SfPro;
    private double _lyricTextScale = 1.0, _lyricVerticalPosition = 0.5;
    private bool _romanizeLyrics = true;
    private AudioRoute _audioRoute = AudioRoute.Unknown;
    private double _trackDuration;
    private string _lyricsStatus = "Waiting for music...";

    public DisplayMode DisplayMode { get => _displayMode; set => Set(ref _displayMode, value, true); }
    public LyricStyle LyricStyle { get => _lyricStyle; set => Set(ref _lyricStyle, value, true); }
    public LyricFont LyricFont { get => _lyricFont; set => Set(ref _lyricFont, value, true); }
    public double LyricTextScale { get => _lyricTextScale; set => Set(ref _lyricTextScale, Math.Clamp(value, 0.6, 1.8), true); }
    public double LyricVerticalPosition { get => _lyricVerticalPosition; set => Set(ref _lyricVerticalPosition, Math.Clamp(value, 0, 1), true); }
    /// <summary>Romanize Hindi / Punjabi / Urdu lyrics (Devanagari, Gurmukhi, Arabic script) into Latin.</summary>
    public bool RomanizeLyrics { get => _romanizeLyrics; set => Set(ref _romanizeLyrics, value, true); }
    /// <summary>Output route and its measured latency (read-only in the UI).</summary>
    public AudioRoute AudioRoute { get => _audioRoute; set => Set(ref _audioRoute, value); }
    public double TrackDuration { get => _trackDuration; set => Set(ref _trackDuration, value); }
    public string LyricsStatus { get => _lyricsStatus; set => Set(ref _lyricsStatus, value); }
    public VocalOnsetLock VocalLock { get; } = new();

    // ---- Persisted settings ----
    private double _thickness = 42;
    private double _glowSpread = 45;
    private double _reactivity = 1.0;
    private double _intensity = 0.85;
    private bool _idleWhenPaused = true;
    private bool _useCustomColors;
    private RgbColor _customPrimary = RgbColor.NeonCyan;
    private RgbColor _customSecondary = RgbColor.NeonMagenta;
    private AnimationStyle _animationStyle = AnimationStyle.Breathing;
    private bool _kineticEffects = true;
    private double _cometLength = 0.18;
    private HashSet<string>? _activeDisplays;

    public double Thickness { get => _thickness; set => Set(ref _thickness, value, true); }
    public double GlowSpread { get => _glowSpread; set => Set(ref _glowSpread, value, true); }
    public double Reactivity { get => _reactivity; set => Set(ref _reactivity, value, true); }
    public double Intensity { get => _intensity; set => Set(ref _intensity, value, true); }
    public bool IdleWhenPaused { get => _idleWhenPaused; set => Set(ref _idleWhenPaused, value, true); }
    public bool UseCustomColors { get => _useCustomColors; set => Set(ref _useCustomColors, value, true); }
    public RgbColor CustomPrimary { get => _customPrimary; set => Set(ref _customPrimary, value, true); }
    public RgbColor CustomSecondary { get => _customSecondary; set => Set(ref _customSecondary, value, true); }
    public AnimationStyle AnimationStyle { get => _animationStyle; set => Set(ref _animationStyle, value, true); }
    /// <summary>Bass-driven edge bounce, sparks and chromatic impact flashes.</summary>
    public bool KineticEffects { get => _kineticEffects; set => Set(ref _kineticEffects, value, true); }
    /// <summary>Comet length as a fraction of the bezel perimeter (Chasing and Symmetry).</summary>
    public double CometLength { get => _cometLength; set => Set(ref _cometLength, value, true); }

    /// <summary>
    /// True once a display choice exists (stored, or picked on first launch). IDs of unplugged displays are
    /// kept, so the glow returns when that monitor is reconnected.
    /// </summary>
    public bool HasDisplayChoice => _activeDisplays != null;
    public IReadOnlySet<string> ActiveDisplays => _activeDisplays ?? new HashSet<string>();

    public void SetActiveDisplays(IEnumerable<string> ids)
    {
        _activeDisplays = new HashSet<string>(ids);
        ScheduleSave();
        Raise();
    }

    public void ToggleDisplay(string id)
    {
        var next = new HashSet<string>(ActiveDisplays);
        if (!next.Remove(id)) next.Add(id);
        SetActiveDisplays(next);
    }

    // ---- Derived values ----
    public bool IsPlaying => _playback == PlaybackState.Playing;
    /// <summary>Audio energies drive the glow: something is playing and either the FFT or Cloud Sync produces levels.</summary>
    public bool AudioReactive => IsPlaying && _levelSource != LevelSource.None;
    /// <summary>Whether the overlay should currently be lit at all.</summary>
    public bool GlowActive => (IsPlaying || _idleWhenPaused) && _displayMode.GlowOn();
    public RgbColor TargetPrimary => _useCustomColors ? _customPrimary : _extractedPrimary;
    public RgbColor TargetSecondary => _useCustomColors ? _customSecondary : _extractedSecondary;

    // ---- Persistence (%APPDATA%\EdgeGlow\settings.json) ----
    private sealed class SettingsData
    {
        public double Thickness { get; set; } = 42;
        public double GlowSpread { get; set; } = 45;
        public double Reactivity { get; set; } = 1.0;
        public double Intensity { get; set; } = 0.85;
        public bool IdleWhenPaused { get; set; } = true;
        public bool UseCustomColors { get; set; }
        public double[]? CustomPrimary { get; set; }
        public double[]? CustomSecondary { get; set; }
        public string? AnimationStyle { get; set; }
        public bool KineticEffects { get; set; } = true;
        public double CometLength { get; set; } = 0.18;
        public string[]? ActiveDisplays { get; set; }
        public string? DisplayMode { get; set; }
        public string? LyricStyle { get; set; }
        public string? LyricFont { get; set; }
        public double LyricTextScale { get; set; } = 1.0;
        public double LyricVerticalPosition { get; set; } = 0.5;
        public bool RomanizeLyrics { get; set; } = true;
    }

    public static string SettingsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "EdgeGlow");
    private static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    private Timer? _saveTimer;
    private readonly object _saveLock = new();
    private bool _loading = true;

    private AppState()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var data = JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(SettingsPath));
                if (data != null)
                {
                    _thickness = Math.Clamp(data.Thickness, 10, 120);
                    _glowSpread = Math.Clamp(data.GlowSpread, 15, 90);
                    _reactivity = Math.Clamp(data.Reactivity, 0, 1.5);
                    _intensity = Math.Clamp(data.Intensity, 0.1, 1.0);
                    _idleWhenPaused = data.IdleWhenPaused;
                    _useCustomColors = data.UseCustomColors;
                    _customPrimary = RgbColor.FromArray(data.CustomPrimary) ?? RgbColor.NeonCyan;
                    _customSecondary = RgbColor.FromArray(data.CustomSecondary) ?? RgbColor.NeonMagenta;
                    _animationStyle = AnimationStyleExtensions.FromKey(data.AnimationStyle);
                    _kineticEffects = data.KineticEffects;
                    _cometLength = Math.Clamp(data.CometLength, 0.05, 0.45);
                    _activeDisplays = data.ActiveDisplays != null ? new HashSet<string>(data.ActiveDisplays) : null;
                    _displayMode = DisplayModeExtensions.FromKey(data.DisplayMode);
                    _lyricStyle = LyricStyleInfo.FromKey(data.LyricStyle);
                    _lyricFont = LyricFontInfo.FromKey(data.LyricFont);
                    _lyricTextScale = Math.Clamp(data.LyricTextScale, 0.6, 1.8);
                    _lyricVerticalPosition = Math.Clamp(data.LyricVerticalPosition, 0, 1);
                    _romanizeLyrics = data.RomanizeLyrics;
                }
            }
        }
        catch
        {
            // A corrupt settings file just means defaults.
        }
        _loading = false;
    }

    private void ScheduleSave()
    {
        if (_loading) return;
        lock (_saveLock)
        {
            _saveTimer ??= new Timer(_ => SaveNow(), null, Timeout.Infinite, Timeout.Infinite);
            _saveTimer.Change(400, Timeout.Infinite);
        }
    }

    public void SaveNow()
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            var data = new SettingsData
            {
                Thickness = _thickness, GlowSpread = _glowSpread, Reactivity = _reactivity, Intensity = _intensity,
                IdleWhenPaused = _idleWhenPaused, UseCustomColors = _useCustomColors,
                CustomPrimary = _customPrimary.ToArray(), CustomSecondary = _customSecondary.ToArray(),
                AnimationStyle = _animationStyle.Key(), KineticEffects = _kineticEffects, CometLength = _cometLength,
                ActiveDisplays = _activeDisplays?.OrderBy(x => x, StringComparer.Ordinal).ToArray(),
                DisplayMode = _displayMode.ToString(), LyricStyle = _lyricStyle.ToString(), LyricFont = _lyricFont.ToString(),
                LyricTextScale = _lyricTextScale, LyricVerticalPosition = _lyricVerticalPosition, RomanizeLyrics = _romanizeLyrics,
            };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // Settings are a convenience; never crash over them.
        }
    }
}
