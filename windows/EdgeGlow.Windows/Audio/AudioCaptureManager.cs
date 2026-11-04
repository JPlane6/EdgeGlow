using System;
using System.Threading;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace EdgeGlow;

/// <summary>
/// Captures the PC's system audio output with WASAPI loopback (never the microphone, no drivers needed) and
/// turns it into bass (20-150 Hz) and vocal (300-3000 Hz) energies with an FFT, auto-gain and envelope
/// followers. Port of AudioCaptureManager.swift.
///
/// Capture runs whenever at least one display has the glow enabled, independent of which player is in use,
/// and restarts itself when the default output device changes (Bluetooth, USB, HDMI). When a native player
/// reports playback but this PC stays digitally silent (Spotify Connect), the levels come from Cloud Sync
/// instead, until real audio returns.
/// </summary>
public sealed class AudioCaptureManager : IMMNotificationClient, IDisposable
{
    /// <summary>KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, how WASAPI mix formats announce 32-bit float.</summary>
    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");
    private const double BassLow = 20, BassHigh = 150;
    private const double VocalLow = 300, VocalHigh = 3400;
    /// <summary>Broadband level above which the PC counts as playing audio (switches back to the live FFT at once).</summary>
    private const double PresenceDb = -68.0;
    /// <summary>Broadband level below which the PC counts as silent...</summary>
    private const double SilenceDb = -72.0;
    /// <summary>...once it has stayed there this long (also used when buffers stop arriving entirely).</summary>
    private const double SilenceHold = 1.5;
    /// <summary>Output-device changes arrive in bursts while a route settles.</summary>
    private const int RouteDebounceMs = 350;

    /// <summary>The rolling maximum is never taken as lower than this (-60 dBFS).</summary>
    private static readonly double NoiseFloor = Math.Pow(10, -60.0 / 20);
    /// <summary>Below -78 dBFS a band counts as silent; the gate opens smoothly over the next 8 dB.</summary>
    private const double GateDb = -78.0;
    private const double GateRangeDb = 8.0;

    private readonly AppState _state;
    private readonly Dispatcher _ui;

    // UI-thread state.
    private WasapiLoopbackCapture? _capture;
    private MMDeviceEnumerator? _enumerator;
    private Timer? _routeTimer;
    private Timer? _retryTimer;
    private bool _screensAsleep;
    private bool _sessionActive = true;
    private bool _updatePending;
    private bool _disposed;

    // Analysis state (guarded by _sync: audio thread + ticker thread).
    private readonly object _sync = new();
    private Timer? _ticker;
    private int _fftSize;
    private float[] _window = Array.Empty<float>();
    private float[] _ring = Array.Empty<float>();
    private float[] _re = Array.Empty<float>();
    private float[] _im = Array.Empty<float>();
    private float[] _cos = Array.Empty<float>();
    private float[] _sin = Array.Empty<float>();
    private int[] _bitReverse = Array.Empty<int>();
    private float[] _power = Array.Empty<float>();
    private int _ringFilled;
    private double _sampleRate = 48_000;
    private double _bassEnvelope, _vocalEnvelope;
    private double _prevVocalRatio, _fluxAverage, _lastOnsetTime;
    private readonly RollingPeak _bassPeak = new();
    private readonly RollingPeak _vocalPeak = new();
    private bool _captureRunning;
    private bool _audioPresent;
    private double? _silentSince;
    private double _lastBufferTime;
    private LevelSource _levelSource = LevelSource.None;
    private double? _nativePlayingSince;
    private double? _lastSynthTime;

    public AudioCaptureManager(AppState state, Dispatcher ui)
    {
        _state = state;
        _ui = ui;
        ConfigureFft();
    }

    // ---- Lifecycle ----

    public void Start()
    {
        // Any state change (displays toggled, playback started) re-evaluates whether capture should run.
        _state.Changed += OnStateChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;

        try
        {
            _enumerator = new MMDeviceEnumerator();
            _enumerator.RegisterEndpointNotificationCallback(this);
        }
        catch
        {
            // No device enumerator: capture still works, it just will not follow route changes.
        }

        lock (_sync)
        {
            _ticker = new Timer(_ => Tick(), null, 250, 250);
        }
        UpdateCapture();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _state.Changed -= OnStateChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        try { _enumerator?.UnregisterEndpointNotificationCallback(this); } catch { }
        _enumerator?.Dispose();
        _routeTimer?.Dispose();
        _retryTimer?.Dispose();
        lock (_sync)
        {
            _ticker?.Dispose();
            _ticker = null;
        }
        StopCapture();
    }

