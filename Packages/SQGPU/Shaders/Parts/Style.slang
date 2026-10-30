// FB-T2 style filters (were StyleFilters.msl; CPU references in SQRender StyleFilters). Part of Filters.slang (FilterU u).
static const float M_PI_F = 3.14159265358979323846f;

float sqEnc(float x) { x = max(x, 0.0f); return x < 0.018053968f ? x * 4.5f : 1.09929682680944f * pow(x, 0.45f) - 0.09929682680944f; }
float sqDec(float e) { e = max(e, 0.0f); return e < 0.081242858f ? e / 4.5f : pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f); }
float sqSmooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0f, 1.0f); return t * t * (3.0f - 2.0f * t); }

float vignetteFalloff(float2 q) {
    float2 d = q - u.center;
    float2 e = d / (u.frame * 0.5f);
    float2 circle = d / (sqrt(u.frame.x * u.frame.y) * 0.5f);
    float r;
    if (u.a.z >= 0.0f) { r = length(e + (circle - e) * u.a.z); }
    else { float n = 2.0f + 8.0f * -u.a.z; r = pow(pow(abs(e.x), n) + pow(abs(e.y), n), 1.0f / n); }
    float m = 0.35f + 0.9f * u.a.y, w = 0.05f + 0.6f * u.a.w;
    return sqSmooth(m - w, m + w, r);
}

float sqHalftone(float2 q, float y) {
    float2 d = q - u.center; float c = cos(u.a.y), s = sin(u.a.y);
    float2 r = float2(c * d.x + s * d.y, -s * d.x + c * d.y) / u.a.x;
    float2 f = r - floor(r) - float2(0.5f);
    float rn = length(f) / 0.70710678f;
    float soft = 0.02f + 0.3f * u.a.z;
    bool color = u.i.x != 0;
    float rho = sqrt(color ? y : 1.0f - y) * (1.0f + 2.0f * soft) - soft;
    float edge = sqSmooth(rho - soft, rho + soft, rn);
    return color ? 1.0f - edge : edge;
}

