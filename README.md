# EdgeGlow

Ambient screen-edge rim lighting for macOS, colored by album art and driven by live system audio.

EdgeGlow draws a soft neon glow along the edges of your display (over the menu bar and around the
notch). Colors come from the album art of whatever is playing in Spotify, Apple Music or a YouTube
Music tab. The motion comes from your Mac's actual audio output, from any app: the bass makes the glow pulse and bloom, and the vocals set how fast it chases around the
screen. It lives in the menu bar and never takes clicks.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 15+ or the Swift 5.9+ command-line tools
- Optional: Spotify, Apple Music, or YouTube Music in Safari or a Chromium browser for track info and
  album colors. Any other app's sound still drives the glow.

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

1. **Automation** for Spotify, Music, and your browser gives it the track info and album art. Each app
   is asked the first time it's needed. Browsers are only asked while audio is playing and neither
   Spotify nor Music is.
2. **Screen & System Audio Recording** gives it the system audio. Only audio is analyzed (the video
   stream is 2×2 px and thrown away), and the microphone is never used. macOS applies this grant
   only after a relaunch, so use the **Relaunch** button in the popover. Capture runs while the glow
   is on for at least one display, regardless of which app is playing, and pauses while the screens
   sleep. So the purple recording indicator stays on while EdgeGlow is active.

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
| `MediaModel.swift` | Platform-neutral `MediaSource`, `NowPlayingInfo`, `LevelSource` and the continuous `PlaybackClock` |
| `MediaBridge.swift` | AppleScript providers (Spotify, Apple Music, YouTube Music tabs), source priority, artwork lookup, and player notifications plus a 2 s backup poll |
| `CloudSync.swift` | Public metadata lookups (iTunes/Deezer artwork, Deezer BPM, LRCLIB synced lyrics), the LRC parser, and the beat/lyric synthesizer |
| `AudioCaptureManager.swift` | ScreenCaptureKit system-audio capture in any PCM format → vDSP FFT with rolling auto-gain → bass and vocal energies; output-route listener; live/Cloud Sync handoff |
| `ColorExtractor.swift` | Artwork download/cache; picks vivid primary and secondary colors with 32×32 RGBA hue bucketing |
| `OverlayPanel.swift` | Full-screen, click-through `NSPanel` above the menu bar |
| `OverlayWindowManager.swift` | One overlay panel (and renderer) per enabled display; adds and removes panels as displays are toggled, plugged in or unplugged |
| `GlowOverlayView.swift` | 60 fps `TimelineView` + `Canvas` with a blurred ambient spill, a crisp bezel rim that wraps the notch automatically, comets and sparks |
| `MenuBarPopoverView.swift` | Dark control panel: now playing, colors, styles, displays, sliders, toggles |

- **Sources:** Spotify, then Apple Music, then any system audio (named after a YouTube Music tab when
  one is open). A paused native player still shows when nothing else is playing. Apple Music and
  YouTube Music don't expose artwork URLs, so the cover is looked up on the iTunes Search API, with
  Deezer as a fallback. Plain system audio uses the default palette.
- **Audio engine:** system audio arrives in whatever format the device uses: any sample rate, Float32
  or Int16/Int32 PCM, interleaved or not. It is mixed to mono and run through a Hann-windowed FFT
  (2048 points, or 4096 above 64 kHz) about 50 times a second. Energy in the 20–150 Hz band (bass)
  and the 300–3000 Hz band (vocals) is divided by its own 4-second rolling maximum (auto-gain, with a
  -60 dBFS floor and a -78 dBFS gate), so local peaks reach 1.0 at any volume. A fast-attack,
  smooth-decay envelope then turns each band into a steady 0–1 value.
- **Speakers:** switching the default output (Bluetooth, AirPlay, USB) restarts capture on the new
  route after a 350 ms debounce.
- **Cloud Sync** (badge shows **SYNC**): Spotify Connect, or AirPlay sent straight from the player,
  leaves the Mac silent. When Spotify or Music reports playback but the Mac has stayed below -72 dBFS
  for 1.5 s, the glow is driven from the track instead:
  - *Bass* is a kick on every beat at the Deezer BPM (122 if unknown), with an accented downbeat.
  - *Vocals* follow the active LRCLIB synced-lyric line's syllable rate: about 0.4 for slow lines,
    0.85–1.0 for fast ones, decaying to 0.08 between lines. Without synced lyrics they swell over
    4-bar phrases.
  - The track position comes from the player poll, extrapolated continuously in between.
  - As soon as local audio rises above -68 dBFS, the live FFT takes over again.
  - Beat phase assumes the first beat falls at 0:00, so it can be offset on tracks with a pickup or
    intro. Track and artist names are sent to iTunes, Deezer and LRCLIB, and nothing else is.
- **Complex wave:** bass drives stroke thickness, opacity and blur bloom in every animated style.
  Vocal energy drives how fast the Chasing and Symmetry comets move: they glide when nobody is singing and speed
  up on dense vocals. With no audio and no Cloud Sync, the glow falls back to a gentle breathing animation.
- **Kinetic physics** (popover toggle, on by default; always on in Sparks Only):
  - *Bounce:* the bezel is a 240-node spring–mass string. Each bass transient plucks it inward at the
    brightest point on the rim, and the ripples travel along the edges and ring down in about a second.
  - *Sparks:* bass and vocal transients fire 3–8 sparks inward from the hot spots. They slow down
    and fade over about a second, with faint constellation lines between nearby sparks.
  - *Impact:* when the bass envelope goes above 0.8, the crisp rim splits into a red copy pushed
    outward and a cyan copy pulled inward, and the glow shakes slightly.
  - When nothing is happening, the edge is drawn as the original rounded rectangle.
- **Animation styles:**
  - *Breathing:* a rotating two-color rim with a kick pulse.
  - *Chasing:* two comets, each a white-hot head fading into a tail, race clockwise around an
    otherwise dark bezel. Vocals speed them up and the bass thickens and blooms them. The
    "Comet Length" slider sets the tail length as a share of the perimeter.
  - *Symmetry:* a mirrored pair of comets leaves top-center, runs down the left and right edges
    together and merges in a bloom at bottom-center (with a spark burst when kinetic physics is on).
    At the moment they merge, the direction flips: the next pair launches from bottom-center and climbs
    both edges to merge at top-center, and it keeps alternating from there. Each new pair rises out
    of the previous pair's draining tails. Their speed follows the vocals.
  - *Sparks Only:* no rim at all. The only thing drawn is the sparks thrown inward from the dark edges
    on hard bass transients.
- **Notch:** each display's renderer checks its own screen. On a built-in panel with a camera notch
  (top safe-area inset over 30 pt) the glow path wraps around the notch; external displays get the
  plain rounded rectangle.
- **Multiple displays:** every connected display is listed in the popover with a checkmark. Turn on
  any combination, from none (glow hidden) to all of them at once. Each enabled display gets its own
  overlay. An enabled display that is unplugged keeps its setting, and its glow comes back when it
  is reconnected.
- **Idle glow:** with "Keep Idle Glow When Paused" on, a dimmer, slowly breathing glow stays lit
  while nothing is playing. Turn it off to fade the overlay out when music stops.
- **No microphone, and no screen pixels are analyzed.** Screen & System Audio Recording permission
  is needed only because ScreenCaptureKit is macOS's API for system audio.
