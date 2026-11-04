import AppKit
import Combine
import QuartzCore

// macOS edge of the media pipeline: reads now-playing info from players over AppleEvents and publishes
// it into AppState. Everything downstream (PlaybackClock, CloudSync, the renderer) is platform-neutral,
// so porting means replacing these providers (e.g. with MPRIS on Linux or SMTC on Windows).

/// One poll of one provider.
enum ProviderReading {
    /// A track is loaded; `polledAt` is the CACurrentMediaTime() the position was read at.
    case active(NowPlayingInfo, playing: Bool, polledAt: CFTimeInterval)
    case stopped
    /// The user denied EdgeGlow Automation access to this app.
    case denied
    case failed
}

/// A media app read with a small AppleScript that returns
/// `STATE|||title|||artist|||artworkURL|||position|||duration` (STATE = PLAYING, PAUSED or STOPPED).
final class AppleScriptProvider {
    let source: MediaSource
    /// Shown in the Automation permission banner.
    let appName: String
    let bundleID: String
    private let scriptSource: String
    /// Provider-specific cleanup; returning nil treats the reading as stopped.
    private let refine: (NowPlayingInfo) -> NowPlayingInfo?
    /// NSAppleScript is not thread-safe, so it is compiled and run only on the bridge's script queue.
    private var script: NSAppleScript?

    init(source: MediaSource, appName: String, bundleID: String, script: String, refine: @escaping (NowPlayingInfo) -> NowPlayingInfo? = { $0 }) {
        self.source = source
        self.appName = appName
        self.bundleID = bundleID
        scriptSource = script
        self.refine = refine
    }

    /// Checked before every poll so AppleEvents (and their permission prompts) only go to running apps.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Script queue only.
    func read() -> ProviderReading {
        if script == nil {
            script = NSAppleScript(source: scriptSource)
        }
        guard let script else { return .failed }
        var error: NSDictionary?
        let t0 = CACurrentMediaTime()
        let descriptor = script.executeAndReturnError(&error)
        let t1 = CACurrentMediaTime()
        // The player samples its position part-way through the round trip, so about 65% of the IPC time has
        // already elapsed by the time the answer is back. Spotify's scripted position also trails its mixer.
        let compensation = (t1 - t0) * 0.65 + (bundleID == "com.spotify.client" ? 0.155 : 0)
        let polledAt = t1
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            // -1743: errAEEventNotPermitted (user denied Automation access in System Settings).
            return code == -1743 ? .denied : .failed
        }

        var parts = (descriptor.stringValue ?? "STOPPED").components(separatedBy: "|||")
        guard parts[0] == "PLAYING" || parts[0] == "PAUSED" else { return .stopped }
        while parts.count < 6 { parts.append("") }
        // Numbers are coerced with the user's locale, so "12,5" is possible.
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
        let info = NowPlayingInfo(
            title: parts[1],
            artist: parts[2],
            artworkURL: parts[3].hasPrefix("http") ? parts[3] : nil,
            position: number(parts[4]).map { $0 + compensation },
            duration: number(parts[5]).flatMap { $0 > 0 ? $0 : nil }
        )
        guard let refined = refine(info) else { return .stopped }
        return .active(refined, playing: parts[0] == "PLAYING", polledAt: polledAt)
    }
}

extension AppleScriptProvider {
    static let spotify = AppleScriptProvider(source: .spotify, appName: "Spotify", bundleID: "com.spotify.client", script: """
    if application "Spotify" is running then
        tell application "Spotify"
            set ps to player state
            if ps is playing or ps is paused then
                set stateText to "PAUSED"
                if ps is playing then set stateText to "PLAYING"
                set t to current track
                set artURL to ""
                try
                    set artURL to (artwork url of t) as string
                end try
                set dur to ""
                try
                    set dur to ((duration of t) / 1000) as string
                end try
                return stateText & "|||" & (name of t) & "|||" & (artist of t) & "|||" & artURL & "|||" & (player position as string) & "|||" & dur
            end if
        end tell
    end if
    return "STOPPED"
    """)

    static let appleMusic = AppleScriptProvider(source: .appleMusic, appName: "Music", bundleID: "com.apple.Music", script: """
    if application id "com.apple.Music" is running then
        tell application id "com.apple.Music"
            set ps to player state
            if ps is playing or ps is paused then
                set stateText to "PAUSED"
                if ps is playing then set stateText to "PLAYING"
                try
                    set t to current track
                    set dur to ""
                    try
                        set dur to (duration of t) as string
                    end try
                    return stateText & "|||" & (name of t) & "|||" & (artist of t) & "||||||" & (player position as string) & "|||" & dur
                end try
            end if
        end tell
    end if
    return "STOPPED"
    """)

