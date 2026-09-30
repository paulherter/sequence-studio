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
        uint pad;
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

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut compositeVertex(uint vid [[vertex_id]], constant CompositeUniforms& u [[buffer(0)]]) {
        float2 uv = float2(vid & 1, vid >> 1);
        float2 p = ((uv - 0.5f) * u.size - u.anchor) * u.scale;
        float2 r = float2(u.rotCos * p.x - u.rotSin * p.y, u.rotSin * p.x + u.rotCos * p.y);
        float2 px = u.canvas * 0.5f + u.position + r;
        VOut o;
        o.position = float4(px.x / u.canvas.x * 2.0f - 1.0f, 1.0f - px.y / u.canvas.y * 2.0f, 0.0f, 1.0f);
        o.uv = uv;
        return o;
    }

    fragment float4 compositeFragment(VOut in [[stage_in]], constant CompositeUniforms& u [[buffer(0)]],
                                      texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]]) {
        float3 rgb = u.mode == 2 ? u.solid.rgb : sourceEncoded(u, ty, tc, in.uv);
        if (u.mode != 2 && u.linearize != 0) rgb = inverseOETF709(rgb);
        rgb = max(rgb, 0.0f);
        return float4(rgb * u.opacity, u.opacity);   // premultiplied
    }
    """
}
