// Drop Shadow (was CompositorShaderSource.msl in SQRender; engine SQRender CompositorEffects.encodeShadow).
// Mirrors the Swift ShadowUniforms (48 bytes): offset in source px, working-linear color + opacity, Shadow Only, spread.
struct ShadowU { float2 offset; float4 color; int shadowOnly; float spread; };
ConstantBuffer<ShadowU> su : register(b0);
#include "Bindings.slang"

// Step 1: the picture's (in0) alpha shifted by `offset` px (bilinear, zero outside) into an alpha plane. The plane may be
// smaller than the picture (reduced): the offset is in picture px.
[shader("compute")][numthreads(16, 16, 1)]
void shadowExtract(uint3 tid : SV_DispatchThreadID) {
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float2 uv = (float2(gid) + 0.5f) / float2(size) - su.offset / float2(inSize());
    out0.Store(gid, float4(in0.SampleLevel(zeroSampler, uv, 0.0f).a));
}

// Step 3: shadow color (premultiplied by the blurred alpha in1 and opacity) behind the picture in0, or alone for Shadow Only.
[shader("compute")][numthreads(16, 16, 1)]
void shadowComposite(uint3 tid : SV_DispatchThreadID) {
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float ba = in1.SampleLevel(edgeSampler, (float2(gid) + 0.5f) / float2(size), 0.0f).r;
    float a = min(1.0f, ba / max(1.0f - su.spread, 0.01f)) * su.color.a;   // Spread: choke the soft edge outwards
    float4 sh = float4(su.color.rgb * a, a);
    float4 p = in0.Load(int3(int2(gid), 0));
    out0.Store(gid, su.shadowOnly != 0 ? sh : p + sh * (1.0f - p.a));
}
