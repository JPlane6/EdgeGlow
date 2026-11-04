import Foundation
import CryptoKit

final class LyricsProvider: @unchecked Sendable {
    static let maxCandidateProbes = 5
    static let durationToleranceMs = 2500

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    // MARK: - Public

    /// Definite "this is not music" answers, so we never re-ask. Network errors are never cached.
    private var rejected = Set<String>()
    private let rejectedLock = NSLock()

    private func isRejected(_ k: String) -> Bool { rejectedLock.lock(); defer { rejectedLock.unlock() }; return rejected.contains(k) }
    private func reject(_ k: String) { rejectedLock.lock(); rejected.insert(k); rejectedLock.unlock() }

    /// Resolves lyrics for a track. Returns nil — and the UI stays invisible — unless valid lyrics exist.
    /// - Music apps: NetEase word-level → LRCLIB → NetEase LRC.
    /// - Everything else (browsers, VLC, IINA…): LRCLIB is the validator; a miss means "not music".
    enum Outcome { case found(TimedLyrics), none, retry }

    private final class FailureFlag { var failed = false }

    /// `.none` is a definitive answer (hide); `.retry` means a service was unreachable or busy.
    func lyrics(for track: TrackInfo, kind: MediaSourceKind) async -> Outcome {
        let flag = FailureFlag()
        if let l = await resolve(track, kind, flag) { return .found(l) }
        return flag.failed ? .retry : .none
    }

    private func resolve(_ track: TrackInfo, _ kind: MediaSourceKind, _ flag: FailureFlag) async -> TimedLyrics? {
        if kind == .podcast { return nil }
        let cacheKey = Self.cacheKey(for: track)
        if let cached = Self.readCache(cacheKey) { return cached }

        let clean = Self.sanitize(title: track.title, artist: track.artist)
        guard !clean.title.isEmpty else { return nil }

        if kind == .validated {
            // Cheap local pre-filter: songs aren't hours long.
            if track.duration > MediaSourcePolicy.maxValidatedDuration { return nil }
            if isRejected(cacheKey) { return nil }
            switch await lrclibLookup(title: clean.title, artist: clean.artist, album: track.album, duration: track.duration, strict: true) {
            case .notFound:
                reject(cacheKey)
                return nil
            case .failed:
                flag.failed = true
                return nil
            case .found(let lrc):
                // Validated as music: upgrade to true word timings if NetEase has them.
                if let r = await neteaseLookup(title: clean.title, artist: clean.artist, duration: track.duration),
                   let yrc = r.yrc, let parsed = Self.parseYRC(yrc) {
                    Self.writeCache(parsed, key: cacheKey)
                    return parsed
                }
                guard let parsed = Self.interpolate(lrc: lrc, trackDuration: track.duration, source: "LRCLIB") else { return nil }
                Self.writeCache(parsed, key: cacheKey)
                return parsed
            }
        }

        var neteaseLRC: String?
        if let r = await neteaseLookup(title: clean.title, artist: clean.artist, duration: track.duration) {
            if let yrc = r.yrc, let parsed = Self.parseYRC(yrc) {
                Self.writeCache(parsed, key: cacheKey)
                return parsed
            }
            neteaseLRC = r.lrc
        }
        let lr = await lrclibLookup(title: clean.title, artist: clean.artist, album: track.album, duration: track.duration, strict: false)
        if case .found(let lrc) = lr, let parsed = Self.interpolate(lrc: lrc, trackDuration: track.duration, source: "LRCLIB") {
            Self.writeCache(parsed, key: cacheKey)
            return parsed
        }
        if case .failed = lr { flag.failed = true }
        if let lrc = neteaseLRC, let parsed = Self.interpolate(lrc: lrc, trackDuration: track.duration, source: "NetEase LRC") {
            Self.writeCache(parsed, key: cacheKey)
            return parsed
        }
        return nil
    }

    // MARK: - Sanitizer

