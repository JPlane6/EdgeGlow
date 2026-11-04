import CoreAudio
import Foundation

/// Compensation for the delay between the Mac producing audio and the listener hearing it, in seconds.
/// Written on route changes, read every frame by the lyric playhead.
final class AudioLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func set(_ newValue: Double) {
        lock.lock()
        seconds = newValue
        lock.unlock()
    }
}

/// Zero-config output latency detection. Follows the default output device and works out how long audio
/// takes to reach the listener, so lyrics land on the sound that is actually heard rather than on the
/// player's decode position. There is deliberately no manual offset.
///
/// latency = (device latency + safety offset + IO buffer + stream latency) / nominal sample rate
///           + a calibrated wireless window on Bluetooth routes.
final class AudioLatencyDetector {
    /// Classic A2DP (AAC/SBC) and LE Audio pipeline delay on Apple Silicon. CoreAudio only reports the
    /// local ring buffer for these devices, not the codec and radio window in front of the earbuds.
    static let bluetoothPipelineLatency = 0.165
    /// A Bluetooth device reporting at least this much already includes the wireless window.
    private static let bluetoothReportedCeiling = 0.120
    /// Route changes arrive in bursts, and Bluetooth devices finish reporting latency a moment later.
    private static let debounce: TimeInterval = 0.25
    private static let settleRecheck: TimeInterval = 1.5

    private let state: AppState
    private let queue = DispatchQueue(label: "com.jplane6.edgeglow.latency", qos: .utility)

    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private var pending: DispatchWorkItem?

    private static var defaultOutputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
    private static var isAliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
    private static var sampleRateAddress = address(kAudioDevicePropertyNominalSampleRate)

    init(state: AppState) {
        self.state = state
    }

