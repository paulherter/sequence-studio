/// MSL source of the colour chain. Mirrors `ColorPipeline.process` 1:1 (same constants, order, clamps).
///
/// Embedded as a string (not a `.metal` file): SwiftPM without Package.swift resources neither compiles nor bundles
/// `.metal` files (`swift test` warns "unhandled file" and `Bundle.module` does not exist). Compiled at runtime with
/// `MTLCompileOptions.mathMode = .safe` by `ColorPipelineGPU`.
enum ColorShaderSource {
    static let msl = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ColorUniforms {
        float3x3 wb;
        float3x3 toRec709;
        float4 luma;
        float4 convMin, convMax, creMin, creMax;
        float4 tone;   // exposureScale, contrastScale, highlights, shadows
        float4 misc;   // saturation, knee, creativeIntensity, unused
        uint4 ints;    // flags, source, convSize, creSize
    };

    constant uint kWB = 1, kExposure = 2, kTone = 4, kSat = 8, kConv = 16, kConv1D = 32,
                  kCreative = 64, kCreative1D = 128, kHDR = 256,
                  kConvIn = 512, kConvOut = 1024, kCreIn = 2048, kCreOut = 4096;
    constant float kMinLuma = 1.0f / 65536.0f;

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

    // MARK: correction (PreparedCorrection.apply)

    float smooth3(float x) {
        float t = min(max(x / 3.0f, 0.0f), 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    float3 applyCorrection(float3 c, constant ColorUniforms &u) {
        uint f = u.ints.x;
        if (f & kWB) { c = u.wb * c; }
        if (f & kExposure) { c *= u.tone.x; }
        if (f & kTone) {
            float y = dot(u.luma.xyz, c);
            float yc = max(y, kMinLuma);
            float l = log2(yc / 0.18f);
            l *= u.tone.y;
            l += u.tone.z * smooth3(l);
            l += u.tone.w * smooth3(-l);
            c *= 0.18f * exp2(l) / yc;
        }
        if (f & kSat) {
            float y = dot(u.luma.xyz, c);
            if (y > kMinLuma) {
                float3 r = max(c, float3(kMinLuma)) / y;
                c = y * float3(pow(r.x, u.misc.x), pow(r.y, u.misc.x), pow(r.z, u.misc.x));
            }
        }
        return c;
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

    float3 processPixel(float3 enc, constant ColorUniforms &u,
                        texture3d<float, access::read> conv3, texture2d<float, access::read> conv1,
                        texture3d<float, access::read> cre3, texture2d<float, access::read> cre1) {
        uint f = u.ints.x;
        uint convVR = ((f & kConvIn) ? 1u : 0u) | ((f & kConvOut) ? 2u : 0u);
        uint creVR = ((f & kCreIn) ? 1u : 0u) | ((f & kCreOut) ? 2u : 0u);
        int src = int(u.ints.y);  // 0 S-Log3, 1 HLG, 2 Rec.709
        float3 linear = applyCorrection(map3(enc, src), u);
        float3 display;
        if (f & kConv) {
            float3 e = map3(linear, src + 3);
            display = (f & kConv1D) ? lookup1D(conv1, u.ints.z, u.convMin.xyz, u.convMax.xyz, e, convVR)
                                    : lookup3D(conv3, u.ints.z, u.convMin.xyz, u.convMax.xyz, e, convVR);
        } else {
            float3 c = src == 2 ? linear : u.toRec709 * linear;
            if (f & kHDR) { c = toneMap(c, u.misc.y); }
            display = map3(max(c, float3(0.0f)), 5);
        }
        if (f & kCreative) {
            float3 graded = (f & kCreative1D) ? lookup1D(cre1, u.ints.w, u.creMin.xyz, u.creMax.xyz, display, creVR)
                                              : lookup3D(cre3, u.ints.w, u.creMin.xyz, u.creMax.xyz, display, creVR);
            float k = u.misc.z;
            display = k >= 1.0f ? graded : display + (graded - display) * k;
        }
        return map3(display, 2);
    }

    kernel void colorChain(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           texture3d<float, access::read> conv3 [[texture(2)]],
                           texture2d<float, access::read> conv1 [[texture(3)]],
                           texture3d<float, access::read> cre3 [[texture(4)]],
                           texture2d<float, access::read> cre1 [[texture(5)]],
                           constant ColorUniforms &u [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float4 px = src.read(gid);
        dst.write(float4(processPixel(px.rgb, u, conv3, conv1, cre3, cre1), px.a), gid);
    }

    kernel void colorChainInPlace(texture2d<float, access::read_write> img [[texture(0)]],
                                  texture3d<float, access::read> conv3 [[texture(2)]],
                                  texture2d<float, access::read> conv1 [[texture(3)]],
                                  texture3d<float, access::read> cre3 [[texture(4)]],
                                  texture2d<float, access::read> cre1 [[texture(5)]],
                                  constant ColorUniforms &u [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= img.get_width() || gid.y >= img.get_height()) { return; }
        float4 px = img.read(gid);
        img.write(float4(processPixel(px.rgb, u, conv3, conv1, cre3, cre1), px.a), gid);
    }
    """#
}
