#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// The original's rule transitions (cg/tr/ysr*.png): a grayscale mask decides
/// where the picture appears first. Dark mask pixels reveal first; `vague`
/// softens the edge.
[[ stitchable ]] half4 ruleReveal(float2 position, half4 color, float2 size,
                                  texture2d<half> mask, float progress, float vague) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float level = mask.sample(linearSampler, position / size).r;
    float edge = max(vague, 0.001);
    float alpha = clamp((progress * (1.0 + edge) - level) / edge, 0.0, 1.0);
    return color * half(alpha);
}

/// The original's camera tint (es.CM.SD / es.CM.MD), baked into pictures as they
/// load: `saturation` 1 is unchanged, 0 grayscale; each channel is then scaled.
/// Flashbacks use 0.25 with (1.25, 1, 0.75), a warm sepia. Colors are premultiplied.
[[ stitchable ]] half4 tint(float2 position, half4 color, float saturation, float red, float green, float blue) {
    half3 rgb = color.rgb;
    half gray = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    rgb = mix(half3(gray), rgb, half(saturation));
    rgb *= half3(half(red), half(green), half(blue));
    return half4(min(rgb, half3(color.a)), color.a);
}