    func start() {
        queue.async { [self] in
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener) == noErr {
                systemListener = listener
            }
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            pending?.cancel()
            if let listener = systemListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)
                systemListener = nil
            }
            unwatchDevice()
        }
    }

    // MARK: Refresh

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
            // Bluetooth devices often publish their final latency a beat after the route switches.
            self?.queue.asyncAfter(deadline: .now() + Self.settleRecheck) { self?.refresh() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func refresh() {
        let device = Self.defaultOutputDevice()
        if device != watchedDevice {
            unwatchDevice()
            watch(device)
        }
        let info = device == kAudioObjectUnknown ? nil : Self.measure(device: device)
        state.audioLatency.set(info?.latency ?? 0)
        DispatchQueue.main.async { [state] in
            if state.audioRoute != info { state.audioRoute = info }
        }
    }

    private func watch(_ device: AudioObjectID) {
        guard device != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
        // A disappearing device (earbuds back in the case) or a sample-rate switch changes the latency.
        for var address in [Self.isAliveAddress, Self.sampleRateAddress] {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        }
        deviceListener = listener
        watchedDevice = device
    }

    private func unwatchDevice() {
        if let listener = deviceListener, watchedDevice != kAudioObjectUnknown {
            for var address in [Self.isAliveAddress, Self.sampleRateAddress] {
                AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, queue, listener)
            }
        }
        deviceListener = nil
        watchedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: CoreAudio queries

    static func measure(device: AudioObjectID) -> AudioRouteInfo? {
        let name = string(device, kAudioObjectPropertyName) ?? "Audio Output"
        let transport = transportType(of: device)
        let rate: Double = scalar(device, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        guard rate > 0 else { return nil }

        let deviceLatency: UInt32 = scalar(device, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeOutput) ?? 0
        let safetyOffset: UInt32 = scalar(device, kAudioDevicePropertySafetyOffset, UInt32(0), scope: kAudioObjectPropertyScopeOutput) ?? 0
        let bufferFrames: UInt32 = scalar(device, kAudioDevicePropertyBufferFrameSize, UInt32(0), scope: kAudioObjectPropertyScopeOutput) ?? 0
        var streamLatency: UInt32 = 0
        if let stream = outputStream(of: device) {
            streamLatency = scalar(stream, kAudioStreamPropertyLatency, UInt32(0)) ?? 0
        }
        var seconds = Double(deviceLatency + safetyOffset + bufferFrames + streamLatency) / rate

        if transport.isBluetooth, seconds < bluetoothReportedCeiling {
            seconds += bluetoothPipelineLatency
        }
        return AudioRouteInfo(deviceName: name, transport: transport.kind, latency: seconds)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func transportType(of device: AudioObjectID) -> (kind: AudioTransport, isBluetooth: Bool) {
        let raw: UInt32 = scalar(device, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        switch raw {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return (.bluetooth, true)
        case kAudioDeviceTransportTypeBuiltIn: return (.builtIn, false)
        case kAudioDeviceTransportTypeUSB: return (.usb, false)
        case kAudioDeviceTransportTypeAirPlay: return (.airPlay, false)
        default: return (.other, false)
        }
    }

    private static func outputStream(of device: AudioObjectID) -> AudioObjectID? {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T: Numeric>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope: scope)
        var value = initial
        let status = withUnsafeMutableBytes(of: &value) { raw -> OSStatus in
            var size = UInt32(raw.count)
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Learns a small timing correction from the vocals in the live audio.
///
/// The audio tap sees sound at the moment the Mac plays it. When a vocal onset (a jump in 300 Hz–3.4 kHz
/// energy) lands close to a lyric word's start time, the gap tells how far the player's reported position
/// is from the audible vocal. A heavily smoothed, clamped estimate of that gap trims the playhead; with no
/// vocals (instrumentals, silence, remote playback) the trim relaxes back to zero.
final class VocalOnsetLock: @unchecked Sendable {
    /// Onsets farther than this from any word start are ignored (percussive hits, ad-libs, wrong word).
    private static let matchWindow = 0.20
    private static let maxCorrection = 0.20
    private static let attackGain = 0.6
    private static let releaseGain = 0.1
    /// Without a confirming onset for this long the trim decays toward zero.
    private static let idleDecay = 4.0

    private let lock = NSLock()
    private var wordStarts: [Double] = []
    private var trim = 0.0
    private var lastConfirmation = 0.0

    /// Sorted word start times of the current lyrics (empty when there are none).
    func setWordStarts(_ starts: [Double]) {
        lock.lock()
        wordStarts = starts
        trim = 0
        lock.unlock()
    }

    func reset() {
        lock.lock()
        trim = 0
        lock.unlock()
    }

    /// Seconds to add to the playhead.
    func correction(at now: CFTimeInterval) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let idle = now - lastConfirmation
        return idle > Self.idleDecay ? trim * max(0, 1 - (idle - Self.idleDecay) / 2) : trim
    }

    /// A vocal onset happened at `trackTime` seconds into the song (player clock, latency not applied).
    func noteOnset(trackTime: Double, at now: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !wordStarts.isEmpty else { return }
        // Nearest word start by binary search.
        var low = 0
        var high = wordStarts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if wordStarts[mid] < trackTime { low = mid + 1 } else { high = mid }
        }
        var nearest = wordStarts[low]
        if low > 0, abs(wordStarts[low - 1] - trackTime) < abs(nearest - trackTime) { nearest = wordStarts[low - 1] }
        // The word is audible at `nearest` but the player clock already reads `trackTime`: a positive gap
        // means the clock runs ahead of the sound, so the playhead is pulled back by that much.
        let gap = trackTime - nearest
        guard abs(gap) <= Self.matchWindow else { return }
        let target = min(max(-gap, -Self.maxCorrection), Self.maxCorrection)
        // Fast attack when the estimate must move away from zero or the error is large, slow release otherwise.
        let gain = abs(target - trim) > 0.04 ? Self.attackGain : Self.releaseGain
        trim += (target - trim) * gain
        lastConfirmation = now
    }
}
