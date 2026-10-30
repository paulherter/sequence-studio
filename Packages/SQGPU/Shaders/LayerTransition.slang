// The motion transition's final draw with the mix computed here instead of read from the mix texture (was
// CompositorShaderSource.msl in SQRender; engine SQRender Compositor.fusesTransitionMix): only when the transition canvas
// is the target size and the draw is plain (no blend mode), so pixel `gid` of the draw is pixel `gid` of the mix. in0 / in1
// = the two sides; the sides' smallest alpha (float bits) at u2.
#include "Parts/CompositeU.slang"
#include "Parts/Transition.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<TransitionRows> tr : register(b1);
RWStructuredBuffer<uint> cover : register(u2);
#include "Parts/LayerVertex.slang"
#include "Bindings.slang"

// The mix is rounded to half as the kernel's store would (a compute store rounds toward zero like a render target store,
// measured, TransitionFusionTests).
[shader("fragment")]
float4 compositeFragmentTransition(VOut i) : SV_Target {
    CompositeU u = cu;
    float2 cv = float2(asfloat(cover[0]), asfloat(cover[1]));
    float4 c = transitionCompose(in0, in1, transitionFromRows(tr), uint2(i.position.xy), u.canvas, cv);
    float4 g = float4(targetHalf(c.x), targetHalf(c.y), targetHalf(c.z), targetHalf(c.w));
    return g * u.opacity;
}
