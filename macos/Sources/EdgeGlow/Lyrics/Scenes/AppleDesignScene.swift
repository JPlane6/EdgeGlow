import SwiftUI

// MARK: - Plan

/// The song as an iMessage thread: one bubble per line, alternating sides in natural runs, with timestamp
/// stamps at phrase gaps, typing indicators before incoming lines and location shares.
struct AppleThread {
    enum Kind {
        case stamp(String)
        case bubble(line: Int, outgoing: Bool, tail: Bool, hero: Bool, echo: Bool)
        case typing
        case map(line: Int, landmark: Landmark, pin: Color, outgoing: Bool)
    }

    struct Item {
        let kind: Kind
        let arrive: Double
        var leave: Double? = nil
    }

    let items: [Item]
}

enum AppleDesignPlan {
    static let cache = PlanCache<AppleThread>()

    static func build(_ lyrics: TimedLyrics) -> AppleThread {
        var items: [AppleThread.Item] = []
        var outgoing = true
        var run = 0
        var sides: [Bool] = []
        for gi in lyrics.groups.indices {
            let start = lyrics.groups[gi].first?.start ?? 0
            let prevEnd = gi > 0 ? (lyrics.groups[gi - 1].last?.end ?? 0) : -10
            if gi > 0 {
                let gap = start - prevEnd
                if gap > 1.6 || run >= 3 || Motion.hash(gi, 21) < 0.4 { outgoing.toggle(); run = 0 }
            }
            run += 1
            sides.append(outgoing)
        }
        let clock = Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened))
        for gi in lyrics.groups.indices {
            let words = lyrics.groups[gi]
            let start = words.first?.start ?? 0
            let prevEnd = gi > 0 ? (lyrics.groups[gi - 1].last?.end ?? 0) : -10
            if gi == 0 || start - prevEnd > 4 {
                items.append(.init(kind: .stamp(gi == 0 ? "Today \(clock)" : "Now"), arrive: max(0, start - 0.9)))
            }
            let out = sides[gi]
            if !out {
                let typingStart = max(start - 0.6, prevEnd + 0.15)
                if start - typingStart > 0.25 {
                    items.append(.init(kind: .typing, arrive: typingStart, leave: start - 0.05))
                }
            }
            let text = lyrics.lineText(gi)
            let tail = gi + 1 >= sides.count || sides[gi + 1] != out
            let echo = text.hasSuffix("!") || text.hasSuffix("?") || words.count <= 2
            items.append(.init(kind: .bubble(line: gi, outgoing: out, tail: tail, hero: words.count == 1, echo: echo), arrive: start - 0.05))
            let named = AppleMapProvider.match(text)
            if named != nil || gi % 7 == 6 {
                let place = named ?? AppleMapProvider.sanFrancisco[(gi / 7) % (AppleMapProvider.sanFrancisco.count - 1)]
                items.append(.init(kind: .map(line: gi, landmark: place, pin: AppleColors.pins[gi % AppleColors.pins.count], outgoing: out),
                                   arrive: start + 0.55))
            }
        }
        return AppleThread(items: items.sorted { $0.arrive < $1.arrive })
    }
}

// MARK: - Scene

/// Apple Design — an authentic dark-mode Messages thread, scrolling with kinetic spring physics and a
/// vertical motion blur driven by the scroll velocity.
struct AppleDesignScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let thread = AppleDesignPlan.cache.value(for: f.songKey) { AppleDesignPlan.build(f.lyrics) }
        let layout = AppleThreadLayout(frame: f, thread: thread)
        let maps = layout.mapPictures()
        AppleThreadCanvas(frame: f, thread: thread, layout: layout, maps: maps)
            // Kicks add a short vertical smear on top of the scroll blur.
            .motionBlur(CGVector(dx: 0, dy: max(-36, min(36, layout.travelVelocity / 60 * 1.3 + 9 * f.kick))), enabled: f.shaders)
    }
}

