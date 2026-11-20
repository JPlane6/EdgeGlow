import SwiftUI

/// Ship — words land one by one on a centered typographic wall that drifts in 3D.
struct ShipScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        ZStack {
            if let gi = f.groupIndex {
                ShipWall(frame: f, groupIndex: gi)
                    .id(gi)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                            removal: .opacity.combined(with: .scale(scale: 1.06))))
            }
        }
        .animation(Motion.standard, value: f.groupIndex)
        .rotation3DEffect(.degrees(sin(f.clock * 0.45) * 8.0), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .rotation3DEffect(.degrees(cos(f.clock * 0.35) * 12.0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .offset(x: sin(f.clock * 0.3) * 14, y: cos(f.clock * 0.4) * 8)
        // Beat kick: the wall tips back and jumps toward the viewer on every hit.
        .rotation3DEffect(.degrees(-6 * Double(f.kick)), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .scaleEffect(f.thump(0.035))
        .position(x: f.canvas.width / 2, y: f.bandCenterY)
    }
}

private struct ShipWall: View {
    let frame: LyricFrame
    let groupIndex: Int

    var body: some View {
        let words = frame.group(groupIndex)
        let rows = WordRows.split(words)
        let size = min(40 * frame.textScale, frame.bandHeight / (CGFloat(rows.count) * 1.22))
        let arrived = words.filter(frame.arrived).count
        VStack(spacing: size * 0.08) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: size * 0.26) {
                    ForEach(rows[r].filter(frame.arrived)) { w in
                        word(w, size: size)
                            .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity), removal: .opacity))
                    }
                }
            }
        }
        .animation(Motion.standard, value: arrived)
        .fixedSize()
    }

    private func word(_ w: TimedWord, size: CGFloat) -> some View {
        let active = frame.isActive(w)
        return Text(w.text)
            .font(frame.font.font(size: size, weight: .bold))
            .foregroundStyle(active ? frame.palette.highlight : frame.palette.text)
            .opacity(active ? 1.0 : 0.84)
            .scaleEffect(active ? frame.thump(0.08) : 1)
            .shadow(color: active ? frame.palette.highlight.opacity(0.65 + 0.3 * Double(frame.kick)) : .clear,
                    radius: active ? size * 0.22 * (1 + frame.kick) : 0)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .animation(Motion.standard, value: active)
    }
}

/// Splits a line into centered rows of about 3–5 words, balanced by length.
enum WordRows {
    static func split(_ words: [TimedWord], maxPerRow: Int = 4) -> [[TimedWord]] {
        guard words.count > maxPerRow else { return [words] }
        let rows = Int((Double(words.count) / Double(maxPerRow)).rounded(.up))
        let total = words.reduce(0) { $0 + $1.text.count + 1 }
        let target = Double(total) / Double(rows)
        var out: [[TimedWord]] = []
        var cur: [TimedWord] = []
        var length = 0
        for (i, w) in words.enumerated() {
            let rowsAfter = rows - out.count - 1
            let wordsLeft = words.count - i
            if !cur.isEmpty, rowsAfter > 0,
               Double(length + w.text.count) > target * 1.1 || cur.count >= 5 || wordsLeft <= rowsAfter {
                out.append(cur)
                cur = []
                length = 0
            }
            cur.append(w)
            length += w.text.count + 1
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { !$0.isEmpty }
    }
}
