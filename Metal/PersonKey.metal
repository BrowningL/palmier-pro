#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" float4 personKey(coreimage::sample_t s, coreimage::sample_t m, float strength) {
    strength = clamp(strength, 0.0, 1.0);
    float keep = mix(1.0, clamp(m.r, 0.0, 1.0), strength);
    // Keep straight RGB; FrameRenderer performs the single final premultiply.
    return float4(s.rgb, s.a * keep);
}
