# EdgeGlow

Ambient screen-edge rim lighting for macOS, synced to Spotify album art and tempo.

EdgeGlow draws a soft neon glow along the edges of your display (over the menu bar and around the
notch). It takes its colors from the current Spotify album art and pulses on the beat. It lives in
the menu bar, never takes clicks, and needs exactly one permission: Automation access to Spotify.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 15+ or the Swift 5.9+ command-line tools
- The Spotify desktop app

## Build & run

```sh
./build.sh          # compile, sign, and launch build/EdgeGlow.app
./build.sh --dmg    # also package build/EdgeGlow.dmg
```

- **VS Code:** `Cmd+Shift+B` runs `./build.sh` (see `.vscode/tasks.json`).
- **Xcode:** open `Package.swift`. Running from Xcode skips the app bundle, so AppleEvents permission
  prompts work most reliably from `./build.sh`.
- **SwiftPM:** `swift build` compiles the same sources.

On first launch with Spotify open, macOS asks for permission for EdgeGlow to control Spotify. If you
dismissed that prompt, turn it back on in **System Settings → Privacy & Security → Automation**.
Every ad-hoc-signed rebuild can invalidate the grant. To get the prompt again, run:

```sh
tccutil reset AppleEvents com.jplane6.edgeglow
```

## How it works

| File | Role |
| --- | --- |
| `main.swift` | Entry point that runs EdgeGlow as a menu bar (accessory) app |
| `AppDelegate.swift` | Status item (`sparkles.tv`), popover, and wiring |
| `AppState.swift` | Shared observable state and settings persisted in `UserDefaults` |
| `SpotifyBridge.swift` | Playback via `NSAppleScript` plus Spotify's distributed notification, a 2 s backup poll, and BPM lookup through Deezer's public API |
| `ColorExtractor.swift` | Artwork download/cache; picks vivid primary and secondary colors with 32×32 RGBA hue bucketing |
| `OverlayPanel.swift` | Full-screen, click-through `NSPanel` above the menu bar that follows display changes |
| `GlowOverlayView.swift` | 60 fps `TimelineView` + `Canvas` with a blurred ambient spill, a crisp bezel rim, and an optional notch halo |
| `MenuBarPopoverView.swift` | Dark control panel: now playing, colors, sliders, toggles |

- **Beat sync:** on each track change EdgeGlow searches `api.deezer.com` for the track, reads its
  `bpm`, and phase-locks a kick-drum envelope (`pow(0.5 + 0.5·sin φ, 2.2)`) to Spotify's playback
  position. If the lookup fails it falls back to 122 BPM, shown as `~122` in the popover.
- **Animation styles:** *Breathing* is a rotating two-color rim with a kick pulse. *Chasing* sends two
  comet-tail highlights clockwise around the bezel (top → right → bottom → left), one lap every
  8 beats. *Solid* is a still gradient that only crossfades when the song changes.
- **Display picker:** choose which connected display gets the glow. If that display is unplugged,
  the glow falls back to the main display and returns when the chosen one is reconnected.
- **Idle glow:** with "Keep Idle Glow When Paused" on, a dimmer, slowly breathing glow stays lit
  while Spotify is paused or closed. Turn it off to fade the overlay out when music stops.
- **No screen recording, microphone, or audio taps** are used.
