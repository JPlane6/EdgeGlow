import AppKit
import SwiftUI

/// Orbital — the album cover as a disc in the middle of the screen, wrapped by a live 360° equalizer, with
/// the current line in bold kinetic caps to its left. The ring reads EdgeGlow's live FFT and spectral flux
/// (or a beat-timed stand-in when system audio isn't captured); the disc thumps with the bass and kick.
struct OrbitalScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let layout = OrbitalLayout(frame: f)
        let pulse = 1 + 0.15 * f.bass
        // Heavy hits (kick above 0.55) slam the rim and halo.
        let hit = Motion.clamp01((f.audio.kick - 0.55) / 0.45)
        ZStack(alignment: .topLeading) {
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
                OrbitalRing.draw(in: ctx, layout: layout, frame: f, pulse: pulse)
            }
            OrbitalDisc(artwork: f.track.artwork, diameter: layout.discRadius * 2, accent: f.palette.highlight,
                        scale: layout.scale, bass: Double(f.bass), hit: hit)
                .scaleEffect(pulse)
                .position(layout.center)
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
                OrbitalLyrics.draw(in: ctx, frame: f, layout: layout)
            }
        }
        .frame(width: f.canvas.width, height: f.canvas.height)
    }
}

// MARK: - Layout

/// Where the disc, its ring and the lyric column go on this canvas.
struct OrbitalLayout {
    let center: CGPoint
    let discRadius: CGFloat
    /// Longest a spoke can reach past `baseRadius` (at full amplitude).
    let maxExtension: CGFloat
    /// Disc size relative to its default (line widths and glows follow it).
    let scale: CGFloat
    /// The lyric column. Beside the ring it spans 6%…36% of the width (never closer to the ring than the
    /// longest spike, its sparks and bloom); on narrow canvases it drops below the ring instead.
    let lyricRect: CGRect
    let lyricsBelow: Bool

    /// Disc at full pulse + gap + spike + peak sparks + bloom.
    private static func reach(_ r: CGFloat, _ ext: CGFloat, _ s: CGFloat) -> CGFloat { r * 1.15 + 4 * s + ext + 26 * s }

    init(frame f: LyricFrame) {
        let w = f.canvas.width, h = f.canvas.height
        // Separate the user's Size slider from the screen factor so the disc doesn't scale twice.
        let screenFactor = max(0.01, LyricStage.textScale(user: 1, canvas: f.canvas))
        let user = min(1.3, max(0.75, f.textScale / screenFactor))
        // 20% of the screen's short side; the lyric canvas is 85% of the screen.
        let r = min(w, h) * (0.20 / 0.85) * 0.5 * user
        let s = r / 90
        scale = s
        discRadius = r

        let left = w * 0.06
        let minColumn = 230 * min(1, f.textScale)
        func columnRight(_ ext: CGFloat) -> CGFloat { min(w * 0.36, w * 0.5 - Self.reach(r, ext, s) - 20 * s) }
        // Spikes reach 1.15 × the disc radius, shortened (down to 0.75×) only when the lyric column needs room.
        var ext = r * 1.15
        let shortfall = minColumn - (columnRight(ext) - left)
        if shortfall > 0 { ext = max(r * 0.75, ext - shortfall) }
        maxExtension = ext
        let reach = Self.reach(r, ext, s)
        let besideRight = columnRight(ext)

        if besideRight - left >= 190 * min(1, f.textScale) {
            lyricsBelow = false
            let cy = h < reach * 2 ? h / 2 : min(max(f.bandCenterY, reach), h - reach)
            center = CGPoint(x: w * 0.5, y: cy)
            let column = min(h * 0.72, h - 24)
            lyricRect = CGRect(x: left, y: cy - column / 2, width: besideRight - left, height: column)
        } else {
            // Portrait / narrow canvas: ring in the upper part, lyrics centered underneath.
            lyricsBelow = true
            let cy = max(reach, min(h * 0.36, h - reach - 140 * f.textScale))
            center = CGPoint(x: w * 0.5, y: cy)
            let top = cy + reach + 10 * s
            lyricRect = CGRect(x: w * 0.07, y: top, width: w * 0.86, height: max(80, h - top - 16))
        }
    }

    var baseRadius: CGFloat { discRadius + 4 * scale }
}

// MARK: - Equalizer ring

enum OrbitalRing {
    static let spokes = 120
    static let cream = Color(hex: "#FFF8E7")

