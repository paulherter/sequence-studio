/// MSL source of the color chain. Mirrors `ColorPipeline.process` 1:1 (same constants, order, clamps).
///
/// Embedded as a string (not a `.metal` file): SwiftPM without Package.swift resources neither compiles nor bundles
/// `.metal` files (`swift test` warns "unhandled file" and `Bundle.module` does not exist). Compiled at runtime with
/// `MTLCompileOptions.mathMode = .safe` by `ColorPipelineGPU`.
enum ColorShaderSource {
    static let msl = mslHead + "\n" + transferMSL + "\n" + mslTail

    static let mslHead = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ColorHeader {
        uint4 ints;   // section count, start domain (0 source-encoded, 1 source-linear, 2 display), end domain (1, 2, 3 = working-linear), source (SourceColorSpace case order: 0 S-Log3, 1 HLG, 2 Rec.709, 3 V-Log, 4 Apple Log, 5 PQ, 6 D-Log, 7 Canon Log, 8 Canon Log 2, 9 Canon Log 3)
        uint4 extra;  // x != 0: the texture is a quarter-turned picture (vignette geometry follows the upright picture); yz: dispatch origin
    };

    // One block of the chain (layout mirrors ColorPipelineGPU.Sec).
    struct Sec {
        uint4 head;   // kind, pre, flags, extra
        float4 a, b, c, d;
        float3x3 m;
    };

    constant uint kConversion = 0, kBasic = 1, kCreative = 2, kLook = 3, kCurves = 4, kWheels = 5, kVignette = 6, kHueCurves = 7, kHSLSecondary = 8;
    constant uint kLutPresent = 1, kLut1D = 2, kLutIn = 4, kLutOut = 8, kLutTrilinear = 16;
    constant float kMinLuma = 1.0f / 65536.0f;
    constant uint kCurveCount = 64;

    """#

    static let mslTail = #"""

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

    // Lumetri tone model (BasicToneCurves.swift), one channel each.
    float lumExposure(float l, float g, float knee) {
        float m = l * g;
        if (m <= knee) { return m; }
        float a = (g - 1.0f) / (1.0f - knee);
        float u = (m - knee) / (g - knee);
        if (u <= 1.0f) { return knee + (1.0f - knee) * u * (1.0f + a) / (1.0f + a * u); }
        return 1.0f + (m - g);
    }
    float lumBias(float u, float k) { return u / (k * (1.0f - u) + 1.0f); }
    float lumContrast(float x, float k, float p) {
        if (x < 0.0f) { return x / (1.0f + k); }
        if (x > 1.0f) { return 1.0f + (x - 1.0f) / (1.0f + k); }
        if (x <= p) { return p * lumBias(x / p, k); }
        return 1.0f - (1.0f - p) * lumBias((1.0f - x) / (1.0f - p), k);
    }
    float lumTone(float x, constant Sec &s, uint f) {
        float t = x;
        if (f & 4u) { t = lumContrast(t, s.a.y, s.d.x); }
        if ((f & 64u) && t > 0.0f && t < 1.0f) { t = t + s.a.z * 6.75f * t * t * (1.0f - t); }
        if ((f & 8u) && t > 0.0f && t < 1.0f) { t = t + s.a.w * 6.75f * t * (1.0f - t) * (1.0f - t); }
        if (f & 16u) {
            t *= s.b.y;
            float d = s.b.x;
            if (t < 0.0f) { t = d + t * (1.0f - 2.0f * d); }
            else if (t < 1.0f) { t = t + d * (1.0f - t) * (1.0f - t); }
        }
        return t;
    }