[shader("compute")][numthreads(16, 16, 1)]
void filterStylePixel(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    if (tid.x >= os.x || tid.y >= os.y) return;
    float4 p = read0(int2(tid.xy));
    float2 q = float2(tid.xy) + 0.5f;
    int op = u.i.w;
    if (op == 1 && u.a.x < 0.0f) { float k = exp2(u.a.x * vignetteFalloff(q)); out0.Store(tid.xy, float4(p.rgb * k, p.a)); return; }
    if (op == 12) {
        float2 o = u.center - u.frame * 0.5f;
        float d = min(min(q.x - o.x, o.x + u.frame.x - q.x), min(q.y - o.y, o.y + u.frame.y - q.y));
        out0.Store(tid.xy, p * sqSmooth(0.0f, u.a.x, max(d, 0.0f))); return;
    }
    if (op == 8) {
        float3 c = p.a > 0.0f ? p.rgb / p.a : float3(0.0f);
        float a = u.i.x != 0 ? 1.0f : p.a;
        if (u.i.y != 0) a = 1.0f - a;
        a *= u.a.x;
        float3 col = u.i.z != 0 ? float3(1.0f) : c;
        out0.Store(tid.xy, float4(col * a, a)); return;
    }
    if (op == 7 && u.i.y != 0) { out0.Store(tid.xy, p * u.a.w); return; }
    if (op == 3 && u.i.x == 4) {
        float a = p.a + ((1.0f - p.a) - p.a) * (1.0f - u.a.x);
        float3 c = p.a > 0.0f ? p.rgb / p.a : float3(0.0f);
        out0.Store(tid.xy, float4(c * a, a)); return;
    }
    if (p.a <= 0.0f) { out0.Store(tid.xy, p); return; }
    float3 lin = p.rgb / p.a;
    float3 e = float3(sqEnc(lin.r), sqEnc(lin.g), sqEnc(lin.b));
    float3 o = e;
    const float3 lw = float3(0.2126f, 0.7152f, 0.0722f);
    if (op == 1) {
        float k = exp2(-u.a.x * vignetteFalloff(q));
        o = max(float3(1.0f) - (float3(1.0f) - min(e, float3(1.0f))) * k, e);
    } else if (op == 3) {
        float3 ce = clamp(e, float3(0.0f), float3(1.0f)), inv = e;
        // One channel picked by a mask: fxc cannot write a vector at a runtime index.
        bool3 pick = u.i.x == 0 ? bool3(true, true, true) : bool3(u.i.x == 1, u.i.x == 2, u.i.x == 3);
        inv = select(pick, float3(1.0f) - ce, e);
        o = inv + (e - inv) * u.a.x;
    } else if (op == 4) {
        float l = u.a.x - 1.0f;
        o = round(clamp(e, float3(0.0f), float3(1.0f)) * l) / l;
    } else if (op == 5) {
        float y = clamp(dot(e, lw), 0.0f, 1.0f);
        float3 target = u.a.rgb + (u.b.rgb - u.a.rgb) * y;
        o = e + (target - e) * u.a.w;
    } else if (op == 6) {
        o = (e - 0.5f) * u.a.y + 0.5f + u.a.x * 0.4f;
    } else if (op == 9) {
        float2 d = (q - u.center) / u.b.w;
        float g = u.a.w * exp(-2.0f * dot(d, d));
        float t = clamp(0.5f + 0.5f * dot(d, u.frame), 0.0f, 1.0f);
        float3 light = min((u.a.rgb + (u.b.rgb - u.a.rgb) * t) * g, float3(1.0f));
        o = e + light * max(float3(1.0f) - e, float3(0.0f));
    } else if (op == 10) {
        float2 d = q - u.center; float len2 = dot(u.frame, u.frame);
        float t = 0.0f;
        if (len2 > 1e-12f) t = u.i.x != 0 ? length(d) / sqrt(len2) : dot(d, u.frame) / len2;
        t = clamp(t, 0.0f, 1.0f);
        o = e + ((u.a.rgb + (u.b.rgb - u.a.rgb) * t) - e) * u.a.w;
    } else if (op == 11) {
        float y = clamp(dot(e, lw), 0.0f, 1.0f);
        float m = sqHalftone(q, y);
        float3 target = u.i.x != 0 ? e * m : float3(m);
        o = e + (target - e) * u.a.w;
    } else if (op == 7) {
        float3 s = u.a.rgb, r = s;
        if (u.i.x == 1) r = e + s;
        else if (u.i.x == 2) r = e * s;
        else if (u.i.x == 3) r = float3(1.0f) - (float3(1.0f) - e) * (float3(1.0f) - s);
        else if (u.i.x == 4) r = abs(e - s);
        o = r + (e - r) * u.a.w;
    } else { out0.Store(tid.xy, p); return; }
    out0.Store(tid.xy, float4(float3(sqDec(o.r), sqDec(o.g), sqDec(o.b)) * p.a, p.a));
}

float sqWave(float x, int type) {
    if (type == 1) return x - floor(x) < 0.5f ? 1.0f : -1.0f;
    if (type == 2) { float f = x - 0.25f - floor(x - 0.25f); return 4.0f * abs(f - 0.5f) - 1.0f; }
    if (type == 3) { float f = x + 0.5f - floor(x + 0.5f); return 2.0f * f - 1.0f; }
    return sin(2.0f * M_PI_F * x);
}

float2 sqFoldIntoFrame(float2 s) {
    float2 lo = u.center - u.frame * 0.5f;
    float2 t = (s - lo) / u.frame;
    float2 m = t - 2.0f * floor(t / 2.0f);
    float2 f = float2(m.x > 1.0f ? 2.0f - m.x : m.x, m.y > 1.0f ? 2.0f - m.y : m.y);
    float2 inner = lo + 0.5f, outer = lo + u.frame - 0.5f;   // half a texel inside: no blend with the outside at the fold line
    return min(max(lo + f * u.frame, inner), max(inner, outer));
}

