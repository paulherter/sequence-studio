import Foundation
import SQRender

/// MSL for the export output stage (working-linear -> BT.709 encoded 8-bit) and the caption overlay.
/// With an HDR delivery the same kernels encode Rec.2020 HLG or PQ instead (primaries conversion, transfer, Rec.2020 matrix):
/// `msl(hdr:)` prefixes `SQ_HDR` = 1 (HLG) or 2 (PQ); `msl` is the Rec.709 source.
enum ExportShaderSource {
    static let msl = msl(hdr: nil)

    static func msl(hdr: HDRDelivery.Transfer?) -> String {
        let mode = hdr == nil ? 0 : (hdr == .hlg ? 1 : 2)
        return "#define SQ_HDR \(mode)\n#define HLG_SCALE \(TransferFunctions.hlgScale)\n" + body
    }

    private static let body = """
    #include <metal_stdlib>
    using namespace metal;

    constant float kAlpha = 1.09929682680944;
    constant float kBeta = 0.018053968510807;

    static inline float3 oetf709(float3 l) {
        l = clamp(l, 0.0, 1.0);
        return select(kAlpha * pow(l, 0.45) - (kAlpha - 1.0), 4.5 * l, l < kBeta);
    }

    // Linear Rec.709 working light (1.0 = reference white, 203 nit) -> output signal. Mirrors `HDRDelivery.encode`.
    static inline float hlgOETF(float s) {
        s = max(s, 0.0);
        return s <= 1.0 / 12.0 ? sqrt(3.0 * s) : 0.17883277 * log(12.0 * s - 0.28466892) + 0.55991073;
    }
    static inline float pqOETF(float l) {
        float y = pow(max(l, 0.0) * 203.0 / 10000.0, 0.1593017578125);
        return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375);
    }
    static inline float3 signalOut(float3 lin) {
    #if SQ_HDR == 0
        return oetf709(lin);
    #else
        float3 c = float3(dot(float3(0.627404, 0.329283, 0.043313), lin), dot(float3(0.069097, 0.919540, 0.011362), lin),
                          dot(float3(0.016391, 0.088013, 0.895595), lin));
        c = max(c, 0.0);
    #if SQ_HDR == 1
        float hlgScale = HLG_SCALE;
        float3 fd = c / hlgScale;
        float yd = dot(float3(0.2627, 0.6780, 0.0593), fd);
        if (yd <= 0.0) { return float3(0.0); }
        float3 e = fd / pow(pow(yd, 1.0 / 1.2), 0.2);
        return clamp(float3(hlgOETF(e.x), hlgOETF(e.y), hlgOETF(e.z)), 0.0, 1.0);
    #else
        return clamp(float3(pqOETF(c.x), pqOETF(c.y), pqOETF(c.z)), 0.0, 1.0);
    #endif
    #endif
    }

    #if SQ_HDR == 0
    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);
    constant float kCbDiv = 1.8556, kCrDiv = 1.5748;
    #else
    constant float3 kLuma = float3(0.2627, 0.6780, 0.0593);
    constant float kCbDiv = 1.8814, kCrDiv = 1.4746;
    #endif

    constexpr sampler linSampler(filter::linear, address::clamp_to_edge, coord::normalized);

    static inline float3 encodedAt(texture2d<float> src, float2 uv) {
        return signalOut(src.sample(linSampler, uv).rgb);
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
        float y = dot(c, kLuma);
        dst.write(float4((16.0 + 219.0 * y) / 255.0, 0, 0, 1), gid);
    }

    // Chroma siting 'Left' (tagged on every YUV buffer, H.264/HEVC default chroma_sample_loc_type 0, ProRes 4:2:2):
    // horizontally co-sited with even luma columns, so chroma texel x sits on luma column 2x and is filtered
    // [1/4, 1/2, 1/4] over columns 2x-1, 2x, 2x+1. Vertically (4:2:0 only, `rows` = 2) it sits between luma rows
    // 2y and 2y+1 and averages them. Returns gamma-encoded R'G'B' (the YCbCr matrix is linear in R'G'B').
    static inline float3 chromaRGB(texture2d<float> src, uint2 gid, float2 lumaSize, uint rows) {
        float3 sum = float3(0);
        float x0 = float(gid.x * 2);
        for (uint j = 0; j < rows; j++) {
            float v = (float(gid.y * rows + j) + 0.5) / lumaSize.y;
            sum += 0.25 * encodedAt(src, float2((x0 - 0.5) / lumaSize.x, v))
                 + 0.50 * encodedAt(src, float2((x0 + 0.5) / lumaSize.x, v))
                 + 0.25 * encodedAt(src, float2((x0 + 1.5) / lumaSize.x, v));
        }
        return sum / float(rows);
    }

    // dst is the 4:2:0 chroma plane (half the luma size), sited as in `chromaRGB`.
    kernel void encodeChroma(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = chromaRGB(src, gid, float2(dst.get_width() * 2, dst.get_height() * 2), 2);
        float y = dot(c, kLuma);
        float cb = (c.b - y) / kCbDiv;
        float cr = (c.r - y) / kCrDiv;
        dst.write(float4((128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0, 0, 1), gid);
    }

    // 10-bit video range (Y 64..940, C 64..960) stored in the high bits of 16-bit planes ('x420', 'x422', 'y416').
    static inline float3 ycbcr(float3 c) {
        float y = dot(c, kLuma);
        return float3(y, (c.b - y) / kCbDiv, (c.r - y) / kCrDiv);
    }
    static inline float code10(float v, float offset, float scale) {
        return round(clamp(offset + scale * v, 0.0, 1023.0)) * 64.0 / 65535.0;
    }

    kernel void encodeLuma10(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float y = ycbcr(encodedAt(src, uv)).x;
        dst.write(float4(code10(y, 64.0, 876.0), 0, 0, 1), gid);
    }

    // Chroma plane of 4:2:0 (half width and height) or 4:2:2 (half width); `blockH` = 2 or 1. Sited as in `chromaRGB`.
    static inline float4 chroma10(texture2d<float> src, uint2 gid, uint2 dstSize, uint blockH) {
        float3 c = ycbcr(chromaRGB(src, gid, float2(dstSize.x * 2, dstSize.y * blockH), blockH));
        return float4(code10(c.y, 512.0, 896.0), code10(c.z, 512.0, 896.0), 0, 1);
    }

    kernel void encodeChroma420_10(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(chroma10(src, gid, uint2(dst.get_width(), dst.get_height()), 2), gid);
    }

    kernel void encodeChroma422_10(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(chroma10(src, gid, uint2(dst.get_width(), dst.get_height()), 1), gid);
    }

    // 16-bit video range for 'y416' (ProRes 4444 is 12-bit: keep the full precision): Y 4096..60160, C 4096..61440.
    static inline float code16(float v, float offset, float scale) {
        return round(clamp(offset + scale * v, 0.0, 65535.0)) / 65535.0;
    }

    // 'y416' texel = (A, Y, Cb, Cr), opaque.
    kernel void encodeAYUV16(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 c = ycbcr(encodedAt(src, uv));
        float alpha = 1.0;
        dst.write(float4(alpha, code16(c.x, 4096.0, 56064.0), code16(c.y, 32768.0, 57344.0), code16(c.z, 32768.0, 57344.0)), gid);
    }

    // ProRes 4444 with alpha: the working texture is premultiplied linear over transparent. Un-premultiply, encode the
    // straight color and write the coverage as (full-range) alpha.
    kernel void encodeAYUV16Alpha(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float4 p = src.sample(linSampler, uv);
        float alpha = clamp(p.a, 0.0, 1.0);
        float3 straight = alpha > 0.0 ? p.rgb / alpha : float3(0.0);
        float3 c = ycbcr(signalOut(straight));
        dst.write(float4(alpha, code16(c.x, 4096.0, 56064.0), code16(c.y, 32768.0, 57344.0), code16(c.z, 32768.0, 57344.0)), gid);
    }

    // Image sequences: the premultiplied linear working picture, resampled to the output size.
    kernel void encodeRGBAHalf(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(src.sample(linSampler, uv), gid);
    }

    struct OverlayU {
        float2 canvas;
        float2 center;
        float2 size;
        float scale;
        float opacity;
        float rotation;
    };
    struct OverlayOut { float4 pos [[position]]; float2 uv; };

    vertex OverlayOut overlayVertex(uint vid [[vertex_id]], constant OverlayU& u [[buffer(0)]]) {
        float2 q = float2(vid & 1, vid >> 1);
        float2 d = (q - 0.5) * u.size * u.scale;
        float co = cos(u.rotation), si = sin(u.rotation);
        float2 p = u.center + float2(co * d.x - si * d.y, si * d.x + co * d.y);
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
