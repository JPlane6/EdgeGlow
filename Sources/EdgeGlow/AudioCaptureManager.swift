import Accelerate
import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

enum AudioCaptureStatus: Equatable {
    /// Not capturing (Spotify isn't playing).
    case off
    case starting
    case live
    /// Screen & System Audio Recording permission is missing.
    case permissionNeeded
    case failed(String)
}

/// Latest band energies (0…1). Written on the audio queue ~50×/s and read by the renderer every frame,
/// so it is lock-protected instead of @Published (which would re-render SwiftUI at audio rate).
final class AudioLevels {
    private let lock = NSLock()
    private var bass = 0.0
    private var vocal = 0.0

    func snapshot() -> (bass: Double, vocal: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (bass, vocal)
    }

    func update(bass: Double, vocal: Double) {
        lock.lock()
        self.bass = bass
        self.vocal = vocal
        lock.unlock()
    }
}

/// Captures the Mac's system audio output with ScreenCaptureKit (no microphone) and turns it into
/// bass (20–150 Hz) and vocal (300–3000 Hz) energies with a vDSP FFT.
final class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let log2n = vDSP_Length(11)
    private static let fftSize = 1 << 11 // 2048 samples ≈ 43 ms at 48 kHz, ~23 Hz per bin
    private static let bassBand = 20.0...150.0
    private static let vocalBand = 300.0...3000.0
    /// How long to keep capturing after Spotify stops playing, so quick pause/skip doesn't restart the stream.
    private static let stopGrace: TimeInterval = 8

    private let state: AppState
    private let sampleQueue = DispatchQueue(label: "com.jplane6.edgeglow.audio", qos: .userInteractive)

    // Main-thread state.
    private var stream: SCStream?
    private var isStarting = false
    private var requestedAccess = false
    private var stopWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    // Sample-queue state.
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var ring: [Float] = []
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var power: [Float]
    private var sampleRate = 48_000.0
    private var bassEnvelope = 0.0
    private var vocalEnvelope = 0.0
    private var bassPeak = RollingPeak()
    private var vocalPeak = RollingPeak()

    init(state: AppState) {
        self.state = state
        let n = Self.fftSize
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fftSetup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
        super.init()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: Lifecycle

    /// Captures only while Spotify is playing, which also keeps the macOS recording indicator off when idle.
    func start() {
        state.$playback
            .removeDuplicates()
            .sink { [weak self] playback in
                self?.playbackChanged(to: playback)
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopWorkItem?.cancel()
        stopCapture()
    }

    private func playbackChanged(to playback: PlaybackState) {
        stopWorkItem?.cancel()
        if playback == .playing {
            startCapture()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.stopCapture() }
            stopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGrace, execute: work)
        }
    }

    private func startCapture() {
        guard stream == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt once; after granting, macOS needs the app relaunched.
            if !requestedAccess {
                requestedAccess = true
                CGRequestScreenCaptureAccess()
            }
            state.audioStatus = .permissionNeeded
            return
        }
        isStarting = true
        state.audioStatus = .starting
        Task { [self] in
            do {
                let stream = try await makeStream()
                await MainActor.run { [self] in
                    isStarting = false
                    self.stream = stream
                    state.audioStatus = .live
                    // Playback may have stopped while the stream was spinning up.
                    if !state.isPlaying { playbackChanged(to: state.playback) }
                }
            } catch {
                await MainActor.run { [self] in
                    isStarting = false
                    state.audioStatus = Self.isPermissionError(error) ? .permissionNeeded : .failed(error.localizedDescription)
                }
            }
        }
    }

    private func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "EdgeGlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }
        // A display filter is required even for audio; system audio is captured regardless of which one.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStreamConfiguration has no audio-only switch, so make the mandatory video stream as cheap
        // as possible: 2×2 px at 1 fps, frames discarded.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // Registering a screen output too stops ScreenCaptureKit logging a "dropping frame" error each second.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        return stream
    }

    private func stopCapture() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
        state.audioStatus = .off
        sampleQueue.async { [self] in resetAnalysis() }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard self.stream === stream else { return }
            self.stream = nil
            sampleQueue.async { [self] in resetAnalysis() }
            if Self.isPermissionError(error) {
                state.audioStatus = .permissionNeeded
                return
            }
            state.audioStatus = .failed(error.localizedDescription)
            // Transient failures (display sleep, audio device switch): try again shortly if still playing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.state.isPlaying else { return }
                self.startCapture()
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let mono = Self.monoSamples(from: sampleBuffer, sampleRate: &sampleRate), !mono.isEmpty else { return }
        analyze(mono)
    }

    /// Mixes the buffer's channels down to mono Float32.
    private static func monoSamples(from sampleBuffer: CMSampleBuffer, sampleRate: inout Double) -> [Float]? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return nil }
        sampleRate = asbd.mSampleRate

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                mono.withUnsafeMutableBufferPointer { out in
                    guard let outBase = out.baseAddress else { return }
                    var channels = 0
                    if nonInterleaved {
                        for buffer in buffers {
                            guard let data = buffer.mData else { continue }
                            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                            vDSP_vadd(data.assumingMemoryBound(to: Float.self), 1, outBase, 1, outBase, 1, vDSP_Length(count))
                            channels += 1
                        }
                    } else if let data = buffers.first?.mData {
                        let stride = Int(asbd.mChannelsPerFrame)
                        let samples = data.assumingMemoryBound(to: Float.self)
                        for channel in 0..<stride {
                            vDSP_vadd(samples + channel, vDSP_Stride(stride), outBase, 1, outBase, 1, vDSP_Length(frames))
                        }
                        channels = stride
                    }
                    if channels > 1 {
                        var scale = 1 / Float(channels)
                        vDSP_vsmul(outBase, 1, &scale, outBase, 1, vDSP_Length(frames))
                    }
                }
            }
        } catch {
            return nil
        }
        return mono
    }

    // MARK: Analysis (sample queue)

    private func analyze(_ mono: [Float]) {
        let n = Self.fftSize
        // Sliding window over the most recent `n` samples; one FFT per delivered buffer.
        ring.append(contentsOf: mono)
        if ring.count > n { ring.removeFirst(ring.count - n) }
        guard ring.count == n else { return }
        let dt = Double(mono.count) / sampleRate

        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { powerPtr in
                    vDSP_zvmags(&split, 1, powerPtr.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Auto-gain: each band is divided by its own rolling maximum, so local peaks reach 1.0 however
        // quiet the track or the Mac's output volume is.
        let bassRatio = Self.autoGain(bandAmplitude(Self.bassBand), peak: &bassPeak, dt: dt)
        let vocalRatio = Self.autoGain(bandAmplitude(Self.vocalBand), peak: &vocalPeak, dt: dt)

        // Kicks sit ~10–15 dB above the gaps between them (an amplitude ratio of ~0.2–0.3), so the linear
        // ratio already reads as distinct hits. Vocals get a square root (≈ a 24 dB window) so sustained
        // singing well below the peak still moves the comets.
        let bassLevel = bassRatio
        let vocalLevel = vocalRatio.squareRoot()

        bassEnvelope = Self.envelope(bassEnvelope, target: bassLevel, dt: dt, attack: 0.012, release: 0.16)
        vocalEnvelope = Self.envelope(vocalEnvelope, target: vocalLevel, dt: dt, attack: 0.03, release: 0.35)
        state.audioLevels.update(bass: bassEnvelope, vocal: vocalEnvelope)
    }

    /// Combined linear amplitude of the bins covering `band` (a full-scale sine reads ≈ 1).
    private func bandAmplitude(_ band: ClosedRange<Double>) -> Double {
        let half = Self.fftSize / 2
        let binHz = sampleRate / Double(Self.fftSize)
        // Bin 0 holds DC (and zrip packs Nyquist into imagp[0]), so start at bin 1.
        let lo = max(1, Int(band.lowerBound / binHz))
        let hi = min(half - 1, Int((band.upperBound / binHz).rounded(.up)))
        guard hi >= lo else { return 0 }
        var sum: Float = 0
        power.withUnsafeBufferPointer { p in
            vDSP_sve(p.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo + 1))
        }
        // zrip output is 2× the DFT and the Hann window halves amplitude: amplitude = |X| · 2 / N.
        return sqrt(Double(sum)) * 2 / Double(Self.fftSize)
    }

    // MARK: Auto-gain

    /// The rolling maximum is never taken as lower than this (-60 dBFS), so near-silence is divided by a
    /// sane reference instead of being amplified into full-scale noise.
    private static let noiseFloor = pow(10, -60.0 / 20)
    /// Below -78 dBFS a band counts as silent; the gate opens smoothly over the next 8 dB.
    private static let gateDb = -78.0
    private static let gateRangeDb = 8.0

    /// Current band amplitude as a 0…1 fraction of the loudest it has been over the last few seconds.
    private static func autoGain(_ amplitude: Double, peak: inout RollingPeak, dt: Double) -> Double {
        let reference = max(peak.update(amplitude, dt: dt), noiseFloor)
        let db = 20 * log10(max(amplitude, 1e-9))
        let gate = min(max((db - gateDb) / gateRangeDb, 0), 1)
        return min(amplitude / reference, 1) * gate
    }

    /// Fast-attack / smooth-decay one-pole envelope follower.
    private static func envelope(_ current: Double, target: Double, dt: Double, attack: Double, release: Double) -> Double {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }

    private func resetAnalysis() {
        ring.removeAll(keepingCapacity: true)
        bassEnvelope = 0
        vocalEnvelope = 0
        bassPeak.reset()
        vocalPeak.reset()
        state.audioLevels.update(bass: 0, vocal: 0)
    }
}

