// Shading of one layer draw (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor). Include after
// Parts/LayerVertex.slang, Bindings.slang, Parts/Transfer.slang, Parts/Convert.slang and Parts/Mask.slang (the module
// declares `maskData` at u2). Fragment inputs: in0 = luma (or RGB / packed / group image), in1 = chroma, in3 = subject /
// Magic matte, in4 / in5 = Picture mask sources.

// One key (Ultra Key chroma, or luma when matte.w == 1) on un-premultiplied linear color: returns K (how much is keyed
// out) and desaturates spill / color-corrects `c`. Mirrors UltraKey.key (CPU reference) and MatteRefine.tone.
//   k: chroma (hue, half width, soft, spill) | luma (threshold, softness, keys brights, 0)
//   m: shrink / grow, pedestal, output (0 composite, 1 alpha, 2 source), mode
//   sh: contrast, midpoint, keep highlights, keep shadows      cc: saturation, hue shift (rad), brightness, spill range
float shapeMatte(float kk, float4 m, float4 sh) {
    float r = kk;
    if (m.y > 0.0f) { r = clamp((r - m.y) / max(1.0f - m.y, 1e-4f), 0.0f, 1.0f); }
    if (m.x != 0.0f || sh.x > 0.0f) {
        float c = 1.0f - r;
        if (m.x > 0.0f) {
            float s = 0.9f * min(m.x, 1.0f);
            c = clamp((c - s) / max(1.0f - s, 1e-4f), 0.0f, 1.0f);
        } else if (m.x < 0.0f) {
            float g = 0.9f * min(-m.x, 1.0f);
            c = min(c / max(1.0f - g, 1e-4f), 1.0f);
        }
        if (sh.x > 0.0f) { c = clamp((c - sh.y) * (1.0f + 9.0f * min(sh.x, 1.0f)) + sh.y, 0.0f, 1.0f); }
        r = 1.0f - c;
    }
    return r;
}

float applyChromaKey(float4 k, float4 matte, float4 sh, float4 cc, inout float3 c) {
    if (matte.z == 2.0f) { return 0.0f; }     // Source: the picture before keying
    if (matte.w == 1.0f) {
        float y = sqrt(clamp(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f, 1.0f));
        bool br = k.z > 0.5f;
        float yy = br ? 1.0f - y : y;
        float tt = br ? 1.0f - k.x : k.x;
        return shapeMatte(1.0f - smoothstep(tt, tt + max(k.y, 1e-4f), yy), matte, sh);
    }
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = mx - mn;
    float h = 0.0f;
    if (d > 0.0f) {
        if (mx == c.r) { h = fmod((c.g - c.b) / d, 6.0f); }
        else if (mx == c.g) { h = (c.b - c.r) / d + 2.0f; }
        else { h = (c.r - c.g) / d + 4.0f; }
        h *= 60.0f;
        if (h < 0.0f) { h += 360.0f; }
    }
    float s = mx > 0.0f ? d / mx : 0.0f;
    float dist = abs(h - k.x);
    dist = min(dist, 360.0f - dist);
    float weight = smoothstep(0.08f, 0.3f, s) * smoothstep(0.001f, 0.01f, mx);
    float inside = 1.0f - smoothstep(k.y, k.y + k.z, dist);
    float raw = inside * weight;
    if (sh.z > 0.0f || sh.w > 0.0f) {
        float keep = min(sh.z * smoothstep(0.5f, 1.0f, mx) + sh.w * (1.0f - smoothstep(0.02f, 0.3f, mx)), 1.0f);
        raw *= 1.0f - keep;
    }
    float key = shapeMatte(raw, matte, sh);
    float zone = 1.0f - smoothstep(k.y + k.z, 2.0f * k.y + k.z + cc.w * 40.0f, dist);
    float w = k.w * zone * weight * (1.0f - raw);
    float luma = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    c = c + (float3(luma) - c) * w;
    if (cc.x != 1.0f || cc.y != 0.0f || cc.z != 1.0f) {
        float y = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        c = float3(y) + (c - float3(y)) * cc.x;
        if (cc.y != 0.0f) {
            float cs = cos(cc.y), sn = sin(cc.y);
            float3 ax = float3(0.57735027f);
            c = c * cs + cross(ax, c) * sn + ax * (dot(ax, c) * (1.0f - cs));
        }
        c = c * cc.z;
    }
    return key;
}