float2 warpSource(float2 q) {
    int op = u.i.w;
    if (op == 29) {
        float2 d = q - u.center;
        return sqFoldIntoFrame(u.center + float2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + u.b.xy);
    }
    if (op == 20) return float2(u.i.x != 0 ? 2.0f * u.center.x - q.x : q.x, u.i.y != 0 ? 2.0f * u.center.y - q.y : q.y);
    if (op == 21) {
        float2 d = q - u.center; float r = length(d), big = u.a.y;
        if (r >= big || big <= 0.0f) return q;
        float k = 1.0f - r / big, th = -u.a.x * k * k, c = cos(th), s = sin(th);
        return u.center + float2(c * d.x - s * d.y, s * d.x + c * d.y);
    }
    if (op == 22) {
        float2 o = u.center - u.frame * 0.5f, dir = u.a.zw, across = float2(-u.a.w, u.a.z);
        float x = dot(q - o, dir) / u.a.y + u.b.x;
        float2 n = (q - o) / u.frame;
        float ex = sqSmooth(0.0f, 0.1f, min(n.x, 1.0f - n.x)), ey = sqSmooth(0.0f, 0.1f, min(n.y, 1.0f - n.y));
        float pin = u.i.y == 1 ? ex * ey : (u.i.y == 2 ? ey : (u.i.y == 3 ? ex : 1.0f));
        return q - across * (u.a.x * sqWave(x, u.i.x) * pin);
    }
    if (op == 23) {
        float2 d = q - u.center; float r = length(d), big = u.a.x;
        if (r >= big || r <= 0.0f) return q;
        float n = r / big, s = u.a.y;
        float f = s > 0.0f ? n + (2.0f / M_PI_F * asin(n) - n) * s : n + (sin(n * M_PI_F / 2.0f) - n) * -s;
        return u.center + d * (f / n);
    }
    if (op == 25) {
        float2 o = u.center - u.frame * 0.5f;
        float2 t = (q - o) / u.frame * u.a.xy + u.a.zw;
        float2 f = t - floor(t);
        if (u.b.x != 0.0f) {
            float2 m = t - 2.0f * floor(t / 2.0f);
            f = float2(m.x > 1.0f ? 2.0f - m.x : m.x, m.y > 1.0f ? 2.0f - m.y : m.y);
        }
        return o + f * u.frame;
    }
    if (op == 26) {
        float2 d = q - u.center; float r = length(d);
        if (r <= 0.0f) return q;
        float w = u.a.x, th = atan2(d.y, d.x);
        float m = th - w * floor(th / w);
        float a = abs(m - w / 2.0f) + u.a.y;
        return u.center + r * u.a.z * float2(cos(a), sin(a));
    }
    if (op == 24) {
        float2 d = q - u.center;
        return u.center + float2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + u.b.xy;
    }
    if (op == 28) {
        float2 d = q - u.center;
        float den = u.b.z * d.x + u.b.w * d.y + 1.0f;
        if (u.i.x != 0 || den <= 1e-6f) return float2(-1e6f, -1e6f);
        return u.center + float2(u.a.x * d.x + u.a.y * d.y + u.a.z, u.a.w * d.x + u.b.x * d.y + u.b.y) / den;
    }
    if (op == 27) {
        if (u.i.y != 0) {
            float2 d = q - u.center;
            float den = u.d.z * d.x + u.d.w * d.y + 1.0f;
            if (den <= 1e-6f) return float2(-1e6f, -1e6f);
            q = u.center + float2(u.c.x * d.x + u.c.y * d.y + u.c.z, u.c.w * d.x + u.d.x * d.y + u.d.y) / den;
        }
        float2 s = u.a.xy; float ext = max(u.a.z, 1.0f); bool alongX = u.i.x != 0;
        float v0 = (alongX ? q.x - u.center.x : q.y - u.center.y) / ext;
        float v = v0 / max(1.0f - (alongX ? s.x : s.y) / ext, 0.5f);
        float2 lo = u.center - u.frame * 0.5f + 0.5f, hi = u.center + u.frame * 0.5f - 0.5f;
        return min(max(q + s * v, lo), max(lo, hi));
    }
    return q;
}

