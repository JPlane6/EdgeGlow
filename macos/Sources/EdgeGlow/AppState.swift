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
    /// A mirrored pair of comets running down both sides to merge at bottom-center, then back up to top-center.
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
        case .symmetry: return "Mirrored comets sweep both sides, alternating top-to-bottom and back"
        case .sparksOnly: return "Dark edges. Only hard bass hits throw sparks inward"
        }
    }

    /// Styles that draw comets, and so use the Comet Length setting.
    var usesComets: Bool { self == .chasing || self == .symmetry }
}

/// Which of the two overlays are running. `off` is full standby: no render loops, no audio tap, no polling.
enum DisplayMode: String, CaseIterable, Identifiable {
    case both
    case glowOnly
    case lyricsOnly
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Both"
        case .glowOnly: return "Glow"
        case .lyricsOnly: return "Lyrics"
        case .off: return "Off"
        }
    }

    var caption: String {
        switch self {
        case .both: return "Rim lighting and synced lyrics"
        case .glowOnly: return "Rim lighting only, lyrics paused"
        case .lyricsOnly: return "Synced lyrics only, rim lighting paused"
        case .off: return "Standby: render loops and audio capture are stopped"
        }
    }

    var glowOn: Bool { self == .both || self == .glowOnly }
    var lyricsOn: Bool { self == .both || self == .lyricsOnly }
}

/// The current output route and the playback delay EdgeGlow compensates for (read-only, automatic).
struct AudioRouteInfo: Equatable {
    var deviceName: String
    var transport: AudioTransport
    /// Seconds between the Mac handing audio to the output and the sound reaching the listener.
    var latency: Double

    var offsetMilliseconds: Int { Int((latency * 1000).rounded()) }
    var summary: String { "\(deviceName) (Auto -\(offsetMilliseconds)ms)" }
}

enum AudioTransport: Equatable {
    case builtIn, bluetooth, usb, airPlay, other

