import AppKit

/// Borderless panel that is allowed to cover the menu bar and notch.
class OverlayPanel: NSPanel {
    // macOS normally pushes windows below the menu bar; returning the frame untouched lets the
    // overlay span the full display, notch included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A click-through panel covering all of `screen`, just above the status bar level.
    convenience init(covering screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Display UUID, which (unlike CGDirectDisplayID) stays the same for a monitor across reboots and
    /// replugging. Falls back to the numeric display ID.
    var edgeGlowIdentifier: String? {
        guard let displayID else { return nil }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return String(displayID)
    }
}
