import SwiftUI
import simd

/// Codestyle Visual: lyrics as live, syntax-highlighted source code on a tilted holographic glass plane in
/// 3D. String literals are the lyric words (lit as they are sung), keywords come from each line's semantic
/// archetype (`await drive(speed: .fast…)`, `try crash(…)`), the caret follows the sung word, and animated
/// semantic props fire beside the active string.
final class CodeScene3D: Scene3D {
    private enum Kind { case keyword, ident, punct, quote, word, comment }
    private struct Seg { let text: String; let kind: Kind; var wordID: Int? = nil }
    private struct Row { let indent: Int; let segs: [Seg]; let line: Int? }

    private var rows: [Row] = []
    private var rowOfLine: [Int: Int] = [:]
    private var scroll = Spring1()
    private var panelScroll = Spring1()

    override func reset() { super.reset(); rows = []; rowOfLine = [:]; scroll = Spring1(); panelScroll = Spring1() }

    private let H: Float = 40          // code font height in world units

    // MARK: Build the source file

    private func build(_ lyrics: TimedLyrics) {
        rows = []; rowOfLine = [:]
        var stanza = 0
        for (li, group) in lyrics.groups.enumerated() {
            let start = group.first?.start ?? 0
            let prevEnd = li > 0 ? (lyrics.groups[li - 1].last?.end ?? 0) : -10
            if li == 0 || start - prevEnd > 2.4 {
                if li > 0 { rows.append(Row(indent: 0, segs: [Seg(text: "}", kind: .punct)], line: nil)) }
                stanza += 1
                let name = stanza == 2 ? "chorus" : "verse\(stanza)"
                rows.append(Row(indent: 0, segs: [Seg(text: "// \(name)", kind: .comment)], line: nil))
                rows.append(Row(indent: 0, segs: [Seg(text: "func ", kind: .keyword), Seg(text: name, kind: .ident), Seg(text: "() async {", kind: .punct)], line: nil))
            }
            // Template by the line's dominant semantic archetype.
            let archetype = group.compactMap { w in engine.tags.indices.contains(w.id) ? engine.tags[w.id].archetype : nil }.first { $0 != .none } ?? .none
            let lead: [Seg]
            var tail = [Seg(text: ")", kind: .punct)]
            switch archetype {
            case .velocity: lead = [Seg(text: "await ", kind: .keyword), Seg(text: "drive", kind: .ident), Seg(text: "(speed: ", kind: .punct), Seg(text: ".fast", kind: .keyword), Seg(text: ", ", kind: .punct)]
            case .impact: lead = [Seg(text: "try ", kind: .keyword), Seg(text: "crash", kind: .ident), Seg(text: "(.hard, ", kind: .punct)]
            case .fire: lead = [Seg(text: "await ", kind: .keyword), Seg(text: "ignite", kind: .ident), Seg(text: "(heat: ", kind: .punct), Seg(text: ".max", kind: .keyword), Seg(text: ", ", kind: .punct)]
            case .heart, .tears: lead = [Seg(text: "await ", kind: .keyword), Seg(text: "pulse", kind: .ident), Seg(text: "(bpm: ", kind: .punct), Seg(text: "72", kind: .keyword), Seg(text: ", ", kind: .punct)]
            case .cosmic: lead = [Seg(text: "await ", kind: .keyword), Seg(text: "orbit", kind: .ident), Seg(text: "(altitude: ", kind: .punct), Seg(text: ".high", kind: .keyword), Seg(text: ", ", kind: .punct)]
            case .vibe: lead = [Seg(text: "await ", kind: .keyword), Seg(text: "amplify", kind: .ident), Seg(text: "(gain: ", kind: .punct), Seg(text: "11", kind: .keyword), Seg(text: ", ", kind: .punct)]
            case .none:
                let t = Int(CanvasKit.hash(li * 5 + 3) * 3)
                if t == 0 { lead = [Seg(text: "let ", kind: .keyword), Seg(text: "line\(li + 1)", kind: .ident), Seg(text: " = ", kind: .punct)]; tail = [] }
                else if t == 1 { lead = [Seg(text: "print", kind: .ident), Seg(text: "(", kind: .punct)] }
                else { lead = [Seg(text: "return ", kind: .keyword)]; tail = [] }
            }
            var segs = lead
            segs.append(Seg(text: "\"", kind: .quote))
            for (k, w) in group.enumerated() {
                segs.append(Seg(text: w.text, kind: .word, wordID: w.id))
                if k < group.count - 1 { segs.append(Seg(text: " ", kind: .punct)) }
            }
            segs.append(Seg(text: "\"", kind: .quote))
            segs.append(contentsOf: tail)
            rowOfLine[li] = rows.count
            rows.append(Row(indent: 1, segs: segs, line: li))
        }
        rows.append(Row(indent: 0, segs: [Seg(text: "}", kind: .punct)], line: nil))
    }

    // MARK: Plane