/// Rolling maximum of a band's amplitude over the last ~4 s, kept as 16 buckets of 0.25 s so each update
/// costs a 16-element max instead of scanning the full history. The reference jumps up to a new peak
/// immediately; when an old peak ages out of the window it eases down in dB (≈0.8 s time constant), so
/// the gain never snaps.
private struct RollingPeak {
    private static let bucketDuration = 0.25
    private static let bucketCount = 16
    private static let releaseTime = 0.8

    private var buckets = [Double](repeating: 0, count: bucketCount)
    private var index = 0
    private var bucketAge = 0.0
    private var reference = 0.0

    mutating func update(_ amplitude: Double, dt: Double) -> Double {
        bucketAge += dt
        while bucketAge >= Self.bucketDuration {
            bucketAge -= Self.bucketDuration
            index = (index + 1) % Self.bucketCount
            buckets[index] = 0
        }
        buckets[index] = max(buckets[index], amplitude)

        let windowMax = buckets.max() ?? 0
        if windowMax >= reference {
            reference = windowMax
        } else {
            // Ease down in the dB domain, so a 24 dB drop settles as quickly as a 6 dB one.
            reference *= pow(max(windowMax, 1e-9) / reference, 1 - exp(-dt / Self.releaseTime))
        }
        return reference
    }

    mutating func reset() {
        self = RollingPeak()
    }
}
