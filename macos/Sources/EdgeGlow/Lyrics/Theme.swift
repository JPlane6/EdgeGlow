import SwiftUI
import AppKit

// MARK: - Styles

enum LyricStyle: String, CaseIterable, Codable, Identifiable {
    case ship, fisheye, visual, fisheyeVisual, flashbang, flashbangVisual, branches, web, constellation
    case appleDesign, appleMoney, appleMap, appleNotify
    case orbital

    var id: String { rawValue }

    /// Reads a stored style, mapping the retired 3D styles onto their closest replacement.
    init(stored raw: String?) {
        switch raw ?? "" {
        case "codestyleVisual": self = .flashbangVisual
        case "constellation3D": self = .constellation
        case "hyperShip3D": self = .ship
        case "orbitalWeb3D": self = .web
        default: self = LyricStyle(rawValue: raw ?? "") ?? .constellation
        }
    }

    var title: String {
        switch self {
        case .ship: return "Ship"
        case .fisheye: return "Fisheye"
        case .visual: return "Visual"
        case .fisheyeVisual: return "Fisheye Visual"
        case .flashbang: return "Codestyle"
        case .flashbangVisual: return "Codestyle Visual"
        case .branches: return "Branches"
        case .web: return "Web"
        case .constellation: return "Constellation"
        case .appleDesign: return "Apple Design"
        case .appleMoney: return "Apple Design Money"
        case .appleMap: return "Apple Design Map"
        case .appleNotify: return "Apple Design Notifications"
        case .orbital: return "Orbital"
        }
    }

    var blurb: String {
        switch self {
        case .ship: return "Words land one by one on a wall that drifts in 3D."
        case .fisheye: return "A tight stack of three words, bulging through a lens."
        case .visual: return "A centered stack, with an icon for every word that has one."
        case .fisheyeVisual: return "Fisheye, with icons beside the words that have one."
        case .flashbang: return "The lyric typed out as code, under a blinking red cursor."
        case .flashbangVisual: return "Codestyle, with icons beside the words that have one."
        case .branches: return "A line draws itself, and each word lights a node on it."
        case .web: return "Each line spun into a spider's web, a strand for every word."
        case .constellation: return "Each line traced as a constellation, star by star."
        case .appleDesign: return "The song as a Messages thread, a bubble for every line."
        case .appleMoney: return "Every line sent as Apple Cash, Wallet cards and Apple Pay."
        case .appleMap: return "A walk across San Francisco, with a pin for every line."
        case .appleNotify: return "Lines arrive as Lock Screen notifications, stacks and widgets."
        case .orbital: return "Circular album art, live 360° equalizer, and bold left-side lyrics."
        }
    }

    /// Styles that draw an icon beside words resolved by `WordVisualResolver`.
    var showsIcons: Bool {
        switch self {
        case .visual, .fisheyeVisual, .flashbangVisual: return true
        default: return false
        }
    }

    /// Styles that consult `WordVisualResolver` at all (Wallet passes pick their glyph from the line).
    var needsWordVisuals: Bool { showsIcons || self == .appleMoney }

    /// Styles 10–13 always use Apple's native SF fonts and system colors, ignoring the user's font and color slots.
    var usesNativeApple: Bool {
        switch self {
        case .appleDesign, .appleMoney, .appleMap, .appleNotify: return true
        default: return false
        }
    }
}

// MARK: - Fonts

