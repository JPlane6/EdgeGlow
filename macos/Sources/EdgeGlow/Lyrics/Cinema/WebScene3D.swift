import SwiftUI
import simd

/// Web: the active stanza hangs as a 3D tension mesh of spring-driven nodes. When a word is sung or a bass
/// transient hits, the sung node and its connected neighbors are pulled toward the glass in z, and visible
/// shockwave ripples run down the silk threads.
final class WebScene3D: Scene3D {
    private struct Node {
        var pos: V3
        var vel = V3(0, 0, 0)
        var rest: V3
        var alpha: Float = 0
        var halfWidth: Float
    }
    private struct Ripple { var origin: Int; var start: Double; var strength: Float }

    private var nodes: [Int: Node] = [:]
    private var windowLine = -1
    private var edges: [(Int, Int)] = []
    private var adjacency: [Int: [Int]] = [:]
    private var ripples: [Ripple] = []
    private var lastActive = -1
    private var lastBass = 0.0
    private var lastImpulse = 0.0

    override func reset() {
        super.reset(); nodes = [:]; edges = []; adjacency = [:]; ripples = []; windowLine = -1; lastActive = -1
    }

    private let fontSize: Float = 52

    private func relayout(line: Int, lyrics: TimedLyrics, font: LyricFont) {
        windowLine = line
        let lineIDs = [line, line + 1].filter { lyrics.groups.indices.contains($0) }
        var ids: [Int] = []
        var rests: [Int: V3] = [:]
        var widths: [Int: Float] = [:]
        var placed: [(Int, Float, Float)] = []
        var rowY: Float = 0
        let maxRow: Float = 1250
        for (n, li) in lineIDs.enumerated() {
            if n > 0 { rowY += 80 }
            var row: [(TimedWord, Float)] = []
            var rowWidth: Float = 0
            func flush() {
                guard !row.isEmpty else { return }
                var x = -rowWidth / 2
                for (k, (w, cw)) in row.enumerated() {
                    let jitter = (hash(w.id * 5 + 1) - 0.5) * 16
                    let stagger = (k % 2 == 0 ? -1 : 1) * 30 * (hash(w.id * 9 + 2) + 0.4)
                    placed.append((w.id, x + cw / 2 + jitter, rowY + stagger))
                    x += cw + 100
                }
                rowY += 190
                row = []; rowWidth = 0
            }
            for w in lyrics.groups[li] {
                let cw = Float(TextMetrics.shared.width(w.text, font: font, size: CGFloat(fontSize))) + 40
                if rowWidth + cw > maxRow, !row.isEmpty { flush() }
                row.append((w, cw)); rowWidth += cw + (row.count > 1 ? 100 : 0)
                widths[w.id] = cw
                ids.append(w.id)
            }
            flush()
        }
        let height = rowY - 100
        for (id, x, y) in placed {
            rests[id] = V3(x, -(y - height / 2), (hash(id * 7 + 3) - 0.5) * 220)
        }
        for id in ids {
            let rest = rests[id]!
            if var n = nodes[id] {
                n.rest = rest; n.halfWidth = (widths[id] ?? 120) / 2
                nodes[id] = n
            } else {
                let a = hash(id * 3 + 7) * 2 * .pi
                nodes[id] = Node(pos: rest + V3(cos(a) * 240, sin(a) * 180, 220), rest: rest, alpha: 0, halfWidth: (widths[id] ?? 120) / 2)
            }
        }
        for id in Array(nodes.keys) where !ids.contains(id) {
            var n = nodes[id]!
            n.rest = V3(n.rest.x, n.rest.y + 120, n.rest.z + 200)
            nodes[id] = n
        }

        var set = Set<[Int]>()
        func add(_ a: Int, _ b: Int) { if a != b { set.insert([min(a, b), max(a, b)]) } }
        for (k, id) in ids.enumerated() {
            if k > 0 { add(ids[k - 1], id) }
            let near = ids.filter { $0 != id }.sorted { simd_distance(rests[$0]!, rests[id]!) < simd_distance(rests[$1]!, rests[id]!) }
            for other in near.prefix(2) { add(id, other) }
        }
        edges = set.map { ($0[0], $0[1]) }
        adjacency = [:]
        for (a, b) in edges { adjacency[a, default: []].append(b); adjacency[b, default: []].append(a) }
        for (id, n) in nodes where !ids.contains(id) && n.alpha < 0.01 { nodes[id] = nil }
    }

    private func anchor(_ index: Int, input: SceneInput) -> SemanticKineticEngine.Anchor? {
        let id = input.lyrics.words[index].id
        guard let n = nodes[id] else { return nil }
        return .init(center: n.pos, halfWidth: n.halfWidth, unit: fontSize)
    }

