// Engine/ must stay platform-agnostic: Foundation only (no AppKit, SwiftUI, CoreGraphics, Metal…).
// build.sh enforces this so the math layer can be ported to C#/Windows.
import Foundation

struct Vec2: Equatable, Sendable {
    var x: Double, y: Double
    init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    static let zero = Vec2(0, 0)
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    static func += (a: inout Vec2, b: Vec2) { a = a + b }
    var length: Double { (x * x + y * y).squareRoot() }
    func lerp(to o: Vec2, _ t: Double) -> Vec2 { Vec2(x + (o.x - x) * t, y + (o.y - y) * t) }
}

struct Vec3: Equatable, Sendable {
    var x: Double, y: Double, z: Double
    init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
}

struct Color4: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    func lerp(to o: Color4, _ t: Double) -> Color4 {
        Color4(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }
    func scaled(_ k: Double) -> Color4 { Color4(r * k, g * k, b * k, a) }
}

enum MathX {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func smoothstep(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }

    /// Deterministic hash → 0…1 (identical on every platform; no RNG state).
    static func hash01(_ seed: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15
        x ^= x >> 30; x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27; x = x &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }
    static func hashSigned(_ seed: Int) -> Double { hash01(seed) * 2 - 1 }
}

/// Critically-tunable damped spring on a scalar (semi-implicit Euler, dt-based).
struct SpringScalar: Sendable {
    var value: Double = 0
    var velocity: Double = 0

    mutating func step(toward target: Double, stiffness k: Double, dampingRatio z: Double, dt: Double) {
        let c = 2 * z * k.squareRoot()
        let steps = max(1, Int((dt / 0.008).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let a = k * (target - value) - c * velocity
            velocity += a * h
            value += velocity * h
        }
    }
}
