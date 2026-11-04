using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace EdgeGlow;

/// <summary>
/// Owns one click-through overlay per enabled display, keyed by the monitor's hardware ID. Overlays are
/// created when a display is checked in the flyout and destroyed when it is unchecked or unplugged. Each
/// overlay has its own renderer, so physics and sparks are per screen. One shared render loop ticks them all.
/// </summary>
public sealed class DisplayManager : IDisposable
{
    private readonly AppState _state;
    private readonly Dispatcher _ui;
    private readonly Dictionary<string, OverlayWindow> _overlays = new();
    private readonly Dictionary<string, LyricsOverlayWindow> _lyricOverlays = new();
    private readonly LyricsModel _lyrics;
    private DisplayMode _lastMode;
    private readonly DispatcherTimer _topmostTimer;
    private bool _rendering;
    private bool _refreshPending;
    private HashSet<string> _lastActive = new();

    public DisplayManager(AppState state, Dispatcher ui, LyricsModel lyrics)
    {
        _state = state;
        _lyrics = lyrics;
        _ui = ui;
        _topmostTimer = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) =>
        {
            foreach (var overlay in _overlays.Values) overlay.ReassertTopmost();
            foreach (var overlay in _lyricOverlays.Values) overlay.ReassertTopmost();
        }, ui);
    }

    public void Start()
    {
        // Fires on plug/unplug, resolution and arrangement changes.
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        _state.Changed += OnStateChanged;
        Refresh();
        _topmostTimer.Start();
    }

    public void Dispose()
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _state.Changed -= OnStateChanged;
        _topmostTimer.Stop();
        StopRendering();
        foreach (var overlay in _overlays.Values) overlay.Close();
        _overlays.Clear();
        foreach (var overlay in _lyricOverlays.Values) overlay.Close();
        _lyricOverlays.Clear();
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => ScheduleRefresh();

    private void OnStateChanged()
    {
        // Only the active display set matters here; ignore everything else without touching the UI thread.
        var active = _state.ActiveDisplays;
        if (active.SetEquals(_lastActive) && _state.DisplayMode == _lastMode) { EnsureRendering(); return; }
        ScheduleRefresh();
    }

    private void ScheduleRefresh()
    {
        if (_refreshPending) return;
        _refreshPending = true;
        // Display changes arrive in bursts while a layout settles.
        _ui.BeginInvoke(new Action(() => { _refreshPending = false; Refresh(); }), DispatcherPriority.Background);
    }

    private void EnsureRendering()
    {
        if (_overlays.Count == 0 && _lyricOverlays.Count == 0) return;
        _ui.BeginInvoke(new Action(StartRendering));
    }

    /// <summary>Re-reads the monitor list and brings the set of live overlays in line with the checked, connected displays.</summary>
    private void Refresh()
    {
        var monitors = MonitorEnumerator.Enumerate();

        // Two identical monitors share a name; number them so the list stays unambiguous.
        var seen = new Dictionary<string, int>();
        var displays = monitors.Select(m =>
        {
            var total = monitors.Count(o => o.Name == m.Name);
            seen[m.Name] = seen.GetValueOrDefault(m.Name) + 1;
            return new DisplayInfo(m.Id, total > 1 ? $"{m.Name} ({seen[m.Name]})" : m.Name, m.IsBuiltIn);
        }).ToList();
        _state.AvailableDisplays = displays;

        // First launch: start with the primary display.
        if (!_state.HasDisplayChoice)
        {
            var primary = monitors.FirstOrDefault(m => m.IsPrimary) ?? monitors.FirstOrDefault();
            _state.SetActiveDisplays(primary != null ? new[] { primary.Id } : Array.Empty<string>());
        }

        var mode = _state.DisplayMode;
        _lastMode = mode;
        var active = _state.ActiveDisplays;
        _lastActive = new HashSet<string>(active);
        var connected = monitors.ToDictionary(m => m.Id, m => m, StringComparer.Ordinal);

        // Standby / lyrics-only tears the glow down; unchecked or disconnected displays lose theirs too.
        var glowIds = mode.GlowOn() ? active : new HashSet<string>();
        var lyricIds = mode.LyricsOn() ? active : new HashSet<string>();
        foreach (var id in _lyricOverlays.Keys.Where(id => !lyricIds.Contains(id) || !connected.ContainsKey(id)).ToList())
        {
            _lyricOverlays[id].Close();
            _lyricOverlays.Remove(id);
        }
        foreach (var monitor in monitors.Where(m => lyricIds.Contains(m.Id)))
        {
            if (_lyricOverlays.TryGetValue(monitor.Id, out var existingLyrics)) existingLyrics.UpdateMonitor(monitor);
            else
            {
                var overlay = new LyricsOverlayWindow(monitor);
                _lyricOverlays[monitor.Id] = overlay;
                overlay.Show();
            }
        }

        foreach (var id in _overlays.Keys.Where(id => !glowIds.Contains(id) || !connected.ContainsKey(id)).ToList())
        {
            _overlays[id].Close();
            _overlays.Remove(id);
        }

        foreach (var monitor in monitors.Where(m => glowIds.Contains(m.Id)))
        {
            if (_overlays.TryGetValue(monitor.Id, out var existing))
            {
                existing.UpdateMonitor(monitor); // resolution or arrangement may have changed
            }
            else
            {
                var overlay = new OverlayWindow(monitor);
                _overlays[monitor.Id] = overlay;
                overlay.Show();
            }
        }

        if (_overlays.Count > 0 || _lyricOverlays.Count > 0) StartRendering(); else StopRendering();
    }

    // ---- Render loop ----

    private void StartRendering()
    {
        if (_rendering) return;
        _rendering = true;
        CompositionTarget.Rendering += OnRendering;
    }

    private void StopRendering()
    {
        if (!_rendering) return;
        _rendering = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        var now = Clock.Now;
        var anyAnimating = false;
        foreach (var overlay in _overlays.Values)
        {
            if (overlay.Render(now, _state)) anyAnimating = true;
        }
        foreach (var overlay in _lyricOverlays.Values)
        {
            if (overlay.Render(now, _state, _lyrics)) anyAnimating = true;
        }
        // Every overlay faded out and blanked: stop burning frames until the glow is lit again.
        if (!anyAnimating) StopRendering();
    }
}