    private func basis(_ t: Double) -> (right: V3, up: V3, normal: V3) {
        let yaw = Float(0.42 + 0.12 * sin(t * 0.27)), pitch = Float(-0.14 + 0.05 * sin(t * 0.21))
        let q = simd_quatf(angle: yaw, axis: V3(0, 1, 0)) * simd_quatf(angle: pitch, axis: V3(1, 0, 0))
        return (q.act(V3(1, 0, 0)), q.act(V3(0, 1, 0)), q.act(V3(0, 0, 1)))
    }

    private var charWidth: Float = 24

    private func world(_ u: Float, _ v: Float, _ b: (right: V3, up: V3, normal: V3)) -> V3 { b.right * u + b.up * v }

    private func anchor(_ index: Int, input: SceneInput) -> SemanticKineticEngine.Anchor? {
        let line = input.lyrics.words[index].line
        guard let r = rowOfLine[line] else { return nil }
        let b = basis(input.time)
        return .init(center: world(0, -Float(r) * H * 1.7, b), halfWidth: 300, unit: H)
    }

    override func update(_ input: SceneInput, dt: Double) {
        if rows.isEmpty { build(input.lyrics) }
        let line = input.cursor.index ?? input.cursor.next ?? 0
        let target = Double(rowOfLine[line] ?? 0)
        if !markPrimedOnce { scroll = Spring1(value: target); panelScroll = Spring1(value: target); markPrimedOnce = true }
        scroll.step(to: target, dt: dt, stiffness: 170, damping: 20)
        panelScroll.step(to: target, dt: dt, stiffness: 120, damping: 18)

        let b = basis(input.time)
        let lh = H * 1.7
        let center = world(0, -Float(scroll.value) * lh, b)
        let distance = Double(1250 / max(0.5, Float(input.theme.scale)))
        let n = SIMD3<Double>(b.normal)
        let target3 = SIMD3<Double>(center)
        camera.update(dt: dt, position: target3 - n * distance, target: target3, lookAhead: target3, anticipation: 0,
                      bank: 0.02 * sin(input.time * 0.3), bass: input.bass, vocalSpike: input.beat.velocity)
        markPrimed()
        engine.update(input: input, dt: dt, anchor: { [unowned self] i in self.anchor(i, input: input) }, camera: camera)
    }
    private var markPrimedOnce = false
    override func reset2() { markPrimedOnce = false }

    // MARK: Draw

