// Clip masks (was CompositorShaderSource.msl in SQRender; mirrors MaskCoverage.coverage, the CPU reference). Include after
// Parts/CompositeU.slang, Bindings.slang, Parts/Transfer.slang and Parts/Convert.slang; the module declares the mask data
// `maskData` as a data buffer: float2 entries, stored as pairs of float bits (data buffers have 4-byte elements).
// Per mask 4 header entries (start, count), (mode, inverted), (feather, expansion), (opacity, source), then the polygons'
// points in layer px (centered, like `local`).
// Source 1/2 = subject mask, its value is the matte `mt` over the clip's frame (no polygon), 2 = no matte; 3/4/5 = Magic
// masks packed into g/b/a of the same texture.
// 6/7 = Picture mask on `pm0` (shape = alpha, brightness = Rec.709 luma of the display-encoded straight color times alpha),
// 8/9 = the same on `pm1`. Its `start` points at 4 entries: the rows and translation of layer px -> the level's canvas px,
// then 1 / canvas size, then the draw's center, its tilt (x, y radians) and camera distance (focal, 0; focal 0 = flat): the
// affine map gives the place before the tilt, which is turned about the center like `compositeVertex` does. Fixed to the
// screen; outside the canvas the matte is 0.
float2 maskAt(uint i) { return float2(asfloat(maskData[2u * i]), asfloat(maskData[2u * i + 1u])); }

float pictureSample(float2 p, uint start, uint flag, Texture2D<float4> pm0, Texture2D<float4> pm1) {
    float2 r0 = maskAt(start), r1 = maskAt(start + 1), t = maskAt(start + 2), inv = maskAt(start + 3);
    float2 sp = float2(dot(r0, p), dot(r1, p)) + t;
    float focal = maskAt(start + 6).x;
    if (focal > 0.0f) {
        float2 c = maskAt(start + 4), tl = maskAt(start + 5);
        float2 v = sp - c;
        float ca = cos(tl.x), sa = sin(tl.x), cb = cos(tl.y), sb = sin(tl.y);
        float y1 = v.y * ca, z1 = -v.y * sa;
        float w = max((focal + v.x * sb + z1 * cb) / focal, 1e-3f);
        sp = c + float2(v.x * cb - z1 * sb, y1) / w;
    }
    float2 uv = sp * inv;
    if (any(uv < 0.0f) || any(uv > 1.0f)) { return 0.0f; }
    uint f = flag - 6u;
    float4 s = f < 2u ? pm0.SampleLevel(edgeSampler, uv, 0.0f) : pm1.SampleLevel(edgeSampler, uv, 0.0f);
    if ((f & 1u) == 0u) { return clamp(s.a, 0.0f, 1.0f); }
    if (s.a <= 0.0f) { return 0.0f; }
    float3 e = oetf709(clamp(s.rgb / s.a, 0.0f, 1.0f));
    return clamp(dot(e, float3(0.2126f, 0.7152f, 0.0722f)) * s.a, 0.0f, 1.0f);
}

// Flag 10 = Color range mask. `start` points at 3 entries: (r, g), (b, tolerance), (softness, 0); the key is display-encoded
// straight color; `pc` is the picture's own pixel in the same encoding. Mirrors ColorRangeKey.value.
float colorRangeValue(uint start, float3 pc) {
    float3 key = float3(maskAt(start).x, maskAt(start).y, maskAt(start + 1).x);
    float tol = maskAt(start + 1).y, soft = maskAt(start + 2).x;
    float d = length(pc - key) * 0.57735026919f;
    if (soft <= 1e-6f) { return d <= tol ? 1.0f : 0.0f; }
    float x = clamp((d - tol) / soft, 0.0f, 1.0f);
    return 1.0f - x * x * (3.0f - 2.0f * x);
}

float maskCombine(float acc, float c, uint mode) {
    if (mode == 0u) { return min(acc + c, 1.0f); }
    if (mode == 1u) { return max(acc - c, 0.0f); }
    if (mode == 2u) { return acc * c; }
    return abs(acc - c);
}

float maskCoverage(float2 p, CompositeU u, Texture2D<float4> mt, Texture2D<float4> pm0, Texture2D<float4> pm1, float3 pc) {
    float pixel = 1.0f / max(min(u.scale.x, u.scale.y), 1e-4f);
    float acc = 0.0f;
    for (uint m = 0; m < u.maskCount; m++) {
        float2 h0 = maskAt(m * 4), h1 = maskAt(m * 4 + 1), h2 = maskAt(m * 4 + 2), h3 = maskAt(m * 4 + 3);
        uint start = uint(h0.x), count = uint(h0.y), mode = uint(h1.x);
        if (m == 0 && (mode == 1u || mode == 2u)) { acc = 1.0f; }   // first Subtract / Intersect: from the whole frame
        if (h3.y != 0.0f) {
            // 1 = matte bound, 2 = none yet (no person). Outside the clip's frame (blur padding) there is no person.
            float2 ms = u.maskSize.x > 0.0f ? u.maskSize : u.size;
            float2 uv = p / ms + 0.5f;
            bool inFrame = all(uv >= 0.0f) && all(uv <= 1.0f);
            // Several mattes in one draw share the texture: 1 = r, 3 = g, 4 = b, 5 = a.
            float c = 0.0f;
            if (h3.y == 10.0f) { c = colorRangeValue(start, pc); }
            else if (h3.y >= 6.0f) { c = pictureSample(p, start, uint(h3.y), pm0, pm1); }
            else if (h3.y != 2.0f && inFrame) {
                float4 s = mt.SampleLevel(edgeSampler, uv, 0.0f);
                c = clamp(h3.y == 1.0f ? s.r : h3.y == 3.0f ? s.g : h3.y == 4.0f ? s.b : s.a, 0.0f, 1.0f);
            }
            if (h1.y != 0.0f) { c = 1.0f - c; }
            c *= h3.x;
            acc = maskCombine(acc, c, mode);
            continue;
        }
        float d2 = 1e30f;
        bool inside = false;
        if (count >= 2u) {
            uint j = start + count - 1;
            for (uint i = start; i < start + count; i++) {
                float2 a = maskAt(j), b = maskAt(i);
                float2 e = b - a, w = p - a;
                float ee = dot(e, e);
                float t = ee > 0.0f ? clamp(dot(w, e) / ee, 0.0f, 1.0f) : 0.0f;
                float2 q = w - e * t;
                d2 = min(d2, dot(q, q));
                if ((b.y > p.y) != (a.y > p.y) && p.x < (a.x - b.x) * (p.y - b.y) / (a.y - b.y) + b.x) { inside = !inside; }
                j = i;
            }
        }
        float d = sqrt(d2);
        if (inside) { d = -d; }
        d -= h2.y;
        float c;
        if (h2.x > pixel) {
            float hh = h2.x * 0.5f;
            float x = clamp((d + hh) / (2.0f * hh), 0.0f, 1.0f);
            c = 1.0f - x * x * (3.0f - 2.0f * x);
        } else {
            c = clamp(0.5f - d / pixel, 0.0f, 1.0f);
        }
        if (h1.y != 0.0f) { c = 1.0f - c; }
        c *= h3.x;
        acc = maskCombine(acc, c, mode);
    }
    return acc;
}
