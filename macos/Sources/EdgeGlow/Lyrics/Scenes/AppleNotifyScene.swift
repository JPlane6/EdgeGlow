import SwiftUI

// MARK: - Plan

enum NotifyPlan {
    enum Kind { case banner, siri, widget, glance }

    struct Item {
        let line: Int
        let kind: Kind
        let arrive: Double
    }

    static let cache = PlanCache<[Item]>()

    /// Short lines become Live Activity glances, questions and exclamations Siri cards, long lines widgets
    /// now and then, the rest Lock Screen banners.
    static func build(_ lyrics: TimedLyrics) -> [Item] {
        var out: [Item] = []
        var previous: Kind?
        for gi in lyrics.groups.indices {
            let words = lyrics.groups[gi]
            let text = lyrics.lineText(gi)
            var kind: Kind
            if words.count <= 3 { kind = .glance }
            else if text.hasSuffix("?") || text.hasSuffix("!") { kind = .siri }
            else if words.count >= 7 && Motion.hash(gi, 41) < 0.45 { kind = .widget }
            else { kind = Motion.hash(gi, 42) < 0.18 ? .siri : .banner }
            if kind == previous, kind != .banner { kind = .banner }
            previous = kind
            out.append(Item(line: gi, kind: kind, arrive: (words.first?.start ?? 0) - 0.1))
        }
        return out
    }
}

// MARK: - Feed physics

/// One notification in the stack.
struct NotifyPanel: Identifiable {
    let item: NotifyPlan.Item
    let rect: CGRect          // where it is drawn (after stacking)
    let rest: CGRect          // its own unstacked size at the front
    let radius: CGFloat
    let depth: Double         // 0 = front, 1, 2, … (continuous)
    let alpha: Double
    let soft: CGFloat         // depth blur radius
    let age: Double
    let handoff: Double       // 0…1, how far it has been pushed back by the newest
    let moving: Double        // entrance spring 0…1
    var id: Int { item.line }
}

/// Stateless stacking: each newer notification pushes every older one one step back through a spring, so
/// depth, scale (1.0 → 0.94 → 0.88), compression, blur (7 / 9 / 11 pt) and the entrance velocity all
/// come from timestamps.
struct NotifyFeed {
    let panels: [NotifyPanel]
    let velocity: CGFloat
    let s: CGFloat

    init(frame f: LyricFrame, items: [NotifyPlan.Item]) {
        let s = min(1.6, f.textScale)
        self.s = s
        let width = min(f.canvas.width * 0.9, 380 * s)
        let pos = f.position
        let arrived = items.filter { $0.arrive <= pos }
        let clearance = f.locked ? f.canvas.height * 0.26 : 0
        var panels: [NotifyPanel] = []
        let newest = arrived.last
        let frontSize = newest.map { Self.size($0, frame: f, width: width, s: s) } ?? .zero
        let anchorTop = max(clearance + 20 * s, f.bandCenterY - frontSize.height / 2)

        for (k, item) in arrived.enumerated().reversed() {
            var depth = 0.0
            for later in arrived[(k + 1)...] { depth += Motion.spring(pos - later.arrive, response: 0.42, damping: 0.8) }
            guard depth < 3.6 else { break }
            let own = Self.size(item, frame: f, width: width, s: s)
            let scale = 1 - 0.06 * CGFloat(depth)
            // Older panels compress toward the front panel's height and peek out below it.
            let squeeze = CGFloat(min(1, depth))
            let height = (own.height + (frontSize.height - own.height) * squeeze) * scale
            let w = own.width * scale
            let peek = CGFloat(depth) * 11 * s
            let age = pos - item.arrive
            let enter = Motion.spring(age, response: 0.42, damping: 0.72)
            let drop = (1 - CGFloat(enter)) * -64 * s
            let top = anchorTop + frontSize.height - height + peek + drop
            let rect = CGRect(x: (f.canvas.width - w) / 2, y: top, width: w, height: height)
            let soft: CGFloat
            switch depth {
            case ..<1: soft = 7.0 * CGFloat(depth)
            case ..<2: soft = 7.0 + 2.0 * CGFloat(depth - 1)
            default: soft = 9.0 + 2.0 * CGFloat(min(1, depth - 2))
            }
            let alpha = Motion.smooth(age / 0.15) * (depth < 1 ? 1 : max(0, 1 - 0.32 * (depth - 1)))
            panels.append(NotifyPanel(item: item, rect: rect, rest: CGRect(origin: .zero, size: own), radius: Self.radius(item.kind, s: s) * scale,
                                      depth: depth, alpha: alpha, soft: soft, age: age, handoff: min(1, depth), moving: enter))
        }
        self.panels = panels.sorted { $0.depth > $1.depth }
        let frontAge = newest.map { pos - $0.arrive } ?? 10
        velocity = 64 * s * CGFloat(Motion.springVelocity(frontAge, response: 0.42, damping: 0.72)) / 60 * 1.4
    }