float4 sampleZ(float2 uv) { return in0.SampleLevel(zeroSampler, uv, 0.0f); }

[shader("compute")][numthreads(16, 16, 1)]
void filterStyleWarp(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    float2 size = float2(os);
    if (tid.x >= os.x || tid.y >= os.y) return;
    float gain = u.i.w == 24 ? u.b.z : 1.0f;
    float2 q = float2(tid.xy) + 0.5f;
    if (u.i.w == 29) {      // Edge Fill: the margin outside the frame passes through; reads past the edge are mirrored
        float2 d = abs(q - u.center);
        if (d.x > u.frame.x * 0.5f || d.y > u.frame.y * 0.5f) { out0.Store(tid.xy, sampleZ(q / size)); return; }
        float2 d0 = q - u.center;
        float2 raw = u.center + float2(u.a.x * d0.x + u.a.y * d0.y, u.a.z * d0.x + u.a.w * d0.y) + u.b.xy;
        float4 sharp = sampleZ(sqFoldIntoFrame(raw) / size);
        float2 lo = u.center - u.frame * 0.5f, hi = u.center + u.frame * 0.5f;
        float ov = length(max(max(lo - raw, raw - hi), float2(0.0f)));
        if (u.i.x != 2 || ov <= 0.0f) { out0.Store(tid.xy, sharp); return; }
        // Blur Edge: the further past the edge, the wider the blur (a 9 x 9 spread of mirrored taps, half-width up to 3 % of the frame).
        float big = max(u.frame.x, u.frame.y);
        float w = smoothstep(0.0f, 0.02f * big, ov), r = 0.03f * big * w * 0.25f;
        float4 acc = float4(0.0f);
        for (int j = -4; j <= 4; j++) for (int i = -4; i <= 4; i++)
            acc += sampleZ(sqFoldIntoFrame(raw + float2(float(i), float(j)) * r) / size);
        out0.Store(tid.xy, lerp(sharp, acc / 81.0f, w));
        return;
    }
    if (u.i.w == 27) {      // Rolling Shutter: the margin around the clip's own frame passes through
        float2 d = abs(q - u.center);
        if (d.x > u.frame.x * 0.5f || d.y > u.frame.y * 0.5f) { out0.Store(tid.xy, sampleZ(q / size)); return; }
    }
    out0.Store(tid.xy, sampleZ(warpSource(q) / size) * gain);
}

bool sqInPicture(float2 q) {
    float2 o = u.a.zw;
    return q.x >= o.x && q.y >= o.y && q.x <= o.x + u.frame.x && q.y <= o.y + u.frame.y;
}

