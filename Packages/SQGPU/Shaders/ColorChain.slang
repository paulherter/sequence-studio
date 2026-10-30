// The generic color chain (was ColorShaderSource colorChain in SQRender; engine SQRender ColorPipelineGPU).
// in0 = the source picture, out0 = the graded picture. A 3D LUT at lut0, a 1D LUT at in3. The dispatch covers the region from cc.extra.yz (the whole texture: 0).
#include "Parts/ColorTypes.slang"
ConstantBuffer<ColorChainU> cc : register(b0);
ConstantBuffer<CurveRows> curves : register(b1);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Color.slang"

[shader("compute")][numthreads(16, 16, 1)]
void colorChain(uint3 tid : SV_DispatchThreadID) {
    uint2 gid = tid.xy + cc.extra.yz;
    uint2 size = outSize();
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    out0.Store(gid, gradePixel(in0.Load(int3(int2(gid), 0)), gid, size));
}