    /// Browsers that can host a music.youtube.com tab. Their tabs don't say whether they're playing, so
    /// the bridge only asks while system audio is actually flowing.
    static let youTubeMusicBrowsers: [AppleScriptProvider] = [
        ("Safari", "com.apple.Safari", "name"),
        ("Google Chrome", "com.google.Chrome", "title"),
        ("Arc", "company.thebrowser.Browser", "title"),
        ("Microsoft Edge", "com.microsoft.edgemac", "title"),
        ("Brave Browser", "com.brave.Browser", "title"),
    ].map { name, bundleID, titleProperty in
        // Chromium browsers: `execute <tab> javascript`; Safari: `do JavaScript … in <tab>`. Both need
        // "Allow JavaScript from Apple Events"; when it is off the calls fail and the bridge falls back to the
        // audio-gated stopwatch, so lyrics still work.
        func js(_ expr: String) -> String {
            titleProperty == "name"
                ? "do JavaScript \"\(expr)\" in t"
                : "execute t javascript \"\(expr)\""
        }
        let media = "(document.querySelector('video,audio')||{})"
        return AppleScriptProvider(source: .youTubeMusic, appName: name, bundleID: bundleID, script: """
        set hosts to {"music.youtube.com", "youtube.com/watch", "soundcloud.com", "jiosaavn.com", "gaana.com", "wynk", "spotify.com", "hungama.com", "music.apple.com", "bandcamp.com", "deezer.com", "tidal.com", "amazon.com/music", "music.amazon"}
        set fallback to ""
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t as string
                        set isMusic to false
                        repeat with h in hosts
                            if u contains (h as string) then set isMusic to true
                        end repeat
                        if isMusic then
                            set ct to ""
                            set du to ""
                            set paused to ""
                            try
                                set ct to (\(js("String(\(media).currentTime)"))) as string
                                set du to (\(js("String(\(media).duration)"))) as string
                                set paused to (\(js("String(\(media).paused)"))) as string
                            end try
                            if paused is not "true" then return "PLAYING|||" & (\(titleProperty) of t) & "||||||" & ct & "|||" & du
                            if fallback is "" then set fallback to "PAUSED|||" & (\(titleProperty) of t) & "||||||" & ct & "|||" & du
                        end if
                    end repeat
                end repeat
            end tell
        end if
        if fallback is not "" then return fallback
        return "STOPPED"
        """, refine: refineYouTubeMusicTitle)
    }

    /// Tab titles look like "(2) Song - YouTube Music"; the bare "YouTube Music" means nothing is loaded.
    private static func refineYouTubeMusicTitle(_ info: NowPlayingInfo) -> NowPlayingInfo? {
        var title = info.title.trimmingCharacters(in: .whitespaces)
        if let range = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { title.removeSubrange(range) }
        if title.hasSuffix(" - YouTube Music") { title = String(title.dropLast(" - YouTube Music".count)) }
        guard !title.isEmpty, title != "YouTube Music" else { return nil }
        for suffix in [" - YouTube", " | SoundCloud", " - SoundCloud"] where title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        var refined = info
        refined.title = title
        // Position survives only when the tab answered the JavaScript probe (NaN / empty means it did not).
        if let p = refined.position, !p.isFinite { refined.position = nil }
        if let d = refined.duration, !d.isFinite { refined.duration = nil }
        return refined
    }
}

/// Detects what's playing across providers, in priority order: Spotify, Apple Music, then any system
/// audio (named after a YouTube Music tab when there is one). Publishes the winner into AppState,
/// drives the PlaybackClock, and starts artwork and Cloud Sync lookups on track changes.
final class MediaBridge {
    private static let notifications = [
        Notification.Name("com.spotify.client.PlaybackStateChanged"),
        Notification.Name("com.apple.Music.playerInfo"),
    ]

    private let state: AppState
    private let scriptQueue = DispatchQueue(label: "com.jplane6.edgeglow.media", qos: .userInitiated)
    private let nativeProviders: [AppleScriptProvider] = [.spotify, .appleMusic]
    private let browserProviders = AppleScriptProvider.youTubeMusicBrowsers

