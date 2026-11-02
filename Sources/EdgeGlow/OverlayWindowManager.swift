import AppKit
import Combine
import SwiftUI

/// Owns one click-through overlay panel per enabled display, keyed by display UUID
/// (`NSScreen.edgeGlowIdentifier`, which, unlike `localizedName`, differs between two identical monitors).
///
/// Panels are created when a display is checked in the popover and destroyed when it is unchecked or
/// unplugged. Each panel gets its own GlowRenderer, so physics, sparks and notch geometry are per screen.
final class OverlayWindowManager {
    private struct Overlay {
        let panel: OverlayPanel
        let renderer: GlowRenderer
    }

    private let state: AppState
    private var overlays: [String: Overlay] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state

        // Fires on plug/unplug, resolution and arrangement changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // @Published emits on willSet, so use the delivered value rather than re-reading the property.
        state.$activeDisplays
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] active in
                self?.sync(active: active)
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for overlay in overlays.values {
            Self.destroy(overlay)
        }
    }

    func start() {
        refreshDisplayList()
        sync(active: state.activeDisplays)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshDisplayList()
        sync(active: state.activeDisplays)
    }

    /// Brings the set of live panels in line with the checked displays that are actually connected.
    private func sync(active: Set<String>) {
        var screens: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.edgeGlowIdentifier { screens[id] = screen }
        }

        // Unchecked or disconnected: tear the panel down.
        let stale = overlays.keys.filter { !active.contains($0) || screens[$0] == nil }
        for id in stale {
            if let overlay = overlays.removeValue(forKey: id) {
                Self.destroy(overlay)
            }
        }

        for (id, screen) in screens where active.contains(id) {
            if let overlay = overlays[id] {
                // Still here, but its resolution, arrangement or notch may have changed.
                overlay.renderer.screen = screen
                if overlay.panel.frame != screen.frame {
                    overlay.panel.setFrame(screen.frame, display: true)
                }
            } else {
                overlays[id] = makeOverlay(for: screen)
            }
        }
    }

    private func makeOverlay(for screen: NSScreen) -> Overlay {
        let renderer = GlowRenderer()
        renderer.screen = screen
        let panel = OverlayPanel(covering: screen)
        let host = NSHostingView(rootView: GlowOverlayView(state: state, renderer: renderer))
        // Keep SwiftUI from resizing the panel to fit its content.
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        return Overlay(panel: panel, renderer: renderer)
    }

    private static func destroy(_ overlay: Overlay) {
        overlay.renderer.animating = false
        overlay.panel.orderOut(nil)
        // Drop the SwiftUI hierarchy now so its TimelineView stops ticking immediately.
        overlay.panel.contentView = nil
        overlay.panel.close()
    }

    private func refreshDisplayList() {
        let screens = NSScreen.screens.compactMap { screen -> (id: String, name: String, builtIn: Bool)? in
            guard let id = screen.edgeGlowIdentifier else { return nil }
            let builtIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            return (id, screen.localizedName, builtIn)
        }
        // Two identical monitors share a localizedName; number them so the list stays unambiguous.
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
}
