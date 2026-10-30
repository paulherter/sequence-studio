// Trails (was TemporalShaderSource.msl in SQRender; engine SQRender TemporalPass). Y planes in0...in8, chroma in9...in17,
// the filtered center in18.
// Mirrors Compositor.TrailsUniforms (48 bytes).
struct TrailsU {
    uint count, blend, flags, pad;
    float4 w0, w1;
};
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<TrailsU> ru : register(b1);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Temporal.slang"

#define TEXEL_AT(Y, C) convertTexel(u, Y, C, 0xFFFFFFFFu, q, size)
#define TRAIL_SLOTS(F) switch (k) { \
    case 0: return F(in0, in9); case 1: return F(in1, in10); case 2: return F(in2, in11); case 3: return F(in3, in12); \
    case 4: return F(in4, in13); case 5: return F(in5, in14); case 6: return F(in6, in15); case 7: return F(in7, in16); \
    default: return F(in8, in17); }
float4 trailTexel(uint k, CompositeU u, uint2 q, uint2 size) { TRAIL_SLOTS(TEXEL_AT) }

// Trails: earlier frames laid over the center, each weighted by its fade and its own alpha, blended in premultiplied
// straight encoded color.
[shader("compute")][numthreads(16, 16, 1)]
void temporalTrails(uint3 tid : SV_DispatchThreadID) {
    CompositeU u = cu;
    TrailsU t = ru;
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float4 c0 = (t.flags & 1u) != 0u ? in18.Load(int3(int2(gid), 0)) : convertTexel(u, in0, in9, 0xFFFFFFFFu, gid, size);
    float3 p = c0.rgb * c0.a;
    float a = c0.a;
    float3 sumAdd = p, prodScr = 1.0f - clamp(p, 0.0f, 1.0f), mx = p;
    float aInv = 1.0f - a;
    for (uint k = 1; k <= t.count; k++) {
        float w = k <= 4u ? t.w0[k - 1u] : t.w1[k - 5u];
        float4 ck = trailTexel(k, u, gid, size);
        float ak = clamp(ck.a, 0.0f, 1.0f) * w;
        float3 pk = ck.rgb * ak;
        sumAdd += pk;
        prodScr *= 1.0f - clamp(pk, 0.0f, 1.0f);
        mx = max(mx, pk);
        aInv *= 1.0f - ak;
    }
    float alpha = 1.0f - aInv;
    float3 r;
    if (t.blend == 0u) { r = min(sumAdd, max(p, float3(alpha))); }
    else if (t.blend == 1u) { r = max(p, 1.0f - prodScr); }
    else { r = mx; }
    float3 res = alpha > 1e-5f ? r / alpha : float3(0.0f);
    if ((t.flags & 2u) != 0u) { res = inverseOETF709(res); }
    out0.Store(gid, float4(res, alpha));
}
