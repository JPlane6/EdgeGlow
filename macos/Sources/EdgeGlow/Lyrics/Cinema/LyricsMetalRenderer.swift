import AppKit
import Metal
import MetalKit
import simd

/// Optical lens parameters for the Fisheye styles (vertex-space barrel distortion).
struct LensParams {
    var center: SIMD2<Float>      // px
    var radii: SIMD2<Float>       // px (ellipse half-axes)
    var k: Float = 0.9
    var magnification: Float = 1.35
    var chroma: Float = 0.07
}

/// The one Metal renderer behind every lyric style. A scene fills a `DrawList` in world space; this class
/// projects it with true perspective division in the vertex shader (plus the optional barrel lens), and
/// draws words from the glyph atlas. Shaders are compiled at runtime from source (`makeLibrary(source:)`),
/// so no offline Metal toolchain is needed.
final class LyricsMetalRenderer {
    struct Vtx {
        var a = V4(0, 0, 0, 0)       // world position, kind
        var b = V4(0, 0, 0, 0)       // ribbon end point, size
        var c = V4(0, 0, 0, 0)       // uv / corner
        var color = V4(1, 1, 1, 1)
        var params = V4(0, 0, 0, 0)  // blur, glow, extra, unused
    }

    struct CamU {
        var right = V4(1, 0, 0, 0), up = V4(0, 1, 0, 0), fwd = V4(0, 0, 1, 0), pos = V4(0, 0, 0, 0)
        var viewport = SIMD2<Float>(1, 1), center = SIMD2<Float>(0.5, 0.5)
        var focal: Float = 1000, time: Float = 0, lensK: Float = 0.9, lensMag: Float = 1.35
        var lensCenter = SIMD2<Float>(0, 0), lensAB = SIMD2<Float>(1, 1)
        var chan = V4(1, 1, 1, 0)    // channel mask, lens on
        var misc = V4(1, 40, 0, 0)   // master alpha, near plane, chroma offset
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vtx { float4 a; float4 b; float4 c; float4 color; float4 params; };
    struct CamU {
        float4 right; float4 up; float4 fwd; float4 pos;
        float2 viewport; float2 center;
        float focal; float time; float lensK; float lensMag;
        float2 lensCenter; float2 lensAB;
        float4 chan; float4 misc;
    };
    struct VOut {
        float4 pos [[position]];
        float2 uv; float2 corner; float2 sp;
        float4 color; float4 params;
        float across;
        float kind [[flat]];
    };
    struct Proj { float2 s; float z; bool ok; };

    Proj project(float3 p, constant CamU& u) {
        float3 v = p - u.pos.xyz;
        float x = dot(v, u.right.xyz), y = dot(v, u.up.xyz), z = dot(v, u.fwd.xyz);
        Proj r;
        r.z = z;
        r.ok = z > u.misc.y;
        float zz = max(z, u.misc.y);
        float2 s = u.center + float2(x, -y) * (u.focal / zz);
        if (u.chan.w > 0.5) {
            // Barrel lens: center magnified, periphery squeezed around the dome (monotonic, so nothing folds back).
            float2 n = (s - u.lensCenter) / u.lensAB;
            float k = u.lensK * (1.0 + u.misc.z);
            n = n * u.lensMag * rsqrt(1.0 + k * dot(n, n));
            s = u.lensCenter + n * u.lensAB;
        }
        r.s = s;
        return r;
    }

