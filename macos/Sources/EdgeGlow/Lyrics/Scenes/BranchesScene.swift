import SwiftUI

/// Branches — an organic line draws itself across the canvas; each word lights a node on it.
struct BranchesScene: View {
    let frame: LyricFrame

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, size in
            for (gi, alpha) in frame.visibleGroups() where alpha > 0.001 {
                var c = ctx
                c.opacity = alpha
                draw(gi, in: &c, size: size)
            }
        }
    }

    private struct Layout {
        var points: [CGPoint]      // lead-in, one per word, lead-out
        var path: Path
        var fractions: [Double]    // path-length fraction of each point
    }

    /// Deterministic per line: x from 12% to 88% (word nodes spaced half by index, half by timing),
    /// y undulating organically around the band center.
    private func layout(_ gi: Int, _ words: [TimedWord], _ size: CGSize) -> Layout {
        let n = words.count
        let cy = frame.bandCenterY
        let amp = frame.bandHeight * 0.30
        let t0 = words.first?.start ?? 0, t1 = max(t0 + 0.01, words.last?.end ?? 1)
        var pts: [CGPoint] = [CGPoint(x: size.width * 0.12, y: cy + amp * 0.25 * Motion.signedHash(gi, 99))]
        let phase = Motion.hash(gi, 7) * .pi * 2
        for (i, w) in words.enumerated() {
            let uniform = n == 1 ? 0.5 : Double(i) / Double(n - 1)
            let timed = (w.start - t0) / (t1 - t0)
            let u = 0.5 * uniform + 0.5 * timed
            let x = size.width * (0.16 + 0.68 * u)
            let wave = sin(Double(i) * 1.35 + phase) * 0.75 + Motion.signedHash(gi, i) * 0.35
            pts.append(CGPoint(x: x, y: cy + amp * CGFloat(wave)))
        }
        pts.append(CGPoint(x: size.width * 0.88, y: cy + amp * 0.25 * Motion.signedHash(gi, 98)))

        // Catmull-Rom through the points, as cubic Béziers.
        var path = Path()
        path.move(to: pts[0])
        var lengths: [Double] = [0]
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = p1 + (p2 - p0) * (1.0 / 6.0)
            let c2 = p2 - (p3 - p1) * (1.0 / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
            var prev = p1, len = 0.0
            for s in 1...12 {
                let t = CGFloat(s) / 12, mt = 1 - t
                let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
                let q = CGPoint(x: a * p1.x + b * c1.x + c * c2.x + d * p2.x, y: a * p1.y + b * c1.y + c * c2.y + d * p2.y)
                len += Double(prev.distance(q))
                prev = q
            }
            total += len
            lengths.append(total)
        }
        return Layout(points: pts, path: path, fractions: lengths.map { $0 / max(total, 1) })
    }

    /// How much of the path is drawn: it reaches node k exactly as word k starts, easing between words.
    private func drawn(_ words: [TimedWord], _ gi: Int, _ fr: [Double]) -> Double {
        let pos = frame.position
        guard let first = words.first else { return 0 }
        if pos < first.start {
            let onset = frame.lineOnset(gi)
            return fr[1] * Motion.smooth((pos - onset) / max(0.05, first.start - onset))
        }
        for k in 0..<words.count {
            let start = words[k].start
            let next = k + 1 < words.count ? words[k + 1].start : max(words[k].end, start + 0.3)
            if pos < next || k == words.count - 1 {
                let f = Motion.smooth((pos - start) / max(0.05, next - start))
                return fr[k + 1] + (fr[k + 2] - fr[k + 1]) * f
            }
        }
        return 1
    }

    private func draw(_ gi: Int, in ctx: inout GraphicsContext, size: CGSize) {
        let words = frame.group(gi)
        guard !words.isEmpty else { return }
        let p = frame.palette
        let L = layout(gi, words, size)
        let ts = frame.textScale

        // Base track, then the lit path with a glow.
        ctx.stroke(L.path, with: .color(p.secondary.opacity(0.22)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        let d = drawn(words, gi, L.fractions)
        if d > 0.0005 {
            let lit = L.path.trimmedPath(from: 0, to: d)
            var g = ctx
            g.addFilter(.shadow(color: p.highlight, radius: 6))
            g.stroke(lit, with: .color(p.highlight), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            if let tip = lit.currentPoint, d < 0.999 {
                let r: CGFloat = 3.2
                g.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)), with: .color(.white))
            }
        }

        let labelFont = frame.font.font(size: 24 * ts, weight: .bold)
        for (i, w) in words.enumerated() {
            let c = L.points[i + 1]
            let arrived = frame.arrived(w)
            let active = frame.isActive(w)
            let pop = Motion.spring(frame.position - w.start, response: 0.3, damping: 0.5)
            if !arrived {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(p.text.opacity(0.2)), lineWidth: 1)
            } else if active {
                let pulse = 7.5 + 1.2 * CGFloat(sin(frame.clock * 6))
                let r = pulse * CGFloat(pop)
                var g = ctx
                g.addFilter(.shadow(color: p.highlight, radius: 9))
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(p.highlight))
                let halo = r + 5 + 3 * CGFloat((frame.clock * 1.5).truncatingRemainder(dividingBy: 1))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2)),
                           with: .color(p.highlight.opacity(0.35)), lineWidth: 1.2)
            } else {
                let r = 4.5 * CGFloat(pop)
                var g = ctx
                g.addFilter(.shadow(color: p.highlight.opacity(0.7), radius: 4))
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(p.highlight.mixed(p.text, 0.35)))
            }

            // Labels alternate above / below the node.
            let above = i % 2 == 0
            let lift = CGFloat(1 - pop) * 8
            let gap = 16 * ts
            let anchorPoint = CGPoint(x: c.x, y: above ? c.y - gap + lift : c.y + gap - lift)
            let anchor: UnitPoint = above ? .bottom : .top
            if active {
                ctx.glowingText(w.text, font: labelFont, color: p.highlight, glow: p.highlight.opacity(0.7), radius: 8, at: anchorPoint, anchor: anchor)
            } else {
                ctx.text(w.text, font: labelFont, color: arrived ? p.text : p.text.opacity(0.2), at: anchorPoint, anchor: anchor)
            }
        }
    }
}
