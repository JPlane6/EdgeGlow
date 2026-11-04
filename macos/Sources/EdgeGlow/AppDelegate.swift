import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var overlays: OverlayWindowManager?
    private var media: MediaBridge?
    private var audio: AudioCaptureManager?
    private var latency: AudioLatencyDetector?
    private var lyricsModel: LyricsModel?
    private var lyricsOverlays: LyricsOverlayManager?
    private var outsideClickMonitor: Any?
    private var lockMonitor: LockScreenMonitor?
    private var sleepBlocker: DisplaySleepBlocker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlays = OverlayWindowManager(state: state)
        overlays.start()
        self.overlays = overlays

        setUpPopover()
        setUpStatusItem()

        let media = MediaBridge(state: state)
        media.start()
        self.media = media

        let audio = AudioCaptureManager(state: state)
        audio.start()
        self.audio = audio

        let latency = AudioLatencyDetector(state: state)
        latency.start()
        self.latency = latency

        // Lyrics follow the same AppState the glow does: one media bridge, one clock, one palette.
        let lyrics = LyricsModel(state: state)
        lyrics.start()
        lyricsModel = lyrics
        let lyricsOverlays = LyricsOverlayManager(state: state, model: lyrics)
        lyricsOverlays.start()
        self.lyricsOverlays = lyricsOverlays

        let lockMonitor = LockScreenMonitor(state: state)
        lockMonitor.start()
        self.lockMonitor = lockMonitor
        let sleepBlocker = DisplaySleepBlocker(state: state)
        sleepBlocker.start()
        self.sleepBlocker = sleepBlocker

        Updater.shared.checkOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepBlocker?.stop()
        media?.stop()
        audio?.stop()
        latency?.stop()
        lyricsOverlays?.stop()
        lyricsModel?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Status item + popover

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "EdgeGlow")
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "EdgeGlow")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    private func setUpPopover() {
        let controller = NSHostingController(rootView: MenuBarPopoverView(state: state))
        controller.sizingOptions = .preferredContentSize
        // Closed manually (see showPopover) so the system color panel can be used without dismissing it.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
    }

    @objc private func togglePopover(_ sender: Any?) {
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Sit above the glow overlay, which lives just above the status bar level.
        popover.contentViewController?.view.window?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

extension NSApplication {
    /// Quits and reopens the app bundle; macOS only applies a new Screen Recording grant after a relaunch.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        terminate(nil)
    }
}
