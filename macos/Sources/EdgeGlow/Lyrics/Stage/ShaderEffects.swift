import SwiftUI

/// Whether `Shaders.metal` was compiled into the app bundle (`Contents/Resources/default.metallib`).
/// Builds made without a Metal toolchain skip it, and every shader effect is then disabled instead of
/// asking SwiftUI for a function that does not exist.
enum ShaderSupport {
    static let available: Bool = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
}

/// Radial barrel bulge (Fisheye, Fisheye Visual). `size` must be the frame of the view it modifies.
struct FisheyeLens: ViewModifier {
    var enabled: Bool
    var size: CGSize

    func body(content: Content) -> some View {
        content.distortionEffect(
            ShaderLibrary.fisheye(.float2(Float(size.width), Float(size.height)), .float(0.45), .float(2.2)),
            maxSampleOffset: CGSize(width: size.width * 0.45, height: size.height * 0.45),
            isEnabled: enabled && ShaderSupport.available)
    }
}

/// Centered 13-tap directional motion blur along `velocity` (points of smear across the whole kernel).
struct MotionBlurModifier: ViewModifier {
    var velocity: CGVector
    var shadersEnabled: Bool

    func body(content: Content) -> some View {
        let vx = Float(velocity.dx), vy = Float(velocity.dy)
        let moving = abs(vx) + abs(vy) >= 0.5
        content.layerEffect(
            ShaderLibrary.motionBlur(.float2(vx, vy)),
            maxSampleOffset: CGSize(width: abs(CGFloat(vx)) * 0.75, height: abs(CGFloat(vy)) * 0.75),
            isEnabled: shadersEnabled && moving && ShaderSupport.available)
    }
}

extension View {
    func fisheyeLens(enabled: Bool, size: CGSize) -> some View {
        modifier(FisheyeLens(enabled: enabled, size: size))
    }

    func motionBlur(_ velocity: CGVector, enabled: Bool) -> some View {
        modifier(MotionBlurModifier(velocity: velocity, shadersEnabled: enabled))
    }
}
