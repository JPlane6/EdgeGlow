import AppKit
import SwiftUI

/// Root view of a lyrics overlay panel. While lyrics are loaded and music plays (or the demo runs) it
/// drives the selected scene from a `TimelineView(.animation)`, extrapolating the playhead every frame.
/// Otherwise it renders nothing, so an idle overlay costs nothing.
struct LyricStage: View {
    @ObservedObject var model: LyricsModel
    @ObservedObject var state: AppState
    @ObservedObject var art: ArtworkColorSync

    var body: some View {
        GeometryReader { geo in
            if let source = model.activeSource(), !source.lyrics.isEmpty {
                TimelineView(.animation(minimumInterval: nil, paused: false)) { context in
                    LyricSceneView(style: state.lyricStyle, frame: makeFrame(source, date: context.date, canvas: geo.size))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func makeFrame(_ source: LyricsModel.ActiveSource, date: Date, canvas: CGSize) -> LyricFrame {
        let style = state.lyricStyle
        var position = source.anchor.position(at: date, lyricDelay: source.delay)
        if let loop = source.loop { position = position.truncatingRemainder(dividingBy: loop) }
        return LyricFrame(
            lyrics: source.lyrics,
            position: position,
            clock: LyricClock.seconds(date),
            canvas: canvas,
            bandHeight: canvas.height * 0.36,
            bandCenterY: canvas.height * (0.2 + 0.6 * CGFloat(state.lyricVerticalPosition)),
            textScale: Self.textScale(user: state.lyricTextScale, canvas: canvas),
            palette: style.usesNativeApple ? .appleNative : art.lyricPalette,
            font: style.usesNativeApple ? .sfPro : state.lyricFont,
            track: LyricTrack(title: source.title, artist: source.artist, artwork: art.artwork, blooms: art.blooms),
            shaders: true,
            locked: state.screenLocked,
            audio: LyricAudioFollower.shared.sample(
                date: date, levels: state.audioLevels, source: state.levelSource,
                position: position, clock: LyricClock.seconds(date), bpm: state.trackBPM))
    }

    /// The user's size slider times a screen factor (1.0 on a 13" laptop, larger on big displays).
    static func textScale(user: Double, canvas: CGSize) -> CGFloat {
        CGFloat(user) * min(1.6, max(0.85, canvas.height / 765))
    }
}

/// Switches on the style. Each scene is a pure function of its `LyricFrame`.
struct LyricSceneView: View {
    let style: LyricStyle
    let frame: LyricFrame

    var body: some View {
        Group {
            switch style {
            case .ship: ShipScene(frame: frame)
            case .fisheye: FisheyeScene(frame: frame, withIcons: false)
            case .visual: VisualScene(frame: frame)
            case .fisheyeVisual: FisheyeScene(frame: frame, withIcons: true)
            case .flashbang: FlashbangScene(frame: frame, withIcons: false)
            case .flashbangVisual: FlashbangScene(frame: frame, withIcons: true)
            case .branches: BranchesScene(frame: frame)
            case .web: WebScene(frame: frame)
            case .constellation: ConstellationScene(frame: frame)
            case .appleDesign: AppleDesignScene(frame: frame)
            case .appleMoney: AppleMoneyScene(frame: frame)
            case .appleMap: AppleMapScene(frame: frame)
            case .appleNotify: AppleNotifyScene(frame: frame)
            case .orbital: OrbitalScene(frame: frame)
            }
        }
        .id(style)
        .frame(width: frame.canvas.width, height: frame.canvas.height)
        .environment(\.colorScheme, .dark)
    }
}