    // Main-thread state.
    private var timer: Timer?
    private var pollInFlight = false
    private var pollQueued = false
    private var deniedApps = Set<String>()
    private var currentTrackKey = ""
    private var currentArtworkURL = ""
    private var artworkLookupKey = ""
    private var artworkTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
    }

    func start() {
        for name in Self.notifications {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(playerNotification(_:)), name: name, object: nil)
        }
        // System audio starting or stopping can change the active source (or reveal a YouTube Music tab).
        // receive(on:) defers past @Published's willSet so poll() sees the new value.
        state.$systemAudioActive
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.poll() }
            .store(in: &cancellables)
        // Standby stops all polling (no AppleEvents, no timers); leaving it resumes at once.
        state.$displayMode
            .map { $0 != .off }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] awake in self?.setPolling(awake) }
            .store(in: &cancellables)
    }

    private func setPolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        // Backup poll so we pick up a track that was already playing at launch and keep position fresh.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        cancellables.removeAll()
        timer?.invalidate()
        timer = nil
        artworkTask?.cancel()
        lookupTask?.cancel()
        cloudTask?.cancel()
    }

    @objc private func playerNotification(_ notification: Notification) {
        poll()
    }

    // MARK: Polling

    private func poll() {
        guard state.displayMode != .off else { return }
        guard !pollInFlight else {
            pollQueued = true
            return
        }
        let natives = nativeProviders.filter(\.isRunning)
        let browsers = state.systemAudioActive ? browserProviders.filter(\.isRunning) : []
        pollInFlight = true
        scriptQueue.async { [weak self] in
            var readings = natives.map { ($0, $0.read()) }
            let nativePlaying = readings.contains { reading in
                if case .active(_, true, _) = reading.1 { return true }
                return false
            }
            // A browser tab is only worth an AppleEvent when audio is flowing and no native player
            // accounts for it.
            if !nativePlaying {
                for browser in browsers {
                    let reading = browser.read()
                    readings.append((browser, reading))
                    if case .active = reading { break }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.apply(readings)
                if self.pollQueued {
                    self.pollQueued = false
                    self.poll()
                }
            }
        }
    }

    private func apply(_ readings: [(AppleScriptProvider, ProviderReading)]) {
        for (provider, reading) in readings {
            switch reading {
            case .denied: deniedApps.insert(provider.appName)
            case .active, .stopped: deniedApps.remove(provider.appName)
            case .failed: break
            }
        }
        setIfChanged(\.automationDeniedApps, deniedApps.sorted())

        func find(_ source: MediaSource, playing wanted: Bool) -> (NowPlayingInfo, CFTimeInterval)? {
            for (provider, reading) in readings where provider.source == source {
                if case let .active(info, playing, polledAt) = reading, playing == wanted { return (info, polledAt) }
            }
            return nil
        }

        // Priority: a playing native player, then live system audio, then a paused native player.
        var chosen: (source: MediaSource, info: NowPlayingInfo?, playing: Bool, polledAt: CFTimeInterval?)?
        if let (info, at) = find(.spotify, playing: true) {
            chosen = (.spotify, info, true, at)
        } else if let (info, at) = find(.appleMusic, playing: true) {
            chosen = (.appleMusic, info, true, at)
        } else if state.systemAudioActive {
            if let (info, _) = find(.youTubeMusic, playing: true) {
                chosen = (.youTubeMusic, info, true, nil)
            } else {
                chosen = (.systemAudio, nil, true, nil)
            }
        } else if let (info, at) = find(.spotify, playing: false) {
            chosen = (.spotify, info, false, at)
        } else if let (info, at) = find(.appleMusic, playing: false) {
            chosen = (.appleMusic, info, false, at)
        }

        let info = chosen?.info
        let playing = chosen?.playing ?? false
        setIfChanged(\.mediaSource, chosen?.source)
        setIfChanged(\.playback, chosen == nil ? .stopped : (playing ? .playing : .paused))
        setIfChanged(\.trackName, info?.title ?? "")
        setIfChanged(\.artistName, info?.artist ?? "")
        setIfChanged(\.trackDuration, info?.duration ?? 0)

        let key = chosen.map { "\($0.source.rawValue)\u{1F}\(info?.title ?? "")\u{1F}\(info?.artist ?? "")" } ?? ""
        let trackChanged = key != currentTrackKey
        if trackChanged {
            currentTrackKey = key
            trackDidChange(key: key, source: chosen?.source, info: info)
        }

        updateClock(source: chosen?.source, info: info, playing: playing, polledAt: chosen?.polledAt, trackChanged: trackChanged)

        // Stopped: keep the last artwork and colors on screen.
        guard let chosen else { return }
        updateArtwork(key: key, source: chosen.source, info: info)
    }

    /// Re-anchor on track change, resume, or noticeable drift; otherwise keep extrapolating so
    /// AppleScript latency jitter does not wobble the beat phase.
    private func updateClock(source: MediaSource?, info: NowPlayingInfo?, playing: Bool, polledAt: CFTimeInterval?, trackChanged: Bool) {
        let clock = state.playbackClock
        let hasPosition = source?.reportsPosition == true || (source == .youTubeMusic && info?.position != nil)
        if hasPosition, let position = info?.position, let polledAt {
            if playing {
                let drift = abs(clock.currentTrackTime(at: polledAt) - position)
                if trackChanged || !clock.isPlaying || drift > 0.25 {
                    clock.anchor(position: position, at: polledAt)
                }
                clock.setPlaying(true, at: polledAt)
            } else {
                clock.setPlaying(false)
                clock.anchor(position: position, at: polledAt)
            }
        } else if source == .youTubeMusic || source == .systemAudio {
            // No readable position (JavaScript from Apple Events is off, or an app that exposes nothing):
            // a stopwatch started at the track change that runs only while the Mac is audibly playing.
            let now = CACurrentMediaTime()
            if trackChanged { clock.anchor(position: 0, at: now) }
            clock.setPlaying(state.systemAudioActive, at: now)
        } else {
            clock.setPlaying(false)
        }
        state.cloudSync.setNativePlaybackActive(hasPosition && playing)
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if state[keyPath: keyPath] != value {
            state[keyPath: keyPath] = value
        }
    }

    // MARK: Cloud Sync metadata

    /// Tempo and synced lyrics are fetched for every native-player track up front, so Cloud Sync is
    /// ready the moment the Mac goes silent (Spotify Connect, AirPlay).
    private func trackDidChange(key: String, source: MediaSource?, info: NowPlayingInfo?) {
        cloudTask?.cancel()
        let cloudSync = state.cloudSync
        cloudSync.beginTrack(key)
        setIfChanged(\.trackBPM, nil)
        guard let source, source.reportsPosition, let info, !info.title.isEmpty else { return }
        cloudTask = Task {
            async let bpm = MediaMetadataService.bpm(title: info.title, artist: info.artist)
            async let lyrics = MediaMetadataService.syncedLyrics(title: info.title, artist: info.artist, duration: info.duration)
            let (tempo, lines) = await (bpm, lyrics)
            guard !Task.isCancelled else { return }
            cloudSync.update(key: key, bpm: tempo, lines: lines)
            await MainActor.run { [weak self] in
                // Shared with the lyrics rhythm engine, so Deezer is asked once per track.
                if let self, self.currentTrackKey == key { self.setIfChanged(\.trackBPM, tempo) }
            }
        }
    }

    // MARK: Artwork + colors

    private func updateArtwork(key: String, source: MediaSource, info: NowPlayingInfo?) {
        guard let info, !info.title.isEmpty else {
            // Plain system audio has no album: fall back to the default palette.
            showArtwork(nil)
            return
        }
        if let url = info.artworkURL {
            lookupTask?.cancel()
            artworkLookupKey = ""
            showArtwork(url)
            return
        }
        // Apple Music and YouTube Music don't expose an artwork URL, so look the cover up by name.
        guard key != artworkLookupKey else { return }
        artworkLookupKey = key
        lookupTask?.cancel()
        lookupTask = Task { [weak self] in
            let url = await MediaMetadataService.artworkURL(title: info.title, artist: info.artist)
            await MainActor.run { [self] in
                guard let self, !Task.isCancelled, self.artworkLookupKey == key else { return }
                self.showArtwork(url)
            }
        }
    }

    private func showArtwork(_ url: String?) {
        let urlString = url ?? ""
        guard urlString != currentArtworkURL else { return }
        currentArtworkURL = urlString
        artworkTask?.cancel()
        guard !urlString.isEmpty else {
            setIfChanged(\.artwork, nil)
            setIfChanged(\.extractedPrimary, .neonCyan)
            setIfChanged(\.extractedSecondary, .neonMagenta)
            return
        }
        artworkTask = Task { [weak self] in
            let image = await ColorExtractor.shared.image(for: urlString)
            let palette = image.flatMap { ColorExtractor.palette(from: $0) }
            await MainActor.run { [self] in
                guard let self, !Task.isCancelled, self.currentArtworkURL == urlString else { return }
                self.state.artwork = image
                guard image != nil else { return }
                // Grayscale covers have no usable hue, so fall back to the default neon pair.
                self.state.extractedPrimary = palette?.primary ?? .neonCyan
                self.state.extractedSecondary = palette?.secondary ?? .neonMagenta
            }
        }
    }
}
