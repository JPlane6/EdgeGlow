import AppKit
import SwiftUI

/// `EdgeGlow --render-style-previews <dir> [style ...]`: renders styles to PNG with `ImageRenderer`, from the
/// built-in demo song at several moments, over a dark wallpaper-like backdrop. Shader effects only run
/// inside the app bundle, so stills show the unshaded look.
@MainActor
enum StylePreviews {
    static func run(outputDir: String, styles: [LyricStyle], canvas: CGSize = CGSize(width: 1224, height: 765)) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let song = DemoLyrics.song
        WordVisualResolver.shared.prepare(song)
        // Let the glyph index and embedding warm up so icons resolve.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        func mid(_ line: Int, _ word: Int) -> Double {
            let w = song.groups[line][min(word, song.groups[line].count - 1)]
            return w.start + w.duration * 0.6
        }
        let moments: [(String, Double)] = [
            ("a", mid(0, 3)), ("b", mid(1, 4)), ("c", mid(4, 5)), ("d", mid(8, 2)), ("e", mid(12, 6)),
        ]
        let palette = LyricPalette(text: Color(white: 0.96), highlight: Color(red: 0.37, green: 0.88, blue: 1.0), secondary: Color(red: 0.75, green: 0.55, blue: 1.0))
        let art = previewArtwork()
        let blooms = ArtworkColorSync.extractBlooms(art.cgImage(forProposedRect: nil, context: nil, hints: nil)!).map(\.color)

        for style in styles {
            if style == .appleMap { prewarmMap(song, canvas: canvas, positions: moments.map(\.1)) }
            if style == .appleDesign || style == .appleMoney { prewarmCards(song, style: style, canvas: canvas) }
            for (label, position) in moments {
                let frame = LyricFrame(
                    lyrics: song, position: position, clock: position, canvas: canvas,
                    bandHeight: canvas.height * 0.36, bandCenterY: canvas.height * 0.5,
                    textScale: LyricStage.textScale(user: 1, canvas: canvas),
                    palette: style.usesNativeApple ? .appleNative : palette,
                    font: style.usesNativeApple ? .sfPro : .sfRounded,
                    track: LyricTrack(title: DemoLyrics.title, artist: DemoLyrics.artist, artwork: art, blooms: blooms),
                    shaders: false, locked: false, still: true,
                    // Orbital: one still with the corner Now Playing pill.
                    orbital: style == .orbital ? OrbitalInput(audio: nil, showTrackInfo: label == "e") : nil)
                let view = ZStack {
                    LinearGradient(colors: [Color(hex: "#1D2B44"), Color(hex: "#3A2149"), Color(hex: "#13161C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    LyricSceneView(style: style, frame: frame)
                }
                .frame(width: canvas.width, height: canvas.height)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                let path = "\(outputDir)/\(style.rawValue)-\(label).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
        }
    }

    private static func prewarmMap(_ song: TimedLyrics, canvas: CGSize, positions: [Double]) {
        let legs = AppleMapPlan.build(song)
        let w = min(canvas.width * 0.62, 600 * LyricStage.textScale(user: 1, canvas: canvas))
        let floating = CGSize(width: w, height: min(w * 0.64, canvas.height * 0.8))
        let shots = positions.compactMap { pos -> MapShot? in
            guard let gi = song.cursor(at: pos).index else { return nil }
            return legs[gi].shot(legs[gi].enlarged ? canvas : floating)
        }
        MapSnapshotCache.shared.prewarm(shots, timeout: 12)
    }

    private static func prewarmCards(_ song: TimedLyrics, style: LyricStyle, canvas: CGSize) {
        let s = min(1.6, LyricStage.textScale(user: 1, canvas: canvas))
        var shots: [MapShot] = []
        if style == .appleDesign {
            let frame = LyricFrame(lyrics: song, position: 0, clock: 0, canvas: canvas, bandHeight: 0, bandCenterY: 0, textScale: s,
                                   palette: .appleNative, font: .sfPro, track: LyricTrack(), shaders: false, locked: false)
            let width = min(canvas.width * 0.92, 410 * s)
            for item in AppleDesignPlan.build(song).items {
                if case .map(_, let landmark, _, _) = item.kind {
                    let size = AppleThreadLayout.measure(item.kind, frame: frame, width: width, s: s)
                    shots.append(AppleMapCard.shot(landmark, size: AppleMapCard.mapSize(size, s: s)))
                }
            }
        } else {
            shots = MoneyPlan.build(song).compactMap { $0.mapShot(scale: s) }
        }
        MapSnapshotCache.shared.prewarm(shots, timeout: 12)
    }

    /// A synthetic album cover (gradient + disc) so card styles have artwork to show.
    static func previewArtwork() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { rect in
            let g = NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.42, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.55, green: 0.25, blue: 0.95, alpha: 1),
                                        NSColor(srgbRed: 0.1, green: 0.75, blue: 0.95, alpha: 1)])
            g?.draw(in: rect, angle: -35)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 95, dy: 95)).fill()
            NSColor(srgbRed: 0.12, green: 0.1, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 138, dy: 138)).fill()
            return true
        }
    }
}
