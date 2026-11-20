import SwiftUI

// MARK: - Model

enum FlashRole { case identifier, keyword, accent, payload, punct, comment }

struct FlashSegment {
    let text: String
    let role: FlashRole
    /// Index into the chunk's `words`, for segments that are a lyric word.
    let wordIndex: Int?
}

struct FlashChunk {
    let words: [TimedWord]
    let segments: [FlashSegment]
    let isComment: Bool
}

/// Formats each lyric line, deterministically, as one line of Swift/JS-like code.
enum FlashTokenizer {
    private static let codeKeywords: Set<String> = [
        "if", "else", "for", "in", "while", "return", "let", "var", "true", "false", "not", "and", "or", "do",
        "try", "await", "async", "new", "this", "self", "nil", "null", "break", "case", "switch", "default", "func",
    ]

    static let plan = PlanCache<[FlashChunk]>()

    static func chunks(_ lyrics: TimedLyrics) -> [FlashChunk] {
        var out: [FlashChunk] = []
        var previousTemplate = -1
        for (gi, words) in lyrics.groups.enumerated() {
            let (chunk, template) = chunk(words, line: gi, avoid: previousTemplate)
            previousTemplate = template
            out.append(chunk)
        }
        return out
    }

    private static func ident(_ s: String) -> String {
        let t = s.filter { $0.isLetter || $0.isNumber }
        return t.isEmpty ? s : t.lowercased()
    }

    private static func chunk(_ words: [TimedWord], line: Int, avoid: Int) -> (FlashChunk, Int) {
        var segs: [FlashSegment] = []
        func p(_ t: String) { segs.append(FlashSegment(text: t, role: .punct, wordIndex: nil)) }
        func k(_ t: String) { segs.append(FlashSegment(text: t, role: .keyword, wordIndex: nil)) }
        func word(_ i: Int, _ role: FlashRole, ident asIdent: Bool = false) {
            let raw = words[i].text
            var r = role
            if asIdent, codeKeywords.contains(ident(raw)) { r = .keyword }
            if role == .payload, raw.hasSuffix("!") { r = .accent }
            segs.append(FlashSegment(text: asIdent ? ident(raw) : raw, role: r, wordIndex: i))
        }
        /// Words `from..<words.count` joined by spaces, each its own segment.
        func run(_ from: Int, _ role: FlashRole, ident asIdent: Bool = false, separator: String = " ") {
            for i in from..<words.count {
                if i > from { p(separator) }
                word(i, role, ident: asIdent)
            }
        }

        let n = words.count
        let text = words.map(\.text).joined(separator: " ")
        let parenthetical = text.hasPrefix("(") || text.hasSuffix(")")
        guard n > 0 else { return (FlashChunk(words: words, segments: [], isComment: true), -1) }

        if parenthetical || (n <= 3 && Motion.hash(line, 5) < 0.3) {
            segs.append(FlashSegment(text: "// ", role: .comment, wordIndex: nil))
            for i in 0..<n {
                if i > 0 { segs.append(FlashSegment(text: " ", role: .comment, wordIndex: nil)) }
                segs.append(FlashSegment(text: words[i].text, role: .comment, wordIndex: i))
            }
            return (FlashChunk(words: words, segments: segs, isComment: true), -1)
        }
        if n == 1 {
            k("return "); p("\""); word(0, .payload); p("\";")
            return (FlashChunk(words: words, segments: segs, isComment: false), 9)
        }
        if n == 2 {
            k("let "); word(0, .identifier, ident: true); p(" = "); word(1, .accent, ident: true); p(";")
            return (FlashChunk(words: words, segments: segs, isComment: false), 8)
        }

        var template = Int(Motion.hash(line, 11) * 5)
        if template == avoid { template = (template + 1) % 5 }
        switch template {
        case 0: // let driving = "fast in my car";
            k("let "); word(0, .identifier, ident: true); p(" = \""); run(1, .payload); p("\";")
        case 1: // func sing(word) -> the rest {
            k("func "); word(0, .accent, ident: true); p("("); word(1, .identifier, ident: true); p(") -> ")
            run(2, .identifier, ident: true, separator: "."); p(" {")
        case 2: // heart.beat("for you tonight");
            word(0, .identifier, ident: true); p("."); word(1, .accent, ident: true); p("(\""); run(2, .payload); p("\");")
        case 3: // if you == "hear the music" {
            k("if "); word(0, .identifier, ident: true); p(" == \""); run(1, .payload); p("\" {")
        default: // await call(me, "when the moon is high");
            k("await "); word(0, .accent, ident: true); p("("); word(1, .identifier, ident: true); p(", \""); run(2, .payload); p("\");")
        }
        return (FlashChunk(words: words, segments: segs, isComment: false), template)
    }
}

