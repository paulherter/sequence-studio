/// MSL for the compositor, compiled at runtime (SwiftPM CLI does not bundle .metal; same pattern as ColorShaderSource).
/// `CompositeUniforms` mirrors `Compositor.Uniforms` (160 bytes).
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

    // Frame Blending in light-linear space: out = mix(lin(a), lin(b), w). p.y = 1: the inputs are source-encoded BT.709 (apply the
    // inverse OETF first); 0: already working-linear (the colour pipeline ran).
    kernel void blendFrames(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            constant float2& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float4 x = a.read(gid), y = b.read(gid);
        if (p.y != 0.0f) { x.rgb = inverseOETF709(x.rgb); y.rgb = inverseOETF709(y.rgb); }
        out.write(mix(x, y, p.x), gid);
    }

    struct VOut { float4 position [[position]]; float2 local; };

    // Edge antialiasing (mask on the layer rect) is on for rounded or rotated layers only, so axis-aligned
    // unrounded layers stay bit-exact. The quad is grown by 1 screen px then so edge pixels outside get covered.
    inline bool edgeAA(constant CompositeUniforms& u) { return u.cornerRadius > 0.0f || u.rotSin != 0.0f; }

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

    fragment float4 compositeFragment(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                      texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]]) {
        float cover = 1.0f;
        if (edgeAA(u)) {
            float2 h = u.size * 0.5f;
            float r = min(u.cornerRadius, min(h.x, h.y));
            float2 q = abs(in.local) - h + r;
            float d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;   // signed distance, layer px
            float w = max(length(float2(dfdx(d), dfdy(d))), 1e-6f);          // layer px per screen px
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
        float a = u.opacity * cover * texA;
        return float4(rgb * a, a);   // premultiplied
    }
    """
}
