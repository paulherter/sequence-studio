/// MSL for the compositor, compiled at runtime (SwiftPM CLI does not bundle .metal; same pattern as ColorShaderSource).
/// `CompositeUniforms` mirrors `Compositor.Uniforms` (224 bytes).
enum CompositorShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    struct CompositeUniforms {
        float3x3 m;          // Y'CbCr -> R'G'B'
        float4 solid;        // placeholder colour (working-linear)
        float4 range;        // yScale, yBias, cScale, cBias
        float2 canvas;       // sequence size, px
        float2 size;         // layer size, px (its own upright size, before transform scale)
        float2 position;     // offset from canvas centre, px, y down
        float2 anchor;       // offset from layer centre, px
        float2 scale;
        float rotCos, rotSin, opacity;
        uint mode;           // 0 = YCbCr bi-planar, 1 = RGB texture, 2 = solid, 3 = premultiplied RGBA group image (linear)
        uint linearize;      // 1 = apply inverse BT.709 OETF (no colour stage)
        float cornerRadius;  // layer-local px (before transform scale)
        uint quarter;        // clockwise quarter turns of the source picture (modes 0 and 1)
        uint blend;          // blend mode id (compositeFragmentBlend only): 1 multiply, 2 screen, 3 add, 4 overlay
        float2 maskSize;     // rectangle Crop / Rounded Corners work on, layer px; 0 = size
        float4 crop;         // left, top, right, bottom insets as fractions of maskSize
        float4 key0;         // Ultra Key: hue (deg), half width (deg), soft edge (deg), spill (0...1)
        float4 key1;
        uint keyCount;       // keys in use (0...2)
    };

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    inline float3 sourceEncoded(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, float2 uv) {
        if (u.mode == 1) return ty.sample(linearSampler, uv).rgb;
        float y = ty.sample(linearSampler, uv).r * u.range.x + u.range.y;
        float2 c = tc.sample(linearSampler, uv).rg * u.range.z + u.range.w;
        return u.m * float3(y, c.x, c.y);
    }

    inline float3 inverseOETF709(float3 e) {
        e = max(e, 0.0f);
        float3 lo = e / 4.5f;
        float3 hi = pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f);
        return select(hi, lo, e < 0.081242858f);
    }

    kernel void convertToRGB(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                             texture2d<float, access::write> out [[texture(2)]],
                             constant CompositeUniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 uv = (float2(gid) + 0.5f) / float2(out.get_width(), out.get_height());
        if (u.mode == 1) {
            // RGB source with alpha (still image): keep alpha, colour un-premultiplied for the colour stage.
            float4 c = ty.sample(linearSampler, uv);
            out.write(float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a), gid);
            return;
        }
        out.write(float4(sourceEncoded(u, ty, tc, uv), 1.0f), gid);
    }

    struct VOut { float4 position [[position]]; float2 local; };

    // Edge antialiasing (mask on the layer rect) is on for rounded or rotated layers only, so axis-aligned
    // unrounded layers stay bit-exact. The quad is grown by 1 screen px then so edge pixels outside get covered.
    inline bool hasCrop(constant CompositeUniforms& u) { return any(u.crop != 0.0f); }
    inline bool edgeAA(constant CompositeUniforms& u) { return u.cornerRadius > 0.0f || u.rotSin != 0.0f || hasCrop(u); }

    vertex VOut compositeVertex(uint vid [[vertex_id]], constant CompositeUniforms& u [[buffer(0)]]) {
        float2 uv = float2(vid & 1, vid >> 1);
        float2 local = (uv - 0.5f) * u.size;
        if (edgeAA(u)) local += (uv * 2.0f - 1.0f) * (1.0f / max(u.scale, 1e-4f));
        float2 p = (local - u.anchor) * u.scale;
        float2 r = float2(u.rotCos * p.x - u.rotSin * p.y, u.rotSin * p.x + u.rotCos * p.y);
        float2 px = u.canvas * 0.5f + u.position + r;
        VOut o;
        o.position = float4(px.x / u.canvas.x * 2.0f - 1.0f, 1.0f - px.y / u.canvas.y * 2.0f, 0.0f, 1.0f);
        o.local = local;
        return o;
    }

    // One Ultra Key on un-premultiplied linear colour: returns K (how much is keyed out) and desaturates spill in `c`.
    // Mirrors UltraKey.key (CPU reference).
    inline float applyChromaKey(float4 k, thread float3& c) {
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
        float key = inside * weight;
        float zone = 1.0f - smoothstep(k.y + k.z, 2.0f * k.y + k.z + 20.0f, dist);
        float w = k.w * zone * weight * (1.0f - key);
        float luma = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        c = c + (float3(luma) - c) * w;
        return key;
    }

    inline float4 shadeLayer(VOut in, constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc) {
        float cover = 1.0f;
        if (edgeAA(u)) {
            // Kept rectangle: the mask rectangle minus the crop insets, rounded by cornerRadius.
            float2 ms = u.maskSize.x > 0.0f ? u.maskSize : u.size;
            float2 lo = -0.5f * ms + u.crop.xy * ms;
            float2 hi = 0.5f * ms - u.crop.zw * ms;
            float2 c = 0.5f * (lo + hi);
            float2 h = 0.5f * (hi - lo);
            float r = min(u.cornerRadius, min(h.x, h.y));
            float2 q = abs(in.local - c) - h + r;
            float d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;   // signed distance, layer px
            float w = 1.0f / max(min(u.scale.x, u.scale.y), 1e-4f);          // layer px per screen px (not dfdx: a 2x2 quad edge skews it)
            cover = clamp(0.5f - d / w, 0.0f, 1.0f);
        }
        float2 uv = in.local / u.size + 0.5f;
        if (u.mode != 3 && u.quarter != 0) {
            // uv is in the upright picture; turn it back into the source texture (clockwise display turn).
            if (u.quarter == 1) uv = float2(uv.y, 1.0f - uv.x);
            else if (u.quarter == 2) uv = float2(1.0f - uv.x, 1.0f - uv.y);
            else uv = float2(1.0f - uv.y, uv.x);
        }
        if (u.mode == 3) {
            float4 g = ty.sample(linearSampler, uv);   // premultiplied, already working-linear
            float k = u.opacity * cover;
            return g * k;
        }
        float texA = 1.0f;
        float3 rgb;
        if (u.mode == 2) {
            rgb = u.solid.rgb;
        } else if (u.mode == 1 && u.linearize != 0) {
            // RGB texture (video BGRA or a still image): premultiplied alpha, un-premultiply before the transfer curve.
            float4 c = ty.sample(linearSampler, uv);
            texA = c.a;
            rgb = texA > 0.0f ? c.rgb / texA : float3(0.0f);
        } else if (u.mode == 1) {
            // Colour-stage output (linear rgb, straight alpha).
            float4 c = ty.sample(linearSampler, uv);
            texA = c.a;
            rgb = c.rgb;
        } else {
            rgb = sourceEncoded(u, ty, tc, uv);
        }
        if (u.mode != 2 && u.linearize != 0) rgb = inverseOETF709(rgb);
        rgb = max(rgb, 0.0f);
        if (u.mode != 2u && u.keyCount > 0u) {
            texA *= 1.0f - applyChromaKey(u.key0, rgb);
            if (u.keyCount > 1u) texA *= 1.0f - applyChromaKey(u.key1, rgb);
        }
        float a = u.opacity * cover * texA;
        return float4(rgb * a, a);   // premultiplied
    }

    fragment float4 compositeFragment(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                      texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]]) {
        return shadeLayer(in, u, ty, tc);
    }

    // B(cd, cs) of the blend modes; mirrors BlendModes.channel (CPU reference).
    inline float3 blendChannel(uint mode, float3 cd, float3 cs) {
        if (mode == 1u) return cd * cs;
        if (mode == 2u) return cd + cs - cd * cs;
        if (mode == 3u) return cd + cs;
        if (mode == 4u) {
            float3 lo = 2.0f * cd * cs;
            float3 hi = 1.0f - 2.0f * (1.0f - cd) * (1.0f - cs);
            return select(hi, lo, cd <= 0.5f);
        }
        return cs;
    }

    // Single-layer composite with a blend mode: reads the destination (programmable blending, Apple GPUs) and writes the
    // finished pixel, so the pipeline has fixed-function blending off.
    fragment float4 compositeFragmentBlend(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                           texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                                           float4 dst [[color(0)]]) {
        float4 s = shadeLayer(in, u, ty, tc);
        float3 cs = s.a > 0.0f ? s.rgb / s.a : float3(0.0f);
        float3 cd = dst.a > 0.0f ? dst.rgb / dst.a : float3(0.0f);
        float3 b = blendChannel(u.blend, cd, cs);
        float3 rgb = s.rgb * (1.0f - dst.a) + dst.rgb * (1.0f - s.a) + s.a * dst.a * b;
        return float4(rgb, s.a + dst.a * (1.0f - s.a));
    }

    // One axis of a separable Gaussian: out(p) = sum_k w[k + r] * in(p + k * axis), zero outside the image.
    struct BlurUniforms { int2 axis; int radius; };

    kernel void gaussianBlur1D(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant BlurUniforms& b [[buffer(0)]], constant float* w [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int W = int(src.get_width()), H = int(src.get_height());
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        float4 acc = float4(0.0f);
        for (int k = -b.radius; k <= b.radius; k++) {
            int2 p = int2(gid) + b.axis * k;
            if (p.x < 0 || p.y < 0 || p.x >= W || p.y >= H) continue;
            acc += src.read(uint2(p)) * w[k + b.radius];
        }
        dst.write(acc, gid);
    }
    """
}