    static func radius(_ kind: NotifyPlan.Kind, s: CGFloat) -> CGFloat {
        switch kind {
        case .banner: return 22 * s
        case .siri: return 26 * s
        case .widget: return 24 * s
        case .glance: return 20 * s
        }
    }

    static func size(_ item: NotifyPlan.Item, frame f: LyricFrame, width: CGFloat, s: CGFloat) -> CGSize {
        let text = f.lineText(item.line)
        switch item.kind {
        case .banner:
            let t = TextMeasure.shared.size(text, size: 15 * s, weight: .medium, width: width - 28 * s - 38 * s - 12 * s, maxLines: 3)
            return CGSize(width: width, height: max(68 * s, t.height + 28 * s + 19 * s + 6 * s))
        case .siri:
            let t = TextMeasure.shared.size(text, size: 19 * s, weight: .bold, width: width - 32 * s - 36 * s - 12 * s, maxLines: 3)
            return CGSize(width: width, height: max(66 * s, t.height + 36 * s + 6 * s))
        case .widget:
            let t = TextMeasure.shared.size(text, size: 19 * s, weight: .bold, width: width - 32 * s - 72 * s - 14 * s, maxLines: 3)
            return CGSize(width: width, height: max(104 * s, t.height + 18 * s + 34 * s + 6 * s))
        case .glance:
            let t = TextMeasure.shared.size(text, size: 13.5 * s, weight: .bold, width: 1000)
            return CGSize(width: min(width, t.width + 26 * s + 24 * s + 30 * s + 16 * s), height: 42 * s)
        }
    }
}

// MARK: - Scene

/// Apple Design Notifications — lines arrive as Lock Screen notifications, Siri cards, widgets and
/// Live Activity glances, stacking with depth blur and a motion-blurred drop-in.
struct AppleNotifyScene: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame
        let items = NotifyPlan.cache.value(for: f.songKey) { NotifyPlan.build(f.lyrics) }
        let feed = NotifyFeed(frame: f, items: items)
        NotifyFeedCanvas(frame: f, feed: feed)
            .motionBlur(CGVector(dx: 0, dy: max(-32, min(32, feed.velocity))), enabled: f.shaders)
    }
}

struct NotifyFeedCanvas: View {
    let frame: LyricFrame
    let feed: NotifyFeed

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(feed.panels) { panel in
                NotifyPanelView(frame: frame, panel: panel, s: feed.s)
                    .frame(width: panel.rect.width, height: panel.rect.height)
                    .rotation3DEffect(.degrees(14 * (1 - panel.moving)), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
                    .scaleEffect(x: 1, y: 0.92 + 0.08 * min(1, panel.moving), anchor: .top)
                    .blur(radius: panel.soft)
                    .opacity(panel.alpha)
                    .position(x: panel.rect.midX, y: panel.rect.midY)
                    .zIndex(-panel.depth)
            }
        }
        .frame(width: frame.canvas.width, height: frame.canvas.height, alignment: .topLeading)
    }
}

private struct NotifyPanelView: View {
    let frame: LyricFrame
    let panel: NotifyPanel
    let s: CGFloat

