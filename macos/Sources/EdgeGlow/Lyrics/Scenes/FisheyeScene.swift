import SwiftUI

/// Fisheye — a tight stack of exactly three words `[previous, current, next]` seen through a barrel lens.
/// Fisheye Visual adds icons beside the words, inside the lens so they bulge with the text.
struct FisheyeScene: View {
    let frame: LyricFrame
    let withIcons: Bool

    var body: some View {
        let f = frame
        let size = f.bandHeight * 0.26 * f.textScale
        let lens = CGSize(width: min(f.canvas.width * 0.94, size * 15), height: size * 5.4)
        let center = f.groupIndex == nil ? nil : f.activeWordIndex
        ZStack {
            if let center {
                VStack(spacing: -6 * f.textScale) {
                    ForEach(slots(center), id: \.word.id) { slot in
                        row(slot, size: size)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: center)
        .frame(width: lens.width, height: lens.height)
        // The lens pumps with heavy bass: 0.45 at rest, up to 0.60 on a hit.
        .fisheyeLens(enabled: true, size: lens, strength: 0.45 + 0.15 * max(f.kick, max(0, f.bass - 0.5) * 2))
        .position(x: f.canvas.width / 2, y: f.bandCenterY)
    }

    private struct Slot { let word: TimedWord; let isCenter: Bool; let visibleSince: Double }

    /// Word j has been on screen since word j-1 started (when it slid in as "next").
    private func slots(_ i: Int) -> [Slot] {
        let words = frame.lyrics.words
        return [i - 1, i, i + 1].filter(words.indices.contains).map { j in
            Slot(word: words[j], isCenter: j == i, visibleSince: j > 0 ? words[j - 1].start : 0)
        }
    }

    private func row(_ slot: Slot, size: CGFloat) -> some View {
        let p = frame.palette
        let color = slot.isCenter ? p.highlight : p.text
        return HStack(spacing: size * 0.22) {
            Text(slot.word.text)
                .font(frame.font.font(size: size, weight: .heavy))
                .tracking(-0.02 * size)
                .lineLimit(1)
                .foregroundStyle(color)
            if withIcons, let v = WordVisualResolver.shared.visual(for: slot.word.text) {
                VisualIcon(visual: v, size: size * 0.85, color: slot.isCenter ? p.highlight : p.secondary, age: frame.position - slot.visibleSince,
                           kick: slot.isCenter ? frame.kick : 0)
            }
        }
        .opacity(slot.isCenter ? 1.0 : 0.45)
        .scaleEffect(slot.isCenter ? 1.08 * frame.thump(0.08) : 0.88)
        .shadow(color: slot.isCenter ? p.highlight.opacity(0.5 + 0.35 * Double(frame.kick)) : .clear, radius: size * 0.18 * (1 + frame.kick))
        .fixedSize()
    }
}
