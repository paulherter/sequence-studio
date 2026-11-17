// Film / tape look (was CompositorShaderSource.msl in SQRender; mirrors FilmLook in SQCore, see Effects/FilmLookPass.swift).
// LookU mirrors the Swift LookUniforms (112 bytes).
struct LookU {
    float4 dims;      // width, height, scale (layer px per 1080-line px), grain color 0...1
    uint4 ids;        // flags (1 grain, 8 scanlines, 16 chroma, 32 tracking, 64 aged film), grain seed, tracking seed, aged seed
    float4 grain;     // amount, size px, softness, luma weight
    float4 scan;      // intensity, spacing px, thickness, 0
    float4 chroma;    // bleed px, shift px, 0, 0
    float4 track;     // amount, band height, phase, 0
    float4 aged;      // dust, scratches, flicker, 0
};

uint pcg(uint v) {
    uint s = v * 747796405u + 2891336653u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
float hash2(int2 p, uint seed) {
    return float(pcg(uint(p.x) + pcg(uint(p.y) + pcg(seed)))) * (1.0f / 4294967295.0f);
}
// Value noise 0...1 on a lattice of one cell per unit: nearest cell for softness 0, smooth interpolation for 1.
float grainNoise(float2 p, float soft, uint seed) {
    float2 fl = floor(p);
    int2 i = int2(fl);
    float2 f = p - fl;
    float a = hash2(i, seed), b = hash2(i + int2(1, 0), seed), c = hash2(i + int2(0, 1), seed), d = hash2(i + int2(1, 1), seed);
    float2 u = lerp(step(float2(0.5f), f), f * f * (3.0f - 2.0f * f), soft);
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// The per-pixel tail of the look (tracking streak, grain, aged film, scanlines): shared by the kernel and the fused upright
// draw, so both produce the same bits.
float4 lookPointwise(float4 c, float streak, uint2 gid, LookU L) {
    float sc = L.dims.z;
    uint flags = L.ids.x;
    const float3 lw = float3(0.2126f, 0.7152f, 0.0722f);
    c.rgb += streak * 0.6f * c.a;

    // Film grain: noise on a lattice of grain-sized cells, added in a display-like (square root) space so it reads the same
    // in shadows and highlights, weighted towards the mid-tones by the luma weight.
    if ((flags & 1u) != 0u && c.a > 0.0f) {
        float3 col = c.rgb / c.a;
        float ld = clamp(sqrt(max(dot(col, lw), 0.0f)), 0.0f, 1.0f);
        float mid = 1.0f - (2.0f * ld - 1.0f) * (2.0f * ld - 1.0f);
        float w = lerp(1.0f, mid, L.grain.w);
        float gs = max(L.grain.y * sc, 0.5f);
        float2 gp = (float2(gid) + 0.5f) / gs;
        float gain = 1.0f + L.grain.z * 0.9f;
        float n = (grainNoise(gp, L.grain.z, L.ids.y) * 2.0f - 1.0f) * gain;
        float3 nv = float3(n);
        if (L.dims.w > 0.0f) {
            // Color grain: an independent pattern per channel, blended in by the color amount.
            float3 nc = float3((grainNoise(gp, L.grain.z, L.ids.y + 101u) * 2.0f - 1.0f) * gain,
                               (grainNoise(gp, L.grain.z, L.ids.y + 202u) * 2.0f - 1.0f) * gain,
                               (grainNoise(gp, L.grain.z, L.ids.y + 303u) * 2.0f - 1.0f) * gain);
            nv = lerp(nv, nc, L.dims.w);
        }
        float3 cd = sqrt(max(col, 0.0f)) + nv * L.grain.x * 0.25f * w;
        cd = max(cd, 0.0f);
        c.rgb = cd * cd * c.a;
    }

    // Aged film (pointwise, no neighbor reads): exposure flicker per frame, dust specks (at most one per 64 px cell, kept
    // clear of the cell edge so only the own cell is read) and up to three vertical scratches that hold for 3 frames.
    if ((flags & 64u) != 0u && c.a > 0.0f) {
        const float inv = 1.0f / 4294967295.0f;
        uint fs = L.ids.w;
        c.rgb *= 1.0f + (float(pcg(fs * 3u + 7u)) * inv * 2.0f - 1.0f) * L.aged.z * 0.35f;
        if (L.aged.x > 0.0f) {
            float cell = 64.0f * sc;
            float2 p = float2(gid) + 0.5f;
            int2 ci = int2(floor(p / cell));
            if (hash2(ci, fs ^ 0x9e37u) < L.aged.x * 0.08f) {
                float2 ctr = (float2(ci) + 0.1f + 0.8f * float2(hash2(ci, fs + 1u), hash2(ci, fs + 2u))) * cell;
                float r = (1.0f + 2.5f * hash2(ci, fs + 3u)) * sc;
                float a = 1.0f - smoothstep(r * 0.5f, r, length(p - ctr));
                if (hash2(ci, fs + 4u) > 0.5f) { c.rgb = lerp(c.rgb, float3(0.9f) * c.a, a); }
                else { c.rgb *= 1.0f - 0.9f * a; }
            }
        }
        if (L.aged.y > 0.0f) {
            float v = (float(gid.y) + 0.5f) / L.dims.y;
            for (uint k = 0u; k < 3u; k++) {
                uint s = pcg((fs / 3u) * 5u + k * 977u + 13u);
                if (float(pcg(s + 1u)) * inv >= L.aged.y) { continue; }
                float x = float(pcg(s + 2u)) * inv * L.dims.x;
                float wpx = (0.8f + float(pcg(s + 3u)) * inv) * sc;
                float y0 = float(pcg(s + 4u)) * inv, len = 0.4f + 0.6f * float(pcg(s + 5u)) * inv;
                float a = (1.0f - smoothstep(0.0f, wpx, abs(float(gid.x) + 0.5f - x))) * step(y0, v) * step(v, y0 + len);
                c.rgb = lerp(c.rgb, float3(0.85f) * c.a, a * 0.7f);
            }
        }
    }

    // Scanlines: dark rows, one gap every `spacing` px, the gap `thickness` of the spacing wide.
    if ((flags & 8u) != 0u) {
        float period = max(L.scan.y * sc, 2.0f);
        float f = frac(float(gid.y) / period);
        float d = min(f, 1.0f - f);
        float gapHalf = L.scan.z * 0.5f;
        float m = smoothstep(gapHalf - 0.12f, gapHalf + 0.12f, d);
        c.rgb *= lerp(1.0f, m, L.scan.x);
    }
    return c;
}