float4 sqCubicW(float t) {
    return float4(((-0.5f * t + 1.0f) * t - 0.5f) * t, (1.5f * t - 2.5f) * t * t + 1.0f, ((-1.5f * t + 2.0f) * t + 0.5f) * t, (0.5f * t - 0.5f) * t * t);
}
// StyleFilters.lensHold.
float2 sqLensHold(float2 p, out float cover) {
    float2 o = u.a.zw, e = o + u.frame;
    cover = 1.0f;
    if (u.i.y != 0) return clamp(p, o + 0.5f, e - 0.5f);
    float2 m = clamp(min(p - o, e - p) + 0.5f, float2(0.0f), float2(1.0f));
    cover = m.x * m.y;
    return p;
}
// Bilinear clamp-to-edge tap at texel position p (Metal used a pixel-coordinate sampler; Slang samplers are normalized).
float4 sqEdgeTap(float2 p) { return in0.SampleLevel(edgeSampler, p / float2(inSize()), 0.0f); }
// StyleFilters.lensTap: Catmull-Rom without the block's corners as five bilinear fetches (the two middle texels of
// each axis share one fetch at their weighted position).
float4 sqLensTap(float2 p) {
    float2 o = u.a.zw, e = o + u.frame;
    float cover;
    p = sqLensHold(p, cover);
    if (cover <= 0.0f) return u.b;
    float2 lo = ceil(o - 0.5f) + 0.5f, hi = floor(e - 0.5f) + 0.5f;
    float2 q = p - 0.5f, b = floor(q);
    float4 wx = sqCubicW(q.x - b.x), wy = sqCubicW(q.y - b.y);
    float2 w12 = float2(wx.y + wx.z, wy.y + wy.z);
    float2 c0 = clamp(b - 0.5f, lo, hi), c12 = clamp(b + 0.5f + float2(wx.z, wy.z) / w12, lo, hi), c3 = clamp(b + 2.5f, lo, hi);
    float4 acc = sqEdgeTap(float2(c12.x, c0.y)) * (w12.x * wy.x) + sqEdgeTap(float2(c0.x, c12.y)) * (wx.x * w12.y)
        + sqEdgeTap(c12) * (w12.x * w12.y) + sqEdgeTap(float2(c3.x, c12.y)) * (wx.w * w12.y)
        + sqEdgeTap(float2(c12.x, c3.y)) * (w12.x * wy.w);
    acc /= 1.0f - (wx.x + wx.w) * (wy.x + wy.w);
    return acc * cover + u.b * (1.0f - cover);
}
// StyleFilters.lensTapLinear.
float4 sqLensLinear(float2 p) {
    float2 o = u.a.zw, e = o + u.frame;
    float cover;
    p = sqLensHold(p, cover);
    if (cover <= 0.0f) return u.b;
    return sqEdgeTap(clamp(p, ceil(o - 0.5f) + 0.5f, floor(e - 0.5f) + 0.5f)) * cover + u.b * (1.0f - cover);
}

[shader("compute")][numthreads(16, 16, 1)]
void filterLens(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    float2 size = float2(os);
    if (tid.x >= os.x || tid.y >= os.y) return;
    float2 q = float2(tid.xy) + 0.5f;
    if (!sqInPicture(q)) { out0.Store(tid.xy, sampleZ(q / size)); return; }
    if (u.i.z == 0) {       // the look of effects saved before F7.15 (StyleFilters.lensLegacySource)
        float2 d = q - u.center; float r = length(d) / u.a.y, k = u.a.x;
        float f = k >= 0.0f ? 1.0f + k * r * r : 1.0f / (1.0f - k * r * r);
        float2 s = u.center + d * f;
        out0.Store(tid.xy, u.b.w > 0.0f && !sqInPicture(s) ? u.b : sampleZ(s / size));
        return;
    }
    float zoom = asfloat(u.i.x);
    float2 d = q - u.center; float len = length(d), rho = len / u.a.y * zoom, k = u.a.x;
    float f, g;
    if (k >= 0.0f) { f = 1.0f + k * rho * rho; g = 1.0f + 3.0f * k * rho * rho; }
    else {
        float a = -k, x = rho / (1.0f + a * rho * rho);
        for (int n = 0; n < 4; n++) x -= (x * (1.0f + a * x * x) - rho) / (1.0f + 3.0f * a * x * x);
        f = rho > 1e-6f ? x / rho : 1.0f; g = 1.0f / (1.0f + 3.0f * a * x * x);
    }
    float2 s = u.center + d * (zoom * f);
    float2 o = u.a.zw, e = o + u.frame;
    if (u.i.y == 0 && (s.x < o.x - 3.0f || s.y < o.y - 3.0f || s.x > e.x + 3.0f || s.y > e.y + 3.0f)) { out0.Store(tid.xy, u.b); return; }
    float2 stretch = float2(zoom * g, zoom * f);
    float t = clamp((max(stretch.x, stretch.y) - 1.15f) / 0.25f, 0.0f, 1.0f);
    float4 c = float4(0.0f);
    if (t < 1.0f) c += sqLensTap(s) * (1.0f - t);
    if (t > 0.0f) {
        float2 spread = clamp(stretch - 1.0f, float2(0.0f), float2(2.0f)) * 0.5f;
        float2 er = len > 1e-6f ? d / len : float2(1.0f, 0.0f), et = float2(-er.y, er.x);
        float2 a = er * spread.x, b = et * spread.y;
        c += (sqLensLinear(s + a + b) + sqLensLinear(s + a - b) + sqLensLinear(s - a + b) + sqLensLinear(s - a - b)) * (0.25f * t);
    }
    // StyleFilters.premultipliedHeld.
    float hold = c.a > 1.0f ? 1.0f / c.a : 1.0f;
    out0.Store(tid.xy, c.a <= 0.0f ? float4(0.0f) : float4(max(c.rgb, float3(0.0f)) * hold, min(c.a, 1.0f)));
}

