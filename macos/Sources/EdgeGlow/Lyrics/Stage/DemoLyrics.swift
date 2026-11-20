import Foundation

/// A built-in timed song for trying every style without a track playing (popover "Demo" pill or
/// `EdgeGlow --lyrics-demo`). The lines are chosen to hit icons, places, questions, hero words,
/// parentheticals and an instrumental gap.
enum DemoLyrics {
    static let title = "Golden Hour Drive"
    static let artist = "EdgeGlow Demo"

    static let lines: [(text: String, gapAfter: Double)] = [
        ("Driving fast across the Golden Gate", 0.8),
        ("My heart is on fire tonight", 0.7),
        ("Can you hear the music?", 0.9),
        ("Stars!", 0.6),
        ("We walk down Lombard Street in the rain", 0.8),
        ("(ooh, don't let go)", 1.0),
        ("Money in my pocket, party on the roof", 0.7),
        ("Call me when the moon is high", 4.5),
        ("Fly me to Paris, light up the world", 0.8),
        ("Time keeps running like a river", 0.7),
        ("Smile for the camera, say it loud", 0.9),
        ("Is this love?", 0.6),
        ("Brooklyn Bridge at midnight, the city never sleeps", 0.8),
        ("Sun on my face, swim in the ocean", 0.7),
        ("Broken but I'm still dancing", 0.9),
        ("Home!", 2.0),
    ]

    static let song: TimedLyrics = {
        var words: [TimedWord] = []
        var groups: [[TimedWord]] = []
        var t = 1.2
        for (li, line) in lines.enumerated() {
            var group: [TimedWord] = []
            let tokens = line.text.split(separator: " ").map(String.init)
            for (wi, token) in tokens.enumerated() {
                let letters = token.filter(\.isLetter).count
                let held = wi == tokens.count - 1 || token.hasSuffix("!") || token.hasSuffix("?")
                let duration = min(1.1, 0.2 + Double(letters) * 0.045 + (held ? 0.35 : 0))
                let w = TimedWord(id: words.count, text: token, start: t, end: t + duration, line: li)
                words.append(w)
                group.append(w)
                t += duration + 0.06
            }
            groups.append(group)
            t += line.gapAfter
        }
        return TimedLyrics(tier: .wordLevel, words: words, groups: groups, source: "demo")
    }()
}
