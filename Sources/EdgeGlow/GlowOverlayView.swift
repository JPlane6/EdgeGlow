import SwiftUI

/// Full-screen liquid rim that hugs the display bezel, pulsing with the bass and chasing with the vocals.
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
    /// Chasing style: comet head position along the perimeter (0…1, clockwise from top-center) and its
    /// smoothed speed in laps per second.
    private var chasePosition = 0.0
    private var chaseRate = 0.0

    /// Chasing speeds in laps per second: the glide with no vocals, and the extra speed at full vocal energy.
    private static let chaseGlideRate = 1.0 / 12.0
    private static let chaseVocalBoost = 0.6

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

        let spinRate = playing ? 0.35 : 0.12
        angle = (angle + dt * spinRate).truncatingRemainder(dividingBy: 2 * .pi)

        // Live system-audio energies (already envelope-followed on the audio thread).
        let audioReactive = state.audioReactive
        let levels = audioReactive ? state.audioLevels.snapshot() : (bass: 0.0, vocal: 0.0)

        let rawPulse: Double
        if audioReactive {
            // The kick drives the pulse directly.
            rawPulse = levels.bass
        } else {
            // Slow ambient breathing while idle (or while system audio access is unavailable).
            let t = date.timeIntervalSinceReferenceDate
            rawPulse = 0.35 * pow(0.5 + 0.5 * sin(2 * .pi * t / 6), 2.2)
        }
        // Light smoothing turns ~50 Hz audio updates into a fluid 60 fps pulse without dulling the kick.
        pulse += (rawPulse - pulse) * approach(30)

        // Vocal velocity: the comet glides when there's no singing and surges on dense vocals. Speeding up
        // reacts quickly, slowing down eases off, and integrating dt means the comet never jumps.
        let targetChaseRate: Double
        if audioReactive {
            targetChaseRate = Self.chaseGlideRate + Self.chaseVocalBoost * pow(levels.vocal, 1.5)
        } else {
            targetChaseRate = playing ? 1.0 / 8.0 : 1.0 / 14.0
        }
        chaseRate += (targetChaseRate - chaseRate) * approach(targetChaseRate > chaseRate ? 6 : 1.2)
        chasePosition = (chasePosition + dt * chaseRate).truncatingRemainder(dividingBy: 1)

        guard presence > 0.002 else { return }

        let beat = pulse * state.reactivity
        let opacity = state.intensity * presence
        let bounds = CGRect(origin: .zero, size: size)

        switch state.animationStyle {
        case .breathing:
            // Bass blooms the blur slightly on each kick (≈1× spread at a typical average bass level).
            drawRim(in: context, bounds: bounds, angle: angle, beat: beat, bloom: 0.9 + 0.3 * beat, opacity: opacity, state: state)
        case .chasing:
            drawChase(in: context, bounds: bounds, beat: beat, opacity: opacity, state: state)
        case .solid:
            drawRim(in: context, bounds: bounds, angle: -.pi / 2, beat: 0, bloom: 1, opacity: opacity, state: state)
        }

        if state.notchGlowEnabled {
            drawNotchGlow(in: context, size: size, state: state, beat: state.animationStyle == .solid ? 0 : beat, opacity: opacity)
        }
    }

    /// The original two-layer rim (breathing style, and solid with a fixed angle and no beat).
    private func drawRim(in context: GraphicsContext, bounds: CGRect, angle: Double, beat: Double, bloom: Double, opacity: Double, state: AppState) {
        let gradient = Gradient(colors: [primary.color, secondary.color, primary.color, secondary.color, primary.color])
        let shading = GraphicsContext.Shading.conicGradient(
            gradient,
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            angle: .radians(angle)
        )

        // Layer 1: ambient spill. Stroke is centered on the bezel, so the inner half bleeds onto the screen.
        let ambientPath = RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: bounds)
        var ambient = context
        ambient.addFilter(.blur(radius: state.glowSpread * bloom))
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
    }

    /// Two comets on opposite sides of the screen racing clockwise around the bezel, over a faint
    /// base ring so the edges never go fully dark. Uses the same ambient + crisp core layering as the rim.
    private func drawChase(in context: GraphicsContext, bounds: CGRect, beat: Double, opacity: Double, state: AppState) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let head = Self.perimeterPoint(chasePosition, in: bounds)
        // The head moves at constant speed along the edges; aim the conic gradient's seam at it.
        let headAngle = atan2(head.y - center.y, head.x - center.x)

        // Gradient locations increase clockwise from the seam. Each half holds one comet: dark ahead of
        // the head, then a tail brightening from the secondary color into a white-hot primary head that
        // ends on a sharp leading edge at the seam (location 0.5 / 1.0).
        let headColor = primary.lerp(to: RGBColor(r: 1, g: 1, b: 1), t: 0.35).color
        var stops: [Gradient.Stop] = []
        for offset in [0.0, 0.5] {
            stops += [
                Gradient.Stop(color: secondary.color.opacity(0), location: offset),
                Gradient.Stop(color: secondary.color.opacity(0), location: offset + 0.22),
                Gradient.Stop(color: secondary.color.opacity(0.4), location: offset + 0.36),
                Gradient.Stop(color: primary.color.opacity(0.9), location: offset + 0.47),
                Gradient.Stop(color: headColor, location: offset + 0.4995),
            ]
        }
        let cometShading = GraphicsContext.Shading.conicGradient(Gradient(stops: stops), center: center, angle: .radians(headAngle))
        let baseShading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: [primary.color, secondary.color, primary.color, secondary.color, primary.color]),
            center: center,
            angle: .radians(headAngle)
        )

        let ambientPath = RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: bounds)

        var base = context
        base.addFilter(.blur(radius: state.glowSpread))
        base.opacity = opacity * 0.25
        base.stroke(ambientPath, with: baseShading, lineWidth: state.thickness * 0.75)

        // Bass owns the comet's body: thickness, brightness and bloom all swell on the kick.
        var ambient = context
        ambient.addFilter(.blur(radius: state.glowSpread * (0.8 + 0.45 * beat)))
        ambient.opacity = opacity * (0.7 + 0.3 * min(beat, 1))
        ambient.stroke(ambientPath, with: cometShading, lineWidth: state.thickness * (0.85 + 0.55 * beat))

        let rimWidth = max(4, state.thickness * 0.22) * (1 + 0.25 * beat)
        let rimPath = RoundedRectangle(cornerRadius: 16, style: .continuous)
            .path(in: bounds.insetBy(dx: rimWidth * 0.25, dy: rimWidth * 0.25))
        var rim = context
        rim.addFilter(.blur(radius: 8 * (1 + 0.5 * beat)))
        rim.opacity = min(1, opacity * (0.75 + 0.4 * beat))
        rim.stroke(rimPath, with: cometShading, lineWidth: rimWidth)
    }

    /// Point at fraction `t` of the way around `rect`, starting at top-center and moving clockwise
    /// (top → right → bottom → left) in the canvas's y-down coordinates.
    private static func perimeterPoint(_ t: Double, in rect: CGRect) -> CGPoint {
        let w = rect.width
        let h = rect.height
        var d = t * 2 * (w + h)
        if d < w / 2 { return CGPoint(x: rect.midX + d, y: rect.minY) }
        d -= w / 2
        if d < h { return CGPoint(x: rect.maxX, y: rect.minY + d) }
        d -= h
        if d < w { return CGPoint(x: rect.maxX - d, y: rect.maxY) }
        d -= w
        if d < h { return CGPoint(x: rect.minX, y: rect.maxY - d) }
        d -= h
        return CGPoint(x: rect.minX + d, y: rect.minY)
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