    private void Post(Action action) => _ui.BeginInvoke(action);

    private void OnStateChanged()
    {
        // Coalesce: state changes arrive in bursts, and UpdateCapture itself writes AudioStatus.
        if (_updatePending || _disposed) return;
        _updatePending = true;
        Post(() => { _updatePending = false; UpdateCapture(); });
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        switch (e.Reason)
        {
            case SessionSwitchReason.SessionLock:
            case SessionSwitchReason.ConsoleDisconnect:
            case SessionSwitchReason.RemoteDisconnect:
                _sessionActive = false; break;
            case SessionSwitchReason.SessionUnlock:
            case SessionSwitchReason.ConsoleConnect:
            case SessionSwitchReason.RemoteConnect:
                _sessionActive = true; break;
            default: return;
        }
        Post(UpdateCapture);
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) _screensAsleep = true;
        else if (e.Mode == PowerModes.Resume) _screensAsleep = false;
        else return;
        Post(UpdateCapture);
    }

    /// <summary>At least one display shows the glow and the PC isn't asleep or locked.</summary>
    private bool CaptureWanted => _state.DisplayMode != DisplayMode.Off && _state.ActiveDisplays.Count > 0 && !_screensAsleep && _sessionActive;

    private void UpdateCapture()
    {
        if (_disposed) return;
        if (CaptureWanted) StartCapture(); else StopCapture();
    }

    private void StartCapture()
    {
        if (_capture != null) return;
        try
        {
            _state.AudioStatus = AudioCaptureStatus.Starting;
            var capture = new WasapiLoopbackCapture(); // default render endpoint
            capture.DataAvailable += OnData;
            capture.RecordingStopped += OnStopped;
            lock (_sync)
            {
                _sampleRate = capture.WaveFormat.SampleRate;
                ConfigureFft();
            }
            capture.StartRecording();
            _capture = capture;
            _state.AudioError = "";
            _state.AudioStatus = AudioCaptureStatus.Live;
            lock (_sync)
            {
                _captureRunning = true;
                _lastBufferTime = Clock.Now;
            }
        }
        catch (Exception ex)
        {
            _capture = null;
            _state.AudioError = ex.Message;
            _state.AudioStatus = AudioCaptureStatus.Failed;
            ScheduleRetry();
        }
    }

    private void StopCapture()
    {
        var capture = _capture;
        _capture = null;
        if (capture != null)
        {
            capture.DataAvailable -= OnData;
            capture.RecordingStopped -= OnStopped;
            try { capture.StopRecording(); } catch { }
            try { capture.Dispose(); } catch { }
            _state.AudioStatus = AudioCaptureStatus.Off;
        }
        lock (_sync)
        {
            _captureRunning = false;
            ResetAnalysis();
        }
    }

    /// <summary>Tears the capture down and builds a fresh one on the current output route.</summary>
    private void RestartCapture()
    {
        if (_capture == null) { UpdateCapture(); return; }
        StopCapture();
        _state.AudioStatus = AudioCaptureStatus.Starting;
        UpdateCapture();
    }

    private void ScheduleRetry()
    {
        // Transient failures (device switch, driver reset): try again shortly.
        _retryTimer?.Dispose();
        _retryTimer = new Timer(_ => Post(UpdateCapture), null, 3000, Timeout.Infinite);
    }

    private void OnStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception == null) return;
        Post(() =>
        {
            if (!ReferenceEquals(sender, _capture)) return;
            var capture = _capture;
            _capture = null;
            if (capture != null)
            {
                capture.DataAvailable -= OnData;
                capture.RecordingStopped -= OnStopped;
                try { capture.Dispose(); } catch { }
            }
            lock (_sync) { _captureRunning = false; ResetAnalysis(); }
            _state.AudioError = e.Exception.Message;
            _state.AudioStatus = AudioCaptureStatus.Failed;
            ScheduleRetry();
        });
    }

    // ---- Output route (IMMNotificationClient) ----

    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (flow != DataFlow.Render || role != Role.Multimedia) return;
        _routeTimer?.Dispose();
        _routeTimer = new Timer(_ => Post(() =>
        {
            if (CaptureWanted) RestartCapture();
        }), null, RouteDebounceMs, Timeout.Infinite);
    }

    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

    // ---- Samples -> mono ----

    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (sender is not WasapiLoopbackCapture capture || e.BytesRecorded <= 0) return;
        var mono = MonoSamples(e.Buffer, e.BytesRecorded, capture.WaveFormat);
        if (mono == null || mono.Length == 0) return;
        lock (_sync)
        {
            if (!_captureRunning) return;
            Analyze(mono, capture.WaveFormat.SampleRate);
        }
    }

    /// <summary>Mixes the interleaved buffer down to mono float, whatever its layout (Float32 / Int16 / Int24 / Int32).</summary>
    private static float[]? MonoSamples(byte[] buffer, int bytes, WaveFormat format)
    {
        var channels = Math.Max(format.Channels, 1);
        var bits = format.BitsPerSample;
        var bytesPerSample = bits / 8;
        if (bytesPerSample <= 0) return null;
        var frames = bytes / (bytesPerSample * channels);
        if (frames <= 0) return null;

        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
                      || (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubFormat);
        var mono = new float[frames];
        var offset = 0;
        for (var f = 0; f < frames; f++)
        {
            float sum = 0;
            for (var c = 0; c < channels; c++)
            {
                float v;
                if (isFloat && bits == 32) v = BitConverter.ToSingle(buffer, offset);
                else if (bits == 16) v = BitConverter.ToInt16(buffer, offset) / 32768f;
                else if (bits == 24) v = ((buffer[offset] << 8 | buffer[offset + 1] << 16 | buffer[offset + 2] << 24) >> 8) / 8388608f;
                else if (bits == 32) v = BitConverter.ToInt32(buffer, offset) / 2147483648f;
                else return null;
                sum += v;
                offset += bytesPerSample;
            }
            mono[f] = sum / channels;
        }
        return mono;
    }

    // ---- Analysis (under _sync) ----

    /// <summary>A 2048-point FFT (~43 ms, ~23 Hz bins at 48 kHz), doubled above 64 kHz so high-rate devices keep the same bass resolution.</summary>
    private void ConfigureFft()
    {
        var n = _sampleRate > 64_000 ? 4096 : 2048;
        if (n == _fftSize) return;
        _fftSize = n;
        _window = new float[n];
        for (var i = 0; i < n; i++) _window[i] = (float)(0.5 * (1 - Math.Cos(2 * Math.PI * i / n))); // hanning (denormalized)
        _ring = new float[n];
        _ringFilled = 0;
        _re = new float[n];
        _im = new float[n];
        _power = new float[n / 2];
        _cos = new float[n / 2];
        _sin = new float[n / 2];
        for (var i = 0; i < n / 2; i++)
        {
            _cos[i] = (float)Math.Cos(-2 * Math.PI * i / n);
            _sin[i] = (float)Math.Sin(-2 * Math.PI * i / n);
        }
        var bits = (int)Math.Round(Math.Log2(n));
        _bitReverse = new int[n];
        for (var i = 0; i < n; i++)
        {
            var r = 0;
            for (var b = 0; b < bits; b++) if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
            _bitReverse[i] = r;
        }
    }

    private void Analyze(float[] mono, double rate)
    {
        if (rate != _sampleRate)
        {
            _sampleRate = rate;
            ConfigureFft();
        }
        var now = Clock.Now;
        _lastBufferTime = now;

        double sumSq = 0;
        foreach (var s in mono) sumSq += (double)s * s;
        var rms = Math.Sqrt(sumSq / mono.Length);
        UpdatePresence(20 * Math.Log10(Math.Max(rms, 1e-9)), now);
        UpdateLevelSource(now);

        var n = _fftSize;
        // Sliding window over the most recent n samples; one FFT per delivered buffer.
        if (mono.Length >= n)
        {
            Array.Copy(mono, mono.Length - n, _ring, 0, n);
        }
        else
        {
            Array.Copy(_ring, mono.Length, _ring, 0, n - mono.Length);
            Array.Copy(mono, 0, _ring, n - mono.Length, mono.Length);
        }
        _ringFilled = Math.Min(_ringFilled + mono.Length, n);
        if (_ringFilled < n) return;
        var dt = mono.Length / _sampleRate;

        for (var i = 0; i < n; i++)
        {
            _re[_bitReverse[i]] = _ring[i] * _window[i];
        }
        Array.Clear(_im, 0, n);
        Fft();
        // Match vDSP's real-FFT scaling (2x the DFT) so the band amplitude formula is identical to macOS.
        var half = n / 2;
        for (var k = 0; k < half; k++) _power[k] = 4f * (_re[k] * _re[k] + _im[k] * _im[k]);

        // Auto-gain: each band is divided by its own rolling maximum, so local peaks reach 1.0 however
        // quiet the track or the PC's output volume is.
        var bassRatio = AutoGain(BandAmplitude(BassLow, BassHigh), _bassPeak, dt);
        var vocalRatio = AutoGain(BandAmplitude(VocalLow, VocalHigh), _vocalPeak, dt);

        // Kicks sit ~10-15 dB above the gaps between them, so the linear ratio already reads as distinct
        // hits. Vocals get a square root (~24 dB window) so sustained singing well below the peak still
        // moves the comets.
        var bassLevel = bassRatio;
        var vocalLevel = Math.Sqrt(vocalRatio);

        // Vocal onset: a spectral-flux spike in the 300 Hz-3.4 kHz band, matched against lyric word starts so the
        // playhead locks onto the singer's voice.
        var flux = Math.Max(0, vocalRatio - _prevVocalRatio);
        _prevVocalRatio = vocalRatio;
        if (flux > 0.10 && flux > 2.2 * _fluxAverage && vocalRatio > 0.25 && now - _lastOnsetTime > 0.12 && _state.PlaybackClock.IsPlaying)
        {
            _lastOnsetTime = now;
            _state.VocalLock.NoteOnset(_state.PlaybackClock.CurrentTrackTime(now), now);
        }
        _fluxAverage += (flux - _fluxAverage) * Math.Min(1, dt * 3);

        _bassEnvelope = Envelope(_bassEnvelope, bassLevel, dt, 0.012, 0.16);
        _vocalEnvelope = Envelope(_vocalEnvelope, vocalLevel, dt, 0.03, 0.35);
        // The FFT keeps running under Cloud Sync (to notice audio coming back) but only publishes when live.
        if (_levelSource != LevelSource.CloudSync)
            _state.AudioLevels.Update(_bassEnvelope, _vocalEnvelope);
    }

    /// <summary>In-place iterative radix-2 FFT; input was written bit-reversed into _re/_im.</summary>
    private void Fft()
    {
        var n = _fftSize;
        for (var size = 2; size <= n; size <<= 1)
        {
            var halfSize = size >> 1;
            var step = n / size;
            for (var start = 0; start < n; start += size)
            {
                for (var j = 0; j < halfSize; j++)
                {
                    var wr = _cos[j * step];
                    var wi = _sin[j * step];
                    var a = start + j;
                    var b = a + halfSize;
                    var tr = _re[b] * wr - _im[b] * wi;
                    var ti = _re[b] * wi + _im[b] * wr;
                    _re[b] = _re[a] - tr;
                    _im[b] = _im[a] - ti;
                    _re[a] += tr;
                    _im[a] += ti;
                }
            }
        }
    }

    /// <summary>Combined linear amplitude of the bins covering the band (a full-scale sine reads about 1).</summary>
    private double BandAmplitude(double low, double high)
    {
        var half = _fftSize / 2;
        var binHz = _sampleRate / _fftSize;
        // Bin 0 holds DC, so start at bin 1.
        var lo = Math.Max(1, (int)(low / binHz));
        var hi = Math.Min(half - 1, (int)Math.Ceiling(high / binHz));
        if (hi < lo) return 0;
        double sum = 0;
        for (var k = lo; k <= hi; k++) sum += _power[k];
        // zrip-style output is 2x the DFT and the Hann window halves amplitude: amplitude = |X| * 2 / N.
        return Math.Sqrt(sum) * 2 / _fftSize;
    }

    /// <summary>Current band amplitude as a 0..1 fraction of the loudest it has been over the last few seconds.</summary>
    private static double AutoGain(double amplitude, RollingPeak peak, double dt)
    {
        var reference = Math.Max(peak.Update(amplitude, dt), NoiseFloor);
        var db = 20 * Math.Log10(Math.Max(amplitude, 1e-9));
        var gate = Math.Min(Math.Max((db - GateDb) / GateRangeDb, 0), 1);
        return Math.Min(amplitude / reference, 1) * gate;
    }

    /// <summary>Fast-attack / smooth-decay one-pole envelope follower.</summary>
    private static double Envelope(double current, double target, double dt, double attack, double release)
    {
        var tau = target > current ? attack : release;
        return current + (target - current) * (1 - Math.Exp(-dt / tau));
    }

    private void ResetAnalysis()
    {
        _ringFilled = 0;
        _bassEnvelope = 0;
        _vocalEnvelope = 0;
        _bassPeak.Reset();
        _vocalPeak.Reset();
        SetAudioPresent(false);
        UpdateLevelSource(Clock.Now);
        if (_levelSource != LevelSource.CloudSync) _state.AudioLevels.Update(0, 0);
    }

    // ---- Live <-> Cloud Sync ----

    /// <summary>Audio counts as present the instant it rises above -68 dBFS, and as gone after 1.5 s below -72 dBFS.</summary>
    private void UpdatePresence(double levelDb, double now)
    {
        if (levelDb > PresenceDb)
        {
            _silentSince = null;
            SetAudioPresent(true);
        }
        else if (levelDb < SilenceDb)
        {
            var since = _silentSince ?? now;
            _silentSince = since;
            if (now - since >= SilenceHold) SetAudioPresent(false);
        }
        else
        {
            _silentSince = null;
        }
    }

    private void SetAudioPresent(bool present)
    {
        if (present == _audioPresent) return;
        _audioPresent = present;
        if (!present) _silentSince = null;
        _state.SystemAudioActive = present;
    }

    /// <summary>
    /// Live FFT while the PC is making sound; Cloud Sync once a native player has reported playback for
    /// 1.5 s with the PC silent (or capture unavailable); otherwise the (silent) live FFT if capture runs.
    /// </summary>
    private void UpdateLevelSource(double now)
    {
        var nativePlaying = _state.CloudSync.NativePlaybackActive;
        if (!nativePlaying) _nativePlayingSince = null;
        else _nativePlayingSince ??= now;

        LevelSource source;
        if (_audioPresent) source = LevelSource.Live;
        else if (_nativePlayingSince is double since && now - since >= SilenceHold) source = LevelSource.CloudSync;
        else source = _captureRunning ? LevelSource.Live : LevelSource.None;

        if (source == _levelSource) return;
        var wasCloud = _levelSource == LevelSource.CloudSync;
        _levelSource = source;
        if (source == LevelSource.CloudSync)
        {
            _lastSynthTime = null;
            ScheduleTicker(8); // ~120 Hz synthesizer clock (the OS timer rounds this up)
        }
        else if (wasCloud)
        {
            ScheduleTicker(250);
        }
        _state.LevelSource = source;
    }

    private void ScheduleTicker(int intervalMs) => _ticker?.Change(intervalMs, intervalMs);

    /// <summary>Watchdog (4 Hz) and, under Cloud Sync, the synthesizer clock.</summary>
    private void Tick()
    {
        lock (_sync)
        {
            if (_disposed) return;
            var now = Clock.Now;
            // No buffers at all (loopback delivers nothing while the PC is silent) is silence too.
            if (_audioPresent && (!_captureRunning || now - _lastBufferTime > SilenceHold))
                SetAudioPresent(false);
            UpdateLevelSource(now);
            if (_levelSource != LevelSource.CloudSync) return;
            var dt = _lastSynthTime.HasValue ? now - _lastSynthTime.Value : 0;
            _lastSynthTime = now;
            var trackTime = _state.PlaybackClock.CurrentTrackTime(now);
            var levels = _state.CloudSync.Levels(trackTime, dt);
            _state.AudioLevels.Update(levels.Bass, levels.Vocal);
        }
    }
}

