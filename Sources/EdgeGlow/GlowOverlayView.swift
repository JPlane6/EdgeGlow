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
    private var nodesSize = CGSize.zero
    /// Inward displacement (pt) and velocity (pt/s) of each node.
    private var displacement = [Double](repeating: 0, count: nodeCount)
    private var displacementVelocity = [Double](repeating: 0, count: nodeCount)
    /// False once the string has settled; the original RoundedRectangle paths are drawn while asleep.
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

        let bounds = CGRect(origin: .zero, size: size)
        prepareNodes(for: size)
        // Physics keeps stepping even while faded out, so ripples and sparks always settle cleanly.
        let kinetic = state.kineticEffects && state.animationStyle != .solid
        updateKinetics(dt: dt, levels: levels, spawning: audioReactive && kinetic, bounds: bounds, state: state)

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

        switch state.animationStyle {
        case .breathing:
            // Bass blooms the blur slightly on each kick (≈1× spread at a typical average bass level).
            drawRim(in: shaken, bounds: bounds, angle: angle, beat: beat, bloom: 0.9 + 0.3 * beat, opacity: opacity, aberration: aberration, state: state)
        case .chasing:
            drawChase(in: shaken, bounds: bounds, beat: beat, opacity: opacity, aberration: aberration, state: state)
        case .solid:
            drawRim(in: context, bounds: bounds, angle: -.pi / 2, beat: 0, bloom: 1, opacity: opacity, aberration: 0, state: state)
        }

        drawSparks(in: context, opacity: opacity)

        if state.notchGlowEnabled {
            drawNotchGlow(in: context, size: size, state: state, beat: state.animationStyle == .solid ? 0 : beat, opacity: opacity)
        }
    }

    /// The original two-layer rim (breathing style, and solid with a fixed angle and no beat).
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

        drawChromaticSplit(in: context, bounds: bounds, shading: shading, inset: rimWidth * 0.25, lineWidth: rimWidth, amount: aberration, opacity: opacity)
    }

    /// Two comets on opposite sides of the screen racing clockwise around the bezel, over a faint
    /// base ring so the edges never go fully dark. Uses the same ambient + crisp core layering as the rim.
    private func drawChase(in context: GraphicsContext, bounds: CGRect, beat: Double, opacity: Double, aberration: Double, state: AppState) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let headAngle = chaseHeadAngle(in: bounds)

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

        let ambientPath = edgePath(in: bounds, inset: 0)

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
        let rimPath = edgePath(in: bounds, inset: rimWidth * 0.25)
        var rim = context
        rim.addFilter(.blur(radius: 8 * (1 + 0.5 * beat)))
        rim.opacity = min(1, opacity * (0.75 + 0.4 * beat)) * (1 - 0.45 * aberration)
        rim.stroke(rimPath, with: cometShading, lineWidth: rimWidth)

        drawChromaticSplit(in: context, bounds: bounds, shading: cometShading, inset: rimWidth * 0.25, lineWidth: rimWidth, amount: aberration, opacity: opacity)
    }

    /// Angle (from screen center) of the leading chase comet's head, which moves at constant speed along the edges.
    private func chaseHeadAngle(in bounds: CGRect) -> Double {
        let head = Self.perimeterPoint(chasePosition, in: bounds)
        return atan2(head.y - bounds.midY, head.x - bounds.midX)
    }

    /// Heavy-impact channel split: the crisp rim redrawn as a red copy pushed outward and a cyan copy
    /// pulled inward. Each copy keeps the rim's own gradient as its alpha (so in Chasing only the comets
    /// split) and is driven straight off the bass envelope, so it snaps back as the hit decays.
    private func drawChromaticSplit(in context: GraphicsContext, bounds: CGRect, shading: GraphicsContext.Shading, inset: Double, lineWidth: Double, amount: Double, opacity: Double) {
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
            // Replace RGB with a pure tint while keeping the gradient's alpha.
            var tint = ColorMatrix()
            tint.r1 = 0; tint.r5 = channel.red
            tint.g2 = 0; tint.g5 = channel.green
            tint.b3 = 0; tint.b5 = channel.blue
            split.addFilter(.colorMatrix(tint))
            split.addFilter(.blur(radius: 2.5))
            split.stroke(edgePath(in: bounds, inset: channel.inset), with: shading, lineWidth: lineWidth * 0.8)
        }
    }

    // MARK: Kinetic physics

    private func updateKinetics(dt: Double, levels: (bass: Double, vocal: Double), spawning: Bool, bounds: CGRect, state: AppState) {
        bassCooldown -= dt
        vocalCooldown -= dt

        if spawning, !nodes.isEmpty {
            let hot = hotAngles(in: bounds, style: state.animationStyle).map { nodeIndex(nearestAngle: $0) }

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
                spawnSparks(count: 3 + Int((hit * 5).rounded()), around: hot, color: primary.lerp(to: .white, t: 0.3), energy: hit)
                shake = min(shake + hit * hit * state.reactivity * (levels.bass > 0.7 ? 1 : 0.35), 1.5)
                bassCooldown = 0.14
            }

            // Vocal transient: a burst of secondary-colored sparks, no bounce.
            let vocalRise = levels.vocal - vocalAverage
            if vocalCooldown <= 0, levels.vocal > 0.5, vocalRise > 0.2 {
                let hit = min(max(vocalRise * 2, 0.3), 1)
                spawnSparks(count: 3 + Int((hit * 2).rounded()), around: hot, color: secondary.lerp(to: .white, t: 0.2), energy: hit * 0.8)
                vocalCooldown = 0.3
            }
        }

        bassAverage += (levels.bass - bassAverage) * (1 - exp(-dt * 3))
        vocalAverage += (levels.vocal - vocalAverage) * (1 - exp(-dt * 2))
        shake *= exp(-dt * 9)
        stepString(dt: dt)
        stepSparks(dt: dt)
    }

    /// Angles of the two brightest points on the rim: the chase comet heads, or the brighter of the
    /// two album colors in the rotating breathing gradient.
    private func hotAngles(in bounds: CGRect, style: AnimationStyle) -> [Double] {
        let base: Double
        switch style {
        case .chasing:
            base = chaseHeadAngle(in: bounds)
        case .breathing, .solid:
            // Gradient stops [p, s, p, s, p]: primary sits at +0/+π, secondary at +π/2/+3π/2.
            base = primary.luminance >= secondary.luminance ? angle : angle + .pi / 2
        }
        return [base, base + .pi]
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
            // Settled: snap to rest so drawing goes back to the exact original rounded-rect paths.
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

    /// The bezel path at `inset`, bent by the string displacement. While the string is at rest this is
    /// exactly the original continuous RoundedRectangle, so the calm look is unchanged.
    private func edgePath(in bounds: CGRect, inset: Double) -> Path {
        guard stringAwake, nodes.count == Self.nodeCount, nodesSize == bounds.size else {
            return RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .path(in: bounds.insetBy(dx: inset, dy: inset))
        }
        let points = nodes.indices.map { i -> CGPoint in
            let node = nodes[i]
            let offset = inset + displacement[i]
            return CGPoint(x: node.point.x + node.normal.dx * offset, y: node.point.y + node.normal.dy * offset)
        }
        // Quadratic curves through the midpoints give a smooth closed curve with no kinks at the nodes.
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let n = points.count
        var path = Path()
        path.move(to: midpoint(points[n - 1], points[0]))
        for i in 0..<n {
            path.addQuadCurve(to: midpoint(points[i], points[(i + 1) % n]), control: points[i])
        }
        path.closeSubpath()
        return path
    }

    /// Lays out the string nodes evenly by arc length around the rounded bezel. Recomputed only when the
    /// overlay changes size (e.g. moved to another display), which also resets in-flight physics.
    private func prepareNodes(for size: CGSize) {
        let r = Self.cornerRadius
        guard size != nodesSize, size.width > 2 * r, size.height > 2 * r else { return }
        nodesSize = size
        let rect = CGRect(origin: .zero, size: size)
        let length = 2 * (rect.width + rect.height) - 8 * r + 2 * .pi * r
        nodes = (0..<Self.nodeCount).map { i in
            let (point, normal) = Self.roundedRectSample(Double(i) / Double(Self.nodeCount) * length, in: rect, radius: r)
            return EdgeNode(point: point, normal: normal, angle: atan2(point.y - rect.midY, point.x - rect.midX))
        }
        displacement = [Double](repeating: 0, count: Self.nodeCount)
        displacementVelocity = displacement
        stringAwake = false
        sparks.removeAll()
    }

    /// Point and inward normal at arc length `distance` around a rounded rect, clockwise from top-center
    /// (y-down coordinates).
    private static func roundedRectSample(_ distance: Double, in rect: CGRect, radius r: Double) -> (CGPoint, CGVector) {
        let quarterArc = .pi * r / 2
        var s = distance
        func arc(center: CGPoint, from start: Double) -> (CGPoint, CGVector) {
            let a = start + s / r
            let direction = CGVector(dx: cos(a), dy: sin(a))
            return (CGPoint(x: center.x + r * direction.dx, y: center.y + r * direction.dy), CGVector(dx: -direction.dx, dy: -direction.dy))
        }

        var segment = rect.width / 2 - r
        if s < segment { return (CGPoint(x: rect.midX + s, y: rect.minY), CGVector(dx: 0, dy: 1)) }
        s -= segment
        if s < quarterArc { return arc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2) }
        s -= quarterArc
        segment = rect.height - 2 * r
        if s < segment { return (CGPoint(x: rect.maxX, y: rect.minY + r + s), CGVector(dx: -1, dy: 0)) }
        s -= segment
        if s < quarterArc { return arc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0) }
        s -= quarterArc
        segment = rect.width - 2 * r
        if s < segment { return (CGPoint(x: rect.maxX - r - s, y: rect.maxY), CGVector(dx: 0, dy: -1)) }
        s -= segment
        if s < quarterArc { return arc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2) }
        s -= quarterArc
        segment = rect.height - 2 * r
        if s < segment { return (CGPoint(x: rect.minX, y: rect.maxY - r - s), CGVector(dx: 1, dy: 0)) }
        s -= segment
        if s < quarterArc { return arc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi) }
        s -= quarterArc
        return (CGPoint(x: rect.minX + r + s, y: rect.minY), CGVector(dx: 0, dy: 1))
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