[shader("compute")][numthreads(16, 16, 1)]
void filterGlitch(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    float2 size = float2(os);
    if (tid.x >= os.x || tid.y >= os.y) return;
    float2 q = float2(tid.xy) + 0.5f;
    uint id = uint(int((q.y - (u.center.y - u.frame.y * 0.5f)) / u.a.y)), seed = uint(u.i.x);
    float sx = hash01(id, 0u, seed, 0u) < u.a.w ? (hash01(id, 1u, seed, 1u) * 2.0f - 1.0f) * u.a.x : 0.0f;
    float4 r = sampleZ((q + float2(sx - u.a.z, 0.0f)) / size);
    float4 g = sampleZ((q + float2(sx, 0.0f)) / size);
    float4 b = sampleZ((q + float2(sx + u.a.z, 0.0f)) / size);
    out0.Store(tid.xy, float4(r.r, g.g, b.b, max(r.a, max(g.a, b.a))));
}

[shader("compute")][numthreads(16, 16, 1)]
void filterRGBSplit(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    float2 size = float2(os);
    if (tid.x >= os.x || tid.y >= os.y) return;
    float2 q = float2(tid.xy) + 0.5f, d = u.a.xy;
    if (u.i.x != 0) d = length(d) * (q - u.center) / u.a.w;
    float4 p = sampleZ(q / size), r = sampleZ((q - d) / size), b = sampleZ((q + d) / size);
    float4 s = float4(r.r, p.g, b.b, max(r.a, max(p.a, b.a)));
    out0.Store(tid.xy, s + (p - s) * u.a.z);
}

[shader("compute")][numthreads(16, 16, 1)]
void filterRadialBlur(uint3 tid : SV_DispatchThreadID) {
    uint2 os = outSize();
    float2 size = float2(os);
    if (tid.x >= os.x || tid.y >= os.y) return;
    float2 q = float2(tid.xy) + 0.5f, d = q - u.center;
    int n = u.i.y;
    float4 acc = float4(0.0f);
    for (int k = 0; k < n; k++) {
        float t = (float(k) / float(n - 1) - 0.5f) * u.a.x;
        float2 s;
        if (u.i.x != 0) s = u.center + d * (1.0f + t);
        else { float c = cos(t), sn = sin(t); s = u.center + float2(c * d.x - sn * d.y, sn * d.x + c * d.y); }
        acc += sampleZ(s / size);
    }
    out0.Store(tid.xy, acc / float(n));
}