    vertex VOut lyricVertex(uint vid [[vertex_id]], constant Vtx* V [[buffer(0)]], constant CamU& u [[buffer(1)]]) {
        Vtx v = V[vid];
        int kind = int(v.a.w + 0.5);
        VOut o;
        o.kind = float(kind);
        o.color = v.color; o.params = v.params;
        o.uv = v.c.xy; o.corner = v.c.zw; o.across = 0.0;

        Proj p0 = project(v.a.xyz, u);
        float2 s = p0.s;
        bool ok = p0.ok;
        if (kind == 1) {
            Proj p1 = project(v.b.xyz, u);
            ok = ok && p1.ok;
            float2 d = p1.s - p0.s;
            float len = max(length(d), 1e-3);
            float2 dir = d / len;
            float2 n = float2(-dir.y, dir.x);
            float w0 = v.b.w * u.focal / max(p0.z, 1.0), w1 = v.b.w * u.focal / max(p1.z, 1.0);
            float endv = v.c.z, side = v.c.w;
            float w = mix(w0, w1, endv);
            s = mix(p0.s, p1.s, endv) + n * side * w * 0.5 + dir * (endv * 2.0 - 1.0) * w * 0.35;
            o.across = side;
            o.uv = float2(endv, 0.0);
        } else if (kind == 2 || kind == 3 || kind == 5 || kind == 6 || kind == 7) {
            float r = v.b.w * u.focal / max(p0.z, 1.0);
            float asp = (kind == 3 && v.params.y > 0.01) ? v.params.y : 1.0;
            s = p0.s + float2(v.c.z * asp, v.c.w) * r;
        }
        o.sp = s;
        float2 ndc = float2(s.x / u.viewport.x * 2.0 - 1.0, 1.0 - s.y / u.viewport.y * 2.0);
        o.pos = ok ? float4(ndc, 0.5, 1.0) : float4(3.0, 3.0, 0.5, 1.0);
        return o;
    }