    // flags: 1 WB, 2 exposure, 4 contrast, 8 shadows, 16 levels, 32 saturation/vibrance, 64 highlights;
    // head.w: 0 legacy tone model, 1 Lumetri tone model
    // `f` and `lum` are the block's structure (s.head.z, s.head.w == 1): uniforms in the generic chain, literals in a
    // specialised kernel (ColorKernelSource), so the compiler drops the unused branches.
    float3 basicStageF(float3 c, constant Sec &s, bool pre, uint f, bool lum) {
        float3 x = c;
        if ((f & 3u) != 0u) {
            float3 lin = pre ? x : map3(x, 2);
            if (f & 1u) { lin = s.m * lin; }
            if (f & 2u) {
                if (lum && s.c.w > 0.5f) {
                    lin = float3(lumExposure(lin.x, s.a.x, s.d.y), lumExposure(lin.y, s.a.x, s.d.y), lumExposure(lin.z, s.a.x, s.d.y));
                } else {
                    lin *= s.a.x;
                }
            }
            x = pre ? lin : map3(lin, 12);
        }
        if ((f & 124u) != 0u && lum) {
            float3 t = pre ? map3(x, 12) : x;
            t = float3(lumTone(t.x, s, f), lumTone(t.y, s, f), lumTone(t.z, s, f));
            t = satVib(t, s.b.z, s.b.w, s.c.xyz);
            x = pre ? map3(t, 2) : t;
        } else if ((f & 124u) != 0u) {
            float3 t = pre ? map3(x, 12) : x;
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
    float3 basicStage(float3 c, constant Sec &s, bool pre) { return basicStageF(c, s, pre, s.head.z, s.head.w == 1u); }

    float3 creativeStageF(float3 c, constant Sec &s, bool pre, bool tint) {
        float3 t = pre ? map3(c, 12) : c;
        float fade = s.a.x;
        if (fade != 0.0f) { t = t * (1.0f - fade) + float3(fade * 0.85f); }
        if (tint) {
            float bal = s.a.w;
            float y = dot(s.d.xyz, t);
            float ms = 1.0f - smoothS(0.15f + 0.25f * bal, 0.65f + 0.25f * bal, y);
            float mh = smoothS(0.35f + 0.25f * bal, 0.85f + 0.25f * bal, y);
            t += ms * s.b.xyz + mh * s.c.xyz;
        }
        t = satVib(t, s.a.y, s.a.z, s.d.xyz);
        return pre ? map3(t, 2) : t;
    }
    float3 creativeStage(float3 c, constant Sec &s, bool pre) { return creativeStageF(c, s, pre, (s.head.z & 1u) != 0u); }

    float3 wheelsStageF(float3 c, constant Sec &s, bool pre, bool gamma) {
        float3 t = pre ? map3(c, 12) : c;
        t += (1.0f - smoothS(0.0f, 0.5f, dot(s.d.xyz, t))) * s.a.xyz;
        if (gamma) {
            float y = dot(s.d.xyz, t);
            float wm = smoothS(0.0f, 0.5f, y) * (1.0f - smoothS(0.5f, 1.0f, y));
            float3 p = float3(pow(max(t.x, 0.0f), s.b.x), pow(max(t.y, 0.0f), s.b.y), pow(max(t.z, 0.0f), s.b.z));
            t += (p - t) * wm;
        }
        t *= float3(1.0f) + smoothS(0.35f, 1.15f, dot(s.d.xyz, t)) * s.c.xyz;
        t = satVib(t, s.a.w, 0.0f, s.d.xyz);
        return pre ? map3(t, 2) : t;
    }
    float3 wheelsStage(float3 c, constant Sec &s, bool pre) { return wheelsStageF(c, s, pre, (s.head.z & 1u) != 0u); }

    float3 vignetteStage(float3 c, constant Sec &s, bool pre, float2 uv, float aspect) {
        float px = (uv.x - 0.5f) * 2.0f * (1.0f + (aspect - 1.0f) * s.b.x), py = (uv.y - 0.5f) * 2.0f;
        float n = s.a.w;
        float e = n > 2.0001f ? pow(pow(fabs(px), n) + pow(fabs(py), n), 1.0f / n) : sqrt(px * px + py * py);
        float m = smoothS(s.a.y, s.a.y + s.a.z, e);
        return pre ? c * exp2(s.a.x * m) : c * exp2(0.45f * s.a.x * m);
    }

    float3 curvesStage(float3 c, constant Sec &s, bool pre, constant float4 *table) {
        float3 t = pre ? map3(c, 12) : c;
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
        float3 t = pre ? map3(c, 12) : c;
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

    // Color Range (PreparedHSLSecondary).
    float hslMask(float3 t, constant Sec &s) {
        if (s.head.w == 1u) {
            float mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z));
            float d = mx - mn;
            float sv = mx > 1e-4f ? clamp(d / mx, 0.0f, 1.0f) : 0.0f;
            float hue = 0.0f;
            if (d > 1e-6f) {
                float h;
                if (mx == t.x) { h = (t.y - t.z) / d; } else if (mx == t.y) { h = (t.z - t.x) / d + 2.0f; } else { h = (t.x - t.y) / d + 4.0f; }
                h /= 6.0f;
                hue = h - floor(h);
            }
            float ang = hue * 6.2831853f;
            float3 p = float3(sv * cos(ang), sv * sin(ang), dot(s.d.xyz, t));
            float vm = 1.0f - smoothS(s.a.w, s.a.w + s.b.x, length(p - s.a.xyz));
            return s.b.w > 0.5f ? 1.0f - vm : vm;
        }
        float mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z));
        float d = mx - mn;
        float wh = 1.0f;
        if (s.a.w < 0.5f) {
            float hue = 0.0f;
            if (d > 1e-6f) {
                float h;
                if (mx == t.x) { h = (t.y - t.z) / d; } else if (mx == t.y) { h = (t.z - t.x) / d + 2.0f; } else { h = (t.x - t.y) / d + 4.0f; }
                h /= 6.0f;
                hue = h - floor(h);
            }
            float dh = hue - s.a.x;
            dh -= floor(dh + 0.5f);
            wh = (1.0f - smoothS(s.a.y, s.a.y + s.a.z, fabs(dh))) * smoothS(0.005f, 0.05f, d);
        }
        float sv = mx > 1e-4f ? clamp(d / mx, 0.0f, 1.0f) : 0.0f;
        float ws = smoothS(s.b.x - s.b.z, s.b.x, sv) * (1.0f - smoothS(s.b.y, s.b.y + s.b.z, sv));
        float y = dot(s.d.xyz, t);
        float wl = (s.c.x > 0.0f ? smoothS(s.c.x - s.c.z, s.c.x, y) : 1.0f) * (s.c.y < 1.0f ? 1.0f - smoothS(s.c.y, s.c.y + s.c.z, y) : 1.0f);
        float m = wh * ws * wl;
        return s.b.w > 0.5f ? 1.0f - m : m;
    }
    float3 hslSecondaryStage(float3 c, constant Sec &s, bool pre) {
        float3 t = pre ? map3(c, 12) : c;
        float w = hslMask(t, s);
        if (!(w > 0.0f)) { return c; }
        float3 o = t * float3(s.m[0][0], s.m[1][1], s.m[2][2]);
        float theta = s.d.w;
        if (theta != 0.0f) {
            float m = (o.x + o.y + o.z) / 3.0f;
            float3 dv = o - float3(m);
            float3 cr = float3(dv.z - dv.y, dv.x - dv.z, dv.y - dv.x) * 0.57735027f;
            o = float3(m) + dv * cos(theta) + cr * sin(theta);
        }
        if (s.c.w != 1.0f) {
            float y = dot(s.d.xyz, o);
            o = float3(y) + (o - float3(y)) * s.c.w;
        }
        float3 r = t + (o - t) * w;
        return pre ? map3(r, 2) : r;
    }

    // Zone Board (PreparedZoneBoard.apply).
    float3 zoneBoardStage(float3 c, constant Sec &s, bool pre) {
        float3 t = pre ? map3(c, 12) : c;
        float3 lum = float3(s.m[1][1], s.m[1][2], s.m[2][0]);
        float y = dot(lum, t);
        float sh = 1.0f - smoothS(0.0f, 0.5f, y);
        float mid = smoothS(0.0f, 0.5f, y) * (1.0f - smoothS(0.5f, 1.0f, y));
        float hi = smoothS(0.35f, 1.15f, y);
        float4 w = float4(1.0f, sh, mid, hi);
        float gains[4] = { s.m[0][0], s.m[0][1], s.m[0][2], s.m[1][0] };
        float4 sats = float4(s.a.w, s.b.w, s.c.w, s.d.w);
        float3 offs[4] = { s.a.xyz, s.b.xyz, s.c.xyz, s.d.xyz };
        float gain = 1.0f, sat = 1.0f;
        float3 off = float3(0.0f);
        for (int z = 0; z < 4; z++) {
            gain *= 1.0f + w[z] * (gains[z] - 1.0f);
            sat += w[z] * (sats[z] - 1.0f);
            off += w[z] * offs[z];
        }
        t = t * gain + off;
        if (sat != 1.0f) {
            float ty = dot(lum, t);
            t = float3(ty) + (t - float3(ty)) * max(sat, 0.0f);
        }
        return pre ? map3(t, 2) : t;
    }

    // Pro grade Step primaries (PreparedPrimaries.apply). flags: 1 gamma, 2 contrast, 4 saturation.
    float3 primariesStage(float3 c, constant Sec &s, bool pre, uint flags) {
        float3 t = pre ? map3(c, 12) : c;
        t = t + s.a.xyz * (float3(1.0f) - t);
        t = t * s.c.xyz + s.d.xyz;
        if (flags & 1u) {
            for (int ch = 0; ch < 3; ch++) {
                if (t[ch] > 0.0f && s.b[ch] != 1.0f) { t[ch] = pow(t[ch], s.b[ch]); }
            }
        }
        if (flags & 2u) { t = (t - float3(s.b.w)) * s.a.w + float3(s.b.w); }
        if (flags & 4u) {
            float y = dot(float3(0.2126f, 0.7152f, 0.0722f), t);
            t = float3(y) + (t - float3(y)) * s.c.w;
        }
        return pre ? map3(t, 2) : t;
    }

    // Step window (PreparedWindow.mask). m columns: (cx, cy, half x), (half y, cos, sin), (soft, shape, invert).
    float stepWindowMask(constant Sec &s, float2 uv, float aspect) {
        float3 r0 = s.m[0], r1 = s.m[1], r2 = s.m[2];
        float px = (uv.x - r0.x) * aspect, py = uv.y - r0.y;
        float qx = px * r1.y + py * r1.z, qy = -px * r1.z + py * r1.y;
        float hx = max(r0.z * aspect, 1e-5f), hy = max(r1.x, 1e-5f);
        float soft = r2.x;
        float m;
        if (r2.y < 0.5f) {
            float ex = qx / hx, ey = qy / hy;
            m = 1.0f - smoothS(1.0f - soft, 1.0f, sqrt(ex * ex + ey * ey));
        } else if (r2.y < 1.5f) {
            m = 1.0f - smoothS(1.0f - soft, 1.0f, max(fabs(qx) / hx, fabs(qy) / hy));
        } else {
            float e = max(soft * hy, 1e-4f);
            m = 1.0f - smoothS(-e, e, qy);
        }
        return r2.z > 0.5f ? 1.0f - m : m;
    }

    // End of a limited Step (PreparedStepMatte.apply): the Step's result over its input `n0`. flags: 1 qualifier, 2 window.
    // flags also: 4 mix below 1 (s.d.w), 8 layer branch (branchEndStage).
    float stepMatte(float3 n0, constant Sec &s, bool pre, uint flags, float2 uv, float aspect) {
        float m = 1.0f;
        if (flags & 1u) { m = hslMask(pre ? map3(n0, 12) : n0, s); }
        if (flags & 2u) { m *= stepWindowMask(s, uv, aspect); }
        if (flags & 4u) { m *= s.d.w; }
        return m;
    }
    // km: the key register (1 when the end has no key terms before it, flag 16).
    float3 stepEndStage(float3 c, float3 n0, constant Sec &s, bool pre, uint flags, float2 uv, float aspect, float km) {
        float m = stepMatte(n0, s, pre, flags, uv, aspect) * km;
        return n0 + (c - n0) * m;
    }
    // End of a branch of a column with Parallel / Layer Steps (ColorOp.branchEnd): adds the keyed result over the column
    // input `g0` to `acc` (parallel) or lays it over `acc` (layer, flag 8).
    // A layer composites by the Layer mix in flags bits 5...7 (PreparedStepMatte.composite).
    float3 layerComposite(float3 acc, float3 c, uint mode) {
        switch (mode) {
        case 1: return acc + c;
        case 2: return acc - c;
        case 3: return acc * c;
        case 4: return float3(1.0f) - (float3(1.0f) - acc) * (float3(1.0f) - c);
        case 5: return max(acc, c);
        case 6: return min(acc, c);
        default: return c;
        }
    }
    void branchEndStage(float3 c, float3 g0, thread float3 &acc, constant Sec &s, bool pre, uint flags, float2 uv, float aspect, float km) {
        float m = stepMatte(g0, s, pre, flags, uv, aspect) * km;
        if (flags & 8u) { acc = acc + (layerComposite(acc, c, (flags >> 5) & 7u) - acc) * m; } else { acc += g0 + (c - g0) * m; }
    }
    // One key wire (PreparedKeyTerm.apply): flags 1 qualifier, 2 window, 4 outside, bits 5...7 mode (0 set, 1 add, 2 multiply,
    // 3 subtract, 4 max) combining it with the key register `km`. Evaluated on the receiving Step's input `n0`.
    float keyTermStage(float3 n0, constant Sec &s, bool pre, uint flags, float2 uv, float aspect, float km) {
        float m = 1.0f;
        if (flags & 1u) { m = hslMask(pre ? map3(n0, 12) : n0, s); }
        if (flags & 2u) { m *= stepWindowMask(s, uv, aspect); }
        if (flags & 4u) { m = 1.0f - m; }
        switch ((flags >> 5) & 7u) {
        case 1: return min(km + m, 1.0f);
        case 2: return km * m;
        case 3: return max(km - m, 0.0f);
        case 4: return max(km, m);
        default: return m;
        }
    }

    // MARK: tone mapping

    // ToneMapping.mapMax(_:peak:): peak <= knee (0) = exponential roll-off, else extended Reinhard reaching 1 at peak.
    float3 toneMap(float3 rgb, float knee, float peak) {
        float m = max(rgb.x, max(rgb.y, rgb.z));
        if (m <= knee) { return rgb; }
        float r = 1.0f - knee;
        float mapped;
        if (peak > knee + 1e-4f) {
            if (m >= peak) { mapped = 1.0f; }
            else {
                float w = (peak - knee) / r;
                float x = (m - knee) / r;
                mapped = knee + r * (x * (1.0f + x / (w * w)) / (1.0f + x));
            }
        } else {
            mapped = knee + r * (1.0f - exp(-(m - knee) / r));
        }
        return rgb * (mapped / m);
    }

    // SoftGamutCompression.compress, then the export exposure gain (ToneMapping.trim).
    float3 hdrTrim(float3 rgb, float gain, float compress) {
        float m = max(rgb.x, max(rgb.y, rgb.z));
        if (compress > 0.5f && m > 0.0f) {
            for (int i = 0; i < 3; i++) {
                if (rgb[i] < m) {
                    float d = (m - rgb[i]) / m;
                    if (d > 0.9f) {
                        float x = (d - 0.9f) / 0.1f;
                        float l = (1.5f - 0.9f) / 0.1f;
                        d = 0.9f + 0.1f * (x * (1.0f + x / (l * l)) / (1.0f + x));
                    }
                    rgb[i] = m - d * m;
                }
            }
        }
        return rgb * gain;
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
        if (vr & 4u) {
            float3 x00 = mix(t.read(base).rgb, t.read(base + uint3(1,0,0)).rgb, fr);
            float3 x10 = mix(t.read(base + uint3(0,1,0)).rgb, t.read(base + uint3(1,1,0)).rgb, fr);
            float3 x01 = mix(t.read(base + uint3(0,0,1)).rgb, t.read(base + uint3(1,0,1)).rgb, fr);
            float3 x11 = mix(t.read(base + uint3(0,1,1)).rgb, t.read(base + uint3(1,1,1)).rgb, fr);
            return videoOut(mix(mix(x00, x10, fg), mix(x01, x11, fg), fb), vr);
        }
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
        uint vr = ((flags >> 2) & 3u) | ((flags & kLutTrilinear) ? 4u : 0u);   // bit 2: trilinear
        return (flags & kLut1D) ? lookup1D(t1, size, dmin.xyz, dmax.xyz, x, vr)
                                : lookup3D(t3, size, dmin.xyz, dmax.xyz, x, vr);
    }

    // The conversion block (`src`: SourceColorSpace index, `flags`: s.head.z).
    float3 conversionStage(float3 c, constant Sec &s, int src, uint flags,
                           texture3d<float, access::read> lut3, texture2d<float, access::read> lut1) {
        if (flags & kLutPresent) {
            float3 e = map3(c, src + 10);
            return lookupLUT(flags, s.head.w, s.a, s.b, e, lut3, lut1);
        }
        float3 d = src == 2 ? c : s.m * c;
        if (src != 2 && s.c.w > -0.5f) { d = toneMap(hdrTrim(d, s.c.z, s.c.w), s.c.x, s.c.y); }
        return map3(max(d, float3(0.0f)), 12);
    }

    float3 lookStage(float3 c, constant Sec &s, bool pre, uint flags,
                     texture3d<float, access::read> lut3, texture2d<float, access::read> lut1) {
        float3 t = pre ? map3(c, 12) : c;
        float3 graded = lookupLUT(flags, s.head.w, s.a, s.b, t, lut3, lut1);
        float k = s.c.x;
        t = k >= 1.0f ? graded : t + (graded - t) * k;
        return pre ? map3(t, 2) : t;
    }

    float3 processPixel(float3 px, constant ColorHeader &h, constant Sec *secs, constant float4 *curves,
                        texture3d<float, access::read> lut3, texture2d<float, access::read> lut1,
                        float2 uv, float aspect) {
        int src = int(h.ints.w);  // SourceColorSpace case order (2 = Rec.709)
        float3 c = h.ints.y == 0u ? map3(px, src) : px;
        float3 n0 = c;
        float3 acc = float3(0.0f);
        float km = 1.0f;
        for (uint i = 0; i < h.ints.x; i++) {
            constant Sec &s = secs[i];
            bool pre = s.head.y != 0u;
            switch (s.head.x) {
            case 0: c = conversionStage(c, s, src, s.head.z, lut3, lut1); break;
            case 1: c = basicStage(c, s, pre); break;
            case 2: c = creativeStage(c, s, pre); break;
            case 3: c = lookStage(c, s, pre, s.head.z, lut3, lut1); break;
            case 4: c = curvesStage(c, s, pre, curves); break;
            case 5: c = wheelsStage(c, s, pre); break;
            case 6: c = vignetteStage(c, s, pre, uv, aspect); break;
            case 7: c = hueCurvesStage(c, s, pre, curves); break;
            case 8: c = hslSecondaryStage(c, s, pre); break;
            case 9: c = primariesStage(c, s, pre, s.head.z); break;
            case 10: n0 = c; break;
            case 11: c = stepEndStage(c, n0, s, pre, s.head.z, uv, aspect, (s.head.z & 16u) != 0u ? km : 1.0f); if (s.head.z & 16u) { km = 1.0f; } break;
            case 12: n0 = c; acc = float3(0.0f); break;
            case 13: branchEndStage(c, n0, acc, s, pre, s.head.z, uv, aspect, (s.head.z & 16u) != 0u ? km : 1.0f); if (s.head.z & 16u) { km = 1.0f; } c = n0; break;
            case 14: acc = s.head.z != 0u ? n0 : acc * s.a.x; break;
            case 15: c = acc; break;
            case 16: km = keyTermStage(n0, s, pre, s.head.z, uv, aspect, km); break;
            case 18: c = zoneBoardStage(c, s, pre); break;
            case 17: acc = n0 + (acc - n0) * km; km = 1.0f; break;
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
                           uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + h.extra.yz;   // origin of the dispatched region (the whole texture: 0)
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
                                  uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + h.extra.yz;   // origin of the dispatched region (the whole texture: 0)
        if (gid.x >= img.get_width() || gid.y >= img.get_height()) { return; }
        float4 px = img.read(gid);
        float2 uv = (float2(gid) + 0.5f) / float2(img.get_width(), img.get_height());
        float aspect = float(img.get_width()) / float(img.get_height());
        if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
        img.write(float4(processPixel(px.rgb, h, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
    }
    """#

    /// What an `rgba16Float` texture store followed by a read gives back for one channel, as a float: Apple GPUs round
    /// toward zero and saturate finite values to +-65504 (infinity and NaN stay; not round-to-nearest like `half(x)`). Lets a fused kernel keep the exact value
    /// the old intermediate texture held (`GradeFusionTests.storeHalfMatchesTextureStore`).
    static let storeHalfMSL = #"""
    float storeHalf1(float v) {
        if (isnan(v) || isinf(v)) { return v; }
        float a = fabs(v), r;
        if (a >= 65504.0f) { r = 65504.0f; }
        else if (a >= 6.103515625e-05f) { r = as_type<float>(as_type<uint>(a) & 0xFFFFE000u); }   // 10 mantissa bits, truncated
        else { r = floor(a * 16777216.0f) * 5.9604644775390625e-08f; }                           // half subnormal: n x 2^-24
        return copysign(r, v);
    }
    float4 storeHalf(float4 v) { return float4(storeHalf1(v.x), storeHalf1(v.y), storeHalf1(v.z), storeHalf1(v.w)); }
    """#

    /// The source transfer functions and `map3` (decode 0…9 and 20…26, encode +10; the index is `ColorPipelineGPU.shaderIndex`), shared with
    /// `CompositorShaderSource` (half-size light average in `convertToRGB`).
    static let transferMSL = #"""
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

    // V-Log, D-Log: CV/1023 code fractions like S-Log3. Apple Log, PQ: the range-expanded value is the signal.
    constant float kVlogB = 0.00873f, kVlogC = 0.241514f, kVlogD = 0.598206f;
    float vlogDecode(float x) { return x < 0.181f ? (x - 0.125f) / 5.6f : pow(10.0f, (x - kVlogD) / kVlogC) - kVlogB; }
    float vlogEncode(float y) { return y < 0.01f ? 5.6f * y + 0.125f : kVlogC * log10(y + kVlogB) + kVlogD; }
    float vlogDecodeLegal(float v) { return vlogDecode((v * 876.0f + 64.0f) / 1023.0f); }
    float vlogEncodeLegal(float y) { return (vlogEncode(y) * 1023.0f - 64.0f) / 876.0f; }

    float dlogDecode(float x) { return x <= 0.14f ? (x - 0.0929f) / 6.025f : (pow(10.0f, 3.89616f * x - 2.27752f) - 0.0108f) / 0.9892f; }
    float dlogEncode(float y) { return y <= 0.0078f ? 6.025f * y + 0.0929f : log10(y * 0.9892f + 0.0108f) * 0.256663f + 0.584555f; }
    float dlogDecodeLegal(float v) { return dlogDecode((v * 876.0f + 64.0f) / 1023.0f); }
    float dlogEncodeLegal(float y) { return (dlogEncode(y) * 1023.0f - 64.0f) / 876.0f; }

    // Canon Log, Canon Log 2, Canon Log 3 (TransferFunctions.canonLog*): CV/1023 code fractions, linear = reflection / 0.9.
    float canonMirroredDecode(float x, float a, float k, float c) {
        return (x < c ? -(pow(10.0f, (c - x) / a) - 1.0f) / k : (pow(10.0f, (x - c) / a) - 1.0f) / k) * 0.9f;
    }
    float canonMirroredEncode(float y, float a, float k, float c) {
        float l = y / 0.9f;
        return l < 0.0f ? -(a * log10(-l * k + 1.0f) - c) : a * log10(l * k + 1.0f) + c;
    }
    float canonLogDecodeLegal(float v) { return canonMirroredDecode((v * 876.0f + 64.0f) / 1023.0f, 0.45310179f, 10.1596f, 0.12512248f); }
    float canonLogEncodeLegal(float y) { return (canonMirroredEncode(y, 0.45310179f, 10.1596f, 0.12512248f) * 1023.0f - 64.0f) / 876.0f; }
    float canonLog2DecodeLegal(float v) { return canonMirroredDecode((v * 876.0f + 64.0f) / 1023.0f, 0.24136077f, 87.09937546f, 0.092864125f); }
    float canonLog2EncodeLegal(float y) { return (canonMirroredEncode(y, 0.24136077f, 87.09937546f, 0.092864125f) * 1023.0f - 64.0f) / 876.0f; }
    constant float kCanon3A = 0.36726845f, kCanon3K = 14.98325f;
    float canonLog3Decode(float x) {
        float l;
        if (x < 0.097465473f) { l = -(pow(10.0f, (0.12783901f - x) / kCanon3A) - 1.0f) / kCanon3K; }
        else if (x <= 0.15277891f) { l = (x - 0.12512219f) / 1.9754798f; }
        else { l = (pow(10.0f, (x - 0.12240537f) / kCanon3A) - 1.0f) / kCanon3K; }
        return l * 0.9f;
    }
    float canonLog3Encode(float y) {
        float l = y / 0.9f;
        if (l < -0.014f) { return -kCanon3A * log10(-l * kCanon3K + 1.0f) + 0.12783901f; }
        if (l <= 0.014f) { return 1.9754798f * l + 0.12512219f; }
        return kCanon3A * log10(l * kCanon3K + 1.0f) + 0.12240537f;
    }
    float canonLog3DecodeLegal(float v) { return canonLog3Decode((v * 876.0f + 64.0f) / 1023.0f); }
    float canonLog3EncodeLegal(float y) { return (canonLog3Encode(y) * 1023.0f - 64.0f) / 876.0f; }

    constant float kAppleR0 = -0.05641088f, kAppleRt = 0.01f, kAppleC = 47.28711236f;
    constant float kAppleBeta = 0.00964052f, kAppleGamma = 0.08550479f, kAppleDelta = 0.69336945f;
    float appleLogDecode(float p) {
        float pt = kAppleC * (kAppleRt - kAppleR0) * (kAppleRt - kAppleR0);
        if (p >= pt) { return pow(2.0f, (p - kAppleDelta) / kAppleGamma) - kAppleBeta; }
        if (p >= 0.0f) { return sqrt(p / kAppleC) + kAppleR0; }
        return kAppleR0;
    }
    float appleLogEncode(float x) {
        if (x >= kAppleRt) { return kAppleGamma * log2(x + kAppleBeta) + kAppleDelta; }
        if (x >= kAppleR0) { return kAppleC * (x - kAppleR0) * (x - kAppleR0); }
        return 0.0f;
    }

    constant float kPqM1 = 2610.0f / 16384.0f, kPqM2 = 2523.0f / 4096.0f * 128.0f;
    constant float kPqC1 = 3424.0f / 4096.0f, kPqC2 = 2413.0f / 4096.0f * 32.0f, kPqC3 = 2392.0f / 4096.0f * 32.0f;
    constant float kPqRefWhite = 203.0f;
    float pqDecode(float e) {
        float p = pow(max(e, 0.0f), 1.0f / kPqM2);
        float y = pow(max(p - kPqC1, 0.0f) / (kPqC2 - kPqC3 * p), 1.0f / kPqM1);
        return y * 10000.0f / kPqRefWhite;
    }
    float pqEncode(float l) {
        float y = pow(max(l, 0.0f) * kPqRefWhite / 10000.0f, kPqM1);
        return pow((kPqC1 + kPqC2 * y) / (1.0f + kPqC3 * y), kPqM2);
    }

    // Vendor logs (TransferFunctions+Vendor.swift): ARRI LogC3 / LogC4, RED Log3G10, Blackmagic Film Gen 5, Nikon N-Log,
    // Fujifilm F-Log2, ACEScct. The LogC4 constants are derived in Swift (Double) and pasted here.
    float legalToCode(float v) { return (v * 876.0f + 64.0f) / 1023.0f; }
    float codeToLegal(float x) { return (x * 1023.0f - 64.0f) / 876.0f; }
    float logC3Decode(float x) { return x > 5.367655f * 0.010591f + 0.092809f ? (pow(10.0f, (x - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f : (x - 0.092809f) / 5.367655f; }
    float logC3Encode(float y) { return y > 0.010591f ? 0.247190f * log10(5.555556f * y + 0.052272f) + 0.385537f : 5.367655f * y + 0.092809f; }
    constant float kC4A = \#(Float(TransferFunctions.logC4A))f, kC4B = \#(Float(TransferFunctions.logC4B))f, kC4C = \#(Float(TransferFunctions.logC4C))f;
    constant float kC4S = \#(Float(TransferFunctions.logC4S))f, kC4T = \#(Float(TransferFunctions.logC4T))f;
    float logC4Decode(float x) { return x >= 0.0f ? (pow(2.0f, 14.0f * (x - kC4C) / kC4B + 6.0f) - 64.0f) / kC4A : x * kC4S + kC4T; }
    float logC4Encode(float y) { return y >= kC4T ? (log2(kC4A * y + 64.0f) - 6.0f) / 14.0f * kC4B + kC4C : (y - kC4T) / kC4S; }
    float log3G10Decode(float y) { return y < 0.0f ? y / 15.1927f - 0.01f : (pow(10.0f, y / 0.224282f) - 1.0f) / 155.975327f - 0.01f; }
    float log3G10Encode(float x) { float s = x + 0.01f; return s < 0.0f ? s * 15.1927f : 0.224282f * log10(s * 155.975327f + 1.0f); }
    float bmdDecode(float y) { return y < 8.283605932402494f * 0.005f + 0.09246575342465753f ? (y - 0.09246575342465753f) / 8.283605932402494f : exp((y - 0.5300133392291939f) / 0.08692876065491224f) - 0.005494072432257808f; }
    float bmdEncode(float x) { return x < 0.005f ? 8.283605932402494f * x + 0.09246575342465753f : 0.08692876065491224f * log(x + 0.005494072432257808f) + 0.5300133392291939f; }
    float nLogDecode(float x) {
        float cv = x * 1023.0f;
        if (cv < 150.0f * log(0.328f) + 619.0f) { float t = cv / 650.0f; return t * t * t - 0.0075f; }
        return exp((cv - 619.0f) / 150.0f);
    }
    float nLogEncode(float y) { return y < 0.328f ? 650.0f * pow(max(y + 0.0075f, 0.0f), 1.0f / 3.0f) / 1023.0f : (150.0f * log(y) + 619.0f) / 1023.0f; }
    float fLog2Decode(float x) { return x >= 0.100686685370811f ? (pow(10.0f, (x - 0.384316f) / 0.245281f) - 0.064829f) / 5.555556f : (x - 0.092864f) / 8.799461f; }
    float fLog2Encode(float y) { return y >= 0.000889f ? 0.245281f * log10(5.555556f * y + 0.064829f) + 0.384316f : 8.799461f * y + 0.092864f; }
    float acesCCTDecode(float y) { return y <= 0.155251141552511f ? (y - 0.0729055341958355f) / 10.5402377416545f : pow(2.0f, y * 17.52f - 9.72f); }
    float acesCCTEncode(float x) { return x <= 0.0078125f ? 10.5402377416545f * x + 0.0729055341958355f : (log2(x) + 9.72f) / 17.52f; }

    float3 map3(float3 v, int fn) {
        switch (fn) {
        case 0: return float3(slog3DecodeLegal(v.x), slog3DecodeLegal(v.y), slog3DecodeLegal(v.z));
        case 1: return hlgDecode3(v);
        case 2: return float3(bt709InverseOETF(v.x), bt709InverseOETF(v.y), bt709InverseOETF(v.z));
        case 3: return float3(vlogDecodeLegal(v.x), vlogDecodeLegal(v.y), vlogDecodeLegal(v.z));
        case 4: return float3(appleLogDecode(v.x), appleLogDecode(v.y), appleLogDecode(v.z));
        case 5: return float3(pqDecode(v.x), pqDecode(v.y), pqDecode(v.z));
        case 6: return float3(dlogDecodeLegal(v.x), dlogDecodeLegal(v.y), dlogDecodeLegal(v.z));
        case 7: return float3(canonLogDecodeLegal(v.x), canonLogDecodeLegal(v.y), canonLogDecodeLegal(v.z));
        case 8: return float3(canonLog2DecodeLegal(v.x), canonLog2DecodeLegal(v.y), canonLog2DecodeLegal(v.z));
        case 9: return float3(canonLog3DecodeLegal(v.x), canonLog3DecodeLegal(v.y), canonLog3DecodeLegal(v.z));
        case 10: return float3(slog3EncodeLegal(v.x), slog3EncodeLegal(v.y), slog3EncodeLegal(v.z));
        case 11: return hlgEncode3(v);
        case 12: return float3(bt709OETF(v.x), bt709OETF(v.y), bt709OETF(v.z));
        case 13: return float3(vlogEncodeLegal(v.x), vlogEncodeLegal(v.y), vlogEncodeLegal(v.z));
        case 14: return float3(appleLogEncode(v.x), appleLogEncode(v.y), appleLogEncode(v.z));
        case 15: return float3(pqEncode(v.x), pqEncode(v.y), pqEncode(v.z));
        case 16: return float3(dlogEncodeLegal(v.x), dlogEncodeLegal(v.y), dlogEncodeLegal(v.z));
        case 17: return float3(canonLogEncodeLegal(v.x), canonLogEncodeLegal(v.y), canonLogEncodeLegal(v.z));
        case 18: return float3(canonLog2EncodeLegal(v.x), canonLog2EncodeLegal(v.y), canonLog2EncodeLegal(v.z));
        case 19: return float3(canonLog3EncodeLegal(v.x), canonLog3EncodeLegal(v.y), canonLog3EncodeLegal(v.z));
        case 20: return float3(logC3Decode(legalToCode(v.x)), logC3Decode(legalToCode(v.y)), logC3Decode(legalToCode(v.z)));
        case 21: return float3(logC4Decode(legalToCode(v.x)), logC4Decode(legalToCode(v.y)), logC4Decode(legalToCode(v.z)));
        case 22: return float3(log3G10Decode(v.x), log3G10Decode(v.y), log3G10Decode(v.z));
        case 23: return float3(bmdDecode(legalToCode(v.x)), bmdDecode(legalToCode(v.y)), bmdDecode(legalToCode(v.z)));
        case 24: return float3(nLogDecode(legalToCode(v.x)), nLogDecode(legalToCode(v.y)), nLogDecode(legalToCode(v.z)));
        case 25: return float3(fLog2Decode(legalToCode(v.x)), fLog2Decode(legalToCode(v.y)), fLog2Decode(legalToCode(v.z)));
        case 26: return float3(acesCCTDecode(v.x), acesCCTDecode(v.y), acesCCTDecode(v.z));
        case 30: return float3(codeToLegal(logC3Encode(v.x)), codeToLegal(logC3Encode(v.y)), codeToLegal(logC3Encode(v.z)));
        case 31: return float3(codeToLegal(logC4Encode(v.x)), codeToLegal(logC4Encode(v.y)), codeToLegal(logC4Encode(v.z)));
        case 32: return float3(log3G10Encode(v.x), log3G10Encode(v.y), log3G10Encode(v.z));
        case 33: return float3(codeToLegal(bmdEncode(v.x)), codeToLegal(bmdEncode(v.y)), codeToLegal(bmdEncode(v.z)));
        case 34: return float3(codeToLegal(nLogEncode(v.x)), codeToLegal(nLogEncode(v.y)), codeToLegal(nLogEncode(v.z)));
        case 35: return float3(codeToLegal(fLog2Encode(v.x)), codeToLegal(fLog2Encode(v.y)), codeToLegal(fLog2Encode(v.z)));
        case 36: return float3(acesCCTEncode(v.x), acesCCTEncode(v.y), acesCCTEncode(v.z));
        default: return v;
        }
    }
    """#
}
