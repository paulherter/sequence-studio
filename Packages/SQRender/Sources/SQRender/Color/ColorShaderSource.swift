/// MSL source of the colour chain. Mirrors `ColorPipeline.process` 1:1 (same constants, order, clamps).
///
/// Embedded as a string (not a `.metal` file): SwiftPM without Package.swift resources neither compiles nor bundles
/// `.metal` files (`swift test` warns "unhandled file" and `Bundle.module` does not exist). Compiled at runtime with
/// `MTLCompileOptions.mathMode = .safe` by `ColorPipelineGPU`.
enum ColorShaderSource {
    static let msl = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ColorHeader {
        uint4 ints;   // section count, start domain (0 source-encoded, 1 source-linear, 2 display), end domain (1, 2, 3 = working-linear), source (0 S-Log3, 1 HLG, 2 Rec.709)
        uint4 extra;  // x != 0: the texture is a quarter-turned picture (vignette geometry follows the upright picture)
    };

    // One block of the chain (layout mirrors ColorPipelineGPU.Sec).
    struct Sec {
        uint4 head;   // kind, pre, flags, extra
        float4 a, b, c, d;
        float3x3 m;
    };

    constant uint kConversion = 0, kBasic = 1, kCreative = 2, kLook = 3, kCurves = 4, kWheels = 5, kVignette = 6, kHueCurves = 7;
    constant uint kLutPresent = 1, kLut1D = 2, kLutIn = 4, kLutOut = 8;
    constant float kMinLuma = 1.0f / 65536.0f;
    constant uint kCurveCount = 64;

    // MARK: transfer functions (TransferFunctions.swift)

    constant float kSlog3CutEncoded = 171.2102946929f / 1023.0f;
    constant float kSlog3CutLinear = 0.01125f;

    float slog3Decode(float x) {
        if (x >= kSlog3CutEncoded) {
            return pow(10.0f, (x * 1023.0f - 420.0f) / 261.5f) * (0.18f + 0.01f) - 0.01f;
        }
        return (x * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f);
    }
    float slog3Encode(float y) {
        if (y >= kSlog3CutLinear) {
            return (420.0f + log10((y + 0.01f) / (0.18f + 0.01f)) * 261.5f) / 1023.0f;
        }
        return (y * (171.2102946929f - 95.0f) / 0.01125f + 95.0f) / 1023.0f;
    }
    float slog3DecodeLegal(float v) { return slog3Decode((v * 876.0f + 64.0f) / 1023.0f); }
    float slog3EncodeLegal(float y) { return (slog3Encode(y) * 1023.0f - 64.0f) / 876.0f; }

    constant float kHlgA = 0.17883277f;
    constant float kHlgB = 0.28466892f;
    constant float kHlgC = 0.55991073f;
    constant float kHlgGamma = 1.2f;
    constant float3 kHlgLuma = float3(0.2627f, 0.6780f, 0.0593f);

    float hlgInverseOETF(float e) {
        e = max(e, 0.0f);
        if (e <= 0.5f) { return e * e / 3.0f; }
        return (exp((e - kHlgC) / kHlgA) + kHlgB) / 12.0f;
    }
    float hlgOETF(float s) {
        s = max(s, 0.0f);
        if (s <= 1.0f / 12.0f) { return sqrt(3.0f * s); }
        return kHlgA * log(12.0f * s - kHlgB) + kHlgC;
    }
    // Non-separable HLG OOTF (TransferFunctions.hlgDecode / hlgEncode). Scale is derived: 1 / E75^γ.
    float hlgScale() {
        float e = hlgInverseOETF(0.75f);
        return 1.0f / (e * pow(e, kHlgGamma - 1.0f));
    }
    float3 hlgDecode3(float3 v) {
        float3 e = float3(hlgInverseOETF(v.x), hlgInverseOETF(v.y), hlgInverseOETF(v.z));
        float ys = dot(kHlgLuma, e);
        float gain = ys > 0.0f ? pow(ys, kHlgGamma - 1.0f) : 0.0f;
        return e * gain * hlgScale();
    }
    float3 hlgEncode3(float3 v) {
        float3 fd = v / hlgScale();
        float yd = dot(kHlgLuma, fd);
        if (!(yd > 0.0f)) { return float3(hlgOETF(0.0f)); }
        float ys = pow(yd, 1.0f / kHlgGamma);
        float3 e = fd / pow(ys, kHlgGamma - 1.0f);
        return float3(hlgOETF(e.x), hlgOETF(e.y), hlgOETF(e.z));
    }

