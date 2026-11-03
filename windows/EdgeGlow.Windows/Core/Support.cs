using System.Diagnostics;

namespace EdgeGlow;

/// <summary>Monotonic seconds since process start (the CACurrentMediaTime of this port).</summary>
public static class Clock
{
    private static readonly Stopwatch Watch = Stopwatch.StartNew();
    public static double Now => Watch.Elapsed.TotalSeconds;
}

/// <summary>
/// Latest band energies (0..1). Written ~50-120x/s off the UI thread and read by the renderer every
/// frame, so it is lock-protected instead of raising change events.
/// </summary>
public sealed class AudioLevels
{
    private readonly object _lock = new();
    private double _bass;
    private double _vocal;

    public (double Bass, double Vocal) Snapshot()
    {
        lock (_lock) return (_bass, _vocal);
    }

    public void Update(double bass, double vocal)
    {
        lock (_lock) { _bass = bass; _vocal = vocal; }
    }
}

/// <summary>
/// Continuous playback clock: the last polled track position plus the time elapsed since the poll.
/// Written by the media bridge every couple of seconds, read at audio/frame rate from other threads.
/// </summary>
public sealed class PlaybackClock
{
    private readonly object _lock = new();
    private double _lastPolledPosition;
    private double _lastPollTime = Clock.Now;
    private bool _playing;

    public bool IsPlaying { get { lock (_lock) return _playing; } }

    /// <summary>currentTrackTime = lastPolledPosition + (now - lastPollTime) while playing; frozen while paused.</summary>
    public double CurrentTrackTime(double? at = null)
    {
        var now = at ?? Clock.Now;
        lock (_lock) return _playing ? _lastPolledPosition + (now - _lastPollTime) : _lastPolledPosition;
    }

    /// <summary>Re-anchors the clock to a position that was sampled at <paramref name="time"/> (a Clock.Now value).</summary>
    public void Anchor(double position, double time)
    {
        lock (_lock) { _lastPolledPosition = position; _lastPollTime = time; }
    }

    public void SetPlaying(bool value, double? at = null)
    {
        var now = at ?? Clock.Now;
        lock (_lock)
        {
            if (_playing != value)
            {
                // Freeze (or restart) the clock at the current extrapolated position.
                _lastPolledPosition = _playing ? _lastPolledPosition + (now - _lastPollTime) : _lastPolledPosition;
                _lastPollTime = now;
                _playing = value;
            }
        }
    }
}