// MARK: - Scene

/// Codestyle — each line is typed out as code under a blinking red cursor; the editor scrolls a line
/// per lyric with a vertical motion blur. Codestyle Visual pops icons beside word tokens.
struct FlashbangScene: View {
    let frame: LyricFrame
    let withIcons: Bool

    static let keyword = Color(hex: "#DEBDFA")
    static let accent = Color(hex: "#FFA380")
    static let payload = Color(hex: "#FCD17A")
    static let cursor = Color(hex: "#FF453A")

    var body: some View {
        let f = frame
        let chunks = FlashTokenizer.plan.value(for: f.songKey) { FlashTokenizer.chunks(f.lyrics) }
        let current = f.groupIndex ?? f.cursor.next.map { $0 - 1 } ?? -1
        let size = fontSize(chunks, current)
        let lineHeight = size * 1.6
        // Scroll: the editor advances one line per lyric with the standard spring.
        let since = current >= 0 ? f.position - f.lineOnset(current) : 10
        let scroll = 1 - Motion.spring(since)
        let velocity = -lineHeight * Motion.springVelocity(since) / 60 * 1.4
        let left = blockLeft(chunks, current, size)
        let visible = Array(max(0, current - 3)...max(0, current)).filter { chunks.indices.contains($0) && current >= 0 }

        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.self) { ci in
                let depth = current - ci
                CodeLine(frame: f, chunk: chunks[ci], lineNumber: ci + 1, size: size, isCurrent: depth == 0 && f.groupIndex != nil,
                         withIcons: withIcons)
                    .opacity(lineAlpha(depth) * (f.groupIndex == nil && depth == 0 ? gapFade(current) : 1))
                    .offset(x: left, y: f.bandCenterY - lineHeight / 2 + (CGFloat(-depth) + CGFloat(scroll)) * lineHeight)
            }
        }
        .frame(width: f.canvas.width, height: f.canvas.height, alignment: .topLeading)
        .motionBlur(CGVector(dx: 0, dy: max(-40, min(40, velocity))), enabled: f.shaders)
    }

    private func lineAlpha(_ depth: Int) -> Double {
        switch depth {
        case 0: return 1
        case 1: return 0.5
        case 2: return 0.3
        default: return 0.15
        }
    }

    private func gapFade(_ i: Int) -> Double { Motion.smooth((frame.lineEnd(i) + 2.5 - frame.position) / 0.35) }

    private static func chars(_ c: FlashChunk) -> Int { c.segments.reduce(0) { $0 + $1.text.count } + 5 }

    /// Monospaced, sized so the current line fits the canvas once fully typed.
    private func fontSize(_ chunks: [FlashChunk], _ current: Int) -> CGFloat {
        let base = 30 * frame.textScale
        guard chunks.indices.contains(current) else { return base }
        let fit = frame.canvas.width * 0.88 / (CGFloat(Self.chars(chunks[current])) * 0.61)
        return max(11, min(base, fit))
    }

    /// The block is centered on the current line's finished width, so typing never shifts it.
    private func blockLeft(_ chunks: [FlashChunk], _ current: Int, _ size: CGFloat) -> CGFloat {
        guard chunks.indices.contains(current) else { return frame.canvas.width * 0.1 }
        let width = CGFloat(Self.chars(chunks[current])) * size * 0.61
        return max(frame.canvas.width * 0.04, (frame.canvas.width - width) / 2)
    }
}

