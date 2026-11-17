// Helpers of the temporal kernels (TemporalStats, TemporalDenoise, TemporalTrails): the luma used to
// compare frames. Include after Parts/Convert.slang.

#include "YCC.slang"

// Brightness of one texel, comparable between frames of the same source.
float texLuma(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, int2 p, uint2 size) {
    uint2 q = uint2(clamp(p, int2(0), int2(size) - 1));
    if (u.mode == 0) { return ty.Load(int3(int2(q), 0)).r * u.range.x + u.range.y; }
    return dot(convertTexel(u, ty, tc, 0xFFFFFFFFu, q, size).rgb, float3(0.2126f, 0.7152f, 0.0722f));
}
// 5-tap patch (center and the four diagonal neighbors).
float patchLuma(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, int2 p, uint2 size) {
    return (texLuma(u, ty, tc, p, size) + texLuma(u, ty, tc, p + int2(1, 1), size) + texLuma(u, ty, tc, p + int2(-1, 1), size)
          + texLuma(u, ty, tc, p + int2(1, -1), size) + texLuma(u, ty, tc, p + int2(-1, -1), size)) * 0.2f;
}