    var symbol: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .airPlay: return "airplayaudio"
        case .other: return "speaker.wave.2"
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

/// Single source of truth shared by the media bridge, the audio pipeline, the overlay renderer and the popover UI.
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let thickness = "thickness"
        static let glowSpread = "glowSpread"
        static let reactivity = "reactivity"
        static let intensity = "intensity"
        static let idleWhenPaused = "idleWhenPaused"
        static let showOnLockScreen = "showOnLockScreen"
        static let useCustomColors = "useCustomColors"
        static let customPrimary = "customPrimary"
        static let customSecondary = "customSecondary"
        static let animationStyle = "animationStyle"
        static let activeDisplays = "activeDisplays"
        static let kineticEffects = "kineticEffects"
        static let cometLength = "cometLength"
        static let displayMode = "displayMode"
        static let lyricStyle = "lyricStyle"
        static let lyricFont = "lyricFont"
        static let romanizeLyrics = "romanizeLyrics"
        static let lyricTextScale = "lyricTextScale"
        static let lyricVerticalPosition = "lyricVerticalPosition"
        // Removed settings, cleared on launch.
        static let legacyNotchGlowEnabled = "notchGlowEnabled"
        static let legacySelectedDisplayID = "selectedDisplayID"
    }

    // MARK: Playback (driven by MediaBridge)

    @Published var playback: PlaybackState = .stopped
    /// The player (or plain system audio) the glow is following; nil when nothing is playing or paused.
    @Published var mediaSource: MediaSource?
    @Published var trackName = ""
    @Published var artistName = ""
    @Published var artwork: NSImage?
    /// Apps that denied EdgeGlow Automation access, by name.
    @Published var automationDeniedApps: [String] = []
    @Published var extractedPrimary = RGBColor.neonCyan
    @Published var extractedSecondary = RGBColor.neonMagenta

    /// Length of the current track in seconds (0 when unknown).
    @Published var trackDuration = 0.0
    /// Tempo of the current track from Deezer, once the lookup finishes.
    @Published var trackBPM: Double?

    /// Continuous track position for the current native player. Read at audio rate, so not @Published.
    let playbackClock = PlaybackClock()
    /// Tempo and lyric timing for the current track, used when the Mac itself is silent.
    let cloudSync = CloudSyncEngine()

    // MARK: Audio (driven by AudioCaptureManager)

    @Published var audioStatus: AudioCaptureStatus = .off
    /// Sound above -68 dBFS is coming out of the Mac; false after 1.5 s of digital silence.
    @Published var systemAudioActive = false
    /// What is currently feeding `audioLevels`.
    @Published var levelSource: LevelSource = .none
    /// Bass/vocal energies; read by the renderer every frame, so not @Published.
    let audioLevels = AudioLevels()

    /// Active output route and its automatically detected latency (driven by AudioLatencyDetector).
    @Published var audioRoute: AudioRouteInfo?
    /// Per-frame readable copy of the compensation (seconds); the lyric playhead subtracts it.
    let audioLatency = AudioLatency()
    /// Timing nudges learned from vocal onsets in the live audio.
    let vocalLock = VocalOnsetLock()

    // MARK: Displays (driven by OverlayWindowManager)

    /// Connected displays, in NSScreen order.
    @Published var availableDisplays: [DisplayInfo] = []

    // MARK: Persisted settings

    @Published var thickness: Double { didSet { defaults.set(thickness, forKey: Key.thickness) } }
    @Published var glowSpread: Double { didSet { defaults.set(glowSpread, forKey: Key.glowSpread) } }
    @Published var reactivity: Double { didSet { defaults.set(reactivity, forKey: Key.reactivity) } }
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: Key.intensity) } }
    @Published var idleWhenPaused: Bool { didSet { defaults.set(idleWhenPaused, forKey: Key.idleWhenPaused) } }
    /// Keep the overlays visible over the macOS lock screen.
    @Published var showOnLockScreen: Bool { didSet { defaults.set(showOnLockScreen, forKey: Key.showOnLockScreen) } }
    /// True while the screen is locked (driven by LockScreenMonitor).
    @Published var screenLocked = false
    @Published var useCustomColors: Bool { didSet { defaults.set(useCustomColors, forKey: Key.useCustomColors) } }
    @Published var customPrimary: RGBColor { didSet { defaults.set(customPrimary.array, forKey: Key.customPrimary) } }
    @Published var customSecondary: RGBColor { didSet { defaults.set(customSecondary.array, forKey: Key.customSecondary) } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) } }
    /// Bass-driven edge bounce, sparks and chromatic impact flashes. The physics state itself lives in
    /// GlowRenderer, since it changes every frame and must not trigger SwiftUI updates.
    @Published var kineticEffects: Bool { didSet { defaults.set(kineticEffects, forKey: Key.kineticEffects) } }
    /// Comet length as a fraction of the bezel perimeter (Chasing and Symmetry).
    @Published var cometLength: Double { didSet { defaults.set(cometLength, forKey: Key.cometLength) } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) } }
    @Published var romanizeLyrics: Bool { didSet { defaults.set(romanizeLyrics, forKey: Key.romanizeLyrics) } }
    @Published var lyricFont: LyricFont { didSet { defaults.set(lyricFont.rawValue, forKey: Key.lyricFont) } }
    @Published var lyricStyle: LyricStyle { didSet { defaults.set(lyricStyle.rawValue, forKey: Key.lyricStyle) } }
    /// Lyric size multiplier (0.6…1.8).
    @Published var lyricTextScale: Double { didSet { defaults.set(lyricTextScale, forKey: Key.lyricTextScale) } }
    /// 0 = top of the screen, 1 = bottom.
    @Published var lyricVerticalPosition: Double { didSet { defaults.set(lyricVerticalPosition, forKey: Key.lyricVerticalPosition) } }
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
            Key.showOnLockScreen: true,
            Key.useCustomColors: false,
            Key.kineticEffects: true,
            Key.cometLength: 0.18,
            Key.lyricTextScale: 1.0,
            Key.lyricVerticalPosition: 0.5,
        ])
        thickness = defaults.double(forKey: Key.thickness)
        glowSpread = defaults.double(forKey: Key.glowSpread)
        reactivity = defaults.double(forKey: Key.reactivity)
        intensity = defaults.double(forKey: Key.intensity)
        idleWhenPaused = defaults.bool(forKey: Key.idleWhenPaused)
        showOnLockScreen = defaults.bool(forKey: Key.showOnLockScreen)
        useCustomColors = defaults.bool(forKey: Key.useCustomColors)
        kineticEffects = defaults.bool(forKey: Key.kineticEffects)
        customPrimary = RGBColor(array: defaults.array(forKey: Key.customPrimary) as? [Double]) ?? .neonCyan
        customSecondary = RGBColor(array: defaults.array(forKey: Key.customSecondary) as? [Double]) ?? .neonMagenta
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: Key.animationStyle) ?? "") ?? .breathing
        cometLength = defaults.double(forKey: Key.cometLength)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .both
        romanizeLyrics = defaults.object(forKey: Key.romanizeLyrics) as? Bool ?? true
        lyricFont = LyricFont(rawValue: defaults.string(forKey: Key.lyricFont) ?? "") ?? .sfPro
        lyricStyle = LyricStyle(rawValue: defaults.string(forKey: Key.lyricStyle) ?? "") ?? .constellation
        lyricTextScale = defaults.double(forKey: Key.lyricTextScale)
        lyricVerticalPosition = defaults.double(forKey: Key.lyricVerticalPosition)

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

    /// Audio energies are driving the glow: something is playing and either the live FFT or Cloud Sync
    /// is producing levels.
    var audioReactive: Bool { isPlaying && levelSource != .none }

    /// Whether the overlay should currently be lit at all.
    var glowActive: Bool { displayMode.glowOn && (isPlaying || idleWhenPaused) }

    var targetPrimary: RGBColor { useCustomColors ? customPrimary : extractedPrimary }
    var targetSecondary: RGBColor { useCustomColors ? customSecondary : extractedSecondary }
}
