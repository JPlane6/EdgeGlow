import AppKit
import SwiftUI

/// Borderless panel that is allowed to cover the menu bar and notch.
class OverlayPanel: NSPanel {
    // macOS normally pushes windows below the menu bar; returning the frame untouched lets the
    // overlay span the full display, notch included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the full-screen click-through overlay and keeps it sized to the display.
final class OverlayController {
    private let state: AppState
    private let panel: OverlayPanel
    private let renderer = GlowRenderer()

    init(state: AppState) {
        self.state = state
        let screen = Self.targetScreen()
        panel = OverlayPanel(
            contentRect: screen?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: GlowOverlayView(state: state, renderer: renderer))
        // Keep SwiftUI from resizing the panel to fit its content.
        host.sizingOptions = []
        panel.contentView = host

        updateGeometry(for: screen)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        updateGeometry(for: Self.targetScreen())
    }

    private func updateGeometry(for screen: NSScreen?) {
        guard let screen else { return }
        panel.setFrame(screen.frame, display: true)

        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: notchHeight)
        } else {
            state.hasNotch = false
            state.notchSize = CGSize(width: 190, height: 32)
        }
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }
}
