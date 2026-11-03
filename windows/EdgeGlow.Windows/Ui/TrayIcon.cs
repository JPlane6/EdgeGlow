using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace EdgeGlow;

/// <summary>System tray (NotifyIcon) entry point: left click toggles the dark flyout, right click opens a small menu.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly AppState _state;
    private readonly FlyoutWindow _flyout;
    private readonly ToolStripMenuItem _startupItem;
    private readonly Icon _appIcon;

    public TrayIcon(AppState state, FlyoutWindow flyout, Action quit)
    {
        _state = state;
        _flyout = flyout;
        _appIcon = LoadIcon();

        _startupItem = new ToolStripMenuItem("Launch at startup") { CheckOnClick = false };
        _startupItem.Click += (_, _) => LaunchAtStartup.IsEnabled = !LaunchAtStartup.IsEnabled;

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open EdgeGlow", null, (_, _) => _flyout.ShowFlyout());
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit EdgeGlow", null, (_, _) => quit());
        menu.Opening += (_, _) => _startupItem.Checked = LaunchAtStartup.IsEnabled;

        _icon = new NotifyIcon
        {
            Icon = _appIcon,
            Text = "EdgeGlow",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) _flyout.ToggleFlyout();
        };

        _state.Changed += UpdateTooltip;
    }

    /// <summary>The multi-resolution AppIcon.ico embedded in the executable; Windows picks the best size for the tray.</summary>
    private static Icon LoadIcon()
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("AppIcon.ico");
            if (stream != null) return new Icon(stream, SystemInformation.SmallIconSize);
        }
        catch
        {
            // Fall through to the default icon.
        }
        return SystemIcons.Application;
    }

    private void UpdateTooltip()
    {
        // NotifyIcon.Text is limited to 63 characters.
        var text = _state.Playback != PlaybackState.Stopped && _state.TrackName.Length > 0
            ? $"EdgeGlow — {_state.TrackName}" + (_state.ArtistName.Length > 0 ? $" · {_state.ArtistName}" : "")
            : "EdgeGlow";
        if (text.Length > 63) text = text.Substring(0, 62) + "…";
        try { _icon.Text = text; } catch { }
    }

    public void Dispose()
    {
        _state.Changed -= UpdateTooltip;
        _icon.Visible = false;
        _icon.Dispose();
        _appIcon.Dispose();
    }
}
