import AppKit

/// Watches Spotify over AppleEvents and publishes playback state and artwork colors into AppState.
final class SpotifyBridge {
    private static let bundleID = "com.spotify.client"
    private static let playbackNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private static let scriptSource = """
    if application "Spotify" is running then
        tell application "Spotify"
            set artURL to ""
            try
                set artURL to (artwork url of current track) as string
            end try
            if player state is playing then
                return "PLAYING|||" & (name of current track) & "|||" & (artist of current track) & "|||" & artURL & "|||" & (player position as string)
            else if player state is paused then
                return "PAUSED|||" & (name of current track) & "|||" & (artist of current track) & "|||" & artURL & "|||0"
            end if
        end tell
    end if
    return "STOPPED"
    """

    private enum ScriptResult {
        case output(String)
        case denied
        case failed
    }

    private let state: AppState
    /// NSAppleScript is not thread-safe, so the compiled script lives on (and only runs on) this queue.
    private let scriptQueue = DispatchQueue(label: "com.jplane6.edgeglow.spotify", qos: .userInitiated)
    private var script: NSAppleScript?

    // Main-thread state.
    private var timer: Timer?
    private var pollInFlight = false
    private var currentTrackKey = ""
    private var currentArtworkURL = ""
    private var artworkTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Self.playbackNotification,
            object: nil
        )
        // Backup poll so we pick up a track that was already playing at launch and keep position fresh.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        timer?.invalidate()
        timer = nil
        artworkTask?.cancel()
    }

    @objc private func playbackStateChanged(_ notification: Notification) {
        poll()
    }

    // MARK: Polling

    private func poll() {
        // Skip the AppleScript entirely while Spotify is closed; this also defers the TCC prompt
        // until there is actually something to sync with.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            handle(.output("STOPPED"), spotifyRunning: false)
            return
        }
        guard !pollInFlight else { return }
        pollInFlight = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runScript()
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.handle(result, spotifyRunning: true)
            }
        }
    }

    private func runScript() -> ScriptResult {
        if script == nil {
            script = NSAppleScript(source: Self.scriptSource)
        }
        guard let script else { return .failed }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            // -1743: errAEEventNotPermitted (user denied Automation access in System Settings).
            return code == -1743 ? .denied : .failed
        }
        return .output(descriptor.stringValue ?? "STOPPED")
    }

    private func handle(_ result: ScriptResult, spotifyRunning: Bool) {
        setIfChanged(\.spotifyRunning, spotifyRunning)

        switch result {
        case .denied:
            setIfChanged(\.automationDenied, true)
            setIfChanged(\.playback, .stopped)
            return
        case .failed:
            return
        case .output(let output):
            setIfChanged(\.automationDenied, false)
            apply(output: output)
        }
    }

    private func apply(output: String) {
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 5, parts[0] == "PLAYING" || parts[0] == "PAUSED" else {
            setIfChanged(\.playback, .stopped)
            return
        }

        let playing = parts[0] == "PLAYING"
        let name = parts[1]
        let artist = parts[2]
        let artworkURL = parts[3].hasPrefix("http") ? parts[3] : ""
        // `player position as string` follows the user's locale, so "12,5" is possible.
        let position = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0

        let key = name + "\u{1F}" + artist
        let trackChanged = key != currentTrackKey
        let wasPlaying = state.isPlaying

        setIfChanged(\.playback, playing ? .playing : .paused)
        setIfChanged(\.trackName, name)
        setIfChanged(\.artistName, artist)

        if trackChanged {
            currentTrackKey = key
        }

        if playing {
            // Re-anchor on track change, resume, or noticeable drift; otherwise keep extrapolating so
            // AppleScript latency jitter does not wobble the beat phase.
            let now = Date()
            let drift = abs(state.playbackPosition(at: now) - position)
            if trackChanged || !wasPlaying || drift > 0.25 {
                state.positionAnchor = position
                state.anchorDate = now
            }
        }

        if artworkURL != currentArtworkURL {
            currentArtworkURL = artworkURL
            loadArtwork(artworkURL)
        }
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if state[keyPath: keyPath] != value {
            state[keyPath: keyPath] = value
        }
    }

    // MARK: Artwork + colors

    private func loadArtwork(_ urlString: String) {
        artworkTask?.cancel()
        guard !urlString.isEmpty else {
            state.artwork = nil
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
