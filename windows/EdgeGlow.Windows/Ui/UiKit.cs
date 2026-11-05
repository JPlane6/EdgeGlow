using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace EdgeGlow;

/// <summary>Small dark-theme building blocks for the flyout (the Windows counterpart of the SwiftUI popover pieces).</summary>
internal static class Ui
{
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
    public static readonly Brush TextPrimary = Frozen(new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF4)));
    public static readonly Brush TextSecondary = Frozen(new SolidColorBrush(Color.FromRgb(0xA0, 0xA0, 0xA8)));
    public static readonly Brush TextTertiary = Frozen(new SolidColorBrush(Color.FromRgb(0x6C, 0x6C, 0x74)));
    public static readonly Brush CardFill = Frozen(new SolidColorBrush(Color.FromArgb(0x0D, 255, 255, 255)));
    public static readonly Brush CardBorder = Frozen(new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255)));
    public static readonly Brush TrackFill = Frozen(new SolidColorBrush(Color.FromArgb(0x2A, 255, 255, 255)));
    public static readonly Brush Clear = Brushes.Transparent;

    private static T Frozen<T>(T freezable) where T : Freezable
    {
        freezable.Freeze();
        return freezable;
    }

    public static Color ToColor(RgbColor c, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), RgbColor.ToByte(c.R), RgbColor.ToByte(c.G), RgbColor.ToByte(c.B));

    public static SolidColorBrush Brush(RgbColor c, double alpha = 1) => new(ToColor(c, alpha));

    public static TextBlock Text(string text, double size, FontWeight? weight = null, Brush? foreground = null, bool wrap = false) => new()
    {
        Text = text,
        FontFamily = Font,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        Foreground = foreground ?? TextPrimary,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    public static Border Card(UIElement child) => new()
    {
        Child = child,
        Padding = new Thickness(12),
        CornerRadius = new CornerRadius(12),
        Background = CardFill,
        BorderBrush = CardBorder,
        BorderThickness = new Thickness(1),
    };

    public static TextBlock SectionTitle(string text)
    {
        var t = Text(text.ToUpperInvariant(), 10, FontWeights.SemiBold, TextSecondary);
        return t;
    }

    public static StackPanel VStack(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Vertical };
        for (var i = 0; i < children.Length; i++)
        {
            if (children[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(fe.Margin.Left, fe.Margin.Top + spacing, fe.Margin.Right, fe.Margin.Bottom);
            panel.Children.Add(children[i]);
        }
        return panel;
    }
}

/// <summary>A pill switch matching the macOS toggle style.</summary>
internal sealed class SwitchControl : Border
{
    private readonly Ellipse _thumb = new() { Width = 14, Height = 14, Fill = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    public bool IsOn { get; private set; }
    public event Action<bool>? Toggled;

    public SwitchControl()
    {
        Width = 36;
        Height = 20;
        CornerRadius = new CornerRadius(10);
        Cursor = Cursors.Hand;
        Background = Ui.TrackFill;
        Child = _thumb;
        MouseLeftButtonUp += (_, _) =>
        {
            if (!IsEnabled) return;
            Toggled?.Invoke(!IsOn);
        };
    }

    public void Set(bool on, RgbColor accent)
    {
        IsOn = on;
        Background = on ? Ui.Brush(accent, 0.95) : Ui.TrackFill;
        _thumb.HorizontalAlignment = on ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        _thumb.Margin = new Thickness(3, 0, 3, 0);
        Opacity = IsEnabled ? 1 : 0.45;
    }
}

/// <summary>A thin custom slider (track, accent fill, round thumb) that stays dark under any Windows theme.</summary>
internal sealed class SliderControl : Grid
{
    private readonly Border _track = new() { Height = 4, CornerRadius = new CornerRadius(2), Background = Ui.TrackFill, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border _fill = new() { Height = 4, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    private readonly Ellipse _thumb = new() { Width = 14, Height = 14, Fill = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    private readonly double _min, _max;
    private double _value;

    public bool IsDragging { get; private set; }
    public event Action<double>? ValueChanged;

    public SliderControl(double min, double max)
    {
        _min = min;
        _max = max;
        Height = 18;
        Background = Brushes.Transparent; // hit-testable
        Cursor = Cursors.Hand;
        Children.Add(_track);
        Children.Add(_fill);
        Children.Add(_thumb);
        SizeChanged += (_, _) => Layout();
        MouseLeftButtonDown += (_, e) => { IsDragging = true; CaptureMouse(); Drag(e); };
        MouseMove += (_, e) => { if (IsDragging) Drag(e); };
        MouseLeftButtonUp += (_, _) => { IsDragging = false; ReleaseMouseCapture(); };
    }

    public double Value
    {
        get => _value;
        set { _value = Math.Clamp(value, _min, _max); Layout(); }
    }

    public void SetAccent(RgbColor accent) => _fill.Background = Ui.Brush(accent, 0.95);

    private void Drag(MouseEventArgs e)
    {
        var usable = Math.Max(ActualWidth - 14, 1);
        var ratio = Math.Clamp((e.GetPosition(this).X - 7) / usable, 0, 1);
        var v = _min + ratio * (_max - _min);
        _value = v;
        Layout();
        ValueChanged?.Invoke(v);
    }

    private void Layout()
    {
        var usable = Math.Max(ActualWidth - 14, 0);
        var ratio = _max > _min ? (_value - _min) / (_max - _min) : 0;
        var x = usable * ratio;
        _thumb.Margin = new Thickness(x, 0, 0, 0);
        _fill.Width = x + 7;
    }
}

/// <summary>A compact toggle pill (text or glyph) that lights up with the accent color when on.</summary>
internal sealed class PillControl : Border
{
    private readonly TextBlock _label;
    public bool IsOn { get; private set; }
    public event Action<bool>? Toggled;

    public PillControl(string label, string? tooltip = null)
    {
        _label = Ui.Text(label, 11, FontWeights.Medium, Ui.TextSecondary);
        _label.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI, Segoe UI Symbol");
        CornerRadius = new CornerRadius(12);
        Padding = new Thickness(12, 4, 12, 4);
        BorderThickness = new Thickness(1);
        Cursor = Cursors.Hand;
        ToolTip = tooltip;
        Child = _label;
        Margin = new Thickness(0, 0, 6, 0);
        MouseLeftButtonUp += (_, _) => { if (IsEnabled) Toggled?.Invoke(!IsOn); };
    }

    public void Set(bool on, RgbColor accent)
    {
        IsOn = on;
        Background = on ? Ui.Brush(accent, 0.2) : new SolidColorBrush(Color.FromArgb(0x0D, 255, 255, 255));
        BorderBrush = on ? Ui.Brush(accent, 0.55) : new SolidColorBrush(Color.FromArgb(0x1A, 255, 255, 255));
        _label.Foreground = on ? Ui.TextPrimary : Ui.TextSecondary;
        Opacity = IsEnabled ? 1 : 0.45;
    }
}

/// <summary>A dark, label-less dropdown: the current value with a caret, opening a popup list.</summary>
internal sealed class DropdownControl : Border
{
    private readonly TextBlock _value = Ui.Text("", 11.5, FontWeights.Medium);
    private readonly Popup _popup;
    private readonly StackPanel _list = new();
    private readonly List<(Border Row, TextBlock Text)> _rows = new();
    private int _selected = -1;
    private RgbColor _accent = RgbColor.NeonCyan;

    public event Action<int>? Selected;
    public event Action<bool>? OpenChanged;

    public DropdownControl(IReadOnlyList<string> items)
    {
        CornerRadius = new CornerRadius(8);
        Padding = new Thickness(10, 6, 8, 6);
        BorderThickness = new Thickness(1);
        Background = new SolidColorBrush(Color.FromArgb(0x0F, 255, 255, 255));
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 255, 255, 255));
        Cursor = Cursors.Hand;

        var caret = Ui.Text("▾", 10, null, Ui.TextSecondary);
        caret.Margin = new Thickness(6, 0, 0, 0);
        caret.VerticalAlignment = VerticalAlignment.Center;
        var dock = new DockPanel();
        DockPanel.SetDock(caret, Dock.Right);
        dock.Children.Add(caret);
        dock.Children.Add(_value);
        Child = dock;

        for (var i = 0; i < items.Count; i++)
        {
            var index = i;
            var text = Ui.Text(items[i], 12);
            var row = new Border { Padding = new Thickness(10, 6, 10, 6), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand, Child = text };
            row.MouseEnter += (_, _) => { if (index != _selected) row.Background = new SolidColorBrush(Color.FromArgb(0x14, 255, 255, 255)); };
            row.MouseLeave += (_, _) => Paint();
            row.MouseLeftButtonUp += (_, e) => { e.Handled = true; _popup!.IsOpen = false; Selected?.Invoke(index); };
            _rows.Add((row, text));
            _list.Children.Add(row);
        }

        _popup = new Popup
        {
            PlacementTarget = this,
            Placement = PlacementMode.Bottom,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = new Border
            {
                Margin = new Thickness(0, 4, 0, 8),
                Padding = new Thickness(4),
                CornerRadius = new CornerRadius(10),
                BorderThickness = new Thickness(1),
                BorderBrush = Ui.CardBorder,
                Background = new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x28)),
                Child = new ScrollViewer { MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Content = _list },
            },
        };
        _popup.Opened += (_, _) => OpenChanged?.Invoke(true);
        _popup.Closed += (_, _) => OpenChanged?.Invoke(false);
        MouseLeftButtonUp += (_, _) =>
        {
            if (_popup.IsOpen) { _popup.IsOpen = false; return; }
            ((Border)_popup.Child).MinWidth = ActualWidth;
            Paint();
            _popup.IsOpen = true;
        };
    }

    public void Set(int index, RgbColor accent)
    {
        _selected = index;
        _accent = accent;
        _value.Text = index >= 0 && index < _rows.Count ? _rows[index].Text.Text : "";
        Paint();
    }

    private void Paint()
    {
        for (var i = 0; i < _rows.Count; i++)
        {
            var on = i == _selected;
            _rows[i].Row.Background = on ? Ui.Brush(_accent, 0.2) : Brushes.Transparent;
            _rows[i].Text.Foreground = on ? Ui.TextPrimary : Ui.TextSecondary;
        }
    }
}
