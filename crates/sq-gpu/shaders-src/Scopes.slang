// Counts are one RWByteAddressBuffer (wgpu binds D3D12 storage buffers as raw views).
// Scopes (was ScopeShaderSource.msl in SQRender): waveform, parade, vectorscope and histogram counts of the Rec.709
// output signal, their maxima, and the normalized r32Float planes. Mirrors SQRender ScopesReference exactly (same
// constants, binning, row orientation). Engine: SQRender ScopesGPU. Counts live in one uint buffer at u2.
// Linear kernels (clear, max) index i = y * rowWidth + x over a 2D grid.
struct ScopeU {
    uint width, height, stride, flags;
    uint waveW, waveL, vecN, rowWidth;
    uint offWaveLuma, offParade, offVector, offHist;
    uint offset, count, maxIndex, gainBits; // clear, max and resolve: the region and its maximum slot; draw: gain as float bits
    uint outW, outH, pad1, pad2;
};
ConstantBuffer<ScopeU> u : register(b0);
RWByteAddressBuffer counts : register(u2);
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
    if (tid.x < u.rowWidth && i < u.count) { counts.Store((u.offset + i) * 4, 0u); }
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
        counts.InterlockedAdd((u.offWaveLuma + row * W + col) * 4, 1u, old);
    }
    if ((u.flags & kParade) != 0) {
        for (uint ch = 0; ch < 3; ch++) {
            uint row = L - 1 - levelOf(s[ch], L);
            counts.InterlockedAdd((u.offParade + row * 3 * W + ch * W + col) * 4, 1u, old);
        }
    }
    if ((u.flags & kVector) != 0) {
        float cb = (s.z - luma) / 1.8556f, cr = (s.x - luma) / 1.5748f;
        float nf = float(u.vecN);
        float cx = min(max(floor(cb * nf + nf / 2.0f + 0.5f), 0.0f), nf - 1.0f);
        float cy = min(max(floor(nf / 2.0f - cr * nf + 0.5f), 0.0f), nf - 1.0f);
        counts.InterlockedAdd((u.offVector + uint(cy) * u.vecN + uint(cx)) * 4, 1u, old);
    }
    if ((u.flags & kHist) != 0) {
        for (uint ch = 0; ch < 3; ch++) {
            counts.InterlockedAdd((u.offHist + ch * 256 + levelOf(s[ch], 256)) * 4, 1u, old);
        }
        counts.InterlockedAdd((u.offHist + 3 * 256 + levelOf(luma, 256)) * 4, 1u, old);
    }
}

// Maximum of counts[offset ..< offset + count] into counts[maxIndex]: a group reduction, one atomic per group
// (the old MSL used simd_max; cs_5_0 has no wave operations). Dispatch whole groups: rowWidth and the grid height
// multiples of 16 (Metal runs smaller edge groups, whose missing threads would leave groupMax unset).
groupshared uint groupMax[256];

[shader("compute")][numthreads(16, 16, 1)]
void scopeFindMax(uint3 tid : SV_DispatchThreadID, uint gi : SV_GroupIndex) {
    uint i = tid.y * u.rowWidth + tid.x;
    groupMax[gi] = tid.x < u.rowWidth && i < u.count ? counts.Load((u.offset + i) * 4) : 0u;
    GroupMemoryBarrierWithGroupSync();
    for (uint s = 128; s > 0; s >>= 1) {
        if (gi < s) { groupMax[gi] = max(groupMax[gi], groupMax[gi + s]); }
        GroupMemoryBarrierWithGroupSync();
    }
    uint old;
    if (gi == 0 && groupMax[0] > 0) { counts.InterlockedMax((u.maxIndex) * 4, groupMax[0], old); }
}

[shader("compute")][numthreads(16, 16, 1)]
void scopeResolve(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= u.outW || tid.y >= u.outH) { return; }
    uint c = counts.Load((u.offset + tid.y * u.outW + tid.x) * 4);
    uint m = counts.Load((u.maxIndex) * 4);
    out0.Store(tid.xy, float4(m == 0 ? 0.0f : float(c) / float(m), 0.0f, 0.0f, 1.0f));
}

// scopeDraw: one scope picture (out0, Rgba8Unorm, outW x outH) straight from the counts: the GPU form of the CPU
// `ScopeImage::render` (sq-draw-monitor). flags = kind (0 waveform, 1 parade, 2 vectorscope, 3 histogram); waveW x waveL =
// the plane (count / max at offset, maximum at maxIndex); gainBits = the trace intensity. Bilinear clamp sampling,
// compressive map, 4-tap cross glow, phosphor tints, additive histogram curves on 12/255 gray.
static const float kBackground = 12.0f / 255.0f;
static const float kOver100 = 0.015f;

