// The generic color chain in place (was ColorShaderSource colorChainInPlace in SQRender; engine SQRender ColorPipelineGPU).
// out0 is read and written (later passes of a grade, or source == destination). A 3D LUT at lut0, a 1D LUT at in3. The dispatch covers the region from cc.extra.yz (the whole texture: 0).
#include "Parts/ColorTypes.slang"
ConstantBuffer<ColorChainU> cc : register(b0);
ConstantBuffer<CurveRows> curves : register(b1);
#define SQ_OUT_READ
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Color.slang"

[shader("compute")][numthreads(16, 16, 1)]
void colorChainInPlace(uint3 tid : SV_DispatchThreadID) {
    uint2 gid = tid.xy + cc.extra.yz;
    uint2 size = outSize();
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    out0.Store(gid, gradePixel(out0.Load(gid), gid, size));
}
