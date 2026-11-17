// Gyroflow warp of one picture plane (Swift: the Metal kernel `sq_gyro_warp` in GyroWarpMap.swift). The map (float4 texels
// (u, v, known, 0) = where each coarse output texel samples the source, normalized to the picture) is at u2; the plane is
// in0 (any size: the map is normalized), the warped plane goes to out0. Bilinear between map texels (linear extrapolation
// past the last one, the background where a corner is unknown), then Lanczos-4 over 8x8 source pixels with the background
// outside the picture; positions are rounded to 1/32 pixel and the weights normalized like gyroflow_core's
// `sample_input_at` (wgpu_undistort.wgsl).
// Mirrors GyroWarpU (48 bytes).
struct GyroWarpU {
    uint2 dstSize;
    uint2 srcSize;
    uint2 mapSize;
    uint2 pad;
    float4 background;
};
ConstantBuffer<GyroWarpU> gu : register(b0);
RWByteAddressBuffer gyroMap : register(u2);
#include "Bindings.slang"

float4 mapTexel(uint2 p, uint w) { return asfloat(gyroMap.Load4((p.y * w + p.x) * 16u)); }

void lanczos4(float x, out float c[8]) {
    if (x < 1.19209290e-07f) {
        for (int i = 0; i < 8; i++) { c[i] = 0.0f; }
        c[3] = 1.0f;
        return;
    }
    const float S45 = 0.70710678118654752f;
    const float2 cs[8] = { float2(1, 0), float2(-S45, -S45), float2(0, 1), float2(S45, -S45),
                           float2(-1, 0), float2(S45, S45), float2(0, -1), float2(-S45, S45) };
    float y0 = -(x + 3.0f) * 0.78539816339744831f;
    float s0 = sin(y0), c0 = cos(y0), sum = 0.0f;
    for (int i = 0; i < 8; i++) {
        float y = -(x + 3.0f - float(i)) * 0.78539816339744831f;
        c[i] = (cs[i].x * s0 + cs[i].y * c0) / (y * y);
        sum += c[i];
    }
    float k = 1.0f / sum;
    for (int i = 0; i < 8; i++) { c[i] *= k; }
}

[shader("compute")][numthreads(16, 16, 1)]
void gyroWarp(uint3 tid : SV_DispatchThreadID) {
    GyroWarpU p = gu;
    if (tid.x >= p.dstSize.x || tid.y >= p.dstSize.y) { return; }
    uint2 gid = tid.xy;
    float2 m = (float2(gid) + 0.5f) * float2(p.mapSize) / float2(p.dstSize) - 0.5f;
    int2 i0 = clamp(int2(floor(m)), int2(0, 0), max(int2(p.mapSize) - 2, int2(0, 0)));
    int2 i1 = min(i0 + 1, int2(p.mapSize) - 1);
    float2 t = m - float2(i0);
    uint w = p.mapSize.x;
    float4 a = mapTexel(uint2(i0), w), b = mapTexel(uint2(i1.x, i0.y), w);
    float4 c = mapTexel(uint2(i0.x, i1.y), w), d = mapTexel(uint2(i1), w);
    if (min(min(a.z, b.z), min(c.z, d.z)) < 0.5f) { out0.Store(gid, p.background); return; }
    float2 s = lerp(lerp(a.xy, b.xy, t.x), lerp(c.xy, d.xy, t.x), t.y);
    float2 uv = s * float2(p.srcSize) - 3.0f;
    int2 q = int2(round(uv * 32.0f));
    int2 base = q >> 5;
    float2 f = float2(q & 31) / 32.0f;
    float cx[8];
    float cy[8];
    lanczos4(f.x, cx);
    lanczos4(f.y, cy);
    int2 size = int2(p.srcSize);
    float4 sum = float4(0.0f, 0.0f, 0.0f, 0.0f);
    for (int yp = 0; yp < 8; yp++) {
        int sy = base.y + yp;
        if (sy < 0 || sy >= size.y) { sum += p.background * cy[yp]; continue; }
        float4 row = float4(0.0f, 0.0f, 0.0f, 0.0f);
        for (int xp = 0; xp < 8; xp++) {
            int sx = base.x + xp;
            float4 px = (sx >= 0 && sx < size.x) ? read0(int2(sx, sy)) : p.background;
            row += px * cx[xp];
        }
        sum += row * cy[yp];
    }
    out0.Store(gid, clamp(sum, float4(0.0f, 0.0f, 0.0f, 0.0f), float4(1.0f, 1.0f, 1.0f, 1.0f)));
}
