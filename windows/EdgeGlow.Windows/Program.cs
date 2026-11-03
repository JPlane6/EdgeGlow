using System;
using System.IO;
using System.Threading;
using System.Windows;

namespace EdgeGlow;

public static class Program
{
    [STAThread]
    public static int Main()
    {
        // One instance per user session.
        using var mutex = new Mutex(true, @"Local\EdgeGlow.Windows.SingleInstance", out var isFirst);
        if (!isFirst) return 0;

        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash(e.ExceptionObject as Exception);

        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            LogCrash(e.Exception);
            e.Handled = true; // a rendering hiccup should never take the glow down
        };

        var state = AppState.Shared;
        DisplayManager? displays = null;
        MediaBridge? media = null;
        AudioCaptureManager? audio = null;
        TrayIcon? tray = null;
        var quitting = false;

        void Quit()
        {
            if (quitting) return;
            quitting = true;
            state.SaveNow();
            tray?.Dispose();
            displays?.Dispose();
            audio?.Dispose();
            media?.Dispose();
            app.Shutdown();
        }

        app.Startup += (_, _) =>
        {
            displays = new DisplayManager(state, app.Dispatcher);
            displays.Start();

            var flyout = new FlyoutWindow(state, Quit);
            tray = new TrayIcon(state, flyout, Quit);

            media = new MediaBridge(state);
            media.Start();

            audio = new AudioCaptureManager(state, app.Dispatcher);
            audio.Start();
        };

        return app.Run();
    }

    private static void LogCrash(Exception? exception)
    {
        try
        {
            Directory.CreateDirectory(AppState.SettingsDirectory);
            File.AppendAllText(Path.Combine(AppState.SettingsDirectory, "crash.log"), $"[{DateTime.Now:u}] {exception}\n\n");
        }
        catch
        {
            // Nothing left to do.
        }
    }
}
