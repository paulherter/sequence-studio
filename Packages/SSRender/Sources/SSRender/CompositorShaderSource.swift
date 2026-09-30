/// MSL for the compositor, compiled at runtime (SwiftPM CLI does not bundle .metal; same pattern as ColorShaderSource).
/// `CompositeUniforms` mirrors `Compositor.Uniforms` (144 bytes).
enum CompositorShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    struct CompositeUniforms {
        float3x3 m;          // Y'CbCr -> R'G'B'
        float4 solid;        // placeholder colour (working-linear)
        float4 range;        // yScale, yBias, cScale, cBias
        float2 canvas;       // sequence size, px
        float2 size;         // aspect-fitted layer size, px (before transform scale)
        float2 position;     // offset from canvas centre, px, y down
        float2 anchor;       // offset from layer centre, px
        float2 scale;
        float rotCos, rotSin, opacity;
        uint mode;           // 0 = YCbCr bi-planar, 1 = RGB texture, 2 = solid
        uint linearize;      // 1 = apply inverse BT.709 OETF (no colour stage)
        float cornerRadius;  // layer-local px (aspect-fitted layer, before transform scale)
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
        out.write(float4(sourceEncoded(u, ty, tc, uv), 1.0f), gid);
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
        float3 rgb = u.mode == 2 ? u.solid.rgb : sourceEncoded(u, ty, tc, uv);
        if (u.mode != 2 && u.linearize != 0) rgb = inverseOETF709(rgb);
        rgb = max(rgb, 0.0f);
        float a = u.opacity * cover;
        return float4(rgb * a, a);   // premultiplied
    }
    """
}
