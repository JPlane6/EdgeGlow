using System;
using System.Linq;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace EdgeGlow;

/// <summary>
/// Measures how long audio takes to leave the default output, with no user input. Wired / built-in endpoints report
/// their WASAPI stream latency and device period (about 15 ms). Bluetooth endpoints (enumerator BTHENUM / BTHHFENUM,
/// or a Bluetooth form factor / name) add the A2DP pipeline delay (about 165 ms) when the driver reports less than 120 ms.
/// Re-evaluated when the default device changes.
/// </summary>
public sealed class AudioLatencyDetector : IMMNotificationClient, IDisposable
{
    public const double BluetoothPipelineMs = 165;
    private const double BluetoothReportedCeilingMs = 120;
    private static readonly PropertyKey EnumeratorName = new(new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 24);

    private readonly AppState _state;
    private MMDeviceEnumerator? _enumerator;
    private Timer? _timer;
    private bool _disposed;

    public AudioLatencyDetector(AppState state) => _state = state;

    public void Start()
    {
        try
        {
            _enumerator = new MMDeviceEnumerator();
            _enumerator.RegisterEndpointNotificationCallback(this);
        }
        catch { /* no audio stack: keep the default route */ }
        Refresh();
        _timer = new Timer(_ => Refresh(), null, 10_000, 10_000);
    }

    public void Dispose()
    {
        _disposed = true;
        _timer?.Dispose();
        try { _enumerator?.UnregisterEndpointNotificationCallback(this); } catch { }
        _enumerator?.Dispose();
    }

    public void Refresh()
    {
        if (_disposed) return;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var name = device.FriendlyName;
            var enumeratorName = "";
            try { if (device.Properties.Contains(EnumeratorName)) enumeratorName = device.Properties[EnumeratorName].Value?.ToString() ?? ""; } catch { }
            var formFactor = "";
            try { formFactor = device.Properties.Contains(PropertyKeys.PKEY_AudioEndpoint_FormFactor) ? device.Properties[PropertyKeys.PKEY_AudioEndpoint_FormFactor].Value?.ToString() ?? "" : ""; } catch { }

            var lower = name.ToLowerInvariant();
            var bluetooth = enumeratorName.StartsWith("BTH", StringComparison.OrdinalIgnoreCase) || lower.Contains("bluetooth") ||
                            lower.Contains("airpods") || lower.Contains("buds") || lower.Contains("wh-1000") || lower.Contains("hands-free");

            double reportedMs = 15;
            try
            {
                var client = device.AudioClient;
                var stream = client.StreamLatency / 10_000.0;                // 100 ns units to ms
                var period = client.DefaultDevicePeriod / 10_000.0;
                reportedMs = Math.Max(stream + period / 2, 1);
            }
            catch { /* exclusive-mode device or access denied */ }

            var total = reportedMs;
            if (bluetooth && reportedMs < BluetoothReportedCeilingMs) total += BluetoothPipelineMs;
            else if (!bluetooth) total = Math.Clamp(reportedMs, 8, 60);

            var headphones = bluetooth || formFactor is "3" or "5" or "6" || lower.Contains("headphone") || lower.Contains("headset");
            var friendly = headphones ? "Headphones" : "Speakers";
            _state.AudioRoute = new AudioRoute(friendly, bluetooth, total);
        }
        catch { /* leave the previous route */ }
    }

    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId) { if (flow == DataFlow.Render) Refresh(); }
    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
}

/// <summary>
/// Learns a small timing correction from the vocals in the live audio. A vocal onset (a jump in 300 Hz-3.4 kHz energy)
/// that lands near a lyric word start says how far the player's reported position is from the audible voice. An
/// asymmetric moving average (fast attack, slow release) clamped to +/-200 ms trims the playhead; with no vocals the
/// trim relaxes to zero.
/// </summary>
public sealed class VocalOnsetLock
{
    private const double MatchWindow = 0.20, MaxCorrection = 0.20, AttackGain = 0.6, ReleaseGain = 0.1, IdleDecay = 4.0;
    private readonly object _lock = new();
    private double[] _starts = Array.Empty<double>();
    private double _trim, _lastConfirmation;

    public void SetWordStarts(double[] sortedStarts) { lock (_lock) { _starts = sortedStarts; _trim = 0; } }
    public void Reset() { lock (_lock) _trim = 0; }

    public double Correction(double now)
    {
        lock (_lock)
        {
            var idle = now - _lastConfirmation;
            return idle > IdleDecay ? _trim * Math.Max(0, 1 - (idle - IdleDecay) / 2) : _trim;
        }
    }

    public void NoteOnset(double trackTime, double now)
    {
        lock (_lock)
        {
            if (_starts.Length == 0) return;
            var i = Array.BinarySearch(_starts, trackTime);
            if (i < 0) i = ~i;
            double nearest = double.NaN;
            if (i < _starts.Length) nearest = _starts[i];
            if (i > 0 && (double.IsNaN(nearest) || Math.Abs(_starts[i - 1] - trackTime) < Math.Abs(nearest - trackTime))) nearest = _starts[i - 1];
            if (double.IsNaN(nearest)) return;
            var gap = trackTime - nearest;
            if (Math.Abs(gap) > MatchWindow) return;
            var target = Math.Clamp(-gap, -MaxCorrection, MaxCorrection);
            var gain = Math.Abs(target - _trim) > 0.04 ? AttackGain : ReleaseGain;
            _trim += (target - _trim) * gain;
            _lastConfirmation = now;
        }
    }
}
