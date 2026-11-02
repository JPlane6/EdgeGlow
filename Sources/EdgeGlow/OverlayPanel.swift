import AppKit
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        let screen = Self.targetScreen(selectedID: state.selectedDisplayID)
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

        refreshDisplayList()
        updateGeometry(for: screen)

        // Fires on plug/unplug, resolution and arrangement changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // @Published emits on willSet, so use the delivered value rather than re-reading the property.
        state.$selectedDisplayID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] selectedID in
                self?.updateGeometry(for: Self.targetScreen(selectedID: selectedID))
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshDisplayList()
        updateGeometry(for: Self.targetScreen(selectedID: state.selectedDisplayID))
    }

    private func refreshDisplayList() {
        let screens = NSScreen.screens.compactMap { screen -> (id: String, name: String, builtIn: Bool)? in
            guard let id = screen.edgeGlowIdentifier else { return nil }
            let builtIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            return (id, screen.localizedName, builtIn)
        }
        // Two identical monitors share a localizedName; number them so the picker stays unambiguous.
        var seen: [String: Int] = [:]
        let displays = screens.map { screen -> DisplayInfo in
            let total = screens.filter { $0.name == screen.name }.count
            seen[screen.name, default: 0] += 1
            let name = total > 1 ? "\(screen.name) (\(seen[screen.name]!))" : screen.name
            return DisplayInfo(id: screen.id, name: name, isBuiltIn: screen.builtIn)
        }
        if state.availableDisplays != displays {
            state.availableDisplays = displays
        }
    }

    private func updateGeometry(for screen: NSScreen?) {
        guard let screen else { return }
        panel.setFrame(screen.frame, display: true)
        state.activeDisplayID = screen.edgeGlowIdentifier

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

    /// The user's chosen display, or the main screen when nothing is chosen or it is disconnected.
    private static func targetScreen(selectedID: String?) -> NSScreen? {
        if let selectedID, let match = NSScreen.screens.first(where: { $0.edgeGlowIdentifier == selectedID }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Display UUID, which (unlike CGDirectDisplayID) stays the same for a monitor across reboots and
    /// replugging. Falls back to the numeric display ID.
    var edgeGlowIdentifier: String? {
        guard let displayID else { return nil }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return String(displayID)
    }
}