    /// Spectrum value at `m` (0 = lowest band … 1 = highest), linearly interpolated with only a slight
    /// blend of the neighbors, so individual bands spike on their own.
    static func value(_ bands: [Double], at m: Double) -> Double {
        guard bands.count > 1 else { return bands.first ?? 0 }
        func at(_ x: Double) -> Double {
            let p = min(max(x, 0), 1) * Double(bands.count - 1)
            let i = Int(p), j = min(i + 1, bands.count - 1)
            return bands[i] + (bands[j] - bands[i]) * (p - Double(i))
        }
        let d = 0.5 / Double(bands.count)
        return max(0, 0.12 * at(m - d) + 0.76 * at(m) + 0.12 * at(m + d))
    }

    /// Spoke amplitudes (0…1): level plus fresh transients, through a contrast curve for jagged peaks.
    static func amplitudes(_ audio: LyricAudio) -> (amp: [Double], flux: [Double]) {
        let n = spokes
        var amp = [Double](repeating: 0, count: n), flux = [Double](repeating: 0, count: n)
        for k in 0..<n {
            // Low end at the top, mirrored across the vertical axis: both halves meet seamlessly.
            let m = Double(min(k, n - k)) / Double(n / 2)
            let raw = value(audio.bands, at: m)
            let fx = value(audio.bandFlux, at: m)
            amp[k] = pow(Motion.clamp01(raw * 1.45 + fx * 2.2), 1.35)
            flux[k] = fx
        }
        return (amp, flux)
    }

    static func draw(in ctx: GraphicsContext, layout l: OrbitalLayout, frame f: LyricFrame, pulse: CGFloat) {
        let p = f.palette
        let c = l.center
        let base = l.discRadius * pulse + 4 * l.scale
        let ext = l.maxExtension
        let n = spokes
        let (amp, flux) = amplitudes(f.audio)
        let sparks = OrbitalPeaks.shared.step(levels: amp, flux: flux, clock: f.clock, still: f.still)
        let surge = Motion.clamp01(0.55 * f.audio.energy + 0.6 * f.audio.kick)

        var tips: [CGPoint] = []
        tips.reserveCapacity(n)
        var bars = Path()
        var dots = Path()
        let dotR = 1.7 * l.scale
        for k in 0..<n {
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(k) / Double(n)
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            // A small floor keeps a tight ripple during quiet vocals; drops spike out to the full extension.
            let len = ext * CGFloat(0.035 + 0.965 * amp[k])
            let tip = c + dir * (base + len)
            bars.move(to: c + dir * base)
            bars.addLine(to: tip)
            tips.append(tip)
            // Peak-hold spark floating just beyond the spoke.
            if sparks[k] > 0.3 {
                let at = c + dir * (base + ext * CGFloat(sparks[k]) + 5 * l.scale)
                dots.addEllipse(in: CGRect(x: at.x - dotR, y: at.y - dotR, width: dotR * 2, height: dotR * 2))
            }
        }

        let gradient = Gradient(stops: [
            .init(color: cream, location: 0),
            .init(color: cream.mixed(p.highlight, 0.55), location: 0.08),
            .init(color: p.highlight, location: 0.3),
            .init(color: p.secondary, location: 0.78),
            .init(color: p.secondary.mixed(p.highlight, 0.25), location: 1),
        ])
        let shading = GraphicsContext.Shading.radialGradient(gradient, center: c, startRadius: base, endRadius: base + ext)

        // Ribbon: a smooth closed curve through the spoke tips, filled down to the disc, behind the bars.
        // It thickens from 0.20 to 0.50 opacity with energy and kicks.
        var ribbon = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        ribbon.move(to: mid(tips[n - 1], tips[0]))
        for k in 0..<n {
            ribbon.addQuadCurve(to: mid(tips[k], tips[(k + 1) % n]), control: tips[k])
        }
        ribbon.closeSubpath()
        ribbon.addEllipse(in: CGRect(x: c.x - base, y: c.y - base, width: base * 2, height: base * 2))
        var fill = ctx
        fill.opacity = 0.20 + 0.30 * surge
        fill.fill(ribbon, with: shading, style: FillStyle(eoFill: true))

        // Bars and sparks with an outer bloom that surges from 10 to 24 pt.
        var glow = ctx
        glow.addFilter(.shadow(color: p.highlight.opacity(0.9), radius: (10 + 14 * CGFloat(surge)) * l.scale))
        glow.stroke(bars, with: shading, style: StrokeStyle(lineWidth: (2.2 + 0.6 * f.kick) * l.scale, lineCap: .round))
        glow.fill(dots, with: .color(cream.mixed(p.highlight, 0.25)))
    }
}

/// Peak-hold sparks: each spoke's spark rides its tip, is launched outward by fresh transients and falls
/// back under gravity. Shared by every display (time-based, so each advances by its own elapsed time).
final class OrbitalPeaks: @unchecked Sendable {
    static let shared = OrbitalPeaks()

    private static let gravity = 5.0       // extensions per second²
    private static let launch = 2.4        // extensions per second per unit of flux
    private static let ceiling = 1.05

