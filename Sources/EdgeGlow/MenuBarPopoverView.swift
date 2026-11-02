import AppKit
import SwiftUI

/// Dark control panel shown from the menu bar item.
struct MenuBarPopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nowPlayingCard
            if state.automationDenied {
                permissionBanner
            }
            if state.audioStatus == .permissionNeeded {
                audioPermissionBanner
            }
            // The settings cards scroll so the popover never grows taller than the screen and pushes the
            // header up under the menu bar. The header, now playing, toggles and footer stay pinned.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    colorsCard
                    styleCard
                    displaysCard
                    slidersCard
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            togglesCard
            footer
        }
        .padding(16)
        .frame(width: 340)
        .frame(maxHeight: 650)
        .background(
            LinearGradient(
                colors: [Color(white: 0.11), Color(white: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .preferredColorScheme(.dark)
        .tint(state.targetPrimary.color)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [state.targetPrimary.color, state.targetSecondary.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("EdgeGlow")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.8), radius: 3)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            audioBadge
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }

    /// Live bass/vocal meter while audio is flowing, otherwise the capture status.
    @ViewBuilder
    private var audioBadge: some View {
        switch state.audioStatus {
        case .live:
            // Levels aren't @Published (they update at audio rate), so poll them while the popover is shown.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let levels = state.audioLevels.snapshot()
                HStack(spacing: 4) {
                    levelBar(levels.bass, color: state.targetPrimary.color)
                    levelBar(levels.vocal, color: state.targetSecondary.color)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.5)
                }
            }
            .help("Bass (20–150 Hz) and vocals (300–3000 Hz) from system audio")
        case .starting:
            badgeLabel("waveform", "Starting…", color: .secondary)
        case .off:
            badgeLabel("waveform", "Audio Off", color: .secondary)
                .help("System audio capture runs while Spotify is playing")
        case .permissionNeeded:
            badgeLabel("exclamationmark.triangle.fill", "No Access", color: .yellow)
        case .failed(let message):
            badgeLabel("exclamationmark.triangle.fill", "Audio Error", color: .orange)
                .help(message)
        }
    }

    private func levelBar(_ level: Double, color: Color) -> some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule()
                .fill(color)
                .frame(height: max(2, 12 * min(max(level, 0), 1)))
                .shadow(color: color.opacity(0.8), radius: 2)
        }
        .frame(width: 4, height: 12)
    }

    private func badgeLabel(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private var statusColor: Color {
        switch state.playback {
        case .playing: return .green
        case .paused: return .yellow
        case .stopped: return Color(white: 0.45)
        }
    }

    private var statusText: String {
        switch state.playback {
        case .playing: return "Live"
        case .paused: return "Paused"
        case .stopped: return state.spotifyRunning ? "Idle" : "No Spotify"
        }
    }

    // MARK: Now playing

    private var nowPlayingCard: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = state.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [state.targetPrimary.color.opacity(0.6), state.targetSecondary.color.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: state.targetPrimary.color.opacity(0.35), radius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(hasTrack ? state.trackName : "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(hasTrack ? state.artistName : (state.spotifyRunning ? "Press play in Spotify" : "Open Spotify to sync the glow"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var hasTrack: Bool {
        state.playback != .stopped && !state.trackName.isEmpty
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("EdgeGlow can't read Spotify. Allow it under Privacy & Security → Automation.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .card()
    }

    private var audioPermissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow EdgeGlow under Privacy & Security → Screen & System Audio Recording so the glow can react to the music, then relaunch.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Relaunch") {
                        NSApp.relaunch()
                    }
                }
                .controlSize(.small)
            }
        }
        .card()
    }

    // MARK: Colors

    private var colorsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Colors")
            HStack(spacing: 8) {
                colorPill(label: "Primary", color: state.targetPrimary)
                colorPill(label: "Secondary", color: state.targetSecondary)
            }
            Toggle(isOn: $state.useCustomColors) {
                Text("Override Album Colors")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if state.useCustomColors {
                HStack {
                    ColorPicker("Primary", selection: colorBinding(\.customPrimary), supportsOpacity: false)
                    Spacer()
                    ColorPicker("Secondary", selection: colorBinding(\.customSecondary), supportsOpacity: false)
                }
                .font(.system(size: 12))
            }
        }
        .card()
    }

    private func colorPill(label: String, color: RGBColor) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color.color)
                .frame(width: 12, height: 12)
                .shadow(color: color.color.opacity(0.9), radius: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(color.hex)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(color.color.opacity(0.12)))
        .overlay(Capsule().stroke(color.color.opacity(0.35), lineWidth: 0.5))
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppState, RGBColor>) -> Binding<Color> {
        Binding(
            get: { state[keyPath: keyPath].color },
            set: { state[keyPath: keyPath] = RGBColor($0) }
        )
    }

    // MARK: Animation style

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Animation Style")
            HStack(spacing: 6) {
                ForEach(AnimationStyle.allCases) { style in
                    styleTile(style)
                }
            }
            Text(state.animationStyle.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func styleTile(_ style: AnimationStyle) -> some View {
        let selected = state.animationStyle == style
        let accent = state.targetPrimary.color
        return Button {
            state.animationStyle = style
        } label: {
            VStack(spacing: 5) {
                Image(systemName: style.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 16)
                Text(style.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? accent.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? accent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(style.caption)
    }

    // MARK: Displays

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Displays")
                Spacer()
                Text(displaySummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            VStack(spacing: 2) {
                ForEach(state.availableDisplays) { display in
                    displayRow(display)
                }
            }
            if disconnectedActiveCount > 0 {
                Text(disconnectedActiveCount == 1
                     ? "1 enabled display is disconnected. Its glow comes back when you plug it in."
                     : "\(disconnectedActiveCount) enabled displays are disconnected. Their glow comes back when you plug them in.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func displayRow(_ display: DisplayInfo) -> some View {
        let enabled = state.activeDisplays.contains(display.id)
        let accent = state.targetPrimary.color
        return Button {
            if enabled {
                state.activeDisplays.remove(display.id)
            } else {
                state.activeDisplays.insert(display.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .frame(width: 18)
                Text(display.name)
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(enabled ? accent : Color.white.opacity(0.25))
                    .shadow(color: enabled ? accent.opacity(0.6) : .clear, radius: 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? accent.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var enabledConnectedCount: Int {
        state.availableDisplays.filter { state.activeDisplays.contains($0.id) }.count
    }

    private var disconnectedActiveCount: Int {
        let connected = Set(state.availableDisplays.map(\.id))
        return state.activeDisplays.subtracting(connected).count
    }

    private var displaySummary: String {
        let total = state.availableDisplays.count
        let on = enabledConnectedCount
        if on == 0 { return "Glow hidden" }
        return on == total ? (total == 1 ? "On" : "All \(total) on") : "\(on) of \(total) on"
    }

    // MARK: Sliders

    private var slidersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Glow")
            sliderRow("Thickness", value: $state.thickness, range: 10...120, display: "\(Int(state.thickness))pt")
            sliderRow("Glow Spill / Blur", value: $state.glowSpread, range: 15...90, display: "\(Int(state.glowSpread))pt")
            sliderRow("Bass Reactivity", value: $state.reactivity, range: 0...1.5, display: "\(Int((state.reactivity * 100).rounded()))%")
            sliderRow("Master Brightness", value: $state.intensity, range: 0.1...1.0, display: "\(Int((state.intensity * 100).rounded()))%")
            if state.animationStyle.usesComets {
                sliderRow("Comet Length", value: $state.cometLength, range: 0.05...0.45, display: "\(Int((state.cometLength * 100).rounded()))%")
            }
        }
        .card()
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(display)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    // MARK: Toggles

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow("Keep Idle Glow When Paused", caption: "Soft breathing glow when nothing is playing", isOn: $state.idleWhenPaused)
            toggleRow("Kinetic Physics", caption: state.animationStyle == .sparksOnly
                      ? "Always on in Sparks Only"
                      : "Edge bounce, sparks and impact flashes on the bass", isOn: $state.kineticEffects)
                .disabled(state.animationStyle == .sparksOnly)
        }
        .card()
    }

    private func toggleRow(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Spotify colors · live system audio")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit EdgeGlow", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
