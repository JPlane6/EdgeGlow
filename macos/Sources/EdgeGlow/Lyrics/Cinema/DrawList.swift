import Foundation
import simd

typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>

/// What a draw item looks like to the fragment shader.
enum DrawKind: Float {
    case text = 0, ribbon = 1, glow = 2, plume = 3, icon = 4, ring = 5, flare = 6, chip = 7, panel = 8
}

/// Which pass an item is drawn in.
enum DrawLayer {
    /// Alpha-blended backdrops (dark plumes, glass).
    case back
    /// Depth-sorted words and icons. With the lens on, drawn as three chromatic channel passes.
    case body
    /// Additive light: glows, filaments, particles, flares.
    case glow
    /// Alpha-blended overlays (lens rim).
    case top
}

/// One drawable: a (possibly tessellated) quad in world space or a screen-space sprite/ribbon.
struct DrawItem {
    var kind: DrawKind
    var layer: DrawLayer
    /// Quad corners in world space: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
    var corners: (V3, V3, V3, V3)
    /// Second endpoint for ribbons.
    var end = V3(0, 0, 0)
    /// Texture rectangle (u0, v0, u1, v1).
    var uv = V4(0, 0, 1, 1)
    var color = V4(1, 1, 1, 1)
    /// Ribbon width / sprite radius in world units.
    var size: Float = 0
    var blur: Float = 0
    var glow: Float = 0
    /// Free parameter: ring thickness, flare spin, icon raw-color flag, plume strength…
    var extra: Float = 0
    var depth: Float = 0
    /// Heat-shimmer wave on a quad: (amplitude in world units, frequency, phase, unused).
    var wave = V4(0, 0, 0, 0)
}

/// Everything a scene wants on screen this frame. The renderer sorts and tessellates it.
final class DrawList {
    private(set) var items: [DrawItem] = []

    func reset() { items.removeAll(keepingCapacity: true) }

    /// A textured quad (word or code token) centered at `center`, spanned by `right`/`up` half-extent vectors.
    func quad(_ kind: DrawKind, uv: V4, center: V3, right: V3, up: V3, color: V4, blur: Float = 0,
              extra: Float = 0, glow: Float = 0, wave: V4 = V4(0, 0, 0, 0), layer: DrawLayer = .body, camera: CameraFrame) {
        let tl = center - right + up, tr = center + right + up, br = center + right - up, bl = center - right - up
        var item = DrawItem(kind: kind, layer: layer, corners: (tl, tr, br, bl))
        item.uv = uv; item.color = color; item.blur = blur; item.extra = extra; item.glow = glow; item.wave = wave
        item.depth = camera.depth(of: center)
        item.color.w *= Self.nearFade(item.depth)
        items.append(item)
    }

    /// A glowing ribbon between two world points; `width` is the full width in world units (soft edges).
    func ribbon(from a: V3, to b: V3, width: Float, color: V4, glow: Float = 0.6, layer: DrawLayer = .glow, camera: CameraFrame) {
        var item = DrawItem(kind: .ribbon, layer: layer, corners: (a, a, a, a))
        item.end = b; item.size = width; item.color = color; item.glow = glow
        item.depth = camera.depth(of: (a + b) * 0.5)
        item.color.w *= Self.nearFade(item.depth)
        items.append(item)
    }

    /// A screen-facing sprite (glow, plume, ring, flare) with a world-unit radius.
    func sprite(_ kind: DrawKind, at p: V3, radius: Float, color: V4, extra: Float = 0, stretch: Float = 0, layer: DrawLayer = .glow, camera: CameraFrame) {
        var item = DrawItem(kind: kind, layer: layer, corners: (p, p, p, p))
        item.size = radius; item.color = color; item.extra = extra; item.glow = stretch
        item.depth = camera.depth(of: p)
        item.color.w *= Self.nearFade(item.depth)
        items.append(item)
    }

    /// Things that pass close to the lens dissolve instead of filling the frame.
    static func nearFade(_ depth: Float) -> Float {
        let t = min(1, max(0, (depth - 140) / 300))
        return t * t * (3 - 2 * t)
    }
}
