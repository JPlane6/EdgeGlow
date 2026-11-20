// SwiftUI stitchable shaders for the lyric styles. build.sh compiles this file into
// EdgeGlow.app/Contents/Resources/default.metallib (ShaderLibrary.default). When no Metal toolchain is
// installed the app still builds; ShaderSupport.available turns every effect off.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 1. Centered 13-tap directional motion blur (AppleDesign, AppleMoney, AppleNotify, Flashbang)
[[ stitchable ]] half4 motionBlur(float2 position, SwiftUI::Layer layer, float2 velocity) {
    if (fabs(velocity.x) + fabs(velocity.y) < 0.5) {
        return layer.sample(position);
    }
    half4 acc = half4(0.0h);
    for (int i = 0; i < 13; i++) {
        float t = float(i) * (1.0 / 12.0) - 0.5; // 0.083333336 and -0.5
        acc += layer.sample(position + velocity * t);
    }
    return acc * (1.0h / 13.0h); // half 0x3ccd
}

// 2. Radial barrel/lens bulge distortion (Fisheye and Fisheye Visual)
[[ stitchable ]] float2 fisheye(float2 position, float2 size, float strength, float power) {
    float2 halfSize = max(size * 0.5, float2(1.0));
    float2 uv = (position - halfSize) / halfSize;
    float r = sqrt(dot(uv, uv));
    if (r < 1e-5) return position;
    // Inverse radial map for SwiftUI distortionEffect so the center bulges outward
    float factor = 1.0 / (1.0 + strength * pow(r, power));
    return halfSize + uv * factor * halfSize;
}
