import SwiftUI
import simd

/// Constellation: words are glowing 3D star coordinates scattered along a winding flight path through a
/// parallax starfield. Filaments trace through space from word to word as they are sung, with faint
/// triangulated struts to neighbors; the cinematic camera flies the path, banking on turns, and each active
/// word ignites with an optical star-cross flare.
final class ConstellationScene3D: Scene3D {
    /// Constellation 3D: extra parallax star shells, stronger banking toward the active star, bass-breathing halos.
    private let deep: Bool
    init(icons: Bool, deep: Bool) { self.deep = deep; super.init(icons: icons, seed: deep ? 17 : 7) }
    convenience init(icons: Bool) { self.init(icons: icons, deep: false) }
    private var nodes: [V3] = []
    private var dirs: [V3] = []
    private var yaws: [Double] = []
    private var pitches: [Double] = []

    override func reset() { super.reset(); nodes = []; dirs = []; yaws = []; pitches = [] }

    private func ensure(_ index: Int, _ words: [TimedWord]) {
        while nodes.count <= index {
            let i = nodes.count
            guard i > 0 else { nodes.append(.zero); dirs.append(V3(0, 0, 1)); yaws.append(0); pitches.append(0); continue }
            let newLine = words[i].line != words[i - 1].line
            var yaw = yaws[i - 1] + (CanvasKit.hash(i * 7 + 1) - 0.5) * (newLine ? 1.6 : 0.9)
            yaw -= yaw * 0.14
            var pitch = pitches[i - 1] + (CanvasKit.hash(i * 13 + 5) - 0.5) * 1.5
            pitch -= pitch * 0.12
            yaw = max(-1.2, min(1.2, yaw)); pitch = max(-0.95, min(0.95, pitch))
            let d = V3(Float(sin(yaw) * cos(pitch)), Float(sin(pitch)), Float(cos(yaw) * cos(pitch)))
            let len = Float(250 + 120 * CanvasKit.hash(i * 17 + 3) + (newLine ? 130 : 0))
            nodes.append(nodes[i - 1] + d * len)
            dirs.append(d); yaws.append(yaw); pitches.append(pitch)
        }
    }

    private func anchor(_ i: Int) -> SemanticKineticEngine.Anchor? {
        guard nodes.indices.contains(i) else { return nil }
        return .init(center: nodes[i] + V3(0, 70, 0), halfWidth: 90, unit: 78)
    }

