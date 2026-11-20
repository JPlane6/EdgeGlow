import AppKit
import SwiftUI

/// Orbital — the album cover as a disc in the middle of the screen, wrapped by a live 360° equalizer, with
/// the current line in bold kinetic caps to its left. The ring reads EdgeGlow's live FFT (or a beat-synced
/// stand-in when system audio isn't captured); the disc breathes with the bass.
struct OrbitalScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let layout = OrbitalLayout(frame: f)
        let audio = f.orbital?.audio ?? .procedural(position: f.position, clock: f.clock, bpm: nil)
        let bass = Motion.clamp01(audio.bass)
        let pulse = 1 + 0.07 * CGFloat(bass)
        let accent = f.palette.highlight
        ZStack(alignment: .topLeading) {
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
                OrbitalRing.draw(in: ctx, layout: layout, audio: audio, pulse: pulse, palette: f.palette)
            }
            OrbitalDisc(artwork: f.track.artwork, diameter: layout.discRadius * 2, accent: accent, scale: layout.scale, bass: bass)
                .scaleEffect(pulse)
                .position(layout.center)
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
                OrbitalLyrics.draw(in: ctx, frame: f, layout: layout)
            }
            if f.orbital?.showTrackInfo == true, !f.track.title.isEmpty {
                OrbitalBadge(track: f.track, scale: min(1.25, max(0.9, f.textScale)))
                    .padding(.leading, f.canvas.width * 0.06)
                    .padding(.bottom, 22 * min(1.25, max(0.9, f.textScale)))
                    .frame(width: f.canvas.width, height: f.canvas.height, alignment: .bottomLeading)
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
    /// longest spike plus its bloom); on narrow canvases it drops below the ring instead.
    let lyricRect: CGRect
    let lyricsBelow: Bool

    init(frame f: LyricFrame) {
        let w = f.canvas.width, h = f.canvas.height
        // Separate the user's Size slider from the screen factor so the disc doesn't scale twice.
        let screenFactor = max(0.01, LyricStage.textScale(user: 1, canvas: f.canvas))
        let user = min(1.3, max(0.75, f.textScale / screenFactor))
        // 20% of the screen's short side; the lyric canvas is 85% of the screen.
        let r = min(w, h) * (0.20 / 0.85) * 0.5 * user
        scale = r / 90
        discRadius = r
        maxExtension = r * 0.75
        // Full reach: pulsed disc + gap + longest spike + bloom.
        let reach = r * 1.07 + 4 * scale + maxExtension + 12 * scale

        let left = w * 0.06
        let besideRight = min(w * 0.36, w * 0.5 - reach - 24 * scale)
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
            let top = cy + reach + 10 * scale
            lyricRect = CGRect(x: w * 0.07, y: top, width: w * 0.86, height: max(80, h - top - 16))
        }
    }

    var baseRadius: CGFloat { discRadius + 4 * scale }
}

// MARK: - Equalizer ring

enum OrbitalRing {
    static let spokes = 120
    static let cream = Color(hex: "#FFF8E7")

    /// Spectrum value at `m` (0 = lowest band … 1 = highest), linearly interpolated with a light blur
    /// across neighbors so adjacent spokes ripple together instead of flickering.
    static func value(_ bands: [Double], at m: Double) -> Double {
        guard bands.count > 1 else { return bands.first ?? 0 }
        func at(_ x: Double) -> Double {
            let p = min(max(x, 0), 1) * Double(bands.count - 1)
            let i = Int(p), j = min(i + 1, bands.count - 1)
            return bands[i] + (bands[j] - bands[i]) * (p - Double(i))
        }
        let d = 0.6 / Double(bands.count)
        return Motion.clamp01(0.25 * at(m - d) + 0.5 * at(m) + 0.25 * at(m + d))
    }

    static func draw(in ctx: GraphicsContext, layout l: OrbitalLayout, audio: OrbitalAudio, pulse: CGFloat, palette p: LyricPalette) {
        let c = l.center
        let base = l.discRadius * pulse + 4 * l.scale
        let ext = l.maxExtension
        let n = spokes

        var tips: [CGPoint] = []
        tips.reserveCapacity(n)
        var bars = Path()
        for k in 0..<n {
            // Start at the top and go clockwise; the low end sits at the top and the spectrum is mirrored
            // across the vertical axis, so both halves meet seamlessly at the top and the bottom.
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(k) / Double(n)
            let m = Double(min(k, n - k)) / Double(n / 2)
            let amp = value(audio.bands, at: m)
            // A small floor keeps a tight ripple during quiet vocals; drops spike out to the full extension.
            let len = ext * CGFloat(0.035 + 0.965 * amp)
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let inner = c + dir * base
            let tip = c + dir * (base + len)
            bars.move(to: inner)
            bars.addLine(to: tip)
            tips.append(tip)
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
        var ribbon = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        ribbon.move(to: mid(tips[n - 1], tips[0]))
        for k in 0..<n {
            ribbon.addQuadCurve(to: mid(tips[k], tips[(k + 1) % n]), control: tips[k])
        }
        ribbon.closeSubpath()
        ribbon.addEllipse(in: CGRect(x: c.x - base, y: c.y - base, width: base * 2, height: base * 2))
        var fill = ctx
        fill.opacity = 0.25
        fill.fill(ribbon, with: shading, style: FillStyle(eoFill: true))

        // Bars with an outer bloom in the album accent.
        var glow = ctx
        glow.addFilter(.shadow(color: p.highlight.opacity(0.9), radius: 10 * l.scale))
        glow.stroke(bars, with: shading, style: StrokeStyle(lineWidth: 2.2 * l.scale, lineCap: .round))
    }
}

// MARK: - Album disc

private struct OrbitalDisc: View {
    let artwork: NSImage?
    let diameter: CGFloat
    let accent: Color
    let scale: CGFloat
    let bass: Double

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
        .overlay(Circle().stroke(accent, lineWidth: 2.5 * scale))
        .shadow(color: accent.opacity(0.55), radius: (18 + 8 * CGFloat(bass)) * scale)
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
                let k = 1.08 - 0.08 * CGFloat(pop)
                w.scaleBy(x: k, y: k)
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

// MARK: - Track badge

/// Compact Now Playing pill: mini cover, title and artist.
private struct OrbitalBadge: View {
    let track: LyricTrack
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 9 * scale) {
            Group {
                if let art = track.artwork {
                    Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(hex: "#2A2C31")
                        Image(systemName: "music.note").font(.system(size: 13 * scale, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                    }
                }
            }
            .frame(width: 30 * scale, height: 30 * scale)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.clip(track.title))
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(Color.white)
                if !track.artist.isEmpty {
                    Text(Self.clip(track.artist))
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }
            .lineLimit(1)
        }
        .fixedSize()
        .padding(.leading, 6 * scale)
        .padding(.trailing, 14 * scale)
        .padding(.vertical, 6 * scale)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 8 * scale, y: 2 * scale)
    }

    /// Keeps the pill compact without measuring: long titles end in an ellipsis.
    static func clip(_ s: String, max: Int = 36) -> String {
        s.count > max ? String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }
}
