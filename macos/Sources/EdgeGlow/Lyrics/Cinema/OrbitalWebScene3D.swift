import SwiftUI
import simd

/// Orbital Web 3D: the polar spoke-and-ring web as a holographic gyroscope disc. The disc banks toward
/// the currently sung (spoke, ring) intersection, turns so that spoke faces the viewer, and bass
/// transients ripple outward through the rings. Words sit on the intersections; a light travels along the
/// thread from each sung word to the next.
final class OrbitalWebScene3D: Scene3D {
    private let geo = OrbitalGeometry(spokes: 8, rings: 4, innerRadius: 300, ringStep: 260)
    private var rotation = 0.0
    private var rotationPrimed = false
    private var ripple = 0.0
    private var lastBass = 0.0
    private var rippleClock = -10.0

    override func reset2() { rotationPrimed = false; ripple = 0; rippleClock = -10 }

    private func nodePoint(_ i: Int) -> V3 {
        let s = geo.slot(i)
        let p = geo.point(spoke: s.spoke, ring: s.ring, rotation: rotation)
        return V3(Float(p.x), 0, Float(p.z))
    }

    private func anchor(_ i: Int) -> SemanticKineticEngine.Anchor? {
        .init(center: nodePoint(i) + V3(0, 34, 0), halfWidth: 70, unit: 56)
    }

