import Foundation
import simd

/// Smooth 1D gradient noise (Perlin-style) used for camera shake: continuous and band-limited, so the
/// shake feels like a physical handheld camera instead of random jitter.
enum Perlin {
    private static func hash(_ i: Int, _ seed: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 374761393 &+ seed &* 668265263)
        x = (x ^ (x >> 13)) &* 1274126177
        x ^= x >> 16
        return Double(x % 20_000) / 10_000 - 1     // -1…1 gradient
    }

    static func noise(_ t: Double, seed: Int) -> Double {
        let i = Int(floor(t))
        let f = t - Double(i)
        let u = f * f * f * (f * (f * 6 - 15) + 10)    // quintic fade
        let g0 = hash(i, seed) * f
        let g1 = hash(i + 1, seed) * (f - 1)
        return (g0 + (g1 - g0) * u) * 2
    }
}

/// Critically damped 3D spring (stiffness 170, damping 20 by default).
struct Spring3 {
    var value = SIMD3<Double>(repeating: 0)
    var velocity = SIMD3<Double>(repeating: 0)

    mutating func step(to target: SIMD3<Double>, dt: Double, stiffness: Double = 170, damping: Double = 20) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
            remaining -= h
        }
    }
}

struct Spring1 {
    var value = 0.0
    var velocity = 0.0

    mutating func step(to target: Double, dt: Double, stiffness: Double = 170, damping: Double = 20) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
            remaining -= h
        }
    }
}

/// Camera basis for one frame (world space, right-handed: +x right, +y up, +z away from the viewer).
struct CameraFrame {
    var position = SIMD3<Float>(0, 0, -1000)
    var right = SIMD3<Float>(1, 0, 0)
    var up = SIMD3<Float>(0, 1, 0)
    var forward = SIMD3<Float>(0, 0, 1)
    /// Distance to the plane that is in sharp focus.
    var focusDistance: Float = 1000
    /// Focal length in pixels (perspective scale at distance z is `focal / z`).
    var focal: Float = 1000

    func depth(of p: SIMD3<Float>) -> Float { simd_dot(p - position, forward) }

    /// DoF: perspective already scales words by `focal / (focal + z)`-style falloff; this adds the
    /// matching soften/fade for things in front of or behind the focal plane.
    func dof(depth z: Float, range: Float = 900) -> (blur: Float, fade: Float) {
        let d = min(abs(z - focusDistance) / range, 1)
        return (d, 1 - 0.55 * d * d)
    }
}

/// Shared cinematic rig for every 3D style: spring-damper tracking of a focus target with look-ahead,
/// trauma-based shake, banking, and impulse springs for kicks (dolly, pitch, roll, yaw).
final class CinematicCamera3D {
    // Tracking springs.
    private var position = Spring3()
    private var lookAt = Spring3()
    private var bank = Spring1()
    private var dolly = Spring1()
    private var pitchKick = Spring1()
    private var yawKick = Spring1()
    private var rollKick = Spring1()
    private var primed = false

    /// 0…1. Shake amplitude is `trauma²`; it decays over about a second.
    private(set) var trauma = 0.0
    private var shakeTime = 0.0
    private let shakeSeed: Int

    init(seed: Int = 7) { shakeSeed = seed }

    func reset() {
        position = Spring3(); lookAt = Spring3()
        bank = Spring1(); dolly = Spring1(); pitchKick = Spring1(); yawKick = Spring1(); rollKick = Spring1()
        trauma = 0; primed = false
    }

    // MARK: Inputs

    func addTrauma(_ amount: Double) { trauma = min(1, trauma + amount) }

    /// One-shot kicks that spring back: forward dolly (negative = toward the scene), pitch/yaw/roll in radians.
    func kick(dolly d: Double = 0, pitch: Double = 0, yaw: Double = 0, roll: Double = 0) {
        dolly.velocity += d * 14
        pitchKick.velocity += pitch * 14
        yawKick.velocity += yaw * 14
        rollKick.velocity += roll * 14
    }

