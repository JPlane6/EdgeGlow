import AppKit
import SwiftUI

/// Minimal dark control panel shown from the menu bar item: a mode bar, only the controls the mode needs,
/// and a one-line footer. No headers, captions or helper text.
struct MenuBarPopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            if !state.automationDeniedApps.isEmpty {
                permissionBanner
            }
            if state.audioStatus == .permissionNeeded {
                audioPermissionBanner
            }
            if state.displayMode != .off {
                // Scrolls so the popover never grows taller than the screen.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.displayMode.glowOn {
                            glowSection
                        }
                        if state.displayMode.lyricsOn {
                            lyricsSection
                        }
                        if state.availableDisplays.count > 1 {
                            displaysRow
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .frame(maxHeight: 620)
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

    // MARK: Mode

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(DisplayMode.allCases) { mode in
                modeSegment(mode)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func modeSegment(_ mode: DisplayMode) -> some View {
        let selected = state.displayMode == mode
        let accent = state.targetPrimary.color
        return Button {
            state.displayMode = mode
        } label: {
            Text(mode.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent.opacity(0.22) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? accent.opacity(0.6) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Glow

    private var glowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AnimationStyle.allCases) { style in
                    styleTile(style)
                }
            }
            colorRow
            iconSlider("sun.max.fill", value: $state.intensity, range: 0.1...1.0)
            iconSlider("bolt.fill", value: $state.reactivity, range: 0...1.5)
            iconSlider("arrow.left.and.right.square", value: $state.thickness, range: 10...120)
            iconSlider("circle.dashed", value: $state.glowSpread, range: 15...90)
            if state.animationStyle.usesComets {
                iconSlider("gauge.with.needle", value: $state.cometLength, range: 0.05...0.45)
            }
            HStack(spacing: 6) {
                pill("atom", isOn: $state.kineticEffects)
                    .disabled(state.animationStyle == .sparksOnly)
                pill("lock.fill", isOn: $state.showOnLockScreen)
            }
        }
        .card()
    }

    private func styleTile(_ style: AnimationStyle) -> some View {
        let selected = state.animationStyle == style
        let accent = state.targetPrimary.color
        return Button {
            state.animationStyle = style
        } label: {
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
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
        .help(style.title)
    }

    private var colorRow: some View {
        HStack(spacing: 8) {
            if state.useCustomColors {
                ColorPicker("", selection: colorBinding(\.customPrimary), supportsOpacity: false)
                    .labelsHidden()
                ColorPicker("", selection: colorBinding(\.customSecondary), supportsOpacity: false)
                    .labelsHidden()
            } else {
                colorDot(state.targetPrimary)
                colorDot(state.targetSecondary)
            }
            Spacer()
            pill("paintpalette.fill", isOn: $state.useCustomColors)
        }
    }

    private func colorDot(_ color: RGBColor) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 18, height: 18)
            .shadow(color: color.color.opacity(0.8), radius: 4)
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppState, RGBColor>) -> Binding<Color> {
        Binding(
            get: { state[keyPath: keyPath].color },
            set: { state[keyPath: keyPath] = RGBColor($0) }
        )
    }

    // MARK: Lyrics

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $state.lyricStyle) {
                    ForEach(LyricStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("", selection: $state.lyricFont) {
                    ForEach(LyricFont.allCases.filter { $0 != .sfMono }) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text("A").font(.system(size: 9, weight: .semibold))
                    Slider(value: $state.lyricTextScale, in: 0.6...1.8)
                        .controlSize(.small)
                    Text("A").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            iconSlider("arrow.up.and.down", value: $state.lyricVerticalPosition, range: 0...1)
            pill("Romanize", isOn: $state.romanizeLyrics)
        }
        .card()
    }

    // MARK: Displays

    private var displaysRow: some View {
        let accent = state.targetPrimary.color
        return HStack(spacing: 6) {
            ForEach(state.availableDisplays) { display in
                let enabled = state.activeDisplays.contains(display.id)
                Button {
                    if enabled {
                        state.activeDisplays.remove(display.id)
                    } else {
                        state.activeDisplays.insert(display.id)
                    }
                } label: {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 13))
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(enabled ? accent.opacity(0.16) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(enabled ? accent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: enabled ? 1 : 0.5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(display.name)
            }
        }
    }

    // MARK: Controls

    private func iconSlider(_ symbol: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    /// Compact toggle pill: a text label, or an SF Symbol when the string is a symbol name.
    private func pill(_ label: String, isOn: Binding<Bool>) -> some View {
        let accent = state.targetPrimary.color
        let on = isOn.wrappedValue
        let isSymbol = NSImage(systemSymbolName: label, accessibilityDescription: nil) != nil
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Group {
                if isSymbol {
                    Image(systemName: label).font(.system(size: 11, weight: .medium))
                } else {
                    Text(label).font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? accent.opacity(0.2) : Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(on ? accent.opacity(0.55) : Color.white.opacity(0.1), lineWidth: on ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Banners (only when something needs the user's action)

    private var deniedAppsList: String {
        let apps = state.automationDeniedApps
        guard apps.count > 1 else { return apps.first ?? "" }
        return apps.dropLast().joined(separator: ", ") + " and " + apps[apps.count - 1]
    }

    private var permissionBanner: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Allow \(deniedAppsList)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.yellow)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .card()
    }

    private var audioPermissionBanner: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Audio access", systemImage: "waveform.badge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.yellow)
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let route = state.audioRoute {
                let icon = route.transport == .bluetooth ? "🎧" : "🔊"
                Text("\(icon) -\(route.offsetMilliseconds)ms")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            Spacer()
            Button(updater.status.text.isEmpty ? "Update" : updater.status.text) {
                updater.checkNow()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(updater.status.isBusy)
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 2)
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