    constant float kBt709Alpha = 1.09929682680944f;
    constant float kBt709Beta = 0.018053968510807f;

    float bt709OETF(float l) {
        if (l < kBt709Beta) { return 4.5f * l; }
        return kBt709Alpha * pow(l, 0.45f) - (kBt709Alpha - 1.0f);
    }
    float bt709InverseOETF(float v) {
        if (v < 4.5f * kBt709Beta) { return v / 4.5f; }
        return pow((v + kBt709Alpha - 1.0f) / kBt709Alpha, 1.0f / 0.45f);
    }

    float3 map3(float3 v, int fn) {
        switch (fn) {
        case 0: return float3(slog3DecodeLegal(v.x), slog3DecodeLegal(v.y), slog3DecodeLegal(v.z));
        case 1: return hlgDecode3(v);
        case 2: return float3(bt709InverseOETF(v.x), bt709InverseOETF(v.y), bt709InverseOETF(v.z));
        case 3: return float3(slog3EncodeLegal(v.x), slog3EncodeLegal(v.y), slog3EncodeLegal(v.z));
        case 4: return hlgEncode3(v);
        case 5: return float3(bt709OETF(v.x), bt709OETF(v.y), bt709OETF(v.z));
        default: return v;
        }
    }

    // MARK: tone maths (ColorStages.swift)

