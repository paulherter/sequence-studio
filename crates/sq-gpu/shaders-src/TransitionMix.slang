// Motion transition mix (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor.materialiseMix). in0 / in1 =
// the two sides; the sides' smallest alpha (float bits, `transitionCoverMin`) at u2.
#include "Parts/Transition.slang"
ConstantBuffer<TransitionRows> tr : register(b0);
RWByteAddressBuffer cover : register(u2);
#include "Bindings.slang"

[shader("compute")][numthreads(16, 16, 1)]
void transitionMix(uint3 tid : SV_DispatchThreadID) {
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float2 cv = float2(asfloat(cover.Load((0) * 4u)), asfloat(cover.Load((1) * 4u)));
    out0.Store(gid, transitionCompose(in0, in1, transitionFromRows(tr), gid, float2(size), cv));
}
