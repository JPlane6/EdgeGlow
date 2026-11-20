import SwiftUI

// MARK: - Plan

/// Every line becomes an Apple Cash payment, a Dynamic Island activity, a Wallet pass, an Apple Pay sheet,
/// a map card or a payment message, cycling deterministically.
enum MoneyPlan {
    enum Kind: CaseIterable { case cash, island, card, pay, map, message }

    struct Card {
        let line: Int
        let kind: Kind
        let arrive: Double
        let tint: Color
        let landmark: Landmark?

        func mapShot(scale s: CGFloat) -> MapShot? {
            guard kind == .map, let landmark else { return nil }
            return MapShot(center: landmark.coordinate, distance: 1300, pitch: 45, heading: 20, size: CGSize(width: 340 * s, height: 104 * s))
        }
    }

    static let cache = PlanCache<[Card]>()
    private static let cycle: [Kind] = [.cash, .island, .card, .pay, .message, .map]

    static func build(_ lyrics: TimedLyrics) -> [Card] {
        var out: [Card] = []
        var previous: Kind?
        var step = Int(Motion.hash(lyrics.groups.count, 3) * 6)
        for gi in lyrics.groups.indices {
            let words = lyrics.groups[gi]
            let text = lyrics.lineText(gi)
            let place = AppleMapProvider.match(text)
            var kind: Kind
            if place != nil { kind = .map }
            else if words.count <= 2 { kind = .cash }
            else {
                kind = cycle[step % cycle.count]
                step += 1
                if kind == .map { kind = .card }
                if kind == previous { kind = cycle[step % cycle.count]; step += 1; if kind == .map { kind = .pay } }
            }
            previous = kind
            let landmark = place ?? (kind == .map ? AppleMapProvider.sanFrancisco[gi % 14] : nil)
            out.append(Card(line: gi, kind: kind, arrive: (words.first?.start ?? 0) - 0.08,
                            tint: AppleColors.wallet[Int(Motion.hash(gi, 17) * Double(AppleColors.wallet.count))], landmark: landmark))
        }
        return out
    }
}

// MARK: - Scene

/// Apple Design Money — a kinetic vertical feed of Apple Cash / Wallet / Apple Pay cards, one per line,
/// with spring travel, handoff and a scroll-velocity motion blur.
struct AppleMoneyScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let cards = MoneyPlan.cache.value(for: f.songKey) { MoneyPlan.build(f.lyrics) }
        let feed = MoneyFeed(frame: f, cards: cards)
        MoneyFeedCanvas(frame: f, feed: feed, maps: feed.mapPictures())
            // Kicks add a short vertical smear on top of the scroll blur.
            .motionBlur(CGVector(dx: 0, dy: max(-36, min(36, feed.travelVelocity / 60 * 1.3 + 9 * f.kick))), enabled: f.shaders)
    }
}

/// Measured card sizes and their placement in the feed.
struct MoneyFeed {
    let frame: LyricFrame
    let cards: [MoneyPlan.Card]
    let s: CGFloat
    let column: CGRect
    let sizes: [CGSize]
    let textSizes: [CGFloat]
    let placements: [FeedPlacement]
    let travelVelocity: CGFloat

    init(frame: LyricFrame, cards: [MoneyPlan.Card]) {
        self.frame = frame
        self.cards = cards
        let s = min(1.6, frame.textScale)
        self.s = s
        let width = min(frame.canvas.width * 0.9, 380 * s)
        let clearance = frame.locked ? frame.canvas.height * 0.26 : 0
        let height = min(frame.canvas.height * 0.88 - clearance, 660 * s)
        var bottom = frame.bandCenterY + height / 2
        bottom = min(frame.canvas.height - 10, max(clearance + height, bottom))
        column = CGRect(x: (frame.canvas.width - width) / 2, y: bottom - height, width: width, height: height)

        var sizes: [CGSize] = [], textSizes: [CGFloat] = [], entries: [FeedEntry] = []
        for c in cards {
            let (size, fs) = Self.measure(c, text: frame.lineText(c.line), width: width, s: s)
            sizes.append(size)
            textSizes.append(fs)
            entries.append(FeedEntry(arrive: c.arrive, height: size.height, gap: 14 * s))
        }
        self.sizes = sizes
        self.textSizes = textSizes
        let placed = FeedPhysics.place(entries, position: frame.position, bottom: column.maxY - 8 * s, top: column.minY)
        placements = placed.items
        travelVelocity = placed.velocity
    }

