using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using EdgeGlow.Lyrics;

namespace EdgeGlow;

/// <summary>
/// Minimal dark control flyout shown from the tray icon (the Windows counterpart of MenuBarPopoverView): a mode bar,
/// only the controls the mode needs, and a one-line footer. No headers, captions or helper text.
/// Controls are built once and refreshed in place, so dragging a slider is never interrupted.
/// </summary>
public sealed class FlyoutWindow : Window
{
    private static readonly FontFamily SymbolFont = new("Segoe UI Symbol, Segoe UI Emoji, Segoe UI");

    private readonly AppState _s;
    private readonly Action _quit;
    private bool _refreshPending;
    private bool _suppressHide;
    private int _openDropdowns;
    private DateTime _hiddenAt = DateTime.MinValue;

    // Mode
    private readonly Dictionary<DisplayMode, (Border Tile, TextBlock Label)> _modeTiles = new();

    // Banner
    private readonly Border _audioBanner = new();

    // Glow
    private readonly StackPanel _glowPanel = new();
    private Border _glowCard = null!, _lyricsCard = null!;
    private readonly Dictionary<AnimationStyle, (Border Tile, TextBlock Glyph)> _tiles = new();
    private readonly Ellipse _primaryDot = new() { Width = 18, Height = 18 }, _secondaryDot = new() { Width = 18, Height = 18 };
    private readonly Border _customPrimaryButton = new(), _customSecondaryButton = new();
    private readonly StackPanel _autoColors = new() { Orientation = Orientation.Horizontal }, _customColors = new() { Orientation = Orientation.Horizontal };
    private readonly PillControl _overridePill = new("🎨", "Custom colors"), _kineticPill = new("✧", "Kinetic physics");
    private readonly SliderControl _intensity = new(0.1, 1.0), _reactivity = new(0, 1.5), _thickness = new(10, 120), _spread = new(15, 90), _comet = new(0.05, 0.45);
    private readonly Grid _cometRow = new();

    // Lyrics
    private readonly StackPanel _lyricsPanel = new();
    private readonly DropdownControl _styleDropdown = new(Enum.GetValues<LyricStyle>().Select(x => x.Title()).ToList());
    private readonly DropdownControl _fontDropdown = new(Enum.GetValues<LyricFont>().Select(x => x.Title()).ToList());
    private readonly SliderControl _lyricScale = new(0.6, 1.8), _lyricVertical = new(0, 1);
    private readonly PillControl _romanizePill = new("Romanize");

    // Displays
    private readonly StackPanel _displayRow = new() { Orientation = Orientation.Horizontal };
    private string _displaySignature = "";

    // Footer
    private readonly Border _latencyBadge = new();
    private readonly TextBlock _latencyText = Ui.Text("", 11, FontWeights.Medium, Ui.TextSecondary);
    private readonly TextBlock _updateText = Ui.Text("Update", 12, FontWeights.Medium, Ui.TextSecondary);
    private bool _updating;

