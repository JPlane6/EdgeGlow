import AppKit
import SwiftUI

/// Plain sRGB color value that is cheap to lerp every frame and easy to persist.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let neonCyan = RGBColor(r: 0.0, g: 0.90, b: 1.0)
    static let neonMagenta = RGBColor(r: 1.0, g: 0.16, b: 0.85)

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
    /// Comet-tail gradient racing around the perimeter, top → right → bottom → left, sped up by vocal energy.
    case chasing
    /// Fixed gradient, no motion or pulse; only fades and color crossfades.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breathing: return "Breathing"
        case .chasing: return "Chasing"
        case .solid: return "Solid"
        }
    }
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
        static let notchGlowEnabled = "notchGlowEnabled"
        static let customPrimary = "customPrimary"
        static let customSecondary = "customSecondary"
        static let animationStyle = "animationStyle"
        static let selectedDisplayID = "selectedDisplayID"
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

    // MARK: Display geometry (driven by OverlayController)

    @Published var hasNotch = false
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var availableDisplays: [DisplayInfo] = []
    /// The display the overlay is actually on. Differs from `selectedDisplayID` while the chosen
    /// monitor is unplugged and the overlay has fallen back to the main screen.
    @Published var activeDisplayID: String?

    // MARK: Persisted settings

    @Published var thickness: Double { didSet { defaults.set(thickness, forKey: Key.thickness) } }
    @Published var glowSpread: Double { didSet { defaults.set(glowSpread, forKey: Key.glowSpread) } }
    @Published var reactivity: Double { didSet { defaults.set(reactivity, forKey: Key.reactivity) } }
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: Key.intensity) } }
    @Published var idleWhenPaused: Bool { didSet { defaults.set(idleWhenPaused, forKey: Key.idleWhenPaused) } }
    @Published var useCustomColors: Bool { didSet { defaults.set(useCustomColors, forKey: Key.useCustomColors) } }
    @Published var notchGlowEnabled: Bool { didSet { defaults.set(notchGlowEnabled, forKey: Key.notchGlowEnabled) } }
    @Published var customPrimary: RGBColor { didSet { defaults.set(customPrimary.array, forKey: Key.customPrimary) } }
    @Published var customSecondary: RGBColor { didSet { defaults.set(customSecondary.array, forKey: Key.customSecondary) } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) } }
    /// User's chosen display; nil means "main screen". Kept while that display is disconnected so the
    /// overlay returns to it when it is plugged back in.
    @Published var selectedDisplayID: String? { didSet { defaults.set(selectedDisplayID, forKey: Key.selectedDisplayID) } }

    private init() {
        defaults.register(defaults: [
            Key.thickness: 42.0,
            Key.glowSpread: 45.0,
            Key.reactivity: 1.0,
            Key.intensity: 0.85,
            Key.idleWhenPaused: true,
            Key.useCustomColors: false,
            Key.notchGlowEnabled: false,
        ])
        thickness = defaults.double(forKey: Key.thickness)
        glowSpread = defaults.double(forKey: Key.glowSpread)
        reactivity = defaults.double(forKey: Key.reactivity)
        intensity = defaults.double(forKey: Key.intensity)
        idleWhenPaused = defaults.bool(forKey: Key.idleWhenPaused)
        useCustomColors = defaults.bool(forKey: Key.useCustomColors)
        notchGlowEnabled = defaults.bool(forKey: Key.notchGlowEnabled)
        customPrimary = RGBColor(array: defaults.array(forKey: Key.customPrimary) as? [Double]) ?? .neonCyan
        customSecondary = RGBColor(array: defaults.array(forKey: Key.customSecondary) as? [Double]) ?? .neonMagenta
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: Key.animationStyle) ?? "") ?? .breathing
        selectedDisplayID = defaults.string(forKey: Key.selectedDisplayID)
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
