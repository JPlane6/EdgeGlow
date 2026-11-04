import AppKit
import Metal
import MetalKit
import SwiftUI

/// Shared Metal device and runtime shader compilation.
/// Shaders are compiled from source at launch (`makeLibrary(source:)`), so neither an offline
/// Metal toolchain nor a bundled .metallib is required.
final class GPU: @unchecked Sendable {
    static let shared = GPU()
    let device: MTLDevice?
    let queue: MTLCommandQueue?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    var isAvailable: Bool { device != nil && queue != nil }

    func library(source: String) -> MTLLibrary? {
        guard let device else { return nil }
        do { return try device.makeLibrary(source: source, options: nil) }
        catch { fputs("EdgeLyrics: shader compile failed: \(error)\n", stderr); return nil }
    }

    func pipeline(library: MTLLibrary, vertex: String, fragment: String, format: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState? {
        guard let device, let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    static func configure(_ v: MTKView) {
        v.device = shared.device
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColorMake(0, 0, 0, 0)
        v.isPaused = true                    // we draw once per SwiftUI frame (TimelineView-driven)
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = true
        (v.layer as? CAMetalLayer)?.isOpaque = false
        (v.layer as? CAMetalLayer)?.maximumDrawableCount = 2   // double-buffered: one fewer full-band drawable
        v.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Renders `encode` into an offscreen texture and reads it back (used by tests / previews).
    func renderOffscreen(width: Int, height: Int, encode: (MTLRenderCommandEncoder) -> Void) -> CGImage? {
        guard let device, let queue else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc)
        enc.endEncoding()
        if !device.hasUnifiedMemory, let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: tex); blit.endEncoding() }
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Shared full-screen-triangle vertex stage.
let metalCommonSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float hash11(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }
"""

// MARK: - Text rasterisation (CPU → texture) for shader-based styles

enum TextRaster {
    /// Draws coloured word runs, centred and wrapped, into a premultiplied BGRA bitmap texture.
    static func texture(device: MTLDevice, lines: [(runs: [(String, NSColor)], font: NSFont)], size: CGSize, scale: CGFloat) -> MTLTexture? {
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        var blocks: [(NSAttributedString, CGFloat)] = []
        let maxW = size.width * 0.94
        for line in lines {
            let a = NSMutableAttributedString()
            for (i, run) in line.runs.enumerated() {
                a.append(NSAttributedString(string: (i > 0 ? " " : "") + run.0,
                                            attributes: [.font: line.font, .foregroundColor: run.1, .paragraphStyle: para]))
            }
            let r = a.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            blocks.append((a, ceil(r.height)))
        }
        let total = blocks.reduce(0) { $0 + $1.1 } + CGFloat(max(0, blocks.count - 1)) * 8
        var y = (size.height + total) / 2            // CG origin is bottom-left
        for (a, bh) in blocks {
            y -= bh
            a.draw(with: CGRect(x: (size.width - maxW) / 2, y: y, width: maxW, height: bh), options: [.usesLineFragmentOrigin])
            y -= 8
        }
        NSGraphicsContext.restoreGraphicsState()

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }
}

extension NSColor {
    var simd4: SIMD4<Float> {
        let c = usingColorSpace(.sRGB) ?? self
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }
}
