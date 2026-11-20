import Foundation
import QuartzCore

/// What the Orbital style needs beyond the shared `LyricFrame`.
struct OrbitalInput {
    /// Smoothed spectrum for this frame; nil renders the procedural wave (previews).
    var audio: OrbitalAudio?
    /// Show the bottom-left Now Playing pill.
    var showTrackInfo = false
}

/// One frame of equalizer input: `bands` run low → high (0…1 each), `bass` drives the disc pulse.
struct OrbitalAudio {
    var bands: [Double]
    var bass: Double
    /// 0 = fully procedural, 1 = fully live FFT (cross-faded so a switch never pops).
    var live: Double

    static let bandCount = AudioLevels.spectrumBands

    /// Beat-synced stand-in used when system audio isn't captured (Cloud Sync, permission off, demo):
    /// a kick envelope on every beat of the track's tempo, plus slow ripples so the ring never sits still.
    static func procedural(position: Double, clock: Double, bpm: Double?) -> OrbitalAudio {
        let tempo = min(max(bpm ?? 96, 60), 180)
        let beats = max(0, position) * tempo / 60
        let beat = Int(beats.rounded(.down))
        let phase = beats - Double(beat)
        let kick = exp(-phase * 5.5) * (beat % 4 == 0 ? 1 : 0.78)
        let offbeat = exp(-abs(phase - 0.5) * 9) * 0.35
        var bands = [Double](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let x = Double(i) / Double(bandCount - 1)
            let ripple = 0.13 + 0.10 * (0.5 + 0.5 * sin(clock * 1.7 + x * 9.0)) + 0.07 * (0.5 + 0.5 * sin(clock * 0.83 - x * 5.3))
            let low = kick * (0.62 * pow(1 - x, 1.6) + 0.12) * (0.75 + 0.25 * Motion.hash(beat, i))
            let high = offbeat * pow(x, 1.2) * (0.6 + 0.4 * Motion.hash(beat, i + 97))
            bands[i] = min(1, ripple + low + high)
        }
        return OrbitalAudio(bands: bands, bass: 0.12 + 0.78 * kick, live: 0)
    }
}

/// Per-band attack/decay smoothing for the Orbital ring, shared by every display's stage. Smoothing is
/// time-based (the spec's per-frame factors are defined at 60 fps), so two displays sampling the same
/// follower each advance it by their own elapsed time, and a second call within the same instant is free.
final class OrbitalAudioFollower: @unchecked Sendable {
    static let shared = OrbitalAudioFollower()

    /// Per-frame lerp factors at 60 fps.
    private static let bandAttack = 0.45, bandDecay = 0.15
    private static let bassAttack = 0.35, bassRelease = 0.12
    /// A spectrum older than this counts as stale (capture stopped or paused).
    private static let staleAfter: CFTimeInterval = 0.3

    private let lock = NSLock()
    private var lastDate: Date?
    private var bands = [Double](repeating: 0, count: OrbitalAudio.bandCount)
    private var bass = 0.0
    private var live = 0.0

    func sample(date: Date, levels: AudioLevels, live liveSource: Bool, position: Double, clock: Double, bpm: Double?) -> OrbitalAudio {
        lock.lock()
        defer { lock.unlock() }
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 1.0 / 15.0) } ?? (1.0 / 60.0)
        if let last = lastDate, abs(date.timeIntervalSince(last)) < 0.0005 {
            return OrbitalAudio(bands: bands, bass: bass, live: live)
        }
        lastDate = date

        let spectrum = levels.spectrum()
        let fresh = liveSource && spectrum.time > 0 && CACurrentMediaTime() - spectrum.time < Self.staleAfter
            && spectrum.bands.count == OrbitalAudio.bandCount
        live += ((fresh ? 1.0 : 0.0) - live) * (1 - exp(-dt * 4))

        let fallback = OrbitalAudio.procedural(position: position, clock: clock, bpm: bpm)
        let liveBass = levels.snapshot().bass
        let frames = dt * 60
        func step(_ current: Double, _ target: Double, attack: Double, release: Double) -> Double {
            let k = 1 - pow(1 - (target > current ? attack : release), frames)
            return current + (target - current) * k
        }
        for i in bands.indices {
            let measured = fresh ? Double(spectrum.bands[i]) : 0
            let target = measured * live + fallback.bands[i] * (1 - live)
            bands[i] = step(bands[i], target, attack: Self.bandAttack, release: Self.bandDecay)
        }
        let bassTarget = (fresh ? liveBass : 0) * live + fallback.bass * (1 - live)
        bass = step(bass, bassTarget, attack: Self.bassAttack, release: Self.bassRelease)
        return OrbitalAudio(bands: bands, bass: bass, live: live)
    }
}
