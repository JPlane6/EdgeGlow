import Foundation

// Cloud Sync: when a track is playing on a remote speaker (Spotify Connect, AirPlay sent straight from
// the player) the Mac hears nothing, so the glow is driven by the track's tempo and synced lyrics
// instead. Foundation only: public web APIs plus pure math, no platform frameworks.

// MARK: - Lyrics

/// One sung lyric line with its estimated vocal cadence.
struct LyricLine: Equatable {
    let start: Double
    let end: Double
    /// Estimated syllables per second while the line is sung.
    let syllablesPerSecond: Double
    /// `syllablesPerSecond` mapped onto 0…1 (≈2 syl/s → 0, ≥6 syl/s → 1).
    let cadence: Double
}

enum LyricsParser {
    /// Parses LRC text (`[mm:ss.xx] line`, several timestamps per line allowed) into timed lines.
    /// Empty lines are kept only as end markers for the line before them.
    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(time: Double, text: String)] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            var rest = Substring(rawLine)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = timestamp(tag) { times.append(time) }
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, text)) }
        }
        entries.sort { $0.time < $1.time }

        var lines: [LyricLine] = []
        for (index, entry) in entries.enumerated() {
            let syllables = syllableCount(entry.text)
            guard syllables > 0 else { continue }
            let next = index + 1 < entries.count ? entries[index + 1].time : entry.time + 6
            // Back-to-back lines are sung across the whole gap; before an instrumental break assume a
            // typical ~3 syllables per second instead of stretching the line over the break.
            let gap = max(next - entry.time, 0.3)
            let duration = min(gap, max(1.2, Double(syllables) / 3))
            let rate = Double(syllables) / duration
            let cadence = min(max((rate - 2) / 4, 0), 1)
            lines.append(LyricLine(start: entry.time, end: entry.time + duration, syllablesPerSecond: rate, cadence: cadence))
        }
        return lines
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss:xx`; nil for metadata tags like `[ar:Artist]`.
    private static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        let seconds = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let value = Double(seconds) else { return nil }
        return minutes * 60 + value
    }

    private static let vowels = Set("aeiouyàáâãäåèéêëìíîïòóôõöùúûüýÿæœ")

    /// Vowel groups per Latin word; one per character for scripts without spaces between syllables (CJK).
    static func syllableCount(_ text: String) -> Int {
        var count = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            if word.contains(where: { $0.isASCII }) {
                var groups = 0
                var inVowel = false
                for character in word {
                    let isVowel = vowels.contains(character)
                    if isVowel && !inVowel { groups += 1 }
                    inVowel = isVowel
                }
                if groups > 1, word.hasSuffix("e"), !word.hasSuffix("le") { groups -= 1 }
                count += max(groups, 1)
            } else {
                count += word.count
            }
        }
        return count
    }
}

// MARK: - Metadata lookups

/// Public, keyless web APIs used to fill in what a player doesn't report.
enum MediaMetadataService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "EdgeGlow/1.0 (macOS ambient lighting app)"]
        return URLSession(configuration: config)
    }()

    /// 600×600 cover from the iTunes Search API, falling back to Deezer's large cover.
    static func artworkURL(title: String, artist: String) async -> String? {
        let term = "\(primaryArtist(artist)) \(cleanTitle(title))".trimmingCharacters(in: .whitespaces)
        if let response: ITunesSearch = await fetch("https://itunes.apple.com/search", ["term": term, "entity": "song", "limit": "1"]),
           let small = response.results.first?.artworkUrl100 {
            return small.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        }
        return await deezerTrack(title: title, artist: artist)?.album?.cover_xl
    }

    /// Tempo from Deezer's track details. Deezer reports 0 for tracks it hasn't analyzed.
    static func bpm(title: String, artist: String) async -> Double? {
        guard let id = await deezerTrack(title: title, artist: artist)?.id,
              let track: DeezerTrackDetail = await fetch("https://api.deezer.com/track/\(id)", [:]),
              let bpm = track.bpm, bpm > 40, bpm < 250 else { return nil }
        return bpm
    }

    /// Synced lyrics from LRCLIB: the exact-match endpoint first, then its search.
    static func syncedLyrics(title: String, artist: String, duration: Double?) async -> [LyricLine]? {
        let track = cleanTitle(title)
        let artistName = primaryArtist(artist)
        var query = ["track_name": track, "artist_name": artistName]
        if let duration, duration > 0 { query["duration"] = String(Int(duration.rounded())) }
        if let exact: LrclibRecord = await fetch("https://lrclib.net/api/get", query),
           let lines = exact.syncedLyrics.map(LyricsParser.parse), !lines.isEmpty {
            return lines
        }
        guard let results: [LrclibRecord] = await fetch("https://lrclib.net/api/search", ["track_name": track, "artist_name": artistName]) else { return nil }
        // Prefer the synced result whose length is closest to the playing track.
        let synced = results.filter { !($0.syncedLyrics ?? "").isEmpty }
        let best = synced.min { abs(($0.duration ?? 0) - (duration ?? 0)) < abs(($1.duration ?? 0) - (duration ?? 0)) }
        guard let text = best?.syncedLyrics else { return nil }
        let lines = LyricsParser.parse(text)
        return lines.isEmpty ? nil : lines
    }

    private static func deezerTrack(title: String, artist: String) async -> DeezerTrack? {
        let track = cleanTitle(title)
        let artistName = primaryArtist(artist)
        if let strict: DeezerSearch = await fetch("https://api.deezer.com/search", ["q": "artist:\"\(artistName)\" track:\"\(track)\""]),
           let first = strict.data.first {
            return first
        }
        let loose: DeezerSearch? = await fetch("https://api.deezer.com/search", ["q": "\(artistName) \(track)"])
        return loose?.data.first
    }

    private static func fetch<T: Decodable>(_ base: String, _ query: [String: String]) async -> T? {
        guard var components = URLComponents(string: base) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// Drops "- Remastered 2011", "(feat. X)" and similar decorations that break exact-match lookups.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        if let dash = result.range(of: " - ") { result = String(result[..<dash.lowerBound]) }
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = result.range(of: open), let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                let inner = result[start.upperBound..<end.lowerBound].lowercased()
                guard ["feat", "ft.", "with ", "remaster", "version", "edit"].contains(where: inner.contains) else { break }
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " x "]
        var result = artist
        for separator in separators {
            if let range = result.range(of: separator) { result = String(result[..<range.lowerBound]) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // Response shapes (only the fields EdgeGlow reads).
    private struct ITunesSearch: Decodable {
        struct Result: Decodable { let artworkUrl100: String? }
        let results: [Result]
    }
    private struct DeezerSearch: Decodable { let data: [DeezerTrack] }
    private struct DeezerTrack: Decodable {
        struct Album: Decodable { let cover_xl: String? }
        let id: Int
        let album: Album?
    }
    private struct DeezerTrackDetail: Decodable { let bpm: Double? }
    private struct LrclibRecord: Decodable {
        let syncedLyrics: String?
        let duration: Double?
    }
}

// MARK: - Synthesizer

/// Turns a track's tempo and lyric timing into bass/vocal energies shaped like the live FFT output,
/// so the renderer's pulse, transient detection, sparks and comet speed all behave the same.
final class CloudSyncEngine: @unchecked Sendable {
    static let defaultBPM = 122.0

    private let lock = NSLock()
    private var trackKey = ""
    private var bpm = CloudSyncEngine.defaultBPM
    private var lines: [LyricLine] = []
    private var nativePlaying = false
    private var vocalEnvelope = 0.08

    /// True while a native player (Spotify, Apple Music) reports playback with a usable position.
    var nativePlaybackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativePlaying
    }

    func setNativePlaybackActive(_ active: Bool) {
        lock.lock()
        nativePlaying = active
        lock.unlock()
    }

    /// Forgets the previous track's tempo and lyrics; lookups for `key` fill them back in.
    func beginTrack(_ key: String) {
        lock.lock()
        trackKey = key
        bpm = Self.defaultBPM
        lines = []
        lock.unlock()
    }

    /// Ignored when the track has already changed again.
    func update(key: String, bpm newBPM: Double? = nil, lines newLines: [LyricLine]? = nil) {
        lock.lock()
        if key == trackKey {
            if let newBPM { bpm = newBPM }
            if let newLines { lines = newLines }
        }
        lock.unlock()
    }

    /// Energies at `trackTime` seconds into the song; `dt` is the time since the previous call.
    func levels(at trackTime: Double, dt: Double) -> (bass: Double, vocal: Double) {
        lock.lock()
        defer { lock.unlock() }
        let beat = 60 / bpm
        let t = max(trackTime, 0)

        // Bass: a kick on every beat (accented downbeat), sharp 12 ms attack and ~130 ms decay, which
        // trips the renderer's transient detector just like a real kick does.
        let beatIndex = (t / beat).rounded(.down)
        let sinceBeat = t - beatIndex * beat
        let attack = 0.012
        let kick = sinceBeat < attack ? sinceBeat / attack : exp(-(sinceBeat - attack) / 0.13)
        let accent = Int(beatIndex) % 4 == 0 ? 1.0 : 0.82
        let bass = 0.06 + 0.94 * accent * kick

        // Vocals: the active line's cadence (slow ≈ 0.4, fast 0.85–1.0, with a slight syllable-rate
        // shimmer), easing down to 0.08 in the gaps. Without lyrics, swell over 4-bar phrases.
        let target: Double
        if lines.isEmpty {
            let phrase = 16 * beat
            let progress = t.truncatingRemainder(dividingBy: phrase) / phrase
            target = 0.3 + 0.4 * (0.5 - 0.5 * cos(2 * .pi * progress)) + 0.08 * kick
        } else if let line = activeLine(at: t) {
            let shimmer = 0.92 + 0.08 * sin(2 * .pi * line.syllablesPerSecond * (t - line.start))
            target = (0.4 + 0.6 * line.cadence) * shimmer
        } else {
            target = 0.08
        }
        let tau = target > vocalEnvelope ? 0.06 : 0.5
        vocalEnvelope += (target - vocalEnvelope) * (1 - exp(-max(dt, 0) / tau))
        return (bass, min(max(vocalEnvelope, 0), 1))
    }

    /// Binary search for the line being sung at `t`.
    private func activeLine(at t: Double) -> LyricLine? {
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= t { low = mid + 1 } else { high = mid - 1 }
        }
        guard high >= 0 else { return nil }
        let line = lines[high]
        return t < line.end ? line : nil
    }
}
