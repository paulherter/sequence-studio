// The source conversion (was CompositorShaderSource.convertMSL in SQRender): Y'CbCr bi-planar, RGB and
// packed alpha sources to straight encoded color + alpha, at full or reduced size. Include after Parts/CompositeU.slang,
// Bindings.slang and Parts/Transfer.slang. ty = luma (or RGB / packed) plane, tc = chroma plane.

float3 ycbcrToRGB(CompositeU u, float3 v) { return u.m0.xyz * v.x + u.m1.xyz * v.y + u.m2.xyz * v.z; }

uint2 texSize(Texture2D<float4> t) { uint w, h; t.GetDimensions(w, h); return uint2(w, h); }

float3 sourceEncoded(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, float2 uv) {
    if (u.mode == 1) { return ty.SampleLevel(edgeSampler, uv, 0.0f).rgb; }
    float y = ty.SampleLevel(edgeSampler, uv, 0.0f).r * u.range.x + u.range.y;
    float2 c = tc.SampleLevel(edgeSampler, uv, 0.0f).rg * u.range.z + u.range.w;
    return ycbcrToRGB(u, float3(y, c.x, c.y));
}

// One texel of an alpha source (mode 4, or mode 1 with alphaMode != 0) as premultiplied R'G'B'A. Premultiplied
// Y'CbCr (offsets removed) maps to premultiplied R'G'B' through the same matrix (it is linear).
float4 texelPremul(CompositeU u, Texture2D<float4> ty, uint2 p) {
    float4 t = ty.Load(int3(int2(p), 0));
    float4 c;
    if (u.mode == 4) {
        float3 ycc = float3(t.g * u.range.x + u.range.y, t.b * u.range.z + u.range.w, t.a * u.range.z + u.range.w);
        c = float4(ycbcrToRGB(u, ycc), t.r);
    } else {
        c = t;
    }
    // Premultiplied color cannot exceed its alpha; lossy coding overshoots at soft edges.
    if (u.alphaMode == 2u) { c.rgb = clamp(c.rgb, 0.0f, c.a); } else { c.rgb *= c.a; }
    return c;
}

// Bilinear sample of premultiplied color (clamp to edge).
float4 samplePremul(CompositeU u, Texture2D<float4> ty, float2 uv) {
    int2 mx = int2(texSize(ty)) - 1;
    float2 p = uv * float2(mx + 1) - 0.5f;
    float2 fl = floor(p), f = p - fl;
    int2 i0 = int2(fl);
    uint2 a = uint2(clamp(i0, int2(0), mx)), b = uint2(clamp(i0 + 1, int2(0), mx));
    float4 t00 = texelPremul(u, ty, a), t10 = texelPremul(u, ty, uint2(b.x, a.y));
    float4 t01 = texelPremul(u, ty, uint2(a.x, b.y)), t11 = texelPremul(u, ty, b);
    return lerp(lerp(t00, t10, f.x), lerp(t01, t11, f.x), f.y);
}

bool alphaSource(CompositeU u) { return u.mode == 4 || (u.mode == 1 && u.alphaMode != 0u); }

float3 inverseOETF709(float3 e) {
    e = max(e, 0.0f);
    float3 lo = e / 4.5f;
    float3 hi = pow((e + 0.09929682680944f) / 1.09929682680944f, float3(1.0f / 0.45f));
    return select(e < 0.081242858f, lo, hi);
}

// BT.709 OETF (exact inverse of inverseOETF709, extended above 1 by the same curve).
float3 oetf709(float3 l) {
    l = max(l, 0.0f);
    float3 hi = 1.09929682680944f * pow(l, float3(0.45f)) - 0.09929682680944f;
    return select(l < 0.018053968510807f, l * 4.5f, hi);
}

// Straight encoded color + alpha of one point of a mode 0 or mode 1 source.
float4 convertPoint(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, float2 uv) {
    if (u.mode == 1) {
        float4 c = ty.SampleLevel(edgeSampler, uv, 0.0f);
        return float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
    }
    return float4(sourceEncoded(u, ty, tc, uv), 1.0f);
}

float4 straightPoint(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, float2 q) {
    if (alphaSource(u)) {
        float4 c = samplePremul(u, ty, q);
        return float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
    }
    return convertPoint(u, ty, tc, q);
}

float3 decodeCurve(float3 e, uint transfer) {
    return transfer == 2u ? sign(e) * inverseOETF709(abs(e)) : transfer < 30u ? map3(e, int(transfer)) : e;
}
float3 encodeCurve(float3 m, uint transfer) {
    return transfer == 2u ? sign(m) * oetf709(abs(m)) : transfer < 30u ? map3(m, int(transfer) + 10) : m;
}

// What convertToRGB writes at `gid` of an `outSize` texture. Half resolution: the 2 x 2 source texels averaged in light
// (through `transfer`, the source curve; any value >= 30: plain average of the encoded values), weighted by alpha.
float4 convertTexel(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, uint transfer, uint2 gid, uint2 outSize) {
    float2 uv = (float2(gid) + 0.5f) / float2(outSize);
    uint2 ts = texSize(ty);
    if (outSize.x < ts.x) {
        float2 d = 0.5f / float2(ts);
        float3 acc = float3(0.0f);
        float a = 0.0f;
        for (int k = 0; k < 4; k++) {
            float2 q = uv + float2((k & 1) != 0 ? d.x : -d.x, (k & 2) != 0 ? d.y : -d.y);
            float4 e = straightPoint(u, ty, tc, q);
            acc += decodeCurve(e.rgb, transfer) * e.a;
            a += e.a;
        }
        float3 m = a > 0.0f ? acc / a : float3(0.0f);
        return float4(encodeCurve(m, transfer), a * 0.25f);
    }
    return straightPoint(u, ty, tc, uv);
}

// Preview only (Compositor.gradesAtDisplaySize): converts to the size the layer is shown at, any ratio; n x n samples
// per output texel (n = ceil(ratio), 1...4 per axis), averaged in light like the half-size path.
float4 convertTexelScaled(CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, uint transfer, uint2 gid, uint2 outPixels) {
    float2 outSz = float2(outPixels);
    float2 ts = float2(texSize(ty));
    float2 uv = (float2(gid) + 0.5f) / outSz;
    float2 ratio = ts / outSz;
    int2 n = clamp(int2(ceil(ratio - 0.01f)), int2(1), int2(4));
    float2 stp = ratio / float2(n) / ts;
    float3 acc = float3(0.0f);
    float a = 0.0f;
    for (int j = 0; j < n.y; j++) {
        for (int i = 0; i < n.x; i++) {
            float2 q = uv + (float2(float(i), float(j)) + 0.5f - float2(n) * 0.5f) * stp;
            float4 e = straightPoint(u, ty, tc, q);
            acc += decodeCurve(e.rgb, transfer) * e.a;
            a += e.a;
        }
    }
    float3 m = a > 0.0f ? acc / a : float3(0.0f);
    return float4(encodeCurve(m, transfer), a / float(n.x * n.y));
}