    /// Instantly place the rig (first frame, style switch).
    func snap(position p: SIMD3<Double>, lookAt l: SIMD3<Double>) {
        position = Spring3(value: p); lookAt = Spring3(value: l)
        primed = true
    }

    /// Advances the rig. `target`/`lookAhead` are the active word and the next one; the camera look point
    /// leans toward the next word by `anticipation` (0…1).
    func update(dt: Double, position desiredPosition: SIMD3<Double>, target: SIMD3<Double>, lookAhead: SIMD3<Double>,
                anticipation: Double, bank bankTarget: Double, bass: Double, vocalSpike: Double) {
        let look = target + (lookAhead - target) * anticipation
        if !primed { snap(position: desiredPosition, lookAt: look) }
        position.step(to: desiredPosition, dt: dt)
        lookAt.step(to: look, dt: dt)
        bank.step(to: bankTarget, dt: dt, stiffness: 60, damping: 11)
        dolly.step(to: 0, dt: dt, stiffness: 90, damping: 11)
        pitchKick.step(to: 0, dt: dt, stiffness: 90, damping: 11)
        yawKick.step(to: 0, dt: dt, stiffness: 90, damping: 11)
        rollKick.step(to: 0, dt: dt, stiffness: 90, damping: 11)

        // Trauma comes from bass kicks and vocal spikes (semantic impacts call addTrauma directly).
        trauma = max(0, trauma - dt * 0.9)
        if bass > 0.82 { trauma = max(trauma, 0.12 + 0.18 * (bass - 0.82) / 0.18) }
        if vocalSpike > 0.85 { trauma = max(trauma, 0.1) }
        shakeTime += dt
    }

    /// The camera for this frame, with shake and impulse offsets applied.
    func frame(viewport: SIMD2<Float>, fovFocal: Float) -> CameraFrame {
        let shake = trauma * trauma
        let t = shakeTime * 9
        let nx = Perlin.noise(t, seed: shakeSeed), ny = Perlin.noise(t + 31.7, seed: shakeSeed + 1)
        let nr = Perlin.noise(t + 77.1, seed: shakeSeed + 2), np = Perlin.noise(t + 120.3, seed: shakeSeed + 3)
        let nyaw = Perlin.noise(t + 200.9, seed: shakeSeed + 4)

        var pos = position.value
        let toLook = lookAt.value - pos
        var fwd = simd_normalize(toLook.x == 0 && toLook.y == 0 && toLook.z == 0 ? SIMD3<Double>(0, 0, 1) : toLook)
        let distance = simd_length(toLook)
        pos -= fwd * dolly.value * 60

        // Build the basis, then rotate it by bank + shake.
        let worldUp = SIMD3<Double>(0, 1, 0)
        var right = simd_normalize(simd_cross(worldUp, fwd))
        var up = simd_cross(fwd, right)
        let roll = bank.value + rollKick.value + shake * 0.06 * nr
        let pitch = pitchKick.value + shake * 0.045 * np
        let yaw = yawKick.value + shake * 0.045 * nyaw
        func rotate(_ v: SIMD3<Double>, axis: SIMD3<Double>, angle: Double) -> SIMD3<Double> {
            let c = cos(angle), s = sin(angle)
            return v * c + simd_cross(axis, v) * s + axis * simd_dot(axis, v) * (1 - c)
        }
        fwd = rotate(fwd, axis: up, angle: yaw); right = rotate(right, axis: up, angle: yaw)
        fwd = rotate(fwd, axis: right, angle: -pitch); up = rotate(up, axis: right, angle: -pitch)
        right = rotate(right, axis: fwd, angle: roll); up = rotate(up, axis: fwd, angle: roll)
        pos += right * shake * 26 * nx + up * shake * 26 * ny

        var f = CameraFrame()
        f.position = SIMD3<Float>(pos)
        f.right = SIMD3<Float>(right); f.up = SIMD3<Float>(up); f.forward = SIMD3<Float>(fwd)
        f.focusDistance = Float(max(distance, 200))
        f.focal = fovFocal
        _ = viewport
        return f
    }
}