private struct CodeLine: View {
    let frame: LyricFrame
    let chunk: FlashChunk
    let lineNumber: Int
    let size: CGFloat
    let isCurrent: Bool
    let withIcons: Bool

    var body: some View {
        let p = frame.palette
        HStack(alignment: .center, spacing: 0) {
            Text(String(format: "%3d  ", lineNumber).replacingOccurrences(of: " ", with: "\u{00A0}"))
                .foregroundStyle(p.secondary.opacity(0.35))
            ForEach(chunk.segments.indices, id: \.self) { si in
                segment(si)
            }
            if isCurrent {
                Rectangle()
                    .fill(FlashbangScene.cursor)
                    .frame(width: 3, height: size * 1.15)
                    .opacity(sin(frame.clock * 7.5) > 0 ? 1.0 : 0.15)
                    .shadow(color: FlashbangScene.cursor.opacity(0.8), radius: 4)
                    .padding(.leading, 1)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .monospaced))
        .fixedSize()
        .animation(Motion.standard, value: revealedCount)
    }

    private var revealedCount: Int { chunk.segments.indices.filter { reveal($0) > 0 }.count }

    @ViewBuilder private func segment(_ si: Int) -> some View {
        let seg = chunk.segments[si]
        let shown = reveal(si)
        if shown > 0 {
            let text = String(seg.text.prefix(shown)).replacingOccurrences(of: " ", with: "\u{00A0}")
            let active = seg.wordIndex.map { frame.isActive(chunk.words[$0]) } ?? false
            let color = color(seg.role)
            // Kicks and snare / vocal transients surge the active token's glow and brightness.
            let surge = min(1.4, frame.kick + 0.6 * frame.flux)
            HStack(spacing: 0) {
                Text(text)
                    .foregroundStyle(color)
                    .italic(seg.role == .comment)
                    .brightness(active ? 0.18 * Double(surge) : 0)
                    .shadow(color: active ? color.opacity(0.9) : .clear, radius: 0.35)
                    .shadow(color: active ? color.opacity(min(1, 0.7 + 0.3 * Double(surge))) : .clear, radius: active ? 6 + 12 * surge : 0)
                if withIcons, let wi = seg.wordIndex, shown >= seg.text.count,
                   let v = WordVisualResolver.shared.visual(for: chunk.words[wi].text) {
                    FlashIcon(visual: v, size: size * 0.9, color: active ? frame.palette.highlight : color, age: frame.position - window(si).1,
                              kick: active ? frame.kick : 0)
                        .padding(.horizontal, size * 0.25)
                }
            }
        }
    }

    private func color(_ role: FlashRole) -> Color {
        let p = frame.palette
        switch role {
        case .keyword: return FlashbangScene.keyword
        case .identifier: return p.text
        case .accent: return FlashbangScene.accent
        case .payload: return FlashbangScene.payload
        case .punct: return p.secondary.opacity(0.7)
        case .comment: return p.secondary.opacity(0.55)
        }
    }

    /// Characters of segment `si` typed so far. Words type across their own `[start, end]`; code around
    /// them types just before the next word (or just after the last one).
    private func reveal(_ si: Int) -> Int {
        let seg = chunk.segments[si]
        let count = seg.text.count
        let (t0, t1) = window(si)
        let p = (frame.position - t0) / max(0.02, t1 - t0)
        if p <= 0 { return 0 }
        return min(count, Int((Double(count) * p).rounded(.up)))
    }

    private func window(_ si: Int) -> (Double, Double) {
        let segs = chunk.segments
        if let wi = segs[si].wordIndex {
            let w = chunk.words[wi]
            return (w.start, w.start + max(0.06, (w.end - w.start) * 0.85))
        }
        if let next = segs[(si + 1)...].first(where: { $0.wordIndex != nil })?.wordIndex {
            let s = chunk.words[next].start
            // Leading code of the line types during the 0.35 s pre-roll; the rest just before its word.
            let lead = segs[..<si].contains { $0.wordIndex != nil } ? 0.1 : 0.3
            return (s - lead, s - 0.01)
        }
        let end = chunk.words.last?.end ?? 0
        return (end, end + 0.12)
    }
}
