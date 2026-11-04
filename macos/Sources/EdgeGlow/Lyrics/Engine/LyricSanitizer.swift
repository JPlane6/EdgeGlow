import Foundation

/// Pure, platform-neutral metadata cleanup and lyric-ranking math (Foundation only), so the Windows port
/// can mirror it one to one. Indian streaming metadata is noisy: film credits in the title, several
/// artists in one field, record-label suffixes, YouTube decorations.
enum LyricSanitizer {
    private static let noise: [NSRegularExpression] = [
        #"[\[\(]\s*(from|theme from|music from)\s*[:\-]?\s*[“"'‘][^\]\)]*[\]\)]"#,
        #"\s[-–—]\s*from\s*[“"'‘].*$"#,
        #"[\[\(]\s*from\s+[^\]\)]*[\]\)]"#,
        #"[\[\(][^\]\)]*original motion picture soundtrack[^\]\)]*[\]\)]"#,
        #"[\[\(][^\]\)]*(official|lyrical|lyric|full|music|audio|video|visuali[sz]er|hd|4k|hq|mv)[^\]\)]*(video|audio|song|visuali[sz]er|version)?[^\]\)]*[\]\)]"#,
        #"[\[\(][^\]\)]*(slowed|reverb|lofi|lo-fi|flip|sped up|nightcore|8d|bass boosted)[^\]\)]*[\]\)]"#,
        #"\b(full\s+video|full\s+song|lyrical\s+video|official\s+video|official\s+audio)\b"#,
        #"\s[-–—|]\s*(t-series|sony music( india)?|yrf|zee music( company)?|saregama( music)?|tips( official| music)?|speed records|white hill music|times music|desi melodies|jio ?saavn|think music|lahari music|aditya music|eros now music|venus|universal music( india)?|warner music( india)?)\s*$"#,
        #"\s*\|\s.*$"#,
        #"\s*-\s*Topic$"#,
        #"\bVEVO\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func clean(_ s: String) -> String {
        var out = s
        for re in noise {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|").union(.whitespacesAndNewlines))
    }

    /// "Artist 1, Artist 2 & Composer feat. X" → "Artist 1".
    static func primaryArtist(_ artist: String) -> String {
        var a = clean(artist)
        for sep in [" feat.", " ft.", " featuring ", " & ", ", ", " x ", " × ", " with ", " and ", ";", "/", " , "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        return a.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitize(title: String, artist: String) -> (title: String, artist: String) {
        var t = title, a = artist
        let lowered = a.lowercased()
        if let range = t.range(of: " - "), a.isEmpty || lowered.contains("topic") || lowered.contains("vevo") || t.lowercased().hasPrefix(lowered + " - ") {
            a = String(t[..<range.lowerBound])
            t = String(t[range.upperBound...])
        }
        t = clean(t)
        return (t, primaryArtist(a))
    }

    // MARK: Ranking

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Jaccard similarity of word sets, 0…1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Candidate score for the LRCLIB search stage: title similarity dominates, duration proximity breaks ties.
    /// Returns nil when the duration is further than `tolerance` away.
    static func score(title: String, artist: String, candidateTitle: String, candidateArtist: String,
                      duration: Double, candidateDuration: Double, tolerance: Double = 8) -> Double? {
        if duration > 0, candidateDuration > 0, abs(duration - candidateDuration) > tolerance { return nil }
        let t = similarity(title, candidateTitle)
        guard t >= 0.34 else { return nil }
        let a = artist.isEmpty ? 0.5 : max(similarity(artist, candidateArtist), tokens(candidateArtist).isSuperset(of: tokens(artist)) ? 1 : 0)
        let d = duration > 0 && candidateDuration > 0 ? 1 - abs(duration - candidateDuration) / tolerance : 0.5
        return t * 3 + a * 1.5 + d
    }

    // MARK: Plain lyrics → LRC

    /// No synced lyrics exist: spread the plain lines across the song (after an intro, before an outro) in
    /// proportion to their length.
    static func spreadPlain(_ plain: String, duration: Double) -> String? {
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
        guard lines.count >= 4, duration > 20 else { return nil }
        let start = min(18, duration * 0.08), end = duration * 0.94
        let weights = lines.map { Double(max($0.count, 6)) }
        let total = weights.reduce(0, +)
        var t = start
        var rows: [String] = []
        for (line, w) in zip(lines, weights) {
            rows.append(String(format: "[%02d:%05.2f]%@", Int(t) / 60, t.truncatingRemainder(dividingBy: 60), line))
            t += (end - start) * w / total
        }
        return rows.joined(separator: "\n")
    }
}

/// Non-Latin scripts → readable Latin (Hinglish-style for Hindi/Punjabi/Urdu).
enum LyricRomanizer {
    static func needsRomanizing(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0900...0x0DFF).contains($0.value) || (0x0600...0x077F).contains($0.value) || (0x0E00...0x0E7F).contains($0.value) }
    }

    /// "पल पल दिल के पास" → "pala pala dila ke pasa" → light Hinglish cleanup of schwa-style endings.
    static func romanize(_ s: String) -> String {
        guard needsRomanizing(s) else { return s }
        guard let latin = s.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) else { return s }
        return latin.lowercased()
    }
}

