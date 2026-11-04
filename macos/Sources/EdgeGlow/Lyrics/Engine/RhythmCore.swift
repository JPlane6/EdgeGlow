import Foundation

/// Per-frame output of the Zero-Mic Rhythm Engine.
struct BeatState: Equatable, Sendable {
    var bpm: Double = 0
    var beatPhase: Double = 0          // 0…1 within the current beat
    var beatPulse: Double = 0          // 1 on the beat, decays exponentially
    var beatIndex: Int = 0             // monotonically increasing beat counter (event trigger for renderers)
    var vocalEnergy: Double = 0        // 0…1 smoothed cadence
    var isInstrumentalBreak: Bool = false
    var wordsPerSecond: Double = 0
    var sustain: Double = 0            // 0…1 swell while a long note (>700 ms) is held
    /// Onset velocity 0…1: spikes on each vocal onset, scaled by how fast the syllables are arriving.
    var velocity: Double = 0
    var onsetAge: Double = 99          // seconds since the most recent vocal onset
    var syllableDelta: Double = 0.5    // seconds between the last two onsets

    static let idle = BeatState()
}

/// Pure tempo / cadence math. No UI, no networking, no platform types.
///  Tier 1: vocal cadence & syllable velocity from word timestamps
///  Tier 2: externally supplied BPM, phase-locked to the first vocal onset
///  Tier 3: onset-interval clustering when no BPM is known
final class RhythmCore {
    private(set) var bpm: Double = 0
    private var period: Double = 0
    private var anchor: Double = 0
    private var starts: [Double] = []
    private var maxEnd: [Double] = []
    private var trackDuration: Double = 0
    private var words: [TimedWord] = []

    func load(words input: [TimedWord], trackDuration: Double) {
        words = input.sorted { $0.start < $1.start }
        starts = words.map(\.start)
        var m = 0.0
        maxEnd = words.map { m = max(m, $0.end); return m }
        self.trackDuration = trackDuration
        anchor = starts.first ?? 0
        bpm = 0; period = 0
    }

    /// Phase-lock a beat oscillator at `bpm` Hz/60 to `anchor` (defaults to the first vocal onset).
    func lockTempo(bpm: Double, anchor: Double? = nil) {
        guard bpm > 40 else { return }
        self.bpm = bpm; period = 60 / bpm
        self.anchor = anchor ?? starts.first ?? 0
    }

    func clearTempo() { bpm = 0; period = 0 }

    /// Tier 3. Returns true when a tempo could be inferred.
    @discardableResult
    func inferTempoFromCadence() -> Bool {
        guard let est = Self.estimateTempo(words) else { return false }
        lockTempo(bpm: est.bpm, anchor: est.anchor)
        return true
    }

    // MARK: Per-frame state — a pure function of the playhead

    func state(at pos: Double) -> BeatState {
        var s = BeatState()
        s.bpm = bpm
        let n = starts.count

        var lo = 0, hi = n
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= pos { lo = mid + 1 } else { hi = mid } }
        let reached = lo

        if reached > 0 {
            s.onsetAge = pos - starts[reached - 1]
            if reached > 1 { s.syllableDelta = starts[reached - 1] - starts[reached - 2] }
        }

        if period > 0 {
            let beats = (pos - anchor) / period
            let ph = beats - beats.rounded(.down)
            s.beatPhase = ph
            s.beatPulse = exp(-4.5 * ph)
            s.beatIndex = Int(beats.rounded(.down))
        } else if reached > 0 {
            s.beatPhase = min(1, max(0, s.onsetAge / 0.5))
            s.beatPulse = exp(-6 * max(0, s.onsetAge))
            s.beatIndex = reached
        }
        guard n > 0 else { return s }

        // Tier 1 — vocal cadence: words/sec in ±1.5 s
        let wLo = lowerBound(pos - 1.5), wHi = lowerBound(pos + 1.5)
        s.wordsPerSecond = Double(max(0, wHi - wLo)) / 3.0
        let cadence = MathX.clamp(s.wordsPerSecond / 4.5)

        var inWordProgress: Double?
        if reached > 0 {
            let w = words[reached - 1]
            if pos < w.end, w.duration > 0 {
                inWordProgress = (pos - w.start) / w.duration
                if w.duration > 0.7 { s.sustain = sin(.pi * MathX.clamp(inWordProgress!)) }
            }
        }
        s.vocalEnergy = min(1, cadence * 0.8 + (inWordProgress != nil ? 0.2 : 0))

        // Velocity: an onset impulse whose size grows as the gap between syllables shrinks.
        let impact = exp(-s.onsetAge * 7) * MathX.clamp(0.14 / max(0.05, s.syllableDelta), 0, 1.4)
        s.velocity = MathX.clamp(0.5 * cadence + 0.5 * min(1, impact))

        let prevEnd = reached > 0 ? maxEnd[reached - 1] : 0
        let nextStart = reached < n ? starts[reached] : max(trackDuration, prevEnd)
        if pos > prevEnd, nextStart - prevEnd > 4.0 { s.isInstrumentalBreak = true }
        return s
    }

    private func lowerBound(_ x: Double) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    // MARK: Tier 3 — onset-interval clustering

    static func estimateTempo(_ words: [TimedWord]) -> (bpm: Double, anchor: Double)? {
        let onsets = words.map(\.start)
        guard onsets.count >= 12 else { return nil }

        var intervals: [Double] = []
        for i in 1..<onsets.count {
            let d = onsets[i] - onsets[i - 1]
            if d >= 0.09, d <= 2.4 { intervals.append(d) }
        }
        var lineStarts: [Double] = []
        var lastLine = -1
        for w in words where w.line != lastLine { lineStarts.append(w.start); lastLine = w.line }
        if lineStarts.count > 2 {
            for i in 1..<lineStarts.count {
                let d = lineStarts[i] - lineStarts[i - 1]
                if d > 0.3, d < 10 {
                    var x = d
                    while x > 2.4 { x /= 2 }
                    intervals.append(x)
                }
            }
        }
        guard intervals.count >= 8 else { return nil }

        let lowBPM = 70.0, highBPM = 180.0
        var hist = [Double](repeating: 0, count: Int((highBPM - lowBPM) * 2) + 1)
        for d in intervals {
            var b = 60 / d
            while b < lowBPM { b *= 2 }
            while b > highBPM { b /= 2 }
            let center = (b - lowBPM) * 2
            let lowI = max(0, Int(center) - 6), highI = min(hist.count - 1, Int(center) + 6)
            if lowI > highI { continue }
            for i in lowI...highI {
                let dx = Double(i) - center
                hist[i] += exp(-dx * dx / 8)
            }
        }
        guard let peak = hist.enumerated().max(by: { $0.element < $1.element }), peak.element > 2 else { return nil }
        let bpm = lowBPM + Double(peak.offset) / 2
        let period = 60 / bpm

        var sx = 0.0, sy = 0.0
        for t in onsets {
            let a = 2 * Double.pi * t / period
            sx += cos(a); sy += sin(a)
        }
        var phase = atan2(sy, sx) / (2 * Double.pi) * period
        if phase < 0 { phase += period }
        return (bpm, phase)
    }
}
