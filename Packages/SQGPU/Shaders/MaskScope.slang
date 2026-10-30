// Effect mask input (was CompositorShaderSource.msl in SQRender; engine SQRender CompositorMasks.encodeMaskScope). in0 = the
// picture the effect read (`pre`), in1 = its result (`post`), in3 = subject / Magic matte, in4 / in5 = Picture mask
// sources; mask data at u2.
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
RWStructuredBuffer<uint> maskData : register(u2);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Mask.slang"

// `post` shows only where the masks cover, `pre` elsewhere. `u.maskSize` = the clip's frame in pass px, centered in the
// textures; `u.scale` = 1 (one pass px per px).
[shader("compute")][numthreads(16, 16, 1)]
void maskScopeMix(uint3 tid : SV_DispatchThreadID) {
    CompositeU u = cu;
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float2 p = float2(gid) + 0.5f - 0.5f * float2(size);
    float4 a = in0.Load(int3(int2(gid), 0)), b = in1.Load(int3(int2(gid), 0));
    float3 pc = a.a > 0.0f ? oetf709(clamp(a.rgb / a.a, 0.0f, 1.0f)) : float3(0.0f);
    float c = maskCoverage(p, u, in3, in4, in5, pc);
    out0.Store(gid, a + (b - a) * c);
}
