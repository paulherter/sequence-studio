// Motion transitions (was CompositorShaderSource.msl in SQRender; RenderNode.transition). Include after Bindings.slang.
// Offsets and blur are frame fractions (y down); each side is sampled bilinearly with transparent outside, so edges between
// pixels stay smooth.
// `taps`: 0 = about one tap per 1.5 px (up to 256); > 0 = exactly that many, used after `transitionPreBlur` smeared the side
// over one tap spacing (box * comb = one long box, so a 1400 px whip needs ~2 x 64 taps, not 1000).
// `mirror` 1: outside the picture it repeats mirrored (a settling Zoom In / Out side below 100 %) instead of being
// transparent, but only when the side is an opaque picture that fills its canvas: a small, moved or see-through one (or one
// with any hole) stays transparent outside, so no reflected copy of it appears. The test is exact: `transitionCoverMin`
// reduces the side's smallest alpha (the CPU binds it as `cover`; a mirror side below 0.999 is treated as mirror 0).
struct TransitionSideU { float2 offset; float2 blur; float scale; float opacity; float zoomBlur; float taps; float rotation; float mirror; };
struct TransitionU {
    TransitionSideU a, b;
    float2 wipeDir; float wipeFront; float wipeSoft; uint compose; float borderWidth, borderR, borderG, borderB;
};

// The constant blocks as float4 rows: HLSL starts a nested struct on a 16-byte row, Metal does not, so the shaders read
// Compositor.TransitionSideUniforms (40 bytes) and TransitionUniforms (120 bytes) as rows and unpack them.
struct TransitionSideRows { float4 r0, r1; float2 r2; };
struct TransitionRows { float4 r0, r1, r2, r3, r4, r5, r6; float2 r7; };

TransitionSideU sideFromRows(TransitionSideRows r) {
    TransitionSideU s;
    s.offset = r.r0.xy; s.blur = r.r0.zw;
    s.scale = r.r1.x; s.opacity = r.r1.y; s.zoomBlur = r.r1.z; s.taps = r.r1.w;
    s.rotation = r.r2.x; s.mirror = r.r2.y;
    return s;
}

TransitionU transitionFromRows(TransitionRows r) {
    TransitionU u;
    u.a.offset = r.r0.xy; u.a.blur = r.r0.zw;
    u.a.scale = r.r1.x; u.a.opacity = r.r1.y; u.a.zoomBlur = r.r1.z; u.a.taps = r.r1.w;
    u.a.rotation = r.r2.x; u.a.mirror = r.r2.y;
    u.b.offset = r.r2.zw; u.b.blur = r.r3.xy;
    u.b.scale = r.r3.z; u.b.opacity = r.r3.w; u.b.zoomBlur = r.r4.x; u.b.taps = r.r4.y;
    u.b.rotation = r.r4.z; u.b.mirror = r.r4.w;
    u.wipeDir = r.r5.xy; u.wipeFront = r.r5.z; u.wipeSoft = r.r5.w;
    u.compose = asuint(r.r6.x); u.borderWidth = r.r6.y; u.borderR = r.r6.z; u.borderG = r.r6.w; u.borderB = r.r7.x;
    return u;
}

float4 sideSample(Texture2D<float4> t, float2 q, bool mirror) {
    // One fetch either way (two samplers behind a select would cost every tap twice): mirror the coordinate here and keep
    // it half a texel inside, so the transparent border never blends in at the fold.
    if (mirror) {
        uint w, h;
        t.GetDimensions(w, h);
        float2 hf = 0.5f / float2(float(w), float(h));
        q = clamp(1.0f - abs(1.0f - fmod(abs(q), 2.0f)), hf, 1.0f - hf);
    }
    return t.SampleLevel(zeroSampler, q, 0.0f);
}