    override func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {
        guard !rows.isEmpty else { return }
        let lyrics = input.lyrics
        let hl = highlight(input), sec = secondary(input)
        let b = basis(input.time)
        let lh = H * 1.7
        let activeLine = input.cursor.index ?? input.cursor.next ?? 0
        let activeRow = rowOfLine[activeLine] ?? 0
        if let m = atlas.text("M", font: input.theme.font, mono: true) { charWidth = m.size.x * H / Float(GlyphAtlas.rasterSize) * 1.25 }
        let cw = charWidth

        // Longest visible row decides the panel width.
        let visible = rows.indices.filter { abs($0 - activeRow) <= 6 }
        let maxChars = max(30, visible.map { rows[$0].indent * 4 + rows[$0].segs.reduce(0) { $0 + $1.text.count } }.max() ?? 30)
        let panelW = (Float(maxChars) + 10) * cw
        let panelH = lh * 13
        let gutter = cw * 4
        let left = -panelW / 2 + gutter + cw * 2
        let panelCenterV = -Float(panelScroll.value) * lh

        // Glass panel (holographic plane) and its dark backing for legibility.
        list.quad(.panel, uv: V4(0, 0, 1, 1), center: world(0, panelCenterV, b), right: b.right * panelW / 2, up: b.up * panelH / 2,
                  color: V4(hl.x, hl.y, hl.z, 0.82), blur: 0.03, extra: 1.0, glow: Float(panelW / panelH), layer: .back, camera: frame)
        list.sprite(.glow, at: world(0, panelCenterV, b) + b.normal * 20, radius: panelW * 0.5, color: V4(hl.x, hl.y, hl.z, 0.05 + 0.1 * Float(input.bass)), extra: 1.6, camera: frame)

        // Title bar.
        drawWord("lyrics.swift", at: world(0, panelCenterV + panelH / 2 - lh * 0.1, b), height: H * 0.7, right: b.right, up: b.up,
                 color: V4(1, 1, 1, 0.5), mono: true, atlas: atlas, input: input, list: list, frame: frame)
        for (k, c) in [V4(1, 0.35, 0.35, 0.8), V4(1, 0.8, 0.3, 0.8), V4(0.35, 0.9, 0.45, 0.8)].enumerated() {
            list.sprite(.glow, at: world(-panelW / 2 + cw * (1.6 + Float(k) * 1.5), panelCenterV + panelH / 2 - lh * 0.1, b), radius: 9, color: c, extra: 1.2, camera: frame)
        }

        var caret: V3?
        var rowIcons: [(WordVisual, Int, V3)] = []
        let lo = max(0, activeRow - 6), hi = min(rows.count - 1, activeRow + 6)
        for r in lo...hi {
            let row = rows[r]
            let v = -Float(r) * lh
            let d = abs(Double(r) - panelScroll.value)
            let dim = Float(1 / (1 + 0.38 * d))
            let isActiveRow = r == activeRow
            let rowDepth = frame.depth(of: world(0, v, b))
            let dof = frame.dof(depth: rowDepth, range: 1200)

            if isActiveRow {
                list.quad(.panel, uv: V4(0, 0, 1, 1), center: world(0, v, b) + b.normal * -2, right: b.right * panelW / 2, up: b.up * lh / 2,
                          color: V4(1, 1, 1, 0.1), blur: 0.02, extra: 0, glow: panelW / lh, layer: .back, camera: frame)
            }
            // Line number.
            let numCenter = world(-panelW / 2 + gutter - cw * 0.3, v, b)
            drawWord("\(r + 1)", at: numCenter, height: H * 0.82, right: b.right, up: b.up,
                     color: V4(1, 1, 1, (isActiveRow ? 0.75 : 0.28) * dim), mono: true, blur: dof.blur * 0.5, atlas: atlas, input: input, list: list, frame: frame)

            var col = row.indent * 4
            var lastReachedU: Float?
            for seg in row.segs {
                let width = Float(seg.text.count) * cw
                let uCenter = left + (Float(col) + Float(seg.text.count) / 2) * cw
                var color: V4
                var mod = WordMod()
                var alpha = dim * dof.fade
                switch seg.kind {
                case .keyword: color = V4(sec.x, sec.y, sec.z, 1); let m = (sec + V4(1, 1, 1, 0) * 0.25); color = V4(min(1, m.x), min(1, m.y), min(1, m.z), 1)
                case .ident: color = V4(1, 1, 1, 0.92)
                case .punct: color = V4(1, 1, 1, 0.55)
                case .quote: color = V4(hl.x, hl.y, hl.z, 0.75)
                case .comment: color = V4(1, 1, 1, 0.38)
                case .word:
                    color = hl
                    if let id = seg.wordID {
                        let w = lyrics.words[id]
                        let reached = input.pos >= w.start
                        let active = id == input.activeWord
                        mod = engine.wordMod(index: id, input: input, isActive: active)
                        if active {
                            color = V4(1, 1, 1, 1)
                            list.sprite(.glow, at: world(uCenter, v, b) + b.normal * -4, radius: width * 0.8 + 70, color: V4(hl.x, hl.y, hl.z, 0.6), extra: 2.2, camera: frame)
                        } else if reached {
                            color = V4(min(1, hl.x + 0.25), min(1, hl.y + 0.25), min(1, hl.z + 0.25), 1)
                        } else {
                            alpha *= isActiveRow ? 0.5 : 0.7
                        }
                        if reached { lastReachedU = uCenter + width / 2 }
                        if active, let vis = visual(for: id, input: input) { rowIcons.append((vis, id, world(uCenter, v, b))) }
                    }
                }
                color.w *= alpha
                if seg.text != " " {
                    drawWord(seg.text, at: world(uCenter, v, b), height: H, right: b.right, up: b.up, color: color, mod: mod, mono: true,
                             blur: dof.blur * 0.6, atlas: atlas, input: input, list: list, frame: frame)
                }
                col += seg.text.count
            }

            if isActiveRow {
                let u = lastReachedU ?? (left + Float(row.indent * 4 + 1) * cw)
                caret = world(u + cw * 0.15, v, b)
                // Semantic props beside the string literal, after the end of the row.
                let endU = min(left + Float(col) * cw + cw * 2.2, panelW / 2 - H * 3)
                for (k, entry) in rowIcons.suffix(4).enumerated() {
                    let pm = engine.propMod(index: entry.1, input: input)
                    prop(entry.0, at: world(endU + Float(k) * H * 1.5, v + 4, b) + b.normal * -10, size: H * 1.5, right: b.right, up: b.up, mod: pm,
                         tint: engine.tint(entry.1, fallback: hl), atlas: atlas, list: list, frame: frame)
                }
            }
        }

        // Glowing cursor caret.
        if let caret, sin(input.time * 7) > -0.35 {
            list.sprite(.glow, at: caret + b.normal * -6, radius: 30, color: V4(hl.x, hl.y, hl.z, 0.9), extra: 2, camera: frame)
            list.quad(.panel, uv: V4(0, 0, 1, 1), center: caret + b.normal * -8, right: b.right * 3, up: b.up * lh * 0.42, color: V4(1, 1, 1, 1),
                      blur: 0.0, extra: 0, glow: 6 / (lh * 0.84), layer: .glow, camera: frame)
        }
        engine.draw(into: list, camera: frame)
    }
}
