import AppKit
import SwiftUI

/// Plain sRGB color value that is cheap to lerp every frame and easy to persist.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let neonCyan = RGBColor(r: 0.0, g: 0.90, b: 1.0)
    static let neonMagenta = RGBColor(r: 1.0, g: 0.16, b: 0.85)
    static let white = RGBColor(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    init?(array: [Double]?) {
        guard let array, array.count == 3 else { return nil }
        self.init(r: array[0], g: array[1], b: array[2])
    }

    var array: [Double] { [r, g, b] }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// Relative luminance (Rec. 709), used to find the brightest part of a gradient.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    func lerp(to target: RGBColor, t: Double) -> RGBColor {
        RGBColor(r: r + (target.r - r) * t, g: g + (target.g - g) * t, b: b + (target.b - b) * t)
    }
}

enum PlaybackState: Equatable {
    case playing
    case paused
    case stopped
}

enum AnimationStyle: String, CaseIterable, Identifiable {
    /// Rotating dual-color rim pulsing with the bass (the original look).
    case breathing
    /// Two comets with bright heads and fading tails racing clockwise around an otherwise dark bezel.
    case chasing
    /// A mirrored pair of comets running from top-center down both sides and merging at bottom-center.
    case symmetry
    /// No rim at all: only the kinetic sparks fired inward by hard bass transients.
    case sparksOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breathing: return "Breathing"
        case .chasing: return "Chasing"
        case .symmetry: return "Symmetry"
        case .sparksOnly: return "Sparks Only"
        }
    }

    var symbol: String {
        switch self {
        case .breathing: return "wind"
        case .chasing: return "arrow.clockwise"
        case .symmetry: return "arrow.triangle.merge"
        case .sparksOnly: return "sparkles"
        }
    }

    var caption: String {
        switch self {
        case .breathing: return "Rotating two-color rim that pulses with the kick"
        case .chasing: return "Comets chase the bezel, faster on vocals, fuller on bass"
        case .symmetry: return "Mirrored comets fall down both sides and merge at the bottom"
        case .sparksOnly: return "Dark edges. Only hard bass hits throw sparks inward"
        }
    }

    /// Styles that draw comets, and so use the Comet Length setting.
    var usesComets: Bool { self == .chasing || self == .symmetry }
}

/// A connected display as shown in the popover's display picker.
struct DisplayInfo: Identifiable, Equatable {
    /// Stable per-monitor identifier (display UUID), so the choice survives reboots and replugging.
    let id: String
    let name: String
    let isBuiltIn: Bool
}

