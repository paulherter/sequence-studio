// Whole-picture effects (were in ImageFilters.msl): Sharpen, Directional Blur, Mirror, Noise, Mosaic. CPU references:
// SQRender ImageFilters. Premultiplied working-linear pixels; the clip's own frame is centered in the texture.
struct FilterU { float4 a; float4 b; float2 center; float2 frame; int4 i; float4 c; float4 d; };
ConstantBuffer<FilterU> u : register(b0);
#include "Bindings.slang"

// i = picture pixel rect (minX, minY, maxX, maxY): inside it the neighborhood is clamped to it, outside to the texture.
[shader("compute")][numthreads(16, 16, 1)]
void filterSharpen(uint3 tid : SV_DispatchThreadID) {
    uint2 s = inSize();
    int W = int(s.x), H = int(s.y);
    int2 g = int2(tid.xy);
    if (g.x >= W || g.y >= H) return;
    bool inside = g.x >= u.i.x && g.y >= u.i.y && g.x <= u.i.z && g.y <= u.i.w;
    int2 lo = inside ? u.i.xy : int2(0), hi = inside ? u.i.zw : int2(W - 1, H - 1);
    float4 box = float4(0.0f);
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) box += read0(clamp(g + int2(i, j), lo, hi));
    float4 p = read0(g);
    float4 o = max(p + u.a.x * (p - box / 9.0f), float4(0.0f));
    o.a = min(o.a, 1.0f);
    out0.Store(tid.xy, o);
}

[shader("compute")][numthreads(16, 16, 1)]
void filterDirectionalBlur(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float2 size = float2(s);
    float2 c = float2(tid.xy) + 0.5f;
    int n = u.i.x;
    float4 acc = float4(0.0f);
    for (int k = 0; k < n; k++) acc += in0.SampleLevel(zeroSampler, (c + u.a.xy * (float(k) / float(n - 1) - 0.5f)) / size, 0.0f);
    out0.Store(tid.xy, acc / float(n));
}

// One comb pass of a long smear: n = i.x taps step = a.xy apart, centered; shift = b.xy maps a dst pixel into src pixels.
[shader("compute")][numthreads(16, 16, 1)]
void filterSmearComb(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float2 size = float2(inSize());
    float2 c = float2(tid.xy) + 0.5f + u.b.xy;
    int n = u.i.x;
    float2 start = c - u.a.xy * (0.5f * float(n - 1));
    float4 acc = float4(0.0f);
    for (int k = 0; k < n; k++) acc += in0.SampleLevel(zeroSampler, (start + u.a.xy * float(k)) / size, 0.0f);
    out0.Store(tid.xy, acc / float(n));
}

[shader("compute")][numthreads(16, 16, 1)]
void filterMirror(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float2 size = float2(s);
    float2 q = float2(tid.xy) + 0.5f;
    float d = dot(q - u.center, u.a.xy);
    if (d > 0.0f) q -= 2.0f * d * u.a.xy;
    out0.Store(tid.xy, in0.SampleLevel(zeroSampler, q / size, 0.0f));
}

float hash01(uint x, uint y, uint seed, uint ch) {
    uint h = x * 1973u + y * 9277u + seed * 26699u + ch * 104729u;
    h = h * 747796405u + 2891336453u;
    uint w = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    w = (w >> 22u) ^ w;
    return float(w >> 8u) / 16777216.0f;
}

// i.x color noise, i.y clip, i.z seed (bit pattern).
[shader("compute")][numthreads(16, 16, 1)]
void filterNoise(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float4 p = read0(int2(tid.xy)), o = p;
    uint seed = asuint(u.i.z);
    for (uint c = 0; c < 3; c++) {
        float v = p[c] + u.a.x * (hash01(tid.x, tid.y, seed, u.i.x != 0 ? c : 0u) - 0.5f) * p.a;
        o[c] = u.i.y != 0 ? clamp(v, 0.0f, max(p.a, p[c])) : max(v, 0.0f);
    }
    out0.Store(tid.xy, o);
}

// Mosaic: pixels [start, end) whose centers fall in block b (mirrors ImageFilters.blockRange).
int2 blockRange(float o, float bs, int b, int limit) {
    int s = int(ceil(o + float(b) * bs - 0.5f)), e = int(ceil(o + float(b + 1) * bs - 0.5f));
    return clamp(int2(s, e), int2(0), int2(limit));
}

// Mosaic, step 1: the mean of each block's part of each picture row, one thread per (block column, row).
// Output columns x (rows of picture pixels), row j = picture row i.w + j. i.x columns, i.y rows, i.z sharp, i.w first row.
// a.xy = block size (frame / count), divided on the CPU: GPU division is not exact on every backend (D3D allows 2.5 ulp),
// and an inexact block size moves whole pixel rows to the neighboring block.
[shader("compute")][numthreads(16, 16, 1)]
void filterMosaicRows(uint3 tid : SV_DispatchThreadID) {
    if (int(tid.x) >= u.i.x || tid.y >= outSize().y) return;
    float o = u.center.x - u.frame.x * 0.5f, bw = u.a.x;
    int2 r = blockRange(o, bw, int(tid.x), int(inSize().x));
    int y = u.i.w + int(tid.y);
    float4 acc = float4(0.0f);
    for (int x = r.x; x < r.y; x++) acc += read0(int2(x, y));
    out0.Store(tid.xy, r.y > r.x ? acc / float(r.y - r.x) : float4(0.0f));
}

