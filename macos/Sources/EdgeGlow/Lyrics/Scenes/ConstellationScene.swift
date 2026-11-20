import SwiftUI

/// Constellation — each line is traced star by star: a star flares for every word and a luminous line
/// joins it to the previous one across the word's duration.
struct ConstellationScene: View {
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

    /// Seeded scatter in the central region with a minimum separation, then ordered left to right.
    private func stars(_ gi: Int, count: Int, size: CGSize) -> [CGPoint] {
        let dy = frame.bandCenterY - size.height * 0.5
        let rect = CGRect(x: size.width * 0.15, y: size.height * 0.25 + dy, width: size.width * 0.70, height: size.height * 0.50)
        var minSep = min(rect.width / CGFloat(max(1, count)) * 1.1, rect.height * 0.45)
        var pts: [CGPoint] = []
        var attempt = 0
        while pts.count < count {
            let seed = gi * 1000 + attempt
            // Stratify x so the trace reads left to right.
            let slot = CGFloat(pts.count) / CGFloat(count)
            let jitter = CGFloat(Motion.hash(seed, 1))
            let x = rect.minX + rect.width * (slot + jitter / CGFloat(count))
            let y = rect.minY + rect.height * CGFloat(Motion.hash(seed, 2))
            let candidate = CGPoint(x: x, y: y)
            if pts.allSatisfy({ $0.distance(candidate) >= minSep }) {
                pts.append(candidate)
            }
            attempt += 1
            if attempt % 40 == 0 { minSep *= 0.85 }
        }
        return pts.sorted { $0.x < $1.x }
    }

    private func draw(_ gi: Int, in ctx: inout GraphicsContext, size: CGSize) {
        let words = frame.group(gi)
        guard !words.isEmpty else { return }
        let p = frame.palette
        let pos = frame.position
        let pts = stars(gi, count: words.count, size: size)

        // Faint dust behind the figure.
        for k in 0..<26 {
            let x = size.width * CGFloat(Motion.hash(gi, 300 + k)), y = size.height * CGFloat(Motion.hash(gi, 400 + k))
            let tw = 0.5 + 0.5 * sin(frame.clock * (1.2 + Motion.hash(gi, 500 + k) * 2) + Double(k))
            let r = 0.6 + CGFloat(Motion.hash(gi, 600 + k)) * 1.1
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(p.text.opacity(0.06 + 0.16 * tw)))
        }

        // Constellation lines.
        for i in 1..<max(1, words.count) where frame.arrived(words[i]) {
            let w = words[i]
            let f = Motion.smooth((pos - w.start) / max(0.3, w.duration))
            var line = Path()
            line.move(to: pts[i - 1])
            line.addLine(to: pts[i - 1].lerp(pts[i], f))
            if f < 1 || frame.isActive(w) {
                var c = ctx
                c.addFilter(.shadow(color: p.highlight, radius: 5))
                c.stroke(line, with: .color(p.highlight), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            } else {
                ctx.stroke(line, with: .color(p.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }

        // Stars and names.
        let labelFont = frame.font.font(size: 22 * frame.textScale, weight: .bold)
        for (i, w) in words.enumerated() {
            let c = pts[i]
            guard frame.arrived(w) else {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(p.text.opacity(0.18)))
                continue
            }
            let active = frame.isActive(w)
            let pop = CGFloat(Motion.spring(pos - w.start, response: 0.3, damping: 0.45))
            let radius: CGFloat
            let rotation: Double
            let color: Color
            if active {
                radius = (12 + 2 * CGFloat(sin(frame.clock * 4))) * pop
                rotation = frame.clock * 0.5
                color = p.highlight
            } else {
                radius = (6 + 0.9 * CGFloat(sin(frame.clock * 3 + Double(i)))) * pop
                rotation = 0
                color = p.text.mixed(p.highlight, 0.3)
            }
            StarSparkle(center: c, radius: max(0.5, radius)).draw(in: ctx, color: color, rotation: rotation)

            // Put the name on the side away from the lines into and out of this star.
            var pull: CGFloat = 0
            if i > 0 { pull += pts[i - 1].y - c.y }
            if i + 1 < pts.count { pull += pts[i + 1].y - c.y }
            let below = pull < 0 || (pull == 0 && c.y < frame.bandCenterY)
            let gap = max(radius, 6) + 10 * frame.textScale
            let at = CGPoint(x: c.x, y: below ? c.y + gap : c.y - gap)
            let anchor: UnitPoint = below ? .top : .bottom
            if active {
                ctx.glowingText(w.text, font: labelFont, color: p.highlight, glow: p.highlight.opacity(0.7), radius: 8, at: at, anchor: anchor)
            } else {
                ctx.text(w.text, font: labelFont, color: p.text.opacity(0.9), at: at, anchor: anchor)
            }
        }
    }
}

/// A crisp four-point flare (four concave quadratic curves meeting at N/E/S/W spikes) over a soft core.
struct StarSparkle {
    let center: CGPoint
    let radius: CGFloat

    func path(rotation: Double, scale: CGFloat = 1, pinch: CGFloat = 0.16) -> Path {
        let r = radius * scale
        func at(_ angle: Double, _ d: CGFloat) -> CGPoint { CGPoint(x: center.x + CGFloat(cos(angle)) * d, y: center.y + CGFloat(sin(angle)) * d) }
        var p = Path()
        let base = rotation - Double.pi / 2
        p.move(to: at(base, r))
        for k in 0..<4 {
            let tip = at(base + Double(k + 1) * Double.pi / 2, r)
            let control = at(base + (Double(k) + 0.5) * Double.pi / 2, r * pinch)
            p.addQuadCurve(to: tip, control: control)
        }
        p.closeSubpath()
        return p
    }

    func draw(in ctx: GraphicsContext, color: Color, rotation: Double) {
        let glowR = radius * 1.9
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0)]), center: center, startRadius: 0, endRadius: glowR))
        var c = ctx
        c.addFilter(.shadow(color: color, radius: radius * 0.45))
        c.fill(path(rotation: rotation + Double.pi / 4, scale: 0.5, pinch: 0.2), with: .color(color.opacity(0.55)))
        c.fill(path(rotation: rotation), with: .color(color))
        let core = radius * 0.22
        c.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)), with: .color(.white))
    }
}
