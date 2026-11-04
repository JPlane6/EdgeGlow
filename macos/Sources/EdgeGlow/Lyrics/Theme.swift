import SwiftUI
import AppKit

// MARK: - Styles

enum LyricStyle: String, CaseIterable, Codable, Identifiable {
    case ship, visual, fisheye, fisheyeVisual, constellation, branches, web, codestyleVisual, constellation3D, hyperShip3D, orbitalWeb3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ship: return "Ship"
        case .visual: return "Visual"
        case .fisheye: return "Fisheye"
        case .fisheyeVisual: return "Fisheye Visual"
        case .constellation: return "Constellation"
        case .branches: return "Branches"
        case .web: return "Web"
        case .codestyleVisual: return "Codestyle Visual"
        case .constellation3D: return "Constellation 3D"
        case .hyperShip3D: return "HyperShip 3D"
        case .orbitalWeb3D: return "Orbital Web 3D"
        }
    }

    var blurb: String {
        switch self {
        case .ship: return "3D architectural word wall, camera dollying across it"
        case .visual: return "3D wall with living, animated semantic props"
        case .fisheye: return "The word wall through a convex optical lens"
        case .fisheyeVisual: return "Convex lens with animated semantic icons"
        case .constellation: return "Fly through a 3D star map, word to word"
        case .branches: return "A 3D neural tree grows to each word"
        case .web: return "3D tension mesh with shockwaves down the threads"
        case .codestyleVisual: return "Lyrics as live code on a tilted holographic plane"
        case .constellation3D: return "Deep parallax starfield, banking toward each star"
        case .hyperShip3D: return "Floating perspective stage, icons lift off the glass"
        case .orbitalWeb3D: return "A holographic spoke-and-ring disc that banks to each word"
        }
    }

    var showsIcons: Bool {
        switch self {
        case .visual, .fisheyeVisual, .codestyleVisual, .hyperShip3D: return true
        default: return false
        }
    }
}

// MARK: - Fonts

enum LyricFont: String, CaseIterable, Codable, Identifiable {
    case sfPro, sfRounded, newYork, helveticaNeue, avenirNext, futura, didot, sfMono
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
        case .sfMono: return "SF Mono"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .sfPro: return .system(size: size, weight: .bold, design: .default)
        case .sfRounded: return .system(size: size, weight: .bold, design: .rounded)
        case .newYork: return .system(size: size, weight: .bold, design: .serif)
        case .sfMono: return .system(size: size, weight: .semibold, design: .monospaced)
        case .helveticaNeue: return .custom("HelveticaNeue-Bold", size: size)
        case .avenirNext: return .custom("AvenirNext-Bold", size: size)
        case .futura: return .custom("Futura-Bold", size: size)
        case .didot: return .custom("Didot-Bold", size: size)
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        func design(_ d: NSFontDescriptor.SystemDesign, _ w: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: w)
            if let desc = base.fontDescriptor.withDesign(d), let f = NSFont(descriptor: desc, size: size) { return f }
            return base
        }
        switch self {
        case .sfPro: return NSFont.systemFont(ofSize: size, weight: .semibold)
        case .sfRounded: return design(.rounded, .bold)
        case .newYork: return design(.serif, .bold)
        case .sfMono: return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        case .helveticaNeue: return NSFont(name: "HelveticaNeue-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        case .avenirNext: return NSFont(name: "AvenirNext-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        case .futura: return NSFont(name: "Futura-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        case .didot: return NSFont(name: "Didot-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        }
    }
}

// MARK: - Colors

enum ColorSlot: String, CaseIterable, Identifiable {
    case text, highlight, secondary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text"
        case .highlight: return "Highlight"
        case .secondary: return "Secondary"
        }
    }
}

struct RGBA: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? NSColor.white.usingColorSpace(.sRGB)!
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func mixed(_ o: RGBA, _ t: Double) -> RGBA {
        let k = min(1, max(0, t))
        return RGBA(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k, a: a + (o.a - a) * k)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
}

extension Color {
    /// Mixes two colors in sRGB. (`Color.mix` only exists on macOS 15+.)
    func mixed(_ other: Color, _ t: Double) -> Color {
        RGBA(NSColor(self)).mixed(RGBA(NSColor(other)), t).color
    }
}

// MARK: - Theme

struct LyricTheme: Equatable {
    var font: LyricFont = .sfRounded
    var text: Color = .white
    var highlight: Color = Color(red: 0.37, green: 0.88, blue: 1.0)
    var secondary: Color = Color(red: 0.70, green: 0.53, blue: 1.0)
    var scale: Double = 1.0
    /// Dominant artwork colours for mesh-style renderers (may be empty).
    var meshColors: [Color] = []

    var baseSize: CGFloat { CGFloat(54 * scale) }

    func scaled(_ s: Double) -> LyricTheme { var t = self; t.scale = s; return t }

    static let preview = LyricTheme(font: .sfRounded, scale: 0.55)
}

// MARK: - Text metrics (cached NSFont measurement for Canvas layouts)

final class TextMetrics: @unchecked Sendable {
    static let shared = TextMetrics()
    private var cache: [String: CGFloat] = [:]
    private let lock = NSLock()

    func width(_ s: String, font: LyricFont, size: CGFloat) -> CGFloat {
        let key = "\(font.rawValue)|\(Int(size * 2))|\(s)"
        lock.lock()
        if let v = cache[key] { lock.unlock(); return v * (size / (CGFloat(Int(size * 2)) / 2)) }
        lock.unlock()
        let q = CGFloat(Int(size * 2)) / 2
        let w = NSAttributedString(string: s, attributes: [.font: font.nsFont(size: max(1, q))]).size().width
        lock.lock()
        if cache.count > 6000 { cache.removeAll() }
        cache[key] = w
        lock.unlock()
        return w * (size / max(1, q))
    }
}
