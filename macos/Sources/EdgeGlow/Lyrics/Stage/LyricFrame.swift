import AppKit
import SwiftUI

// MARK: - Playhead

/// A sampled player position: `position = elapsed + (now - timestamp) * rate + lyricDelay`.
/// Extrapolating from one anchor per frame keeps every scene moving smoothly at 60/120 fps between the
/// player's (much slower) position reports.
struct PlayheadAnchor: Equatable {
    var elapsed: Double
    var timestamp: Date
    var rate: Double

    func position(at date: Date, lyricDelay: Double = 0) -> Double {
        elapsed + date.timeIntervalSince(timestamp) * rate + lyricDelay
    }
}

/// Monotonic-ish scene clock (seconds since launch) for idle motion; small numbers keep `sin` exact.
enum LyricClock {
    static let epoch = Date()
    static func seconds(_ date: Date) -> Double { date.timeIntervalSince(epoch) }
}

// MARK: - Frame

struct LyricTrack {
    var title: String = ""
    var artist: String = ""
    var artwork: NSImage?
    /// Vivid accent colors from the artwork (`ArtworkColorSync`), for Wallet / Notification tints.
    var blooms: [Color] = []
}

/// Everything a scene needs to draw one frame: `(position, clock, canvas, bandHeight, textScale)` plus the
/// lyrics, palette, font and track.
struct LyricFrame {
    let lyrics: TimedLyrics
    /// Song position in seconds (playhead, already latency compensated).
    let position: Double
    /// Scene clock in seconds, for idle drift, blinking and shimmer.
    let clock: Double
    /// The overlay canvas, in points.
    let canvas: CGSize
    /// Height of the lyric band and its vertical center (from the Position slider).
    let bandHeight: CGFloat
    let bandCenterY: CGFloat
    /// User text size × screen factor.
    let textScale: CGFloat
    let palette: LyricPalette
    let font: LyricFont
    let track: LyricTrack
    /// Shader effects may run (metallib present and allowed).
    let shaders: Bool
    /// The Mac is on the lock screen: keep big chrome clear of the clock.
    let locked: Bool
    /// Rendering a still (previews): skip `.onAppear` entrances.
    let still: Bool
    /// Live spectrum and options for the Orbital style (nil for every other style, and in previews).
    let orbital: OrbitalInput?
    let cursor: LineCursor

    init(lyrics: TimedLyrics, position: Double, clock: Double, canvas: CGSize, bandHeight: CGFloat, bandCenterY: CGFloat,
         textScale: CGFloat, palette: LyricPalette, font: LyricFont, track: LyricTrack, shaders: Bool, locked: Bool, still: Bool = false,
         orbital: OrbitalInput? = nil) {
        self.lyrics = lyrics; self.position = position; self.clock = clock; self.canvas = canvas
        self.bandHeight = bandHeight; self.bandCenterY = bandCenterY; self.textScale = textScale
        self.palette = palette; self.font = font; self.track = track; self.shaders = shaders && ShaderSupport.available
        self.locked = locked; self.still = still; self.orbital = orbital
        self.cursor = lyrics.cursor(at: position)
    }

    // MARK: Lines

    var groupIndex: Int? { cursor.index }
    var group: [TimedWord] { groupIndex.map { lyrics.groups[$0] } ?? [] }

    func group(_ i: Int) -> [TimedWord] { lyrics.groups.indices.contains(i) ? lyrics.groups[i] : [] }
    func lineText(_ i: Int) -> String { lyrics.lineText(i) }

    /// When line `i` takes over the screen (`TimedLyrics.cursor` switches 0.35 s before its first word).
    func lineOnset(_ i: Int) -> Double { (group(i).first?.start ?? 0) - 0.35 }
    func lineStart(_ i: Int) -> Double { group(i).first?.start ?? 0 }
    func lineEnd(_ i: Int) -> Double { group(i).last?.end ?? 0 }

