// The compositor's source conversion (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor). in0 = luma
// (or RGB / packed) plane, in1 = chroma plane. The grade's fused first pass binds the same slots (texture 0/1, buffer 0/1).
// Mirrors Compositor.ConvertUniforms (16 bytes): the dispatch may cover only the visible part of the texture (`origin`);
// `transfer` = the source curve of the half-size average (>= 30: plain average of the encoded values).
struct ConvertU { uint2 origin; uint transfer; uint pad; };
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<ConvertU> vu : register(b1);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"

[shader("compute")][numthreads(16, 16, 1)]
void convertToRGB(uint3 tid : SV_DispatchThreadID) {
    CompositeU u = cu;
    uint2 gid = tid.xy + vu.origin;
    uint2 size = outSize();
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    out0.Store(gid, convertTexel(u, in0, in1, vu.transfer, gid, size));
}

[shader("compute")][numthreads(16, 16, 1)]
void convertToRGBScaled(uint3 tid : SV_DispatchThreadID) {
    CompositeU u = cu;
    uint2 gid = tid.xy + vu.origin;
    uint2 size = outSize();
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    out0.Store(gid, convertTexelScaled(u, in0, in1, vu.transfer, gid, size));
}