float4 transitionSide(Texture2D<float4> t, float2 uv, TransitionSideU s, float2 px) {
    if (s.opacity <= 0.0f) { return float4(0.0f); }
    bool m = s.mirror > 0.5f;
    float sc = max(s.scale, 1e-4f);
    float2 q0 = uv - 0.5f - s.offset;
    if (s.rotation != 0.0f) {
        // Rotate in pixel space (the picture stays undistorted); positive = clockwise on screen (y down).
        float cr = cos(s.rotation), sr = sin(s.rotation);
        float2 pp = q0 * px;
        q0 = float2(cr * pp.x + sr * pp.y, -sr * pp.x + cr * pp.y) / px;
    }
    float2 q = q0 / sc + 0.5f;
    float2 bl = s.blur / sc;
    // Smear length in pixels (directional, or radial at this distance from the center): about one tap per 1.5 px.
    float len = max(length(bl * px), length((q - 0.5f) * px) * abs(s.zoomBlur));
    // A strong radial smear (Cross Zoom, Spin: zoomBlur > 0.1) would need up to 256 taps per pixel at 4K: it takes 24
    // jittered taps instead (interleaved gradient noise shifts every pixel's tap pattern, so the gaps read as fine grain).
    bool heavy = s.taps <= 0.0f && abs(s.zoomBlur) > 0.1f;
    int n = s.taps > 0.0f ? int(s.taps) : clamp(int(ceil(len / 1.5f)) + 1, 1, heavy ? 24 : 256);
    if (n <= 1) { return sideSample(t, q, m) * s.opacity; }
    float4 acc = float4(0.0f);
    float2 pix = uv * px;
    float jit = frac(52.9829189f * frac(dot(pix, float2(0.06711056f, 0.00583715f))));
    for (int k = 0; k < n; k++) {
        float f = heavy ? (float(k) + jit) / float(n) - 0.5f : float(k) / float(n - 1) - 0.5f;
        float2 qk = q + bl * f;
        qk = 0.5f + (qk - 0.5f) * (1.0f + s.zoomBlur * f);
        acc += sideSample(t, qk, m);
    }
    return acc / float(n) * s.opacity;
}

// One side of a pair, chosen without a resource select (fxc cannot pick a texture at run time).
float4 sideOf(bool second, Texture2D<float4> ta, Texture2D<float4> tb, float2 uv, TransitionU u, float2 px) {
    if (second) { return transitionSide(tb, uv, u.b, px); }
    return transitionSide(ta, uv, u.a, px);
}

float lnHash(float2 p) {
    uint2 q = uint2(int2(p) + 4096);
    uint h = q.x * 0x9E3779B1u ^ q.y * 0x85EBCA6Bu;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return float(h & 0xFFFFu) / 65535.0f;
}

