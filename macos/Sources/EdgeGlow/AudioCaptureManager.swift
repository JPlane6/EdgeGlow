import Accelerate
import AppKit
import Combine
import CoreAudio
import CoreMedia
import QuartzCore
import ScreenCaptureKit

enum AudioCaptureStatus: Equatable {
    /// Not capturing (no display enabled, or the screens are asleep / the session is inactive).
    case off
    case starting
    case live
    /// Screen & System Audio Recording permission is missing.
    case permissionNeeded
    case failed(String)
}

/// Latest band energies (0…1). Written ~50–120×/s off the main thread and read by the renderer every
/// frame, so it is lock-protected instead of @Published (which would re-render SwiftUI at audio rate).
final class AudioLevels: @unchecked Sendable {
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

/// Captures the Mac's system audio output (never the microphone) and turns it into bass (20–150 Hz) and
/// vocal (300 Hz–3.4 kHz) energies with a vDSP FFT.
///
/// On macOS 14.2+ the audio comes from a CoreAudio process tap (`SystemAudioTap`): audio only, no video
/// pipeline, no screen-sharing indicator. Older systems, or a failed tap, fall back to ScreenCaptureKit
/// configured as an audio-only stream (a 2×2 px, 1 fps dummy video that is never delivered).
///
/// Capture runs whenever at least one display has the glow enabled, independent of which player is in
/// use, and restarts itself when the default output device changes (Bluetooth, AirPlay, USB). When a
/// native player reports playback but the Mac stays digitally silent (Spotify Connect, AirPlay sent
/// from the app), the levels come from Cloud Sync instead, until real audio returns.
final class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let bassBand = 20.0...150.0
    private static let vocalBand = 300.0...3400.0
    /// Broadband level above which the Mac counts as playing audio (switches back to the live FFT at once).
    private static let presenceDb = -68.0
    /// Broadband level below which the Mac counts as silent…
    private static let silenceDb = -72.0
    /// …once it has stayed there this long (also used when buffers stop arriving entirely).
    private static let silenceHold: CFTimeInterval = 1.5
    /// Output-device changes arrive in bursts while a route settles.
    private static let routeDebounce: TimeInterval = 0.35

    private let state: AppState
    private let sampleQueue = DispatchQueue(label: "com.jplane6.edgeglow.audio", qos: .userInteractive)

    // Main-thread state.
    private var stream: SCStream?
    /// A `SystemAudioTap` (macOS 14.2+); typed as AnyObject so this class has no availability requirement.
    private var tap: AnyObject?
    private var tapUnavailable = false
    private var isStarting = false
    private var restartWhenStarted = false
    private var requestedAccess = false
    private var screensAsleep = false
    private var sessionActive = true
    private var routeWorkItem: DispatchWorkItem?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    // Sample-queue state.
    private let fftSetup: FFTSetup
    private var log2n = vDSP_Length(0)
    private var fftSize = 0
    private var window: [Float] = []
    private var ring: [Float] = []
    private var windowed: [Float] = []
    private var realp: [Float] = []
    private var imagp: [Float] = []
    private var power: [Float] = []
    private var sampleRate = 48_000.0
    private var bassEnvelope = 0.0
    private var vocalEnvelope = 0.0
    private var bassPeak = RollingPeak()
    private var vocalPeak = RollingPeak()
    private var vocalSlow = 0.0
    private var lastVocalOnset: CFTimeInterval = 0
    private var captureRunning = false
    private var audioPresent = false
    private var silentSince: CFTimeInterval?
    private var lastBufferTime: CFTimeInterval = 0
    private var levelSource = LevelSource.none
    /// When the native player last went from not playing to playing; Cloud Sync waits out the same
    /// 1.5 s silence window from here, so local playback that is still spinning up never flashes SYNC.
    private var nativePlayingSince: CFTimeInterval?
    private var lastSynthTime: CFTimeInterval?
    private var ticker: DispatchSourceTimer?

