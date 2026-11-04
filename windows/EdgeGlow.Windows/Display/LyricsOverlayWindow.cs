using System;
using System.Numerics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using EdgeGlow.Lyrics;
using SkiaSharp;

namespace EdgeGlow;

/// <summary>
/// The lyrics overlay for one monitor: a borderless, transparent, click-through (WS_EX_TRANSPARENT | WS_EX_LAYERED |
/// WS_EX_TOOLWINDOW), always-on-top window over the central 85 % of the screen. The 11 styles are drawn by the shared
/// SkiaSharp renderer into a WriteableBitmap.
/// </summary>
public sealed class LyricsOverlayWindow : Window
{
    private const int MaxRenderWidth = 1920;
    private const double MinFrameInterval = 1.0 / 30;

    private readonly Image _image = new() { Stretch = Stretch.Fill, SnapsToDevicePixels = true };
    private readonly LyricsDirector _director = new();
    private WriteableBitmap? _bitmap;
    private MonitorInfo _monitor;
    private IntPtr _hwnd;
    private bool _cleared;
    private double _lastFrame;
    private double _alpha;

    public string MonitorId => _monitor.Id;

    public LyricsOverlayWindow(MonitorInfo monitor)
    {
        _monitor = monitor;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false; IsHitTestVisible = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = monitor.X; Top = monitor.Y; Width = 100; Height = 100;
        Content = _image;
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.Linear);
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.AddExStyle(_hwnd, Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST);
            HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
            Reposition();
        };
        Closed += (_, _) => _director.Dispose();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_NCHITTEST: handled = true; return new IntPtr(Native.HTTRANSPARENT);
            case Native.WM_MOUSEACTIVATE: handled = true; return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_DPICHANGED: handled = true; Reposition(); break;
        }
        return IntPtr.Zero;
    }

    /// <summary>The 85 % safe area, centred, in physical pixels.</summary>
    private (int X, int Y, int W, int H) Canvas() =>
        ((int)(_monitor.X + _monitor.Width * 0.075), (int)(_monitor.Y + _monitor.Height * 0.075), (int)(_monitor.Width * 0.85), (int)(_monitor.Height * 0.85));

    private void Reposition()
    {
        if (_hwnd == IntPtr.Zero) return;
        var (x, y, w, h) = Canvas();
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        var scale = Math.Min(1.0, MaxRenderWidth / (double)Math.Max(w, 1));
        _bitmap = new WriteableBitmap(Math.Max(1, (int)Math.Round(w * scale)), Math.Max(1, (int)Math.Round(h * scale)), 96, 96, PixelFormats.Pbgra32, null);
        _image.Source = _bitmap;
        _cleared = false;
    }

    public void UpdateMonitor(MonitorInfo monitor) { if (monitor == _monitor) return; _monitor = monitor; Reposition(); }

    public void ReassertTopmost()
    {
        if (_hwnd == IntPtr.Zero) return;
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    /// <summary>Draws one frame. Returns false once blank and idle (nothing to animate).</summary>
    public bool Render(double now, AppState state, LyricsModel model)
    {
        var bitmap = _bitmap;
        if (bitmap == null) return true;
        var lyrics = model.Lyrics;
        var visible = lyrics != null && !lyrics.IsEmpty && state.DisplayMode.LyricsOn();
        var playing = state.IsPlaying;
        if (!visible)
        {
            _alpha = 0;
            if (!_cleared) { Clear(bitmap); _cleared = true; }
            return false;
        }
        // One dimmed frame while paused is enough; while playing, cap at 30 fps.
        if (now - _lastFrame < MinFrameInterval && playing) return true;
        _lastFrame = now;
        _cleared = false;
        _alpha += ((playing ? 1.0 : 0.55) - _alpha) * 0.25;

        bitmap.Lock();
        try
        {
            var info = new SKImageInfo(bitmap.PixelWidth, bitmap.PixelHeight, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var surface = SKSurface.Create(info, bitmap.BackBuffer, bitmap.BackBufferStride);
            var canvas = surface.Canvas;
            canvas.Clear(SKColors.Transparent);
            var (bass, vocal) = state.AudioLevels.Snapshot();
            var hl = state.TargetPrimary; var sec = state.TargetSecondary;
            var theme = new LyricTheme(state.LyricFont, new Vector4((float)hl.R, (float)hl.G, (float)hl.B, 1), new Vector4((float)sec.R, (float)sec.G, (float)sec.B, 1), state.LyricTextScale);
            var input = new SceneInput
            {
                Lyrics = lyrics!, Pos = model.Playhead(now), Theme = theme, Width = info.Width, Height = info.Height,
                Bass = bass, Vocal = vocal, Velocity = Math.Clamp(vocal * 1.2, 0, 1), Time = now, FocusY = state.LyricVerticalPosition,
            };
            var scene = _director.Advance(input, state.LyricStyle);
            _director.Render(canvas, input, scene, (float)_alpha);
            canvas.Flush();
            bitmap.AddDirtyRect(new Int32Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight));
        }
        finally { bitmap.Unlock(); }
        return playing;
    }

    private static void Clear(WriteableBitmap bitmap)
    {
        bitmap.Lock();
        try
        {
            var info = new SKImageInfo(bitmap.PixelWidth, bitmap.PixelHeight, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var surface = SKSurface.Create(info, bitmap.BackBuffer, bitmap.BackBufferStride);
            surface.Canvas.Clear(SKColors.Transparent);
            surface.Canvas.Flush();
            bitmap.AddDirtyRect(new Int32Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight));
        }
        finally { bitmap.Unlock(); }
    }
}
