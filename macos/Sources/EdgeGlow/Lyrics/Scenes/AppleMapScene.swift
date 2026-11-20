import CoreLocation
import SwiftUI

/// Apple Design Map — a walk across San Francisco (or wherever the lyrics go): each line is a leg of the
/// route on a real dark-mode `MKMapSnapshotter` picture, with a turn-by-turn banner reading the lyric,
/// a blue location dot walking in time, and a pin dropped for every line.
struct AppleMapScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let legs = AppleMapPlan.cache.value(for: f.songKey) { AppleMapPlan.build(f.lyrics) }
        let current = currentLeg(legs.count)
        ZStack {
            if let current {
                let rect = windowRect(legs, current)
                let radius = Motion.lerp(24, 30, enlargedness(legs, current))
                ZStack {
                    AppleMapStage(frame: f, legs: legs, current: current, window: rect.size, floating: floatingSize)
                    AppleMapChrome(frame: f, leg: legs[current], progress: legProgress(current), scale: chromeScale(rect.size))
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
                // A barely-there thump on kicks; the map stays readable.
                .scaleEffect(f.thump(0.012))
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: f.canvas.width, height: f.canvas.height)
    }

    // MARK: Timing

    private func currentLeg(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let g = frame.groupIndex { return g }
        if let next = frame.cursor.next { return max(0, next - 1) }
        return count - 1
    }

    private func legProgress(_ i: Int) -> Double {
        let start = frame.lineStart(i), end = max(frame.lineEnd(i), start + 0.5)
        return Motion.smooth((frame.position - start) / (end - start))
    }

    // MARK: Window

    private var floatingSize: CGSize {
        let w = min(frame.canvas.width * 0.62, 600 * frame.textScale)
        return CGSize(width: w, height: min(w * 0.64, frame.canvas.height * 0.8))
    }

    /// Keeps the floating map clear of the macOS lock-screen clock.
    private var lockScreenClearance: CGFloat { frame.locked ? frame.canvas.height * 0.28 : 12 }

    private func enlargedness(_ legs: [MapLeg], _ i: Int) -> Double {
        let cur = legs[i].enlarged ? 1.0 : 0.0
        let prev = i > 0 && legs[i - 1].enlarged ? 1.0 : 0.0
        return prev + (cur - prev) * Motion.spring(frame.position - frame.lineOnset(i), response: 0.55, damping: 0.85)
    }

    private func windowRect(_ legs: [MapLeg], _ i: Int) -> CGRect {
        let c = frame.canvas
        let top = lockScreenClearance
        let fs = floatingSize
        var cy = frame.bandCenterY
        cy = max(top + fs.height / 2, min(c.height - 12 - fs.height / 2, cy))
        let floating = CGRect(x: (c.width - fs.width) / 2, y: cy - fs.height / 2, width: fs.width, height: fs.height)
        let big = CGRect(x: 0, y: top, width: c.width, height: c.height - top)
        let e = enlargedness(legs, i)
        return CGRect(x: Motion.lerp(floating.minX, big.minX, e), y: Motion.lerp(floating.minY, big.minY, e),
                      width: Motion.lerp(floating.width, big.width, e), height: Motion.lerp(floating.height, big.height, e))
    }

    private func chromeScale(_ size: CGSize) -> CGFloat { max(0.8, min(1.4, size.width / 560)) * min(1.25, frame.textScale) }
}

// MARK: - Stage

/// Crossfades between leg pictures (`Layer(id, picture, transform, opacity)`), drawing the route, pins and
/// the walking dot over each.
struct AppleMapStage: View {
    let frame: LyricFrame
    let legs: [MapLeg]
    let current: Int
    let window: CGSize
    let floating: CGSize

    struct Layer: Identifiable {
        let id: Int
        let picture: MapPicture?
        let shot: MapShot
        let transform: CGAffineTransform
        let opacity: Double
        let overlay: Overlay
    }

    /// Everything drawn over a picture, projected on the main thread (Canvas may render off it).
    struct Overlay {
        var route: [CGPoint] = []
        var progress = 0.0
        var earlierPins: [(CGPoint, Color)] = []
        var pin: Color = .red
        var drop = 1.0
        var dot = CGPoint.zero
        var ink: CGFloat = 1
    }

    var body: some View {
        ZStack {
            ForEach(layers()) { layer in
                layerView(layer)
            }
        }
        .frame(width: window.width, height: window.height)
        .clipped()
    }

    private func shotSize(_ leg: MapLeg) -> CGSize {
        leg.enlarged ? CGSize(width: frame.canvas.width, height: frame.canvas.height) : floating
    }

    private func layers() -> [Layer] {
        let cache = MapSnapshotCache.shared
        // Pre-render the next legs while this one plays.
        for k in [current + 1, current + 2] where legs.indices.contains(k) {
            cache.request(legs[k].shot(shotSize(legs[k])))
        }
        let fade = Motion.smooth((frame.position - frame.lineOnset(current)) / 0.6)
        var out: [Layer] = []
        if current > 0, fade < 1 {
            out.append(layer(current - 1, opacity: 1 - fade, cache: cache))
        }
        out.append(layer(current, opacity: current > 0 ? fade : 1, cache: cache))
        return out
    }

