import AppKit
import Combine
import IOKit.pwr_mgt

/// Tracks macOS lock/unlock via the distributed notifications the login window posts.
final class LockScreenMonitor {
    private let state: AppState
    init(state: AppState) { self.state = state }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(unlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func locked() { DispatchQueue.main.async { self.state.screenLocked = true } }
    @objc private func unlocked() { DispatchQueue.main.async { self.state.screenLocked = false } }
}

/// Holds a "prevent idle display sleep" assertion while music is playing, so the lock screen
/// keeps showing the lyrics; releases it as soon as playback stops.
final class DisplaySleepBlocker {
    private let state: AppState
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    private var cancellable: AnyCancellable?

    init(state: AppState) { self.state = state }

    func start() {
        cancellable = state.$playback
            .map { $0 == .playing }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in playing ? self?.acquire() : self?.release() }
    }

    func stop() {
        cancellable = nil
        release()
    }

    private func acquire() {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "EdgeGlow music playback active" as CFString,
            &assertionID
        )
        held = result == kIOReturnSuccess
    }

    private func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }
}
