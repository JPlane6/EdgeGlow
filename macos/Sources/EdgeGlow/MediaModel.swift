import Foundation
import QuartzCore

// Platform-neutral playback model shared by the media bridge, the audio pipeline and the UI. Nothing in
// this file touches AppKit, AppleScript or ScreenCaptureKit, so it ports as-is.

/// Where the current music (and its metadata) comes from, in detection priority order.
enum MediaSource: String, Equatable {
    case spotify
    case appleMusic
    /// A music tab in a browser; playback is read from the tab's media element.
    case youTubeMusic

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .youTubeMusic: return "YouTube Music"
        }
    }

    var symbol: String {
        switch self {
        case .spotify, .appleMusic: return "music.note"
        case .youTubeMusic: return "globe"
        }
    }

    /// Native players report a trustworthy track position, which Cloud Sync needs.
    var reportsPosition: Bool { self == .spotify || self == .appleMusic }
}

/// Track metadata as reported by one provider.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    /// HTTP artwork URL when the provider exposes one (Spotify does, Apple Music and browsers don't).
    var artworkURL: String?
    /// Playback position and track length in seconds, when known.
    var position: Double?
    var duration: Double?
}

/// Which signal is driving the glow's bass/vocal energies.
enum LevelSource: Equatable {
    /// No audio pipeline is running.
    case none
    /// Live FFT of the Mac's system audio.
    case live
    /// Synthesized from the track's BPM and synced lyrics, because the music plays on a remote speaker
    /// (Spotify Connect, AirPlay from the app) and the Mac itself is silent.
    case cloudSync
}

/// Continuous playback clock: the last polled track position plus the time elapsed since the poll.
/// Written by the media bridge every couple of seconds, read at audio/frame rate from other threads.
final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPolledPosition = 0.0
    private var lastPollTime = CACurrentMediaTime()
    private var playing = false

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playing
    }

    /// `currentTrackTime = lastPolledPosition + (now - lastPollTime)` while playing; frozen while paused.
    func currentTrackTime(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return playing ? lastPolledPosition + (now - lastPollTime) : lastPolledPosition
    }

    /// Re-anchors the clock to a position that was sampled at `time` (a CACurrentMediaTime value).
    func anchor(position: Double, at time: CFTimeInterval) {
        lock.lock()
        lastPolledPosition = position
        lastPollTime = time
        lock.unlock()
    }

    func setPlaying(_ newValue: Bool, at now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        if playing != newValue {
            // Freeze (or restart) the clock at the current extrapolated position.
            lastPolledPosition = playing ? lastPolledPosition + (now - lastPollTime) : lastPolledPosition
            lastPollTime = now
            playing = newValue
        }
        lock.unlock()
    }
}