    private func layer(_ i: Int, opacity: Double, cache: MapSnapshotCache) -> Layer {
        let leg = legs[i]
        let shot = leg.shot(shotSize(leg))
        let progress = Motion.smooth((frame.position - frame.lineStart(i)) / max(0.5, frame.lineEnd(i) - frame.lineStart(i)))
        // Slow push-in over the leg.
        let zoom = 1 + 0.06 * CGFloat(progress)
        let picture = cache.picture(shot)
        let project = picture?.project ?? MapMath.approximateProjection(shot)
        var o = Overlay()
        o.route = leg.road.points.map(project)
        o.progress = progress
        for k in 0..<i {
            let p = project(legs[k].to.coordinate)
            if p.x > -20, p.y > -20, p.x < shot.size.width + 20, p.y < shot.size.height + 20 { o.earlierPins.append((p, legs[k].pin)) }
        }
        o.pin = leg.pin
        o.drop = Motion.spring(frame.position - frame.lineOnset(i), response: 0.45, damping: 0.55)
        o.dot = MapMath.point(along: o.route, fraction: progress)
        o.ink = 1 / max(0.5, max(window.width / shot.size.width, window.height / shot.size.height))
        return Layer(id: i, picture: picture, shot: shot, transform: CGAffineTransform(scaleX: zoom, y: zoom), opacity: opacity, overlay: o)
    }

    private func layerView(_ layer: Layer) -> some View {
        let s = layer.shot.size
        let fill = max(window.width / s.width, window.height / s.height)
        return ZStack {
            if let picture = layer.picture {
                Image(nsImage: picture.image).resizable().frame(width: s.width, height: s.height)
            } else {
                Canvas { ctx, size in MapMath.drawPlaceholder(in: ctx, rect: CGRect(origin: .zero, size: size), seed: layer.id) }
                    .frame(width: s.width, height: s.height)
            }
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
                drawOverlay(layer, in: ctx)
            }
            .frame(width: s.width, height: s.height)
        }
        .scaleEffect(fill * layer.transform.a)
        .frame(width: window.width, height: window.height)
        .opacity(layer.opacity)
    }

    private func drawOverlay(_ layer: Layer, in ctx: GraphicsContext) {
        let o = layer.overlay
        let ink = o.ink
        MapMath.drawRoute(o.route, in: ctx, width: 6.0 * ink, color: AppleColors.blue, upTo: o.progress)
        for (p, color) in o.earlierPins { MapMath.drawPin(at: p, color: color, in: ctx, scale: 0.8 * ink) }
        if let first = o.route.first {
            ctx.fill(Path(ellipseIn: CGRect(x: first.x - 5 * ink, y: first.y - 5 * ink, width: 10 * ink, height: 10 * ink)), with: .color(.white.opacity(0.85)))
        }
        if let last = o.route.last { MapMath.drawPin(at: last, color: o.pin, in: ctx, scale: 1.1 * ink, drop: o.drop) }
        MapMath.drawLocationDot(at: o.dot, in: ctx, clock: frame.clock, scale: ink, kick: frame.kick)
    }
}

// MARK: - Chrome

/// Turn-by-turn banner (the lyric is the street), countdown distance and an arrival bar.
struct AppleMapChrome: View {
    let frame: LyricFrame
    let leg: MapLeg
    let progress: Double
    let scale: CGFloat

    private static let banner = [Color(hex: "#16804C"), Color(hex: "#0E5E37")]

    var body: some View {
        let remaining = leg.road.meters * (1 - progress)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14 * scale) {
                Image(systemName: leg.turnSymbol)
                    .font(.system(size: 34 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(MapDistance.format(remaining))
                        .font(.system(size: 22 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text(lyricLine)
                        .font(.system(size: 18 * scale, weight: .bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 12 * scale)
            .background(
                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                    .fill(LinearGradient(colors: Self.banner, startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .black.opacity(0.45), radius: 3.0, y: 2)
            .padding(12 * scale)

            Spacer(minLength: 0)

            HStack(spacing: 8 * scale) {
                Text(arrival(remaining)).font(.system(size: 15 * scale, weight: .bold)).foregroundStyle(.white)
                Text("·").foregroundStyle(AppleColors.gray)
                Text("\(max(1, Int((remaining / 1.4 / 60).rounded()))) min").font(.system(size: 13.8 * scale, weight: .semibold)).foregroundStyle(AppleColors.green)
                Text("·").foregroundStyle(AppleColors.gray)
                Text(leg.to.name).font(.system(size: 13.8 * scale, weight: .semibold)).foregroundStyle(AppleColors.gray).lineLimit(1)
            }
            .monospacedDigit()
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 9 * scale)
            .background(Capsule().fill(AppleColors.surface.opacity(0.94)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 3.0, y: 1)
            .padding(.bottom, 12 * scale)
        }
    }

    /// The current lyric, each word brightening as it is sung.
    private var lyricLine: AttributedString {
        var out = AttributedString()
        for (i, w) in frame.group(leg.line).enumerated() {
            var part = AttributedString((i > 0 ? " " : "") + w.text)
            let lit = frame.arrived(w) ? 1.0 : 0.45
            part.foregroundColor = Color.white.opacity(lit)
            out += part
        }
        return out
    }

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)

    private func arrival(_ remaining: Double) -> String {
        "Arrive " + Date().addingTimeInterval(max(60, remaining / 1.4)).formatted(Self.timeFormat)
    }
}