/// Column geometry and the measured size of every thread item.
struct AppleThreadLayout {
    let frame: LyricFrame
    let thread: AppleThread
    let s: CGFloat
    let column: CGRect
    let placements: [FeedPlacement]
    let sizes: [CGSize]
    let travelVelocity: CGFloat

    static let padH: CGFloat = 12, padV: CGFloat = 7.5

    init(frame: LyricFrame, thread: AppleThread) {
        self.frame = frame
        self.thread = thread
        let s = min(1.6, frame.textScale)
        self.s = s
        let width = min(frame.canvas.width * 0.92, 410 * s)
        let clearance = frame.locked ? frame.canvas.height * 0.26 : 0
        let height = min(frame.canvas.height * 0.86 - clearance, 640 * s)
        var bottom = frame.bandCenterY + height / 2
        bottom = min(frame.canvas.height - 10, max(clearance + height, bottom))
        column = CGRect(x: (frame.canvas.width - width) / 2, y: bottom - height, width: width, height: height)

        var sizes: [CGSize] = []
        var entries: [FeedEntry] = []
        var prevSide: Bool?
        for item in thread.items {
            let size = Self.measure(item.kind, frame: frame, width: width, s: s)
            sizes.append(size)
            var gap: CGFloat
            switch item.kind {
            case .bubble(_, let out, _, _, _):
                gap = prevSide == out ? 3 * s : 12 * s
                if prevSide == true && out == false { gap = 20 * s }   // room for "Delivered"
                prevSide = out
            case .map(_, _, _, let out):
                gap = 4 * s
                prevSide = out
            case .typing:
                gap = prevSide == false ? 3 * s : 12 * s
            case .stamp:
                gap = 16 * s
                prevSide = nil
            }
            entries.append(FeedEntry(arrive: item.arrive, leave: item.leave, height: size.height, gap: gap))
        }
        self.sizes = sizes
        let placed = FeedPhysics.place(entries, position: frame.position, bottom: column.maxY - 22 * s, top: column.minY)
        placements = placed.items
        travelVelocity = placed.velocity
    }

    static func bubbleFont(hero: Bool, s: CGFloat) -> (CGFloat, NSFont.Weight) { hero ? (20 * s, .bold) : (16.5 * s, .regular) }

    static func measure(_ kind: AppleThread.Kind, frame: LyricFrame, width: CGFloat, s: CGFloat) -> CGSize {
        switch kind {
        case .stamp: return CGSize(width: width, height: 16 * s)
        case .typing: return CGSize(width: 62 * s, height: 37 * s)
        case .map: return CGSize(width: min(width * 0.68, 264 * s), height: 172 * s)
        case .bubble(let line, _, _, let hero, _):
            let (size, weight) = bubbleFont(hero: hero, s: s)
            let text = frame.lineText(line)
            let t = TextMeasure.shared.size(text, size: size, weight: weight, width: width * 0.72 - padH * 2 * s)
            return CGSize(width: t.width + padH * 2 * s, height: max(34 * s, t.height + padV * 2 * s))
        }
    }

    /// Map pictures for the visible location shares (requested on the main thread).
    @MainActor func mapPictures() -> [Int: MapPicture] {
        var out: [Int: MapPicture] = [:]
        for p in placements {
            if case .map(_, let landmark, _, _) = thread.items[p.index].kind {
                if let pic = MapSnapshotCache.shared.picture(AppleMapCard.shot(landmark, size: AppleMapCard.mapSize(sizes[p.index], s: s))) {
                    out[p.index] = pic
                }
            }
        }
        return out
    }
}

