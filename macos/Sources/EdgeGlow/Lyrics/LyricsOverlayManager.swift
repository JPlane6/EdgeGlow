import AppKit
import Combine
import SwiftUI

/// Owns one click-through full-canvas lyrics panel per enabled display while the mode includes lyrics. Switching to
/// `Glow Only` or `Off` destroys the panels (and with them their render loops and Metal/SpriteKit
/// resources); switching back rebuilds them.
@MainActor
final class LyricsOverlayManager {
    private let state: AppState
    private let model: LyricsModel
    private lazy var director: LyricsDirector? = LyricsDirector()
    private var panels: [String: OverlayPanel] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, model: LyricsModel) {
        self.state = state
        self.model = model
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Publishers.CombineLatest(state.$activeDisplays, state.$displayMode.map(\.lyricsOn).removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.sync() }
            .store(in: &cancellables)

        sync()
    }

    func stop() {
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        for id in Array(panels.keys) { destroy(id) }
    }

    @objc private func screensChanged() { sync() }

    private func sync() {
        var screens: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.edgeGlowIdentifier { screens[id] = screen }
        }
        let wanted = state.displayMode.lyricsOn ? state.activeDisplays : []

        for id in panels.keys where !wanted.contains(id) || screens[id] == nil {
            destroy(id)
        }
        for (id, screen) in screens where wanted.contains(id) {
            if let panel = panels[id] {
                let frame = canvasFrame(on: screen)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            } else {
                panels[id] = makePanel(for: screen)
            }
        }
    }

    private func makePanel(for screen: NSScreen) -> OverlayPanel {
        let panel = OverlayPanel(covering: screen)
        let frame = canvasFrame(on: screen)
        panel.contentView = LyricsMetalView(model: model, state: state, director: director)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        return panel
    }

    /// The lyric canvas: an 85% × 85% safe area, so spatial styles can drift across the screen.
    private func canvasFrame(on screen: NSScreen) -> NSRect {
        let canvas = OverlayLayout.canvasRect(screen: screen.frame.size)
        return NSRect(x: screen.frame.minX + canvas.minX, y: screen.frame.maxY - canvas.maxY, width: canvas.width, height: canvas.height)
    }

    private func destroy(_ id: String) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.orderOut(nil)
        // Drop the hierarchy now so its TimelineView and any Metal/SpriteKit views stop immediately.
        panel.contentView = nil
        panel.close()
    }
}

enum OverlayLayout {
    /// The lyric canvas: an 85% × 85% safe area centered on the screen, so 3D camera moves have the
    /// whole monitor to breathe while the menu bar and the glow rim stay clear.
    static func canvasRect(screen: CGSize) -> CGRect {
        let w = screen.width * 0.85, h = screen.height * 0.85
        return CGRect(x: (screen.width - w) / 2, y: (screen.height - h) / 2, width: w, height: h)
    }
}
