// C5 Outline and Long Shadow (were OutlineFilters.msl; CPU notes in SQRender OutlineFilters). Part of Filters.slang.
// Seed texels whose x is beyond this are empty (OutlineFilters.emptySeed).
static const float emptySeed = 30000.0f;

float outlineAlpha(int2 p) {
    uint2 s = inSize();
    if (p.x < 0 || p.y < 0 || p.x >= int(s.x) || p.y >= int(s.y)) return 0.0f;
    return read0(p).a;
}

// Seed: the nearest alpha 0.5 crossing toward a 4-neighbor on the other side, as (0, 0, sub-pixel offset).
[shader("compute")][numthreads(16, 16, 1)]
void filterOutlineSeed(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    int2 g = int2(tid.xy);
    float a = outlineAlpha(g);
    bool inside = a >= 0.5f;
    float bestT = 2.0f;
    float2 off = float2(0.0f);
    int2 nb[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int k = 0; k < 4; k++) {
        float an = outlineAlpha(g + nb[k]);
        if ((an >= 0.5f) == inside) continue;
        float t = clamp((0.5f - a) / (an - a), 0.0f, 1.0f);
        if (t < bestT) { bestT = t; off = float2(nb[k]) * t; }
    }
    out0.Store(tid.xy, bestT <= 1.0f ? float4(0.0f, 0.0f, off) : float4(emptySeed, 0.0f, 0.0f, 0.0f));
}

// One jump-flood pass, step i.x px: keep the nearest of the 9 seeds at step distance.
[shader("compute")][numthreads(16, 16, 1)]
void filterOutlineJump(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    int W = int(os.x), H = int(os.y);
    if (int(tid.x) >= W || int(tid.y) >= H) return;
    int2 g = int2(tid.xy);
    float4 best = read0(g);
    float bd = best.x < 10000.0f ? length(best.xy + best.zw) : 1e9f;
    int step = u.i.x;
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        if (i == 0 && j == 0) continue;
        int2 q = g + int2(i, j) * step;
        if (q.x < 0 || q.y < 0 || q.x >= W || q.y >= H) continue;
        float4 s = read0(q);
        if (s.x >= 10000.0f) continue;
        float2 ip = float2(q - g) + s.xy;
        float d = length(ip + s.zw);
        if (d < bd) { bd = d; best = float4(ip, s.zw); }
    }
    out0.Store(tid.xy, best);
}

// in0 = picture, in1 = seeds. a.x width, a.y softness (texture px), b.rgb linear color, i.x position (0 outside, 1 inside,
// 2 center).
[shader("compute")][numthreads(16, 16, 1)]
void filterOutlineApply(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    float4 p = read0(int2(tid.xy));
    float4 s = read1(int2(tid.xy));
    float d = s.x < 10000.0f ? length(s.xy + s.zw) : 1e9f;
    float sd = p.a >= 0.5f ? -d : d;           // signed distance to the edge, < 0 inside the picture
    float w = u.a.x, soft = max(u.a.y, 1.0f);
    float3 col = u.b.rgb;
    if (u.i.x == 1) {
        // Inside: the band within `w` of the edge takes the color, the picture's alpha stays.
        float cov = clamp((w + sd) / soft + 0.5f, 0.0f, 1.0f);
        out0.Store(tid.xy, float4(lerp(p.rgb, col * p.a, cov), p.a));
    } else if (u.i.x == 2) {
        float cov = clamp((0.5f * w - abs(sd)) / soft + 0.5f, 0.0f, 1.0f);
        out0.Store(tid.xy, float4(col * cov, cov) + p * (1.0f - cov));
    } else {
        // Outside: under the picture, from just inside the edge out to `w`.
        float cov = clamp((w - sd) / soft + 0.5f, 0.0f, 1.0f) * clamp(sd + 1.0f, 0.0f, 1.0f);
        out0.Store(tid.xy, p + float4(col * cov, cov) * (1.0f - p.a));
    }
}

// One doubling pass: a.xy the step back along the shadow (texture px), a.z the fade over that step; i.x = 1 reads the
// picture's alpha (first pass), else the plane's red.
[shader("compute")][numthreads(16, 16, 1)]
void filterLongShadowStep(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    float2 size = float2(os);     // plane px (in0 may be the larger picture)
    float2 c = float2(tid.xy) + 0.5f;
    float4 s0 = in0.SampleLevel(zeroSampler, c / size, 0.0f), s1 = in0.SampleLevel(zeroSampler, (c - u.a.xy) / size, 0.0f);
    float a0 = u.i.x == 1 ? s0.a : s0.r, a1 = u.i.x == 1 ? s1.a : s1.r;
    out0.Store(tid.xy, float4(max(a0, a1 - u.a.z)));
}

// in0 = picture, in1 = plane (may be smaller: sampled linear at the same normalized spot). b.rgb linear color, a.w opacity.
[shader("compute")][numthreads(16, 16, 1)]
void filterLongShadowApply(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    float4 p = read0(int2(tid.xy));
    float2 n = (float2(tid.xy) + 0.5f) / float2(os);
    float s = clamp(in1.SampleLevel(zeroSampler, n, 0.0f).r, 0.0f, 1.0f) * u.a.w;
    out0.Store(tid.xy, p + float4(u.b.rgb * s, s) * (1.0f - p.a));
}
