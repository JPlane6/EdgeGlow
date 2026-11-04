using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using EdgeGlow.Lyrics;

namespace EdgeGlow;

/// <summary>
/// Dark control flyout shown from the tray icon (the Windows counterpart of MenuBarPopoverView): header with
/// status and live level meter, now-playing card, colors, animation style, displays, glow sliders, toggles.
/// Controls are built once and refreshed in place, so dragging a slider is never interrupted.
/// </summary>
public sealed class FlyoutWindow : Window
{
    private readonly AppState _s;
    private readonly Action _quit;
    private readonly List<Action> _refreshers = new();
    private readonly DispatcherTimer _meterTimer;
    private bool _refreshPending;
    private bool _suppressHide;
    private DateTime _hiddenAt = DateTime.MinValue;

    // Header
    private readonly TextBlock _glyph = Ui.Text("✦", 16, FontWeights.SemiBold);
    private readonly Ellipse _statusDot = new() { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _statusText = Ui.Text("Idle", 11, FontWeights.Medium, Ui.TextSecondary);
    private readonly Border _bassBar = LevelBar(), _vocalBar = LevelBar();
    private readonly Grid _bassHost = new() { Width = 4, Height = 12 }, _vocalHost = new() { Width = 4, Height = 12 };
    private readonly TextBlock _badgeText = Ui.Text("", 10, FontWeights.Bold);
    private readonly Border _badge = new();

    // Now playing
    private readonly Grid _art = new() { Width = 54, Height = 54 };
    private readonly Image _artImage = new() { Stretch = Stretch.UniformToFill };
    private readonly Border _artFallback = new();
    private readonly TextBlock _title = Ui.Text("", 13, FontWeights.SemiBold);
    private readonly TextBlock _subtitle = Ui.Text("", 12, null, Ui.TextSecondary);
    private readonly TextBlock _sourceLine = Ui.Text("", 10, FontWeights.Medium);
    private byte[]? _shownArtwork;

    // Banner
    private readonly Border _audioBanner = new();
    private readonly TextBlock _audioBannerText = Ui.Text("", 11, null, Ui.TextPrimary, wrap: true);

    // Colors
    private readonly Border _primaryPill = new(), _secondaryPill = new();
    private readonly Ellipse _primaryDot = new() { Width = 12, Height = 12 }, _secondaryDot = new() { Width = 12, Height = 12 };
    private readonly TextBlock _primaryHex = Ui.Text("", 11, FontWeights.Medium), _secondaryHex = Ui.Text("", 11, FontWeights.Medium);
    private readonly SwitchControl _overrideSwitch = new();
    private readonly StackPanel _customRow = new() { Orientation = Orientation.Horizontal };
    private readonly Border _customPrimaryButton = new(), _customSecondaryButton = new();

    // Style
    private readonly Dictionary<AnimationStyle, (Border Tile, TextBlock Glyph, TextBlock Label)> _tiles = new();
    // Mode + lyrics
    private readonly Dictionary<DisplayMode, (Border Tile, TextBlock Label)> _modeTiles = new();
    private readonly Dictionary<LyricStyle, (Border Tile, TextBlock Label)> _lyricStyleTiles = new();
    private readonly Dictionary<LyricFont, (Border Tile, TextBlock Label)> _fontTiles = new();
    private readonly SliderControl _lyricScale = new(0.6, 1.8), _lyricVertical = new(0, 1);
    private readonly TextBlock _lyricScaleValue = Value(), _lyricVerticalValue = Value();
    private readonly SwitchControl _romanizeSwitch = new();
    private readonly TextBlock _syncPill = Ui.Text("", 11, FontWeights.Medium, Ui.TextPrimary);
    private readonly Border _syncPillBorder = new();
    private readonly TextBlock _lyricsStatusText = Ui.Text("", 10, null, Ui.TextSecondary, wrap: true);
    private readonly TextBlock _styleCaption = Ui.Text("", 10, null, Ui.TextSecondary, wrap: true);

    // Displays
    private readonly StackPanel _displayRows = new();
    private readonly TextBlock _displaySummary = Ui.Text("", 10, FontWeights.Medium, Ui.TextSecondary);
    private readonly TextBlock _disconnectedNote = Ui.Text("", 10, null, Ui.TextSecondary, wrap: true);
    private string _displaySignature = "";

    // Sliders
    private readonly SliderControl _thickness = new(10, 120), _spread = new(15, 90), _reactivity = new(0, 1.5), _intensity = new(0.1, 1.0), _comet = new(0.05, 0.45);
    private readonly TextBlock _thicknessValue = Value(), _spreadValue = Value(), _reactivityValue = Value(), _intensityValue = Value(), _cometValue = Value();
    private readonly StackPanel _cometRow = new();

    // Toggles
    private readonly SwitchControl _idleSwitch = new(), _kineticSwitch = new(), _startupSwitch = new();
    private readonly TextBlock _kineticCaption = Ui.Text("", 10, null, Ui.TextSecondary);
    private readonly TextBlock _footerText = Ui.Text("", 10, null, Ui.TextTertiary);

    private readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

    public FlyoutWindow(AppState state, Action quit)
    {
        _s = state;
        _quit = quit;

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Height;
        Width = 360;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(1),
            BorderBrush = Ui.CardBorder,
            Background = new LinearGradientBrush(Color.FromRgb(0x1C, 0x1C, 0x1F), Color.FromRgb(0x12, 0x12, 0x14), 90),
            Padding = new Thickness(16),
            Child = BuildContent(),
        };

        state.Changed += ScheduleRefresh;
        Deactivated += (_, _) =>
        {
            if (_suppressHide) return;
            HideFlyout();
        };
        KeyDown += (_, e) => { if (e.Key == Key.Escape) HideFlyout(); };

        // Levels aren't change events (they update at audio rate), so poll them while the flyout is shown.
        _meterTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Background, (_, _) => UpdateMeters(), Dispatcher);
        Refresh();
    }

    // ---- Show / hide / position ----

    public void ToggleFlyout()
    {
        if (IsVisible) { HideFlyout(); return; }
        // The tray click that dismisses the flyout (it deactivates on mouse down) must not instantly reopen it.
        if ((DateTime.UtcNow - _hiddenAt).TotalMilliseconds < 250) return;
        ShowFlyout();
    }

    public void ShowFlyout()
    {
        Refresh();
        Opacity = 0;
        Show();
        UpdateLayout();
        Position();
        Opacity = 1;
        Activate();
        _meterTimer.Start();
    }

    public void HideFlyout()
    {
        if (!IsVisible) return;
        _meterTimer.Stop();
        Hide();
        _hiddenAt = DateTime.UtcNow;
    }

    /// <summary>Anchors the flyout to the taskbar corner of the monitor the cursor is on, inside the work area.</summary>
    private void Position()
    {
        Native.GetCursorPos(out var cursor);
        var screen = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(cursor.X, cursor.Y));
        var wa = screen.WorkingArea;
        var b = screen.Bounds;
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        _scroll.MaxHeight = Math.Max(180, wa.Height / dpi - 330);
        UpdateLayout();
        var w = (int)Math.Round(ActualWidth * dpi);
        var h = (int)Math.Round(ActualHeight * dpi);
        const int margin = 12;
        int x, y;
        if (wa.Top > b.Top) { y = wa.Top + margin; x = wa.Right - w - margin; }                  // taskbar on top
        else if (wa.Left > b.Left) { x = wa.Left + margin; y = wa.Bottom - h - margin; }          // taskbar on the left
        else { x = wa.Right - w - margin; y = wa.Bottom - h - margin; }                           // bottom or right
        x = Math.Clamp(x, wa.Left, Math.Max(wa.Left, wa.Right - w));
        y = Math.Clamp(y, wa.Top, Math.Max(wa.Top, wa.Bottom - h));
        Native.SetWindowPos(new System.Windows.Interop.WindowInteropHelper(this).Handle, Native.HWND_TOPMOST, x, y, 0, 0,
            Native.SWP_NOSIZE | Native.SWP_SHOWWINDOW);
    }

    // ---- Layout ----

    private static Border LevelBar() => new() { Background = Brushes.White, VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(2), Height = 2 };
    private static TextBlock Value() => Ui.Text("", 11, FontWeights.Medium, Ui.TextSecondary);

    private FrameworkElement BuildContent()
    {
        var root = new StackPanel();
        root.Children.Add(BuildHeader());
        root.Children.Add(Gap(14, BuildNowPlaying()));
        root.Children.Add(Gap(14, BuildAudioBanner()));
        root.Children.Add(Gap(14, BuildModes()));

        var cards = new StackPanel();
        cards.Children.Add(BuildLyrics());
        cards.Children.Add(Gap(14, BuildColors()));
        cards.Children.Add(Gap(14, BuildStyle()));
        cards.Children.Add(Gap(14, BuildDisplays()));
        cards.Children.Add(Gap(14, BuildSliders()));
        _scroll.Content = cards;
        root.Children.Add(Gap(14, _scroll));

        root.Children.Add(Gap(14, BuildToggles()));
        root.Children.Add(Gap(14, BuildFooter()));
        return root;
    }

    private static FrameworkElement Gap(double top, FrameworkElement e)
    {
        e.Margin = new Thickness(0, top, 0, 0);
        return e;
    }

    private FrameworkElement BuildHeader()
    {
        var dock = new DockPanel { LastChildFill = false };

        _badge.CornerRadius = new CornerRadius(12);
        _badge.Padding = new Thickness(8, 4, 8, 4);
        _badge.Background = new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255));
        _badge.BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 255, 255, 255));
        _badge.BorderThickness = new Thickness(1);
        _bassHost.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x1F, 255, 255, 255)), CornerRadius = new CornerRadius(2) });
        _bassHost.Children.Add(_bassBar);
        _vocalHost.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x1F, 255, 255, 255)), CornerRadius = new CornerRadius(2) });
        _vocalHost.Children.Add(_vocalBar);
        _badgeText.Margin = new Thickness(4, 0, 0, 0);
        var badgeRow = new StackPanel { Orientation = Orientation.Horizontal };
        _bassHost.Margin = new Thickness(0, 0, 4, 0);
        badgeRow.Children.Add(_bassHost);
        badgeRow.Children.Add(_vocalHost);
        badgeRow.Children.Add(_badgeText);
        _badge.Child = badgeRow;
        DockPanel.SetDock(_badge, Dock.Right);
        dock.Children.Add(_badge);

        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(_glyph);
        var name = Ui.Text("EdgeGlow", 15, FontWeights.SemiBold);
        name.Margin = new Thickness(8, 0, 10, 0);
        left.Children.Add(name);
        _statusDot.Margin = new Thickness(0, 0, 5, 0);
        left.Children.Add(_statusDot);
        left.Children.Add(_statusText);
        dock.Children.Add(left);
        return dock;
    }

    private FrameworkElement BuildNowPlaying()
    {
        _art.Clip = new RectangleGeometry(new Rect(0, 0, 54, 54), 9, 9);
        _artFallback.Child = Ui.Text("♪", 22, FontWeights.SemiBold, Brushes.White);
        ((TextBlock)_artFallback.Child).HorizontalAlignment = HorizontalAlignment.Center;
        ((TextBlock)_artFallback.Child).VerticalAlignment = VerticalAlignment.Center;
        _art.Children.Add(_artFallback);
        _art.Children.Add(_artImage);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        text.Children.Add(_title);
        _subtitle.Margin = new Thickness(0, 3, 0, 0);
        text.Children.Add(_subtitle);
        _sourceLine.Margin = new Thickness(0, 3, 0, 0);
        text.Children.Add(_sourceLine);

        var row = new DockPanel();
        DockPanel.SetDock(_art, Dock.Left);
        row.Children.Add(_art);
        row.Children.Add(text);
        return Ui.Card(row);
    }

    private FrameworkElement BuildAudioBanner()
    {
        _audioBanner.CornerRadius = new CornerRadius(12);
        _audioBanner.Padding = new Thickness(12);
        _audioBanner.Background = Ui.CardFill;
        _audioBanner.BorderBrush = Ui.CardBorder;
        _audioBanner.BorderThickness = new Thickness(1);
        var row = new DockPanel();
        var icon = Ui.Text("⚠", 14, null, Brushes.Gold);
        icon.Margin = new Thickness(0, 0, 10, 0);
        icon.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var stack = new StackPanel();
        stack.Children.Add(_audioBannerText);
        var settings = Button("Open Sound Settings", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:sound") { UseShellExecute = true }));
        settings.Margin = new Thickness(0, 6, 0, 0);
        settings.HorizontalAlignment = HorizontalAlignment.Left;
        stack.Children.Add(settings);
        row.Children.Add(stack);
        _audioBanner.Child = row;
        return _audioBanner;
    }

    private Border Button(string label, Action click)
    {
        var button = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 4, 10, 4),
            Background = new SolidColorBrush(Color.FromArgb(0x1F, 255, 255, 255)),
            Cursor = Cursors.Hand,
            Child = Ui.Text(label, 11, FontWeights.Medium),
        };
        button.MouseLeftButtonUp += (_, _) => click();
        return button;
    }

    private FrameworkElement BuildColors()
    {
        var pills = new Grid();
        pills.ColumnDefinitions.Add(new ColumnDefinition());
        pills.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        pills.ColumnDefinitions.Add(new ColumnDefinition());
        var p = Pill("Primary", _primaryPill, _primaryDot, _primaryHex);
        var q = Pill("Secondary", _secondaryPill, _secondaryDot, _secondaryHex);
        Grid.SetColumn(p, 0);
        Grid.SetColumn(q, 2);
        pills.Children.Add(p);
        pills.Children.Add(q);

        _overrideSwitch.Toggled += on => _s.UseCustomColors = on;
        var overrideRow = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(_overrideSwitch, Dock.Right);
        overrideRow.Children.Add(_overrideSwitch);
        overrideRow.Children.Add(Ui.Text("Override Album Colors", 12));

        _customPrimaryButton.Child = Ui.Text("Primary", 11, FontWeights.Medium);
        _customSecondaryButton.Child = Ui.Text("Secondary", 11, FontWeights.Medium);
        foreach (var b in new[] { _customPrimaryButton, _customSecondaryButton })
        {
            b.CornerRadius = new CornerRadius(6);
            b.Padding = new Thickness(10, 5, 10, 5);
            b.Margin = new Thickness(0, 0, 8, 0);
            b.Cursor = Cursors.Hand;
            b.BorderThickness = new Thickness(2);
            ((TextBlock)b.Child).Foreground = Brushes.White;
            ((TextBlock)b.Child).Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 3, ShadowDepth = 0, Color = Colors.Black, Opacity = 0.9 };
        }
        _customPrimaryButton.MouseLeftButtonUp += (_, _) => PickColor(_s.CustomPrimary, c => _s.CustomPrimary = c);
        _customSecondaryButton.MouseLeftButtonUp += (_, _) => PickColor(_s.CustomSecondary, c => _s.CustomSecondary = c);
        _customRow.Margin = new Thickness(0, 10, 0, 0);
        _customRow.Children.Add(_customPrimaryButton);
        _customRow.Children.Add(_customSecondaryButton);

        return Ui.Card(Ui.VStack(0, Ui.SectionTitle("Colors"), Gap(10, pills), overrideRow, _customRow));
    }

    private static Border Pill(string label, Border pill, Ellipse dot, TextBlock hex)
    {
        pill.CornerRadius = new CornerRadius(16);
        pill.Padding = new Thickness(10, 6, 10, 6);
        pill.BorderThickness = new Thickness(1);
        dot.Margin = new Thickness(0, 0, 6, 0);
        dot.VerticalAlignment = VerticalAlignment.Center;
        var labels = new StackPanel();
        labels.Children.Add(Ui.Text(label, 9, FontWeights.Medium, Ui.TextSecondary));
        hex.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        labels.Children.Add(hex);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(dot);
        row.Children.Add(labels);
        pill.Child = row;
        return pill;
    }

    /// <summary>The standard Windows color dialog; the flyout must not auto-hide while it has focus.</summary>
    private void PickColor(RgbColor current, Action<RgbColor> apply)
    {
        _suppressHide = true;
        try
        {
            using var dialog = new System.Windows.Forms.ColorDialog
            {
                FullOpen = true,
                Color = System.Drawing.Color.FromArgb(RgbColor.ToByte(current.R), RgbColor.ToByte(current.G), RgbColor.ToByte(current.B)),
            };
            if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
                apply(new RgbColor(dialog.Color.R / 255.0, dialog.Color.G / 255.0, dialog.Color.B / 255.0));
        }
        finally
        {
            _suppressHide = false;
            Activate();
        }
    }

    /// <summary>A selectable tile used by the mode, lyric style and font pickers.</summary>
    private Border Chip(string label, string? tooltip, Action click, out TextBlock text, double size = 10.5)
    {
        text = Ui.Text(label, size, FontWeights.Medium);
        text.HorizontalAlignment = HorizontalAlignment.Center;
        text.TextAlignment = TextAlignment.Center;
        var chip = new Border
        {
            CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 7, 6, 7), BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand, Child = text, ToolTip = tooltip, Margin = new Thickness(0, 0, 6, 6),
        };
        chip.MouseLeftButtonUp += (_, _) => click();
        return chip;
    }

    private static void StyleChip(Border chip, TextBlock label, bool selected, RgbColor accent)
    {
        chip.Background = selected ? Ui.Brush(accent, 0.16) : new SolidColorBrush(Color.FromArgb(0x0A, 255, 255, 255));
        chip.BorderBrush = selected ? Ui.Brush(accent, 0.55) : new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255));
        label.Foreground = selected ? Ui.TextPrimary : Ui.TextSecondary;
    }

    /// <summary>Both / Glow Only / Lyrics Only / Off. Off tears down overlays and pauses audio capture and media polling.</summary>
    private FrameworkElement BuildModes()
    {
        var grid = new UniformGrid { Columns = 4 };
        foreach (var mode in Enum.GetValues<DisplayMode>())
        {
            var m = mode;
            var chip = Chip(m.Title(), m == DisplayMode.Off ? "Standby: overlays, audio capture and media polling stop" : null, () => _s.DisplayMode = m, out var label, 11);
            chip.Margin = new Thickness(0, 0, m == DisplayMode.Off ? 0 : 6, 0);
            grid.Children.Add(chip);
            _modeTiles[m] = (chip, label);
        }
        return Ui.Card(Ui.VStack(0, Ui.SectionTitle("Mode"), Gap(10, grid)));
    }

    private FrameworkElement BuildLyrics()
    {
        // Read-only audio sync pill: there is deliberately no manual timing offset.
        _syncPillBorder.CornerRadius = new CornerRadius(10);
        _syncPillBorder.Padding = new Thickness(9, 4, 9, 4);
        _syncPillBorder.BorderThickness = new Thickness(1);
        _syncPillBorder.HorizontalAlignment = HorizontalAlignment.Left;
        _syncPillBorder.Child = _syncPill;
        _syncPillBorder.ToolTip = "Lyrics are synced automatically to this output's measured latency and to the singer's voice";

        var styles = new WrapPanel();
        foreach (var style in Enum.GetValues<LyricStyle>())
        {
            var st = style;
            var chip = Chip(st.Title(), null, () => _s.LyricStyle = st, out var label);
            chip.Width = 90;
            styles.Children.Add(chip);
            _lyricStyleTiles[st] = (chip, label);
        }
        var fonts = new WrapPanel();
        foreach (var font in Enum.GetValues<LyricFont>())
        {
            var f = font;
            var chip = Chip(f.Title(), null, () => _s.LyricFont = f, out var label, 10);
            chip.Width = 90;
            fonts.Children.Add(chip);
            _fontTiles[f] = (chip, label);
        }

        _lyricScale.ValueChanged += v => _s.LyricTextScale = v;
        _lyricVertical.ValueChanged += v => _s.LyricVerticalPosition = v;
        _romanizeSwitch.Toggled += on => _s.RomanizeLyrics = on;
        _lyricsStatusText.Margin = new Thickness(0, 8, 0, 0);

        return Ui.Card(Ui.VStack(0,
            Ui.SectionTitle("Lyrics"),
            Gap(8, _syncPillBorder),
            Gap(10, styles),
            Gap(4, Ui.Text("Font", 12, FontWeights.Medium)),
            Gap(6, fonts),
            Gap(4, SliderRow("Text Scale", _lyricScale, _lyricScaleValue)),
            Gap(10, SliderRow("Vertical Position", _lyricVertical, _lyricVerticalValue)),
            Gap(10, ToggleRow("Romanize Hindi / Punjabi / Urdu", Ui.Text("Devanagari, Gurmukhi and Arabic script to Latin", 10, null, Ui.TextSecondary), _romanizeSwitch)),
            _lyricsStatusText));
    }

    private FrameworkElement BuildStyle()
    {
        var tiles = new Grid();
        var styles = Enum.GetValues<AnimationStyle>();
        for (var i = 0; i < styles.Length; i++)
        {
            if (i > 0) tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
            tiles.ColumnDefinitions.Add(new ColumnDefinition());
            var style = styles[i];
            var glyph = Ui.Text(style.Glyph(), 15, FontWeights.Medium);
            glyph.HorizontalAlignment = HorizontalAlignment.Center;
            var label = Ui.Text(style.Title(), 10, FontWeights.Medium);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.Margin = new Thickness(0, 4, 0, 0);
            var stack = new StackPanel();
            stack.Children.Add(glyph);
            stack.Children.Add(label);
            var tile = new Border
            {
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(0, 8, 0, 8),
                BorderThickness = new Thickness(1),
                Cursor = Cursors.Hand,
                Child = stack,
                ToolTip = style.Caption(),
            };
            tile.MouseLeftButtonUp += (_, _) => _s.AnimationStyle = style;
            Grid.SetColumn(tile, i * 2);
            tiles.Children.Add(tile);
            _tiles[style] = (tile, glyph, label);
        }
        _styleCaption.Margin = new Thickness(0, 10, 0, 0);
        return Ui.Card(Ui.VStack(0, Ui.SectionTitle("Animation Style"), Gap(10, tiles), _styleCaption));
    }

    private FrameworkElement BuildDisplays()
    {
        var header = new DockPanel();
        DockPanel.SetDock(_displaySummary, Dock.Right);
        header.Children.Add(_displaySummary);
        header.Children.Add(Ui.SectionTitle("Displays"));
        _displayRows.Margin = new Thickness(0, 8, 0, 0);
        _disconnectedNote.Margin = new Thickness(0, 6, 0, 0);
        return Ui.Card(Ui.VStack(0, header, _displayRows, _disconnectedNote));
    }

    private FrameworkElement BuildSliders()
    {
        _thickness.ValueChanged += v => _s.Thickness = Math.Round(v);
        _spread.ValueChanged += v => _s.GlowSpread = Math.Round(v);
        _reactivity.ValueChanged += v => _s.Reactivity = v;
        _intensity.ValueChanged += v => _s.Intensity = v;
        _comet.ValueChanged += v => _s.CometLength = v;

        _cometRow.Children.Add(SliderRow("Comet Length", _comet, _cometValue));
        _cometRow.Margin = new Thickness(0, 10, 0, 0);
        return Ui.Card(Ui.VStack(0,
            Ui.SectionTitle("Glow"),
            Gap(10, SliderRow("Thickness", _thickness, _thicknessValue)),
            Gap(10, SliderRow("Glow Spill / Blur", _spread, _spreadValue)),
            Gap(10, SliderRow("Bass Reactivity", _reactivity, _reactivityValue)),
            Gap(10, SliderRow("Master Brightness", _intensity, _intensityValue)),
            _cometRow));
    }

    private static FrameworkElement SliderRow(string title, SliderControl slider, TextBlock value)
    {
        var head = new DockPanel();
        DockPanel.SetDock(value, Dock.Right);
        head.Children.Add(value);
        head.Children.Add(Ui.Text(title, 12));
        slider.Margin = new Thickness(0, 4, 0, 0);
        return Ui.VStack(0, head, slider);
    }

    private FrameworkElement BuildToggles()
    {
        _idleSwitch.Toggled += on => _s.IdleWhenPaused = on;
        _kineticSwitch.Toggled += on => _s.KineticEffects = on;
        _startupSwitch.Toggled += on => { LaunchAtStartup.IsEnabled = on; Refresh(); };

        return Ui.Card(Ui.VStack(0,
            ToggleRow("Keep Idle Glow When Paused", Ui.Text("Soft breathing glow when nothing is playing", 10, null, Ui.TextSecondary), _idleSwitch),
            Gap(10, ToggleRow("Kinetic Physics", _kineticCaption, _kineticSwitch)),
            Gap(10, ToggleRow("Launch at Startup", Ui.Text("Start EdgeGlow when you sign in to Windows", 10, null, Ui.TextSecondary), _startupSwitch))));
    }

    private static FrameworkElement ToggleRow(string title, TextBlock caption, SwitchControl toggle)
    {
        var dock = new DockPanel();
        toggle.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(toggle, Dock.Right);
        dock.Children.Add(toggle);
        var text = new StackPanel { Margin = new Thickness(0, 0, 8, 0) };
        text.Children.Add(Ui.Text(title, 12));
        caption.Margin = new Thickness(0, 1, 0, 0);
        text.Children.Add(caption);
        dock.Children.Add(text);
        return dock;
    }

    private FrameworkElement BuildFooter()
    {
        var dock = new DockPanel { Margin = new Thickness(2, 0, 2, 0) };
        var quit = Ui.Text("⏻  Quit EdgeGlow", 12, FontWeights.Medium, Ui.TextSecondary);
        quit.Cursor = Cursors.Hand;
        quit.MouseLeftButtonUp += (_, _) => _quit();
        DockPanel.SetDock(quit, Dock.Right);
        dock.Children.Add(quit);
        dock.Children.Add(_footerText);
        return dock;
    }

    // ---- Refresh ----

    private void ScheduleRefresh()
    {
        if (_refreshPending) return;
        _refreshPending = true;
        Dispatcher.BeginInvoke(new Action(() => { _refreshPending = false; if (IsVisible) Refresh(); }), DispatcherPriority.Background);
    }

    private void Refresh()
    {
        var s = _s;
        var primary = s.TargetPrimary;
        var secondary = s.TargetSecondary;

        // Header
        _glyph.Foreground = new LinearGradientBrush(ToWpf(primary), ToWpf(secondary), 45);
        var (statusColor, statusLabel) = s.Playback switch
        {
            PlaybackState.Playing => (Colors.LimeGreen, "Live"),
            PlaybackState.Paused => (Colors.Gold, "Paused"),
            _ => (Color.FromRgb(0x73, 0x73, 0x73), "Idle"),
        };
        _statusDot.Fill = new SolidColorBrush(statusColor);
        _statusDot.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 5, ShadowDepth = 0, Color = statusColor, Opacity = 0.8 };
        _statusText.Text = statusLabel;
        RefreshBadge(primary, secondary);

        // Now playing
        var hasTrack = s.Playback != PlaybackState.Stopped && s.TrackName.Length > 0;
        _title.Text = hasTrack ? s.TrackName : (s.MediaSource == MediaSource.SystemAudio ? "Listening to system audio" : "Nothing playing");
        _subtitle.Text = hasTrack
            ? (s.ArtistName.Length == 0 ? s.MediaSource?.DisplayName() ?? "" : s.ArtistName)
            : (s.MediaSource == MediaSource.SystemAudio ? "Any app's sound drives the glow" : "Play music in Spotify, Apple Music or any app");
        if (s.MediaSource is { } source)
        {
            _sourceLine.Text = $"{source.Glyph()} " + (s.LevelSource == LevelSource.CloudSync ? $"{source.DisplayName()} · Cloud Sync" : source.DisplayName());
            _sourceLine.Foreground = Ui.Brush(primary, 0.9);
            _sourceLine.Visibility = Visibility.Visible;
        }
        else
        {
            _sourceLine.Visibility = Visibility.Collapsed;
        }
        _artFallback.Background = new LinearGradientBrush(ToWpf(primary, 0.6), ToWpf(secondary, 0.6), 45);
        if (!ReferenceEquals(_shownArtwork, s.Artwork))
        {
            _shownArtwork = s.Artwork;
            _artImage.Source = DecodeArtwork(s.Artwork);
        }
        _art.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 0, Color = ToWpf(primary), Opacity = 0.35 };

        // Audio banner
        var failed = s.AudioStatus == AudioCaptureStatus.Failed;
        _audioBanner.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        _audioBannerText.Text = $"EdgeGlow can't capture system audio ({s.AudioError}). Check your default playback device; it will retry automatically.";

        // Colors
        SetPill(_primaryPill, _primaryDot, _primaryHex, primary);
        SetPill(_secondaryPill, _secondaryDot, _secondaryHex, secondary);
        _overrideSwitch.Set(s.UseCustomColors, primary);
        _customRow.Visibility = s.UseCustomColors ? Visibility.Visible : Visibility.Collapsed;
        _customPrimaryButton.Background = Ui.Brush(s.CustomPrimary);
        _customPrimaryButton.BorderBrush = Ui.Brush(s.CustomPrimary.Lerp(RgbColor.White, 0.35));
        _customSecondaryButton.Background = Ui.Brush(s.CustomSecondary);
        _customSecondaryButton.BorderBrush = Ui.Brush(s.CustomSecondary.Lerp(RgbColor.White, 0.35));

        // Style tiles
        foreach (var (style, parts) in _tiles)
        {
            var selected = s.AnimationStyle == style;
            parts.Tile.Background = selected ? Ui.Brush(primary, 0.16) : new SolidColorBrush(Color.FromArgb(0x0A, 255, 255, 255));
            parts.Tile.BorderBrush = selected ? Ui.Brush(primary, 0.55) : new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255));
            parts.Glyph.Foreground = selected ? Ui.TextPrimary : Ui.TextSecondary;
            parts.Label.Foreground = selected ? Ui.TextPrimary : Ui.TextSecondary;
        }
        _styleCaption.Text = s.AnimationStyle.Caption();

        // Mode + lyrics
        foreach (var (mode, parts) in _modeTiles) StyleChip(parts.Tile, parts.Label, s.DisplayMode == mode, primary);
        foreach (var (style, parts) in _lyricStyleTiles) StyleChip(parts.Tile, parts.Label, s.LyricStyle == style, primary);
        foreach (var (font, parts) in _fontTiles) StyleChip(parts.Tile, parts.Label, s.LyricFont == font, primary);
        _syncPill.Text = s.AudioRoute.Pill;
        _syncPillBorder.Background = Ui.Brush(primary, 0.10);
        _syncPillBorder.BorderBrush = Ui.Brush(primary, 0.35);
        SetSlider(_lyricScale, s.LyricTextScale, primary); _lyricScaleValue.Text = $"{(int)Math.Round(s.LyricTextScale * 100)}%";
        SetSlider(_lyricVertical, s.LyricVerticalPosition, primary); _lyricVerticalValue.Text = $"{(int)Math.Round(s.LyricVerticalPosition * 100)}%";
        _romanizeSwitch.Set(s.RomanizeLyrics, primary);
        _lyricsStatusText.Text = s.LyricsStatus;

        RefreshDisplays(primary);

        // Sliders (never fight an in-progress drag)
        SetSlider(_thickness, s.Thickness, primary); _thicknessValue.Text = $"{(int)s.Thickness}pt";
        SetSlider(_spread, s.GlowSpread, primary); _spreadValue.Text = $"{(int)s.GlowSpread}pt";
        SetSlider(_reactivity, s.Reactivity, primary); _reactivityValue.Text = $"{(int)Math.Round(s.Reactivity * 100)}%";
        SetSlider(_intensity, s.Intensity, primary); _intensityValue.Text = $"{(int)Math.Round(s.Intensity * 100)}%";
        SetSlider(_comet, s.CometLength, primary); _cometValue.Text = $"{(int)Math.Round(s.CometLength * 100)}%";
        _cometRow.Visibility = s.AnimationStyle.UsesComets() ? Visibility.Visible : Visibility.Collapsed;

        // Toggles
        _idleSwitch.Set(s.IdleWhenPaused, primary);
        var sparksOnly = s.AnimationStyle == AnimationStyle.SparksOnly;
        _kineticSwitch.IsEnabled = !sparksOnly;
        _kineticSwitch.Set(s.KineticEffects || sparksOnly, primary);
        _kineticCaption.Text = sparksOnly ? "Always on in Sparks Only" : "Edge bounce, sparks and impact flashes on the bass";
        _startupSwitch.Set(LaunchAtStartup.IsEnabled, primary);

        // Footer
        var sourceName = s.MediaSource?.DisplayName() ?? "Album colors";
        _footerText.Text = s.LevelSource switch
        {
            LevelSource.CloudSync => $"{sourceName} · cloud sync",
            LevelSource.Live => $"{sourceName} · live audio",
            _ => sourceName,
        };
    }

    private static Color ToWpf(RgbColor c, double alpha = 1) => Ui.ToColor(c, alpha);

    private static void SetPill(Border pill, Ellipse dot, TextBlock hex, RgbColor c)
    {
        dot.Fill = Ui.Brush(c);
        dot.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 6, ShadowDepth = 0, Color = ToWpf(c), Opacity = 0.9 };
        pill.Background = Ui.Brush(c, 0.12);
        pill.BorderBrush = Ui.Brush(c, 0.35);
        hex.Text = c.Hex;
    }

    private static void SetSlider(SliderControl slider, double value, RgbColor accent)
    {
        slider.SetAccent(accent);
        if (!slider.IsDragging) slider.Value = value;
    }

    private static BitmapSource? DecodeArtwork(byte[]? bytes)
    {
        if (bytes == null) return null;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.DecodePixelWidth = 108;
            image.StreamSource = new MemoryStream(bytes);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Bass/vocal meter while levels are flowing (LIVE from the system audio FFT, SYNC from Cloud Sync), otherwise the capture status.</summary>
    private void RefreshBadge(RgbColor primary, RgbColor secondary)
    {
        var meters = false;
        string label;
        string tip;
        if (_s.LevelSource == LevelSource.CloudSync)
        {
            meters = true; label = "SYNC";
            tip = "The music is playing on another device, so the glow follows the track's tempo and synced lyrics";
        }
        else
        {
            switch (_s.AudioStatus)
            {
                case AudioCaptureStatus.Live:
                    meters = true; label = "LIVE";
                    tip = "Bass (20–150 Hz) and vocals (300–3000 Hz) from system audio";
                    break;
                case AudioCaptureStatus.Starting:
                    label = "Starting…"; tip = "Starting audio capture"; break;
                case AudioCaptureStatus.Failed:
                    label = "⚠ Audio Error"; tip = _s.AudioError; break;
                default:
                    label = "Audio Off"; tip = "System audio capture runs while the glow is on for at least one display"; break;
            }
        }
        _badgeText.Text = label;
        _badge.ToolTip = tip;
        _bassHost.Visibility = _vocalHost.Visibility = meters ? Visibility.Visible : Visibility.Collapsed;
        _badgeText.Margin = new Thickness(meters ? 4 : 0, 0, 0, 0);
        _bassBar.Background = Ui.Brush(primary);
        _vocalBar.Background = Ui.Brush(secondary);
    }

    private void UpdateMeters()
    {
        if (_bassHost.Visibility != Visibility.Visible) return;
        var levels = _s.AudioLevels.Snapshot();
        _bassBar.Height = Math.Max(2, 12 * Math.Clamp(levels.Bass, 0, 1));
        _vocalBar.Height = Math.Max(2, 12 * Math.Clamp(levels.Vocal, 0, 1));
    }

    private void RefreshDisplays(RgbColor accent)
    {
        var s = _s;
        var active = s.ActiveDisplays;
        var signature = string.Join("|", s.AvailableDisplays.Select(d => $"{d.Id}:{d.Name}:{active.Contains(d.Id)}")) + $"#{accent.Hex}";
        var connected = s.AvailableDisplays.Select(d => d.Id).ToHashSet();
        var onCount = s.AvailableDisplays.Count(d => active.Contains(d.Id));
        var total = s.AvailableDisplays.Count;
        _displaySummary.Text = onCount == 0 ? "Glow hidden" : onCount == total ? (total == 1 ? "On" : $"All {total} on") : $"{onCount} of {total} on";
        var disconnected = active.Count(id => !connected.Contains(id));
        _disconnectedNote.Visibility = disconnected > 0 ? Visibility.Visible : Visibility.Collapsed;
        _disconnectedNote.Text = disconnected == 1
            ? "1 enabled display is disconnected. Its glow comes back when you plug it in."
            : $"{disconnected} enabled displays are disconnected. Their glow comes back when you plug them in.";

        if (signature == _displaySignature) return;
        _displaySignature = signature;
        _displayRows.Children.Clear();
        foreach (var display in s.AvailableDisplays)
        {
            var enabled = active.Contains(display.Id);
            var check = Ui.Text(enabled ? "●" : "○", 14, null, enabled ? Ui.Brush(accent) : new SolidColorBrush(Color.FromArgb(0x40, 255, 255, 255)));
            var icon = Ui.Text(display.IsBuiltIn ? "▭" : "▣", 12, null, enabled ? Ui.TextPrimary : Ui.TextSecondary);
            icon.Width = 18;
            var name = Ui.Text(display.Name, 12, null, enabled ? Ui.TextPrimary : Ui.TextSecondary);
            var row = new DockPanel();
            DockPanel.SetDock(icon, Dock.Left);
            DockPanel.SetDock(check, Dock.Right);
            row.Children.Add(icon);
            row.Children.Add(check);
            row.Children.Add(name);
            var id = display.Id;
            var button = new Border
            {
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(8, 6, 8, 6),
                Background = enabled ? Ui.Brush(accent, 0.10) : Brushes.Transparent,
                Cursor = Cursors.Hand,
                Child = row,
                Margin = new Thickness(0, 2, 0, 0),
            };
            button.MouseLeftButtonUp += (_, _) => _s.ToggleDisplay(id);
            _displayRows.Children.Add(button);
        }
    }
}
