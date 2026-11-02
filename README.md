# EdgeGlow

Ambient screen-edge rim lighting for macOS, colored by Spotify album art and driven by live system audio.

EdgeGlow draws a soft neon glow along the edges of your display (over the menu bar and around the
notch). Colors come from the current Spotify album art. The motion comes from your Mac's actual audio
output: the bass makes the glow pulse and bloom, and the vocals set how fast it chases around the
screen. It lives in the menu bar and never takes clicks.

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

EdgeGlow needs two permissions, both under **System Settings → Privacy & Security**:

1. **Automation → Spotify** gives it the track info and album art.
2. **Screen & System Audio Recording** gives it the system audio. Only audio is analyzed (the video
   stream is 2×2 px and thrown away), and the microphone is never used. macOS applies this grant
   only after a relaunch, so use the **Relaunch** button in the popover. Capture runs only while
   Spotify is playing, so the purple recording indicator goes away when the music stops.

Ad-hoc-signed rebuilds change the app's signature, so macOS may forget both grants after a rebuild.
Sign with a stable identity to avoid that (`SIGN_IDENTITY="EdgeGlow Dev" ./build.sh`, using a
self-signed code-signing certificate). To reset the prompts, run:

```sh
tccutil reset AppleEvents com.jplane6.edgeglow
tccutil reset ScreenCapture com.jplane6.edgeglow
```

## How it works

| File | Role |
| --- | --- |
| `main.swift` | Entry point that runs EdgeGlow as a menu bar (accessory) app |
| `AppDelegate.swift` | Status item (`sparkles.tv`), popover, and wiring |
| `AppState.swift` | Shared observable state and settings persisted in `UserDefaults` |
| `SpotifyBridge.swift` | Playback state and artwork via `NSAppleScript`, Spotify's distributed notification, and a 2 s backup poll |
| `AudioCaptureManager.swift` | ScreenCaptureKit system-audio capture → vDSP FFT → bass and vocal energies |
| `ColorExtractor.swift` | Artwork download/cache; picks vivid primary and secondary colors with 32×32 RGBA hue bucketing |
| `OverlayPanel.swift` | Full-screen, click-through `NSPanel` above the menu bar that follows display changes |
| `GlowOverlayView.swift` | 60 fps `TimelineView` + `Canvas` with a blurred ambient spill, a crisp bezel rim, and an optional notch halo |
| `MenuBarPopoverView.swift` | Dark control panel: now playing, colors, sliders, toggles |

- **Audio engine:** system audio is mixed to mono and run through a 2048-point Hann-windowed FFT about
  50 times a second. Energy in the 20–150 Hz band (bass) and the 300–3000 Hz band (vocals) is
  converted to dB and scaled against a running peak, so loud and quiet tracks both use the full
  range. A fast-attack, smooth-decay envelope then turns each band into a steady 0–1 value.
- **Complex wave:** bass drives stroke thickness, opacity and blur bloom in every animated style.
  Vocal energy drives how fast the Chasing comets move: they glide when nobody is singing and speed
  up on dense vocals. Without audio access, the glow falls back to a gentle breathing animation.
- **Kinetic physics** (popover toggle, on by default; Breathing and Chasing only):
  - *Bounce:* the bezel is a 240-node spring–mass string. Each bass transient plucks it inward at the
    brightest point on the rim, and the ripples travel along the edges and ring down in about a second.
  - *Sparks:* bass and vocal transients fire 3–8 sparks inward from the hot spots. They slow down
    and fade over about a second, with faint constellation lines between nearby sparks.
  - *Impact:* when the bass envelope goes above 0.8, the crisp rim splits into a red copy pushed
    outward and a cyan copy pulled inward, and the glow shakes slightly.
  - When nothing is happening, the edge is drawn as the original rounded rectangle.
- **Animation styles:** *Breathing* is a rotating two-color rim with a kick pulse. *Chasing* sends two
  comet-tail highlights clockwise around the bezel (top → right → bottom → left) at a speed set by
  the vocals. *Solid* is a still gradient that only crossfades when the song changes.
- **Display picker:** choose which connected display gets the glow. If that display is unplugged,
  the glow falls back to the main display and returns when the chosen one is reconnected.
- **Idle glow:** with "Keep Idle Glow When Paused" on, a dimmer, slowly breathing glow stays lit
  while Spotify is paused or closed. Turn it off to fade the overlay out when music stops.
- **No microphone, and no screen pixels are analyzed.** Screen & System Audio Recording permission
  is needed only because ScreenCaptureKit is macOS's API for system audio.
