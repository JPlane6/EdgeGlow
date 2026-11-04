import AppKit
import Metal

/// One shared texture atlas for every word, code token and icon the 3D styles draw. Words are rasterized
/// once (CoreText → 8-bit coverage) into a single R8 atlas and drawn as perspective-projected quads, so the
/// renderer needs no per-frame text rasterization and no offscreen textures.
final class GlyphAtlas {
    struct Entry {
        /// uv rectangle (u0, v0, u1, v1) of the glyph box, padding excluded.
        var uv: SIMD4<Float>
        /// Size of the glyph box in raster pixels.
        var size: SIMD2<Float>
    }

    static let rasterSize: CGFloat = 168
    private static let textSide = 3072
    private static let iconSide = 1024
    private static let pad = 4

    let device: MTLDevice
    let textTexture: MTLTexture
    let iconTexture: MTLTexture

    private var textEntries: [String: Entry] = [:]
    private var iconEntries: [String: Entry] = [:]
    private var textShelf = Shelf(side: textSide)
    private var iconShelf = Shelf(side: iconSide)

    private struct Shelf {
        let side: Int
        var x = 0, y = 0, rowHeight = 0
        init(side: Int) { self.side = side }
        mutating func place(_ w: Int, _ h: Int) -> (Int, Int)? {
            if x + w > side { x = 0; y += rowHeight; rowHeight = 0 }
            guard y + h <= side else { return nil }
            defer { x += w; rowHeight = max(rowHeight, h) }
            return (x, y)
        }
        mutating func reset() { x = 0; y = 0; rowHeight = 0 }
    }

    init?(device: MTLDevice) {
        self.device = device
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.textSide, height: Self.textSide, mipmapped: false)
        t.usage = .shaderRead
        let i = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.iconSide, height: Self.iconSide, mipmapped: false)
        i.usage = .shaderRead
        guard let tt = device.makeTexture(descriptor: t), let it = device.makeTexture(descriptor: i) else { return nil }
        textTexture = tt
        iconTexture = it
    }

    // MARK: Text

    func text(_ string: String, font: LyricFont, mono: Bool = false) -> Entry? {
        let key = "\(mono ? "m" : font.rawValue)|\(string)"
        if let hit = textEntries[key] { return hit }
        let nsFont: NSFont = mono
            ? (NSFont(name: "JetBrainsMono-Regular", size: Self.rasterSize * 0.8) ?? NSFont.monospacedSystemFont(ofSize: Self.rasterSize * 0.8, weight: .medium))
            : font.nsFont(size: Self.rasterSize)
        // Tight -0.03em tracking: the Verci-style headline setting.
        let attributed = NSAttributedString(string: string, attributes: [.font: nsFont, .foregroundColor: NSColor.white, .kern: -0.03 * nsFont.pointSize])
        let size = attributed.size()
        let pad = Self.pad
        let w = Int(ceil(size.width)) + pad * 2, h = Int(ceil(size.height)) + pad * 2
        guard w < Self.textSide, h < 640 else { return nil }
        if textShelf.place(w, h) == nil { resetText() }
        guard let origin = textShelf.place(w, h) else { return nil }

        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldSmoothFonts(false)
            ctx.setShouldAntialias(true)
            ctx.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            attributed.draw(at: CGPoint(x: CGFloat(pad), y: CGFloat(pad)))
            NSGraphicsContext.restoreGraphicsState()
        }
        textTexture.replace(region: MTLRegionMake2D(origin.0, origin.1, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w)
        let s = Float(Self.textSide)
        let entry = Entry(uv: SIMD4(Float(origin.0 + pad) / s, Float(origin.1 + pad) / s,
                                    Float(origin.0 + w - pad) / s, Float(origin.1 + h - pad) / s),
                          size: SIMD2(Float(w - pad * 2), Float(h - pad * 2)))
        textEntries[key] = entry
        return entry
    }

    /// Full reset when the atlas fills up (long sessions); entries re-rasterize on demand.
    private func resetText() {
        textEntries.removeAll(); textShelf.reset()
    }

    // MARK: Icons

    func icon(_ visual: WordVisual) -> Entry? {
        let key: String
        switch visual {
        case .symbol(let n): key = "s|\(n)"
        case .emoji(let e): key = "e|\(e)"
        }
        if let hit = iconEntries[key] { return hit }
        let side = 128, pad = 4, cell = side + pad * 2
        if iconShelf.place(cell, cell) == nil { iconEntries.removeAll(); iconShelf.reset() }
        guard let origin = iconShelf.place(cell, cell) else { return nil }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        var bytes = [UInt8](repeating: 0, count: cell * cell * 4)
        var drawn = false
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cell, height: cell, bitsPerComponent: 8, bytesPerRow: cell * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let box = NSRect(x: pad, y: pad, width: side, height: side)
            switch visual {
            case .symbol(let name):
                guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { break }
                let config = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.8, weight: .bold)
                let img = base.withSymbolConfiguration(config) ?? base
                let white = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceIn)
                    return true
                }
                let ratio = min(CGFloat(side) * 0.9 / max(white.size.width, 1), CGFloat(side) * 0.9 / max(white.size.height, 1))
                let target = NSSize(width: white.size.width * ratio, height: white.size.height * ratio)
                white.draw(in: NSRect(x: box.midX - target.width / 2, y: box.midY - target.height / 2, width: target.width, height: target.height))
                drawn = true
            case .emoji(let e):
                let str = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(side) * 0.78)])
                let sz = str.size()
                str.draw(at: CGPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2))
                drawn = true
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard drawn else { return nil }
        iconTexture.replace(region: MTLRegionMake2D(origin.0, origin.1, cell, cell), mipmapLevel: 0, withBytes: bytes, bytesPerRow: cell * 4)
        let s = Float(Self.iconSide)
        let entry = Entry(uv: SIMD4(Float(origin.0 + pad) / s, Float(origin.1 + pad) / s, Float(origin.0 + pad + side) / s, Float(origin.1 + pad + side) / s),
                          size: SIMD2(Float(side), Float(side)))
        iconEntries[key] = entry
        return entry
    }
}
