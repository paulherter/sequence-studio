// First pass of a long directional transition smear (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor):
// the side (in0) placed on the canvas (offset, scale) with a short smear of one comb spacing. Done in canvas space, on a
// canvas grown by `pad` (fraction) on every side, so the comb pass still finds the picture that lies just outside the frame.
// Mirrors Compositor.PreBlurUniforms (16 bytes); the sides' smallest alpha (float bits) at u2, this side's at `slot`.
struct PreBlurU { float2 canvas; float pad; uint slot; };
#include "Parts/Transition.slang"
ConstantBuffer<TransitionSideRows> sr : register(b0);
ConstantBuffer<PreBlurU> pu : register(b1);
RWStructuredBuffer<uint> cover : register(u2);
#include "Bindings.slang"

[shader("compute")][numthreads(16, 16, 1)]
void transitionPreBlur(uint3 tid : SV_DispatchThreadID) {
    TransitionSideU s = sideFromRows(sr);
    if (asfloat(cover[pu.slot]) < 0.999f) { s.mirror = 0.0f; }
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float2 uv = (float2(gid) + 0.5f) / float2(size) * (1.0f + 2.0f * pu.pad) - pu.pad;
    out0.Store(gid, transitionSide(in0, uv, s, pu.canvas));
}
