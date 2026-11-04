import Foundation

/// How much we trust a now-playing source to be music.
enum MediaSourceKind: Sendable {
    case musicApp      // dedicated music player: lyrics are looked up directly
    case podcast       // never shown
    case validated     // browsers, VLC, IINA, unknown clients: shown only if LRCLIB confirms lyrics
}

enum MediaSourcePolicy {
    /// Layer 1 — dedicated music apps bypass strict filtering.
    static let musicApps: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.apple.iTunes",
        "com.tidal.desktop", "com.deezer.deezer-desktop", "com.amazon.music",
        "com.github.th-ch.youtube-music", "com.qobuz.QobuzApp", "tv.plex.plexamp",
        "com.coppertino.Vox", "com.cider-collective.cider", "com.swinsian.Swinsian",
        "com.decibel.app", "org.nickvision.tubeconverter.music", "com.roon.Roon", "com.audirvana.Audirvana-Plus",
    ]

    static let podcastApps: Set<String> = [
        "com.apple.podcasts", "fm.overcast.overcast", "au.com.shiftyjelly.podcasts",
        "com.spotify.podcasts", "com.pocketcasts.macos", "co.castro.castro", "com.apple.Audiobooks", "com.apple.iBooks",
    ]

    /// Browsers (and WebKit/Chromium helper processes) can't tell YouTube Music from YouTube.
    static let browserPrefixes: [String] = [
        "com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.nightly", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "app.zen-browser.zen",
        "com.duckduckgo.macos.browser", "net.imput.helium", "com.kagi.kagimacOS",
    ]

    /// Anything longer than this from a non-music-app source is a video/podcast, not a song.
    static let maxValidatedDuration: Double = 12 * 60

    static func normalize(_ id: String?) -> String? {
        guard var s = id, !s.isEmpty else { return nil }
        // Chromium helper processes report e.g. "com.google.Chrome.helper.Renderer".
        if let r = s.range(of: ".helper") { s = String(s[..<r.lowerBound]) }
        return s
    }

    static func classify(_ rawID: String?) -> MediaSourceKind {
        guard let id = normalize(rawID) else { return .validated }
        if musicApps.contains(id) { return .musicApp }
        if podcastApps.contains(id) { return .podcast }
        return .validated   // browsers and everything else go through the LRCLIB validator
    }

    static func isBrowser(_ rawID: String?) -> Bool {
        guard let id = normalize(rawID) else { return false }
        return browserPrefixes.contains { id.hasPrefix($0) }
    }
}