float planeAt(int x, int y, float inv) {
    int xx = clamp(x, 0, int(u.waveW) - 1), yy = clamp(y, 0, int(u.waveL) - 1);
    return float(counts.Load((u.offset + uint(yy) * u.waveW + uint(xx)) * 4)) * inv;
}

float planeSample(float uu, float tt, float inv) {
    float fx = uu * float(u.waveW) - 0.5f, fy = tt * float(u.waveL) - 0.5f;
    float x0f = floor(fx), y0f = floor(fy);
    float ax = fx - x0f, ay = fy - y0f;
    int x0 = int(x0f), y0 = int(y0f);
    float top = planeAt(x0, y0, inv) * (1.0f - ax) + planeAt(x0 + 1, y0, inv) * ax;
    float bottom = planeAt(x0, y0 + 1, inv) * (1.0f - ax) + planeAt(x0 + 1, y0 + 1, inv) * ax;
    return top * (1.0f - ay) + bottom * ay;
}

float mapTrace(float v, float gain) { return saturate(pow(max(v, 0.0f), 0.45f) * 1.6f * gain); }
float mapVector(float v, float gain) {
    if (v <= 0.0f) { return 0.0f; }
    return saturate((0.34f + 0.66f * saturate(1.0f + log2(v) * 0.30102999566f / 5.0f)) * gain);
}
float mapOf(float v, float gain, bool vec) { return vec ? mapVector(v, gain) : mapTrace(v, gain); }

float glowOf(float uu, float tt, float gain, float sx, float sy, bool vec, float inv) {
    float tx = sx / float(u.waveW), ty = sy / float(u.waveL);
    float g = mapOf(planeSample(uu + tx, tt, inv), gain, vec) + mapOf(planeSample(uu - tx, tt, inv), gain, vec)
        + mapOf(planeSample(uu, tt + ty, inv), gain, vec) + mapOf(planeSample(uu, tt - ty, inv), gain, vec);
    return saturate(mapOf(planeSample(uu, tt, inv), gain, vec) + 0.18f * g);
}

[shader("compute")][numthreads(16, 16, 1)]
void scopeDraw(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= u.outW || tid.y >= u.outH) { return; }
    float uu = (float(tid.x) + 0.5f) / float(u.outW), tt = (float(tid.y) + 0.5f) / float(u.outH);
    float gain = asfloat(u.gainBits);
    uint m = counts.Load(u.maxIndex * 4);
    float inv = m == 0 ? 0.0f : 1.0f / float(m);
    float bg = kBackground;
    float3 col = float3(bg, bg, bg);
    if (u.flags == 0) {
        float i = glowOf(uu, tt, gain, 1.5f, 1.5f, false, inv);
        col = tt < kOver100 ? float3(bg + i, bg + i * 0.22f, bg + i * 0.20f) : float3(bg + i * 0.62f, bg + i, bg + i * 0.72f);
    } else if (u.flags == 1) {
        float panel = min(floor(uu * 3.0f), 2.0f);
        float i = glowOf(uu, tt, gain, 1.0f, 1.5f, false, inv);
        float3 tint = tt < kOver100 ? float3(1.0f, 0.22f, 0.20f)
            : (panel < 0.5f ? float3(1.0f, 0.30f, 0.26f) : (panel < 1.5f ? float3(0.30f, 1.0f, 0.42f) : float3(0.30f, 0.52f, 1.0f)));
        col = float3(bg, bg, bg) + i * tint;
    } else if (u.flags == 2) {
        float i = glowOf(uu, tt, gain, 1.5f, 1.5f, true, inv);
        col = float3(bg + i * 0.70f, bg + i, bg + i * 0.80f);
    } else {
        float h = 1.0f - tt;
        float3 add = float3(0.0f, 0.0f, 0.0f);
        for (int r = 0; r < 4; r++) {
            float3 tint = r == 0 ? float3(0.85f, 0.12f, 0.10f) : (r == 1 ? float3(0.10f, 0.75f, 0.22f) : (r == 2 ? float3(0.12f, 0.30f, 0.95f) : float3(0.22f, 0.22f, 0.22f)));
            if (h <= sqrt(max(planeSample(uu, (float(r) + 0.5f) / 4.0f, inv), 0.0f))) { add += tint; }
        }
        col = float3(bg, bg, bg) + add * gain;
    }
    out0.Store(tid.xy, float4(saturate(col), 1.0f));
}