    /// Card size and lyric font size for a line.
    static func measure(_ c: MoneyPlan.Card, text: String, width: CGFloat, s: CGFloat) -> (CGSize, CGFloat) {
        func h(_ size: CGFloat, _ weight: NSFont.Weight, _ design: TextMeasure.Design = .standard, inset: CGFloat, lines: Int = 3) -> CGFloat {
            TextMeasure.shared.size(text, size: size, weight: weight, design: design, width: width - inset * 2, maxLines: lines).height
        }
        let n = CGFloat(text.count)
        switch c.kind {
        case .cash:
            let fs = max(28, min(35, 35 - (n - 8) * 0.35)) * s
            return (CGSize(width: width, height: 92 * s + h(fs, .bold, .rounded, inset: 20 * s)), fs)
        case .island:
            return (CGSize(width: width, height: 62 * s), 14.5 * s)
        case .card:
            let fs = max(20, min(28, 28 - (n - 14) * 0.3)) * s
            return (CGSize(width: width, height: 104 * s + h(fs, .bold, inset: 20 * s)), fs)
        case .pay:
            let fs = max(20, min(33, 33 - (n - 10) * 0.4)) * s
            return (CGSize(width: width, height: 150 * s + h(fs, .bold, inset: 24 * s)), fs)
        case .map:
            return (CGSize(width: width, height: 104 * s + 30 * s + h(14.5 * s, .semibold, inset: 16 * s, lines: 2)), 14.5 * s)
        case .message:
            let fs = 17 * s
            let t = TextMeasure.shared.size(text, size: fs, weight: .regular, width: width * 0.72 - 24 * s)
            return (CGSize(width: t.width + 24 * s, height: max(36 * s, t.height + 16 * s)), fs)
        }
    }

    @MainActor func mapPictures() -> [Int: MapPicture] {
        var out: [Int: MapPicture] = [:]
        for p in placements {
            if let shot = cards[p.index].mapShot(scale: s), let pic = MapSnapshotCache.shared.picture(shot) { out[p.index] = pic }
        }
        return out
    }
}