    private static let noisePatterns: [String] = [
        #"\((feat|ft|with|featuring)[.\s][^)]*\)"#,
        #"\((from|theme from|music from)[^)]*\)"#,
        #"\((\d{4} )?(re-?master(ed)?|deluxe|bonus|explicit|single|album)[^)]*\)"#,
        // Only the remaster suffix is noise; "- Remix", "- Radio Edit", "- Live" etc. identify a different recording.
        #"\s-\s*(\d{4}\s+)?re-?master(ed)?(\s+\d{4})?\s*$"#,
        // YouTube noise
        #"[\[\(]\s*(official\s*)?(music\s*)?(lyric(s)?\s*)?(video|audio|visuali[sz]er|mv|hd|4k|hq)\s*[\]\)]"#,
        #"[\[\(]\s*(lyrics?|with lyrics?|lyric video)\s*[\]\)]"#,
        #"\[[^\]]*(official|lyrics?|4k|hd)[^\]]*\]"#,
        #"\b(HD|4K|HQ)\b"#,
        #"\s*\|\s.*$"#,
        #"\s*-\s*Topic$"#,
        #"(?i)\bVEVO\b"#,
    ]
    private static let noiseRegexes: [NSRegularExpression] = noisePatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    private static func strip(_ s: String) -> String {
        var out = s
        for re in noiseRegexes {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitize(title: String, artist: String) -> (title: String, artist: String) {
        LyricSanitizer.sanitize(title: strip(title), artist: artist)
    }

    // MARK: - Credit filtering

    private static let creditRegex = try! NSRegularExpression(
        pattern: #"(producer|produced|composed|composer|lyrics by|lyricist|written by|arranged|arrangement|作词|作曲|编曲|制作|监制|混音|母带|\[[^\]]*\])"#,
        options: [.caseInsensitive])
    private static let bracketRegex = try! NSRegularExpression(pattern: #"^\s*\[[^\]]*\]\s*$"#)

    static func isCreditLine(_ text: String, position: Int) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if bracketRegex.firstMatch(in: text, range: range) != nil { return true }   // [Chorus], [Verse 1]
        guard position < 10 else { return false }
        return creditRegex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - NetEase

    private struct NetEaseResult { var yrc: String?; var lrc: String? }

    private func request(_ url: URL, netease: Bool = false) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if netease { r.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        return r
    }

    private func neteaseLookup(title: String, artist: String, duration: Double) async -> NetEaseResult? {
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(for: request(url, netease: true)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        let targetMs = Int(duration * 1000)
        struct Cand { var id: Int; var score: Int }
        var candidates: [Cand] = []
        for s in songs {
            guard let id = s["id"] as? Int else { continue }
            let ms = (s["duration"] as? Int) ?? (s["dt"] as? Int) ?? 0
            if targetMs > 0, ms > 0, abs(ms - targetMs) > Self.durationToleranceMs { continue }
            // The search is fuzzy: without a title match NetEase happily returns an unrelated (often Chinese) song.
            let hitName = (s["name"] as? String) ?? ""
            let hitArtists = ((s["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: " ")
            let titleScore = LyricSanitizer.similarity(title, hitName)
            let artistMatch = !artist.isEmpty && LyricSanitizer.similarity(artist, hitArtists) > 0
            if titleScore < 0.5 || (!artist.isEmpty && !artistMatch && titleScore < 1) { continue }
            var score = targetMs > 0 && ms > 0 ? abs(ms - targetMs) : 1000
            let artists = ((s["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: " ").lowercased()
            if !artist.isEmpty, artists.contains(artist.lowercased()) { score -= 600 }
            if let name = (s["name"] as? String)?.lowercased(), name == title.lowercased() { score -= 300 }
            candidates.append(Cand(id: id, score: score))
        }
        candidates.sort { $0.score < $1.score }

        var lrcFallback: String?
        for c in candidates.prefix(Self.maxCandidateProbes) {
            var lc = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
            lc.queryItems = [
                URLQueryItem(name: "id", value: String(c.id)),
                URLQueryItem(name: "cp", value: "false"),
                URLQueryItem(name: "lv", value: "-1"), URLQueryItem(name: "yv", value: "-1"),
                URLQueryItem(name: "tv", value: "-1"), URLQueryItem(name: "kv", value: "-1"),
            ]
            guard let lurl = lc.url,
                  let (ld, _) = try? await session.data(for: request(lurl, netease: true)),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }
            let yrc = (obj["yrc"] as? [String: Any])?["lyric"] as? String
            let lrc = (obj["lrc"] as? [String: Any])?["lyric"] as? String
            if let yrc, !yrc.isEmpty { return NetEaseResult(yrc: yrc, lrc: lrc) }
            if lrcFallback == nil, let lrc, !lrc.isEmpty { lrcFallback = lrc }
        }
        return lrcFallback.map { NetEaseResult(yrc: nil, lrc: $0) }
    }

    /// Parses NetEase yrc: `[lineStartMs,lineDurMs](wordStartMs,wordDurMs,0)text…`
    static func parseYRC(_ yrc: String) -> TimedLyrics? {
        let lineRe = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordRe = try! NSRegularExpression(pattern: #"\((\d+),(\d+),-?\d+\)([^(]*)"#)

        struct Line { var words: [(text: String, start: Double, end: Double)] }
        var lines: [Line] = []

        for raw in yrc.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            if s.hasPrefix("{") { continue }   // metadata JSON rows (credits)
            let ns = s as NSString
            guard let lm = lineRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let body = ns.substring(with: lm.range(at: 3)) as NSString
            var chunks: [(String, Double, Double)] = []
            for m in wordRe.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                let st = Double(body.substring(with: m.range(at: 1))) ?? 0
                let du = Double(body.substring(with: m.range(at: 2))) ?? 0
                let tx = body.substring(with: m.range(at: 3))
                chunks.append((tx, st / 1000, (st + du) / 1000))
            }
            guard !chunks.isEmpty else { continue }

            // Merge syllable chunks into words (split on whitespace; CJK stays per-glyph).
            var merged: [(text: String, start: Double, end: Double)] = []
            var prevEndedWithSpace = true
            for (tx, st, en) in chunks {
                let startsWithSpace = tx.first?.isWhitespace ?? false
                let trimmed = tx.trimmingCharacters(in: .whitespaces)
                defer { prevEndedWithSpace = tx.last?.isWhitespace ?? false }
                if trimmed.isEmpty { continue }
                let isCJK = trimmed.unicodeScalars.contains(where: LyricText.isCJK)
                var prevIsCJK = false
                if let lastScalar = merged.last?.text.unicodeScalars.last { prevIsCJK = LyricText.isCJK(lastScalar) }
                if !merged.isEmpty, !prevEndedWithSpace, !startsWithSpace, !isCJK, !prevIsCJK {
                    merged[merged.count - 1].text += trimmed
                    merged[merged.count - 1].end = max(merged[merged.count - 1].end, en)
                } else {
                    merged.append((trimmed, st, max(en, st + 0.05)))
                }
            }
            if !merged.isEmpty { lines.append(Line(words: merged)) }
        }
        // Drop credits/translations.
        var kept: [Line] = []
        for (i, l) in lines.enumerated() {
            let text = l.words.map(\.text).joined(separator: " ")
            if isCreditLine(text, position: i) { continue }
            kept.append(l)
        }
        guard kept.count >= 2 else { return nil }
        return build(lines: kept.map { $0.words }, tier: .wordLevel, source: "NetEase yrc")
    }

    private static func build(lines: [[(text: String, start: Double, end: Double)]], tier: LyricTier, source: String) -> TimedLyrics {
        var words: [TimedWord] = []
        var groups: [[TimedWord]] = []
        for (li, line) in lines.enumerated() {
            var g: [TimedWord] = []
            for w in line {
                let tw = TimedWord(id: words.count, text: w.text, start: w.start, end: w.end, line: li)
                words.append(tw); g.append(tw)
            }
            groups.append(g)
        }
        return TimedLyrics(tier: tier, words: words, groups: groups, source: source)
    }

    // MARK: - LRCLIB

    /// LRCLIB goes through EdgeGlow's shared client (same cache and request coalescing as Cloud Sync).
    private func lrclibLookup(title: String, artist: String, album: String, duration: Double, strict: Bool) async -> LRCLIBResult {
        await MediaMetadataService.lrclibSynced(title: title, artist: artist, album: album, duration: duration, strict: strict)
    }

    // MARK: - LRC parsing & syllable-weighted interpolation

    static func parseLRC(_ lrc: String) -> [(start: Double, text: String)] {
        let tsRe = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
        var rows: [(Double, String)] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            let ns = s as NSString
            let ms = tsRe.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                rows.append((mins * 60 + secs, text))
            }
        }
        rows.sort { $0.0 < $1.0 }
        // Duplicate timestamps are translations of the same line: keep the first.
        var out: [(Double, String)] = []
        for r in rows {
            if let l = out.last, abs(l.0 - r.0) < 0.001 { continue }
            out.append(r)
        }
        return out.map { (start: $0.0, text: $0.1) }
    }

    static func interpolate(lrc: String, trackDuration: Double, source: String) -> TimedLyrics? {
        interpolate(rows: parseLRC(lrc), trackDuration: trackDuration, source: source)
    }

    static func interpolate(rows: [(start: Double, text: String)], trackDuration: Double, source: String) -> TimedLyrics? {
        var lines: [[(text: String, start: Double, end: Double)]] = []
        var kept = 0
        for (i, row) in rows.enumerated() {
            let text = row.text
            if text.isEmpty { continue }
            if isCreditLine(text, position: kept) { continue }
            kept += 1
            let nextStart = i + 1 < rows.count ? rows[i + 1].start : (trackDuration > row.start ? trackDuration : row.start + 5)
            // A line is sung for roughly as long as its text suggests; a long gap after it is an
            // instrumental break, not a stretched last syllable.
            let tokenCount = Double(text.split(whereSeparator: \.isWhitespace).count)
            let letterCount = Double(text.filter { $0.isLetter || $0.isNumber }.count)
            let sungEstimate = max(2.0, 0.55 * tokenCount + 0.08 * letterCount)
            let lineEnd = min(nextStart, row.start + min(9, sungEstimate))
            let words = weightedWords(text: text, start: row.start, end: lineEnd)
            if !words.isEmpty { lines.append(words) }
        }
        guard lines.count >= 2 else { return nil }
        return build(lines: lines, tier: .interpolated, source: source)
    }

    /// Spreads a line's time budget across words by vowel/character weight, with breath pauses at punctuation.
    static func weightedWords(text: String, start: Double, end: Double) -> [(text: String, start: Double, end: Double)] {
        // Tokenise: whitespace-separated, and per-glyph for CJK runs.
        var tokens: [String] = []
        var current = ""
        for ch in text {
            let isCJK = ch.unicodeScalars.first.map(LyricText.isCJK) ?? false
            if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if isCJK {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return [] }

        let vowels = Set("aeiouyAEIOUYàáâäæãåāèéêëēėęîïíīįìôöòóœøōõûüùúūÿ")
        func weight(_ t: String) -> (sung: Double, pause: Double) {
            let letters = t.filter { $0.isLetter || $0.isNumber }
            let v = letters.filter { vowels.contains($0) }.count
            let isCJK = t.unicodeScalars.first.map(LyricText.isCJK) ?? false
            var w = isCJK ? 1.6 : (Double(max(1, v)) * 1.0 + Double(letters.count) * 0.22)
            if letters.isEmpty { w = 0.3 }
            var p = 0.0
            if let last = t.last {
                if ",;:–—".contains(last) { p = 0.7 }
                else if ".!?…。！？".contains(last) { p = 1.3 }
            }
            return (w, p)
        }
        let ws = tokens.map(weight)
        let tail = min(0.2, (end - start) * 0.06)     // breathing room before the next line
        let avail = max(0.2, end - start - tail)
        let total = ws.reduce(0) { $0 + $1.sung + $1.pause }
        let scale = avail / max(0.001, total)

        var out: [(String, Double, Double)] = []
        var cursor = start
        for (t, w) in zip(tokens, ws) {
            let dur = w.sung * scale
            out.append((t, cursor, cursor + dur))
            cursor += dur + w.pause * scale
        }
        return out
    }

    // MARK: - Disk cache (v4)

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return base.appendingPathComponent("com.jplane6.edgeglow/Lyrics/v4", isDirectory: true)
    }

    static func cacheKey(for t: TrackInfo) -> String {
        let clean = sanitize(title: t.title, artist: t.artist)
        let raw = "\(clean.artist.lowercased())|\(clean.title.lowercased())|\(Int(t.duration.rounded()))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func readCache(_ key: String) -> TimedLyrics? {
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TimedLyrics.self, from: d)
    }

    static func writeCache(_ l: TimedLyrics, key: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(l) {
            try? d.write(to: cacheDirectory.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }
}
