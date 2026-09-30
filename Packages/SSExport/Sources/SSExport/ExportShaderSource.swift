import Foundation

/// MSL for the export output stage (working-linear -> BT.709 encoded 8-bit) and the caption overlay.
enum ExportShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    constant float kAlpha = 1.09929682680944;
    constant float kBeta = 0.018053968510807;

    static inline float3 oetf709(float3 l) {
        l = clamp(l, 0.0, 1.0);
        return select(kAlpha * pow(l, 0.45) - (kAlpha - 1.0), 4.5 * l, l < kBeta);
    }

    constexpr sampler linSampler(filter::linear, address::clamp_to_edge, coord::normalized);

    static inline float3 encodedAt(texture2d<float> src, float2 uv) {
        return oetf709(src.sample(linSampler, uv).rgb);
    }

    kernel void encodeBGRA(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(float4(encodedAt(src, uv), 1.0), gid);
    }

    kernel void encodeLuma(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 c = encodedAt(src, uv);
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        dst.write(float4((16.0 + 219.0 * y) / 255.0, 0, 0, 1), gid);
    }

    // dst is the chroma plane (half the luma size); each texel averages its 2x2 luma block.
    kernel void encodeChroma(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 lumaSize = float2(dst.get_width() * 2, dst.get_height() * 2);
        float3 sum = float3(0);
        for (uint j = 0; j < 2; j++) for (uint i = 0; i < 2; i++) {
            float2 uv = (float2(gid) * 2.0 + float2(i, j) + 0.5) / lumaSize;
            sum += encodedAt(src, uv);
        }
        float3 c = sum * 0.25;
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        float cb = (c.b - y) / 1.8556;
        float cr = (c.r - y) / 1.5748;
        dst.write(float4((128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0, 0, 1), gid);
    }

    struct OverlayU {
        float2 canvas;
        float2 center;
        float2 size;
        float scale;
        float opacity;
    };
    struct OverlayOut { float4 pos [[position]]; float2 uv; };

    vertex OverlayOut overlayVertex(uint vid [[vertex_id]], constant OverlayU& u [[buffer(0)]]) {
        float2 q = float2(vid & 1, vid >> 1);
        float2 p = u.center + (q - 0.5) * u.size * u.scale;
        OverlayOut o;
        o.pos = float4(p.x / u.canvas.x * 2.0 - 1.0, 1.0 - p.y / u.canvas.y * 2.0, 0, 1);
        o.uv = q;
        return o;
    }

    // Premultiplied linear source; blending (one, 1 - srcAlpha) does the over.
    fragment float4 overlayFragment(OverlayOut in [[stage_in]], constant OverlayU& u [[buffer(0)]],
                                    texture2d<float> tex [[texture(0)]]) {
        return tex.sample(linSampler, in.uv) * u.opacity;
    }
    """
}
