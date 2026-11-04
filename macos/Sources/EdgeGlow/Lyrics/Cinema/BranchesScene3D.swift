import SwiftUI
import simd

/// Branches: a 3D neural tree. Each word sprouts from the previous one along a glowing cubic Bézier spline
/// that twists through depth and forks into twigs. The camera rides the growing tip; sung words stay along
/// the illuminated branch and recede into depth-of-field blur.
final class BranchesScene3D: Scene3D {
    private var nodes: [V3] = []
    private var dirs: [V3] = []
    private var lens: [Float] = []

    override func reset() { super.reset(); nodes = []; dirs = []; lens = [] }

    private func ensure(_ index: Int, _ words: [TimedWord]) {
        while nodes.count <= index {
            let i = nodes.count
            guard i > 0 else { nodes.append(.zero); dirs.append(V3(0, 0.15, 1)); lens.append(0); continue }
            let prev = dirs[i - 1]
            let wobble = V3(Float(CanvasKit.hash(i * 11 + 3) - 0.5), Float(CanvasKit.hash(i * 19 + 7) - 0.5) * 1.6, Float(0.15)) * 1.5
            var d = simd_normalize(prev + wobble)
            // Soft pull back toward the middle so the tree stays in frame.
            d.y -= nodes[i - 1].y * 0.0006
            d = simd_normalize(d)
            let len = Float(230 + 100 * CanvasKit.hash(i * 17 + 9))
            nodes.append(nodes[i - 1] + d * len)
            dirs.append(d); lens.append(len)
        }
    }

    private struct Cubic {
        var p0, c1, c2, p1: V3
        func point(_ t: Float) -> V3 {
            let u = 1 - t
            return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
        }
    }

    private func segment(_ i: Int) -> Cubic {
        let p0 = nodes[i - 1], p1 = nodes[i], len = lens[i]
        return Cubic(p0: p0, c1: p0 + dirs[i - 1] * len * 0.5, c2: p1 - dirs[i] * len * 0.5, p1: p1)
    }

    private func growth(_ i: Int, words: [TimedWord], pos: Double) -> Double {
        let end = words[i].start
        let begin = max(words[i - 1].start, end - 1.3)
        guard end > begin else { return pos >= end ? 1 : 0 }
        return CanvasKit.smoothstep((pos - begin) / (end - begin))
    }

    private func tip(_ input: SceneInput) -> (index: Int, point: V3) {
        let words = input.lyrics.words
        let g = min(words.count - 1, (input.activeWord ?? -1) + 1)
        guard g >= 1, nodes.indices.contains(g) else { return (0, nodes.first ?? .zero) }
        return (g, segment(g).point(Float(growth(g, words: words, pos: input.pos))))
    }

    private func anchor(_ i: Int) -> SemanticKineticEngine.Anchor? {
        guard nodes.indices.contains(i) else { return nil }
        return .init(center: nodes[i] + V3(0, 70, 0), halfWidth: 90, unit: 78)
    }

