import SwiftUI
import simd

/// A typeset wall of lyric lines in flat "wall units" (wrapped, centered rows). Shared by every wall style.
final class WallLayout {
    struct Item {
        let wordIndex: Int
        /// Center of the word in wall units (x right, y down).
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    static let fontSize: CGFloat = 54
    let maxWidth: CGFloat
    private let font: LyricFont
    private(set) var items: [[Item]] = []
    private(set) var lineTop: [CGFloat] = []
    private(set) var lineHeight: [CGFloat] = []

    init(maxWidth: CGFloat, font: LyricFont) {
        self.maxWidth = maxWidth
        self.font = font
    }

    var count: Int { items.count }

    func ensure(_ line: Int, in lyrics: TimedLyrics) {
        while items.count <= min(line, lyrics.groups.count - 1) {
            let li = items.count
            let words = lyrics.groups[li]
            let rowHeight = Self.fontSize * 1.3
            let gap = Self.fontSize * 0.62
            var rows: [[(TimedWord, CGFloat)]] = [[]]
            var rowWidth: CGFloat = 0
            for w in words {
                let cw = TextMetrics.shared.width(w.text, font: font, size: Self.fontSize)
                if rowWidth + cw > maxWidth, !rows[rows.count - 1].isEmpty { rows.append([]); rowWidth = 0 }
                rows[rows.count - 1].append((w, cw))
                rowWidth += cw + gap
            }
            let top = (lineTop.last ?? 0) + (lineHeight.last ?? 0) + (li == 0 ? 0 : Self.fontSize * 0.75)
            var lineItems: [Item] = []
            for (r, row) in rows.enumerated() {
                let total = row.reduce(0) { $0 + $1.1 } + gap * CGFloat(max(0, row.count - 1))
                var x = -total / 2
                for (w, cw) in row {
                    lineItems.append(Item(wordIndex: w.id, x: x + cw / 2, y: top + rowHeight * (CGFloat(r) + 0.5), width: cw))
                    x += cw + gap
                }
            }
            items.append(lineItems)
            lineTop.append(top)
            lineHeight.append(rowHeight * CGFloat(rows.count))
        }
    }

    func item(forWord index: Int, line: Int) -> Item? {
        guard items.indices.contains(line) else { return nil }
        return items[line].first { $0.wordIndex == index }
    }
}

/// Ship, Visual, Fisheye and Fisheye Visual: a 3D architectural word wall in real perspective. Each sung
/// word stamps onto the wall with spring physics while the cinematic camera dollies, pans and orbits
/// across it; bass pushes the active word toward the glass. Visual adds the semantic props and the
/// Fisheye variants look through the barrel lens.
final class WallScene3D: Scene3D {
    private let lens: Bool
    /// HyperShip 3D: a floating stage fixed at pitch 8° / yaw -14° that breathes and punches toward the glass on bass kicks.
    private let stage: Bool
    private var layout: WallLayout?
    override var usesLens: Bool { lens }

    init(icons: Bool, lens: Bool, stage: Bool = false) {
        self.lens = lens
        self.stage = stage
        super.init(icons: icons, seed: lens ? 11 : stage ? 23 : 5)
    }

    override func reset() { super.reset(); layout = nil }

    private func activeLine(_ input: SceneInput) -> Int { input.cursor.index ?? input.cursor.next ?? 0 }

    private func world(_ item: WallLayout.Item, z: Float = 0) -> V3 { V3(Float(item.x), -Float(item.y), z) }

    private func anchor(_ index: Int, input: SceneInput) -> SemanticKineticEngine.Anchor? {
        guard let layout, let item = layout.item(forWord: index, line: input.lyrics.words[index].line) else { return nil }
        return .init(center: world(item), halfWidth: Float(item.width) / 2, unit: Float(WallLayout.fontSize))
    }