struct MoneyFeedCanvas: View {
    let frame: LyricFrame
    let feed: MoneyFeed
    let maps: [Int: MapPicture]

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { ctx, _ in
            for p in feed.placements.reversed() { draw(p, in: ctx) }
            var fade = ctx
            fade.blendMode = .destinationOut
            let c = feed.column
            fade.fill(Path(CGRect(x: c.minX - 60, y: c.minY - 600, width: c.width + 120, height: 600)), with: .color(.black))
            fade.fill(Path(CGRect(x: c.minX - 60, y: c.minY, width: c.width + 120, height: 120 * feed.s)),
                      with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: CGPoint(x: 0, y: c.minY), endPoint: CGPoint(x: 0, y: c.minY + 120 * feed.s)))
        }
    }

    private var s: CGFloat { feed.s }

    private func draw(_ p: FeedPlacement, in base: GraphicsContext) {
        let card = feed.cards[p.index]
        let size = feed.sizes[p.index]
        let col = feed.column
        let x = card.kind == .message ? col.maxX - size.width : col.minX + (col.width - size.width) / 2
        let rect = CGRect(x: x, y: p.bottom - size.height, width: size.width, height: size.height)
        var ctx = base
        // Handoff: earlier cards step back and dim as new ones arrive.
        let back = CGFloat(min(3, p.rank))
        ctx.opacity = max(0.4, 1 - 0.16 * Double(back)) * Motion.smooth(p.age / 0.1)
        let enter = CGFloat(p.enter)
        // The newest card thumps with the beat (scale, squash and a hair of tilt).
        let beat = p.rank == 0 ? frame.kick : 0
        let scale = (1 - 0.025 * back) * (0.82 + 0.18 * enter) * (1 + 0.025 * beat)
        let squash = 1 + 0.05 * (1 - enter) + 0.03 * beat
        let anchor = CGPoint(x: rect.midX, y: rect.maxY)
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: .degrees(Double(1 - enter) * (p.index % 2 == 0 ? 3 : -3) + Double(beat) * (p.index % 2 == 0 ? 0.7 : -0.7)))
        ctx.scaleBy(x: scale / squash, y: scale * squash)
        ctx.translateBy(x: -anchor.x, y: -anchor.y)

        let words = frame.group(card.line)
        let fs = feed.textSizes[p.index]
        switch card.kind {
        case .cash: cash(rect, words, fs, p, ctx)
        case .island: island(rect, words, fs, p, ctx)
        case .card: wallet(rect, words, fs, card, ctx)
        case .pay: pay(rect, words, fs, ctx)
        case .map: mapCard(rect, words, fs, card, maps[p.index], ctx)
        case .message: message(rect, words, fs, ctx)
        }
    }

    // MARK: Shared

    private func lyric(_ words: [TimedWord], size: CGFloat, weight: Font.Weight, design: Font.Design = .default, color: Color = .white) -> Text {
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            var part = AttributedString((i > 0 ? " " : "") + w.text)
            part.foregroundColor = color.opacity(0.35 + 0.65 * Motion.smooth((frame.position - w.start) / 0.12))
            part.font = .system(size: size, weight: weight, design: design)
            out += part
        }
        return Text(out)
    }

    private func surface(_ path: Path, _ shading: GraphicsContext.Shading, _ ctx: GraphicsContext) {
        var c = ctx
        c.addFilter(.shadow(color: .black.opacity(0.45), radius: 3.0, y: 1.5))
        c.fill(path, with: shading)
    }

    private func artwork(_ rect: CGRect, radius: CGFloat, _ ctx: GraphicsContext) {
        var c = ctx
        let clip = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        c.clip(to: clip)
        if let art = frame.track.artwork {
            c.draw(Image(nsImage: art), in: rect)
        } else {
            c.fill(clip, with: .linearGradient(Gradient(colors: [bloom(0), bloom(1)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            c.text("♪", font: .system(size: rect.height * 0.5, weight: .bold), color: .white, at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func bloom(_ i: Int) -> Color {
        let b = frame.track.blooms
        return b.isEmpty ? AppleColors.wallet[i % AppleColors.wallet.count] : b[i % b.count]
    }

    // MARK: Kinds

    /// Apple Cash: glossy dark card, the line as the amount, a green "Sent" badge.
    private func cash(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ p: FeedPlacement, _ ctx: GraphicsContext) {
        let shape = Path(roundedRect: r, cornerRadius: 22 * s, style: .continuous)
        surface(shape, .color(AppleColors.surface), ctx)
        var sheen = ctx
        sheen.clip(to: shape)
        sheen.fill(Path(ellipseIn: CGRect(x: r.minX - r.width * 0.2, y: r.minY - r.height * 0.9, width: r.width * 0.9, height: r.height * 1.4)),
                   with: .radialGradient(Gradient(colors: [bloom(0).opacity(0.28), .clear]), center: CGPoint(x: r.minX + r.width * 0.25, y: r.minY), startRadius: 0, endRadius: r.width * 0.6))
        sheen.fill(Path(ellipseIn: CGRect(x: r.maxX - r.width * 0.6, y: r.maxY - r.height * 0.5, width: r.width * 0.9, height: r.height * 1.2)),
                   with: .radialGradient(Gradient(colors: [bloom(1).opacity(0.22), .clear]), center: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY), startRadius: 0, endRadius: r.width * 0.55))
        ctx.stroke(shape, with: .color(.white.opacity(0.08)), lineWidth: 0.8)
        ctx.draw(Text("\(Image(systemName: "apple.logo")) Cash").font(.system(size: 12.5 * s, weight: .semibold)).foregroundColor(.white),
                 at: CGPoint(x: r.minX + 20 * s, y: r.minY + 22 * s), anchor: .leading)
        ctx.draw(lyric(words, size: fs, weight: .bold, design: .rounded), in: CGRect(x: r.minX + 20 * s, y: r.minY + 40 * s, width: r.width - 40 * s, height: r.height - 80 * s))
        // Sent badge with an echo ring when the line completes.
        let done = frame.position >= (words.last?.end ?? 0)
        let badge = CGPoint(x: r.minX + 30 * s, y: r.maxY - 24 * s)
        let color = done ? AppleColors.green : AppleColors.gray
        if done {
            let age = frame.position - (words.last?.end ?? 0)
            if age < 0.8 {
                let k = CGFloat(age / 0.8)
                let rr = (10 + 14 * k) * s
                ctx.stroke(Path(ellipseIn: CGRect(x: badge.x - rr, y: badge.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(AppleColors.green.opacity(0.6 * Double(1 - k))), lineWidth: 2 * s)
            }
        }
        ctx.draw(Text(Image(systemName: done ? "checkmark.circle.fill" : "clock.fill")).font(.system(size: 18 * s, weight: .semibold)).foregroundColor(color), at: badge)
        ctx.text(done ? "Sent" : "Sending…", font: .system(size: 13 * s, weight: .semibold), color: color,
                 at: CGPoint(x: badge.x + 16 * s, y: badge.y), anchor: .leading)
        ctx.text("Apple Cash", font: .system(size: 12 * s, weight: .medium), color: AppleColors.gray, at: CGPoint(x: r.maxX - 20 * s, y: badge.y), anchor: .trailing)
    }

    /// Dynamic Island: a black pill that expands with artwork, live words and an equalizer.
    private func island(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ p: FeedPlacement, _ ctx: GraphicsContext) {
        let expand = CGFloat(Motion.spring(p.age, response: 0.42, damping: 0.72))
        let w = 150 * s + (r.width - 150 * s) * expand
        let pill = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        let shape = Path(roundedRect: pill, cornerRadius: pill.height / 2, style: .continuous)
        surface(shape, .color(.black), ctx)
        ctx.stroke(shape, with: .color(.white.opacity(0.07)), lineWidth: 0.8)
        let art = CGRect(x: pill.minX + 12 * s, y: pill.midY - 19 * s, width: 38 * s, height: 38 * s)
        artwork(art, radius: 10 * s, ctx)
        var c = ctx
        c.opacity *= Double(max(0, min(1, (expand - 0.4) / 0.6)))
        let textRect = CGRect(x: art.maxX + 12 * s, y: pill.minY, width: pill.width - 38 * s - 12 * s * 3 - 46 * s, height: pill.height)
        var tc = c
        tc.clip(to: Path(textRect))
        // Live scrolling words: the tail of the line stays in view.
        let sung = words.filter(frame.arrived)
        let visible = Array(sung.suffix(5))
        tc.draw(lyric(visible, size: fs, weight: .semibold), at: CGPoint(x: textRect.maxX, y: textRect.midY), anchor: .trailing)
        // Equalizer bars tinted by the artwork accent, driven by the live spectrum (bass → highs).
        let tint = bloom(0)
        let bands = frame.audio.bands
        for i in 0..<4 {
            let band = bands.isEmpty ? 0 : bands[min(bands.count - 1, 3 + i * bands.count / 4)]
            let level = 0.2 + 0.8 * Motion.clamp01(band * 1.25 + Double(frame.kick) * (i == 0 ? 0.4 : 0.15))
            let bh = 22 * s * CGFloat(level)
            let bx = pill.maxX - 22 * s - CGFloat(3 - i) * 6 * s
            c.fill(Path(roundedRect: CGRect(x: bx - 1.6 * s, y: pill.midY - bh / 2, width: 3.2 * s, height: bh), cornerRadius: 1.6 * s), with: .color(tint))
        }
    }

    /// Wallet pass: tinted card with a top highlight, glyph, track header and the line.
    private func wallet(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ card: MoneyPlan.Card, _ ctx: GraphicsContext) {
        let shape = Path(roundedRect: r, cornerRadius: 20 * s, style: .continuous)
        let tint = frame.track.blooms.isEmpty ? card.tint : bloom(card.line).mixed(card.tint, 0.35)
        surface(shape, .linearGradient(Gradient(colors: [tint.mixed(.white, 0.08), tint.mixed(.black, 0.45)]),
                                       startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)), ctx)
        var hl = ctx
        hl.clip(to: shape)
        hl.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 20 * s, style: .continuous),
                  with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.minY + 30 * s)),
                  lineWidth: 1.2)
        let glyph: String = {
            for w in words { if case .symbol(let n)? = WordVisualResolver.shared.visual(for: w.text) { return n } }
            return "wallet.pass.fill"
        }()
        ctx.draw(Text(Image(systemName: glyph)).font(.system(size: 22 * s, weight: .semibold)).foregroundColor(.white),
                 at: CGPoint(x: r.minX + 30 * s, y: r.minY + 30 * s))
        ctx.text(frame.track.title.isEmpty ? "Now Playing" : frame.track.title, font: .system(size: 12 * s, weight: .semibold), color: .white,
                 at: CGPoint(x: r.minX + 52 * s, y: r.minY + 23 * s), anchor: .leading)
        ctx.text(frame.track.artist, font: .system(size: 12 * s, weight: .regular), color: .white.opacity(0.75),
                 at: CGPoint(x: r.minX + 52 * s, y: r.minY + 38 * s), anchor: .leading)
        ctx.text("LINE \(card.line + 1)", font: .system(size: 10 * s, weight: .bold), color: .white.opacity(0.7),
                 at: CGPoint(x: r.maxX - 20 * s, y: r.minY + 23 * s), anchor: .trailing)
        ctx.draw(lyric(words, size: fs, weight: .bold), in: CGRect(x: r.minX + 20 * s, y: r.minY + 58 * s, width: r.width - 40 * s, height: r.height - 100 * s))
        // Barcode strip.
        let strip = CGRect(x: r.minX + 20 * s, y: r.maxY - 30 * s, width: r.width - 40 * s, height: 14 * s)
        var x = strip.minX
        var k = card.line * 31
        while x < strip.maxX {
            let bw = (1 + CGFloat(Motion.hash(k, 1) * 2.5)) * s
            if Motion.hash(k, 2) > 0.35 { ctx.fill(Path(CGRect(x: x, y: strip.minY, width: bw, height: strip.height)), with: .color(.white.opacity(0.55))) }
            x += bw + 1.2 * s
            k += 1
        }
    }

    /// Apple Pay sheet: bottom-sheet surface, Face ID pulse turning into a checkmark when the line ends.
    private func pay(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ ctx: GraphicsContext) {
        let shape = Path(roundedRect: r, cornerRadii: RectangleCornerRadii(topLeading: 24 * s, bottomLeading: 12 * s, bottomTrailing: 12 * s, topTrailing: 24 * s), style: .continuous)
        surface(shape, .color(AppleColors.surface), ctx)
        ctx.stroke(shape, with: .color(.white.opacity(0.07)), lineWidth: 0.8)
        ctx.fill(Path(roundedRect: CGRect(x: r.midX - 18 * s, y: r.minY + 7 * s, width: 36 * s, height: 5 * s), cornerRadius: 2.5 * s), with: .color(.white.opacity(0.25)))
        ctx.draw(Text("\(Image(systemName: "apple.logo"))Pay").font(.system(size: 20 * s, weight: .semibold)).foregroundColor(.white),
                 at: CGPoint(x: r.minX + 24 * s, y: r.minY + 34 * s), anchor: .leading)
        ctx.text("Cancel", font: .system(size: 14 * s, weight: .regular), color: AppleColors.blue, at: CGPoint(x: r.maxX - 24 * s, y: r.minY + 34 * s), anchor: .trailing)
        ctx.fill(Path(CGRect(x: r.minX + 24 * s, y: r.minY + 54 * s, width: r.width - 48 * s, height: 0.5)), with: .color(.white.opacity(0.12)))
        ctx.draw(lyric(words, size: fs, weight: .bold), in: CGRect(x: r.minX + 24 * s, y: r.minY + 64 * s, width: r.width - 48 * s, height: r.height - 150 * s))
        let done = frame.position >= (words.last?.end ?? 0)
        let center = CGPoint(x: r.midX, y: r.maxY - 46 * s)
        if done {
            let k = Motion.spring(frame.position - (words.last?.end ?? 0), response: 0.3, damping: 0.5)
            ctx.draw(Text(Image(systemName: "checkmark.circle.fill")).font(.system(size: 34 * s * CGFloat(0.6 + 0.4 * k), weight: .regular)).foregroundColor(AppleColors.green), at: center)
            ctx.text("Done", font: .system(size: 13 * s, weight: .semibold), color: .white, at: CGPoint(x: center.x, y: center.y + 28 * s))
        } else {
            let pulse = max(0.5 + 0.5 * sin(frame.clock * 5), Double(frame.kick))
            ctx.draw(Text(Image(systemName: "faceid")).font(.system(size: 34 * s * frame.thump(0.1), weight: .regular)).foregroundColor(AppleColors.blue.opacity(0.6 + 0.4 * pulse)), at: center)
            ctx.text("Confirm with Face ID", font: .system(size: 13 * s, weight: .semibold), color: .white.opacity(0.8), at: CGPoint(x: center.x, y: center.y + 28 * s))
        }
    }

    /// Compact map window with a pin and the line as its caption.
    private func mapCard(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ card: MoneyPlan.Card, _ picture: MapPicture?, _ ctx: GraphicsContext) {
        let shape = Path(roundedRect: r, cornerRadius: 18 * s, style: .continuous)
        surface(shape, .color(AppleColors.surface), ctx)
        var c = ctx
        c.clip(to: shape)
        let mapRect = CGRect(x: r.minX, y: r.minY, width: r.width, height: 104 * s)
        guard let shot = card.mapShot(scale: s), let landmark = card.landmark else { return }
        if let picture {
            c.draw(Image(nsImage: picture.image), in: mapRect)
        } else {
            MapMath.drawPlaceholder(in: c, rect: mapRect, seed: card.line)
        }
        let project = picture?.project ?? MapMath.approximateProjection(shot)
        let scale = mapRect.width / shot.size.width
        let pinPoint = project(landmark.coordinate)
        MapMath.drawPin(at: CGPoint(x: mapRect.minX + pinPoint.x * scale, y: mapRect.minY + pinPoint.y * scale), color: card.tint, in: c,
                        drop: Motion.spring(frame.position - card.arrive, response: 0.45, damping: 0.55))
        c.text(landmark.name, font: .system(size: 11 * s, weight: .semibold), color: AppleColors.gray,
               at: CGPoint(x: r.minX + 16 * s, y: mapRect.maxY + 14 * s), anchor: .leading)
        c.draw(lyric(words, size: fs, weight: .semibold), in: CGRect(x: r.minX + 16 * s, y: mapRect.maxY + 24 * s, width: r.width - 32 * s, height: r.height - mapRect.height - 28 * s))
    }

    /// iMessage payment reply bubble.
    private func message(_ r: CGRect, _ words: [TimedWord], _ fs: CGFloat, _ ctx: GraphicsContext) {
        var path = Path(roundedRect: r, cornerRadius: min(r.height / 2, 18 * s), style: .continuous)
        path.addPath(AppleThreadCanvas.tail(r, outgoing: true, s: s))
        surface(path, .linearGradient(Gradient(colors: [AppleColors.blue, AppleColors.blue.mixed(AppleColors.blueDeep, 0.38)]),
                                      startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)), ctx)
        ctx.draw(lyric(words, size: fs, weight: .regular), in: r.insetBy(dx: 12 * s, dy: 7 * s).insetBy(dx: -1, dy: -2))
    }
}