// A partial buffer read at a whole-picture texel position `p` (texels, relative to the part), transparent outside it.
// Metal samples in pixel coordinates, as the old MSL did: no division, so a part drawn in place is the same picture as the
// whole one bit for bit (PartialContentTests). D3D has no pixel-coordinate sampler; there the position is normalized
// (shortcut: last-bit rounding can differ from the whole picture, upgrade if a D3D test needs bit equality).
#ifdef SQ_METAL
float4 samplePartTexels(Texture2D<float4> t, float2 p) {
    __target_switch {
    case metal: __intrinsic_asm "$0.sample(sampler(coord::pixel, address::clamp_to_zero, filter::linear), $1)";
    }
}
#else
float4 samplePartTexels(Texture2D<float4> t, float2 p) { return t.SampleLevel(zeroSampler, p / float2(texSize(t)), 0.0f); }
#endif

bool keyMatteView(CompositeU u) { return u.matte0.z == 1.0f || (u.keyCount > 1u && u.matte1.z == 1.0f); }

float4 shadeLayer(VOut i, CompositeU u, Texture2D<float4> ty, Texture2D<float4> tc, Texture2D<float4> mt,
                  Texture2D<float4> pm0, Texture2D<float4> pm1) {
    float cover = 1.0f;
    if (edgeAA(u)) {
        // Kept rectangle: the mask rectangle minus the crop insets, rounded by cornerRadius.
        float2 ms = u.maskSize.x > 0.0f ? u.maskSize : u.size;
        float2 lo = -0.5f * ms + u.crop.xy * ms;
        float2 hi = 0.5f * ms - u.crop.zw * ms;
        float2 c = 0.5f * (lo + hi);
        float2 h = 0.5f * (hi - lo);
        float d;
        if (u.roundFirst != 0u) {
            // Rounded Corners, then Crop: intersection of the rounded full frame and the straight crop rectangle.
            float2 h0 = 0.5f * ms;
            float r0 = min(u.cornerRadius, min(h0.x, h0.y));
            float2 q0 = abs(i.local) - h0 + r0;
            float d0 = length(max(q0, 0.0f)) + min(max(q0.x, q0.y), 0.0f) - r0;
            float2 q1 = abs(i.local - c) - h;
            float d1 = length(max(q1, 0.0f)) + min(max(q1.x, q1.y), 0.0f);
            d = max(d0, d1);
        } else {
            float r = min(u.cornerRadius, min(h.x, h.y));
            float2 q = abs(i.local - c) - h + r;
            d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;      // signed distance, layer px
        }
        float w = 1.0f / max(min(u.scale.x, u.scale.y), 1e-4f);          // layer px per screen px (not ddx: a 2x2 quad edge skews it)
        // Crop Softness widens the ramp inwards (0 outside, full softness + half a pixel inside); 0 keeps the old edge exactly.
        cover = u.cropFeather > 0.0f ? clamp((0.5f * w - d) / (w + u.cropFeather), 0.0f, 1.0f)
                                     : clamp(0.5f - d / w, 0.0f, 1.0f);
    }
    float2 uv = i.local / u.size + 0.5f;
    if (u.mode != 3u && u.quarter != 0u) {
        // uv is in the upright picture; turn it back into the source texture (clockwise display turn).
        if (u.quarter == 1u) { uv = float2(uv.y, 1.0f - uv.x); }
        else if (u.quarter == 2u) { uv = float2(1.0f - uv.x, 1.0f - uv.y); }
        else { uv = float2(1.0f - uv.y, uv.x); }
    }
    if (u.mode == 3u) {
        float4 g;                                  // premultiplied, already working-linear
        if (u.part.z > 0.0f) {
            // A partial buffer in place of the whole picture: the whole picture's texel coordinate (held inside it, as
            // clamp to edge does), read from the part in texels, transparent outside it.
            float2 c = clamp(uv * u.part.zw, float2(0.5f), u.part.zw - 0.5f);
            g = samplePartTexels(ty, c - u.part.xy);
        } else {
            g = ty.SampleLevel(edgeSampler, uv, 0.0f);
        }
        if (u.maskCount > 0u) {
            float3 pc = g.a > 0.0f ? oetf709(clamp(g.rgb / g.a, 0.0f, 1.0f)) : float3(0.0f);
            cover *= maskCoverage(i.local, u, mt, pm0, pm1, pc);
        }
        if (u.keyCount > 0u && g.a > 0.0f) {
            // Ultra Key after a blur (or another pass): key the straight color, premultiply again.
            float3 c = g.rgb / g.a;
            float kept = 1.0f - applyChromaKey(u.key0, u.matte0, u.shape0, u.cc0, c);
            if (u.keyCount > 1u) { kept *= 1.0f - applyChromaKey(u.key1, u.matte1, u.shape1, u.cc1, c); }
            if (keyMatteView(u)) { g = float4(float3(kept) * g.a, g.a); }   // Alpha output
            else { g = float4(c * g.a * kept, g.a * kept); }
        }
        float k = u.opacity * cover;
        return g * k;
    }
    float texA = 1.0f;
    float3 rgb;
    if (u.mode == 2u) {
        rgb = u.solid.rgb;
    } else if (alphaSource(u)) {
        // Alpha video, a straight RGB source or the color stage's output of one: filter premultiplied, then straight
        // color for the transfer curve / keys (premultiplied again below).
        float4 c = samplePremul(u, ty, uv);
        texA = c.a;
        rgb = texA > 0.0f ? c.rgb / texA : float3(0.0f);
    } else if (u.mode == 1u && u.linearize != 0u) {
        // RGB texture (video BGRA or a still image): premultiplied alpha, un-premultiply before the transfer curve.
        float4 c = ty.SampleLevel(edgeSampler, uv, 0.0f);
        texA = c.a;
        rgb = texA > 0.0f ? c.rgb / texA : float3(0.0f);
    } else if (u.mode == 1u) {
        // Color-stage output (linear rgb, straight alpha).
        float4 c = ty.SampleLevel(edgeSampler, uv, 0.0f);
        texA = c.a;
        rgb = c.rgb;
    } else {
        rgb = sourceEncoded(u, ty, tc, uv);
    }
    if (u.mode != 2u && u.linearize != 0u) { rgb = inverseOETF709(rgb); }
    rgb = max(rgb, 0.0f);
    // Masks last: a Color range mask reads the picture's own pixel (display-encoded), before any key changes it.
    if (u.maskCount > 0u) { cover *= maskCoverage(i.local, u, mt, pm0, pm1, oetf709(clamp(rgb, 0.0f, 1.0f))); }
    if (u.mode != 2u && u.keyCount > 0u) {
        float kept = 1.0f - applyChromaKey(u.key0, u.matte0, u.shape0, u.cc0, rgb);
        if (u.keyCount > 1u) { kept *= 1.0f - applyChromaKey(u.key1, u.matte1, u.shape1, u.cc1, rgb); }
        if (keyMatteView(u)) { rgb = float3(kept); }   // Alpha output: gray, coverage as is
        else { texA *= kept; }
    }
    float a = u.opacity * cover * texA;
    return float4(rgb * a, a);   // premultiplied
}