enum LyricFont: String, CaseIterable, Codable, Identifiable {
    case sfPro, sfRounded, newYork, helveticaNeue, avenirNext, futura, didot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfPro: return "SF Pro"
        case .sfRounded: return "SF Rounded"
        case .newYork: return "New York"
        case .helveticaNeue: return "Helvetica Neue"
        case .avenirNext: return "Avenir Next"
        case .futura: return "Futura"
        case .didot: return "Didot"
        }
    }

    /// The custom faces are single bold cuts, so `weight` only applies to the system designs.
    func font(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        switch self {
        case .sfPro: return .system(size: size, weight: weight, design: .default)
        case .sfRounded: return .system(size: size, weight: weight, design: .rounded)
        case .newYork: return .system(size: size, weight: weight, design: .serif)
        case .helveticaNeue: return .custom("HelveticaNeue-Bold", fixedSize: size)
        case .avenirNext: return .custom("AvenirNext-Bold", fixedSize: size)
        case .futura: return .custom("Futura-Bold", fixedSize: size)
        case .didot: return .custom("Didot-Bold", fixedSize: size)
        }
    }
}

// MARK: - Colors

struct RGBA: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? NSColor.white.usingColorSpace(.sRGB)!
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    init(_ color: Color) { self.init(NSColor(color)) }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func mixed(_ o: RGBA, _ t: Double) -> RGBA {
        let k = min(1, max(0, t))
        return RGBA(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k, a: a + (o.a - a) * k)
    }

    /// `#RRGGBBAA`, the format the three lyric color slots are stored in.
    var hexRGBA: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
    }

    /// Accepts `#RRGGBB` and `#RRGGBBAA`.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }
}

extension Color {
    /// Hex literal (`#RRGGBB` / `#RRGGBBAA`); used for the fixed Apple system and Codestyle colors.
    init(hex: String) { self = (RGBA(hex: hex) ?? RGBA(r: 1, g: 1, b: 1)).color }

    /// Perceptual mix on macOS 15+ (`Color.mix`), sRGB lerp before that.
    func mixed(_ other: Color, _ t: Double) -> Color {
        if #available(macOS 15.0, *) {
            return self.mix(with: other, by: min(1, max(0, t)), in: .perceptual)
        }
        return RGBA(self).mixed(RGBA(other), t).color
    }
}

/// The three lyric color slots.
struct LyricPalette: Equatable {
    var text: Color
    var highlight: Color
    var secondary: Color

    /// Native iOS / macOS dark-mode colors for the Apple Design styles.
    static let appleNative = LyricPalette(text: .white, highlight: Color(hex: "#0A84FF"), secondary: Color(hex: "#8E8E93"))
    static let fallback = LyricPalette(text: .white, highlight: Color(red: 0.37, green: 0.88, blue: 1.0), secondary: Color(red: 0.70, green: 0.53, blue: 1.0))
}

/// Apple's system palette (dark appearance), used by the Apple Design styles.
enum AppleColors {
    static let blue = Color(hex: "#0A84FF")
    static let blueDeep = Color(hex: "#0045B8")
    static let green = Color(hex: "#30D158")
    static let red = Color(hex: "#FF453A")
    static let pink = Color(hex: "#FF375F")
    static let orange = Color(hex: "#FF9F0A")
    static let purple = Color(hex: "#BF5AF2")
    static let indigo = Color(hex: "#5E5CE6")
    static let teal = Color(hex: "#30B0C7")
    static let cyan = Color(hex: "#40C8E0")
    static let sky = Color(hex: "#5AC8FA")
    static let brown = Color(hex: "#AC8E68")
    static let gray = Color(hex: "#8E8E93")
    static let gray2 = Color(hex: "#636366")
    static let surface = Color(hex: "#1C1C1E")
    static let bubbleIncoming = Color(hex: "#262629")
    static let bubbleIncomingTop = Color(hex: "#2C2C2E")

    /// Location-share pin colors.
    static let pins = ["#FF453A", "#30B0C7", "#AC8E68", "#5E5CE6", "#0A84FF", "#FF375F", "#FF9F0A", "#5AC8FA", "#30D158", "#BF5AF2"].map(Color.init(hex:))
    /// Wallet pass tints.
    static let wallet = ["#8C9EFF", "#6BD6FA", "#FFD6FA", "#30D158", "#FF9F58", "#FF375F", "#BF5AF2", "#40C8E0", "#5E5CE6", "#FF453A"].map(Color.init(hex:))
}