/// Draws the thread: bubbles, tails, stamps, typing dots, receipts, echoes and location cards.
struct AppleThreadCanvas: View {
    let frame: LyricFrame
    let thread: AppleThread
    let layout: AppleThreadLayout
    let maps: [Int: MapPicture]

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, size in
            let latestOutgoing = layout.placements.first { p in
                if case .bubble(_, true, _, _, _) = thread.items[p.index].kind { return true }
                return false
            }?.index
            for p in layout.placements.reversed() {
                draw(p, latestOutgoing: latestOutgoing, in: ctx)
            }
            // Fade the top of the thread out, like the edge of a scroll view.
            var fade = ctx
            fade.blendMode = .destinationOut
            let c = layout.column
            fade.fill(Path(CGRect(x: c.minX - 40, y: c.minY - 400, width: c.width + 80, height: 400)), with: .color(.black))
            fade.fill(Path(CGRect(x: c.minX - 40, y: c.minY, width: c.width + 80, height: 110 * layout.s)),
                      with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: CGPoint(x: 0, y: c.minY), endPoint: CGPoint(x: 0, y: c.minY + 110 * layout.s)))
        }
    }

    private func draw(_ p: FeedPlacement, latestOutgoing: Int?, in base: GraphicsContext) {
        let item = thread.items[p.index]
        let size = layout.sizes[p.index]
        let s = layout.s
        let col = layout.column
        let rect: CGRect
        var ctx = base
        // Older slots dim slightly with age (focus stays on the newest lines).
        ctx.opacity = max(0.55, 1 - 0.07 * Double(p.rank)) * Motion.smooth(p.age / 0.12)

        switch item.kind {
        case .stamp(let label):
            rect = CGRect(x: col.minX, y: p.bottom - size.height, width: col.width, height: size.height)
            var t = AttributedString(label)
            t.font = .system(size: 11 * s, weight: .medium)
            t.foregroundColor = AppleColors.gray
            if let r = t.range(of: label.hasPrefix("Today") ? "Today" : label) { t[r].font = .system(size: 11 * s, weight: .semibold) }
            ctx.draw(Text(t), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)

        case .typing:
            rect = CGRect(x: col.minX + 4 * s, y: p.bottom - size.height, width: size.width, height: size.height)
            let k = CGFloat(min(1, max(0, p.presence)))
            ctx.opacity *= Double(k)
            transformed(&ctx, around: CGPoint(x: rect.minX, y: rect.maxY), scale: 0.6 + 0.4 * CGFloat(p.enter))
            fillBubble(rect, outgoing: false, tail: true, in: ctx)
            for i in 0..<3 {
                let phase = sin(frame.clock * 6.5 - Double(i) * 0.75)
                let y = rect.midY - CGFloat(max(0, phase)) * 3 * s
                let x = rect.midX + CGFloat(i - 1) * 11 * s
                let r = 3.6 * s
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(Color.white.opacity(0.45 + 0.4 * max(0, phase))))
            }

        case .bubble(let line, let outgoing, let tail, let hero, let echo):
            let x = outgoing ? col.maxX - size.width - 6 * s : col.minX + 6 * s
            rect = CGRect(x: x, y: p.bottom - size.height, width: size.width, height: size.height)
            let anchor = CGPoint(x: outgoing ? rect.maxX : rect.minX, y: rect.maxY)
            // Entrance: pop from the tail corner with a little squash and tilt; micro-pop on each word.
            let enter = CGFloat(p.enter)
            let words = frame.group(line)
            let lastStart = words.last(where: frame.arrived)?.start ?? -10
            let micro = 0.018 * CGFloat(exp(-10 * max(0, frame.position - lastStart)))
            // The newest bubble thumps with the beat: a small scale kick, squash and tilt.
            let beat = p.rank == 0 ? frame.kick : 0
            let squash = 1 + 0.07 * (1 - enter) + 0.035 * beat
            transformed(&ctx, around: anchor, scale: 0.55 + 0.45 * enter + micro + 0.03 * beat, squashY: squash,
                        tilt: Double(outgoing ? -2.5 : 2.5) * Double(1 - enter) + Double(outgoing ? -0.8 : 0.8) * Double(beat))
            if echo { drawEcho(rect, outgoing: outgoing, age: frame.position - (words.first?.start ?? 0), in: ctx) }
            if beat > 0.35 { drawEcho(rect, outgoing: outgoing, age: 0.8 * Double(1 - beat), in: ctx) }
            fillBubble(rect, outgoing: outgoing, tail: tail, in: ctx)
            let (fs, weight) = AppleThreadLayout.bubbleFont(hero: hero, s: s)
            let text = Text(fill(words, size: fs, weight: weight == .bold ? .bold : .regular))
            let inner = rect.insetBy(dx: AppleThreadLayout.padH * s, dy: AppleThreadLayout.padV * s)
            ctx.draw(text, in: CGRect(x: inner.minX, y: inner.minY - 1, width: inner.width + 2, height: inner.height + 4))
            if outgoing, p.index == latestOutgoing, frame.position > (words.last?.end ?? 0) {
                var r = ctx
                r.opacity *= Motion.smooth((frame.position - (words.last?.end ?? 0)) / 0.3)
                r.text("Delivered", font: .system(size: 11 * s, weight: .semibold), color: AppleColors.gray,
                       at: CGPoint(x: rect.maxX - 2 * s, y: rect.maxY + 3 * s), anchor: .topTrailing)
            }

        case .map(_, let landmark, let pin, let outgoing):
            let x = outgoing ? col.maxX - size.width - 6 * s : col.minX + 6 * s
            rect = CGRect(x: x, y: p.bottom - size.height, width: size.width, height: size.height)
            transformed(&ctx, around: CGPoint(x: outgoing ? rect.maxX : rect.minX, y: rect.maxY), scale: 0.6 + 0.4 * CGFloat(p.enter))
            AppleMapCard.draw(in: ctx, rect: rect, landmark: landmark, pin: pin, picture: maps[p.index], s: s, clock: frame.clock)
        }
    }

    private func transformed(_ ctx: inout GraphicsContext, around a: CGPoint, scale: CGFloat, squashY: CGFloat = 1, tilt: Double = 0) {
        ctx.translateBy(x: a.x, y: a.y)
        if tilt != 0 { ctx.rotate(by: .degrees(tilt)) }
        ctx.scaleBy(x: scale / max(0.01, squashY), y: scale * squashY)
        ctx.translateBy(x: -a.x, y: -a.y)
    }

    /// Words fill in on their own timings (0.35 → 1.0).
    private func fill(_ words: [TimedWord], size: CGFloat, weight: Font.Weight) -> AttributedString {
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            var part = AttributedString((i > 0 ? " " : "") + w.text)
            let lit = 0.35 + 0.65 * Motion.smooth((frame.position - w.start) / 0.12)
            part.foregroundColor = Color.white.opacity(lit)
            part.font = .system(size: size, weight: weight)
            out += part
        }
        return out
    }

    private func fillBubble(_ rect: CGRect, outgoing: Bool, tail: Bool, in ctx: GraphicsContext) {
        let s = layout.s
        let radius = min(rect.height / 2, 18 * s)
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        if tail { path.addPath(Self.tail(rect, outgoing: outgoing, s: s)) }
        let shading: GraphicsContext.Shading = outgoing
            ? .linearGradient(Gradient(colors: [AppleColors.blue, AppleColors.blue.mixed(AppleColors.blueDeep, 0.38)]),
                              startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
            : .linearGradient(Gradient(colors: [AppleColors.bubbleIncomingTop, AppleColors.bubbleIncoming]),
                              startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.35), radius: 3.0, y: 1))
        shadowed.fill(path, with: shading)
    }

    /// The curved iMessage tail at the bottom outer corner.
    static func tail(_ r: CGRect, outgoing: Bool, s: CGFloat) -> Path {
        let dir: CGFloat = outgoing ? 1 : -1
        let edge = outgoing ? r.maxX : r.minX
        var p = Path()
        p.move(to: CGPoint(x: edge - dir * 1 * s, y: r.maxY - 17 * s))
        p.addCurve(to: CGPoint(x: edge + dir * 6 * s, y: r.maxY),
                   control1: CGPoint(x: edge - dir * 0.5 * s, y: r.maxY - 6 * s),
                   control2: CGPoint(x: edge + dir * 2 * s, y: r.maxY - 1 * s))
        p.addCurve(to: CGPoint(x: edge - dir * 13 * s, y: r.maxY - 1.5 * s),
                   control1: CGPoint(x: edge - dir * 3 * s, y: r.maxY + 0.8 * s),
                   control2: CGPoint(x: edge - dir * 9 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: edge - dir * 13 * s, y: r.maxY - 17 * s))
        p.closeSubpath()
        return p
    }

    /// Expanding highlight ring on emphasis bubbles.
    private func drawEcho(_ rect: CGRect, outgoing: Bool, age: Double, in ctx: GraphicsContext) {
        guard age >= 0, age < 0.8 else { return }
        let k = CGFloat(age / 0.8)
        let grow = 12 * layout.s * k
        let ring = rect.insetBy(dx: -grow, dy: -grow)
        let color = outgoing ? AppleColors.blue : Color.white
        ctx.stroke(Path(roundedRect: ring, cornerRadius: min(ring.height / 2, 18 * layout.s + grow), style: .continuous),
                   with: .color(color.opacity(0.55 * Double(1 - k))), lineWidth: 2 * layout.s)
    }
}