    private let lock = NSLock()
    private var heights = [Double](repeating: 0, count: OrbitalRing.spokes)
    private var velocity = [Double](repeating: 0, count: OrbitalRing.spokes)
    private var lastClock: Double?

    /// Advances the sparks to `clock` and returns each spoke's spark height (in units of `maxExtension`).
    func step(levels: [Double], flux: [Double], clock: Double, still: Bool) -> [Double] {
        // Stills have no history: place sparks just above the tips, higher where transients are fresh.
        if still { return zip(levels, flux).map { min(Self.ceiling, $0 + 0.05 + 0.3 * $1) } }
        lock.lock()
        defer { lock.unlock() }
        guard levels.count == heights.count else { return heights }
        if let last = lastClock, abs(clock - last) < 0.0005 { return heights }
        let dt = lastClock.map { min(max(clock - $0, 0), 1.0 / 15.0) } ?? (1.0 / 60.0)
        lastClock = clock
        for k in heights.indices {
            let floor = levels[k] + 0.04
            let resting = heights[k] - floor < 0.02
            if resting, flux[k] > 0.12 { velocity[k] = max(velocity[k], flux[k] * Self.launch) }
            velocity[k] -= Self.gravity * dt
            heights[k] = min(Self.ceiling, heights[k] + velocity[k] * dt)
            if heights[k] <= floor {
                // The spoke carries the spark up (and catches it on the way down).
                heights[k] = min(Self.ceiling, floor)
                velocity[k] = max(0, velocity[k])
            }
            if heights[k] >= Self.ceiling { velocity[k] = min(0, velocity[k]) }
        }
        return heights
    }
}

// MARK: - Album disc