    override func update(_ input: SceneInput, dt: Double) {
        let words = input.lyrics.words
        guard !words.isEmpty else { return }
        let a = input.activeWord ?? 0
        let s = geo.slot(a)
        // Turn the disc so the active spoke faces the viewer (shortest way round, eased).
        let wanted = geo.rotationFacing(spoke: s.spoke)
        if !rotationPrimed { rotation = wanted; rotationPrimed = true }
        var delta = (wanted - rotation).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        rotation += delta * (1 - exp(-dt * 2.6))

        // Bass transient → a ripple that travels outward through the rings.
        if input.bass > 0.55, lastBass <= 0.55, input.time - rippleClock > 0.25 { rippleClock = input.time }
        lastBass = input.bass

        let scale = max(0.5, input.theme.scale)
        let node = SIMD3<Double>(SIMD3<Float>(nodePoint(a)))
        let tilt = 0.50 + 0.06 * sin(input.time * 0.33)          // viewing elevation of the disc
        let dist = 1500 / scale
        // Bank: slide sideways with the active node so the disc visibly rolls toward it.
        let side = node.x * 0.35
        let desired = SIMD3(side, dist * sin(tilt), dist * cos(tilt))
        let progress = input.activeWord.map { CanvasKit.smoothstep(input.progress(words[$0])) } ?? 0
        let next = a + 1 < words.count ? SIMD3<Double>(SIMD3<Float>(nodePoint(a + 1))) : node
        camera.update(dt: dt, position: desired, target: node * 0.55, lookAhead: next * 0.55, anticipation: progress * 0.5,
                      bank: max(-0.3, min(0.3, -node.x / 1400)), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i) }, camera: camera)
    }

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        let words = input.lyrics.words
        guard !words.isEmpty else { return }
        let hl = highlight(input), sec = secondary(input)
        let activeIndex = input.activeWord
        let a = activeIndex ?? 0
        let lo = max(0, a - 12), hi = min(words.count - 1, a + 12)
        let t = Float(input.time)
        let rippleAge = Float(input.time - rippleClock)

        // Soft dark vignette under the disc so thin lines stay readable on any wallpaper.
        list.sprite(.plume, at: V3(0, -6, 0), radius: Float(geo.outerRadius) * 1.1, color: V4(0, 0, 0, 1), extra: 0.2, stretch: 1.0, layer: .back, camera: frame)

        // Spokes.
        for sp in 0..<geo.spokes {
            let ang = geo.angle(spoke: sp) + rotation
            let dir = V3(Float(cos(ang)), 0, Float(sin(ang)))
            let lit = (lo...hi).contains { geo.slot($0).spoke == sp && input.pos >= words[$0].start && activeIndex != nil }
            let from = dir * Float(geo.innerRadius * 0.4), to = dir * Float(geo.outerRadius)
            let px = perPixel(frame.depth(of: (from + to) * 0.5), frame)
            let c: V4 = lit ? V4(hl.x, hl.y, hl.z, 0.8) : V4(1, 1, 1, 0.42)
            list.ribbon(from: from, to: to, width: (lit ? 2.0 : 1.4) * px, color: c, glow: lit ? 0.7 : 0.2, camera: frame)
        }

        // Rings: 72-segment polylines with a bass ripple that raises each ring in turn.
        for r in 0..<geo.rings {
            let radius = Float(geo.radius(ring: r))
            let lit = (lo...hi).contains { geo.slot($0).ring == r && input.pos >= words[$0].start && activeIndex != nil }
            let wave = max(0, 1 - abs(rippleAge * 1.6 - Float(r)) * 1.3)
            let lift = 26 * wave * Float(max(0.2, input.bass))
            var prev: V3?
            for k in 0...72 {
                let ang = Float(k) / 72 * 2 * .pi
                let p = V3(cos(ang) * radius, lift * sin(ang * 4 + t), sin(ang) * radius)
                if let q = prev {
                    let px = perPixel(frame.depth(of: (p + q) * 0.5), frame)
                    let c: V4 = lit ? V4(sec.x, sec.y, sec.z, 0.7 + 0.3 * wave) : V4(1, 1, 1, 0.38 + 0.4 * wave)
                    list.ribbon(from: q, to: p, width: (lit ? 2.0 : 1.4) * px, color: c, glow: 0.2 + wave, camera: frame)
                }
                prev = p
            }
        }

        // Thread from each sung word to the next, with a light traveling along the live one.
        for i in max(1, lo)...max(1, hi) where i < words.count {
            let from = i - 1
            guard activeIndex != nil, from <= a else { continue }
            let traced = from < a ? 1 : Double(CanvasKit.smoothstep(input.progress(words[a])))
            let p0 = nodePoint(from), p1 = nodePoint(i)
            let end = p0 + (p1 - p0) * Float(traced)
            let px = perPixel(frame.depth(of: (p0 + end) * 0.5), frame)
            let live = from == a
            list.ribbon(from: p0, to: end, width: (live ? 2.6 : 1.4) * px, color: V4(hl.x, hl.y, hl.z, live ? 0.95 : 0.45), glow: live ? 1.2 : 0.4, camera: frame)
            if live { list.sprite(.glow, at: end, radius: 24, color: V4(hl.x, hl.y, hl.z, 0.95), extra: 2, camera: frame) }
        }

        // Nodes and labels (labels face the camera so type stays razor-flat and legible).
        let right = frame.right, up = frame.up
        for i in lo...hi {
            let p = nodePoint(i)
            let isActive = i == a && activeIndex != nil
            let past = activeIndex != nil && i < a
            let age = Float(max(0, input.pos - words[i].start))
            let depth = frame.depth(of: p)
            let dof = frame.dof(depth: depth, range: 1500)
            let nodeAlpha: Float = isActive ? 1 : (past ? 0.4 : 0.2)
            list.sprite(.glow, at: p, radius: (isActive ? 56 : 30) * (1 + 0.4 * Float(input.bass)), color: V4(hl.x, hl.y, hl.z, nodeAlpha * 0.7), extra: 2, camera: frame)
            list.sprite(.glow, at: p, radius: 9, color: V4(1, 1, 1, min(1, nodeAlpha * 1.6)), extra: 1.6, camera: frame)
            if isActive || (past && age < 1.4) {
                let f = exp(-age * 3)
                list.sprite(.flare, at: p, radius: 70 + 150 * f, color: V4(hl.x, hl.y, hl.z, min(1, 0.4 + f)), camera: frame)
            }
            let mod = engine.wordMod(index: i, input: input, isActive: isActive)
            let height: Float = isActive ? 84 : 52
            let center = p + up * (isActive ? 62 : 44)
            var color = V4(1, 1, 1, isActive ? 1 : (past ? 0.42 : 0.18))
            color.w *= dof.fade
            list.sprite(.plume, at: center, radius: height * 0.8, color: V4(0, 0, 0, 1), extra: isActive ? 0.34 : 0.1, stretch: 2.4, layer: .back, camera: frame)
            drawWord(words[i].text, at: center, height: height, right: right, up: up, color: color, mod: mod,
                     blur: (isActive || past) ? 0 : 1.5 + min(2.5, dof.blur), atlas: atlas, input: input, list: list, frame: frame)
        }
        engine.draw(into: list, camera: frame)
    }
}
