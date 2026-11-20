import SwiftUI

/// Visual — the current line builds as a centered stack, with an icon beside every word that has one.
struct VisualScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        ZStack {
            if let gi = f.groupIndex {
                VisualStack(frame: f, groupIndex: gi)
                    .id(gi)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)),
                                            removal: .opacity.combined(with: .offset(y: -18))))
            }
        }
        .animation(Motion.standard, value: f.groupIndex)
        .position(x: f.canvas.width / 2, y: f.bandCenterY)
    }
}

private struct VisualStack: View {
    let frame: LyricFrame
    let groupIndex: Int

    var body: some View {
        let words = frame.group(groupIndex)
        let rows = WordRows.split(words, maxPerRow: 3)
        let size = min(46 * frame.textScale, frame.bandHeight / (CGFloat(rows.count) * 1.25))
        let arrived = words.filter(frame.arrived).count
        VStack(spacing: size * 0.12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: size * 0.3) {
                    ForEach(rows[r].filter(frame.arrived)) { w in
                        cell(w, size: size)
                            .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity), removal: .opacity))
                    }
                }
            }
        }
        .animation(Motion.standard, value: arrived)
        .fixedSize()
    }

    private func cell(_ w: TimedWord, size: CGFloat) -> some View {
        let active = frame.isActive(w)
        let p = frame.palette
        return HStack(spacing: size * 0.18) {
            Text(w.text)
                .font(frame.font.font(size: size, weight: .bold))
                .foregroundStyle(active ? p.highlight : p.text)
                .opacity(active ? 1 : 0.86)
                .shadow(color: active ? p.highlight.opacity(0.6 + 0.3 * Double(frame.kick)) : .clear, radius: size * 0.2 * (1 + frame.kick))
            if let v = WordVisualResolver.shared.visual(for: w.text) {
                VisualIcon(visual: v, size: size * 0.85, color: active ? p.highlight : p.secondary, age: frame.position - w.start,
                           kick: active ? frame.kick : frame.kick * 0.4)
            }
        }
        .scaleEffect(active ? frame.thump(0.08) : 1)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .animation(Motion.standard, value: active)
    }
}
