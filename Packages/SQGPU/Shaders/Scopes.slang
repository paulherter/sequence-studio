// Scopes (was ScopeShaderSource.msl in SQRender): waveform, parade, vectorscope and histogram counts of the Rec.709
// output signal, their maxima, and the normalized r32Float planes. Mirrors SQRender ScopesReference exactly (same
// constants, binning, row orientation). Engine: SQRender ScopesGPU. Counts live in one uint buffer at u2.
// Linear kernels (clear, max) index i = y * rowWidth + x over a 2D grid.
struct ScopeU {
    uint width, height, stride, flags;
    uint waveW, waveL, vecN, rowWidth;
    uint offWaveLuma, offParade, offVector, offHist;
    uint offset, count, maxIndex, pad0;     // clear, max and resolve: the region and its maximum slot
    uint outW, outH, pad1, pad2;
};
ConstantBuffer<ScopeU> u : register(b0);
RWStructuredBuffer<uint> counts : register(u2);
#include "Bindings.slang"

static const uint kWaveLuma = 1, kParade = 2, kVector = 4, kHist = 8;
static const float kBt709Alpha = 1.09929682680944f;
static const float kBt709Beta = 0.018053968510807f;

float bt709OETF(float l) {
    if (l < kBt709Beta) { return 4.5f * l; }
    return kBt709Alpha * pow(l, 0.45f) - (kBt709Alpha - 1.0f);
}

uint levelOf(float v, uint levels) { return min(uint(v * float(levels)), levels - 1); }

[shader("compute")][numthreads(16, 16, 1)]
void scopeClear(uint3 tid : SV_DispatchThreadID) {
    uint i = tid.y * u.rowWidth + tid.x;
    if (tid.x < u.rowWidth && i < u.count) { counts[u.offset + i] = 0; }
}

[shader("compute")][numthreads(16, 16, 1)]
void scopeAccumulate(uint3 tid : SV_DispatchThreadID) {
    uint x = tid.x * u.stride, y = tid.y * u.stride;
    if (x >= u.width || y >= u.height) { return; }
    float3 lin = read0(int2(int(x), int(y))).rgb;
    float3 c = clamp(lin, 0.0f, 1.0f);
    float3 s = float3(bt709OETF(c.x), bt709OETF(c.y), bt709OETF(c.z));
    float luma = s.x * 0.2126f + s.y * 0.7152f + s.z * 0.0722f;
    uint W = u.waveW, L = u.waveL;
    uint col = min(x * W / u.width, W - 1);
    uint old;
    if ((u.flags & kWaveLuma) != 0) {
        uint row = L - 1 - levelOf(luma, L);
        InterlockedAdd(counts[u.offWaveLuma + row * W + col], 1u, old);
    }
    if ((u.flags & kParade) != 0) {
        for (uint ch = 0; ch < 3; ch++) {
            uint row = L - 1 - levelOf(s[ch], L);
            InterlockedAdd(counts[u.offParade + row * 3 * W + ch * W + col], 1u, old);
        }
    }
    if ((u.flags & kVector) != 0) {
        float cb = (s.z - luma) / 1.8556f, cr = (s.x - luma) / 1.5748f;
        float nf = float(u.vecN);
        float cx = min(max(floor(cb * nf + nf / 2.0f + 0.5f), 0.0f), nf - 1.0f);
        float cy = min(max(floor(nf / 2.0f - cr * nf + 0.5f), 0.0f), nf - 1.0f);
        InterlockedAdd(counts[u.offVector + uint(cy) * u.vecN + uint(cx)], 1u, old);
    }
    if ((u.flags & kHist) != 0) {
        for (uint ch = 0; ch < 3; ch++) {
            InterlockedAdd(counts[u.offHist + ch * 256 + levelOf(s[ch], 256)], 1u, old);
        }
        InterlockedAdd(counts[u.offHist + 3 * 256 + levelOf(luma, 256)], 1u, old);
    }
}

// Maximum of counts[offset ..< offset + count] into counts[maxIndex]: a group reduction, one atomic per group
// (the old MSL used simd_max; cs_5_0 has no wave operations). Dispatch whole groups: rowWidth and the grid height
// multiples of 16 (Metal runs smaller edge groups, whose missing threads would leave groupMax unset).
groupshared uint groupMax[256];

[shader("compute")][numthreads(16, 16, 1)]
void scopeFindMax(uint3 tid : SV_DispatchThreadID, uint gi : SV_GroupIndex) {
    uint i = tid.y * u.rowWidth + tid.x;
    groupMax[gi] = tid.x < u.rowWidth && i < u.count ? counts[u.offset + i] : 0u;
    GroupMemoryBarrierWithGroupSync();
    for (uint s = 128; s > 0; s >>= 1) {
        if (gi < s) { groupMax[gi] = max(groupMax[gi], groupMax[gi + s]); }
        GroupMemoryBarrierWithGroupSync();
    }
    uint old;
    if (gi == 0 && groupMax[0] > 0) { InterlockedMax(counts[u.maxIndex], groupMax[0], old); }
}

[shader("compute")][numthreads(16, 16, 1)]
void scopeResolve(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= u.outW || tid.y >= u.outH) { return; }
    uint c = counts[u.offset + tid.y * u.outW + tid.x];
    uint m = counts[u.maxIndex];
    out0.Store(tid.xy, float4(m == 0 ? 0.0f : float(c) / float(m), 0.0f, 0.0f, 1.0f));
}
