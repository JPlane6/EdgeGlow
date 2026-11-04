import AppKit
import Metal
import SwiftUI

/// `EdgeGlow --render-style-previews <dir>`: renders every style to PNG over a bright wallpaper-like
/// backdrop (the worst case for legibility), from a synthetic song full of semantic trigger words with
/// simulated bass and vocal pulses driving the real renderer, camera rig and semantic engine.
@MainActor
enum StylePreviews {
    static let lines = [
        "Driving fast in my car",
        "Crashing through the stars",
        "My heart is on fire",
        "Thunder in the night, we cry in the rain!",
        "Feel the bass shake the sky",
        "Hold me close and never let go",
    ]

    static func song() -> TimedLyrics {
        var words: [TimedWord] = []
        var groups: [[TimedWord]] = []
        var t = 1.0
        for (li, text) in lines.enumerated() {
            var group: [TimedWord] = []
            for token in text.split(separator: " ") {
                let long = token.hasPrefix("fire") || token.hasPrefix("rain")
                let w = TimedWord(id: words.count, text: String(token), start: t, end: t + (long ? 1.1 : 0.4), line: li)
                words.append(w); group.append(w)
                t += long ? 1.15 : 0.46
            }
            groups.append(group)
            t += 0.7
        }
        return TimedLyrics(tier: .interpolated, words: words, groups: groups, source: "preview")
    }

    static func run(outputDir: String, size: CGSize = CGSize(width: 1920, height: 1080)) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        guard let director = LyricsDirector(), let device = GPU.shared.device, let queue = GPU.shared.queue else {
            print("Metal unavailable"); return
        }
        print("semantic lexicon: \(SemanticLexicon.wordCount) words")
        let lyrics = song()
        let theme = LyricTheme(font: .sfRounded, text: .white, highlight: Color(red: 0.30, green: 0.88, blue: 1.0),
                               secondary: Color(red: 1.0, green: 0.36, blue: 0.82), scale: 1)
        func start(_ text: String) -> Double { lyrics.words.first { $0.text.hasPrefix(text) }!.start }
        let captures: [(String, Double)] = [
            ("1-car", start("car") + 0.25), ("2-crashing", start("Crashing") + 0.18), ("3-stars", start("stars") + 0.3),
            ("4-heart", start("heart") + 0.15), ("5-fire", start("fire") + 0.45), ("6-bass", start("bass") + 0.2),
        ]
        for style in LyricStyle.allCases {
            if style.showsIcons { WordVisualResolver.shared.prepare(lyrics) }
            var t = 0.0
            let step = 1.0 / 60
            for (label, at) in captures {
                var image: CGImage?
                while t < at + step {
                    let input = makeInput(lyrics, theme, size, t)
                    let scene = director.advance(input, style: style)
                    t += step
                    let capture = t >= at
                    if capture || Int(t * 60) % 6 == 0 {      // build every 6th frame so the atlas warms up
                        if let img = renderFrame(director, input, style, scene, size, device, queue), capture { image = img }
                    }
                }
                if let image, let out = composite(image, size: size), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
                    let path = "\(outputDir)/\(style.rawValue)-\(label).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                }
            }
        }
    }

    private static func makeInput(_ lyrics: TimedLyrics, _ theme: LyricTheme, _ size: CGSize, _ t: Double) -> SceneInput {
        let beat = 0.5
        let phase = (t / beat).truncatingRemainder(dividingBy: 1)
        let bass = exp(-phase * 5)
        var state = BeatState()
        state.bpm = 120; state.beatPhase = phase; state.beatPulse = bass; state.beatIndex = Int(t / beat)
        state.vocalEnergy = 0.6; state.velocity = 0.5 + 0.4 * sin(t * 3)
        return SceneInput(lyrics: lyrics, pos: t, beat: state, theme: theme, size: size,
                          bass: bass, vocal: 0.5 + 0.3 * sin(t * 2.3), time: t, focusY: 0.5)
    }

    private static func renderFrame(_ director: LyricsDirector, _ input: SceneInput, _ style: LyricStyle, _ scene: Scene3D,
                                    _ size: CGSize, _ device: MTLDevice, _ queue: MTLCommandQueue) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        director.encode(input, style: style, scene: scene, alpha: 1, encoder: enc)
        enc.endEncoding()
        if !device.hasUnifiedMemory, let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Over a bright, busy wallpaper stand-in.
    private static func composite(_ overlay: CGImage, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let colors = [CGColor(red: 0.97, green: 0.94, blue: 0.82, alpha: 1), CGColor(red: 0.66, green: 0.84, blue: 0.98, alpha: 1), CGColor(red: 0.99, green: 0.78, blue: 0.66, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        }
        ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
