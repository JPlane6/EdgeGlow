import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var overlay: OverlayController?
    private var spotify: SpotifyBridge?
    private var audio: AudioCaptureManager?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController(state: state)
        overlay.show()
        self.overlay = overlay

        setUpPopover()
        setUpStatusItem()

        let spotify = SpotifyBridge(state: state)
        spotify.start()
        self.spotify = spotify

        let audio = AudioCaptureManager(state: state)
        audio.start()
        self.audio = audio
    }

    func applicationWillTerminate(_ notification: Notification) {
        spotify?.stop()
        audio?.stop()
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
        popover.contentViewController?.view.window?.level = .popUpMenu
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