// Step 2: one thread per block, the mean of its row means (or the pixel under its center: Sharp Colors, or a block
// holding no pixel center). in0 = picture, in1 = row means.
[shader("compute")][numthreads(16, 16, 1)]
void filterMosaicBlocks(uint3 tid : SV_DispatchThreadID) {
    if (int(tid.x) >= u.i.x || int(tid.y) >= u.i.y) return;
    float2 o = u.center - u.frame * 0.5f, bs = u.a.xy;
    uint2 s = inSize();
    int W = int(s.x), H = int(s.y);
    int2 rx = blockRange(o.x, bs.x, int(tid.x), W), ry = blockRange(o.y, bs.y, int(tid.y), H);
    if (u.i.z != 0 || rx.y <= rx.x || ry.y <= ry.x) {
        int2 p = int2(floor(o + (float2(tid.xy) + 0.5f) * bs));
        bool inside = p.x >= 0 && p.y >= 0 && p.x < W && p.y < H;
        out0.Store(tid.xy, inside ? read0(p) : float4(0.0f));
        return;
    }
    float4 acc = float4(0.0f);
    for (int y = ry.x; y < ry.y; y++) acc += read1(int2(int(tid.x), y - u.i.w));
    out0.Store(tid.xy, acc / float(ry.y - ry.x));
}

// Step 3: in0 = picture, in1 = blocks.
[shader("compute")][numthreads(16, 16, 1)]
void filterMosaicApply(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float2 q = float2(tid.xy) + 0.5f - (u.center - u.frame * 0.5f);
    if (q.x < 0.0f || q.y < 0.0f || q.x >= u.frame.x || q.y >= u.frame.y) { out0.Store(tid.xy, read0(int2(tid.xy))); return; }
    float2 bs = u.a.xy;
    int2 b = int2(q / bs);
    // floor(q / bs) settled with exact products: the quotient may be one ulp off (D3D) right at a block edge.
    for (int c = 0; c < 2; c++) {
        if (float(b[c]) * bs[c] > q[c]) b[c] -= 1;
        else if (float(b[c] + 1) * bs[c] <= q[c]) b[c] += 1;
    }
    b = min(b, u.i.xy - 1);
    out0.Store(tid.xy, read1(b));
}

// ---- Unsharp Mask and Glow (were ImageFilters.msl) ----

// in0 = picture, in1 = its Gaussian blur. a.x amount, a.y threshold, i = picture pixel rect: outside it the picture passes through.
[shader("compute")][numthreads(16, 16, 1)]
void filterUnsharp(uint3 tid : SV_DispatchThreadID) {
    uint2 s = inSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    int2 g = int2(tid.xy);
    float4 p = read0(g);
    bool inside = g.x >= u.i.x && g.y >= u.i.y && g.x <= u.i.z && g.y <= u.i.w;
    float4 d = p - read1(g);
    if (inside && max(max(abs(d.x), abs(d.y)), abs(d.z)) > u.a.y) {
        p = max(p + u.a.x * d, float4(0.0f));
        p.a = min(p.a, 1.0f);
    }
    out0.Store(tid.xy, p);
}

// Glow, step 1 into a plane reduced by i.y: each texel is the mean bright pass of its i.y x i.y block of picture pixels
// (a box, not one tap, so a 1 px highlight neither vanishes nor flickers as it moves). a.x threshold, b.xyz linear tint,
// i.x = 1 when tinted.
float4 glowBright(float4 p) {
    if (p.a <= 0.0f) return float4(0.0f);
    float luma = dot(p.rgb / p.a, float3(0.2126f, 0.7152f, 0.0722f));
    float w = clamp((luma - u.a.x) / max(1.0f - u.a.x, 1e-3f), 0.0f, 1.0f);
    return (u.i.x != 0 ? float4(u.b.rgb * p.a, p.a) : p) * w;
}

[shader("compute")][numthreads(16, 16, 1)]
void filterGlowBright(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize(), s = inSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    int r = max(u.i.y, 1), W = int(s.x), H = int(s.y);
    int2 o = int2(tid.xy) * r;
    float4 acc = float4(0.0f);
    for (int j = 0; j < r; j++) for (int i = 0; i < r; i++) {
        int2 p = o + int2(i, j);
        if (p.x < W && p.y < H) acc += glowBright(read0(p));
    }
    out0.Store(tid.xy, acc / float(r * r));
}

// Step 3: in0 = picture, in1 = blurred reduced plane; a.y intensity; the plane covers (its size x i.y) picture px.
[shader("compute")][numthreads(16, 16, 1)]
void filterGlowAdd(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    uint gw, gh;
    in1.GetDimensions(gw, gh);
    float2 covered = float2(float(gw), float(gh)) * float(max(u.i.y, 1));
    float4 g = in1.SampleLevel(edgeSampler, (float2(tid.xy) + 0.5f) / covered, 0.0f) * u.a.y;
    float4 p = read0(int2(tid.xy));
    out0.Store(tid.xy, float4(p.rgb + g.rgb, min(1.0f, p.a + g.a * (1.0f - p.a))));
}

#include "Parts/Style.slang"
#include "Parts/Outline.slang"
