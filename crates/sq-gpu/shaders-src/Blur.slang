// Separable Gaussian, one axis per dispatch (was gaussianBlur1D in CompositorShaderSource). clampEdges != 0 (Repeat Edge
// Pixels): every read is clamped into lo...hi; otherwise taps outside the texture count as transparent.
struct BlurU { int2 axis; int radius; int clampEdges; int2 lo; int2 hi; };
// 2 * radius + 1 <= 128 weights, the same 512 bytes on both targets. Metal reads them as a flat float array (a computed
// float4 component index, w[j >> 2][j & 3], made the Metal blur about 20 % slower); HLSL constant buffers pad float
// arrays to 16 bytes per element, so there they stay packed four per row. scripts/gpu-shaders.sh sets SQ_METAL.
#ifdef SQ_METAL
struct BlurW { float w[128]; };
#else
struct BlurW { float4 w[32]; };
#endif
ConstantBuffer<BlurU> u : register(b0);
ConstantBuffer<BlurW> wts : register(b1);
#include "Bindings.slang"

#ifdef SQ_METAL
float weight(int j) { return wts.w[j]; }
#else
float weight(int j) { return wts.w[j >> 2][j & 3]; }
#endif

[shader("compute")][numthreads(16, 16, 1)]
void gaussianBlur1D(uint3 tid : SV_DispatchThreadID) {
    uint2 s = inSize();
    int W = int(s.x), H = int(s.y);
    int2 g = int2(tid.xy);
    if (g.x >= W || g.y >= H) return;
    float4 acc = float4(0.0f);
    if (u.clampEdges != 0) {
        for (int k = -u.radius; k <= u.radius; k++) {
            int2 p = clamp(g + u.axis * k, u.lo, u.hi);
            acc += read0(p) * weight(k + u.radius);
        }
    } else {
        for (int k = -u.radius; k <= u.radius; k++) {
            int2 p = g + u.axis * k;
            if (p.x < 0 || p.y < 0 || p.x >= W || p.y >= H) continue;
            acc += read0(p) * weight(k + u.radius);
        }
    }
    out0.Store(tid.xy, acc);
}
