import SwiftUI

/// Full-screen liquid rim that hugs the display bezel and pulses to the beat.
// Note: avoids @State on purpose. In the macOS 27 SDK @State is a macro, and the Command Line Tools
// ship without the SwiftUI macro plugin, so the renderer is injected by OverlayController instead.
struct GlowOverlayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var renderer: GlowRenderer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !renderer.animating)) { timeline in
            Canvas { context, size in
                renderer.draw(in: &context, size: size, date: timeline.date, state: state)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { renderer.animating = state.glowActive }
        .onChange(of: state.glowActive) { _, active in
            if active {
                renderer.animating = true
            } else {
                // Keep ticking long enough for the fade-out to finish, then stop burning frames.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !state.glowActive { renderer.animating = false }
                }
            }
        }
    }
}

/// Per-frame render state. Only `animating` is published; everything else is mutated from inside the
/// Canvas closure every frame and must not trigger view updates.
final class GlowRenderer: ObservableObject {
    @Published var animating = true

    private var lastDate: Date?
    private var angle = 0.0
    private var pulse = 0.0
    private var presence = 0.0
    private var primary = RGBColor.neonCyan
    private var secondary = RGBColor.neonMagenta

    func draw(in context: inout GraphicsContext, size: CGSize, date: Date, state: AppState) {
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 1.0 / 15.0) } ?? 0
        lastDate = date

        // Frame-rate independent exponential smoothing.
        func approach(_ rate: Double) -> Double { 1 - exp(-dt * rate) }

        let playing = state.isPlaying
        let targetPresence = playing ? 1.0 : (state.idleWhenPaused ? 0.55 : 0.0)
        presence += (targetPresence - presence) * approach(2.5)

        // Liquid crossfade toward the current album colors.
        primary = primary.lerp(to: state.targetPrimary, t: approach(2.2))
        secondary = secondary.lerp(to: state.targetSecondary, t: approach(2.2))

        let spinRate = playing ? 0.35 * state.bpm / 120 : 0.12
        angle = (angle + dt * spinRate).truncatingRemainder(dividingBy: 2 * .pi)

        let rawPulse: Double
        if playing {
            // Kick-drum envelope phase-locked to the track position; +π/2 puts the peak on the beat.
            let beats = state.playbackPosition(at: date) * state.bpm / 60
            rawPulse = pow(0.5 + 0.5 * sin(2 * .pi * beats + .pi / 2), 2.2)
        } else {
            // Slow ambient breathing while idle.
            let t = date.timeIntervalSinceReferenceDate
            rawPulse = 0.35 * pow(0.5 + 0.5 * sin(2 * .pi * t / 6), 2.2)
        }
        // Light smoothing removes jitter from position re-anchoring without dulling the kick.
        pulse += (rawPulse - pulse) * approach(30)

        guard presence > 0.002 else { return }

        let beat = pulse * state.reactivity
        let opacity = state.intensity * presence
        let gradient = Gradient(colors: [primary.color, secondary.color, primary.color, secondary.color, primary.color])
        let bounds = CGRect(origin: .zero, size: size)
        let shading = GraphicsContext.Shading.conicGradient(
            gradient,
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            angle: .radians(angle)
        )

        // Layer 1: ambient spill. Stroke is centered on the bezel, so the inner half bleeds onto the screen.
        let ambientPath = RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: bounds)
        var ambient = context
        ambient.addFilter(.blur(radius: state.glowSpread))
        ambient.opacity = opacity
        ambient.stroke(ambientPath, with: shading, lineWidth: state.thickness * (0.75 + 0.55 * beat))

        // Layer 2: crisp neon core pressed right against the bezel.
        let rimWidth = max(4, state.thickness * 0.22) * (1 + 0.25 * beat)
        let rimPath = RoundedRectangle(cornerRadius: 16, style: .continuous)
            .path(in: bounds.insetBy(dx: rimWidth * 0.25, dy: rimWidth * 0.25))
        var rim = context
        rim.addFilter(.blur(radius: 8))
        rim.opacity = min(1, opacity * (0.85 + 0.3 * beat))
        rim.stroke(rimPath, with: shading, lineWidth: rimWidth)

        if state.notchGlowEnabled {
            drawNotchGlow(in: context, size: size, state: state, beat: beat, opacity: opacity)
        }
    }

    private func drawNotchGlow(in context: GraphicsContext, size: CGSize, state: AppState, beat: Double, opacity: Double) {
        let notch = state.notchSize
        let rect = CGRect(x: (size.width - notch.width) / 2, y: -4, width: notch.width, height: notch.height + 4)
        let pill = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: 12, bottomTrailing: 12, topTrailing: 0),
            style: .continuous
        ).path(in: rect)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [primary.color, secondary.color, primary.color]),
            startPoint: CGPoint(x: rect.minX, y: rect.midY),
            endPoint: CGPoint(x: rect.maxX, y: rect.midY)
        )

        var halo = context
        halo.addFilter(.blur(radius: 10 + 8 * beat))
        halo.opacity = opacity * (0.55 + 0.45 * min(beat, 1))
        halo.stroke(pill, with: shading, lineWidth: 4 + 6 * beat)

        var core = context
        core.addFilter(.blur(radius: 2))
        core.opacity = opacity * 0.9
        core.stroke(pill, with: shading, lineWidth: 1.5)
    }
}
