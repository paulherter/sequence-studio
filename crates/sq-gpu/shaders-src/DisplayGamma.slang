// The Program monitor's display gamma on the GPU (was the CPU table pass RgbaImage::mapped; the spec is
// crates/sq-draw/src/display_gamma.rs `video_to_srgb_lut`): every color channel of the 8-bit composite in0 is looked up in
// the 256-entry table in1 (an R8 row: Rec.709 code value -> sRGB code value of the luminance the Mac shows), alpha kept.
// The lookup by exact code value makes the result bit-identical to the CPU table.
#include "Bindings.slang"

[shader("compute")][numthreads(16, 16, 1)]
void displayGamma(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float4 c = read0(int2(tid.xy));
    uint3 i = uint3(round(saturate(c.rgb) * 255.0f));
    float r = in1.Load(int3(int(i.x), 0, 0)).r;
    float g = in1.Load(int3(int(i.y), 0, 0)).r;
    float b = in1.Load(int3(int(i.z), 0, 0)).r;
    out0.Store(tid.xy, float4(r, g, b, c.a));
}
