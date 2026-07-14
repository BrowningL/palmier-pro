#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" float4 lumaKey(coreimage::sample_t s, float threshold, float softness) {
    threshold = clamp(threshold, 0.0, 1.0);
    softness = clamp(softness, 0.0, 1.0);
    if (threshold >= 0.9999) {
        return float4(s.rgb, s.a);
    }
    if (threshold <= 0.0001) {
        return float4(s.rgb, 0.0);
    }

    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float key = softness <= 0.0001
        ? (y >= threshold ? 1.0 : 0.0)
        : smoothstep(max(0.0, threshold - softness), threshold, y);
    float keep = 1.0 - key;
    // Effect stack I/O is unpremultiplied; FrameRenderer premultiplies once after
    // the stack. Scaling RGB here would create a dark fringe at soft edges.
    return float4(s.rgb, s.a * keep);
}

extern "C" float4 lumaDarkKey(coreimage::sample_t s, float threshold, float softness) {
    threshold = clamp(threshold, 0.0, 1.0);
    softness = clamp(softness, 0.0, 1.0);
    if (threshold <= 0.0001) {
        return float4(s.rgb, s.a);
    }
    if (threshold >= 0.9999) {
        return float4(s.rgb, 0.0);
    }

    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float key = softness <= 0.0001
        ? (y <= threshold ? 1.0 : 0.0)
        : 1.0 - smoothstep(threshold, min(1.0, threshold + softness), y);
    float keep = 1.0 - key;
    return float4(s.rgb, s.a * keep);
}