private struct OrbitalDisc: View {
    let artwork: NSImage?
    let diameter: CGFloat
    let accent: Color
    let scale: CGFloat
    let bass: Double
    /// 0…1 strength of a heavy hit (kick above 0.55).
    let hit: Double

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(accent, lineWidth: (2.5 + 2.5 * CGFloat(hit)) * scale))
        .shadow(color: accent.opacity(0.55 + 0.37 * hit), radius: (18 + 6 * CGFloat(bass) + 24 * CGFloat(hit)) * scale)
    }

    /// Dark brushed-metal disc with a music note, until the cover arrives.
    private var placeholder: some View {
        ZStack {
            AngularGradient(colors: [Color(hex: "#2A2C31"), Color(hex: "#5C6068"), Color(hex: "#1D1F23"),
                                     Color(hex: "#4B4F57"), Color(hex: "#24262B"), Color(hex: "#2A2C31")],
                            center: .center)
            RadialGradient(colors: [Color.white.opacity(0.14), .clear], center: UnitPoint(x: 0.34, y: 0.28),
                           startRadius: 0, endRadius: diameter * 0.62)
            ForEach(1..<5) { i in
                Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.6)
                    .frame(width: diameter * (0.35 + 0.15 * CGFloat(i)), height: diameter * (0.35 + 0.15 * CGFloat(i)))
            }
            Image(systemName: "music.note")
                .font(.system(size: diameter * 0.3, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }
}

// MARK: - Kinetic lyrics

enum OrbitalLyrics {
    static func draw(in ctx: GraphicsContext, frame f: LyricFrame, layout l: OrbitalLayout) {
        for (gi, alpha) in f.visibleGroups() where alpha > 0.001 {
            var c = ctx
            c.opacity = alpha
            // The outgoing line lifts away as it fades.
            if gi != f.groupIndex { c.translateBy(x: 0, y: -CGFloat(1 - alpha) * 26 * f.textScale) }
            drawLine(gi, in: c, frame: f, layout: l)
        }
    }

    private struct Placed {
        var word: TimedWord
        var text: GraphicsContext.ResolvedText
        var origin: CGPoint
        var size: CGSize
    }

    private static func drawLine(_ gi: Int, in ctx: GraphicsContext, frame f: LyricFrame, layout l: OrbitalLayout) {
        let words = f.group(gi)
        guard !words.isEmpty else { return }
        let rect = l.lyricRect
        let ts = f.textScale
        let caps = words.map { $0.text.uppercased() }

        // 34–48 pt × text scale, a little smaller for long lines, then shrunk until it wraps into ≤ 3 lines.
        let letters = caps.reduce(0) { $0 + $1.count }
        let size0 = min(48, max(34, 48 - CGFloat(letters - 10) * 0.45)) * ts
        func resolve(_ s: String, _ size: CGFloat) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(OrbitalType.font(f.font, size: size)).tracking(-0.02 * size).foregroundColor(.white))
        }
        func advance(_ size: CGFloat) -> CGFloat { size * 1.19 - 4 * ts }
        func gap(_ size: CGFloat) -> CGFloat { size * 0.24 }
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let resolved0 = caps.map { resolve($0, size0) }
        let widths0 = resolved0.map { $0.measure(in: unbounded).width }

        var size = size0
        var rows = wrap(widths0, gap: gap(size0), width: rect.width)
        for _ in 0..<8 {
            let k = size / size0
            rows = wrap(widths0.map { $0 * k }, gap: gap(size), width: rect.width)
            let widest = widths0.max().map { $0 * k } ?? 0
            if rows.count <= 3, CGFloat(rows.count) * advance(size) <= rect.height, widest <= rect.width { break }
            if size <= 16 * ts { break }
            size *= 0.9
        }
        let resolved = size == size0 ? resolved0 : caps.map { resolve($0, size) }
        let sizes = resolved.map { $0.measure(in: unbounded) }
        rows = wrap(sizes.map(\.width), gap: gap(size), width: rect.width)

        let lineAdvance = advance(size)
        let top = rect.midY - CGFloat(rows.count) * lineAdvance / 2
        var placed: [Placed] = []
        for (r, row) in rows.enumerated() {
            let rowWidth = row.map { sizes[$0].width }.reduce(0, +) + gap(size) * CGFloat(max(0, row.count - 1))
            var x = l.lyricsBelow ? rect.midX - rowWidth / 2 : rect.minX
            let y = top + lineAdvance * (CGFloat(r) + 0.5)
            for i in row {
                placed.append(Placed(word: words[i], text: resolved[i], origin: CGPoint(x: x, y: y), size: sizes[i]))
                x += sizes[i].width + gap(size)
            }
        }

        // One layer for the whole line: a soft white bloom and a dark drop shadow for any wallpaper.
        var c = ctx
        c.addFilter(.shadow(color: Color.white.opacity(0.25), radius: 6 * ts))
        c.addFilter(.shadow(color: Color.black.opacity(0.65), radius: 12 * ts, x: 0, y: 4 * ts))
        let settled = f.palette.text
        c.drawLayer { layer in
            for p in placed where f.arrived(p.word) {
                let t = f.position - p.word.start
                let pop = Motion.spring(t, response: 0.25, damping: 0.70)
                // Lit while sung, then eases down to the settled level over 0.2 s.
                let lit = f.isActive(p.word) ? 1 : Motion.clamp01(1 - (f.position - max(p.word.end, p.word.start + 0.12)) / 0.2)
                var w = layer
                w.opacity = Motion.clamp01(pop) * (0.85 + 0.15 * lit)
                w.translateBy(x: p.origin.x + p.size.width / 2, y: p.origin.y + 6 * ts * CGFloat(1 - pop))
                // The sung word also pulses with the beat (+5% and a brighter bloom on a kick).
                let beat = 0.05 * f.kick * CGFloat(lit)
                let k = (1.08 - 0.08 * CGFloat(pop)) * (1 + beat)
                w.scaleBy(x: k, y: k)
                if lit > 0.5, f.kick > 0.05 {
                    w.addFilter(.shadow(color: Color.white.opacity(0.45 * Double(f.kick)), radius: (6 + 10 * f.kick) * ts))
                }
                var text = p.text
                text.shading = .color(lit > 0.5 ? .white : settled)
                w.draw(text, at: .zero, anchor: .center)
            }
        }
    }

    /// Greedy word wrap; returns word indices per row (a word wider than `width` gets a row of its own).
    static func wrap(_ widths: [CGFloat], gap: CGFloat, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var row: [Int] = []
        var used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !row.isEmpty, used + gap + w > width {
                rows.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : gap) + w
            row.append(i)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

/// Heavy display faces for Orbital, per `LyricFont` (SF Pro goes condensed black).
enum OrbitalType {
    private static let installed: Set<String> = Set(
        ["HelveticaNeue-CondensedBlack", "AvenirNext-Heavy", "Futura-CondensedExtraBold", "Didot-Bold"]
            .filter { NSFont(name: $0, size: 12) != nil })

    static func font(_ font: LyricFont, size: CGFloat) -> Font {
        switch font {
        case .sfPro: return .system(size: size, weight: .black).width(.condensed)
        case .sfRounded: return .system(size: size, weight: .black, design: .rounded)
        case .newYork: return .system(size: size, weight: .black, design: .serif)
        case .helveticaNeue: return face("HelveticaNeue-CondensedBlack", font, size)
        case .avenirNext: return face("AvenirNext-Heavy", font, size)
        case .futura: return face("Futura-CondensedExtraBold", font, size)
        case .didot: return face("Didot-Bold", font, size)
        }
    }

    private static func face(_ name: String, _ fallback: LyricFont, _ size: CGFloat) -> Font {
        installed.contains(name) ? .custom(name, fixedSize: size) : fallback.font(size: size, weight: .black)
    }
}
