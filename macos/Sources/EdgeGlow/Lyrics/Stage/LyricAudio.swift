import Foundation
import QuartzCore

/// One frame of music dynamics for the lyric styles. `bands` and `bandFlux` run low → high (0…1 each);
/// the scalars are 0…1. Every style reads `bass`, `kick` and `energy`; Orbital also draws the spectrum.
struct LyricAudio {
    var bands: [Double]
    /// Positive per-band change (fresh transients) for spiky peaks.
    var bandFlux: [Double]
    var bass: Double
    /// Beat impulse: snaps to ~1 on a kick / drop and falls back within ~0.15 s.
    var kick: Double
    var energy: Double
    /// Broadband transient flux (snares, vocal attacks).
    var flux: Double
    /// 0 = fully procedural, 1 = fully live FFT (cross-faded so a switch never pops).
    var live: Double

    static let bandCount = AudioLevels.spectrumBands

    /// Beat-timed stand-in used when system audio isn't captured (permission off, nothing captured, Demo,
    /// previews): a sharp kick on every beat, snares on 2 and 4, hats on the eighths, and a stepped jitter
    /// floor, so the styles jump on a grid instead of breathing on a sine.
    static func procedural(position: Double, clock: Double, bpm: Double?) -> LyricAudio {
        let tempo = min(max(bpm ?? 100, 60), 180)
        let beats = max(0, position) * tempo / 60
        let beat = Int(beats.rounded(.down))
        let phase = beats - Double(beat)
        let eighths = beats * 2
        let eighth = Int(eighths.rounded(.down))
        let eighthPhase = eighths - Double(eighth)

        let kick = exp(-phase * 9) * (beat % 4 == 0 ? 1 : 0.82)
        let snare = beat % 2 == 1 ? exp(-phase * 12) * 0.85 : 0
        let hat = exp(-eighthPhase * 16) * 0.55
        let fresh = exp(-phase * 28)
        let jitterStep = Int((clock * 12).rounded(.down))

        var bands = [Double](repeating: 0, count: bandCount)
        var flux = [Double](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let x = Double(i) / Double(bandCount - 1)
            let low = kick * pow(1 - x, 2.2) * (0.85 + 0.15 * Motion.hash(beat, i))
            let mid = snare * exp(-pow((x - 0.45) / 0.18, 2)) * (0.7 + 0.3 * Motion.hash(beat, i + 61))
            let high = hat * pow(x, 1.5) * (0.5 + 0.5 * Motion.hash(eighth, i + 131))
            let floor = 0.07 + 0.11 * Motion.hash(jitterStep, i + 7)
            bands[i] = min(1, floor + 0.95 * low + 0.8 * mid + 0.7 * high)
            flux[i] = min(1, fresh * (low + 0.8 * mid) + exp(-eighthPhase * 30) * high * 0.6)
        }
        return LyricAudio(bands: bands, bandFlux: flux, bass: 0.1 + 0.85 * kick, kick: kick,
                          energy: min(1, 0.3 + 0.45 * kick + 0.25 * snare + 0.1 * hat),
                          flux: min(1, fresh * 0.9 + snare * 0.4), live: 0)
    }
}

/// Frame-rate smoothing of the engine's metrics for the lyric stage, shared by every display's stage.
/// Smoothing is time-based (the per-frame factors are defined at 60 fps), so two displays sampling the
/// same follower each advance it by their own elapsed time, and a second call in the same instant is free.
final class LyricAudioFollower: @unchecked Sendable {
    static let shared = LyricAudioFollower()

    /// Per-frame lerp factors at 60 fps: near-instant attack, snappy whip decay.
    private static let bandAttack = 0.88, bandDecay = 0.30
    private static let fluxDecay = 0.35
    private static let bassAttack = 0.78, bassRelease = 0.24
    private static let kickAttack = 0.90, kickRelease = 0.22
    private static let energyAttack = 0.75, energyRelease = 0.20
    /// Engine data older than this counts as stale (capture stopped or paused).
    private static let staleAfter: CFTimeInterval = 0.3

    private let lock = NSLock()
    private var lastDate: Date?
    private var last = LyricAudio(bands: [Double](repeating: 0, count: LyricAudio.bandCount),
                                  bandFlux: [Double](repeating: 0, count: LyricAudio.bandCount),
                                  bass: 0, kick: 0, energy: 0, flux: 0, live: 0)
    /// How much the scalars (bass/kick/energy) and the spectrum come from the engine.
    private var scalarMix = 0.0
    private var spectrumMix = 0.0

    /// - Parameters:
    ///   - source: what feeds `levels` (live FFT, Cloud Sync's synthesized levels, or nothing).
    func sample(date: Date, levels: AudioLevels, source: LevelSource, position: Double, clock: Double, bpm: Double?) -> LyricAudio {
        lock.lock()
        defer { lock.unlock() }
        if let prev = lastDate, abs(date.timeIntervalSince(prev)) < 0.0005 { return last }
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 1.0 / 15.0) } ?? (1.0 / 60.0)
        lastDate = date
        let now = CACurrentMediaTime()

        let pulse = levels.pulse()
        let spectrum = levels.spectrum()
        let scalarsFresh = source != .none && pulse.time > 0 && now - pulse.time < Self.staleAfter
        let spectrumFresh = source == .live && spectrum.time > 0 && now - spectrum.time < Self.staleAfter
            && spectrum.bands.count == LyricAudio.bandCount
        scalarMix += ((scalarsFresh ? 1.0 : 0.0) - scalarMix) * (1 - exp(-dt * 6))
        spectrumMix += ((spectrumFresh ? 1.0 : 0.0) - spectrumMix) * (1 - exp(-dt * 6))

        let fallback = LyricAudio.procedural(position: position, clock: clock, bpm: bpm)
        let frames = dt * 60
        func step(_ current: Double, _ target: Double, _ attack: Double, _ release: Double) -> Double {
            let k = 1 - pow(1 - (target > current ? attack : release), frames)
            return current + (target - current) * k
        }
        func mix(_ engine: Double, _ procedural: Double, _ m: Double) -> Double { engine * m + procedural * (1 - m) }

        var out = last
        for i in 0..<LyricAudio.bandCount {
            let band = spectrumFresh ? Double(spectrum.bands[i]) : 0
            let flux = spectrumFresh ? Double(spectrum.flux[i]) : 0
            out.bands[i] = step(last.bands[i], mix(band, fallback.bands[i], spectrumMix), Self.bandAttack, Self.bandDecay)
            out.bandFlux[i] = step(last.bandFlux[i], mix(flux, fallback.bandFlux[i], spectrumMix), 1, Self.fluxDecay)
        }
        let engineOn = scalarsFresh ? 1.0 : 0.0
        out.bass = step(last.bass, mix(pulse.bass * engineOn, fallback.bass, scalarMix), Self.bassAttack, Self.bassRelease)
        out.kick = step(last.kick, mix(pulse.kick * engineOn, fallback.kick, scalarMix), Self.kickAttack, Self.kickRelease)
        out.energy = step(last.energy, mix(pulse.energy * engineOn, fallback.energy, scalarMix), Self.energyAttack, Self.energyRelease)
        out.flux = step(last.flux, mix(pulse.flux * engineOn, fallback.flux, scalarMix), 1, Self.fluxDecay)
        out.live = spectrumMix
        last = out
        return out
    }
}
