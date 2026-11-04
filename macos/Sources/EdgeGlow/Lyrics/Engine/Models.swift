import Foundation

// MARK: - Lyrics model

struct TimedWord: Codable, Hashable, Sendable, Identifiable {
    var id: Int          // global index across the song
    var text: String
    var start: Double    // seconds
    var end: Double
    var line: Int
    var duration: Double { max(0, end - start) }
}

enum LyricTier: String, Codable, Sendable {
    case wordLevel      // true word timings (NetEase yrc)
    case interpolated   // line-level LRC expanded with syllable weighting
}

struct TimedLyrics: Codable, Sendable {
    var tier: LyricTier
    var words: [TimedWord]
    var groups: [[TimedWord]]
    var source: String = ""

    var isEmpty: Bool { groups.isEmpty }
    var firstOnset: Double { words.first?.start ?? 0 }
    var lastEnd: Double { words.last?.end ?? 0 }

    func lineText(_ index: Int) -> String {
        guard groups.indices.contains(index) else { return "" }
        return LyricText.join(groups[index].map(\.text))
    }

    /// Which line should be on screen at `pos`.
    func cursor(at pos: Double) -> LineCursor {
        guard !groups.isEmpty else { return LineCursor(index: nil, next: nil) }
        var lo = 0, hi = groups.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if (groups[mid].first?.start ?? .infinity) - 0.35 <= pos { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return LineCursor(index: nil, next: 0) }
        let next: Int? = found + 1 < groups.count ? found + 1 : nil
        let end = groups[found].last?.end ?? 0
        if pos > end + 2.5 { return LineCursor(index: nil, next: next) }
        return LineCursor(index: found, next: next)
    }
}

struct LineCursor: Sendable {
    var index: Int?
    var next: Int?
}

enum LyricText {
    /// Joins word strings with spaces, except between adjacent CJK glyphs.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts {
            if let last = out.unicodeScalars.last, let first = p.unicodeScalars.first,
               isCJK(last), isCJK(first) {
                out += p
            } else if out.isEmpty {
                out = p
            } else {
                out += " " + p
            }
        }
        return out
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F:
            return true
        default:
            return false
        }
    }

    static func containsNonLatin(_ s: String) -> Bool {
        for u in s.unicodeScalars where u.value > 0x024F && u.properties.isAlphabetic { return true }
        return false
    }
}

// MARK: - Track

struct TrackInfo: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String = ""
    var duration: Double = 0
    var artwork: Data? = nil
    var sourceBundleID: String? = nil

    var key: String { "\(artist.lowercased())|\(title.lowercased())|\(Int(duration.rounded()))" }
    /// Song identity plus the app playing it (a different source may be validated differently).
    var sessionKey: String { key + "@" + (sourceBundleID ?? "") }

    static func == (l: TrackInfo, r: TrackInfo) -> Bool {
        l.title == r.title && l.artist == r.artist && l.album == r.album && l.sourceBundleID == r.sourceBundleID &&
        abs(l.duration - r.duration) < 0.5 && l.artwork?.count == r.artwork?.count
    }
}

// MARK: - Visual

enum WordVisual: Equatable, Hashable, Sendable {
    case symbol(String)
    case emoji(String)
}