// MARK: - Location share card

/// iMessage location share: a dark map snapshot with a colored pin and a short route, over a label footer.
enum AppleMapCard {
    static let surface = Color(hex: "#212B3D")

    static func mapSize(_ card: CGSize, s: CGFloat) -> CGSize { CGSize(width: card.width, height: card.height - 42 * s) }

    static func shot(_ landmark: Landmark, size: CGSize) -> MapShot {
        MapShot(center: landmark.coordinate, distance: 1500, pitch: 0, heading: 0, size: size)
    }

    static func draw(in ctx: GraphicsContext, rect: CGRect, landmark: Landmark, pin: Color, picture: MapPicture?, s: CGFloat, clock: Double) {
        let clip = Path(roundedRect: rect, cornerRadius: 18 * s, style: .continuous)
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.4), radius: 3.0, y: 1))
        shadowed.fill(clip, with: .color(surface))
        var c = ctx
        c.clip(to: clip)
        let mapRect = CGRect(origin: rect.origin, size: mapSize(rect.size, s: s))
        let shot = Self.shot(landmark, size: mapRect.size)
        if let picture {
            c.draw(Image(nsImage: picture.image), in: mapRect)
        } else {
            MapMath.drawPlaceholder(in: c, rect: mapRect, seed: Motion.stableHash(landmark.id))
        }
        let project = picture?.project ?? MapMath.approximateProjection(shot)
        let start = AppleMapProvider.offset(landmark.coordinate, meters: 420, bearing: Motion.hash(Motion.stableHash(landmark.id), 4) * 360)
        let road = Road.walk(from: start, to: landmark.coordinate, seed: Motion.stableHash(landmark.id))
        var m = c
        m.translateBy(x: mapRect.minX, y: mapRect.minY)
        let pts = road.points.map(project)
        MapMath.drawRoute(pts, in: m, width: 5.5 * s, color: AppleColors.blue, upTo: 1)
        if let end = pts.last {
            var g = m
            g.addFilter(.shadow(color: pin.opacity(0.8), radius: 6))
            let r = 11 * s
            g.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(pin))
            m.stroke(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(.white), lineWidth: 2.5 * s)
            m.fill(Path(ellipseIn: CGRect(x: end.x - 3.5 * s, y: end.y - 3.5 * s, width: 7 * s, height: 7 * s)), with: .color(.white))
        }
        c.stroke(Path(CGRect(x: rect.minX, y: mapRect.maxY, width: rect.width, height: 0.5)), with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        c.text(landmark.name, font: .system(size: 13.8 * s, weight: .semibold), color: .white,
               at: CGPoint(x: rect.minX + 14 * s, y: mapRect.maxY + 12 * s), anchor: .topLeading)
        c.text("Shared Location", font: .system(size: 11 * s, weight: .regular), color: AppleColors.gray,
               at: CGPoint(x: rect.minX + 14 * s, y: mapRect.maxY + 27 * s), anchor: .topLeading)
    }
}