    init(state: AppState) {
        self.state = state
        // One setup sized for the largest FFT; vDSP setups also serve every smaller power of two.
        guard let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fftSetup = setup
        super.init()
        configureFFT()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: Lifecycle

    func start() {
        // An overlay on any display (and not in standby) → capture. receive(on:) defers past @Published's willSet.
        Publishers.CombineLatest(state.$activeDisplays.map(\.isEmpty), state.$displayMode)
            .map { noDisplays, mode in !noDisplays && mode != .off }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateCapture() }
            .store(in: &cancellables)
        // Wake capture cleanly (e.g. after a failure) the moment any player starts.
        state.$playback
            .removeDuplicates()
            .filter { $0 == .playing }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateCapture() }
            .store(in: &cancellables)

        let center = NSWorkspace.shared.notificationCenter
        let idleEvents: [(Notification.Name, (AudioCaptureManager) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }),
        ]
        workspaceObservers = idleEvents.map { name, apply in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                apply(self)
                self.updateCapture()
            }
        }

        installOutputDeviceListener()
        sampleQueue.async { [self] in startTicker() }
        updateCapture()
    }

    func stop() {
        cancellables.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        removeOutputDeviceListener()
        routeWorkItem?.cancel()
        stopCapture()
        sampleQueue.async { [self] in
            ticker?.cancel()
            ticker = nil
        }
    }

    /// An overlay is enabled on at least one display (not in standby) and the Mac isn't asleep or
    /// switched to another user. The lyrics also use the FFT to lock onto vocal onsets.
    private var captureWanted: Bool {
        // Debug/testing switch: `EDGEGLOW_NO_AUDIO=1` skips the system audio capture (and its permission prompt).
        if ProcessInfo.processInfo.environment["EDGEGLOW_NO_AUDIO"] != nil { return false }
        return state.displayMode != .off && !state.activeDisplays.isEmpty && !screensAsleep && sessionActive
    }

    private func updateCapture() {
        if captureWanted {
            startCapture()
        } else {
            stopCapture()
        }
    }

    private func startCapture() {
        guard stream == nil, tap == nil, !isStarting else { return }
        if #available(macOS 14.2, *), !tapUnavailable, startTap() { return }
        startScreenCapture()
    }

    /// Core Audio process tap. Returns false (and remembers it) when the tap can't be created, so the
    /// ScreenCaptureKit audio-only path takes over.
    @available(macOS 14.2, *)
    private func startTap() -> Bool {
        let tap = SystemAudioTap(queue: sampleQueue) { [weak self] mono, rate in
            self?.analyze(mono, sampleRate: rate)
        }
        do {
            try tap.start()
        } catch {
            tap.stop()
            tapUnavailable = true
            return false
        }
        self.tap = tap
        state.audioStatus = .live
        markCaptureRunning()
        return true
    }

    private func startScreenCapture() {
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
                    markCaptureRunning()
                    if restartWhenStarted {
                        // The output route changed while this stream was spinning up.
                        restartWhenStarted = false
                        restartCapture()
                    } else if !captureWanted {
                        stopCapture()
                    }
                }
            } catch {
                await MainActor.run { [self] in
                    isStarting = false
                    restartWhenStarted = false
                    state.audioStatus = Self.isPermissionError(error) ? .permissionNeeded : .failed(error.localizedDescription)
                }
            }
        }
    }

    private func markCaptureRunning() {
        sampleQueue.async { [self] in
            captureRunning = true
            lastBufferTime = CACurrentMediaTime()
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
        // A request, not a guarantee: the buffer parser accepts whatever format actually arrives.
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStreamConfiguration has no audio-only switch, so make the mandatory video stream as cheap
        // as possible: 2×2 px at 1 fps with the shallowest queue. Only the audio output is registered
        // below, so no full-screen IOSurface buffers are ever allocated or retained.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        return stream
    }

    private func stopCapture() {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap {
            self.tap = nil
            tap.stop()
            state.audioStatus = .off
            sampleQueue.async { [self] in
                captureRunning = false
                resetAnalysis()
            }
            return
        }
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
        state.audioStatus = .off
        sampleQueue.async { [self] in
            captureRunning = false
            resetAnalysis()
        }
    }

    /// Tears the stream down and builds a fresh one on the current output route.
    private func restartCapture() {
        if isStarting {
            restartWhenStarted = true
            return
        }
        if #available(macOS 14.2, *), let old = tap as? SystemAudioTap {
            tap = nil
            old.stop()
            sampleQueue.async { [self] in
                captureRunning = false
                resetAnalysis()
            }
            DispatchQueue.main.async { [weak self] in self?.updateCapture() }
            return
        }
        guard let old = stream else {
            updateCapture()
            return
        }
        stream = nil
        state.audioStatus = .starting
        sampleQueue.async { [self] in
            captureRunning = false
            resetAnalysis()
        }
        old.stopCapture { [weak self] _ in
            DispatchQueue.main.async { self?.updateCapture() }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    // MARK: Output route

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Restarts the stream (debounced) whenever the default output device changes, e.g. connecting
    /// AirPods or picking an AirPlay speaker, so capture follows the new route.
    private func installOutputDeviceListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.main, listener)
        if status == noErr {
            outputDeviceListener = listener
        }
    }

    private func removeOutputDeviceListener() {
        guard let listener = outputDeviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.main, listener)
        outputDeviceListener = nil
    }

    private func outputDeviceChanged() {
        routeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captureWanted else { return }
            self.restartCapture()
        }
        routeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeDebounce, execute: work)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard self.stream === stream else { return }
            self.stream = nil
            sampleQueue.async { [self] in
                captureRunning = false
                resetAnalysis()
            }
            if Self.isPermissionError(error) {
                state.audioStatus = .permissionNeeded
                return
            }
            state.audioStatus = .failed(error.localizedDescription)
            // Transient failures (display sleep, audio device switch): try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updateCapture()
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let (mono, rate) = Self.monoSamples(from: sampleBuffer), !mono.isEmpty else { return }
        analyze(mono, sampleRate: rate)
    }

    private enum SampleFormat {
        case float32, int16, int32

        var bytes: Int {
            switch self {
            case .float32, .int32: return 4
            case .int16: return 2
            }
        }
    }

    /// Mixes the buffer down to mono Float32, whatever its layout: any sample rate, any channel count,
    /// interleaved or not, Float32 / Int16 / Int32 linear PCM.
    private static func monoSamples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0 else { return nil }
        let flags = asbd.mFormatFlags
        guard flags & kAudioFormatFlagIsBigEndian == 0 else { return nil }

        let format: SampleFormat
        if flags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            format = .float32
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 16 {
            format = .int16
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 32 {
            format = .int32
        } else {
            return nil
        }
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let declaredChannels = max(Int(asbd.mChannelsPerFrame), 1)

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        var scratch = [Float](repeating: 0, count: frames)
        var mixed = 0

        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                mono.withUnsafeMutableBufferPointer { out in
                    scratch.withUnsafeMutableBufferPointer { temp in
                        guard let outBase = out.baseAddress, let tempBase = temp.baseAddress else { return }
                        if nonInterleaved {
                            // One buffer per channel.
                            for buffer in buffers {
                                guard let data = buffer.mData else { continue }
                                let count = min(frames, Int(buffer.mDataByteSize) / format.bytes)
                                accumulate(UnsafeRawPointer(data), stride: 1, count: count, format: format, into: outBase, scratch: tempBase)
                                mixed += 1
                            }
                        } else if let buffer = buffers.first, let data = buffer.mData {
                            // One buffer with the channels interleaved frame by frame.
                            let channels = buffer.mNumberChannels > 0 ? Int(buffer.mNumberChannels) : declaredChannels
                            let count = min(frames, Int(buffer.mDataByteSize) / (format.bytes * channels))
                            for channel in 0..<channels {
                                accumulate(UnsafeRawPointer(data) + channel * format.bytes, stride: channels, count: count, format: format, into: outBase, scratch: tempBase)
                            }
                            mixed = channels
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        guard mixed > 0 else { return nil }
        if mixed > 1 {
            var scale = 1 / Float(mixed)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        }
        return (mono, asbd.mSampleRate)
    }

    /// Adds one channel (every `stride`-th sample) into `out` as Float in -1…1.
    private static func accumulate(_ data: UnsafeRawPointer, stride: Int, count: Int, format: SampleFormat, into out: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(count)
        let step = vDSP_Stride(stride)
        switch format {
        case .float32:
            vDSP_vadd(data.assumingMemoryBound(to: Float.self), step, out, 1, out, 1, n)
        case .int16:
            vDSP_vflt16(data.assumingMemoryBound(to: Int16.self), step, scratch, 1, n)
            var scale = Float(1) / 32_768
            vDSP_vsma(scratch, 1, &scale, out, 1, out, 1, n)
        case .int32:
            vDSP_vflt32(data.assumingMemoryBound(to: Int32.self), step, scratch, 1, n)
            var scale = Float(1) / 2_147_483_648
            vDSP_vsma(scratch, 1, &scale, out, 1, out, 1, n)
        }
    }

    // MARK: Analysis (sample queue)

    /// A 2048-point FFT (≈43 ms, ~23 Hz bins at 48 kHz), doubled above 64 kHz so high-rate devices keep
    /// the same frequency resolution in the bass.
    private func configureFFT() {
        let newLog2n = vDSP_Length(sampleRate > 64_000 ? 12 : 11)
        guard newLog2n != log2n else { return }
        log2n = newLog2n
        fftSize = 1 << Int(newLog2n)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: fftSize / 2)
        imagp = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        ring.removeAll(keepingCapacity: true)
    }

    private func analyze(_ mono: [Float], sampleRate rate: Double) {
        if rate != sampleRate {
            sampleRate = rate
            configureFFT()
        }
        let now = CACurrentMediaTime()
        lastBufferTime = now

        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
        updatePresence(levelDb: 20 * log10(max(Double(rms), 1e-9)), now: now)
        updateLevelSource(now: now)

        let n = fftSize
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
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
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

        detectVocalOnset(vocalRatio, dt: dt, now: now)

        bassEnvelope = Self.envelope(bassEnvelope, target: bassLevel, dt: dt, attack: 0.012, release: 0.16)
        vocalEnvelope = Self.envelope(vocalEnvelope, target: vocalLevel, dt: dt, attack: 0.03, release: 0.35)
        // The FFT keeps running under Cloud Sync (to notice audio coming back) but only publishes when live.
        if levelSource != .cloudSync {
            state.audioLevels.update(bass: bassEnvelope, vocal: vocalEnvelope)
        }
    }

    /// A sudden rise of 300 Hz–3.4 kHz energy above its own recent average marks a vocal (or other
    /// mid-range) attack. When live audio is playing from a native player, the onset's track time is
    /// handed to the lyric lock, which compares it with the nearest word start.
    private func detectVocalOnset(_ vocal: Double, dt: Double, now: CFTimeInterval) {
        let rise = vocal - vocalSlow
        vocalSlow += (vocal - vocalSlow) * (1 - exp(-dt / 0.2))
        guard rise > 0.2, vocal > 0.3, now - lastVocalOnset > 0.12,
              audioPresent, levelSource == .live, state.playbackClock.isPlaying else { return }
        lastVocalOnset = now
        // The FFT window is centered half a window behind the newest sample.
        let analysisDelay = 0.5 * Double(fftSize) / sampleRate
        state.vocalLock.noteOnset(trackTime: state.playbackClock.currentTrackTime(at: now - analysisDelay), at: now)
    }

    /// Combined linear amplitude of the bins covering `band` (a full-scale sine reads ≈ 1).
    private func bandAmplitude(_ band: ClosedRange<Double>) -> Double {
        let half = fftSize / 2
        let binHz = sampleRate / Double(fftSize)
        // Bin 0 holds DC (and zrip packs Nyquist into imagp[0]), so start at bin 1.
        let lo = max(1, Int(band.lowerBound / binHz))
        let hi = min(half - 1, Int((band.upperBound / binHz).rounded(.up)))
        guard hi >= lo else { return 0 }
        var sum: Float = 0
        power.withUnsafeBufferPointer { p in
            vDSP_sve(p.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo + 1))
        }
        // zrip output is 2× the DFT and the Hann window halves amplitude: amplitude = |X| · 2 / N.
        return sqrt(Double(sum)) * 2 / Double(fftSize)
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
        vocalSlow = 0
        setAudioPresent(false)
        updateLevelSource(now: CACurrentMediaTime())
        if levelSource != .cloudSync {
            state.audioLevels.update(bass: 0, vocal: 0)
        }
    }

    // MARK: Live ↔ Cloud Sync (sample queue)

    /// Audio counts as present the instant it rises above -68 dBFS, and as gone after 1.5 s below
    /// -72 dBFS; the gap between the two thresholds is hysteresis.
    private func updatePresence(levelDb: Double, now: CFTimeInterval) {
        if levelDb > Self.presenceDb {
            silentSince = nil
            setAudioPresent(true)
        } else if levelDb < Self.silenceDb {
            let since = silentSince ?? now
            silentSince = since
            if now - since >= Self.silenceHold { setAudioPresent(false) }
        } else {
            silentSince = nil
        }
    }

    private func setAudioPresent(_ present: Bool) {
        guard present != audioPresent else { return }
        audioPresent = present
        if !present { silentSince = nil }
        DispatchQueue.main.async { [state] in
            if state.systemAudioActive != present { state.systemAudioActive = present }
        }
    }

    /// Live FFT while the Mac is making sound; Cloud Sync once a native player has reported playback for
    /// 1.5 s with the Mac silent (or capture unavailable); otherwise the (silent) live FFT if capture runs.
    private func updateLevelSource(now: CFTimeInterval) {
        let nativePlaying = state.cloudSync.nativePlaybackActive
        if !nativePlaying {
            nativePlayingSince = nil
        } else if nativePlayingSince == nil {
            nativePlayingSince = now
        }
        let source: LevelSource
        if audioPresent {
            source = .live
        } else if let since = nativePlayingSince, now - since >= Self.silenceHold {
            source = .cloudSync
        } else {
            source = captureRunning ? .live : .none
        }
        guard source != levelSource else { return }
        let wasCloud = levelSource == .cloudSync
        levelSource = source
        if source == .cloudSync {
            lastSynthTime = nil
            scheduleTicker(interval: 1.0 / 120)
        } else if wasCloud {
            scheduleTicker(interval: 0.25)
        }
        DispatchQueue.main.async { [state] in
            if state.levelSource != source { state.levelSource = source }
        }
    }

    /// Watchdog (4 Hz) and, under Cloud Sync, the 120 Hz synthesizer clock.
    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        scheduleTicker(interval: 0.25)
        timer.resume()
    }

    private func scheduleTicker(interval: Double) {
        ticker?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(interval < 0.05 ? 1 : 50))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // No buffers at all (capture off, or ScreenCaptureKit stalled) is silence too.
        if audioPresent, !captureRunning || now - lastBufferTime > Self.silenceHold {
            setAudioPresent(false)
        }
        updateLevelSource(now: now)
        guard levelSource == .cloudSync else { return }
        let dt = lastSynthTime.map { now - $0 } ?? 0
        lastSynthTime = now
        let trackTime = state.playbackClock.currentTrackTime(at: now)
        let levels = state.cloudSync.levels(at: trackTime, dt: dt)
        state.audioLevels.update(bass: levels.bass, vocal: levels.vocal)
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