    private var words: [TimedWord] { frame.group(panel.item.line) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: panel.radius, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(background(shape))
            .clipShape(shape)
            .overlay(border(shape))
            .overlay(echo(shape))
            .shadow(color: .black.opacity(0.4), radius: 3.0, y: 1.5)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch panel.item.kind {
        case .banner:
            HStack(alignment: .top, spacing: 12 * s) {
                art(38 * s, radius: 9 * s)
                VStack(alignment: .leading, spacing: 3 * s) {
                    HStack {
                        Text(frame.track.artist.isEmpty ? "Music" : frame.track.artist)
                            .font(.system(size: 12 * s, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("now").font(.system(size: 11 * s, weight: .regular)).foregroundStyle(.white.opacity(0.55))
                    }
                    lyric(15 * s, .medium).lineLimit(3)
                }
            }
            .padding(14 * s)
        case .siri:
            HStack(spacing: 12 * s) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 26 * s, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: Self.siri, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36 * s)
                lyric(19 * s, .bold).lineLimit(3)
            }
            .padding(.horizontal, 16 * s)
            .padding(.vertical, 18 * s)
        case .widget:
            HStack(alignment: .center, spacing: 14 * s) {
                art(72 * s, radius: 16 * s)
                VStack(alignment: .leading, spacing: 6 * s) {
                    lyric(19 * s, .bold).lineLimit(3)
                    Text([frame.track.title, frame.track.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12 * s, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            .padding(16 * s)
        case .glance:
            HStack(spacing: 10 * s) {
                art(26 * s, radius: 13 * s)
                lyric(13.5 * s, .bold).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 15 * s, weight: .bold))
                    .foregroundStyle(tint)
                    .scaleEffect(x: 1, y: 0.75 + 0.25 * CGFloat(abs(sin(frame.clock * 6))))
            }
            .padding(.horizontal, 8 * s)
            .padding(.trailing, 6 * s)
        }
    }

    private func lyric(_ size: CGFloat, _ weight: Font.Weight) -> Text {
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            var part = AttributedString((i > 0 ? " " : "") + w.text)
            part.foregroundColor = Color.white.opacity(0.35 + 0.65 * Motion.smooth((frame.position - w.start) / 0.12))
            out += part
        }
        return Text(out).font(.system(size: size, weight: weight))
    }

    @ViewBuilder private func art(_ side: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = frame.track.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [AppleColors.pink, AppleColors.red], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "music.note").font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var tint: Color { frame.track.blooms.first ?? AppleColors.pink }

    // MARK: Surfaces

    static let siri = ["#FF375F", "#BF5AF2", "#0A84FF", "#40C8E0", "#FF9F0A", "#FF375F"].map(Color.init(hex:))

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        ZStack {
            glass(shape)
            if panel.item.kind == .widget {
                shape.fill(LinearGradient(colors: [tint.opacity(0.42), (frame.track.blooms.dropFirst().first ?? AppleColors.indigo).opacity(0.25)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }

    /// Frosted dark glass: Liquid Glass on macOS 26+, ultra-thin material before; always over a dark tint
    /// so text stays legible on any wallpaper.
    @ViewBuilder private func glass(_ shape: RoundedRectangle) -> some View {
        let tinted = shape.fill(Color(hex: "#1C1C1E").opacity(frame.still ? 0.88 : 0.5))
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !frame.still {
            Color.clear.glassEffect(.regular, in: shape).overlay(tinted)
        } else {
            materialGlass(shape, tinted)
        }
        #else
        materialGlass(shape, tinted)
        #endif
    }

    @ViewBuilder private func materialGlass(_ shape: RoundedRectangle, _ tinted: some View) -> some View {
        if frame.still { tinted } else { shape.fill(.ultraThinMaterial).overlay(tinted) }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        if panel.item.kind == .siri {
            shape.strokeBorder(AngularGradient(colors: Self.siri, center: .center, angle: .degrees(frame.clock * 90)), lineWidth: 2.5 * s)
                .shadow(color: AppleColors.purple.opacity(0.6), radius: 8)
        } else {
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        }
    }

    /// A glow ring that expands as the notification lands.
    @ViewBuilder private func echo(_ shape: RoundedRectangle) -> some View {
        if panel.age < 0.7 && panel.depth < 0.5 {
            let k = CGFloat(max(0, panel.age) / 0.7)
            shape.stroke(Color.white.opacity(0.35 * Double(1 - k)), lineWidth: 2)
                .padding(-10 * s * k)
        }
    }
}