    override func update(_ input: SceneInput, dt: Double) {
        let words = input.lyrics.words
        guard !words.isEmpty else { return }
        let a = input.activeWord ?? 0
        ensure(min(words.count - 1, a + 20), words)
        let node = SIMD3<Double>(nodes[a])
        let next = a + 1 < nodes.count ? SIMD3<Double>(nodes[a + 1]) : node
        let d = SIMD3<Double>(dirs[a])
        let side = simd_normalize(simd_cross(d, SIMD3<Double>(0, 1, 0)))
        let scale = max(0.5, input.theme.scale)
        let desired = node - d * (220 / scale) + side * ((1000 + 160 * sin(input.time * 0.19)) / scale) + SIMD3(0, 170, 0)
        let turn = a > 0 ? yaws[a] - yaws[a - 1] : 0
        let progress = input.activeWord.map { CanvasKit.smoothstep(input.progress(words[$0])) } ?? 0
        camera.update(dt: dt, position: desired, target: node, lookAhead: next, anticipation: progress * 0.6,
                      bank: max(-0.5, min(0.5, -turn * (deep ? 0.9 : 0.35))), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i) }, camera: camera)
    }

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        let words = input.lyrics.words
        guard !words.isEmpty, !nodes.isEmpty else { return }
        let hl = highlight(input), sec = secondary(input)
        let activeIndex = input.activeWord
        let a = activeIndex ?? 0
        let lo = max(0, a - 10), hi = min(words.count - 1, a + 16)
        let right = frame.right, up = frame.up

        // Parallax starfield: seeded stars around every visible node (true 3D depth), breathing with the bass.
        for i in lo...hi {
            for k in 0..<9 {
                let seed = i * 53 + k
                let off = V3(hash(seed * 3 + 1) - 0.5, hash(seed * 3 + 2) - 0.5, hash(seed * 3 + 3) - 0.5) * 1500
                let tw = 0.65 + 0.35 * sin(Float(input.time) * (0.8 + hash(seed) * 2) + Float(k))
                let r = (5 + 9 * hash(seed + 9)) * (1 + 0.8 * Float(input.bass))
                list.sprite(.glow, at: nodes[i] + off, radius: r, color: V4(1, 1, 1, (0.25 + 0.5 * hash(seed + 5)) * tw), extra: 2.4, camera: frame)
            }
        }

        if deep {
            // Three star shells at different depths. Far shells ride with the camera (small parallax),
            // near shells stay in the world, so the field slides past at different speeds as the camera flies.
            let cam = frame.position
            for (shell, (radius, follow, size)) in [(1800 as Float, 0.92 as Float, 10 as Float), (3000, 0.65, 15), (4600, 0.3, 22)].enumerated() {
                for k in 0..<42 {
                    let seed = shell * 977 + k * 31
                    let dir = simd_normalize(V3(hash(seed + 1) - 0.5, hash(seed + 2) - 0.5, hash(seed + 3) - 0.5) + V3(0, 0, 0.0001))
                    let tw = 0.6 + 0.4 * sin(Float(input.time) * (0.6 + hash(seed) * 1.8) + Float(k))
                    list.sprite(.glow, at: cam * follow + dir * radius, radius: size * (1 + 0.6 * Float(input.bass)), color: V4(1, 1, 1, (0.45 + 0.5 * hash(seed + 5)) * tw), extra: 2.4, camera: frame)
                }
            }
        }

        // Dark plume behind the active label.
        let activeCenter = nodes[a] + up * 70
        list.sprite(.plume, at: activeCenter, radius: 150, color: V4(0.03, 0.03, 0.047, 1), extra: 0.78, stretch: 2.2, layer: .back, camera: frame)

        // Filaments and struts.
        for i in max(1, lo)...max(1, hi) where i < nodes.count && i > 0 {
            let from = i - 1
            let traced: Double
            if activeIndex == nil { traced = 0 }
            else if from < a { traced = 1 }
            else if from == a { traced = CanvasKit.smoothstep(input.progress(words[a])) }
            else { traced = 0 }
            let p0 = nodes[from], p1 = nodes[i]
            let mid = (p0 + p1) * 0.5
            let px = perPixel(frame.depth(of: mid), frame)
            // Faint skeleton for what is still to come.
            ribbonU(list, from: p0, to: p1, width: 2.0 * px, color: V4(hl.x, hl.y, hl.z, 0.32), glow: 0.3, camera: frame)
            if i >= 2 {
                ribbonU(list, from: nodes[i - 2], to: p1, width: 1.6 * px, color: V4(sec.x, sec.y, sec.z, 0.5), glow: 0.3, camera: frame)
            }
            if i >= 3, simd_length(nodes[i - 3] - p1) < 1100 {
                ribbonU(list, from: nodes[i - 3], to: p1, width: 1.3 * px, color: V4(hl.x, hl.y, hl.z, 0.34), glow: 0.2, camera: frame)
            }
            guard traced > 0.001 else { continue }
            let live = from == a
            let end = p0 + (p1 - p0) * Float(traced)
            let age = Float(max(0, a - from))
            let alpha: Float = live ? 0.95 : max(0.3, 0.62 - age * 0.03)
            let width = (live ? 2.6 : 1.5) * px
            let col = from % 2 == 0 ? hl : sec
            // Dark underlay so the luminous filament stays visible over a bright wallpaper.
            ribbonU(list, from: p0, to: end, width: width * 3.0, color: V4(0, 0, 0, live ? 0.42 : 0.3), glow: 0, layer: .back, camera: frame)
            ribbonU(list, from: p0, to: end, width: width * 1.6, color: V4(col.x, col.y, col.z, alpha), glow: live ? 1.2 : 0.5, camera: frame)
            if live {
                list.sprite(.glow, at: end, radius: 26, color: V4(hl.x, hl.y, hl.z, 0.95), extra: 2, camera: frame)
            }
        }

        // Nodes, flares and labels.
        let focus = frame.focusDistance
        for i in lo...hi {
            let p = nodes[i]
            let word = words[i]
            let isActive = i == a && activeIndex != nil
            let past = activeIndex != nil && i < a
            let age = Float(max(0, input.pos - word.start))
            let depth = frame.depth(of: p)
            let dof = frame.dof(depth: depth, range: 1400)
            let nodeAlpha: Float = isActive ? 1 : (past ? 0.35 : 0.2)
            let breathe: Float = deep ? 1 + 0.55 * Float(input.bass) : 1
            list.sprite(.glow, at: p, radius: (isActive ? 64 : 40) * breathe, color: V4(hl.x, hl.y, hl.z, nodeAlpha * 0.8), extra: 2, camera: frame)
            list.sprite(.glow, at: p, radius: 10 + 4 * Float(input.bass), color: V4(1, 1, 1, min(1, nodeAlpha * 1.5)), extra: 1.6, camera: frame)
            if isActive || (past && age < 1.4) {
                let f = exp(-age * 3)
                list.sprite(.flare, at: p, radius: 80 + 190 * f, color: V4(hl.x, hl.y, hl.z, min(1, 0.4 + f)), camera: frame)
            }

            let mod = engine.wordMod(index: i, input: input, isActive: isActive)
            let side: Float = hash(i * 31 + 2) < 0.5 ? -1 : 1
            let height: Float = isActive ? 84 : 52
            let labelCenter = p + up * (isActive ? 78 : side * (height * 0.95))
            var color = V4(1, 1, 1, isActive ? 1 : (past ? 0.42 : 0.18))
            color.w *= dof.fade
            let blur: Float = (isActive || past) ? 0 : 1.5 + min(2.5, dof.blur)
            list.sprite(.plume, at: labelCenter, radius: height * 0.8, color: V4(0, 0, 0, 1), extra: isActive ? 0.6 : 0.3, stretch: 2.4, layer: .back, camera: frame)
            drawWord(word.text, at: labelCenter, height: height, right: right, up: up, color: color, mod: mod, blur: blur,
                     atlas: atlas, input: input, list: list, frame: frame)
            _ = focus
        }
        engine.draw(into: list, camera: frame)
    }
}
