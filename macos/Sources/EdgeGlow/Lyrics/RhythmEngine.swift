import Foundation

/// App-layer wrapper: publishes tempo info.
/// All of the actual math lives in the platform-agnostic `RhythmCore`.
@MainActor
final class RhythmEngine: ObservableObject {
    @Published private(set) var bpm: Double = 0
    @Published private(set) var bpmSource: String = "none"

    private let core = RhythmCore()

    /// Tempo comes from the shared Deezer lookup in MediaBridge (`AppState.trackBPM`) via `adoptExternalBPM`;
    /// until it lands, the tempo is inferred from the lyric cadence.
    func configure(lyrics: TimedLyrics?, track: TrackInfo?) {
        core.load(words: lyrics?.words ?? [], trackDuration: track?.duration ?? 0)
        bpm = 0; bpmSource = "none"

        if core.inferTempoFromCadence() { bpm = core.bpm; bpmSource = "cadence" }   // Tier 3 immediately
    }

    func adoptExternalBPM(_ value: Double) {
        guard bpm == 0 || bpmSource == "cadence", value > 40, value < 220 else { return }
        apply(value, source: "deezer")
    }

    private func apply(_ value: Double, source: String) {
        core.lockTempo(bpm: value)       // Tier 2: phase-locked to the first vocal onset
        bpm = core.bpm; bpmSource = source
    }

    func state(at pos: Double) -> BeatState { core.state(at: pos) }
}
