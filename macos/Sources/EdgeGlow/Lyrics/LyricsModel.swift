import Combine
import QuartzCore
import SwiftUI

/// The lyrics side of EdgeGlow. It owns no media detection of its own: it follows `AppState` (the track
/// MediaBridge detected, the shared PlaybackClock, the shared Deezer tempo, the shared artwork palette)
/// and turns it into timed lyrics, a beat model and a per-frame playhead for the lyric scenes.
@MainActor
final class LyricsModel: ObservableObject {
    private struct TrackKey: Equatable {
        var source: MediaSource?
        var title: String
        var artist: String
        var duration: Int
    }

    let state: AppState
    let rhythm = RhythmEngine()
    private let provider = LyricsProvider()

    @Published private(set) var lyrics: TimedLyrics?
    @Published private(set) var status = "Waiting for music…"

    private var bag = Set<AnyCancellable>()
    private var lyricsTask: Task<Void, Never>?
    private var currentKey: TrackKey?
    private var rawLyrics: TimedLyrics?
    private var rawTrack: TrackInfo?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        // Track identity from the shared media bridge. receive(on:) defers past @Published's willSet.
        Publishers.CombineLatest4(state.$mediaSource, state.$trackName, state.$artistName, state.$trackDuration)
            .combineLatest(state.$displayMode.map(\.lyricsOn).removeDuplicates())
            .debounce(for: .milliseconds(40), scheduler: DispatchQueue.main)
            .sink { [weak self] parts, lyricsOn in
                let (source, title, artist, duration) = parts
                let key = lyricsOn ? TrackKey(source: source, title: title, artist: artist, duration: Int(duration.rounded())) : nil
                self?.trackChanged(key)
            }
            .store(in: &bag)

        state.$lyricStyle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prepareIconsIfNeeded() }
            .store(in: &bag)

        state.$romanizeLyrics
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let raw = rawLyrics, let track = rawTrack else { return }
                apply(raw, track: track)
            }
            .store(in: &bag)

        // Deezer tempo, fetched once per track by the media bridge.
        state.$trackBPM
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bpm in self?.rhythm.adoptExternalBPM(bpm) }
            .store(in: &bag)
    }

    func stop() {
        bag.removeAll()
        trackChanged(nil)
    }

    // MARK: Pipeline

    private func trackChanged(_ key: TrackKey?) {
        guard key != currentKey else { return }
        currentKey = key
        lyricsTask?.cancel()
        clear()

        guard let key else {
            status = "Lyrics are off"
            return
        }
        guard let source = key.source, !key.title.isEmpty else {
            status = "Nothing playing"
            return
        }
        // Synced lyrics need a trustworthy track position, which only the native players report.
        guard let bundleID = Self.bundleID(for: source) else {
            status = "\(source.displayName) has no playback position, so lyrics can't sync"
            return
        }

        status = "Finding lyrics…"
        let track = TrackInfo(title: key.title, artist: key.artist, duration: Double(key.duration), sourceBundleID: bundleID)
        rhythm.configure(lyrics: nil, track: track)
        if let bpm = state.trackBPM { rhythm.adoptExternalBPM(bpm) }

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            // Transient failures (LRCLIB overloaded / offline) are retried quietly; nothing shows meanwhile.
            var result: TimedLyrics?
            for attempt in 0..<5 {
                let outcome = await provider.lyrics(for: track, kind: MediaSourcePolicy.classify(bundleID))
                if Task.isCancelled || currentKey != key { return }
                if case .found(let found) = outcome { result = found; break }
                guard case .retry = outcome else { break }
                try? await Task.sleep(nanoseconds: UInt64(10 + attempt * 10) * 1_000_000_000)
                if Task.isCancelled || currentKey != key { return }
            }
            if Task.isCancelled || currentKey != key { return }
            apply(result, track: track)
        }
    }

    private func apply(_ fetched: TimedLyrics?, track: TrackInfo) {
        rawLyrics = fetched; rawTrack = track
        var result = fetched
        if state.romanizeLyrics, let r = fetched { result = Self.romanized(r) }
        lyrics = result
        guard let result else {
            status = "No synced lyrics found"
            return
        }
        status = result.tier == .wordLevel ? "Word-level lyrics · \(result.source)" : "Synced lyrics · \(result.source)"
        prepareIconsIfNeeded()
        rhythm.configure(lyrics: result, track: track)
        if let bpm = state.trackBPM { rhythm.adoptExternalBPM(bpm) }
        state.vocalLock.setWordStarts(result.words.map(\.start).sorted())
    }

    /// SF Symbol and emoji matching loads a few megabytes of glyph data, so it only runs for the Visual styles.
    private func prepareIconsIfNeeded() {
        guard state.lyricStyle.showsIcons, let lyrics else { return }
        WordVisualResolver.shared.prepare(lyrics)
    }

    /// Devanagari / Gurmukhi / Arabic lines → Latin, word by word so timings are untouched.
    private static func romanized(_ l: TimedLyrics) -> TimedLyrics {
        guard l.words.contains(where: { LyricRomanizer.needsRomanizing($0.text) }) else { return l }
        var out = l
        out.words = l.words.map { var w = $0; w.text = LyricRomanizer.romanize(w.text); return w }
        out.groups = l.groups.map { $0.map { var w = $0; w.text = LyricRomanizer.romanize(w.text); return w } }
        return out
    }

    private func clear() {
        rawLyrics = nil; rawTrack = nil
        lyrics = nil
        rhythm.configure(lyrics: nil, track: nil)
        state.vocalLock.setWordStarts([])
    }

    private static func bundleID(for source: MediaSource) -> String? {
        switch source {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        case .youTubeMusic: return "com.google.Chrome"   // browser tab: LRCLIB must confirm it is a song
        case .systemAudio: return nil
        }
    }

    // MARK: Playhead

    /// Where the listener is in the song right now, in seconds.
    ///
    /// `CACurrentMediaTime()` is monotonic and sub-microsecond, so the clock is exact between media
    /// updates: the last known player position plus the time elapsed since it was read. From that:
    /// - minus the output route's measured latency (`AudioLatencyDetector`), so lyrics follow the sound
    ///   reaching the ears rather than the player's decode position;
    /// - plus the small trim `VocalOnsetLock` has learned by matching real vocal attacks (300 Hz–3.4 kHz
    ///   energy in the audio FFT) against the lyric word starts.
    func playhead(at now: Double = CACurrentMediaTime()) -> Double {
        let position = state.playbackClock.currentTrackTime(at: now)
        return max(0, position - state.audioLatency.value + state.vocalLock.correction(at: now))
    }

    // MARK: Theme

    /// Lyric colors follow EdgeGlow's palette, so the text and the rim always agree (including custom colors).
    var theme: LyricTheme {
        LyricTheme(
            font: state.lyricFont,
            text: .white,
            highlight: state.targetPrimary.color,
            secondary: state.targetSecondary.color,
            scale: state.lyricTextScale,
            meshColors: [])
    }
}