    override func update(_ input: SceneInput, dt: Double) {
        let lyrics = input.lyrics
        guard !lyrics.isEmpty else { return }
        if layout == nil { layout = WallLayout(maxWidth: lens ? 980 : 900, font: input.theme.font) }
        guard let layout else { return }
        let line = activeLine(input)
        layout.ensure(line + 4, in: lyrics)

        var target = SIMD3<Double>(0, 0, 0)
        var next = target
        if layout.lineTop.indices.contains(line) {
            target = SIMD3(0, -Double(layout.lineTop[line] + layout.lineHeight[line] / 2), 0)
            next = target
        }
        if let a = input.activeWord, let item = layout.item(forWord: a, line: lyrics.words[a].line) {
            target = SIMD3(Double(item.x) * 0.85, -Double(item.y), 0)
            next = target
            if a + 1 < lyrics.words.count, let n = layout.item(forWord: a + 1, line: lyrics.words[a + 1].line) {
                next = SIMD3(Double(n.x) * 0.85, -Double(n.y), 0)
            }
        }
        let t = input.time
        let yaw = stage ? 0.42 + 0.05 * sin(t * 0.3) : 0.2 + 0.36 * sin(t * 0.21) + 0.03 * input.vocal
        let pitch = 0.10 * sin(t * 0.17 + 1)
        let punch = stage ? 90 * input.bass : 0
        let distance = ((lens ? 640 : 540) - punch) / max(0.5, input.theme.scale)
        let lift = stage ? distance * 0.14 + 12 * sin(t * 0.5) : distance * 0.28 * sin(pitch) + 30
        let position = target + SIMD3(distance * sin(yaw), lift, -distance * cos(yaw))
        let anticipation = input.activeWord.map { a -> Double in
            let w = lyrics.words[a]
            return CanvasKit.smoothstep(input.progress(w)) * 0.7
        } ?? 0
        camera.update(dt: dt, position: position, target: target, lookAhead: next, anticipation: anticipation,
                      bank: 0.03 * sin(t * 0.4), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i, input: input) }, camera: camera)
    }

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        guard let layout else { return }
        let lyrics = input.lyrics
        let theme = input.theme
        let hl = highlight(input), sec = secondary(input)
        let line = activeLine(input)
        let U = Float(WallLayout.fontSize)
        let right = V3(1, 0, 0), up = V3(0, 1, 0)
        let activeIndex = input.activeWord
        let lo = max(0, line - 3), hi = min(layout.count - 1, line + 3)
        guard lo <= hi else { return }
        let text = Self.vec(theme.text)

        // Dark plume behind the focal cluster (the active line), soft radial falloff at 65 %.
        if layout.items.indices.contains(line), !layout.items[line].isEmpty {
            let items = layout.items[line]
            let minX = items.map { $0.x - $0.width / 2 }.min() ?? 0, maxX = items.map { $0.x + $0.width / 2 }.max() ?? 0
            let y = items.map { $0.y }.reduce(0, +) / CGFloat(items.count)
            let c = V3(Float(minX + maxX) / 2, -Float(y), 40)
            let widthWorld = Float(maxX - minX)
            let pr = max(160, U * 3.0)
            list.sprite(.plume, at: c, radius: pr, color: V4(0, 0, 0, 1), extra: 0.34, stretch: max(2.6, widthWorld * 0.8 / pr), layer: .back, camera: frame)
        }

        for li in lo...hi {
            let dl = li - line
            let lineAlpha: Float = dl == 0 ? 1 : (dl < 0 ? 0.55 / Float(-dl) + 0.1 : 0.6 / Float(dl) + 0.08)
            for item in layout.items[li] {
                let index = item.wordIndex
                let word = lyrics.words[index]
                let reached = input.pos >= word.start
                let isActive = index == activeIndex
                let age = Float(max(0, input.pos - word.start))

                var z = Float(abs(dl)) * 70 + sin(Float(index) * 0.9 + Float(input.time) * 1.3) * 22
                if reached, age < 1.4 { z -= Float(1 - CanvasKit.spring(Double(age))) * 50 }
                if dl == 0 { z -= Float(input.bass) * 30 }
                if isActive { z -= stage ? 30 : 10 }

                let mod = engine.wordMod(index: index, input: input, isActive: isActive)
                let center = world(item, z: z)
                let depth = frame.depth(of: center)
                let dof = frame.dof(depth: depth, range: 1100)

                var color = text
                if isActive { color = V4(1, 1, 1, 1) }
                else if dl == 0 { color = V4(1, 1, 1, reached ? 0.42 : 0.18) }
                else { color = V4(1, 1, 1, min(0.18, lineAlpha * 0.2)) }
                if lens, !isActive { color.w = min(0.55, color.w * 2.2) }   // glass dome backing is dark
                color.w *= dof.fade
                let blur: Float = (isActive || (dl == 0 && reached)) ? 0 : 1.5 + min(2.5, dof.blur)

                if isActive {
                    list.sprite(.glow, at: center, radius: max(Float(item.width) * 0.9, 110), color: V4(hl.x, hl.y, hl.z, 0.30 + 0.12 * Float(input.bass)), extra: 2.2, camera: frame)
                }
                drawWord(word.text, at: center, height: U, right: right, up: up, color: color, mod: mod, blur: blur,
                     atlas: atlas, input: input, list: list, frame: frame)

                if icons, isActive, let v = visual(for: index, input: input) {
                    let pm = engine.propMod(index: index, input: input)
                    let anchorPoint = center + V3(Float(item.width) / 2 + U * 0.3, U * 0.95, -8)
                    prop(v, at: anchorPoint, size: U * 1.15, right: right, up: up, mod: pm, tint: engine.tint(index, fallback: isActive ? hl : sec), atlas: atlas, list: list, frame: frame)
                }
            }
        }
        engine.draw(into: list, camera: frame)
    }

    private func mix(_ a: V4, _ b: V4, _ t: Float) -> V4 { a + (b - a) * t }
}