    override func update(_ input: SceneInput, dt: Double) {
        let lyrics = input.lyrics
        guard !lyrics.isEmpty else { return }
        let line = input.cursor.index ?? input.cursor.next ?? 0
        if line != windowLine { relayout(line: line, lyrics: lyrics, font: input.theme.font) }
        let windowIDs = Set([line, line + 1].filter { lyrics.groups.indices.contains($0) }.flatMap { lyrics.groups[$0].map(\.id) })
        let active = input.activeWord.map { lyrics.words[$0].id }

        // Impulses: a newly sung word, or a bass transient, pulls the node and its neighbors toward the glass.
        if let active, active != lastActive, nodes[active] != nil {
            lastActive = active
            pull(active, strength: 1, now: input.time)
        }
        let spike = input.bass - lastBass > 0.14 && input.bass > 0.3
        lastBass = input.bass
        if spike, input.time - lastImpulse > 0.2, let active, nodes[active] != nil {
            lastImpulse = input.time
            pull(active, strength: 0.6 + Float(input.bass) * 0.6, now: input.time)
        }

        let h = Float(dt)
        for id in Array(nodes.keys) {
            var n = nodes[id]!
            let inWindow = windowIDs.contains(id)
            n.vel += ((n.rest - n.pos) * 95 - n.vel * 9) * h
            n.pos += n.vel * h
            n.alpha += ((inWindow ? 1 : 0) - n.alpha) * Float(1 - exp(-dt * (inWindow ? 5 : 3)))
            nodes[id] = n
        }
        ripples.removeAll { input.time - $0.start > 2.4 }

        var target = SIMD3<Double>(0, 0, 0)
        if let active, let n = nodes[active] { target = SIMD3<Double>(n.pos) * 0.4 }
        let yaw = 0.45 * sin(input.time * 0.23)
        let pitch = 0.1 * sin(input.time * 0.19)
        let distance = 1050 / max(0.5, input.theme.scale)
        let position = target + SIMD3(distance * sin(yaw), distance * 0.3 * sin(pitch) + 60, -distance * cos(yaw))
        camera.update(dt: dt, position: position, target: target, lookAhead: target, anticipation: 0,
                      bank: 0.03 * sin(input.time * 0.3), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i, input: input) }, camera: camera)
    }

    private func pull(_ id: Int, strength: Float, now: Double) {
        guard var n = nodes[id] else { return }
        n.vel.z -= 520 * strength
        nodes[id] = n
        for other in adjacency[id] ?? [] {
            guard var o = nodes[other] else { continue }
            o.vel.z -= 260 * strength
            o.vel += simd_normalize(n.pos - o.pos + V3(0.001, 0, 0)) * 90 * strength
            nodes[other] = o
        }
        ripples.append(Ripple(origin: id, start: now, strength: strength))
    }

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        let lyrics = input.lyrics
        let hl = highlight(input), sec = secondary(input)
        let right = frame.right, up = frame.up
        let activeIndex = input.activeWord
        let activeID = activeIndex.map { lyrics.words[$0].id }
        let byID = Dictionary(uniqueKeysWithValues: lyrics.words.map { ($0.id, $0) })

        if let activeID, let n = nodes[activeID] {
            list.sprite(.plume, at: n.pos, radius: 240, color: V4(0.03, 0.03, 0.047, 1), extra: 0.78, stretch: 2.1, layer: .back, camera: frame)
        }

        // Silk threads with shockwave ripples racing along them.
        for (a, b) in edges {
            guard let na = nodes[a], let nb = nodes[b] else { continue }
            let alpha = min(na.alpha, nb.alpha)
            guard alpha > 0.02 else { continue }
            let mid = (na.pos + nb.pos) * 0.5
            var wave: Float = 0
            for r in ripples {
                guard let origin = nodes[r.origin] else { continue }
                let t = Float(input.time - r.start)
                let dist = simd_distance(mid, origin.pos)
                let front = 1300 * t
                let d = (dist - front) / 130
                wave += exp(-d * d) * exp(-t * 1.5) * r.strength
            }
            wave = min(wave, 1.6)
            let px = perPixel(frame.depth(of: mid), frame)
            let involves = a == activeID || b == activeID
            let col = (a + b) % 2 == 0 ? hl : sec
            let width = (1.1 + 3.2 * wave + (involves ? 1.0 : 0)) * px
            ribbonU(list, from: na.pos, to: nb.pos, width: width * 2.4, color: V4(0, 0, 0, 0.18 * alpha), glow: 0, layer: .back, camera: frame)
            ribbonU(list, from: na.pos, to: nb.pos, width: width, color: V4(col.x, col.y, col.z, alpha * (0.42 + 0.5 * min(1, wave) + (involves ? 0.2 : 0))),
                        glow: 0.5 + wave, camera: frame)
        }

        for (id, n) in nodes.sorted(by: { $0.key < $1.key }) {
            guard let word = byID[id], n.alpha > 0.02 else { continue }
            let isActive = id == activeID
            let reached = input.pos >= word.start
            let age = Float(max(0, input.pos - word.start))
            let depth = frame.depth(of: n.pos)
            let dof = frame.dof(depth: depth, range: 1100)
            let pop: Float = isActive ? 1.25 * (1 + 0.05 * exp(-age * 6)) : 1
            let mod = engine.wordMod(index: word.id, input: input, isActive: isActive)
            var color = V4(1, 1, 1, n.alpha * (isActive ? 1 : (reached ? 0.42 : 0.18)))
            color.w *= dof.fade
            list.sprite(.glow, at: n.pos, radius: 16, color: V4(hl.x, hl.y, hl.z, 0.4 * n.alpha), extra: 2, camera: frame)
            list.sprite(.plume, at: n.pos + V3(0, 0, 4), radius: fontSize * 0.95, color: V4(0, 0, 0, 1), extra: (isActive ? 0.6 : 0.3) * n.alpha,
                        stretch: max(1.3, n.halfWidth * 2 / fontSize * 0.7), layer: .back, camera: frame)
            if isActive {
                list.sprite(.glow, at: n.pos, radius: 120 + 40 * Float(input.bass), color: V4(hl.x, hl.y, hl.z, 0.5), extra: 2.2, camera: frame)
            }
            drawWord(word.text, at: n.pos, height: fontSize * pop, right: right, up: up, color: color, mod: mod,
                     blur: isActive ? 0 : dof.blur * 0.8, atlas: atlas, input: input, list: list, frame: frame)
        }
        engine.draw(into: list, camera: frame)
    }
}
