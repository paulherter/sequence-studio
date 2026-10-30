@testable import SQRender

/// The compositor's MSL as it was before Seam 4 (CompositorShaderSource.msl), kept verbatim for SlangParityTests.
enum LegacyCompositorShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    \(ColorShaderSource.transferMSL)

    \(CompositorShaderSource.convertMSL)

    kernel void convertToRGB(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                             texture2d<float, access::write> out [[texture(2)]],
                             constant CompositeUniforms& u [[buffer(0)]], constant uint2& origin [[buffer(1)]],
                             constant uint& transfer [[buffer(2)]],
                             uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;     // the dispatch may cover only the visible part of the texture
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        out.write(convertTexel(u, ty, tc, transfer, gid, size), gid);
    }

    kernel void convertToRGBScaled(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                                   texture2d<float, access::write> out [[texture(2)]],
                                   constant CompositeUniforms& u [[buffer(0)]], constant uint2& origin [[buffer(1)]],
                                   constant uint& transfer [[buffer(2)]],
                                   uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        out.write(convertTexelScaled(u, ty, tc, transfer, gid, size), gid);
    }

    struct VOut { float4 position [[position]]; float2 local; };

    // Edge antialiasing (mask on the layer rect) is on for rounded or rotated layers only, so axis-aligned
    // unrounded layers stay bit-exact. The quad is grown by 1 screen px then so edge pixels outside get covered.
    inline bool hasCrop(constant CompositeUniforms& u) { return any(u.crop != 0.0f); }
    inline bool edgeAA(constant CompositeUniforms& u) { return u.cornerRadius > 0.0f || u.rotSin != 0.0f || u.tilt.z > 0.0f || hasCrop(u) || u.cropFeather > 0.0f; }

    vertex VOut compositeVertex(uint vid [[vertex_id]], constant CompositeUniforms& u [[buffer(0)]]) {
        float2 uv = float2(vid & 1, vid >> 1);
        float2 local = (uv - 0.5f) * u.size;
        if (edgeAA(u)) local += (uv * 2.0f - 1.0f) * (1.0f / max(u.scale, 1e-4f));
        float2 p = (local - u.anchor) * u.scale;
        float2 r = float2(u.rotCos * p.x - u.rotSin * p.y, u.rotSin * p.x + u.rotCos * p.y);
        float w = 1.0f;
        if (u.tilt.z > 0.0f) {
            // Perspective tilt (mirrors PerspectiveTilt.project): turn about X then Y, project from u.tilt.z px away.
            float ca = cos(u.tilt.x), sa = sin(u.tilt.x), cb = cos(u.tilt.y), sb = sin(u.tilt.y);
            float y1 = r.y * ca, z1 = -r.y * sa;
            float z2 = r.x * sb + z1 * cb;
            w = max((u.tilt.z + z2) / u.tilt.z, 1e-3f);
            r = float2(r.x * cb - z1 * sb, y1) / w;
        }
        float2 px = u.canvas * 0.5f + u.position + r;
        VOut o;
        // w only feeds perspective-correct interpolation of `local`: the position is already divided, so scale it back up.
        o.position = float4(float2(px.x / u.canvas.x * 2.0f - 1.0f, 1.0f - px.y / u.canvas.y * 2.0f) * w, 0.0f, w);
        o.local = local;
        return o;
    }

    // One key (Ultra Key chroma, or luma when matte.w == 1) on un-premultiplied linear color: returns K (how much is keyed
    // out) and desaturates spill / color-corrects `c`. Mirrors UltraKey.key (CPU reference) and MatteRefine.tone.
    //   k: chroma (hue, half width, soft, spill) | luma (threshold, softness, keys brights, 0)
    //   m: shrink / grow, pedestal, output (0 composite, 1 alpha, 2 source), mode
    //   sh: contrast, midpoint, keep highlights, keep shadows      cc: saturation, hue shift (rad), brightness, spill range
    inline float shapeMatte(float kk, float4 m, float4 sh) {
        float r = kk;
        if (m.y > 0.0f) r = clamp((r - m.y) / max(1.0f - m.y, 1e-4f), 0.0f, 1.0f);
        if (m.x != 0.0f || sh.x > 0.0f) {
            float c = 1.0f - r;
            if (m.x > 0.0f) {
                float s = 0.9f * min(m.x, 1.0f);
                c = clamp((c - s) / max(1.0f - s, 1e-4f), 0.0f, 1.0f);
            } else if (m.x < 0.0f) {
                float g = 0.9f * min(-m.x, 1.0f);
                c = min(c / max(1.0f - g, 1e-4f), 1.0f);
            }
            if (sh.x > 0.0f) c = clamp((c - sh.y) * (1.0f + 9.0f * min(sh.x, 1.0f)) + sh.y, 0.0f, 1.0f);
            r = 1.0f - c;
        }
        return r;
    }

    inline float applyChromaKey(float4 k, float4 matte, float4 sh, float4 cc, thread float3& c) {
        if (matte.z == 2.0f) return 0.0f;     // Source: the picture before keying
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
            if (mx == c.r) h = fmod((c.g - c.b) / d, 6.0f);
            else if (mx == c.g) h = (c.b - c.r) / d + 2.0f;
            else h = (c.r - c.g) / d + 4.0f;
            h *= 60.0f;
            if (h < 0.0f) h += 360.0f;
        }
        float s = mx > 0.0f ? d / mx : 0.0f;
        float dist = fabs(h - k.x);
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

    inline bool keyMatteView(constant CompositeUniforms& u) {
        return u.matte0.z == 1.0f || (u.keyCount > 1u && u.matte1.z == 1.0f);
    }

    // W6.7 clip masks; mirrors MaskCoverage.coverage (CPU reference). `md`: per mask 4 header entries (start, count),
    // (mode, inverted), (feather, expansion), (opacity, source), then the polygons' points in layer px (centered, like `local`).
    // W9.8: source 1/2 = subject mask, its value is the matte `mt` over the clip's frame (no polygon), 2 = no matte;
    // 3/4/5 = Magic masks packed into g/b/a of the same texture.
    // C6: 6/7 = Picture mask on `pm0` (shape = alpha, brightness = Rec.709 luma of the display-encoded straight color times
    // alpha), 8/9 = the same on `pm1`. Its `start` points at 4 entries: the rows and translation of layer px -> the level's
    // canvas px, then 1 / canvas size, then the draw's center, its tilt (x, y radians) and camera distance (focal, 0; focal 0 =
    // flat): the affine map gives the place before the tilt, which is turned about the center like `compositeVertex` does.
    // Fixed to the screen; outside the canvas the matte is 0.
    inline float pictureSample(float2 p, uint start, uint flag, constant float2* md, texture2d<float> pm0, texture2d<float> pm1) {
        float2 r0 = md[start], r1 = md[start + 1], t = md[start + 2], inv = md[start + 3];
        float2 sp = float2(dot(r0, p), dot(r1, p)) + t;
        float focal = md[start + 6].x;
        if (focal > 0.0f) {
            float2 c = md[start + 4], tl = md[start + 5];
            float2 v = sp - c;
            float ca = cos(tl.x), sa = sin(tl.x), cb = cos(tl.y), sb = sin(tl.y);
            float y1 = v.y * ca, z1 = -v.y * sa;
            float w = max((focal + v.x * sb + z1 * cb) / focal, 1e-3f);
            sp = c + float2(v.x * cb - z1 * sb, y1) / w;
        }
        float2 uv = sp * inv;
        if (any(uv < 0.0f) || any(uv > 1.0f)) return 0.0f;
        uint f = flag - 6u;
        float4 s = f < 2u ? pm0.sample(linearSampler, uv) : pm1.sample(linearSampler, uv);
        if ((f & 1u) == 0u) return clamp(s.a, 0.0f, 1.0f);
        if (s.a <= 0.0f) return 0.0f;
        float3 e = oetf709(clamp(s.rgb / s.a, 0.0f, 1.0f));
        return clamp(dot(e, float3(0.2126f, 0.7152f, 0.0722f)) * s.a, 0.0f, 1.0f);
    }

    // v87: flag 10 = Color range mask. `start` points at 3 entries: (r, g), (b, tolerance), (softness, 0); the key is
    // display-encoded straight color; `pc` is the picture's own pixel in the same encoding. Mirrors ColorRangeKey.value.
    inline float colorRangeValue(uint start, constant float2* md, float3 pc) {
        float3 key = float3(md[start].x, md[start].y, md[start + 1].x);
        float tol = md[start + 1].y, soft = md[start + 2].x;
        float d = length(pc - key) * 0.57735026919f;
        if (soft <= 1e-6f) return d <= tol ? 1.0f : 0.0f;
        float x = clamp((d - tol) / soft, 0.0f, 1.0f);
        return 1.0f - x * x * (3.0f - 2.0f * x);
    }

    inline float maskCoverage(float2 p, constant CompositeUniforms& u, constant float2* md, texture2d<float> mt,
                              texture2d<float> pm0, texture2d<float> pm1, float3 pc) {
        float pixel = 1.0f / max(min(u.scale.x, u.scale.y), 1e-4f);
        float acc = 0.0f;
        for (uint m = 0; m < u.maskCount; m++) {
            float2 h0 = md[m * 4], h1 = md[m * 4 + 1], h2 = md[m * 4 + 2], h3 = md[m * 4 + 3];
            uint start = uint(h0.x), count = uint(h0.y), mode = uint(h1.x);
            if (m == 0 && (mode == 1u || mode == 2u)) acc = 1.0f;   // first Subtract / Intersect: from the whole frame
            if (h3.y != 0.0f) {
                // 1 = matte bound, 2 = none yet (no person). Outside the clip's frame (blur padding) there is no person.
                float2 ms = u.maskSize.x > 0.0f ? u.maskSize : u.size;
                float2 uv = p / ms + 0.5f;
                bool inFrame = all(uv >= 0.0f) && all(uv <= 1.0f);
                // Several mattes in one draw share the texture: 1 = r, 3 = g, 4 = b, 5 = a.
                float c = 0.0f;
                if (h3.y == 10.0f) c = colorRangeValue(start, md, pc);
                else if (h3.y >= 6.0f) c = pictureSample(p, start, uint(h3.y), md, pm0, pm1);
                else if (h3.y != 2.0f && inFrame) {
                    float4 s = mt.sample(linearSampler, uv);
                    c = clamp(h3.y == 1.0f ? s.r : h3.y == 3.0f ? s.g : h3.y == 4.0f ? s.b : s.a, 0.0f, 1.0f);
                }
                if (h1.y != 0.0f) c = 1.0f - c;
                c *= h3.x;
                if (mode == 0u) acc = min(acc + c, 1.0f);
                else if (mode == 1u) acc = max(acc - c, 0.0f);
                else if (mode == 2u) acc = acc * c;
                else acc = fabs(acc - c);
                continue;
            }
            float d2 = 1e30f;
            bool inside = false;
            if (count >= 2u) {
                uint j = start + count - 1;
                for (uint i = start; i < start + count; i++) {
                    float2 a = md[j], b = md[i];
                    float2 e = b - a, w = p - a;
                    float ee = dot(e, e);
                    float t = ee > 0.0f ? clamp(dot(w, e) / ee, 0.0f, 1.0f) : 0.0f;
                    float2 q = w - e * t;
                    d2 = min(d2, dot(q, q));
                    if ((b.y > p.y) != (a.y > p.y) && p.x < (a.x - b.x) * (p.y - b.y) / (a.y - b.y) + b.x) inside = !inside;
                    j = i;
                }
            }
            float d = sqrt(d2);
            if (inside) d = -d;
            d -= h2.y;
            float c;
            if (h2.x > pixel) {
                float hh = h2.x * 0.5f;
                float x = clamp((d + hh) / (2.0f * hh), 0.0f, 1.0f);
                c = 1.0f - x * x * (3.0f - 2.0f * x);
            } else {
                c = clamp(0.5f - d / pixel, 0.0f, 1.0f);
            }
            if (h1.y != 0.0f) c = 1.0f - c;
            c *= h3.x;
            if (mode == 0u) acc = min(acc + c, 1.0f);
            else if (mode == 1u) acc = max(acc - c, 0.0f);
            else if (mode == 2u) acc = acc * c;
            else acc = fabs(acc - c);
        }
        return acc;
    }

    // Effect mask input: an effect's result `post` shows only where its masks cover, the picture it read (`pre`) elsewhere.
    // `u.maskSize` = the clip's frame in pass px, centered in the textures; `u.scale` = 1 (one pass px per px).
    kernel void maskScopeMix(texture2d<float, access::read> pre [[texture(0)]], texture2d<float, access::read> post [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]], texture2d<float> mt [[texture(3)]],
                             texture2d<float> pm0 [[texture(4)]], texture2d<float> pm1 [[texture(5)]],
                             constant CompositeUniforms& u [[buffer(0)]], constant float2* md [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 p = float2(gid) + 0.5f - 0.5f * float2(dst.get_width(), dst.get_height());
        float4 a = pre.read(gid), b = post.read(gid);
        float3 pc = a.a > 0.0f ? oetf709(clamp(a.rgb / a.a, 0.0f, 1.0f)) : float3(0.0f);
        float c = maskCoverage(p, u, md, mt, pm0, pm1, pc);
        dst.write(a + (b - a) * c, gid);
    }

    inline float4 shadeLayer(VOut in, constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc,
                             constant float2* md, texture2d<float> mt, texture2d<float> pm0, texture2d<float> pm1) {
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
                float2 q0 = abs(in.local) - h0 + r0;
                float d0 = length(max(q0, 0.0f)) + min(max(q0.x, q0.y), 0.0f) - r0;
                float2 q1 = abs(in.local - c) - h;
                float d1 = length(max(q1, 0.0f)) + min(max(q1.x, q1.y), 0.0f);
                d = max(d0, d1);
            } else {
                float r = min(u.cornerRadius, min(h.x, h.y));
                float2 q = abs(in.local - c) - h + r;
                d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;      // signed distance, layer px
            }
            float w = 1.0f / max(min(u.scale.x, u.scale.y), 1e-4f);          // layer px per screen px (not dfdx: a 2x2 quad edge skews it)
            // Crop Softness widens the ramp inwards (0 outside, full softness + half a pixel inside); 0 keeps the old edge exactly.
            cover = u.cropFeather > 0.0f ? clamp((0.5f * w - d) / (w + u.cropFeather), 0.0f, 1.0f)
                                         : clamp(0.5f - d / w, 0.0f, 1.0f);
        }
        float2 uv = in.local / u.size + 0.5f;
        if (u.mode != 3 && u.quarter != 0) {
            // uv is in the upright picture; turn it back into the source texture (clockwise display turn).
            if (u.quarter == 1) uv = float2(uv.y, 1.0f - uv.x);
            else if (u.quarter == 2) uv = float2(1.0f - uv.x, 1.0f - uv.y);
            else uv = float2(1.0f - uv.y, uv.x);
        }
        if (u.mode == 3) {
            float4 g;                                  // premultiplied, already working-linear
            if (u.part.z > 0.0f) {
                // A partial buffer in place of the whole picture: the whole picture's texel coordinate (held inside it, as
                // clamp to edge does), read from the part in texels, transparent outside it.
                constexpr sampler ps(coord::pixel, address::clamp_to_zero, filter::linear);
                float2 c = clamp(uv * u.part.zw, float2(0.5f), u.part.zw - 0.5f);
                g = ty.sample(ps, c - u.part.xy);
            } else {
                g = ty.sample(linearSampler, uv);
            }
            if (u.maskCount > 0u) {
                float3 pc = g.a > 0.0f ? oetf709(clamp(g.rgb / g.a, 0.0f, 1.0f)) : float3(0.0f);
                cover *= maskCoverage(in.local, u, md, mt, pm0, pm1, pc);
            }
            if (u.keyCount > 0u && g.a > 0.0f) {
                // Ultra Key after a blur (or another pass): key the straight color, premultiply again.
                float3 c = g.rgb / g.a;
                float kept = 1.0f - applyChromaKey(u.key0, u.matte0, u.shape0, u.cc0, c);
                if (u.keyCount > 1u) kept *= 1.0f - applyChromaKey(u.key1, u.matte1, u.shape1, u.cc1, c);
                if (keyMatteView(u)) g = float4(float3(kept) * g.a, g.a);   // Alpha output
                else g = float4(c * g.a * kept, g.a * kept);
            }
            float k = u.opacity * cover;
            return g * k;
        }
        float texA = 1.0f;
        float3 rgb;
        if (u.mode == 2) {
            rgb = u.solid.rgb;
        } else if (alphaSource(u)) {
            // Alpha video, a straight RGB source or the color stage's output of one: filter premultiplied, then straight
            // color for the transfer curve / keys (premultiplied again below).
            float4 c = samplePremul(u, ty, uv);
            texA = c.a;
            rgb = texA > 0.0f ? c.rgb / texA : float3(0.0f);
        } else if (u.mode == 1 && u.linearize != 0) {
            // RGB texture (video BGRA or a still image): premultiplied alpha, un-premultiply before the transfer curve.
            float4 c = ty.sample(linearSampler, uv);
            texA = c.a;
            rgb = texA > 0.0f ? c.rgb / texA : float3(0.0f);
        } else if (u.mode == 1) {
            // Color-stage output (linear rgb, straight alpha).
            float4 c = ty.sample(linearSampler, uv);
            texA = c.a;
            rgb = c.rgb;
        } else {
            rgb = sourceEncoded(u, ty, tc, uv);
        }
        if (u.mode != 2 && u.linearize != 0) rgb = inverseOETF709(rgb);
        rgb = max(rgb, 0.0f);
        // Masks last: a Color range mask reads the picture's own pixel (display-encoded), before any key changes it.
        if (u.maskCount > 0u) cover *= maskCoverage(in.local, u, md, mt, pm0, pm1, oetf709(clamp(rgb, 0.0f, 1.0f)));
        if (u.mode != 2u && u.keyCount > 0u) {
            float kept = 1.0f - applyChromaKey(u.key0, u.matte0, u.shape0, u.cc0, rgb);
            if (u.keyCount > 1u) kept *= 1.0f - applyChromaKey(u.key1, u.matte1, u.shape1, u.cc1, rgb);
            if (keyMatteView(u)) rgb = float3(kept);   // Alpha output: gray, coverage as is
            else texA *= kept;
        }
        float a = u.opacity * cover * texA;
        return float4(rgb * a, a);   // premultiplied
    }

    fragment float4 compositeFragment(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                      texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                                      constant float2* md [[buffer(1)]], texture2d<float> mt [[texture(2)]],
                                      texture2d<float> pm0 [[texture(3)]], texture2d<float> pm1 [[texture(4)]]) {
        return shadeLayer(in, u, ty, tc, md, mt, pm0, pm1);
    }

    // B(cd, cs) of the separable blend modes, one channel; mirrors BlendModes.scalar (CPU reference).
    inline float blendScalar(uint mode, float cd, float cs) {
        switch (mode) {
        case 1u: return cd * cs;
        case 2u: return cd + cs - cd * cs;
        case 3u: return cd + cs;
        case 4u: return cd <= 0.5f ? 2.0f * cs * cd : cs + (2.0f * cd - 1.0f) - cs * (2.0f * cd - 1.0f);
        case 5u: return min(cd, cs);
        case 6u: return max(cd, cs);
        case 7u: return cd <= 0.0f ? 0.0f : (cs >= 1.0f ? 1.0f : min(1.0f, cd / (1.0f - cs)));
        case 8u: return cd >= 1.0f ? 1.0f : (cs <= 0.0f ? 0.0f : 1.0f - min(1.0f, (1.0f - cd) / cs));
        case 9u: return max(0.0f, cd + cs - 1.0f);
        case 10u: return cs <= 0.5f ? cd * 2.0f * cs : cd + (2.0f * cs - 1.0f) - cd * (2.0f * cs - 1.0f);
        case 11u: {
            if (cs <= 0.5f) return cd - (1.0f - 2.0f * cs) * cd * (1.0f - cd);
            float d = cd <= 0.25f ? ((16.0f * cd - 12.0f) * cd + 4.0f) * cd : sqrt(max(cd, 0.0f));
            return cd + (2.0f * cs - 1.0f) * (d - cd);
        }
        case 12u: return fabs(cd - cs);
        case 13u: return cd + cs - 2.0f * cd * cs;
        case 15u: {   // Vivid Light: Color Burn with 2cs below half, Color Dodge with 2cs - 1 above
            if (cs <= 0.5f) {
                float s2 = 2.0f * cs;
                return cd >= 1.0f ? 1.0f : (s2 <= 0.0f ? 0.0f : 1.0f - min(1.0f, (1.0f - cd) / s2));
            }
            float s2 = 2.0f * cs - 1.0f;
            return cd <= 0.0f ? 0.0f : (s2 >= 1.0f ? 1.0f : min(1.0f, cd / (1.0f - s2)));
        }
        case 16u: return max(0.0f, cd + 2.0f * cs - 1.0f);
        case 17u: return cs <= 0.5f ? min(cd, 2.0f * cs) : max(cd, 2.0f * cs - 1.0f);
        case 18u: return cd + cs >= 1.0f ? 1.0f : 0.0f;
        case 19u: return max(0.0f, cd - cs);
        case 20u: return cs <= 0.0f ? (cd > 0.0f ? 1.0f : 0.0f) : min(cd / cs, max(1.0f, cd));
        default: return cs;
        }
    }

    // Non-separable helpers (W3C SetLum / SetSat / ClipColor, Rec.709 weights); mirror BlendModes.
    inline float blendLum(float3 c) { return c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f; }
    inline float3 blendClipColor(float3 c) {
        float l = blendLum(c);
        float n = min(c.x, min(c.y, c.z)), x = max(c.x, max(c.y, c.z));
        if (n < 0.0f) c = l + (c - l) * (l / max(l - n, 1e-6f));
        if (l < 1.0f && x > 1.0f) c = l + (c - l) * ((1.0f - l) / max(x - l, 1e-6f));
        return c;
    }
    inline float3 blendSetLum(float3 c, float l) { return blendClipColor(c + (l - blendLum(c))); }
    inline float blendSat(float3 c) { return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)); }
    inline float3 blendSetSat(float3 c, float s) {
        float mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z));
        float range = mx - mn;
        return range > 0.0f ? (c - mn) * (s / range) : float3(0.0f);
    }

    // B(cd, cs) for the whole color; mirrors BlendModes.channel.
    inline float3 blendChannel(uint mode, float3 cd, float3 cs) {
        switch (mode) {
        case 21u: return blendLum(cs) < blendLum(cd) ? cs : cd;                         // Darker Color
        case 22u: return blendLum(cs) > blendLum(cd) ? cs : cd;                         // Lighter Color
        case 23u: return blendSetLum(blendSetSat(cs, blendSat(cd)), blendLum(cd));      // Hue
        case 24u: return blendSetLum(blendSetSat(cd, blendSat(cs)), blendLum(cd));      // Saturation
        case 25u: return blendSetLum(cs, blendLum(cd));                                 // Color
        case 26u: return blendSetLum(cd, blendLum(cs));                                 // Luminosity
        default: return float3(blendScalar(mode, cd.x, cs.x), blendScalar(mode, cd.y, cs.y), blendScalar(mode, cd.z, cs.z));
        }
    }

    // Dissolve's fixed per-pixel threshold in [0, 1); mirrors BlendModes.dissolveThreshold (lowbias32, top 24 bits).
    inline float dissolveThreshold(uint2 p) {
        uint h = (p.x * 0x9E3779B9u) ^ (p.y * 0x85EBCA6Bu);
        h ^= h >> 16; h *= 0x7FEB352Du;
        h ^= h >> 15; h *= 0x846CA68Bu;
        h ^= h >> 16;
        return float(h >> 8) / 16777216.0f;
    }

    // Single-layer composite with a blend mode: reads the destination (programmable blending, Apple GPUs) and writes the
    // finished pixel, so the pipeline has fixed-function blending off.
    fragment float4 compositeFragmentBlend(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                           texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                                           float4 dst [[color(0)]], constant float2* md [[buffer(1)]],
                                           texture2d<float> mt [[texture(2)]], texture2d<float> pm0 [[texture(3)]],
                                           texture2d<float> pm1 [[texture(4)]]) {
        float4 s = shadeLayer(in, u, ty, tc, md, mt, pm0, pm1);
        if (u.blend == 27u) return dst * (1.0f - u.opacity + s.a);   // footage fill: mirrors BlendModes.stencil
        float3 cs = s.a > 0.0f ? s.rgb / s.a : float3(0.0f);
        if (u.blend == 14u) {   // Dissolve: full source where the pixel's threshold is below its coverage, else none
            bool on = dissolveThreshold(uint2(in.position.xy)) < s.a;
            s = on ? float4(cs, 1.0f) : float4(0.0f);
            cs = on ? cs : float3(0.0f);
        }
        float3 cd = dst.a > 0.0f ? dst.rgb / dst.a : float3(0.0f);
        float3 b = blendChannel(u.blend, cd, cs);
        float3 rgb = s.rgb * (1.0f - dst.a) + dst.rgb * (1.0f - s.a) + s.a * dst.a * b;
        return float4(rgb, s.a + dst.a * (1.0f - s.a));
    }

    // One axis of a separable Gaussian: out(p) = sum_k w[k + r] * in(p + k * axis), zero outside the image.
    // MARK: Film / tape look (mirrors FilmLook in SQCore; see Effects/FilmLookPass.swift)

    struct LookUniforms {
        float4 dims;      // width, height, scale (layer px per 1080-line px), grain color 0...1
        uint4 ids;        // flags (1 grain, 8 scanlines, 16 chroma, 32 tracking, 64 aged film), grain seed, tracking seed, aged seed
        float4 grain;     // amount, size px, softness, luma weight
        float4 scan;      // intensity, spacing px, thickness, 0
        float4 chroma;    // bleed px, shift px, 0, 0
        float4 track;     // amount, band height, phase, 0
        float4 aged;      // dust, scratches, flicker, 0
    };

    inline uint pcg(uint v) {
        uint s = v * 747796405u + 2891336653u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }
    inline float hash2(int2 p, uint seed) {
        return float(pcg(uint(p.x) + pcg(uint(p.y) + pcg(seed)))) * (1.0f / 4294967295.0f);
    }
    // Value noise 0...1 on a lattice of one cell per unit: nearest cell for softness 0, smooth interpolation for 1.
    inline float grainNoise(float2 p, float soft, uint seed) {
        float2 fl = floor(p);
        int2 i = int2(fl);
        float2 f = p - fl;
        float a = hash2(i, seed), b = hash2(i + int2(1, 0), seed), c = hash2(i + int2(0, 1), seed), d = hash2(i + int2(1, 1), seed);
        float2 u = mix(step(float2(0.5f), f), f * f * (3.0f - 2.0f * f), soft);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float4 lookPointwise(float4 c, float streak, uint2 gid, constant LookUniforms& L);

    kernel void filmLook(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                         constant LookUniforms& L [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 size = float2(W, H);
        float2 uv = (float2(gid) + 0.5f) / size;
        float sc = L.dims.z;
        uint flags = L.ids.x;
        const float3 lw = float3(0.2126f, 0.7152f, 0.0722f);

        // Tracking noise: rows are shifted sideways inside a band that rolls up the frame, the bottom edge is always noisy,
        // and bright streaks flare on some rows.
        float dx = 0.0f, streak = 0.0f;
        if ((flags & 32u) != 0u) {
            float yn = 1.0f - uv.y;
            float amount = L.track.x, bh = L.track.y, phase = L.track.z;
            float w = 1.0f - smoothstep(0.0f, bh * 0.5f, fabs(yn - phase));
            w = max(w, 0.8f * (1.0f - smoothstep(0.0f, 0.05f, yn)));
            w = max(w, 0.1f);
            float lh = float(pcg(gid.y + pcg(L.ids.z))) * (1.0f / 4294967295.0f);
            dx = ((lh - 0.5f) * 56.0f + sin(yn * 60.0f + phase * 40.0f) * 10.0f) * w * amount * sc;
            float n = hash2(int2(gid), L.ids.z + 17u);
            streak = w * amount * step(0.8f, lh) * (0.4f + 0.6f * n) * smoothstep(0.3f, 1.0f, w);
        }
        float2 suv = uv + float2(dx / size.x, 0.0f);
        float4 c = src.sample(linearSampler, suv);

        // Chroma bleed: the color (rgb minus luma) is averaged over a horizontal span and offset against the brightness.
        if ((flags & 16u) != 0u) {
            float bleed = L.chroma.x * sc, shift = L.chroma.y * sc;
            float y = dot(c.rgb, lw);
            float3 acc = float3(0.0f);
            for (int k = -4; k <= 4; k++) {
                float ox = shift + float(k) * bleed * 0.25f;
                float3 t = src.sample(linearSampler, suv - float2(ox / size.x, 0.0f)).rgb;
                acc += t - dot(t, lw);
            }
            c.rgb = float3(y) + acc * (1.0f / 9.0f);
        }

        dst.write(lookPointwise(c, streak, gid, L), gid);
    }

    // The per-pixel tail of the look (tracking streak, grain, scanlines): shared by the kernel and the fused upright draw
    // (`compositeFragmentLook`), so both produce the same bits.
    inline float4 lookPointwise(float4 c, float streak, uint2 gid, constant LookUniforms& L) {
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
            float w = mix(1.0f, mid, L.grain.w);
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
                nv = mix(nv, nc, L.dims.w);
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
                    if (hash2(ci, fs + 4u) > 0.5f) c.rgb = mix(c.rgb, float3(0.9f) * c.a, a);
                    else c.rgb *= 1.0f - 0.9f * a;
                }
            }
            if (L.aged.y > 0.0f) {
                float v = (float(gid.y) + 0.5f) / L.dims.y;
                for (uint k = 0u; k < 3u; k++) {
                    uint s = pcg((fs / 3u) * 5u + k * 977u + 13u);
                    if (float(pcg(s + 1u)) * inv >= L.aged.y) continue;
                    float x = float(pcg(s + 2u)) * inv * L.dims.x;
                    float wpx = (0.8f + float(pcg(s + 3u)) * inv) * sc;
                    float y0 = float(pcg(s + 4u)) * inv, len = 0.4f + 0.6f * float(pcg(s + 5u)) * inv;
                    float a = (1.0f - smoothstep(0.0f, wpx, fabs(float(gid.x) + 0.5f - x))) * step(y0, v) * step(v, y0 + len);
                    c.rgb = mix(c.rgb, float3(0.85f) * c.a, a * 0.7f);
                }
            }
        }

        // Scanlines: dark rows, one gap every `spacing` px, the gap `thickness` of the spacing wide.
        if ((flags & 8u) != 0u) {
            float period = max(L.scan.y * sc, 2.0f);
            float f = fract(float(gid.y) / period);
            float d = min(f, 1.0f - f);
            float gapHalf = L.scan.z * 0.5f;
            float m = smoothstep(gapHalf - 0.12f, gapHalf + 0.12f, d);
            c.rgb *= mix(1.0f, m, L.scan.x);
        }
        return c;
    }

    // A float written to an rgba16Float render target: Apple GPUs round toward zero there (a plain `half()` conversion
    // rounds to nearest), measured in FilmLookRenderTests. Steps one ulp back towards zero when `half()` rounded away.
    inline float targetHalf(float x) {
        half h = half(x);
        if (isfinite(x) && fabs(float(h)) > fabs(x)) h = as_type<half>(ushort(as_type<ushort>(h) - 1));
        return float(h);
    }

    // Grain / scanlines only (no neighbor reads): steps 1 and 2 of the look pass in one draw. `c` is rounded to half
    // first, exactly as step 1 stores it in its rgba16Float texture before the kernel reads it.
    fragment float4 compositeFragmentLook(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                          texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                                          constant float2* md [[buffer(1)]], texture2d<float> mt [[texture(2)]],
                                          texture2d<float> pm0 [[texture(3)]], texture2d<float> pm1 [[texture(4)]],
                                          constant LookUniforms& L [[buffer(2)]]) {
        float4 s = shadeLayer(in, u, ty, tc, md, mt, pm0, pm1);
        float4 c = float4(targetHalf(s.x), targetHalf(s.y), targetHalf(s.z), targetHalf(s.w));
        return lookPointwise(c, 0.0f, uint2(in.position.xy), L);
    }

    // Motion transitions (RenderNode.transition). Mirrors Compositor.TransitionUniforms (120 bytes). Offsets and blur are frame
    // fractions (y down); each side is sampled bilinearly with transparent outside, so edges between pixels stay smooth.
    // `taps`: 0 = about one tap per 1.5 px (up to 256); > 0 = exactly that many, used after `transitionPreBlur` smeared the
    // side over one tap spacing (box * comb = one long box, so a 1400 px whip needs ~2 x 64 taps, not 1000).
    // `mirror` 1: outside the picture it repeats mirrored (a settling Zoom In / Out side below 100 %) instead of being transparent,
    // but only when the side is an opaque picture that fills its canvas: a small, moved or see-through one (or one with any
    // hole) stays transparent outside, so no reflected copy of it appears. The test is exact: `transitionCoverMin` reduces the
    // side's smallest alpha (the CPU binds it as `cover`; a mirror side below 0.999 is treated as mirror 0).
    struct TransitionSideU { float2 offset; float2 blur; float scale; float opacity; float zoomBlur; float taps; float rotation; float mirror; };
    struct TransitionU { TransitionSideU a; TransitionSideU b; float2 wipeDir; float wipeFront; float wipeSoft; uint compose; float borderWidth, borderR, borderG, borderB; };

    inline float4 sideSample(texture2d<float, access::sample> t, float2 q, bool mirror) {
        constexpr sampler z0(coord::normalized, address::clamp_to_zero, filter::linear);
        // One fetch either way (two samplers behind a select would cost every tap twice): mirror the coordinate here and keep
        // it half a texel inside, so the transparent border never blends in at the fold.
        if (mirror) {
            float2 h = 0.5f / float2(t.get_width(), t.get_height());
            q = clamp(1.0f - fabs(1.0f - fmod(fabs(q), 2.0f)), h, 1.0f - h);
        }
        return t.sample(z0, q);
    }

    // Smallest alpha of a side, exactly: one atomic min per simdgroup into cov[slot] (init 1.0f; non-negative floats order
    // like their bits, so the result does not depend on the order the groups finish). Out-of-range lanes count as opaque.
    kernel void transitionCoverMin(texture2d<float, access::read> t [[texture(0)]], device atomic_uint* cov [[buffer(0)]],
                                   constant uint& slot [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        float a = 1.0f;
        if (gid.x < t.get_width() && gid.y < t.get_height()) a = max(t.read(gid).a, 0.0f);
        float m = simd_min(a);
        if (simd_is_first()) atomic_fetch_min_explicit(&cov[slot], as_type<uint>(m), memory_order_relaxed);
    }

    inline float4 transitionSide(texture2d<float, access::sample> t, float2 uv, TransitionSideU s, float2 px) {
        if (s.opacity <= 0.0f) return float4(0.0f);
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
        float len = max(length(bl * px), length((q - 0.5f) * px) * fabs(s.zoomBlur));
        // A strong radial smear (Cross Zoom, Spin: zoomBlur > 0.1) would need up to 256 taps per pixel at 4K: it takes 24 jittered
        // taps instead (interleaved gradient noise shifts every pixel's tap pattern, so the gaps read as fine grain, not ghosts).
        bool heavy = s.taps <= 0.0f && fabs(s.zoomBlur) > 0.1f;
        int n = s.taps > 0.0f ? int(s.taps) : clamp(int(ceil(len / 1.5f)) + 1, 1, heavy ? 24 : 256);
        if (n <= 1) return sideSample(t, q, m) * s.opacity;
        float4 acc = float4(0.0f);
        float2 pix = uv * px;
        float jit = fract(52.9829189f * fract(dot(pix, float2(0.06711056f, 0.00583715f))));
        for (int k = 0; k < n; k++) {
            float f = heavy ? (float(k) + jit) / float(n) - 0.5f : float(k) / float(n - 1) - 0.5f;
            float2 qk = q + bl * f;
            qk = 0.5f + (qk - 0.5f) * (1.0f + s.zoomBlur * f);
            acc += sideSample(t, qk, m);
        }
        return acc / float(n) * s.opacity;
    }

    // First pass of a long directional smear: the side placed on the canvas (offset, scale) with a short smear of one comb
    // spacing. Done in canvas space, on a canvas grown by `pad` (fraction) on every side, so the comb pass still finds the
    // picture that lies just outside the frame.
    kernel void transitionPreBlur(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                  constant TransitionSideU& s0 [[buffer(0)]], constant float& pad [[buffer(1)]],
                                  constant float2& canvas [[buffer(2)]], constant uint* cover [[buffer(3)]],
                                  constant uint& slot [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
        TransitionSideU s = s0;
        if (as_type<float>(cover[slot]) < 0.999f) s.mirror = 0.0f;
        float2 big = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5f) / big * (1.0f + 2.0f * pad) - pad;
        dst.write(transitionSide(src, uv, s, canvas), gid);
    }

    inline float lnHash(float2 p) {
        uint2 q = uint2(int2(p) + 4096);
        uint h = q.x * 0x9E3779B1u ^ q.y * 0x85EBCA6Bu;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
        return float(h & 0xFFFFu) / 65535.0f;
    }

    // The mixed pixel `gid` of a `px`-sized transition canvas: shared by the kernel and the fused final draw.
    inline float4 transitionCompose(texture2d<float, access::sample> ta, texture2d<float, access::sample> tb,
                                    constant TransitionU& u, uint2 gid, float2 px, constant uint* cover);

    kernel void transitionMix(texture2d<float, access::sample> ta [[texture(0)]], texture2d<float, access::sample> tb [[texture(1)]],
                              texture2d<float, access::write> out [[texture(2)]], constant TransitionU& u [[buffer(0)]],
                              constant uint* cover [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        float2 px = float2(out.get_width(), out.get_height());
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        out.write(transitionCompose(ta, tb, u, gid, px, cover), gid);
    }

    // A float written to an rgba16Float texture by a compute kernel (`texture.write`), as the final draw then samples it:
    // rounded toward zero like a render target store (measured, TransitionFusionTests).
    inline float computeStoreHalf(float x) { return targetHalf(x); }

    // The transition's final draw with the mix computed here instead of read from the mix texture (`Compositor
    // .fusesTransitionMix`): only when the transition canvas is the target size and the draw is plain (no blend mode),
    // so pixel `gid` of the draw is pixel `gid` of the mix. The mix is rounded to half as the kernel's store would.
    fragment float4 compositeFragmentTransition(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                                texture2d<float> ta [[texture(0)]], texture2d<float> tb [[texture(1)]],
                                                constant TransitionU& tu [[buffer(2)]], constant uint* cover [[buffer(3)]]) {
        float4 c = transitionCompose(ta, tb, tu, uint2(in.position.xy), u.canvas, cover);
        float4 g = float4(computeStoreHalf(c.x), computeStoreHalf(c.y), computeStoreHalf(c.z), computeStoreHalf(c.w));
        return g * u.opacity;
    }

    inline float4 transitionCompose(texture2d<float, access::sample> ta, texture2d<float, access::sample> tb,
                                    constant TransitionU& u0, uint2 gid, float2 px, constant uint* cover) {
        TransitionU u = u0;
        if (as_type<float>(cover[0]) < 0.999f) u.a.mirror = 0.0f;
        if (as_type<float>(cover[1]) < 0.999f) u.b.mirror = 0.0f;
        float2 uv = (float2(gid) + 0.5f) / px;
        float4 a = transitionSide(ta, uv, u.a, px), b = transitionSide(tb, uv, u.b, px);
        float4 c;
        if (u.compose == 1u) c = b + a * (1.0f - b.a);
        else if (u.compose == 2u) c = a + b * (1.0f - a.a);
        else if (u.compose == 3u) {
            // Wipe: position along the travel direction, 0 where the edge starts. At least half a pixel of softness (AA).
            float x = dot(uv - 0.5f, u.wipeDir) + 0.5f;
            float s = max(u.wipeSoft, 0.5f / max(dot(fabs(u.wipeDir), px), 1.0f));
            float m = 1.0f - smoothstep(u.wipeFront - s, u.wipeFront + s, x);
            c = a * (1.0f - m) + b * m;
        } else if (u.compose == 4u) {
            // Glitch (mirrors TransitionRender.Glitch): slice displacement + RGB split, hard cut at mix 0.5.
            uint band = min(uint(uv.y * 24.0f), 23u);
            uint seed = as_type<uint>(u.wipeDir.x);
            uint h = band * 0x9E3779B1u ^ seed * 0x85EBCA6Bu;
            h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
            float shift = 0.0f;
            if (float(h & 0xFFu) / 255.0f < 0.45f * u.wipeSoft) shift = (float((h >> 8) & 0xFFFFu) / 65535.0f * 2.0f - 1.0f) * 0.12f * u.wipeSoft;
            float split = 0.025f * clamp(u.wipeSoft, 0.0f, 1.0f);
            bool second = u.wipeFront >= 0.5f;
            texture2d<float, access::sample> t = second ? tb : ta;
            TransitionSideU s = second ? u.b : u.a;
            float4 r = transitionSide(t, uv + float2(shift + split, 0.0f), s, px);
            float4 g = transitionSide(t, uv + float2(shift, 0.0f), s, px);
            float4 bl = transitionSide(t, uv + float2(shift - split, 0.0f), s, px);
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
                float rot = 6.2831853f * fract(52.9829189f * fract(dot(uv * px, float2(0.06711056f, 0.00583715f))));
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
            uint seed = as_type<uint>(u.wipeDir.x);
            float k = clamp(u.wipeSoft, 0.0f, 1.0f);
            uint row = uint(gid.y / 2u);
            uint hr = (row * 0x9E3779B1u) ^ (seed * 0x85EBCA6Bu);
            hr ^= hr >> 15; hr *= 0x2C1B3C6Du; hr ^= hr >> 12;
            float jitter = (float(hr & 0xFFFFu) / 65535.0f * 2.0f - 1.0f) * 0.04f * k * k;
            bool second = u.wipeFront >= 0.5f;
            float4 pic = transitionSide(second ? tb : ta, float2(clamp(uv.x + jitter, 0.5f / px.x, 1.0f - 0.5f / px.x), uv.y), second ? u.b : u.a, px);
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
            float2 gi = floor(g), gf = fract(g);
            gf = gf * gf * (3.0f - 2.0f * gf);
            float v00 = lnHash(gi), v10 = lnHash(gi + float2(1, 0)), v01 = lnHash(gi + float2(0, 1)), v11 = lnHash(gi + float2(1, 1));
            float nz = mix(mix(v00, v10, gf.x), mix(v01, v11, gf.x), gf.y);
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
                if (d < 0.0f) d += 1.0f;
            } else if (shape == 1) d = max(fabs(q.x), fabs(q.y));
            else if (shape == 2) d = (fabs(q.x) + fabs(q.y)) * 0.5f;
            else if (shape == 3) d = min(fabs(q.x), fabs(q.y));
            else if (shape == 4) d = fabs(q.x);
            else if (shape == 5) d = fabs(q.y);
            else if (shape == 6) { float t = uv.y * 8.0f; d = t - floor(t); }
            else if (shape == 7) d = atan2(uv.x, uv.y) * 0.63661977f;
            else if (shape == 8) d = atan2(fabs(q.x), -q.y) * 0.31830989f;
            else if (shape == 9) {
                float c = atan2(q.x, -q.y) * 0.15915494309f;
                if (c < 0.0f) c += 1.0f;
                c *= 4.0f;
                d = c - floor(c);
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
            } else if (shape == 12) d = max(uv.x, uv.y);
            else if (shape == 14) d = (int(floor(uv.y * 10.0f)) % 2 == 0) ? uv.x : 1.0f - uv.x;
            else if (shape == 13) {
                uint cx = uint(min(floor(uv.x * 12.0f), 11.0f));
                uint cy = uint(min(floor(uv.y * 8.0f), 7.0f));
                uint h = (cx * 73856093u) ^ (cy * 19349663u);
                h = (h ^ (h >> 13)) * 1274126177u;
                h ^= h >> 16;
                d = float(h & 0xFFFFu) / 65536.0f;
            } else d = 0.0f;
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
            bool vert = fabs(u.wipeDir.y) > fabs(u.wipeDir.x);
            float sgn = (u.wipeDir.x + u.wipeDir.y) > 0.0f ? 1.0f : -1.0f;
            bool second = p >= 0.5f;
            float ang = sgn * (p * 3.14159265f - (second ? 3.14159265f : 0.0f));
            float2 X = (uv - 0.5f) * 2.0f;
            if (vert) X = X.yx;
            float ca = cos(ang), sa = sin(ang);
            float den = 3.0f * ca + X.x * sa;
            c = float4(0.0f);
            if (den > 0.05f) {
                float x = X.x * 3.0f / den;
                float y = X.y * (3.0f - x * sa) / 3.0f;
                if (fabs(x) <= 1.0f && fabs(y) <= 1.0f) {
                    float2 sq = vert ? float2(y, x) : float2(x, y);
                    c = transitionSide(second ? tb : ta, sq * 0.5f + 0.5f, second ? u.b : u.a, px);
                }
            }
        } else if (u.compose == 13u) {
            // Burn: A burns away along a noise field (plus a lean along the direction) with a glowing edge, B behind it.
            float p = clamp(u.wipeFront, 0.0f, 1.0f);
            float2 g = uv * float2(px.x / px.y, 1.0f) * 4.0f;
            float2 gi = floor(g), gf = fract(g);
            gf = gf * gf * (3.0f - 2.0f * gf);
            float nz = mix(mix(lnHash(gi), lnHash(gi + float2(1, 0)), gf.x), mix(lnHash(gi + float2(0, 1)), lnHash(gi + float2(1, 1)), gf.x), gf.y);
            float d = 0.7f * nz + 0.3f * (dot(uv - 0.5f, u.wipeDir) + 0.5f);
            float band = 0.12f;
            float t = p * (1.0f + band);
            float aa = 0.5f / max(min(px.x, px.y), 1.0f);
            float m = 1.0f - smoothstep(t - aa, t + aa, d);
            c = a * (1.0f - m) + b * m;
            float edge = clamp((d - t) / band, 0.0f, 1.0f);
            float fire = (1.0f - edge) * (1.0f - edge) * step(0.0f, d - t + aa);
            float3 hot = mix(float3(1.0f, 0.35f, 0.05f), float3(1.0f, 0.9f, 0.6f), fire * fire);
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
            float4 pr = transitionSide(second ? tb : ta, clamp(uv + off + float2(split, 0.0f), lo, hi), second ? u.b : u.a, px);
            float4 pg = transitionSide(second ? tb : ta, clamp(uv + off, lo, hi), second ? u.b : u.a, px);
            float4 pb = transitionSide(second ? tb : ta, clamp(uv + off - float2(split, 0.0f), lo, hi), second ? u.b : u.a, px);
            c = float4(pr.r, pg.g, pb.b, pg.a);
        } else c = a + b;
        if (u.borderWidth > 0.0f) {
            // Border (mirrors TransitionRender.Border.coverage): a band centered on the moving edge, half a pixel of AA.
            float x = dot(uv - 0.5f, u.wipeDir) + 0.5f;
            float aa = max(0.5f / max(dot(fabs(u.wipeDir), px), 1.0f), 1e-6f);
            float h = 0.5f * u.borderWidth;
            float cov = (1.0f - smoothstep(h - aa, h + aa, fabs(x - u.wipeFront)))
                      * smoothstep(0.0f, h, u.wipeFront) * smoothstep(0.0f, h, 1.0f - u.wipeFront);
            c = c * (1.0f - cov) + float4(u.borderR, u.borderG, u.borderB, 1.0f) * cov;
        }
        return c;
    }

    // Drop Shadow, step 1: the picture's alpha shifted by `offset` px (bilinear, zero outside) into an alpha plane.
    struct ShadowUniforms { float2 offset; float4 color; int shadowOnly; float spread; };

    kernel void shadowExtract(texture2d<float, access::sample> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant ShadowUniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float W = float(dst.get_width()), H = float(dst.get_height());
        if (gid.x >= uint(W) || gid.y >= uint(H)) return;
        constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
        // dst may be smaller than src (reduced alpha plane): the offset is in src px.
        float2 uv = (float2(gid) + 0.5f) / float2(W, H) - u.offset / float2(src.get_width(), src.get_height());
        dst.write(float4(src.sample(s, uv).a), gid);
    }

    // Step 3: shadow color (premultiplied by the blurred alpha and opacity) behind the picture, or alone for Shadow Only.
    kernel void shadowComposite(texture2d<float, access::read> img [[texture(0)]],
                                texture2d<float, access::sample> blurred [[texture(1)]],
                                texture2d<float, access::write> dst [[texture(2)]],
                                constant ShadowUniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float ba = blurred.sample(s, (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height())).r;
        float a = min(1.0f, ba / max(1.0f - u.spread, 0.01f)) * u.color.a;   // Spread: choke the soft edge outwards
        float4 sh = float4(u.color.rgb * a, a);
        float4 p = img.read(gid);
        dst.write(u.shadowOnly != 0 ? sh : p + sh * (1.0f - p.a), gid);
    }
    """
}