/// <summary>
/// Rolling maximum of a band's amplitude over the last ~4 s, kept as 16 buckets of 0.25 s so each update
/// costs a 16-element max instead of scanning the full history. The reference jumps up to a new peak
/// immediately; when an old peak ages out of the window it eases down in dB (~0.8 s time constant).
/// </summary>
internal sealed class RollingPeak
{
    private const double BucketDuration = 0.25;
    private const int BucketCount = 16;
    private const double ReleaseTime = 0.8;

    private readonly double[] _buckets = new double[BucketCount];
    private int _index;
    private double _bucketAge;
    private double _reference;

    public double Update(double amplitude, double dt)
    {
        _bucketAge += dt;
        while (_bucketAge >= BucketDuration)
        {
            _bucketAge -= BucketDuration;
            _index = (_index + 1) % BucketCount;
            _buckets[_index] = 0;
        }
        _buckets[_index] = Math.Max(_buckets[_index], amplitude);

        var windowMax = 0.0;
        foreach (var b in _buckets) if (b > windowMax) windowMax = b;
        if (windowMax >= _reference)
        {
            _reference = windowMax;
        }
        else
        {
            // Ease down in the dB domain, so a 24 dB drop settles as quickly as a 6 dB one.
            _reference *= Math.Pow(Math.Max(windowMax, 1e-9) / _reference, 1 - Math.Exp(-dt / ReleaseTime));
        }
        return _reference;
    }

    public void Reset()
    {
        Array.Clear(_buckets, 0, BucketCount);
        _index = 0;
        _bucketAge = 0;
        _reference = 0;
    }
}