// The mixed pixel `gid` of a `px`-sized transition canvas: shared by the kernel and the fused final draw. `cover`: the
// sides' smallest alpha (1 when not measured).
float4 transitionCompose(Texture2D<float4> ta, Texture2D<float4> tb, TransitionU u, uint2 gid, float2 px, float2 cover) {
    if (cover.x < 0.999f) { u.a.mirror = 0.0f; }
    if (cover.y < 0.999f) { u.b.mirror = 0.0f; }
    float2 uv = (float2(gid) + 0.5f) / px;
    float4 a = transitionSide(ta, uv, u.a, px), b = transitionSide(tb, uv, u.b, px);
    float4 c;
    if (u.compose == 1u) { c = b + a * (1.0f - b.a); }
    else if (u.compose == 2u) { c = a + b * (1.0f - a.a); }
    else if (u.compose == 3u) {
        // Wipe: position along the travel direction, 0 where the edge starts. At least half a pixel of softness (AA).
        float x = dot(uv - 0.5f, u.wipeDir) + 0.5f;
        float s = max(u.wipeSoft, 0.5f / max(dot(abs(u.wipeDir), px), 1.0f));
        float m = 1.0f - smoothstep(u.wipeFront - s, u.wipeFront + s, x);
        c = a * (1.0f - m) + b * m;
    } else if (u.compose == 4u) {
        // Glitch (mirrors TransitionRender.Glitch): slice displacement + RGB split, hard cut at mix 0.5.
        uint band = min(uint(uv.y * 24.0f), 23u);
        uint seed = asuint(u.wipeDir.x);
        uint h = band * 0x9E3779B1u ^ seed * 0x85EBCA6Bu;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
        float shift = 0.0f;
        if (float(h & 0xFFu) / 255.0f < 0.45f * u.wipeSoft) { shift = (float((h >> 8) & 0xFFFFu) / 65535.0f * 2.0f - 1.0f) * 0.12f * u.wipeSoft; }
        float split = 0.025f * clamp(u.wipeSoft, 0.0f, 1.0f);
        bool second = u.wipeFront >= 0.5f;
        float4 r = sideOf(second, ta, tb, uv + float2(shift + split, 0.0f), u, px);
        float4 g = sideOf(second, ta, tb, uv + float2(shift, 0.0f), u, px);
        float4 bl = sideOf(second, ta, tb, uv + float2(shift - split, 0.0f), u, px);
        c = float4(r.r, g.g, bl.b, g.a);
    } else if (u.compose == 5u) {
        // Iris (mirrors TransitionRender.Iris): B inside a growing ellipse that fits the frame.
        float2 q = (uv - 0.5f) * 2.0f;
        float r = length(q) / 1.41421356237f;
        float s = max(u.wipeSoft, 0.5f / max(min(px.x, px.y), 1.0f));
        float m = 1.0f - smoothstep(u.wipeFront - s, u.wipeFront + s, r);
        c = a * (1.0f - m) + b * m;
    } else if (u.compose == 6u) {
        // Light Leak (mirrors TransitionRender.LightLeak): dissolve + screen-blended warm gradient band.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float w = smoothstep(0.35f, 0.65f, p);
        c = a * (1.0f - w) + b * w;
        float2 d = u.wipeDir, o = uv - 0.5f;
        float x = o.x * d.x + o.y * d.y + 0.5f, y = -o.x * d.y + o.y * d.x + 0.5f;
        float k = (x - (-0.3f + 1.6f * p)) / (0.15f + 1.5f * u.wipeSoft);
        float f = exp(-k * k);
        float bell = max(0.0f, sin(p * 3.14159265359f));
        float t = clamp(y, 0.0f, 1.0f);
        float aa = f * bell * 1.2f, core = f * f * f * bell;
        float3 l = min(float3(1.0f * aa + 0.4f * core, (0.55f - 0.35f * t) * aa + 0.3f * core, (0.15f + 0.3f * t) * aa + 0.2f * core), float3(1.0f));
        c.rgb = c.rgb + l * c.a * (1.0f - c.rgb);
    } else if (u.compose == 7u) {
        // Blur Dissolve (mirrors TransitionRender.BlurDissolve): both pictures smeared by a disc (Vogel spiral), then mixed.
        float rpx = u.wipeSoft * px.y;
        if (rpx < 0.5f) {
            c = a * (1.0f - u.wipeFront) + b * u.wipeFront;
        } else {
            // 6...10 taps on a spiral turned by a per-pixel angle (interleaved gradient noise): fine grain, not banding.
            int n = clamp(int(rpx * 0.25f), 6, 10);
            float4 sa = float4(0.0f), sb = float4(0.0f);
            float rot = 6.2831853f * frac(52.9829189f * frac(dot(uv * px, float2(0.06711056f, 0.00583715f))));
            for (int k = 0; k < n; k++) {
                float rr = sqrt((float(k) + 0.5f) / float(n)), th = float(k) * 2.39996323f + rot;
                float2 d = float2(cos(th), sin(th)) * rr * rpx / px;
                float2 uk = clamp(uv + d, 0.5f / px, 1.0f - 0.5f / px);   // repeat the edge: no dark rim
                sa += transitionSide(ta, uk, u.a, px);
                sb += transitionSide(tb, uk, u.b, px);
            }
            sa /= float(n); sb /= float(n);
            c = sa * (1.0f - u.wipeFront) + sb * u.wipeFront;
        }
    } else if (u.compose == 8u) {
        // Static: channel-change noise (Glitch fields: wipeDir.x = seed bits, wipeFront = mix, wipeSoft = intensity). A
        // hard cut at mix 0.5, rows jitter sideways and the picture is overlaid with per-pixel gray noise.
        uint seed = asuint(u.wipeDir.x);
        float k = clamp(u.wipeSoft, 0.0f, 1.0f);
        uint row = uint(gid.y / 2u);
        uint hr = (row * 0x9E3779B1u) ^ (seed * 0x85EBCA6Bu);
        hr ^= hr >> 15; hr *= 0x2C1B3C6Du; hr ^= hr >> 12;
        float jitter = (float(hr & 0xFFFFu) / 65535.0f * 2.0f - 1.0f) * 0.04f * k * k;
        bool second = u.wipeFront >= 0.5f;
        float4 pic = sideOf(second, ta, tb, float2(clamp(uv.x + jitter, 0.5f / px.x, 1.0f - 0.5f / px.x), uv.y), u, px);
        uint h = (gid.x * 73856093u) ^ (gid.y * 19349663u) ^ (seed * 83492791u);
        h ^= h >> 13; h *= 0x5BD1E995u; h ^= h >> 15; h *= 0x27D4EB2Du; h ^= h >> 13;
        float n = float(h & 0xFFFFu) / 65535.0f;
        float m = 0.85f * k;
        c = float4(pic.rgb * (1.0f - m) + float3(n) * m * pic.a, pic.a);
    } else if (u.compose == 9u) {
        // Light Noise: dissolve + a drifting, screen-blended warm glow modulated by value noise.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float w = smoothstep(0.3f, 0.7f, p);
        c = a * (1.0f - w) + b * w;
        float bell = max(0.0f, sin(p * 3.14159265359f));
        float2 g = uv * float2(px.x / px.y, 1.0f) * 4.0f + float2(p * 3.0f, -p * 2.0f);
        float2 gi = floor(g), gf = frac(g);
        gf = gf * gf * (3.0f - 2.0f * gf);
        float v00 = lnHash(gi), v10 = lnHash(gi + float2(1, 0)), v01 = lnHash(gi + float2(0, 1)), v11 = lnHash(gi + float2(1, 1));
        float nz = lerp(lerp(v00, v10, gf.x), lerp(v01, v11, gf.x), gf.y);
        float glow = bell * smoothstep(0.25f, 0.95f, nz) * 0.9f;
        float3 l = float3(1.0f, 0.88f, 0.65f) * glow;
        c.rgb = c.rgb + l * c.a * (1.0f - c.rgb);
    } else if (u.compose == 10u) {
        // Shape reveal (mirrors TransitionRender.ShapeWipe): B where the shape's distance field is below the front.
        float2 q = (uv - 0.5f) * 2.0f;
        int shape = int(u.wipeDir.x + 0.5f);
        float d;
        if (shape == 0) {
            d = atan2(q.x, -q.y) * 0.15915494309f;
            if (d < 0.0f) { d += 1.0f; }
        } else if (shape == 1) { d = max(abs(q.x), abs(q.y)); }
        else if (shape == 2) { d = (abs(q.x) + abs(q.y)) * 0.5f; }
        else if (shape == 3) { d = min(abs(q.x), abs(q.y)); }
        else if (shape == 4) { d = abs(q.x); }
        else if (shape == 5) { d = abs(q.y); }
        else if (shape == 6) { float t = uv.y * 8.0f; d = t - floor(t); }
        else if (shape == 7) { d = atan2(uv.x, uv.y) * 0.63661977f; }
        else if (shape == 8) { d = atan2(abs(q.x), -q.y) * 0.31830989f; }
        else if (shape == 9) {
            float cc = atan2(q.x, -q.y) * 0.15915494309f;
            if (cc < 0.0f) { cc += 1.0f; }
            cc *= 4.0f;
            d = cc - floor(cc);
        } else if (shape == 10) {
            float cu = uv.x * 8.0f;
            float f = cu - floor(cu);
            int s2 = int(floor(cu)) + int(floor(uv.y * 6.0f));
            d = (s2 % 2 == 0) ? f : 1.0f - f;
        } else if (shape == 11) {
            float row = min(floor(uv.y * 8.0f), 7.0f);
            float col = min(floor(uv.x * 8.0f), 7.0f);
            float along = (col + 0.5f) / 8.0f;
            d = (row + ((int(row) % 2 == 0) ? along : 1.0f - along)) / 8.0f;
        } else if (shape == 12) { d = max(uv.x, uv.y); }
        else if (shape == 14) { d = (int(floor(uv.y * 10.0f)) % 2 == 0) ? uv.x : 1.0f - uv.x; }
        else if (shape == 13) {
            uint cx = uint(min(floor(uv.x * 12.0f), 11.0f));
            uint cy = uint(min(floor(uv.y * 8.0f), 7.0f));
            uint h = (cx * 73856093u) ^ (cy * 19349663u);
            h = (h ^ (h >> 13)) * 1274126177u;
            h ^= h >> 16;
            d = float(h & 0xFFFFu) / 65536.0f;
        } else { d = 0.0f; }
        float s = max(u.wipeSoft, 0.5f / max(min(px.x, px.y), 1.0f));
        float m = 1.0f - smoothstep(u.wipeFront - s, u.wipeFront + s, d);
        c = a * (1.0f - m) + b * m;
    } else if (u.compose == 11u) {
        // Mosaic dissolve: both pictures sampled on a block grid whose block size peaks mid-way (wipeFront = progress).
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float bell = sin(p * 3.14159265f);
        float block = max(1.0f, bell * px.y / 6.0f);
        float2 cell = floor(float2(gid) / block);
        float2 quv = clamp((cell + 0.5f) * block / px, 0.0f, 1.0f);
        float4 sa = transitionSide(ta, quv, u.a, px), sb = transitionSide(tb, quv, u.b, px);
        c = sa * (1.0f - p) + sb * p;
    } else if (u.compose == 12u) {
        // Flip 3D (mirrors TransitionRender.Flip3D): one card turns about the center line, A on the first half, B on the second.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        bool vert = abs(u.wipeDir.y) > abs(u.wipeDir.x);
        float sgn = (u.wipeDir.x + u.wipeDir.y) > 0.0f ? 1.0f : -1.0f;
        bool second = p >= 0.5f;
        float ang = sgn * (p * 3.14159265f - (second ? 3.14159265f : 0.0f));
        float2 X = (uv - 0.5f) * 2.0f;
        if (vert) { X = X.yx; }
        float ca = cos(ang), sa = sin(ang);
        float den = 3.0f * ca + X.x * sa;
        c = float4(0.0f);
        if (den > 0.05f) {
            float x = X.x * 3.0f / den;
            float y = X.y * (3.0f - x * sa) / 3.0f;
            if (abs(x) <= 1.0f && abs(y) <= 1.0f) {
                float2 sq = vert ? float2(y, x) : float2(x, y);
                c = sideOf(second, ta, tb, sq * 0.5f + 0.5f, u, px);
            }
        }
    } else if (u.compose == 13u) {
        // Burn: A burns away along a noise field (plus a lean along the direction) with a glowing edge, B behind it.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float2 g = uv * float2(px.x / px.y, 1.0f) * 4.0f;
        float2 gi = floor(g), gf = frac(g);
        gf = gf * gf * (3.0f - 2.0f * gf);
        float nz = lerp(lerp(lnHash(gi), lnHash(gi + float2(1, 0)), gf.x), lerp(lnHash(gi + float2(0, 1)), lnHash(gi + float2(1, 1)), gf.x), gf.y);
        float d = 0.7f * nz + 0.3f * (dot(uv - 0.5f, u.wipeDir) + 0.5f);
        float band = 0.12f;
        float t = p * (1.0f + band);
        float aa = 0.5f / max(min(px.x, px.y), 1.0f);
        float m = 1.0f - smoothstep(t - aa, t + aa, d);
        c = a * (1.0f - m) + b * m;
        float edge = clamp((d - t) / band, 0.0f, 1.0f);
        float fire = (1.0f - edge) * (1.0f - edge) * step(0.0f, d - t + aa);
        float3 hot = lerp(float3(1.0f, 0.35f, 0.05f), float3(1.0f, 0.9f, 0.6f), fire * fire);
        c.rgb = c.rgb * (1.0f - 0.7f * fire) + hot * fire * 1.6f * a.a;
        c.a = max(c.a, fire * a.a);
    } else if (u.compose == 14u) {
        // Flare: a dissolve with a bright warm flare that sweeps along the direction and peaks mid-way.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float w = smoothstep(0.35f, 0.65f, p);
        c = a * (1.0f - w) + b * w;
        float bell = sin(p * 3.14159265f);
        float2 centre = float2(0.5f) + u.wipeDir * (p - 0.5f) * 0.6f;
        float2 dd = (uv - centre) * float2(px.x / px.y, 1.0f);
        float glow = bell * (exp(-dot(dd, dd) * 6.0f) * 1.2f + 0.25f);
        c.rgb = c.rgb + float3(1.0f, 0.82f, 0.55f) * glow * c.a;
    } else if (u.compose == 15u) {
        // Warp: both pictures ripple (sampling positions sway) around a dissolve.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float bell = sin(p * 3.14159265f);
        float2 d = float2(sin(uv.y * 14.0f + p * 10.0f), cos(uv.x * 11.0f - p * 8.0f)) * 0.05f * bell;
        float2 uw = clamp(uv + d, 0.5f / px, 1.0f - 0.5f / px);
        float w = smoothstep(0.3f, 0.7f, p);
        c = transitionSide(ta, uw, u.a, px) * (1.0f - w) + transitionSide(tb, uw, u.b, px) * w;
    } else if (u.compose == 16u) {
        // Shake: a hard cut at the middle under camera shake (a new random offset every 1/30 of the span) with a color split.
        float p = clamp(u.wipeFront, 0.0f, 1.0f);
        float bell = sin(p * 3.14159265f);
        uint h = (uint(p * 30.0f) + 1u) * 0x9E3779B1u;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12;
        float jx = float(h & 0xFFFFu) / 32767.5f - 1.0f;
        h *= 0x297A2D39u; h ^= h >> 15;
        float jy = float(h & 0xFFFFu) / 32767.5f - 1.0f;
        float2 off = float2(jx, jy) * 0.04f * bell;
        float split = 0.012f * bell;
        bool second = p >= 0.5f;
        float2 lo = 0.5f / px, hi = 1.0f - 0.5f / px;
        float4 pr = sideOf(second, ta, tb, clamp(uv + off + float2(split, 0.0f), lo, hi), u, px);
        float4 pg = sideOf(second, ta, tb, clamp(uv + off, lo, hi), u, px);
        float4 pb = sideOf(second, ta, tb, clamp(uv + off - float2(split, 0.0f), lo, hi), u, px);
        c = float4(pr.r, pg.g, pb.b, pg.a);
    } else { c = a + b; }
    if (u.borderWidth > 0.0f) {
        // Border (mirrors TransitionRender.Border.coverage): a band centered on the moving edge, half a pixel of AA.
        float x = dot(uv - 0.5f, u.wipeDir) + 0.5f;
        float aa = max(0.5f / max(dot(abs(u.wipeDir), px), 1.0f), 1e-6f);
        float h = 0.5f * u.borderWidth;
        float cov = (1.0f - smoothstep(h - aa, h + aa, abs(x - u.wipeFront)))
                  * smoothstep(0.0f, h, u.wipeFront) * smoothstep(0.0f, h, 1.0f - u.wipeFront);
        c = c * (1.0f - cov) + float4(u.borderR, u.borderG, u.borderB, 1.0f) * cov;
    }
    return c;
}
