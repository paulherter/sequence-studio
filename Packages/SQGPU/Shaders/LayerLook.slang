// Layer draw with grain / scanlines (no neighbor reads): steps 1 and 2 of the look pass in one draw (was
// CompositorShaderSource.msl in SQRender; engine SQRender FilmLookPass). Fragment inputs: see Parts/Layer.slang.
#include "Parts/CompositeU.slang"
#include "Parts/Look.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<LookU> lu : register(b1);
RWStructuredBuffer<uint> maskData : register(u2);
#include "Parts/LayerVertex.slang"
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Mask.slang"
#include "Parts/Layer.slang"

// `c` is rounded to half first, exactly as step 1 stores it in its rgba16Float texture before the kernel reads it.
[shader("fragment")]
float4 compositeFragmentLook(VOut i) : SV_Target {
    float4 s = shadeLayer(i, cu, in0, in1, in3, in4, in5);
    float4 c = float4(targetHalf(s.x), targetHalf(s.y), targetHalf(s.z), targetHalf(s.w));
    return lookPointwise(c, 0.0f, uint2(i.position.xy), lu);
}
