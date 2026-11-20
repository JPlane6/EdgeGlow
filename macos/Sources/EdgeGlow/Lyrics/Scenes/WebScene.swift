import SwiftUI

/// Web — each line is spun into a spider's web: a radial strand shoots out for every word, and curved
/// silk joins neighbouring strands.
struct WebScene: View {
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

    private func draw(_ gi: Int, in ctx: inout GraphicsContext, size: CGSize) {
        let words = frame.group(gi)
        guard !words.isEmpty else { return }
        let p = frame.palette
        let pos = frame.position
        let center = CGPoint(x: size.width * 0.5, y: frame.bandCenterY)
        let count = max(5, words.count)
        // The web quivers when a strand lands.
        let lastStart = words.last(where: frame.arrived)?.start ?? -10
        let dt = pos - lastStart
        let quiver = 1 + 0.012 * exp(-5 * dt) * sin(25 * dt)
        let R = min(size.width, size.height) * 0.38 * CGFloat(quiver)

        func dir(_ i: Int) -> CGPoint {
            let theta = (2 * Double.pi * Double(i) / Double(count)) - Double.pi / 2
            return CGPoint(x: cos(theta), y: sin(theta))
        }
        func point(_ i: Int, _ r: CGFloat) -> CGPoint { center + dir(i) * r }
        func grown(_ i: Int) -> Double {
            guard i < words.count else { return 0 }
            return Motion.clamp01(Motion.spring(pos - words[i].start))
        }

        // Guide spokes for unused angles (lines shorter than five words).
        for i in words.count..<count {
            var path = Path()
            path.move(to: center)
            path.addLine(to: point(i, R * 0.92))
            ctx.stroke(path, with: .color(p.secondary.opacity(0.12)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [2, 4]))
        }

        // Concentric silk between adjacent spun spokes, dipping slightly toward the center.
        let rings: [CGFloat] = [0.26, 0.42, 0.58, 0.74, 0.9]
        let closes = words.count == count
        for i in 0..<words.count {
            let j = i + 1 < words.count ? i + 1 : (closes ? 0 : -1)
            guard j >= 0, frame.arrived(words[i]) else { continue }
            let later = max(words[i].start, words[j].start)
            guard pos >= later else { continue }
            let spin = Motion.smooth((pos - later) / 0.45)
            for (ri, f) in rings.enumerated() {
                let ringSpin = Motion.smooth(spin * Double(rings.count) - Double(ri) * 0.6)
                guard ringSpin > 0 else { continue }
                let r = R * f
                let a = point(i, r), b = point(j, r)
                let midDir = (dir(i) + dir(j)) * 0.5
                let len = max(0.001, hypot(midDir.x, midDir.y))
                let control = center + midDir * (1 / len) * (r * 0.86)
                var silk = Path()
                silk.move(to: a)
                silk.addQuadCurve(to: b, control: control)
                ctx.stroke(silk.trimmedPath(from: 0, to: ringSpin), with: .color(p.secondary.opacity(0.35)), lineWidth: 1.0)
            }
        }

        // Strands and labels.
        let labelFont = frame.font.font(size: 22 * frame.textScale, weight: .bold)
        for (i, w) in words.enumerated() where frame.arrived(w) {
            let active = frame.isActive(w)
            let g = grown(i)
            let tip = point(i, R * CGFloat(g))
            var strand = Path()
            strand.move(to: center)
            strand.addLine(to: tip)
            if active {
                var c = ctx
                c.addFilter(.shadow(color: p.highlight, radius: 6))
                c.stroke(strand, with: .color(p.highlight), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                let r: CGFloat = 4 + CGFloat(sin(frame.clock * 7)) * 0.8
                c.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)), with: .color(.white))
            } else {
                ctx.stroke(strand, with: .color(p.text.opacity(0.55)), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            }

            // Horizontal labels at the strand tip, aligned away from the center so they stay readable.
            let d = dir(i)
            let labelPoint = point(i, R * CGFloat(g) + 12 * frame.textScale)
            let anchor: UnitPoint
            if d.x > 0.25 { anchor = .leading } else if d.x < -0.25 { anchor = .trailing } else { anchor = d.y < 0 ? .bottom : .top }
            let alpha = Motion.smooth((pos - w.start) / 0.2)
            var lc = ctx
            lc.opacity = alpha
            if active {
                lc.glowingText(w.text, font: labelFont, color: p.highlight, glow: p.highlight.opacity(0.75), radius: 8, at: labelPoint, anchor: anchor)
            } else {
                lc.text(w.text, font: labelFont, color: p.text, at: labelPoint, anchor: anchor)
            }
        }

        // Hub.
        var hub = ctx
        hub.addFilter(.shadow(color: p.highlight, radius: 5))
        hub.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(p.highlight))
    }
}