    float smoothS(float a, float b, float x) {
        float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    float skinWeight(float3 t) {
        if (!(t.x >= t.y && t.y >= t.z && t.x > t.z)) { return 0.0f; }
        float f = (t.y - t.z) / (t.x - t.z);
        return smoothS(0.10f, 0.30f, f) * (1.0f - smoothS(0.70f, 0.95f, f));
    }

    float3 satVib(float3 t, float sat, float vib, float3 luma) {
        float s = sat;
        if (vib != 0.0f) {
            float mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z));
            float sv = mx > 1e-4f ? clamp((mx - mn) / mx, 0.0f, 1.0f) : 0.0f;
            if (vib > 0.0f) { s *= 1.0f + vib * (1.0f - sv) * (1.0f - 0.5f * skinWeight(t)); }
            else { s *= 1.0f + vib * (0.3f + 0.7f * sv); }
        }
        if (s == 1.0f) { return t; }
        float y = dot(luma, t);
        return float3(y) + (t - float3(y)) * s;
    }

    // flags: 1 WB, 2 exposure, 4 contrast, 8 shadows, 16 levels, 32 saturation/vibrance, 64 highlights
    float3 basicStage(float3 c, constant Sec &s, bool pre) {
        uint f = s.head.z;
        float3 x = c;
        if ((f & 3u) != 0u) {
            float3 lin = pre ? x : map3(x, 2);
            if (f & 1u) { lin = s.m * lin; }
            if (f & 2u) { lin *= s.a.x; }
            x = pre ? lin : map3(lin, 5);
        }
        if ((f & 124u) != 0u) {
            float3 t = pre ? map3(x, 5) : x;
            if (f & 4u) { t = float3(0.45f) + (t - float3(0.45f)) * s.a.y; }
            if (f & 8u) {
                float y = dot(s.c.xyz, t);
                t *= 1.0f + s.a.w * (1.0f - smoothS(0.0f, 0.6f, y));
            }
            if (f & 64u) {
                float y = dot(s.c.xyz, t);
                t += float3(s.a.z * smoothS(0.3f, 1.0f, y));
            }
            if (f & 16u) { t = (t - float3(s.b.x)) / (s.b.y - s.b.x); }
            t = satVib(t, s.b.z, s.b.w, s.c.xyz);
            x = pre ? map3(t, 2) : t;
        }
        return x;
    }

    float3 creativeStage(float3 c, constant Sec &s, bool pre) {
        float3 t = pre ? map3(c, 5) : c;
        float fade = s.a.x;
        if (fade != 0.0f) { t = t * (1.0f - fade) + float3(fade * 0.85f); }
        if (s.head.z & 1u) {
            float bal = s.a.w;
            float y = dot(s.d.xyz, t);
            float ms = 1.0f - smoothS(0.15f + 0.25f * bal, 0.65f + 0.25f * bal, y);
            float mh = smoothS(0.35f + 0.25f * bal, 0.85f + 0.25f * bal, y);
            t += ms * s.b.xyz + mh * s.c.xyz;
        }
        t = satVib(t, s.a.y, s.a.z, s.d.xyz);
        return pre ? map3(t, 2) : t;
    }

    float3 wheelsStage(float3 c, constant Sec &s, bool pre) {
        float3 t = pre ? map3(c, 5) : c;
        t += (1.0f - smoothS(0.0f, 0.5f, dot(s.d.xyz, t))) * s.a.xyz;
        if (s.head.z & 1u) {
            float y = dot(s.d.xyz, t);
            float wm = smoothS(0.0f, 0.5f, y) * (1.0f - smoothS(0.5f, 1.0f, y));
            float3 p = float3(pow(max(t.x, 0.0f), s.b.x), pow(max(t.y, 0.0f), s.b.y), pow(max(t.z, 0.0f), s.b.z));
            t += (p - t) * wm;
        }
        t *= float3(1.0f) + smoothS(0.35f, 1.15f, dot(s.d.xyz, t)) * s.c.xyz;
        t = satVib(t, s.a.w, 0.0f, s.d.xyz);
        return pre ? map3(t, 2) : t;
    }

    float3 vignetteStage(float3 c, constant Sec &s, bool pre, float2 uv, float aspect) {
        float px = (uv.x - 0.5f) * 2.0f * (1.0f + (aspect - 1.0f) * s.b.x), py = (uv.y - 0.5f) * 2.0f;
        float n = s.a.w;
        float e = n > 2.0001f ? pow(pow(fabs(px), n) + pow(fabs(py), n), 1.0f / n) : sqrt(px * px + py * py);
        float m = smoothS(s.a.y, s.a.y + s.a.z, e);
        return pre ? c * exp2(s.a.x * m) : c * exp2(0.45f * s.a.x * m);
    }

    float3 curvesStage(float3 c, constant Sec &s, bool pre, constant float4 *table) {
        float3 t = pre ? map3(c, 5) : c;
        uint base = s.head.w * kCurveCount;
        float3 o = t;
        for (int ch = 0; ch < 3; ch++) {
            float x = clamp(t[ch], 0.0f, 1.0f);
            float p = x * float(kCurveCount - 1);
            uint i = min(uint(p), kCurveCount - 2);
            float f = p - float(i);
            float v0 = table[base + i][ch], v1 = table[base + i + 1][ch];
            o[ch] = v0 + (v1 - v0) * f + (t[ch] - x);
        }
        return pre ? map3(o, 2) : o;
    }

    // Hue Saturation Curves (PreparedHueCurves.apply). Table rows 0…63: (hueVsSat, hueVsHue, hueVsLuma, lumaVsSat); rows 64…127: satVsSat.
    float hueSample(constant float4 *table, uint base, int column, float h) {
        float p = h * float(kCurveCount);
        uint i = min(uint(p), kCurveCount - 1);
        float f = p - float(i);
        float a = table[base + i][column], b = table[base + ((i + 1) % kCurveCount)][column];
        return a + (b - a) * f;
    }
    float linearSample(constant float4 *table, uint row0, int column, float x) {
        float p = clamp(x, 0.0f, 1.0f) * float(kCurveCount - 1);
        uint i = min(uint(p), kCurveCount - 2);
        float f = p - float(i);
        float a = table[row0 + i][column], b = table[row0 + i + 1][column];
        return a + (b - a) * f;
    }
    float3 hueCurvesStage(float3 c, constant Sec &s, bool pre, constant float4 *table) {
        float3 t = pre ? map3(c, 5) : c;
        uint base = s.head.w * kCurveCount;
        float mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z));
        float d = mx - mn;
        float hue = 0.0f;
        if (d > 1e-6f) {
            float h;
            if (mx == t.x) { h = (t.y - t.z) / d; } else if (mx == t.y) { h = (t.z - t.x) / d + 2.0f; } else { h = (t.x - t.y) / d + 4.0f; }
            h /= 6.0f;
            hue = h - floor(h);
        }
        float w = smoothS(0.005f, 0.05f, d);
        float sv = mx > 1e-4f ? clamp(d / mx, 0.0f, 1.0f) : 0.0f;
        float y0 = dot(s.d.xyz, t);
        float vs = hueSample(table, base, 0, hue), vh = hueSample(table, base, 1, hue), vl = hueSample(table, base, 2, hue);
        float ls = linearSample(table, base, 3, y0), ss = linearSample(table, base + kCurveCount, 0, sv);
        float theta = (vh - 0.5f) * 2.0f * (M_PI_F / 3.0f) * w;
        if (theta != 0.0f) {
            float m = (t.x + t.y + t.z) / 3.0f;
            float3 dv = t - float3(m);
            float3 cr = float3(dv.z - dv.y, dv.x - dv.z, dv.y - dv.x) * 0.57735027f;
            t = float3(m) + dv * cos(theta) + cr * sin(theta);
        }
        float sat = (1.0f + (2.0f * vs - 1.0f) * w) * (2.0f * ls) * (2.0f * ss);
        if (sat != 1.0f) {
            float y = dot(s.d.xyz, t);
            t = float3(y) + (t - float3(y)) * max(sat, 0.0f);
        }
        float g = exp2((vl - 0.5f) * 2.0f * w);
        if (g != 1.0f) { t *= g; }
        return pre ? map3(t, 2) : t;
    }

    // MARK: tone mapping

    float3 toneMap(float3 rgb, float knee) {
        float m = max(rgb.x, max(rgb.y, rgb.z));
        if (m <= knee) { return rgb; }
        float r = 1.0f - knee;
        float mapped = knee + r * (1.0f - exp(-(m - knee) / r));
        return rgb * (mapped / m);
    }

    // MARK: LUTs (CubeLUT.lookup)

    // vr bit 0: LUT_IN_VIDEO_RANGE, bit 1: LUT_OUT_VIDEO_RANGE (10-bit: 64…940 of 1023).
    float3 videoIn(float3 x, uint vr) { return (vr & 1u) ? x * 876.0f / 1023.0f + float3(64.0f / 1023.0f) : x; }
    float3 videoOut(float3 y, uint vr) { return (vr & 2u) ? (y - float3(64.0f / 1023.0f)) * 1023.0f / 876.0f : y; }

    float3 lookup3D(texture3d<float, access::read> t, uint n, float3 dmin, float3 dmax, float3 rgb, uint vr) {
        float3 tt = clamp((videoIn(rgb, vr) - dmin) / (dmax - dmin), 0.0f, 1.0f);
        float3 p = tt * float(n - 1);
        uint ir = min(uint(p.x), n - 2), ig = min(uint(p.y), n - 2), ib = min(uint(p.z), n - 2);
        float fr = p.x - float(ir), fg = p.y - float(ig), fb = p.z - float(ib);
        uint3 base = uint3(ir, ig, ib);
        float3 c000 = t.read(base).rgb;
        float3 c111 = t.read(base + uint3(1, 1, 1)).rgb;
        uint3 o1, o2;
        float w0, w1, w2;
        if (fr >= fg) {
            if (fg >= fb)      { o1 = uint3(1,0,0); o2 = uint3(1,1,0); w0 = fr; w1 = fg; w2 = fb; }
            else if (fr >= fb) { o1 = uint3(1,0,0); o2 = uint3(1,0,1); w0 = fr; w1 = fb; w2 = fg; }
            else               { o1 = uint3(0,0,1); o2 = uint3(1,0,1); w0 = fb; w1 = fr; w2 = fg; }
        } else {
            if (fb >= fg)      { o1 = uint3(0,0,1); o2 = uint3(0,1,1); w0 = fb; w1 = fg; w2 = fr; }
            else if (fb >= fr) { o1 = uint3(0,1,0); o2 = uint3(0,1,1); w0 = fg; w1 = fb; w2 = fr; }
            else               { o1 = uint3(0,1,0); o2 = uint3(1,1,0); w0 = fg; w1 = fr; w2 = fb; }
        }
        float3 p1 = t.read(base + o1).rgb, p2 = t.read(base + o2).rgb;
        return videoOut(c000 + w0 * (p1 - c000) + w1 * (p2 - p1) + w2 * (c111 - p2), vr);
    }

    float3 fetch1D(texture2d<float, access::read> t, uint i) {
        return t.read(uint2(i & 4095u, i >> 12)).rgb;
    }

    float3 lookup1D(texture2d<float, access::read> t, uint n, float3 dmin, float3 dmax, float3 rgb, uint vr) {
        float3 tt = clamp((videoIn(rgb, vr) - dmin) / (dmax - dmin), 0.0f, 1.0f);
        float3 p = tt * float(n - 1);
        float3 out;
        for (int ch = 0; ch < 3; ch++) {
            uint i0 = min(uint(p[ch]), n - 2);
            float f = p[ch] - float(i0);
            float a = fetch1D(t, i0)[ch], b = fetch1D(t, i0 + 1)[ch];
            out[ch] = a + (b - a) * f;
        }
        return videoOut(out, vr);
    }

    // MARK: chain (ColorPipeline.process)

    float3 lookupLUT(uint flags, uint size, float4 dmin, float4 dmax, float3 x,
                     texture3d<float, access::read> t3, texture2d<float, access::read> t1) {
        uint vr = (flags >> 2) & 3u;
        return (flags & kLut1D) ? lookup1D(t1, size, dmin.xyz, dmax.xyz, x, vr)
                                : lookup3D(t3, size, dmin.xyz, dmax.xyz, x, vr);
    }

    float3 processPixel(float3 px, constant ColorHeader &h, constant Sec *secs, constant float4 *curves,
                        texture3d<float, access::read> lut3, texture2d<float, access::read> lut1,
                        float2 uv, float aspect) {
        int src = int(h.ints.w);  // 0 S-Log3, 1 HLG, 2 Rec.709
        float3 c = h.ints.y == 0u ? map3(px, src) : px;
        for (uint i = 0; i < h.ints.x; i++) {
            constant Sec &s = secs[i];
            bool pre = s.head.y != 0u;
            switch (s.head.x) {
            case 0: {  // conversion
                if (s.head.z & kLutPresent) {
                    float3 e = map3(c, src + 3);
                    c = lookupLUT(s.head.z, s.head.w, s.a, s.b, e, lut3, lut1);
                } else {
                    float3 d = src == 2 ? c : s.m * c;
                    if (src != 2) { d = toneMap(d, s.c.x); }
                    c = map3(max(d, float3(0.0f)), 5);
                }
                break;
            }
            case 1: c = basicStage(c, s, pre); break;
            case 2: c = creativeStage(c, s, pre); break;
            case 3: {
                float3 t = pre ? map3(c, 5) : c;
                float3 graded = lookupLUT(s.head.z, s.head.w, s.a, s.b, t, lut3, lut1);
                float k = s.c.x;
                t = k >= 1.0f ? graded : t + (graded - t) * k;
                c = pre ? map3(t, 2) : t;
                break;
            }
            case 4: c = curvesStage(c, s, pre, curves); break;
            case 5: c = wheelsStage(c, s, pre); break;
            case 6: c = vignetteStage(c, s, pre, uv, aspect); break;
            case 7: c = hueCurvesStage(c, s, pre, curves); break;
            default: break;
            }
        }
        return h.ints.z == 3u ? map3(c, 2) : c;
    }

    kernel void colorChain(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           texture3d<float, access::read> lut3 [[texture(2)]],
                           texture2d<float, access::read> lut1 [[texture(3)]],
                           constant ColorHeader &h [[buffer(0)]],
                           constant Sec *secs [[buffer(1)]],
                           constant float4 *curves [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 px = src.read(gid);
        float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
        float aspect = float(dst.get_width()) / float(dst.get_height());
        if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
        dst.write(float4(processPixel(px.rgb, h, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
    }

    kernel void colorChainInPlace(texture2d<float, access::read_write> img [[texture(0)]],
                                  texture3d<float, access::read> lut3 [[texture(2)]],
                                  texture2d<float, access::read> lut1 [[texture(3)]],
                                  constant ColorHeader &h [[buffer(0)]],
                                  constant Sec *secs [[buffer(1)]],
                                  constant float4 *curves [[buffer(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= img.get_width() || gid.y >= img.get_height()) { return; }
        float4 px = img.read(gid);
        float2 uv = (float2(gid) + 0.5f) / float2(img.get_width(), img.get_height());
        float aspect = float(img.get_width()) / float(img.get_height());
        if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
        img.write(float4(processPixel(px.rgb, h, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
    }
    """#
}
