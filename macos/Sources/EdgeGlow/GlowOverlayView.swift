import AppKit
import SwiftUI

/// Full-screen liquid rim that hugs the display bezel, pulsing with the bass and chasing with the vocals.
// Note: avoids @State on purpose. In the macOS 27 SDK @State is a macro, and the Command Line Tools
// ship without the SwiftUI macro plugin, so the renderer is injected by OverlayWindowManager instead.
struct GlowOverlayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var renderer: GlowRenderer

    /// The glow is a soft, heavily blurred rim, so it is rasterized at this fraction of the screen's pixel
    /// resolution and scaled up by the GPU. Every blur layer is a full-canvas offscreen texture, so
    /// reduced-area buffers cut the overlay's graphics memory in proportion, with no visible loss
    /// on a blurred gradient.
    static let renderScale: CGFloat = 0.4

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !renderer.animating)) { timeline in
                Canvas { context, size in
                    var scaled = context
                    scaled.scaleBy(x: Self.renderScale, y: Self.renderScale)
                    let full = CGSize(width: size.width / Self.renderScale, height: size.height / Self.renderScale)
                    renderer.draw(in: &scaled, size: full, date: timeline.date, state: state)
                }
                .frame(width: geo.size.width * Self.renderScale, height: geo.size.height * Self.renderScale)
                .scaleEffect(1 / Self.renderScale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
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

/// Per-frame render state for one display. Only `animating` is published; everything else is mutated
/// from inside the Canvas closure every frame and must not trigger view updates.
final class GlowRenderer: ObservableObject {
    @Published var animating = true

    /// The display this renderer draws on. Its notch (if any) shapes the bezel path; set by
    /// OverlayWindowManager on creation and whenever screen parameters change.
    var screen: NSScreen? {
        didSet {
            let newNotch = Self.notchRect(on: screen)
            if newNotch != notch {
                notch = newNotch
                geometrySize = .zero
            }
        }
    }

    private var notch: CGRect?

    private var lastDate: Date?
    private var angle = 0.0
    private var pulse = 0.0
    private var presence = 0.0
    private var primary = RGBColor.neonCyan
    private var secondary = RGBColor.neonMagenta
    /// Chasing style: leading comet head position along the perimeter (0…1, clockwise from top-center)
    /// and its smoothed speed in laps per second. Symmetry reuses the same vocal-driven speed.
    private var chasePosition = 0.0
    private var chaseRate = 0.0
    /// Symmetry style: direction of the current pass. True runs top-center → bottom-center, false runs
    /// bottom-center → top-center; it flips every time the mirrored heads merge.
    private var symmetryTopToBottom = true
    /// Progress of the current mirrored pair in perimeter fractions: 0 = spawning at the origin,
    /// 0.5 = heads merging at the opposite center.
    private var symmetryProgress = 0.0
    /// True while the previous pair's tails are still draining into the point the current pair left from.
    private var symmetryDraining = false

    /// Chasing speeds in laps per second: the glide with no vocals, and the extra speed at full vocal energy.
    private static let chaseGlideRate = 1.0 / 12.0
    private static let chaseVocalBoost = 0.6
    /// Symmetry comets travel this much faster than the chase comets (each only covers half a lap).
    private static let symmetrySpeed = 1.25

    // MARK: Kinetic physics state

    /// Rest position of one bezel "string" node, its inward unit normal, and its angle from screen center.
    private struct EdgeNode {
        let point: CGPoint
        let normal: CGVector
        let angle: Double
    }

    /// A glowing spark shot inward from the rim on an audio transient.
    private struct Spark {
        var position: CGPoint
        var velocity: CGVector
        var age: Double
        let life: Double
        let size: Double
        let color: RGBColor
    }

    private static let nodeCount = 240
    private static let cornerRadius = 16.0
    // The bezel is a closed spring–mass string: tension carries ripples along the edge (≈75 nodes/s),
    // stiffness pulls each node back to rest (≈4 Hz wobble) and damping rings it down within ~1 s.
    private static let stringTension = 5_600.0
    private static let stringStiffness = 630.0
    private static let stringDamping = 5.0
    private static let maxSparks = 180
    private static let sparkLinkDistance = 130.0

    private var nodes: [EdgeNode] = []
    /// Dense rest samples of the bezel (every few points), used to draw the bent string so that tight
    /// curves like the notch keep their exact shape while the nodes are displaced.
    private var samples: [OutlineSample] = []
    private var geometrySize = CGSize.zero
    /// The notch the current geometry was built with (nil if none, or if it didn't fit the canvas).
    private var geometryNotch: CGRect?
    /// Inward displacement (pt) and velocity (pt/s) of each node.
    private var displacement = [Double](repeating: 0, count: nodeCount)
    private var displacementVelocity = [Double](repeating: 0, count: nodeCount)
    /// False once the string has settled; the exact analytic bezel paths are drawn while asleep.
    private var stringAwake = false
    private var sparks: [Spark] = []
    // Transient detection: slow-moving averages to compare the live envelopes against, plus cooldowns.
    private var bassAverage = 0.0
    private var vocalAverage = 0.0
    private var bassCooldown = 0.0
    private var vocalCooldown = 0.0
    /// Screen-shake energy from heavy hits; decays quickly.
    private var shake = 0.0

    func draw(in context: inout GraphicsContext, size: CGSize, date: Date, state: AppState) {
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 1.0 / 15.0) } ?? 0
        lastDate = date

        // Frame-rate independent exponential smoothing.
        func approach(_ rate: Double) -> Double { 1 - exp(-dt * rate) }

        let style = state.animationStyle
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

        // Vocal velocity: the comets glide when there's no singing and surge on dense vocals. Speeding up
        // reacts quickly, slowing down eases off, and integrating dt means the comets never jump.
        let targetChaseRate: Double
        if audioReactive {
            targetChaseRate = Self.chaseGlideRate + Self.chaseVocalBoost * pow(levels.vocal, 1.5)
        } else {
            targetChaseRate = playing ? 1.0 / 8.0 : 1.0 / 14.0
        }
        chaseRate += (targetChaseRate - chaseRate) * approach(targetChaseRate > chaseRate ? 6 : 1.2)
        chasePosition = (chasePosition + dt * chaseRate).truncatingRemainder(dividingBy: 1)

        // Symmetry: alternating passes. The moment the mirrored heads merge, the direction flips and the
        // next pair launches from that same point back toward the opposite center, while the previous
        // pair's tails finish draining into it.
        symmetryProgress += dt * chaseRate * Self.symmetrySpeed
        var merged = false
        if symmetryProgress >= 0.5 {
            symmetryProgress = (symmetryProgress - 0.5).truncatingRemainder(dividingBy: 0.5)
            symmetryTopToBottom.toggle()
            symmetryDraining = true
            merged = style == .symmetry
        }
        if symmetryDraining, symmetryProgress >= state.cometLength {
            symmetryDraining = false
        }

        let bounds = CGRect(origin: .zero, size: size)
        prepareGeometry(for: size)
        // Physics keeps stepping even while faded out, so ripples and sparks always settle cleanly.
        // Sparks Only *is* the kinetic effect, so it ignores the toggle.
        let kinetic = state.kineticEffects || style == .sparksOnly
        updateKinetics(dt: dt, levels: levels, spawning: audioReactive && kinetic, merged: merged, state: state)

        guard presence > 0.002 else { return }

        let beat = pulse * state.reactivity
        let opacity = state.intensity * presence
        // Heavy impact: split the rim's color channels while the bass envelope is above 0.8.
        let aberration = kinetic && audioReactive ? min(max((levels.bass - 0.8) / 0.2, 0), 1) : 0
        var shaken = context
        if shake > 0.01 {
            let t = date.timeIntervalSinceReferenceDate
            let amplitude = min(shake, 1.5) * 6
            shaken.translateBy(x: amplitude * sin(t * 83), y: amplitude * cos(t * 71))
        }

        switch style {
        case .breathing:
            // Bass blooms the blur slightly on each kick (≈1× spread at a typical average bass level).
            drawRim(in: shaken, bounds: bounds, angle: angle, beat: beat, bloom: 0.9 + 0.3 * beat, opacity: opacity, aberration: aberration, state: state)
        case .chasing:
            let comets = [
                Comet(head: chasePosition, direction: 1, clip: nil),
                Comet(head: chasePosition + 0.5, direction: 1, clip: nil),
            ]
            drawComets(comets, in: shaken, bounds: bounds, beat: beat, opacity: opacity, aberration: aberration, state: state)
        case .symmetry:
            var comets = Self.symmetryComets(progress: symmetryProgress, topToBottom: symmetryTopToBottom)
            if symmetryDraining {
                // The previous pass, carried past its merge point so its clipped tails drain into it.
                comets += Self.symmetryComets(progress: 0.5 + symmetryProgress, topToBottom: !symmetryTopToBottom)
            }
            drawComets(comets, in: shaken, bounds: bounds, beat: beat, opacity: opacity, aberration: aberration, state: state)
            drawMergeGlow(in: shaken, bounds: bounds, beat: beat, opacity: opacity, state: state)
        case .sparksOnly:
            // No rim: the dark bezel is only revealed by the sparks it throws.
            break
        }

        drawSparks(in: context, opacity: opacity)
    }

    // MARK: Breathing

    /// The original two-layer rim with a rotating conic gradient.
    private func drawRim(in context: GraphicsContext, bounds: CGRect, angle: Double, beat: Double, bloom: Double, opacity: Double, aberration: Double, state: AppState) {
        let gradient = Gradient(colors: [primary.color, secondary.color, primary.color, secondary.color, primary.color])
        let shading = GraphicsContext.Shading.conicGradient(
            gradient,
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            angle: .radians(angle)
        )

        // Layer 1: ambient spill. Stroke is centered on the bezel, so the inner half bleeds onto the screen.
        let ambientPath = edgePath(in: bounds, inset: 0)
        var ambient = context
        ambient.addFilter(.blur(radius: state.glowSpread * bloom))
        ambient.opacity = opacity
        ambient.stroke(ambientPath, with: shading, lineWidth: state.thickness * (0.75 + 0.55 * beat))

        // Layer 2: crisp neon core pressed right against the bezel.
        let rimWidth = max(4, state.thickness * 0.22) * (1 + 0.25 * beat)
        let rimPath = edgePath(in: bounds, inset: rimWidth * 0.25)
        var rim = context
        rim.addFilter(.blur(radius: 8))
        rim.opacity = min(1, opacity * (0.85 + 0.3 * beat)) * (1 - 0.45 * aberration)
        rim.stroke(rimPath, with: shading, lineWidth: rimWidth)

        drawChromaticSplit(in: context, inset: rimWidth * 0.25, amount: aberration, opacity: opacity) { layer, inset in
            layer.stroke(self.edgePath(in: bounds, inset: inset), with: shading, lineWidth: rimWidth * 0.8)
        }
    }

    // MARK: Comets (Chasing, Symmetry)

    /// One comet of light on the bezel. Positions are perimeter fractions clockwise from top-center and
    /// may exceed 0…1 (they wrap) unless the comet is clipped.
    private struct Comet {
        var head: Double
        /// +1 travels clockwise, -1 counter-clockwise; the tail trails behind the head.
        var direction: Double
        /// Keeps the comet on one stretch of the perimeter (Symmetry's halves). Nil wraps freely.
        var clip: ClosedRange<Double>?
    }

    /// Each comet is drawn as a stack of overlapping trims that all share the head and reach
    /// progressively further back, so brightness ramps smoothly from the head into the tail.
    private static let cometLayerCount = 12
    /// Per-layer alpha (index 0 = shortest, at the head) chosen so the stacked result follows
    /// brightness(x) = (1 - x)^1.6 along the comet, x = 0 at the head and 1 at the tail end.
    private static let cometLayerAlphas: [Double] = {
        let n: Int = cometLayerCount
        var brightness: [Double] = []
        for j in 0...n {
            let x: Double = Double(j) / Double(n)
            brightness.append(j == n ? 0.0 : pow(1.0 - x, 1.6))
        }
        var alphas: [Double] = []
        for j in 0..<n {
            let ratio: Double = (1.0 - brightness[j]) / (1.0 - brightness[j + 1])
            alphas.append(1.0 - ratio)
        }
        return alphas
    }()

    private var cometHeadColor: RGBColor { primary.lerp(to: .white, t: 0.35) }

    /// Color at fraction `t` along a comet: white-hot head, primary body, secondary tail.
    private func cometColor(at t: Double) -> RGBColor {
        t < 0.3 ? cometHeadColor.lerp(to: primary, t: t / 0.3) : primary.lerp(to: secondary, t: (t - 0.3) / 0.7)
    }

    /// Comets over an otherwise dark bezel, with the same ambient spill + crisp core layering as the rim.
    /// Vocals set their speed (upstream); the bass owns their body: thickness, brightness and bloom.
    private func drawComets(_ comets: [Comet], in context: GraphicsContext, bounds: CGRect, beat: Double, opacity: Double, aberration: Double, state: AppState) {
        let length = state.cometLength

        let ambientPath = edgePath(in: bounds, inset: 0)
        var ambient = context
        ambient.addFilter(.blur(radius: state.glowSpread * (0.8 + 0.45 * beat)))
        ambient.opacity = opacity * (0.7 + 0.3 * min(beat, 1))
        ambient.drawLayer { layer in
            self.strokeComets(comets, along: ambientPath, length: length, lineWidth: state.thickness * (0.85 + 0.55 * beat), into: &layer)
        }

        let rimWidth = max(4, state.thickness * 0.22) * (1 + 0.25 * beat)
        let rimPath = edgePath(in: bounds, inset: rimWidth * 0.25)
        var rim = context
        rim.addFilter(.blur(radius: 8 * (1 + 0.5 * beat)))
        rim.opacity = min(1, opacity * (0.75 + 0.4 * beat)) * (1 - 0.45 * aberration)
        rim.drawLayer { layer in
            self.strokeComets(comets, along: rimPath, length: length, lineWidth: rimWidth, into: &layer)
        }

        // White-hot point at each head.
        var core = context
        core.blendMode = .plusLighter
        core.addFilter(.blur(radius: 4 + 2 * beat))
        core.opacity = opacity * (0.75 + 0.25 * min(beat, 1))
        let coreReach = min(0.008, length * 0.2)
        let coreStyle = StrokeStyle(lineWidth: rimWidth * 0.7, lineCap: .round)
        for comet in comets {
            guard let range = Self.cometRange(comet, reach: coreReach) else { continue }
            core.stroke(Self.segment(of: rimPath, from: range.lowerBound, to: range.upperBound), with: .color(cometHeadColor.lerp(to: .white, t: 0.4).color), style: coreStyle)
        }

        drawChromaticSplit(in: context, inset: rimWidth * 0.25, amount: aberration, opacity: opacity) { layer, inset in
            self.strokeComets(comets, along: self.edgePath(in: bounds, inset: inset), length: length, lineWidth: rimWidth * 0.8, into: &layer)
        }
    }

    private func strokeComets(_ comets: [Comet], along path: Path, length: Double, lineWidth: Double, into layer: inout GraphicsContext) {
        let n = Self.cometLayerCount
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        for comet in comets {
            // Longest (tail) first, so the brighter head layers composite on top.
            for k in stride(from: n - 1, through: 0, by: -1) {
                guard let range = Self.cometRange(comet, reach: length * Double(k + 1) / Double(n)) else { continue }
                let color = cometColor(at: Double(k) / Double(n - 1)).color.opacity(Self.cometLayerAlphas[k])
                layer.stroke(Self.segment(of: path, from: range.lowerBound, to: range.upperBound), with: .color(color), style: style)
            }
        }
    }

    /// The stretch of perimeter covered by `comet` from its head back `reach`, after clipping.
    private static func cometRange(_ comet: Comet, reach: Double) -> ClosedRange<Double>? {
        var from = comet.direction > 0 ? comet.head - reach : comet.head
        var to = comet.direction > 0 ? comet.head : comet.head + reach
        if let clip = comet.clip {
            from = max(from, clip.lowerBound)
            to = min(to, clip.upperBound)
        }
        return to - from > 0.0005 ? from...to : nil
    }

    /// The part of the closed bezel `path` between perimeter fractions `from` and `to` (to > from),
    /// wrapping across the top-center start point when needed.
    private static func segment(of path: Path, from: Double, to: Double) -> Path {
        let shift = from.rounded(.down)
        let a = from - shift
        let b = to - shift
        if b <= 1 { return path.trimmedPath(from: a, to: b) }
        var joined = path.trimmedPath(from: a, to: 1)
        joined.addPath(path.trimmedPath(from: 0, to: min(b - 1, 1)))
        return joined
    }

    // MARK: Symmetry

    /// Perimeter fraction where a Symmetry pass starts: top-center (0, the notch area on notched
    /// screens) or bottom-center (0.5). The pass merges at the other one.
    private static func symmetryOrigin(topToBottom: Bool) -> Double { topToBottom ? 0 : 0.5 }

    /// The mirrored pair of one Symmetry pass at `progress` (0…0.5, or beyond while draining). Each comet
    /// is clipped to its own half of the perimeter, so at the merge point they fuse instead of passing.
    private static func symmetryComets(progress p: Double, topToBottom: Bool) -> [Comet] {
        if topToBottom {
            // Right comet clockwise down the right edge, left comet counter-clockwise down the left.
            return [
                Comet(head: p, direction: 1, clip: 0...0.5),
                Comet(head: 1 - p, direction: -1, clip: 0.5...1),
            ]
        }
        // Right comet counter-clockwise up the right edge, left comet clockwise up the left.
        return [
            Comet(head: 0.5 - p, direction: -1, clip: 0...0.5),
            Comet(head: 0.5 + p, direction: 1, clip: 0.5...1),
        ]
    }

    /// Merge blooms as (perimeter fraction, strength): one swelling at the destination as the heads
    /// close in, and one fading at the origin while the previous pair's tails drain into it.
    private func symmetryBlooms(cometLength: Double) -> [(point: Double, glow: Double)] {
        let p = symmetryProgress
        let origin = Self.symmetryOrigin(topToBottom: symmetryTopToBottom)
        var blooms: [(point: Double, glow: Double)] = []
        let t = min(max((p - 0.45) / 0.05, 0), 1)
        let arriving = t * t * (3 - 2 * t)
        if arriving > 0.01 { blooms.append((origin + 0.5, arriving)) }
        if symmetryDraining {
            let draining = max(0, 1 - p / max(cometLength * 0.9, 0.01))
            if draining > 0.01 { blooms.append((origin, draining)) }
        }
        return blooms
    }

    /// Symmetry: a bloom at the merge point that swells as the mirrored heads arrive and fades while
    /// their tails drain into it; bottom-center on downward passes, top-center on upward ones.
    private func drawMergeGlow(in context: GraphicsContext, bounds: CGRect, beat: Double, opacity: Double, state: AppState) {
        let blooms = symmetryBlooms(cometLength: state.cometLength)
        guard !blooms.isEmpty else { return }

        let path = edgePath(in: bounds, inset: 0)
        let reach = 0.01 + 0.008 * min(beat, 1.5)
        var flash = context
        flash.blendMode = .plusLighter
        flash.addFilter(.blur(radius: state.glowSpread * (0.5 + 0.3 * beat)))
        let style = StrokeStyle(lineWidth: state.thickness * (1 + 0.6 * beat), lineCap: .round)
        for bloom in blooms {
            var layer = flash
            layer.opacity = opacity * bloom.glow
            // `segment` wraps, so a bloom at top-center (0) spans both sides of the path's start.
            layer.stroke(Self.segment(of: path, from: bloom.point - reach, to: bloom.point + reach), with: .color(cometHeadColor.color), style: style)
        }
    }

    // MARK: Chromatic impact

    /// Heavy-impact channel split: the crisp rim redrawn as a red copy pushed outward and a cyan copy
    /// pulled inward. `stroke` draws the rim (full ring or comets) at a given inset, so each copy keeps
    /// the rim's own alpha (in the comet styles only the comets split). Driven straight off the bass
    /// envelope, so it snaps back as the hit decays.
    private func drawChromaticSplit(in context: GraphicsContext, inset: Double, amount: Double, opacity: Double, stroke: (inout GraphicsContext, Double) -> Void) {
        guard amount > 0.01 else { return }
        let shift = 3 + 7 * amount
        let channels: [(inset: Double, red: Float, green: Float, blue: Float)] = [
            (inset - shift * 0.6, 1, 0, 0),
            (inset + shift, 0, 1, 1),
        ]
        for channel in channels {
            var split = context
            split.blendMode = .plusLighter
            split.opacity = min(1, opacity * amount * 1.1)
            // Replace RGB with a pure tint while keeping the stroke's alpha.
            var tint = ColorMatrix()
            tint.r1 = 0; tint.r5 = channel.red
            tint.g2 = 0; tint.g5 = channel.green
            tint.b3 = 0; tint.b5 = channel.blue
            split.addFilter(.colorMatrix(tint))
            split.addFilter(.blur(radius: 2.5))
            split.drawLayer { layer in
                stroke(&layer, channel.inset)
            }
        }
    }

    // MARK: Kinetic physics

    private func updateKinetics(dt: Double, levels: (bass: Double, vocal: Double), spawning: Bool, merged: Bool, state: AppState) {
        bassCooldown -= dt
        vocalCooldown -= dt

        if spawning, !nodes.isEmpty {
            let style = state.animationStyle
            let hot = hotNodes(style: style, cometLength: state.cometLength)

            // Bass transient: the envelope jumps well above its recent average.
            let bassRise = levels.bass - bassAverage
            if bassCooldown <= 0, levels.bass > 0.45, bassRise > 0.16 {
                let hit = min(max(bassRise * 2.2, 0.3), 1)
                let kick = hit * state.reactivity * 1_100 * (0.6 + state.thickness / 80)
                for index in hot {
                    pluck(at: index, velocity: kick, width: 7)
                }
                // A smaller thump across the whole bezel so every edge flexes a little.
                for i in displacementVelocity.indices {
                    displacementVelocity[i] += kick * 0.2
                }
                stringAwake = true
                // Sparks are all there is in Sparks Only, so each hit throws a fuller burst.
                let count = style == .sparksOnly ? 6 + Int((hit * 8).rounded()) : 3 + Int((hit * 5).rounded())
                spawnSparks(count: count, around: hot, color: primary.lerp(to: .white, t: 0.3), energy: hit)
                shake = min(shake + hit * hit * state.reactivity * (levels.bass > 0.7 ? 1 : 0.35), 1.5)
                bassCooldown = 0.14
            }

            // Vocal transient: a burst of secondary-colored sparks, no bounce. Sparks Only reacts to
            // hard bass hits alone.
            let vocalRise = levels.vocal - vocalAverage
            if style != .sparksOnly, vocalCooldown <= 0, levels.vocal > 0.5, vocalRise > 0.2 {
                let hit = min(max(vocalRise * 2, 0.3), 1)
                spawnSparks(count: 3 + Int((hit * 2).rounded()), around: hot, color: secondary.lerp(to: .white, t: 0.2), energy: hit * 0.8)
                vocalCooldown = 0.3
            }

            // Symmetry: the mirrored heads colliding flick the string and throw sparks at the merge point,
            // which (after the flip in draw) is the origin of the new pass.
            if merged {
                let mergePoint = nodeIndex(atFraction: Self.symmetryOrigin(topToBottom: symmetryTopToBottom))
                pluck(at: mergePoint, velocity: 450 * state.reactivity, width: 6)
                stringAwake = true
                spawnSparks(count: 5, around: [mergePoint], color: cometHeadColor, energy: 0.6)
            }
        }

        bassAverage += (levels.bass - bassAverage) * (1 - exp(-dt * 3))
        vocalAverage += (levels.vocal - vocalAverage) * (1 - exp(-dt * 2))
        shake *= exp(-dt * 9)
        stepString(dt: dt)
        stepSparks(dt: dt)
    }

    /// Nodes at the brightest points on the rim, where hits pluck the string and sparks spawn: the comet
    /// heads, the brighter of the two album colors in the rotating breathing gradient, or (with no rim
    /// at all) random spots around the bezel.
    private func hotNodes(style: AnimationStyle, cometLength: Double) -> [Int] {
        switch style {
        case .breathing:
            // Gradient stops [p, s, p, s, p]: primary sits at +0/+π, secondary at +π/2/+3π/2.
            let base = primary.luminance >= secondary.luminance ? angle : angle + .pi / 2
            return [base, base + .pi].map { nodeIndex(nearestAngle: $0) }
        case .chasing:
            return [chasePosition, chasePosition + 0.5].map { nodeIndex(atFraction: $0) }
        case .symmetry:
            // The current pair's heads, plus any merge point still blooming, so a hard bass hit during a
            // merge bursts right out of it (bottom-center or top-center, whichever is active).
            var points = Self.symmetryComets(progress: symmetryProgress, topToBottom: symmetryTopToBottom).map(\.head)
            points += symmetryBlooms(cometLength: cometLength).filter { $0.glow > 0.3 }.map(\.point)
            return points.map { nodeIndex(atFraction: $0) }
        case .sparksOnly:
            return (0..<3).map { _ in Int.random(in: 0..<nodes.count) }
        }
    }

    /// Nodes are spaced evenly by arc length from top-center, so a perimeter fraction maps straight to one.
    private func nodeIndex(atFraction t: Double) -> Int {
        let n = nodes.count
        return Int((t - t.rounded(.down)) * Double(n)) % n
    }

    private func nodeIndex(nearestAngle target: Double) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, node) in nodes.enumerated() {
            var delta = abs(node.angle - target).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta = 2 * .pi - delta }
            if delta < bestDistance {
                bestDistance = delta
                best = index
            }
        }
        return best
    }

    /// Gaussian inward velocity kick centered on one node, like plucking a string.
    private func pluck(at center: Int, velocity: Double, width: Double) {
        let n = displacementVelocity.count
        for i in 0..<n {
            var distance = abs(i - center)
            distance = min(distance, n - distance)
            displacementVelocity[i] += velocity * exp(-Double(distance * distance) / (2 * width * width))
        }
    }

    /// Integrates the closed string with semi-implicit Euler in small substeps for stability.
    private func stepString(dt: Double) {
        guard stringAwake, dt > 0 else { return }
        var d = displacement
        var v = displacementVelocity
        let n = d.count
        let steps = max(1, Int((dt / 0.005).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            for i in 0..<n {
                let left = d[i == 0 ? n - 1 : i - 1]
                let right = d[i == n - 1 ? 0 : i + 1]
                let acceleration = Self.stringTension * (left + right - 2 * d[i])
                    - Self.stringStiffness * d[i]
                    - Self.stringDamping * v[i]
                v[i] += acceleration * h
            }
            for i in 0..<n {
                d[i] = min(max(d[i] + v[i] * h, -30), 90)
            }
        }

        let maxDisplacement = d.reduce(0) { max($0, abs($1)) }
        let maxVelocity = v.reduce(0) { max($0, abs($1)) }
        if maxDisplacement < 0.05, maxVelocity < 0.5 {
            // Settled: snap to rest so drawing goes back to the exact analytic bezel paths.
            d = [Double](repeating: 0, count: n)
            v = d
            stringAwake = false
        }
        displacement = d
        displacementVelocity = v
    }

    private func spawnSparks(count: Int, around hot: [Int], color: RGBColor, energy: Double) {
        guard !nodes.isEmpty, !hot.isEmpty else { return }
        let n = nodes.count
        for k in 0..<count {
            let index = (hot[k % hot.count] + Int.random(in: -6...6) + n) % n
            let node = nodes[index]
            let depth = max(displacement[index], 0) + Double.random(in: 2...10)
            let speed = Double.random(in: 320...900) * (0.6 + 0.4 * energy)
            let drift = Double.random(in: -90...90)
            sparks.append(Spark(
                position: CGPoint(x: node.point.x + node.normal.dx * depth, y: node.point.y + node.normal.dy * depth),
                // Mostly straight inward, with some sideways drift along the edge.
                velocity: CGVector(
                    dx: node.normal.dx * speed - node.normal.dy * drift,
                    dy: node.normal.dy * speed + node.normal.dx * drift
                ),
                age: 0,
                life: Double.random(in: 0.8...1.25),
                size: Double.random(in: 1.6...3.6),
                color: color
            ))
        }
        if sparks.count > Self.maxSparks {
            sparks.removeFirst(sparks.count - Self.maxSparks)
        }
    }

    private func stepSparks(dt: Double) {
        guard !sparks.isEmpty else { return }
        let drag = exp(-dt * 2.6)
        for i in sparks.indices {
            sparks[i].velocity.dx *= drag
            sparks[i].velocity.dy *= drag
            sparks[i].position.x += sparks[i].velocity.dx * dt
            sparks[i].position.y += sparks[i].velocity.dy * dt
            sparks[i].age += dt
        }
        sparks.removeAll { $0.age >= $0.life }
    }

    private static func sparkAlpha(_ spark: Spark) -> Double {
        pow(max(1 - spark.age / spark.life, 0), 1.5)
    }

    /// Sparks as a constellation: faint links between nearby sparks, soft glowing halos, bright cores.
    private func drawSparks(in context: GraphicsContext, opacity: Double) {
        guard !sparks.isEmpty else { return }

        var links = context
        links.blendMode = .plusLighter
        for i in sparks.indices {
            let a = sparks[i]
            let alphaA = Self.sparkAlpha(a)
            for j in (i + 1)..<sparks.count {
                let b = sparks[j]
                let dx = a.position.x - b.position.x
                let dy = a.position.y - b.position.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < Self.sparkLinkDistance else { continue }
                let alpha = min(alphaA, Self.sparkAlpha(b)) * (1 - distance / Self.sparkLinkDistance) * 0.55 * opacity
                var line = Path()
                line.move(to: a.position)
                line.addLine(to: b.position)
                links.stroke(line, with: .color(a.color.color.opacity(alpha)), lineWidth: 0.7)
            }
        }

        // One blurred layer for all halos instead of a blur per spark.
        var halos = context
        halos.blendMode = .plusLighter
        halos.addFilter(.blur(radius: 6))
        halos.drawLayer { layer in
            for spark in sparks {
                let alpha = Self.sparkAlpha(spark)
                let radius = spark.size * 3.2 * (0.6 + 0.4 * alpha)
                let rect = CGRect(x: spark.position.x - radius, y: spark.position.y - radius, width: radius * 2, height: radius * 2)
                layer.fill(Path(ellipseIn: rect), with: .color(spark.color.color.opacity(alpha * 0.85 * opacity)))
            }
        }

        var cores = context
        cores.blendMode = .plusLighter
        for spark in sparks {
            let alpha = Self.sparkAlpha(spark)
            let radius = spark.size * (0.6 + 0.4 * alpha)
            let rect = CGRect(x: spark.position.x - radius, y: spark.position.y - radius, width: radius * 2, height: radius * 2)
            cores.fill(Path(ellipseIn: rect), with: .color(spark.color.lerp(to: .white, t: 0.6).color.opacity(alpha * opacity)))
        }
    }

    // MARK: Edge geometry

    /// Notch bottom-corner radius, and the small flare where the notch sides meet the top edge.
    private static let notchBottomRadius = 8.0
    private static let notchFlareRadius = 4.0
    /// Spacing (pt) of the dense samples used to draw the bent string.
    private static let sampleSpacing = 4.0

    /// The camera housing on `screen`, in the overlay's top-left-origin coordinates, or nil for a plain
    /// rectangle. Built-in notched panels report a tall top safe area; external displays report 0.
    private static func notchRect(on screen: NSScreen?) -> CGRect? {
        guard let screen, screen.safeAreaInsets.top > 30 else { return nil }
        let height = screen.safeAreaInsets.top
        let width = screen.frame.width
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let minX = left.width
            let maxX = width - right.width
            if maxX - minX > 40 {
                return CGRect(x: minX, y: 0, width: maxX - minX, height: height)
            }
        }
        let fallbackWidth = 200.0
        return CGRect(x: (width - fallbackWidth) / 2, y: 0, width: fallbackWidth, height: height)
    }

    /// The bezel path at `inset`, bent by the string displacement. While the string is at rest this is
    /// the exact analytic bezel (rounded rectangle, routed around the notch when there is one).
    /// Every variant starts at top-center and runs clockwise, so perimeter fractions line up with the
    /// string nodes for trimming comets.
    private func edgePath(in bounds: CGRect, inset: Double) -> Path {
        guard stringAwake, nodes.count == Self.nodeCount, geometrySize == bounds.size, !samples.isEmpty else {
            return Self.bezelPath(in: bounds, inset: inset, notch: geometrySize == bounds.size ? geometryNotch : nil)
        }
        var path = Path()
        for (k, sample) in samples.enumerated() {
            let offset = inset + displacement(atNode: sample.node)
            let point = CGPoint(x: sample.point.x + sample.normal.dx * offset, y: sample.point.y + sample.normal.dy * offset)
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Catmull-Rom interpolation of the closed string at fractional node position `t`.
    private func displacement(atNode t: Double) -> Double {
        let n = displacement.count
        let i = Int(t.rounded(.down))
        let f = t - Double(i)
        func d(_ k: Int) -> Double { displacement[((k % n) + n) % n] }
        let p0 = d(i - 1), p1 = d(i), p2 = d(i + 1), p3 = d(i + 2)
        return p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
    }

    /// Analytic bezel at `inset`: clockwise from top-center (the bottom-center of the notch when there
    /// is one). Screen corners keep a constant radius like the original inset RoundedRectangle; notch
    /// corners use true offsets so the stroke wraps the housing evenly.
    private static func bezelPath(in rect: CGRect, inset i: Double, notch: CGRect?) -> Path {
        let r = cornerRadius
        var corners: [(point: CGPoint, radius: Double)] = []
        let start: CGPoint
        if let notch {
            start = CGPoint(x: notch.midX, y: notch.maxY + i)
            corners.append((CGPoint(x: notch.maxX + i, y: notch.maxY + i), notchBottomRadius + i))
            corners.append((CGPoint(x: notch.maxX + i, y: rect.minY + i), notchFlareRadius - i))
        } else {
            start = CGPoint(x: rect.midX, y: rect.minY + i)
        }
        corners += [
            (CGPoint(x: rect.maxX - i, y: rect.minY + i), r),
            (CGPoint(x: rect.maxX - i, y: rect.maxY - i), r),
            (CGPoint(x: rect.minX + i, y: rect.maxY - i), r),
            (CGPoint(x: rect.minX + i, y: rect.minY + i), r),
        ]
        if let notch {
            corners.append((CGPoint(x: notch.minX - i, y: rect.minY + i), notchFlareRadius - i))
            corners.append((CGPoint(x: notch.minX - i, y: notch.maxY + i), notchBottomRadius + i))
        }

        var path = Path()
        path.move(to: start)
        for (k, corner) in corners.enumerated() {
            let next = k + 1 < corners.count ? corners[k + 1].point : start
            if corner.radius > 0.01 {
                path.addArc(tangent1End: corner.point, tangent2End: next, radius: corner.radius)
            } else {
                path.addLine(to: corner.point)
            }
        }
        path.addLine(to: start)
        path.closeSubpath()
        return path
    }

    /// Lays out the string nodes evenly by arc length around the bezel outline, plus the dense draw
    /// samples. Recomputed only when the overlay changes size or its screen's notch changes, which also
    /// resets in-flight physics.
    private func prepareGeometry(for size: CGSize) {
        let r = Self.cornerRadius
        guard size != geometrySize, size.width > 2 * r, size.height > 2 * r else { return }
        geometrySize = size
        let rect = CGRect(origin: .zero, size: size)

        // Only route around a notch that actually fits between the screen corners.
        let margin = r + Self.notchFlareRadius + 2
        if let notch,
           notch.minX > rect.minX + margin, notch.maxX < rect.maxX - margin,
           notch.height > Self.notchBottomRadius + Self.notchFlareRadius + 2, notch.height < size.height / 3 {
            geometryNotch = notch
        } else {
            geometryNotch = nil
        }

        let outline = BezelOutline(rect: rect, cornerRadius: r, notch: geometryNotch,
                                   notchBottomRadius: Self.notchBottomRadius, notchFlareRadius: Self.notchFlareRadius)
        nodes = (0..<Self.nodeCount).map { i in
            let (point, normal) = outline.sample(Double(i) / Double(Self.nodeCount) * outline.length)
            return EdgeNode(point: point, normal: normal, angle: atan2(point.y - rect.midY, point.x - rect.midX))
        }
        let sampleCount = max(64, Int(outline.length / Self.sampleSpacing))
        samples = (0..<sampleCount).map { i in
            let fraction = Double(i) / Double(sampleCount)
            let (point, normal) = outline.sample(fraction * outline.length)
            return OutlineSample(point: point, normal: normal, node: fraction * Double(Self.nodeCount))
        }
        displacement = [Double](repeating: 0, count: Self.nodeCount)
        displacementVelocity = displacement
        stringAwake = false
        sparks.removeAll()
    }
}

/// A rest point on the bezel, its inward unit normal, and its fractional string-node position.
private struct OutlineSample {
    let point: CGPoint
    let normal: CGVector
    let node: Double
}

/// The bezel at rest as line and arc segments, clockwise from top-center in y-down coordinates, so it
/// can be sampled by arc length (with inward normals) for the string nodes.
private struct BezelOutline {
    private enum Segment {
        case line(CGPoint, CGPoint)
        /// Angles in y-down canvas space; a positive sweep turns right (a convex screen corner), a
        /// negative one turns left (the notch's bottom corners).
        case arc(center: CGPoint, radius: Double, start: Double, sweep: Double)

        var length: Double {
            switch self {
            case let .line(a, b): return hypot(b.x - a.x, b.y - a.y)
            case let .arc(_, radius, _, sweep): return radius * abs(sweep)
            }
        }

        func sample(_ s: Double) -> (CGPoint, CGVector) {
            switch self {
            case let .line(a, b):
                let length = max(self.length, 1e-9)
                let dx = (b.x - a.x) / length
                let dy = (b.y - a.y) / length
                // Interior is on the right of the clockwise direction of travel.
                return (CGPoint(x: a.x + dx * s, y: a.y + dy * s), CGVector(dx: -dy, dy: dx))
            case let .arc(center, radius, start, sweep):
                let a = start + (sweep >= 0 ? 1 : -1) * s / radius
                let direction = CGVector(dx: cos(a), dy: sin(a))
                let point = CGPoint(x: center.x + radius * direction.dx, y: center.y + radius * direction.dy)
                // Convex corners face the arc center; the notch's concave corners face away from it.
                let sign = sweep >= 0 ? -1.0 : 1.0
                return (point, CGVector(dx: sign * direction.dx, dy: sign * direction.dy))
            }
        }
    }

    private let segments: [Segment]
    let length: Double

    init(rect: CGRect, cornerRadius r: Double, notch: CGRect?, notchBottomRadius rb: Double, notchFlareRadius rt: Double) {
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        var segments: [Segment] = []

        if let n = notch {
            // Along the notch's bottom, around its right corner, up its side and out along the top edge.
            segments += [
                .line(p(n.midX, n.maxY), p(n.maxX - rb, n.maxY)),
                .arc(center: p(n.maxX - rb, n.maxY - rb), radius: rb, start: .pi / 2, sweep: -.pi / 2),
                .line(p(n.maxX, n.maxY - rb), p(n.maxX, minY + rt)),
                .arc(center: p(n.maxX + rt, minY + rt), radius: rt, start: .pi, sweep: .pi / 2),
                .line(p(n.maxX + rt, minY), p(maxX - r, minY)),
            ]
        } else {
            segments.append(.line(p(rect.midX, minY), p(maxX - r, minY)))
        }
        segments += [
            .arc(center: p(maxX - r, minY + r), radius: r, start: -.pi / 2, sweep: .pi / 2),
            .line(p(maxX, minY + r), p(maxX, maxY - r)),
            .arc(center: p(maxX - r, maxY - r), radius: r, start: 0, sweep: .pi / 2),
            .line(p(maxX - r, maxY), p(minX + r, maxY)),
            .arc(center: p(minX + r, maxY - r), radius: r, start: .pi / 2, sweep: .pi / 2),
            .line(p(minX, maxY - r), p(minX, minY + r)),
            .arc(center: p(minX + r, minY + r), radius: r, start: .pi, sweep: .pi / 2),
        ]
        if let n = notch {
            segments += [
                .line(p(minX + r, minY), p(n.minX - rt, minY)),
                .arc(center: p(n.minX - rt, minY + rt), radius: rt, start: -.pi / 2, sweep: .pi / 2),
                .line(p(n.minX, minY + rt), p(n.minX, n.maxY - rb)),
                .arc(center: p(n.minX + rb, n.maxY - rb), radius: rb, start: .pi, sweep: -.pi / 2),
                .line(p(n.minX + rb, n.maxY), p(n.midX, n.maxY)),
            ]
        } else {
            segments.append(.line(p(minX + r, minY), p(rect.midX, minY)))
        }

        self.segments = segments
        length = segments.reduce(0) { $0 + $1.length }
    }

    /// Point and inward normal at arc length `distance` from top-center.
    func sample(_ distance: Double) -> (CGPoint, CGVector) {
        var s = max(distance, 0)
        for segment in segments {
            let length = segment.length
            if s < length { return segment.sample(s) }
            s -= length
        }
        let last = segments[segments.count - 1]
        return last.sample(last.length)
    }
}