    /// Lines to draw with their opacity: the current one fading in (and out after it ends), and the
    /// previous one fading out underneath it.
    func visibleGroups(fade: Double = 0.35) -> [(index: Int, alpha: Double)] {
        var out: [(Int, Double)] = []
        let current = groupIndex
        let reference = current ?? cursor.next.map { $0 - 1 } ?? (lyrics.groups.count - 1)
        if let c = current {
            let fadeIn = Motion.smooth((position - lineOnset(c)) / fade)
            let fadeOut = Motion.smooth((lineEnd(c) + 2.5 - position) / fade)
            if c > 0 {
                let prevGone = lineEnd(c - 1) + 2.5 < lineOnset(c)
                if !prevGone, fadeIn < 1 { out.append((c - 1, 1 - fadeIn)) }
            }
            out.append((c, min(fadeIn, fadeOut)))
        } else if reference >= 0, reference < lyrics.groups.count {
            // In a gap: the last line finishes fading out.
            let a = Motion.smooth((lineEnd(reference) + 2.5 - position) / fade)
            if a > 0 { out.append((reference, a)) }
        }
        return out
    }

    // MARK: Words

    func progress(_ w: TimedWord) -> Double {
        if w.duration <= 0.001 { return position >= w.start ? 1 : 0 }
        return min(1, max(0, (position - w.start) / w.duration))
    }

    func arrived(_ w: TimedWord) -> Bool { position >= w.start }

    /// `start <= position <= end` (very short words stay lit for at least 0.12 s).
    func isActive(_ w: TimedWord) -> Bool { position >= w.start && position <= max(w.end, w.start + 0.12) }

    /// Index into `lyrics.words` of the last word that has started.
    var activeWordIndex: Int? {
        let words = lyrics.words
        var lo = 0, hi = words.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 ? found : nil
    }

    /// Words of line `i` that have arrived.
    func arrivedWords(_ i: Int) -> [TimedWord] { group(i).filter(arrived) }

    /// Signature of the loaded song, for per-song plan caches.
    var songKey: String { "\(lyrics.source)|\(lyrics.words.count)|\(lyrics.firstOnset)|\(lyrics.lastEnd)|\(lyrics.words.first?.text ?? "")" }
}

// MARK: - Motion math

enum Motion {
    /// Step response of SwiftUI's `.spring(response:dampingFraction:)` at `t` seconds after it starts
    /// (0 → 1, overshooting when underdamped). Lets Canvas scenes animate statelessly from timestamps.
    static func spring(_ t: Double, response: Double = 0.25, damping: Double = 0.70) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let z = damping
        if z < 1 {
            let wd = w0 * sqrt(1 - z * z)
            return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
        }
        return 1 - exp(-w0 * t) * (1 + w0 * t)
    }

    /// Time derivative of `spring` (per second), for motion-blur velocities.
    static func springVelocity(_ t: Double, response: Double = 0.25, damping: Double = 0.70) -> Double {
        let h = 1.0 / 240
        return (spring(t + h, response: response, damping: damping) - spring(t - h, response: response, damping: damping)) / (2 * h)
    }

    static let standard = Animation.spring(response: 0.25, dampingFraction: 0.70)
    static let iconArrival = Animation.spring(response: 0.30, dampingFraction: 0.25)

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x)); return t * t * (3 - 2 * t)
    }

    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    /// Deterministic 0…1 hash.
    static func hash(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    static func hash(_ a: Int, _ b: Int) -> Double { hash(a &* 73_856_093 ^ b &* 19_349_663) }

    /// -1…1.
    static func signedHash(_ a: Int, _ b: Int) -> Double { hash(a, b) * 2 - 1 }

    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return Int(truncatingIfNeeded: h)
    }
}

// MARK: - Canvas helpers

extension GraphicsContext {
    /// Draws a single line of text anchored at `point`.
    func text(_ string: String, font: Font, color: Color, at point: CGPoint, anchor: UnitPoint = .center) {
        draw(Text(string).font(font).foregroundColor(color), at: point, anchor: anchor)
    }

    /// Same, with a soft colored bloom behind it.
    func glowingText(_ string: String, font: Font, color: Color, glow: Color, radius: CGFloat, at point: CGPoint, anchor: UnitPoint = .center) {
        var c = self
        c.addFilter(.shadow(color: glow, radius: radius))
        c.text(string, font: font, color: color, at: point, anchor: anchor)
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    func lerp(_ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: x + (b.x - x) * CGFloat(t), y: y + (b.y - y) * CGFloat(t)) }
    func distance(_ b: CGPoint) -> CGFloat { hypot(b.x - x, b.y - y) }
}

/// Caches one value per song (plans are built once, then only read every frame).
final class PlanCache<Value> {
    private var key = ""
    private var value: Value?
    private let lock = NSLock()

    func value(for key: String, build: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        if key == self.key, let value { return value }
        let v = build()
        self.key = key
        value = v
        return v
    }
}