    fragment float4 lyricFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], texture2d<float> icons [[texture(1)]],
                                  constant CamU& u [[buffer(0)]]) {
        constexpr sampler smp(address::clamp_to_edge, filter::linear);
        float edge = 1.0;
        if (u.chan.w > 0.5) {
            float2 n = (in.sp - u.lensCenter) / u.lensAB;
            float r = length(n);
            if (r > 1.0) discard_fragment();
            edge = 1.0 - smoothstep(0.975, 1.0, r);
        }
        int kind = int(in.kind + 0.5);
        float4 c = in.color;
        float a = 0.0;
        float3 rgb = c.rgb;
        float master = u.misc.x;

        if (kind == 0) {
            float blur = in.params.x;
            if (blur < 0.02) {
                a = tex.sample(smp, in.uv).r;
            } else {
                float2 px = float2(blur * 2.6 / 3072.0);
                a = tex.sample(smp, in.uv).r * 0.36
                  + (tex.sample(smp, in.uv + float2(px.x, 0)).r + tex.sample(smp, in.uv - float2(px.x, 0)).r
                   + tex.sample(smp, in.uv + float2(0, px.y)).r + tex.sample(smp, in.uv - float2(0, px.y)).r) * 0.16;
                a *= 1.0 - 0.25 * blur;
            }
        } else if (kind == 1) {
            float x = abs(in.across);
            float core = exp(-x * x * 5.5);
            float halo = exp(-x * x * 2.0) * in.params.y;
            a = core + halo * 0.55;
            rgb = mix(c.rgb, float3(1.0), core * 0.55);
        } else if (kind == 2) {
            float r = length(in.corner);
            a = pow(saturate(1.0 - r), max(in.params.z, 1.6));
        } else if (kind == 3) {
            float r = length(in.corner);
            float strength = in.params.z;
            a = strength * (1.0 - smoothstep(0.30, 1.0, r));
            rgb = float3(0.0);
        } else if (kind == 4) {
            float4 t = icons.sample(smp, in.uv);
            a = t.a;
            rgb = in.params.z > 0.5 ? (t.a > 0.001 ? t.rgb / t.a : float3(0.0)) : c.rgb;
        } else if (kind == 5) {
            float r = length(in.corner);
            float th = max(in.params.z, 0.02);
            float d = (r - 0.82) / th;
            a = exp(-d * d) * (1.0 - smoothstep(0.82, 1.0, r) * 0.0);
        } else if (kind == 6) {
            float2 q = in.corner;
            float2 q2 = float2(q.x + q.y, q.y - q.x) * 0.7071;
            float cross = exp(-abs(q.x) * 26.0) * exp(-abs(q.y) * 2.4) + exp(-abs(q.y) * 26.0) * exp(-abs(q.x) * 2.4);
            float diag = (exp(-abs(q2.x) * 30.0) * exp(-abs(q2.y) * 4.0) + exp(-abs(q2.y) * 30.0) * exp(-abs(q2.x) * 4.0)) * 0.5;
            a = exp(-length(q) * 7.0) * 0.9 + cross + diag;
            rgb = mix(c.rgb, float3(1.0), 0.45);
        } else if (kind == 8) {
            // Rounded glass panel: params.x = corner radius (fraction of height), params.y = aspect (w/h),
            // params.z = border strength. color.rgb = border/tint, color.a = fill opacity.
            float2 p = (in.uv - 0.5) * float2(in.params.y, 1.0);
            float2 hext = float2(in.params.y, 1.0) * 0.5 - in.params.x;
            float2 q = abs(p) - hext;
            float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.params.x;
            float inside = 1.0 - smoothstep(-0.004, 0.002, d);
            float border = exp(-abs(d) * 160.0) * in.params.z;
            float fillA = c.a * inside;
            float3 fill = float3(0.03, 0.035, 0.05) * fillA;
            float3 outRGB = fill + c.rgb * border * 0.8;
            float outA = max(fillA, border * 0.8);
            return float4(outRGB * u.chan.xyz, outA) * edge * master;
        } else if (kind == 7) {
            float r = length(in.corner);
            float disc = 1.0 - smoothstep(0.94, 1.0, r);
            float ring = smoothstep(0.78, 0.9, r) * (1.0 - smoothstep(0.93, 1.0, r));
            float dark = 0.58 * disc;
            float ringA = ring * c.a;
            float aa = dark + ringA * (1.0 - dark);
            float3 premul = c.rgb * ringA;
            return float4(premul * u.chan.xyz, aa) * edge * master;
        }
        a *= c.a * edge * master;
        // Single-channel chromatic passes carry a third of the coverage each, so the summed alpha stays `a`.
        return float4(rgb * a * u.chan.xyz, a * (u.chan.x + u.chan.y + u.chan.z) * 0.3333);
    }

    // Lens glass: dark backing (phase 0) and bright rim + specular crescent (phase 1).
    struct GOut { float4 pos [[position]]; float2 uv; };
    vertex GOut glassVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        GOut o; o.pos = float4(p * 2.0 - 1.0, 0.5, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    fragment float4 glassFragment(GOut in [[stage_in]], constant CamU& u [[buffer(0)]], constant float4& phase [[buffer(1)]]) {
        float2 sp = in.uv * u.viewport;
        float2 n = (sp - u.lensCenter) / u.lensAB;
        float r = length(n);
        float edge = 1.0 - smoothstep(0.985, 1.0, r);
        if (edge <= 0.0) return float4(0.0);
        float3 hi = phase.yzw;
        if (phase.x < 0.5) {
            float backA = 0.60 + 0.28 * smoothstep(0.35, 1.0, r);
            float3 back = (float3(0.012, 0.016, 0.026) + hi * 0.035) * backA;
            return float4(back, backA) * edge * u.misc.x;
        }
        float rim = smoothstep(0.90, 0.985, r) * (1.0 - smoothstep(0.985, 1.0, r));
        float spec = pow(max(0.0, dot(normalize(n + 1e-4), normalize(float2(-0.62, -0.78)))), 7.0) * smoothstep(0.72, 0.96, r) * 0.45;
        float3 rimColor = mix(hi, float3(1.0), 0.55);
        float a = rim * 0.55 + spec;
        return float4(rimColor * a, a) * u.misc.x;
    }
    """

    private let gpu = GPU.shared
    let atlas: GlyphAtlas
    private var alphaPipe: MTLRenderPipelineState?
    private var addPipe: MTLRenderPipelineState?
    private var glassPipe: MTLRenderPipelineState?
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    private let capacity = 36_000      // vertices per frame
    private let sampler: MTLSamplerState?

    var isReady: Bool { alphaPipe != nil && addPipe != nil }

    init?() {
        guard let device = GPU.shared.device, let atlas = GlyphAtlas(device: device) else { return nil }
        self.atlas = atlas
        buffers = (0..<2).compactMap { _ in device.makeBuffer(length: 36_000 * MemoryLayout<Vtx>.stride, options: .storageModeShared) }
        guard buffers.count == 2 else { return nil }
        sampler = nil
        guard let lib = gpu.library(source: Self.source) else { return nil }
        alphaPipe = Self.makePipeline(device, lib, "lyricVertex", "lyricFragment", additive: false)
        addPipe = Self.makePipeline(device, lib, "lyricVertex", "lyricFragment", additive: true)
        glassPipe = Self.makePipeline(device, lib, "glassVertex", "glassFragment", additive: false)
    }

    private static func makePipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ vertex: String, _ fragment: String, additive: Bool) -> MTLRenderPipelineState? {
        guard let v = lib.makeFunction(name: vertex), let f = lib.makeFunction(name: fragment) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f
        let att = d.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: d) }
        catch { fputs("EdgeGlow: pipeline failed: \(error)\n", stderr); return nil }
    }

    // MARK: Emission

    private var staging: [Vtx] = []
    private struct Range { var start = 0, count = 0 }

    private func emitQuad(_ item: DrawItem, tess: (Int, Int)) {
        let kind = item.kind.rawValue
        func vtx(_ p: V3, _ u: Float, _ v: Float) -> Vtx {
            var x = Vtx()
            x.a = V4(p.x, p.y, p.z, kind)
            x.c = V4(u, v, 0, 0)
            x.color = item.color
            x.params = V4(item.blur, item.glow, item.extra, item.wave.w)
            return x
        }
        let (c0, c1, c2, c3) = item.corners
        var (nx, ny) = tess
        let waving = item.wave.x > 0
        if waving { ny = max(ny, 8) }
        let uv = item.uv
        let across = simd_normalize(c1 - c0)
        for j in 0..<ny {
            for i in 0..<nx {
                func at(_ ii: Int, _ jj: Int) -> Vtx {
                    let s = Float(ii) / Float(nx), t = Float(jj) / Float(ny)
                    let top = c0 + (c1 - c0) * s, bottom = c3 + (c2 - c3) * s
                    var p = top + (bottom - top) * t
                    if waving { p += across * item.wave.x * sin(t * item.wave.y + item.wave.z) }
                    return vtx(p, uv.x + (uv.z - uv.x) * s, uv.y + (uv.w - uv.y) * t)
                }
                let a = at(i, j), b = at(i + 1, j), c = at(i + 1, j + 1), d = at(i, j + 1)
                staging.append(contentsOf: [a, b, c, a, c, d])
            }
        }
    }

    private func emitRibbon(_ item: DrawItem) {
        func vtx(_ endv: Float, _ side: Float) -> Vtx {
            var x = Vtx()
            x.a = V4(item.corners.0.x, item.corners.0.y, item.corners.0.z, DrawKind.ribbon.rawValue)
            x.b = V4(item.end.x, item.end.y, item.end.z, item.size)
            x.c = V4(0, 0, endv, side)
            x.color = item.color
            x.params = V4(0, item.glow, 0, 0)
            return x
        }
        let a = vtx(0, -1), b = vtx(0, 1), c = vtx(1, 1), d = vtx(1, -1)
        staging.append(contentsOf: [a, b, c, a, c, d])
    }

    private func emitSprite(_ item: DrawItem) {
        func vtx(_ cx: Float, _ cy: Float) -> Vtx {
            var x = Vtx()
            x.a = V4(item.corners.0.x, item.corners.0.y, item.corners.0.z, item.kind.rawValue)
            x.b = V4(0, 0, 0, item.size)
            x.c = V4(0, 0, cx, cy)
            x.color = item.color
            x.params = V4(0, item.glow, item.extra, 0)
            return x
        }
        let a = vtx(-1, -1), b = vtx(1, -1), c = vtx(1, 1), d = vtx(-1, 1)
        staging.append(contentsOf: [a, b, c, a, c, d])
    }

    // MARK: Encode

    /// Encodes one frame into `encoder` (target already cleared by the pass descriptor).
    func encode(list: DrawList, camera: CameraFrame, viewport: SIMD2<Float>, lens: LensParams?, highlight: V3,
                time: Float, alpha: Float, encoder: MTLRenderCommandEncoder) {
        guard let alphaPipe, let addPipe else { return }
        staging.removeAll(keepingCapacity: true)

        var cam = CamU()
        cam.right = V4(camera.right, 0); cam.up = V4(camera.up, 0); cam.fwd = V4(camera.forward, 0); cam.pos = V4(camera.position, 0)
        cam.viewport = viewport; cam.center = viewport * 0.5
        cam.focal = camera.focal; cam.time = time
        cam.misc = V4(alpha, 40, 0, 0)
        if let lens {
            cam.chan = V4(1, 1, 1, 1)
            cam.lensK = lens.k; cam.lensMag = lens.magnification
            cam.lensCenter = lens.center; cam.lensAB = lens.radii
        }
        let tess = lens == nil ? (1, 1) : (6, 3)

        // Group, sort and emit.
        var ranges: [DrawLayer: Range] = [:]
        for layer in [DrawLayer.back, .body, .glow, .top] {
            let start = staging.count
            var items = list.items.filter { $0.layer == layer }
            if layer == .body || layer == .back { items.sort { $0.depth > $1.depth } }
            for item in items {
                switch item.kind {
                case .text, .icon, .panel: emitQuad(item, tess: tess)
                case .ribbon: emitRibbon(item)
                default: emitSprite(item)
                }
            }
            ranges[layer] = Range(start: start, count: staging.count - start)
        }
        guard staging.count <= capacity else { return }

        let buffer = buffers[bufferIndex % buffers.count]
        bufferIndex += 1
        staging.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer.contents(), base, raw.count) }
        }

        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(viewport.x), height: Double(viewport.y), znear: 0, zfar: 1))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas.textTexture, index: 0)
        encoder.setFragmentTexture(atlas.iconTexture, index: 1)

        func draw(_ layer: DrawLayer, pipe: MTLRenderPipelineState, camera uniforms: CamU) {
            guard let r = ranges[layer], r.count > 0 else { return }
            encoder.setRenderPipelineState(pipe)
            var u = uniforms
            encoder.setVertexBytes(&u, length: MemoryLayout<CamU>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CamU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: r.start, vertexCount: r.count)
        }
        func glass(_ phase: Float) {
            guard let glassPipe else { return }
            encoder.setRenderPipelineState(glassPipe)
            var u = cam
            var p = V4(phase, highlight.x, highlight.y, highlight.z)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CamU>.stride, index: 0)
            encoder.setFragmentBytes(&p, length: MemoryLayout<V4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if lens != nil { glass(0) }
        draw(.back, pipe: alphaPipe, camera: cam)
        if let lens {
            // Chromatic refraction: red, green and blue are drawn additively through slightly different lenses.
            for (mask, offset) in [(V4(1, 0, 0, 1), -lens.chroma), (V4(0, 1, 0, 1), 0), (V4(0, 0, 1, 1), lens.chroma)] {
                var c = cam
                c.chan = mask; c.misc.z = offset
                draw(.body, pipe: addPipe, camera: c)
            }
        } else {
            draw(.body, pipe: alphaPipe, camera: cam)
        }
        draw(.glow, pipe: addPipe, camera: cam)
        if lens != nil { glass(1) }
        draw(.top, pipe: alphaPipe, camera: cam)
    }
}