    private readonly StackPanel _controls = new();
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
        Width = 320;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(1),
            BorderBrush = Ui.CardBorder,
            Background = new LinearGradientBrush(Color.FromRgb(0x1C, 0x1C, 0x1F), Color.FromRgb(0x12, 0x12, 0x14), 90),
            Padding = new Thickness(14),
            Child = BuildContent(),
        };

        state.Changed += ScheduleRefresh;
        Deactivated += (_, _) =>
        {
            if (_suppressHide || _openDropdowns > 0) return;
            HideFlyout();
        };
        KeyDown += (_, e) => { if (e.Key == Key.Escape) HideFlyout(); };
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
    }

    public void HideFlyout()
    {
        if (!IsVisible) return;
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
        _scroll.MaxHeight = Math.Max(180, wa.Height / dpi - 150);
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

    private static FrameworkElement Gap(double top, FrameworkElement e)
    {
        e.Margin = new Thickness(0, top, 0, 0);
        return e;
    }

    private FrameworkElement BuildContent()
    {
        var root = new StackPanel();
        root.Children.Add(BuildModes());
        root.Children.Add(Gap(10, BuildAudioBanner()));

        _controls.Children.Add(BuildGlow());
        _controls.Children.Add(Gap(10, BuildLyrics()));
        _controls.Children.Add(Gap(10, BuildDisplays()));
        _scroll.Content = _controls;
        root.Children.Add(Gap(10, _scroll));
        root.Children.Add(Gap(12, BuildFooter()));
        return root;
    }

    /// <summary>Both / Glow / Lyrics / Off, with no header. Off tears down overlays and pauses audio capture and media polling.</summary>
    private FrameworkElement BuildModes()
    {
        var grid = new UniformGrid { Columns = 4 };
        foreach (var mode in Enum.GetValues<DisplayMode>())
        {
            var m = mode;
            var label = Ui.Text(m.Title(), 12, FontWeights.Medium);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            var tile = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(0, 6, 0, 6), BorderThickness = new Thickness(1), Cursor = Cursors.Hand, Child = label, Margin = new Thickness(2) };
            tile.MouseLeftButtonUp += (_, _) => _s.DisplayMode = m;
            grid.Children.Add(tile);
            _modeTiles[m] = (tile, label);
        }
        return new Border { CornerRadius = new CornerRadius(11), Padding = new Thickness(1), Background = new SolidColorBrush(Color.FromArgb(0x0F, 255, 255, 255)), Child = grid };
    }

    private FrameworkElement BuildAudioBanner()
    {
        _audioBanner.CornerRadius = new CornerRadius(10);
        _audioBanner.Padding = new Thickness(10, 6, 10, 6);
        _audioBanner.Background = Ui.CardFill;
        _audioBanner.BorderBrush = Ui.CardBorder;
        _audioBanner.BorderThickness = new Thickness(1);
        _audioBanner.Cursor = Cursors.Hand;
        _audioBanner.Child = Ui.Text("⚠ Audio", 11, FontWeights.Medium, Brushes.Gold);
        _audioBanner.MouseLeftButtonUp += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:sound") { UseShellExecute = true });
        return _audioBanner;
    }

    private static TextBlock Glyph(string glyph, double size = 13)
    {
        var t = Ui.Text(glyph, size, null, Ui.TextSecondary);
        t.FontFamily = SymbolFont;
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.VerticalAlignment = VerticalAlignment.Center;
        return t;
    }

    /// <summary>Leading glyph + slider on one row: no text label.</summary>
    private static FrameworkElement IconSlider(string glyph, SliderControl slider)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        var g = Glyph(glyph);
        row.Children.Add(g);
        Grid.SetColumn(slider, 1);
        row.Children.Add(slider);
        return row;
    }

    private FrameworkElement BuildGlow()
    {
        var tiles = new Grid();
        var styles = Enum.GetValues<AnimationStyle>();
        for (var i = 0; i < styles.Length; i++)
        {
            if (i > 0) tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
            tiles.ColumnDefinitions.Add(new ColumnDefinition());
            var style = styles[i];
            var glyph = Glyph(style.Glyph(), 15);
            var tile = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(0, 9, 0, 9), BorderThickness = new Thickness(1), Cursor = Cursors.Hand, Child = glyph, ToolTip = style.Title() };
            tile.MouseLeftButtonUp += (_, _) => _s.AnimationStyle = style;
            Grid.SetColumn(tile, i * 2);
            tiles.Children.Add(tile);
            _tiles[style] = (tile, glyph);
        }

        // Colors: the two live colors as dots, or two pickers when overridden.
        _autoColors.Children.Add(Dot(_primaryDot));
        _autoColors.Children.Add(Dot(_secondaryDot));
        foreach (var b in new[] { _customPrimaryButton, _customSecondaryButton })
        {
            b.Width = 22; b.Height = 22; b.CornerRadius = new CornerRadius(11);
            b.Margin = new Thickness(0, 0, 8, 0); b.Cursor = Cursors.Hand; b.BorderThickness = new Thickness(2);
            _customColors.Children.Add(b);
        }
        _customPrimaryButton.MouseLeftButtonUp += (_, _) => PickColor(_s.CustomPrimary, c => _s.CustomPrimary = c);
        _customSecondaryButton.MouseLeftButtonUp += (_, _) => PickColor(_s.CustomSecondary, c => _s.CustomSecondary = c);
        _overridePill.Toggled += on => _s.UseCustomColors = on;
        _overridePill.Margin = new Thickness(0);
        var colorRow = new DockPanel();
        DockPanel.SetDock(_overridePill, Dock.Right);
        colorRow.Children.Add(_overridePill);
        colorRow.Children.Add(_autoColors);
        colorRow.Children.Add(_customColors);

        _intensity.ValueChanged += v => _s.Intensity = v;
        _reactivity.ValueChanged += v => _s.Reactivity = v;
        _thickness.ValueChanged += v => _s.Thickness = Math.Round(v);
        _spread.ValueChanged += v => _s.GlowSpread = Math.Round(v);
        _comet.ValueChanged += v => _s.CometLength = v;
        _kineticPill.Toggled += on => _s.KineticEffects = on;

        _cometRow.Children.Add(IconSlider("⏱", _comet));
        _cometRow.Margin = new Thickness(0, 10, 0, 0);

        _glowPanel.Children.Add(tiles);
        _glowPanel.Children.Add(Gap(12, colorRow));
        _glowPanel.Children.Add(Gap(10, IconSlider("☀", _intensity)));
        _glowPanel.Children.Add(Gap(10, IconSlider("⚡", _reactivity)));
        _glowPanel.Children.Add(Gap(10, IconSlider("↔", _thickness)));
        _glowPanel.Children.Add(Gap(10, IconSlider("◌", _spread)));
        _glowPanel.Children.Add(_cometRow);
        _glowPanel.Children.Add(Gap(12, new StackPanel { Orientation = Orientation.Horizontal, Children = { _kineticPill } }));
        return _glowCard = Ui.Card(_glowPanel);
    }

    private static FrameworkElement Dot(Ellipse dot)
    {
        dot.Margin = new Thickness(0, 0, 8, 0);
        dot.Stroke = new SolidColorBrush(Color.FromArgb(0x33, 255, 255, 255));
        dot.StrokeThickness = 0.5;
        return dot;
    }

    private FrameworkElement BuildLyrics()
    {
        var dropdowns = new Grid();
        dropdowns.ColumnDefinitions.Add(new ColumnDefinition());
        dropdowns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        dropdowns.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(_fontDropdown, 2);
        dropdowns.Children.Add(_styleDropdown);
        dropdowns.Children.Add(_fontDropdown);

        var fonts = Enum.GetValues<LyricFont>();
        var styles = Enum.GetValues<LyricStyle>();
        _styleDropdown.Selected += i => _s.LyricStyle = styles[i];
        _fontDropdown.Selected += i => _s.LyricFont = fonts[i];
        _styleDropdown.OpenChanged += OnDropdownOpenChanged;
        _fontDropdown.OpenChanged += OnDropdownOpenChanged;
        _lyricScale.ValueChanged += v => _s.LyricTextScale = v;
        _lyricVertical.ValueChanged += v => _s.LyricVerticalPosition = v;
        _romanizePill.Toggled += on => _s.RomanizeLyrics = on;

        // Text size: small A, slider, large A.
        var size = new Grid();
        size.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        size.ColumnDefinitions.Add(new ColumnDefinition());
        size.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        var small = Ui.Text("A", 10, FontWeights.SemiBold, Ui.TextSecondary); small.HorizontalAlignment = HorizontalAlignment.Center; small.VerticalAlignment = VerticalAlignment.Center;
        var large = Ui.Text("A", 17, FontWeights.SemiBold, Ui.TextSecondary); large.HorizontalAlignment = HorizontalAlignment.Center; large.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(_lyricScale, 1);
        Grid.SetColumn(large, 2);
        size.Children.Add(small);
        size.Children.Add(_lyricScale);
        size.Children.Add(large);

        _lyricsPanel.Children.Add(dropdowns);
        _lyricsPanel.Children.Add(Gap(12, size));
        _lyricsPanel.Children.Add(Gap(10, IconSlider("↕", _lyricVertical)));
        _lyricsPanel.Children.Add(Gap(12, new StackPanel { Orientation = Orientation.Horizontal, Children = { _romanizePill } }));
        return _lyricsCard = Ui.Card(_lyricsPanel);
    }

    private void OnDropdownOpenChanged(bool open)
    {
        _openDropdowns = Math.Max(0, _openDropdowns + (open ? 1 : -1));
        // Clicking away while the list was open also deactivated the flyout; honor that once the list has closed.
        if (!open) Dispatcher.BeginInvoke(new Action(() => { if (_openDropdowns == 0 && !IsActive) HideFlyout(); }), DispatcherPriority.Background);
    }

    private FrameworkElement BuildDisplays() => _displayRow;

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

    private FrameworkElement BuildFooter()
    {
        _latencyBadge.CornerRadius = new CornerRadius(10);
        _latencyBadge.Padding = new Thickness(8, 3, 8, 3);
        _latencyBadge.Background = new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255));
        _latencyBadge.Child = _latencyText;
        _latencyBadge.VerticalAlignment = VerticalAlignment.Center;

        _updateText.Cursor = Cursors.Hand;
        _updateText.MouseLeftButtonUp += (_, _) => CheckForUpdate();
        var quit = Ui.Text("Quit", 12, FontWeights.Medium, Ui.TextSecondary);
        quit.Cursor = Cursors.Hand;
        quit.MouseLeftButtonUp += (_, _) => _quit();
        quit.Margin = new Thickness(14, 0, 0, 0);

        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(_updateText);
        right.Children.Add(quit);
        var dock = new DockPanel { Margin = new Thickness(2, 0, 2, 0) };
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);
        dock.Children.Add(_latencyBadge);
        return dock;
    }

    private async void CheckForUpdate()
    {
        if (_updating) return;
        _updating = true;
        _updateText.Text = "…";
        void Show(string message)
        {
            Dispatcher.BeginInvoke(new Action(async () =>
            {
                _updateText.Text = message.Length > 22 ? message[..22] + "…" : message;
                await System.Threading.Tasks.Task.Delay(3000);
                _updateText.Text = "Update";
            }));
        }
        try { await Updater.CheckAsync(true, Show, _quit); }
        catch { Show("Failed"); }
        finally { _updating = false; if (_updateText.Text == "…") _updateText.Text = "Update"; }
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
        var glowOn = s.DisplayMode.GlowOn();
        var lyricsOn = s.DisplayMode.LyricsOn();
        var off = s.DisplayMode == DisplayMode.Off;

        // Mode bar + contextual sections: nothing below it shows in Off.
        foreach (var (mode, parts) in _modeTiles) StyleChip(parts.Tile, parts.Label, s.DisplayMode == mode, primary);
        _scroll.Visibility = off ? Visibility.Collapsed : Visibility.Visible;
        _glowCard.Visibility = glowOn ? Visibility.Visible : Visibility.Collapsed;
        _lyricsCard.Visibility = lyricsOn ? Visibility.Visible : Visibility.Collapsed;
        _latencyBadge.Visibility = off ? Visibility.Collapsed : Visibility.Visible;

        _audioBanner.Visibility = s.AudioStatus == AudioCaptureStatus.Failed ? Visibility.Visible : Visibility.Collapsed;

        // Glow
        foreach (var (style, parts) in _tiles)
        {
            var selected = s.AnimationStyle == style;
            parts.Tile.Background = selected ? Ui.Brush(primary, 0.16) : new SolidColorBrush(Color.FromArgb(0x0A, 255, 255, 255));
            parts.Tile.BorderBrush = selected ? Ui.Brush(primary, 0.55) : new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255));
            parts.Glyph.Foreground = selected ? Ui.TextPrimary : Ui.TextSecondary;
        }
        SetDot(_primaryDot, primary);
        SetDot(_secondaryDot, secondary);
        _overridePill.Set(s.UseCustomColors, primary);
        _autoColors.Visibility = s.UseCustomColors ? Visibility.Collapsed : Visibility.Visible;
        _customColors.Visibility = s.UseCustomColors ? Visibility.Visible : Visibility.Collapsed;
        _customPrimaryButton.Background = Ui.Brush(s.CustomPrimary);
        _customPrimaryButton.BorderBrush = Ui.Brush(s.CustomPrimary.Lerp(RgbColor.White, 0.35));
        _customSecondaryButton.Background = Ui.Brush(s.CustomSecondary);
        _customSecondaryButton.BorderBrush = Ui.Brush(s.CustomSecondary.Lerp(RgbColor.White, 0.35));
        SetSlider(_intensity, s.Intensity, primary);
        SetSlider(_reactivity, s.Reactivity, primary);
        SetSlider(_thickness, s.Thickness, primary);
        SetSlider(_spread, s.GlowSpread, primary);
        SetSlider(_comet, s.CometLength, primary);
        _cometRow.Visibility = s.AnimationStyle.UsesComets() ? Visibility.Visible : Visibility.Collapsed;
        var sparksOnly = s.AnimationStyle == AnimationStyle.SparksOnly;
        _kineticPill.IsEnabled = !sparksOnly;
        _kineticPill.Set(s.KineticEffects || sparksOnly, primary);

        // Lyrics
        _styleDropdown.Set(Array.IndexOf(Enum.GetValues<LyricStyle>(), s.LyricStyle), primary);
        _fontDropdown.Set(Array.IndexOf(Enum.GetValues<LyricFont>(), s.LyricFont), primary);
        SetSlider(_lyricScale, s.LyricTextScale, primary);
        SetSlider(_lyricVertical, s.LyricVerticalPosition, primary);
        _romanizePill.Set(s.RomanizeLyrics, primary);

        RefreshDisplays(primary);

        // Footer: output latency, headphones for Bluetooth, speaker otherwise.
        _latencyText.Text = $"{(s.AudioRoute.IsBluetooth ? "🎧" : "🔊")} -{(int)Math.Round(s.AudioRoute.LatencyMs)}ms";
    }

    private static void StyleChip(Border chip, TextBlock label, bool selected, RgbColor accent)
    {
        chip.Background = selected ? Ui.Brush(accent, 0.22) : Brushes.Transparent;
        chip.BorderBrush = selected ? Ui.Brush(accent, 0.6) : Brushes.Transparent;
        label.Foreground = selected ? Ui.TextPrimary : Ui.TextSecondary;
    }

    private static Color ToWpf(RgbColor c, double alpha = 1) => Ui.ToColor(c, alpha);

    private static void SetDot(Ellipse dot, RgbColor c)
    {
        dot.Fill = Ui.Brush(c);
        dot.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 6, ShadowDepth = 0, Color = ToWpf(c), Opacity = 0.8 };
    }

    private static void SetSlider(SliderControl slider, double value, RgbColor accent)
    {
        slider.SetAccent(accent);
        if (!slider.IsDragging) slider.Value = value;
    }

    /// <summary>One icon chip per display, shown only when there is more than one.</summary>
    private void RefreshDisplays(RgbColor accent)
    {
        var s = _s;
        var active = s.ActiveDisplays;
        _displayRow.Visibility = s.AvailableDisplays.Count > 1 && s.DisplayMode != DisplayMode.Off ? Visibility.Visible : Visibility.Collapsed;
        var signature = string.Join("|", s.AvailableDisplays.Select(d => $"{d.Id}:{d.Name}:{active.Contains(d.Id)}")) + $"#{accent.Hex}";
        if (signature == _displaySignature) return;
        _displaySignature = signature;
        _displayRow.Children.Clear();
        foreach (var display in s.AvailableDisplays)
        {
            var enabled = active.Contains(display.Id);
            var icon = Glyph(display.IsBuiltIn ? "▭" : "▣", 14);
            icon.Foreground = enabled ? Ui.TextPrimary : Ui.TextSecondary;
            var id = display.Id;
            var chip = new Border
            {
                CornerRadius = new CornerRadius(9), Padding = new Thickness(14, 7, 14, 7), BorderThickness = new Thickness(1), Cursor = Cursors.Hand,
                Child = icon, ToolTip = display.Name, Margin = new Thickness(0, 0, 6, 0),
                Background = enabled ? Ui.Brush(accent, 0.16) : new SolidColorBrush(Color.FromArgb(0x0A, 255, 255, 255)),
                BorderBrush = enabled ? Ui.Brush(accent, 0.55) : new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255)),
            };
            chip.MouseLeftButtonUp += (_, _) => _s.ToggleDisplay(id);
            _displayRow.Children.Add(chip);
        }
    }
}
