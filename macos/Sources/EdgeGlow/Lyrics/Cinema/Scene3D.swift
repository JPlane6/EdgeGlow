import AppKit
import simd

/// A style: lays lyrics out in 3D world space, drives the cinematic camera, and fills a `DrawList`.
class Scene3D {
    let icons: Bool
    let camera: CinematicCamera3D
    var engine = SemanticKineticEngine()
    private(set) var primed = false
    /// Optical lens (Fisheye styles).
    var usesLens: Bool { false }

    init(icons: Bool, seed: Int = 7) {
        self.icons = icons
        camera = CinematicCamera3D(seed: seed)
    }

    func reset() { camera.reset(); primed = false; reset2() }
    func reset2() {}
    func markPrimed() { primed = true }

    func update(_ input: SceneInput, dt: Double) {}
    func build(_ input: SceneInput, list: DrawList, atlas: GlyphAtlas, frame: CameraFrame) {}

    // MARK: Colors

    func highlight(_ input: SceneInput) -> V4 { Self.vec(input.theme.highlight) }
    func secondary(_ input: SceneInput) -> V4 { Self.vec(input.theme.secondary) }

    static func vec(_ color: SwiftUI.Color) -> V4 {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return V4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
    }

    // MARK: Helpers

    /// World units per screen pixel at `depth`.
    func perPixel(_ depth: Float, _ frame: CameraFrame) -> Float { depth / frame.focal }

    /// Adds a word quad. `height` is the font size in world units. Returns the quad's world width.
    @discardableResult
    func drawWord(_ text: String, at center: V3, height: Float, right: V3, up: V3, color: V4, mod: WordMod = WordMod(),
              mono: Bool = false, blur: Float = 0, layer: DrawLayer = .body, atlas: GlyphAtlas, input: SceneInput,
              list: DrawList, frame: CameraFrame) -> Float {
        guard let entry = atlas.text(text, font: input.theme.font, mono: mono) else { return 0 }
        let s = height / Float(GlyphAtlas.rasterSize) * (mono ? 1.25 : 1)
        let w = entry.size.x * s, h = entry.size.y * s
        var r = right, u = up
        if mod.roll != 0 {
            let c = cos(mod.roll), sn = sin(mod.roll)
            r = right * c + up * sn; u = up * c - right * sn
        }
        let halfW = w * 0.5 * mod.scale.x * mod.tracking, halfH = h * 0.5 * mod.scale.y
        let center = center + right * (mod.offset.x * height) + up * (mod.offset.y * height) + V3(0, 0, mod.offset.z * height)
        let wave = mod.shimmer > 0 ? V4(mod.shimmer * height, 7.0, Float(input.time) * 7, 0) : V4(0, 0, 0, 0)

        if mod.glow.w > 0.01 {
            list.sprite(.glow, at: center, radius: max(halfW * 1.1, halfH * 2.2), color: V4(mod.glow.x, mod.glow.y, mod.glow.z, min(1, mod.glow.w)), extra: 2.2, camera: frame)
        }
        if mod.split > 0.001 {
            // Chromatic split: red and cyan copies slide apart on either side of the word.
            let d = r * (mod.split * height)
            list.quad(.text, uv: entry.uv, center: center - d, right: r * halfW, up: u * halfH, color: V4(1, 0.1, 0.25, color.w * 0.8), blur: blur, layer: .glow, camera: frame)
            list.quad(.text, uv: entry.uv, center: center + d, right: r * halfW, up: u * halfH, color: V4(0.1, 0.9, 1, color.w * 0.8), blur: blur, layer: .glow, camera: frame)
        }
        list.quad(.text, uv: entry.uv, center: center, right: r * halfW, up: u * halfH, color: color, blur: blur, extra: 0, wave: wave, layer: layer, camera: frame)
        return w
    }

    /// An SF Symbol / emoji prop with a dark chip behind it.
    func prop(_ visual: WordVisual, at center: V3, size: Float, right: V3, up: V3, mod: PropMod, tint: V4,
              atlas: GlyphAtlas, list: DrawList, frame: CameraFrame) {
        guard mod.alpha > 0.01, let entry = atlas.icon(visual) else { return }
        let raw: Float
        if case .emoji = visual { raw = 1 } else { raw = 0 }
        let sz = size * mod.scale
        let c = center + right * (mod.offset.x * size) + up * (mod.offset.y * size)
        var r = right, u = up
        if mod.roll != 0 {
            let cs = cos(mod.roll), sn = sin(mod.roll)
            r = right * cs + up * sn; u = up * cs - right * sn
        }
        list.sprite(.glow, at: c, radius: sz * 0.9, color: V4(tint.x, tint.y, tint.z, 0.35 * mod.alpha), extra: 2.2, camera: frame)
        list.quad(.icon, uv: entry.uv, center: c, right: r * sz * 0.38, up: u * sz * 0.38, color: V4(tint.x, tint.y, tint.z, mod.alpha), extra: raw, camera: frame)
    }

    /// Icon for a word: its semantic glyph, or the shared visual resolver as a fallback.
    func visual(for index: Int, input: SceneInput) -> WordVisual? {
        let tags = engine.tags
        if tags.indices.contains(index), let symbol = tags[index].symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return .symbol(symbol)
        }
        return WordVisualResolver.shared.visual(for: input.lyrics.words[index].text)
    }

    func hash(_ i: Int) -> Float { Float(CanvasKitHash.hash(i)) }
}

import SwiftUI