/// Single source of truth shared by the Spotify bridge, the overlay renderer and the popover UI.
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let thickness = "thickness"
        static let glowSpread = "glowSpread"
        static let reactivity = "reactivity"
        static let intensity = "intensity"
        static let idleWhenPaused = "idleWhenPaused"
        static let useCustomColors = "useCustomColors"
        static let customPrimary = "customPrimary"
        static let customSecondary = "customSecondary"
        static let animationStyle = "animationStyle"
        static let activeDisplays = "activeDisplays"
        static let kineticEffects = "kineticEffects"
        static let cometLength = "cometLength"
        // Removed settings, cleared on launch.
        static let legacyNotchGlowEnabled = "notchGlowEnabled"
        static let legacySelectedDisplayID = "selectedDisplayID"
    }

    // MARK: Playback (driven by SpotifyBridge)

    @Published var playback: PlaybackState = .stopped
    @Published var spotifyRunning = false
    @Published var trackName = ""
    @Published var artistName = ""
    @Published var artwork: NSImage?
    @Published var automationDenied = false
    @Published var extractedPrimary = RGBColor.neonCyan
    @Published var extractedSecondary = RGBColor.neonMagenta

    /// Track position (seconds) sampled from Spotify, and when it was sampled. Updated on every poll,
    /// so deliberately not @Published.
    var positionAnchor: Double = 0
    var anchorDate = Date()

    // MARK: System audio (driven by AudioCaptureManager)

    @Published var audioStatus: AudioCaptureStatus = .off
    /// Bass/vocal energies; read by the renderer every frame, so not @Published.
    let audioLevels = AudioLevels()

    // MARK: Displays (driven by OverlayWindowManager)

    /// Connected displays, in NSScreen order.
    @Published var availableDisplays: [DisplayInfo] = []

    // MARK: Persisted settings

    @Published var thickness: Double { didSet { defaults.set(thickness, forKey: Key.thickness) } }
    @Published var glowSpread: Double { didSet { defaults.set(glowSpread, forKey: Key.glowSpread) } }
    @Published var reactivity: Double { didSet { defaults.set(reactivity, forKey: Key.reactivity) } }
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: Key.intensity) } }
    @Published var idleWhenPaused: Bool { didSet { defaults.set(idleWhenPaused, forKey: Key.idleWhenPaused) } }
    @Published var useCustomColors: Bool { didSet { defaults.set(useCustomColors, forKey: Key.useCustomColors) } }
    @Published var customPrimary: RGBColor { didSet { defaults.set(customPrimary.array, forKey: Key.customPrimary) } }
    @Published var customSecondary: RGBColor { didSet { defaults.set(customSecondary.array, forKey: Key.customSecondary) } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) } }
    /// Bass-driven edge bounce, sparks and chromatic impact flashes. The physics state itself lives in
    /// GlowRenderer, since it changes every frame and must not trigger SwiftUI updates.
    @Published var kineticEffects: Bool { didSet { defaults.set(kineticEffects, forKey: Key.kineticEffects) } }
    /// Comet length as a fraction of the bezel perimeter (Chasing and Symmetry).
    @Published var cometLength: Double { didSet { defaults.set(cometLength, forKey: Key.cometLength) } }
    /// Display UUIDs (`NSScreen.edgeGlowIdentifier`) that get an overlay. Empty hides the glow everywhere.
    /// IDs of unplugged displays are kept, so the glow returns when that monitor is reconnected.
    @Published var activeDisplays: Set<String> { didSet { saveActiveDisplays() } }

    private init() {
        defaults.register(defaults: [
            Key.thickness: 42.0,
            Key.glowSpread: 45.0,
            Key.reactivity: 1.0,
            Key.intensity: 0.85,
            Key.idleWhenPaused: true,
            Key.useCustomColors: false,
            Key.kineticEffects: true,
            Key.cometLength: 0.18,
        ])
        thickness = defaults.double(forKey: Key.thickness)
        glowSpread = defaults.double(forKey: Key.glowSpread)
        reactivity = defaults.double(forKey: Key.reactivity)
        intensity = defaults.double(forKey: Key.intensity)
        idleWhenPaused = defaults.bool(forKey: Key.idleWhenPaused)
        useCustomColors = defaults.bool(forKey: Key.useCustomColors)
        kineticEffects = defaults.bool(forKey: Key.kineticEffects)
        customPrimary = RGBColor(array: defaults.array(forKey: Key.customPrimary) as? [Double]) ?? .neonCyan
        customSecondary = RGBColor(array: defaults.array(forKey: Key.customSecondary) as? [Double]) ?? .neonMagenta
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: Key.animationStyle) ?? "") ?? .breathing
        cometLength = defaults.double(forKey: Key.cometLength)

        if let stored = defaults.stringArray(forKey: Key.activeDisplays) {
            activeDisplays = Set(stored)
        } else {
            // First launch, or upgrading from the single display picker: start with the previously
            // chosen display if it is connected, otherwise the main display.
            let connected = NSScreen.screens.compactMap(\.edgeGlowIdentifier)
            if let legacy = defaults.string(forKey: Key.legacySelectedDisplayID), connected.contains(legacy) {
                activeDisplays = [legacy]
            } else {
                activeDisplays = Set([NSScreen.main?.edgeGlowIdentifier ?? connected.first].compactMap { $0 })
            }
            saveActiveDisplays()
        }
        defaults.removeObject(forKey: Key.legacySelectedDisplayID)
        defaults.removeObject(forKey: Key.legacyNotchGlowEnabled)
    }

    private func saveActiveDisplays() {
        defaults.set(activeDisplays.sorted(), forKey: Key.activeDisplays)
    }

    // MARK: Derived values

    var isPlaying: Bool { playback == .playing }

    /// Live audio is driving the glow (Spotify playing and system audio capture running).
    var audioReactive: Bool { isPlaying && audioStatus == .live }

    /// Whether the overlay should currently be lit at all.
    var glowActive: Bool { isPlaying || idleWhenPaused }

    var targetPrimary: RGBColor { useCustomColors ? customPrimary : extractedPrimary }
    var targetSecondary: RGBColor { useCustomColors ? customSecondary : extractedSecondary }

    /// Extrapolated playback position used for beat phase.
    func playbackPosition(at date: Date) -> Double {
        isPlaying ? positionAnchor + date.timeIntervalSince(anchorDate) : positionAnchor
    }
}
