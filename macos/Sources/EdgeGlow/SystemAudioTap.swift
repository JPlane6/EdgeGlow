import Accelerate
import CoreAudio
import Foundation

/// Pure system-audio capture through a CoreAudio process tap (macOS 14.2+).
///
/// A global stereo tap is attached to a private aggregate device and read from an IOProc. No video
/// pipeline exists at all: no ScreenCaptureKit stream, no IOSurface frame buffers and no screen-sharing
/// indicator in the menu bar. The tap is taken before the output device, so it hears the same audio the
/// Mac plays regardless of volume or the Bluetooth route.
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case permissionDenied
        case failed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "System audio recording is not allowed"
            case .failed(let step, let status): return "\(step) failed (\(status))"
            }
        }
    }

    /// Mono samples and their sample rate, delivered on the queue passed to `init`.
    typealias Handler = (_ mono: [Float], _ sampleRate: Double) -> Void

    private let queue: DispatchQueue
    private let handler: Handler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var scratch: [Float] = []

    init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "EdgeGlow audio tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw TapError.failed("Creating the audio tap", status)
        }

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            stop()
            throw TapError.failed("Reading the tap format", status)
        }

        // The aggregate device gives the tap a clock; the default output is its main sub-device.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EdgeGlow Tap",
            kAudioAggregateDeviceUIDKey: "com.jplane6.edgeglow.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outputUID = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw TapError.failed("Creating the aggregate device", status)
        }

        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let rate = format.mSampleRate
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        guard isFloat else {
            stop()
            throw TapError.failed("Unsupported tap format", -1)
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input, nonInterleaved: nonInterleaved, channels: channels, rate: rate)
        }
        guard status == noErr, let procID else {
            stop()
            throw TapError.failed("Creating the IO proc", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw TapError.failed("Starting the audio device", status)
        }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: IO

    private func process(_ list: UnsafePointer<AudioBufferList>, nonInterleaved: Bool, channels: Int, rate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return }

        let frames: Int
        if nonInterleaved {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        } else {
            frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(Int(first.mNumberChannels), 1))
        }
        guard frames > 0 else { return }
        if scratch.count != frames { scratch = [Float](repeating: 0, count: frames) }

        var mixed = 0
        scratch.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            vDSP_vclr(base, 1, vDSP_Length(frames))
            if nonInterleaved {
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    vDSP_vadd(data.assumingMemoryBound(to: Float.self), 1, base, 1, base, 1, vDSP_Length(count))
                    mixed += 1
                }
            } else if let data = first.mData {
                let stride = max(Int(first.mNumberChannels), channels)
                for channel in 0..<stride {
                    vDSP_vadd(data.assumingMemoryBound(to: Float.self) + channel, vDSP_Stride(stride), base, 1, base, 1, vDSP_Length(frames))
                }
                mixed = stride
            }
        }
        guard mixed > 0 else { return }
        if mixed > 1 {
            var scale = 1 / Float(mixed)
            vDSP_vsmul(scratch, 1, &scale, &scratch, 1, vDSP_Length(frames))
        }
        handler(scratch, rate)
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
