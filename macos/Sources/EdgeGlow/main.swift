import AppKit

if CommandLine.arguments.contains("--test-lyrics") {
    // Debug: fetch + romanize lyrics for a few Hindi / Punjabi tracks and exit.
    let cases: [(String, String)] = [("Pal Pal", "Afusic"), ("Tauba Tauba", "Karan Aujla"), ("Tum Hi Ho", "Arijit Singh"),
                                      ("Kesariya (From \"Brahmastra\") [Official Video]", "Arijit Singh, Pritam, Amitabh Bhattacharya - T-Series")]
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let provider = LyricsProvider()
        for (title, artist) in cases {
            let clean = LyricSanitizer.sanitize(title: title, artist: artist)
            let outcome = await provider.lyrics(for: TrackInfo(title: title, artist: artist, duration: 0, sourceBundleID: "com.spotify.client"), kind: .musicApp)
            switch outcome {
            case .found(let l):
                let lines = (0..<min(3, l.groups.count)).map { LyricRomanizer.romanize(l.lineText($0)) }
                print("OK   \"\(title)\" -> \"\(clean.title)\" / \"\(clean.artist)\" [\(l.source), \(l.groups.count) lines]\n     " + lines.joined(separator: " | "))
            case .none: print("NONE \"\(title)\" -> \"\(clean.title)\" / \"\(clean.artist)\"")
            case .retry: print("RETRY \"\(title)\" (network)")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--render-style-previews") {
    // Debug: render every lyric style to PNG files and exit.
    let directory = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "styles"
    MainActor.assumeIsolated { StylePreviews.run(outputDir: directory) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