    override func update(_ input: SceneInput, dt: Double) {
        let words = input.lyrics.words
        guard !words.isEmpty else { return }
        let a = input.activeWord ?? -1
        ensure(min(words.count - 1, a + 14), words)
        let (g, tipPoint) = tip(input)
        let d = SIMD3<Double>(dirs[min(g, dirs.count - 1)])
        let target = SIMD3<Double>(tipPoint)
        let side = simd_normalize(simd_cross(d, SIMD3<Double>(0, 1, 0)))
        let scale = max(0.5, input.theme.scale)
        let desired = target - d * (240 / scale) + side * ((1100 + 140 * sin(input.time * 0.17)) / scale) + SIMD3(0, 160, 0)
        let next = g + 1 < nodes.count ? SIMD3<Double>(nodes[g + 1]) : target
        camera.update(dt: dt, position: desired, target: target, lookAhead: next, anticipation: 0.3,
                      bank: 0.08 * sin(input.time * 0.35), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i) }, camera: camera)
    }

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        let words = input.lyrics.words
        guard !words.isEmpty, nodes.count > 1 else { return }
        let hl = highlight(input), sec = secondary(input)
        let a = input.activeWord ?? -1
        let (g, tipPoint) = tip(input)
        let right = frame.right, up = frame.up
        let lo = max(1, a - 11), hi = min(words.count - 1, g)

        // Dark plume behind the active leaf and the growing tip.
        let focalPoint = a >= 0 ? (nodes[a] + tipPoint) * 0.5 + up * 40 : tipPoint
        list.sprite(.plume, at: focalPoint, radius: 160, color: V4(0, 0, 0, 1), extra: 0.34, stretch: 2.2, layer: .back, camera: frame)

        // Twigs behind the trunk.
        if a >= 0 {
            for i in max(0, a - 9)...a { drawTwigs(i, input: input, list: list, frame: frame, hl: hl, sec: sec) }
        }

        // Trunk splines.
        if lo <= hi {
            for i in lo...hi {
                let growthValue = Float(growth(i, words: words, pos: input.pos))
                guard growthValue > 0.002 else { continue }
                let c = segment(i)
                let live = i == g && growthValue < 0.999
                let recency = Float(exp(-Double(max(0, a - i)) / 3.5))
                let steps = 14
                var prev = c.p0
                for s in 1...steps {
                    let t = Float(s) / Float(steps) * growthValue
                    let q = c.point(t)
                    let px = perPixel(frame.depth(of: (prev + q) * 0.5), frame)
                    let u = Float(s) / Float(steps)
                    let col = hl + (sec - hl) * u
                    let width = (live ? 8 : (2.4 + 4.0 * recency)) * px
                    list.ribbon(from: prev, to: q, width: width * 2.4, color: V4(0, 0, 0, live ? 0.4 : 0.26 + 0.12 * recency), glow: 0, layer: .back, camera: frame)
                    list.ribbon(from: prev, to: q, width: width, color: V4(col.x, col.y, col.z, live ? 1 : 0.4 + 0.55 * recency), glow: live ? 1.4 : 0.6, camera: frame)
                    prev = q
                }
            }
        }
        list.sprite(.glow, at: tipPoint, radius: 38 + 14 * Float(input.bass), color: V4(hl.x, hl.y, hl.z, 0.95), extra: 2, camera: frame)
        list.sprite(.glow, at: tipPoint, radius: 9, color: V4(1, 1, 1, 1), extra: 1.6, camera: frame)

        // Leaves and labels.
        if a >= 0 {
            for i in max(0, a - 10)...a {
                let p = nodes[i]
                let isActive = i == a
                let age = Float(max(0, input.pos - words[i].start))
                let depth = frame.depth(of: p)
                let dof = frame.dof(depth: depth, range: 1500)
                list.sprite(.glow, at: p, radius: isActive ? 60 : 28, color: V4(sec.x, sec.y, sec.z, isActive ? 0.8 : 0.45), extra: 2, camera: frame)
                list.sprite(.glow, at: p, radius: isActive ? 10 : 6, color: V4(1, 1, 1, 0.95), extra: 1.6, camera: frame)
                if isActive || age < 1.2 {
                    list.sprite(.flare, at: p, radius: 60 + 120 * exp(-age * 3), color: V4(hl.x, hl.y, hl.z, 0.7), camera: frame)
                }
                let height: Float = isActive ? 80 : 50
                let side: Float = i % 2 == 0 ? -1 : 1
                let labelCenter = p + up * (isActive ? 86 : side * 56) + right * (isActive ? 0 : 40)
                var color = V4(1, 1, 1, isActive ? 1 : (i < a ? 0.42 : 0.18))
                color.w *= dof.fade
                let mod = engine.wordMod(index: i, input: input, isActive: isActive)
                list.sprite(.plume, at: labelCenter, radius: height * 0.8, color: V4(0, 0, 0, 1), extra: isActive ? 0.34 : 0.12, stretch: 2.4, layer: .back, camera: frame)
                drawWord(words[i].text, at: labelCenter, height: height, right: right, up: up, color: color, mod: mod,
                         blur: (isActive || i < a) ? 0 : 1.5 + min(2.5, dof.blur), atlas: atlas, input: input, list: list, frame: frame)
            }
        }
        // The word the tip is growing toward.
        if g >= 1, g < words.count, g > a {
            let p = nodes[g]
            let t = Float(growth(g, words: words, pos: input.pos))
            drawWord(words[g].text, at: p + up * 64, height: 40, right: right, up: up, color: V4(1, 1, 1, 0.3 + 0.4 * t), blur: 0.1,
                     atlas: atlas, input: input, list: list, frame: frame)
        }
        engine.draw(into: list, camera: frame)
    }

    private func drawTwigs(_ i: Int, input: SceneInput, list: DrawList, frame: CameraFrame, hl: V4, sec: V4) {
        let words = input.lyrics.words
        let age = Float(input.pos - words[i].start)
        let grow = Float(CanvasKit.smoothstep(Double(age) / 0.9))
        guard grow > 0.01 else { return }
        let o = nodes[i]
        let recency = Float(exp(-Double(max(0, (input.activeWord ?? 0) - i)) / 4))
        for k in 0..<2 {
            let side: Float = (i + k) % 2 == 0 ? 1 : -1
            let perp1 = simd_normalize(simd_cross(dirs[i], V3(0, 1, 0)))
            let perp2 = simd_cross(dirs[i], perp1)
            let ang = Float(CanvasKit.hash(i * 19 + k)) * 2 * .pi
            let outward = simd_normalize(perp1 * cos(ang) + perp2 * sin(ang) + dirs[i] * 0.5 * side)
            let len = (130 + 100 * hash(i * 23 + k * 3)) * grow
            let mid = o + outward * len * 0.5 + perp2 * 30
            let end = o + outward * len
            var prev = o
            for s in 1...6 {
                let t = Float(s) / 6
                let u = 1 - t
                let q = o * (u * u) + mid * (2 * u * t) + end * (t * t)
                let px = perPixel(frame.depth(of: q), frame)
                list.ribbon(from: prev, to: q, width: 2.2 * px, color: V4(sec.x, sec.y, sec.z, 0.4 + 0.4 * recency), glow: 0.4, camera: frame)
                prev = q
            }
            list.sprite(.glow, at: end, radius: 12, color: V4(sec.x, sec.y, sec.z, 0.2 + 0.5 * recency), extra: 2, camera: frame)
        }
    }
}
