import SwiftUI

/// An SF Symbol or emoji for a lyric word. Pops in from `scale 0.2, opacity 0, -12°` with the word-icon
/// spring (response 0.30, damping 0.25).
///
/// The entrance is computed from `age` (seconds since the icon appeared) with the same spring step
/// response SwiftUI uses, rather than `@State` + `.onAppear`: in the macOS 27 SDK `@State` is a macro whose
/// plugin the Command Line Tools don't ship. It also makes the pop deterministic and frame-exact.
struct VisualIcon: View {
    let visual: WordVisual
    let size: CGFloat
    let color: Color
    var age: Double = 10
    /// Beat impulse (0…1): a crisp micro-bounce on every kick.
    var kick: CGFloat = 0

    var body: some View {
        let k = Motion.spring(age, response: 0.30, damping: 0.25)
        glyph
            .scaleEffect((0.2 + 0.8 * k) * (1 + 0.14 * kick))
            .offset(y: -size * 0.08 * kick)
            .opacity(Motion.smooth(age / 0.12))
            .rotationEffect(.degrees(-12 * (1 - k)))
    }

    @ViewBuilder private var glyph: some View {
        switch visual {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size))
        }
    }
}

/// The Codestyle Visual icon: a `VisualIcon` with the token's soft halo.
struct FlashIcon: View {
    let visual: WordVisual
    let size: CGFloat
    let color: Color
    var age: Double = 10
    var kick: CGFloat = 0

    var body: some View {
        VisualIcon(visual: visual, size: size, color: color, age: age, kick: kick)
            .shadow(color: color.opacity(0.55), radius: 6 * (1 + kick))
    }
}
