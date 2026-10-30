// Deflicker + temporal denoise of a center frame (was TemporalShaderSource.msl in SQRender; engine SQRender TemporalPass).
// Y planes in0...in10, chroma planes in11...in21 (center, before, after); gains at u3.
// Mirrors Compositor.TemporalUniforms (48 bytes).
struct TemporalU {
    uint count;        // frames bound for the denoise (center + before + after), 1...11
    uint nBefore;      // of them before the center
    uint statsBefore;  // before-frames in the deflicker stats list
    uint flags;        // 1 temporal denoise, 2 deflicker, 4 best (patch distance + motion search), 8 linearize output
    float lumaS;
    float colorS;
    float motion;
    float keep;
    int searchStep;
    uint searchCount;
    uint tilesX;
    uint tilesY;
};
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<TemporalU> tu : register(b1);
RWStructuredBuffer<float> gains : register(u3);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Temporal.slang"

float gainAt(uint frame, float2 uv, TemporalU t) {
    uint n = t.tilesX * t.tilesY;
    float2 p = clamp(uv * float2(float(t.tilesX), float(t.tilesY)) - 0.5f, float2(0.0f), float2(float(t.tilesX - 1), float(t.tilesY - 1)));
    uint2 i0 = uint2(floor(p));
    uint2 i1 = min(i0 + 1u, uint2(t.tilesX - 1, t.tilesY - 1));
    float2 f = p - float2(i0);
    uint b = frame * n;
    float a = lerp(gains[b + i0.y * t.tilesX + i0.x], gains[b + i0.y * t.tilesX + i1.x], f.x);
    float c = lerp(gains[b + i1.y * t.tilesX + i0.x], gains[b + i1.y * t.tilesX + i1.x], f.x);
    return lerp(a, c, f.y);
}

int2 searchOffset(uint c) {
    switch (c) {
        case 1: return int2(1, 0);   case 2: return int2(-1, 0);  case 3: return int2(0, 1);  case 4: return int2(0, -1);
        case 5: return int2(1, 1);   case 6: return int2(-1, 1);  case 7: return int2(1, -1); case 8: return int2(-1, -1);
        default: return int2(0);
    }
}

// One neighbor frame: its Y'CbCr at the best of the search offsets (best mode, patch distance in w) or at the pixel.
float4 neighborYCC(CompositeU u, TemporalU t, Texture2D<float4> ty, Texture2D<float4> tc, uint2 gid, uint2 size, float gk,
                   float p0, bool best) {
    int2 off = int2(0);
    float dp = 0.0f;
    if (best) {
        dp = 1e9f;
        for (uint c = 0; c < t.searchCount; c++) {
            int2 o = searchOffset(c) * t.searchStep;
            float d = abs(patchLuma(u, ty, tc, int2(gid) + o, size) * gk - p0);
            if (d < dp) { dp = d; off = o; }
        }
    }
    uint2 q = uint2(clamp(int2(gid) + off, int2(0), int2(size) - 1));
    return float4(toYCC(convertTexel(u, ty, tc, 0xFFFFFFFFu, q, size).rgb * gk), dp);
}

// Frame k of the denoise list (Y in k, chroma in 11 + k): one switch per frame, as resource arrays cannot be indexed at
// runtime on every target.
#define NB(Y, C) neighborYCC(u, t, Y, C, gid, size, gk, p0, best)
float4 neighborAt(uint k, CompositeU u, TemporalU t, uint2 gid, uint2 size, float gk, float p0, bool best) {
    switch (k) {
    case 1: return NB(in1, in12); case 2: return NB(in2, in13); case 3: return NB(in3, in14); case 4: return NB(in4, in15);
    case 5: return NB(in5, in16); case 6: return NB(in6, in17); case 7: return NB(in7, in18); case 8: return NB(in8, in19);
    case 9: return NB(in9, in20); default: return NB(in10, in21);
    }
}

// Deflicker + temporal denoise of the center frame with its neighbors. Writes straight encoded color (or working-linear
// with flag 8) + the center's alpha.
[shader("compute")][numthreads(16, 16, 1)]
void temporalDenoise(uint3 tid : SV_DispatchThreadID) {
    CompositeU u = cu;
    TemporalU t = tu;
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float2 uv = (float2(gid) + 0.5f) / float2(size);
    bool df = (t.flags & 2u) != 0u, best = (t.flags & 4u) != 0u;
    float4 c0 = convertTexel(u, in0, in11, 0xFFFFFFFFu, gid, size);
    float g0 = df ? gainAt(0, uv, t) : 1.0f;
    float3 x0 = c0.rgb * g0;
    float3 res = x0;
    if ((t.flags & 1u) != 0u) {
        float3 yc0 = toYCC(x0);
        float accY = yc0.x, wy = 1.0f, wc = 1.0f;
        float2 accC = yc0.yz;
        float p0 = best ? patchLuma(u, in0, in11, int2(gid), size) * g0 : 0.0f;
        for (uint k = 1; k < t.count; k++) {
            uint si = k <= t.nBefore ? k : 1u + t.statsBefore + (k - 1u - t.nBefore);
            float gk = df ? gainAt(si, uv, t) : 1.0f;
            float4 n = neighborAt(k, u, t, gid, size, gk, p0, best);
            float3 yck = n.xyz;
            float dp = n.w;
            float dy = best ? dp : abs(yck.x - yc0.x);
            float m = 1.0f - smoothstep(0.7f * t.motion, t.motion, dy);
            float wyk = t.lumaS > 0.0f ? m * max(0.0f, 1.0f - (dy * dy) / (t.lumaS * t.lumaS)) : 0.0f;
            float dc = length(yck.yz - yc0.yz);
            float wck = t.colorS > 0.0f ? m * max(0.0f, 1.0f - (dc * dc) / (t.colorS * t.colorS)) : 0.0f;
            accY += yck.x * wyk; wy += wyk;
            accC += yck.yz * wck; wc += wck;
        }
        res = lerp(fromYCC(float3(accY / wy, accC / wc)), x0, t.keep);
    }
    if ((t.flags & 8u) != 0u) { res = inverseOETF709(res); }
    out0.Store(gid, float4(res, c0.a));
}