/// ~170 Hindi / Punjabi / Urdu lyric words (romanized, with common spellings) → SF Symbol names.
enum HinglishLexicon {
    static let table: [String: String] = {
        var d: [String: String] = [:]
        func add(_ words: String, _ symbol: String) { for w in words.split(separator: " ") { d[String(w)] = symbol } }
        add("dil dilbar pyaar pyar ishq ishk mohabbat muhabbat mohabat prem jaan jaanu sanam sajna sajan mahi mahiya yaar yaara tera mera humdum", "heart.fill")
        add("dard judai bewafa bewafai toota tootna tanha tanhai", "bolt.heart.fill")
        add("aag agni jalna jalta jala shola sholay aatish", "flame.fill")
        add("raat raatein raaton chaand chand chaandni chandni taare taara sitare sitara tara", "moon.stars.fill")
        add("baarish barish barsaat sawan saawan aansu ansu aanson paani pani", "cloud.rain.fill")
        add("sapna sapne khwaab khwab khwaabon neend", "sparkles")
        add("gaadi gadi raftaar raftar safar rasta raaste raah", "car.fill")
        add("waqt vaqt pal lamha lamhe samay", "clock.fill")
        add("udna udna udaan aasman aasmaan hawa hawaa pawan", "wind")
        add("duniya jahaan jahan zamana zamaana jag", "globe")
        add("maut maut zindagi zindagee jeena jeevan", "bolt.heart.fill")
        add("suraj dhoop roshni roshan ujala noor", "sun.max.fill")
        add("phool phoolon gulab gulaab bahaar bahar", "leaf.fill")
        add("samundar sagar dariya darya nadi lehar lehron", "water.waves")
        add("sharaab sharab daaru peena nasha", "wineglass.fill")
        add("gaana gaane geet sur raag awaaz awaz dhun music", "music.note")
        add("aankhen ankhen nazar nazrein nigaah nain naina", "eye.fill")
        add("haath hath", "hand.raised.fill")
        add("ghar ghar makaan", "house.fill")
        add("paisa paise daulat", "indianrupeesign.circle.fill")
        add("jung jang ladai", "shield.fill")
        add("badal baadal megh", "cloud.fill")
        add("barf sardi thand", "snowflake")
        add("khushi hasna haseen muskaan muskurana", "face.smiling.fill")
        add("tauba tauba", "hand.raised.fill")
        add("rab khuda allah bhagwan ishwar dua duaa", "hands.sparkles.fill")
        add("chaabi taala", "key.fill")
        add("pairon paon payal ghungroo ghunghroo", "figure.walk")
        add("naach nachna dance", "figure.dance")
        add("tum", "person.fill")
        add("sabr intezaar intezar", "hourglass")
        return d
    }()

    static func symbol(for token: String) -> String? { table[token.lowercased()] }
}
