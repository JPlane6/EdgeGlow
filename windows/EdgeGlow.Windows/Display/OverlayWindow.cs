using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkiaSharp;

namespace EdgeGlow;

/// <summary>
/// One borderless, transparent, click-through, always-on-top window covering a single monitor. It never takes
/// focus, hides from Alt-Tab and the taskbar, and passes every mouse event through to the windows below.
/// The glow is rasterized with SkiaSharp into a WriteableBitmap at reduced resolution (the glow is soft, so
/// this is invisible) and stretched over the window.
/// </summary>
public sealed class OverlayWindow : Window
{
    /// <summary>Cap on the rendered bitmap width; large monitors render below native resolution.</summary>
    private const int MaxRenderWidth = 1600;

    private readonly Image _image = new() { Stretch = Stretch.Fill, SnapsToDevicePixels = true };
    private readonly GlowRenderer _renderer = new();
    private WriteableBitmap? _bitmap;
    private MonitorInfo _monitor;
    private IntPtr _hwnd;
    private bool _fadingOut;
    private double _fadeOutUntil;
    private bool _cleared;

    public string MonitorId => _monitor.Id;

    public OverlayWindow(MonitorInfo monitor)
    {
        _monitor = monitor;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        IsHitTestVisible = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = monitor.X;
        Top = monitor.Y;
        Width = 100;
        Height = 100;
        Content = _image;
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.Linear);
        SourceInitialized += OnSourceInitialized;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        Native.AddExStyle(_hwnd, Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW
                                  | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST);
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
        Reposition();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_NCHITTEST:
                handled = true;
                return new IntPtr(Native.HTTRANSPARENT);
            case Native.WM_MOUSEACTIVATE:
                handled = true;
                return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_DPICHANGED:
                // We size ourselves in physical pixels; ignore the suggested rectangle.
                handled = true;
                Reposition();
                break;
        }
        return IntPtr.Zero;
    }

    /// <summary>Places the window exactly over the monitor, in physical pixels, above everything (including the taskbar).</summary>
    private void Reposition()
    {
        if (_hwnd == IntPtr.Zero) return;
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, _monitor.X, _monitor.Y, _monitor.Width, _monitor.Height,
            Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        AllocateBitmap();
    }

    /// <summary>Re-applies geometry after a resolution/arrangement change.</summary>
    public void UpdateMonitor(MonitorInfo monitor)
    {
        if (monitor == _monitor) return;
        _monitor = monitor;
        Reposition();
    }

    /// <summary>Windows reorders topmost windows as other topmost windows appear (e.g. the taskbar); keep the glow above them.</summary>
    public void ReassertTopmost()
    {
        if (_hwnd == IntPtr.Zero) return;
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
            Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }


    private void AllocateBitmap()
    {
        var pxW = Math.Max(_monitor.Width, 1);
        var pxH = Math.Max(_monitor.Height, 1);
        var scale = Math.Min(1.0, MaxRenderWidth / (double)pxW);
        var bw = Math.Max(1, (int)Math.Round(pxW * scale));
        var bh = Math.Max(1, (int)Math.Round(pxH * scale));
        _bitmap = new WriteableBitmap(bw, bh, 96, 96, PixelFormats.Pbgra32, null);
        _image.Source = _bitmap;
        _cleared = false;
    }

    /// <summary>Renders one frame. Returns false once the fade-out has finished and the window is blank (nothing left to animate).</summary>
    public bool Render(double now, AppState state)
    {
        var bitmap = _bitmap;
        if (bitmap == null) return true;

        if (state.GlowActive)
        {
            _fadingOut = false;
        }
        else if (!_fadingOut)
        {
            // Keep ticking long enough for the fade-out to finish, then stop burning frames.
            _fadingOut = true;
            _fadeOutUntil = now + 2.5;
        }
        if (_fadingOut && now > _fadeOutUntil)
        {
            if (!_cleared) { Clear(bitmap); _cleared = true; }
            return false;
        }
        _cleared = false;

        bitmap.Lock();
        try
        {
            var info = new SKImageInfo(bitmap.PixelWidth, bitmap.PixelHeight, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var surface = SKSurface.Create(info, bitmap.BackBuffer, bitmap.BackBufferStride);
            var canvas = surface.Canvas;
            canvas.Clear(SKColors.Transparent);

            // Draw in device-independent points: monitor pixels / DPI scale, mapped onto the (smaller) bitmap.
            var dipW = (float)(_monitor.Width / _monitor.DpiScale);
            var dipH = (float)(_monitor.Height / _monitor.DpiScale);
            canvas.Scale(bitmap.PixelWidth / dipW, bitmap.PixelHeight / dipH);
            _renderer.Draw(canvas, dipW, dipH, now, state);
            canvas.Flush();
            bitmap.AddDirtyRect(new Int32Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight));
        }
        finally
        {
            bitmap.Unlock();
        }
        return true;
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
        finally
        {
            bitmap.Unlock();
        }
    }
}
