// The color chain's blocks (was ColorShaderSource.mslTail in SQRender; mirrors ColorPipeline.process and ColorStages.swift
// 1:1, same constants, order and clamps). Include after Parts/ColorTypes.slang, the
// constant blocks, Bindings.slang and Parts/Transfer.slang. A 3D LUT is lut0, a 1D LUT (rows of 4096) in3.
//
// shortcut: the Mac still grades with ColorShaderSource.msl, because the specialised chains (ColorKernelSource) are MSL
// generated at runtime and must match the generic chain byte for byte; move the Mac over once the generator emits Slang
// (a slang compile at runtime or a precompiled set of chain layouts).

static const uint kLutPresent = 1, kLut1D = 2, kLutIn = 4, kLutOut = 8, kLutTrilinear = 16;
static const float kMinLuma = 1.0f / 65536.0f;

float3 mulM(Sec s, float3 v) { return s.m0.xyz * v.x + s.m1.xyz * v.y + s.m2.xyz * v.z; }
float4 curveRow(uint i) { return curves.rows[i]; }
float3 lut3Read(uint3 p) { return lut0.Load(int4(int3(p), 0)).rgb; }

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
float lumTone(float x, Sec s, uint f) {
    float t = x;
    if ((f & 4u) != 0u) { t = lumContrast(t, s.a.y, s.d.x); }
    if (((f & 64u) != 0u) && t > 0.0f && t < 1.0f) { t = t + s.a.z * 6.75f * t * t * (1.0f - t); }
    if (((f & 8u) != 0u) && t > 0.0f && t < 1.0f) { t = t + s.a.w * 6.75f * t * (1.0f - t) * (1.0f - t); }
    if ((f & 16u) != 0u) {
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
float3 basicStageF(float3 c, Sec s, bool pre, uint f, bool lum) {
    float3 x = c;
    if ((f & 3u) != 0u) {
        float3 lin = pre ? x : map3(x, 2);
        if ((f & 1u) != 0u) { lin = mulM(s, lin); }
        if ((f & 2u) != 0u) {
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
        if ((f & 4u) != 0u) { t = float3(0.45f) + (t - float3(0.45f)) * s.a.y; }
        if ((f & 8u) != 0u) {
            float y = dot(s.c.xyz, t);
            t *= 1.0f + s.a.w * (1.0f - smoothS(0.0f, 0.6f, y));
        }
        if ((f & 64u) != 0u) {
            float y = dot(s.c.xyz, t);
            t += float3(s.a.z * smoothS(0.3f, 1.0f, y));
        }
        if ((f & 16u) != 0u) { t = (t - float3(s.b.x)) / (s.b.y - s.b.x); }
        t = satVib(t, s.b.z, s.b.w, s.c.xyz);
        x = pre ? map3(t, 2) : t;
    }
    return x;
}
float3 basicStage(float3 c, Sec s, bool pre) { return basicStageF(c, s, pre, s.head.z, s.head.w == 1u); }

float3 creativeStageF(float3 c, Sec s, bool pre, bool tint) {
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
float3 creativeStage(float3 c, Sec s, bool pre) { return creativeStageF(c, s, pre, (s.head.z & 1u) != 0u); }

float3 wheelsStageF(float3 c, Sec s, bool pre, bool gamma) {
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
float3 wheelsStage(float3 c, Sec s, bool pre) { return wheelsStageF(c, s, pre, (s.head.z & 1u) != 0u); }

float3 vignetteStage(float3 c, Sec s, bool pre, float2 uv, float aspect) {
    float px = (uv.x - 0.5f) * 2.0f * (1.0f + (aspect - 1.0f) * s.b.x), py = (uv.y - 0.5f) * 2.0f;
    float n = s.a.w;
    float e = n > 2.0001f ? pow(pow(abs(px), n) + pow(abs(py), n), 1.0f / n) : sqrt(px * px + py * py);
    float m = smoothS(s.a.y, s.a.y + s.a.z, e);
    return pre ? c * exp2(s.a.x * m) : c * exp2(0.45f * s.a.x * m);
}

// Per-channel helpers instead of `for ch` loops writing v[ch]: fxc forces such loops to unroll and then fails to unroll
// the section loop around them (X3511); one call per channel compiles on every target.
float curveChannel(uint base, float v, int ch) {
    float x = clamp(v, 0.0f, 1.0f);
    float p = x * float(kCurveCount - 1);
    uint i = min(uint(p), kCurveCount - 2);
    float f = p - float(i);
    float v0 = curveRow(base + i)[ch], v1 = curveRow(base + i + 1)[ch];
    return v0 + (v1 - v0) * f + (v - x);
}

float3 curvesStage(float3 c, Sec s, bool pre) {
    float3 t = pre ? map3(c, 12) : c;
    uint base = s.head.w * kCurveCount;
    float3 o = float3(curveChannel(base, t.x, 0), curveChannel(base, t.y, 1), curveChannel(base, t.z, 2));
    return pre ? map3(o, 2) : o;
}

// Hue Saturation Curves (PreparedHueCurves.apply). Table rows 0…63: (hueVsSat, hueVsHue, hueVsLuma, lumaVsSat); rows 64…127: satVsSat.
float hueSample(uint base, int column, float h) {
    float p = h * float(kCurveCount);
    uint i = min(uint(p), kCurveCount - 1);
    float f = p - float(i);
    float a = curveRow(base + i)[column], b = curveRow(base + ((i + 1) % kCurveCount))[column];
    return a + (b - a) * f;
}
float linearSample(uint row0, int column, float x) {
    float p = clamp(x, 0.0f, 1.0f) * float(kCurveCount - 1);
    uint i = min(uint(p), kCurveCount - 2);
    float f = p - float(i);
    float a = curveRow(row0 + i)[column], b = curveRow(row0 + i + 1)[column];
    return a + (b - a) * f;
}
float3 hueCurvesStage(float3 c, Sec s, bool pre) {
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
    float vs = hueSample(base, 0, hue), vh = hueSample(base, 1, hue), vl = hueSample(base, 2, hue);
    float ls = linearSample(base, 3, y0), ss = linearSample(base + kCurveCount, 0, sv);
    float theta = (vh - 0.5f) * 2.0f * (3.14159265358979f / 3.0f) * w;
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
float hslMask(float3 t, Sec s) {
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
        wh = (1.0f - smoothS(s.a.y, s.a.y + s.a.z, abs(dh))) * smoothS(0.005f, 0.05f, d);
    }
    float sv = mx > 1e-4f ? clamp(d / mx, 0.0f, 1.0f) : 0.0f;
    float ws = smoothS(s.b.x - s.b.z, s.b.x, sv) * (1.0f - smoothS(s.b.y, s.b.y + s.b.z, sv));
    float y = dot(s.d.xyz, t);
    float wl = (s.c.x > 0.0f ? smoothS(s.c.x - s.c.z, s.c.x, y) : 1.0f) * (s.c.y < 1.0f ? 1.0f - smoothS(s.c.y, s.c.y + s.c.z, y) : 1.0f);
    float m = wh * ws * wl;
    return s.b.w > 0.5f ? 1.0f - m : m;
}
float3 hslSecondaryStage(float3 c, Sec s, bool pre) {
    float3 t = pre ? map3(c, 12) : c;
    float w = hslMask(t, s);
    if (!(w > 0.0f)) { return c; }
    float3 o = t * float3(s.m0.x, s.m1.y, s.m2.z);
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
float3 zoneBoardStage(float3 c, Sec s, bool pre) {
    float3 t = pre ? map3(c, 12) : c;
    float3 lum = float3(s.m1.y, s.m1.z, s.m2.x);
    float y = dot(lum, t);
    float sh = 1.0f - smoothS(0.0f, 0.5f, y);
    float mid = smoothS(0.0f, 0.5f, y) * (1.0f - smoothS(0.5f, 1.0f, y));
    float hi = smoothS(0.35f, 1.15f, y);
    float4 w = float4(1.0f, sh, mid, hi);
    float gains[4] = { s.m0.x, s.m0.y, s.m0.z, s.m1.x };
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

float gammaChannel(float v, float e) { return v > 0.0f && e != 1.0f ? pow(v, e) : v; }

// Pro grade Step primaries (PreparedPrimaries.apply). flags: 1 gamma, 2 contrast, 4 saturation.
float3 primariesStage(float3 c, Sec s, bool pre, uint flags) {
    float3 t = pre ? map3(c, 12) : c;
    t = t + s.a.xyz * (float3(1.0f) - t);
    t = t * s.c.xyz + s.d.xyz;
    if ((flags & 1u) != 0u) {
        t = float3(gammaChannel(t.x, s.b.x), gammaChannel(t.y, s.b.y), gammaChannel(t.z, s.b.z));
    }
    if ((flags & 2u) != 0u) { t = (t - float3(s.b.w)) * s.a.w + float3(s.b.w); }
    if ((flags & 4u) != 0u) {
        float y = dot(float3(0.2126f, 0.7152f, 0.0722f), t);
        t = float3(y) + (t - float3(y)) * s.c.w;
    }
    return pre ? map3(t, 2) : t;
}

// Step window (PreparedWindow.mask). m columns: (cx, cy, half x), (half y, cos, sin), (soft, shape, invert).
float stepWindowMask(Sec s, float2 uv, float aspect) {
    float3 r0 = s.m0.xyz, r1 = s.m1.xyz, r2 = s.m2.xyz;
    float px = (uv.x - r0.x) * aspect, py = uv.y - r0.y;
    float qx = px * r1.y + py * r1.z, qy = -px * r1.z + py * r1.y;
    float hx = max(r0.z * aspect, 1e-5f), hy = max(r1.x, 1e-5f);
    float soft = r2.x;
    float m;
    if (r2.y < 0.5f) {
        float ex = qx / hx, ey = qy / hy;
        m = 1.0f - smoothS(1.0f - soft, 1.0f, sqrt(ex * ex + ey * ey));
    } else if (r2.y < 1.5f) {
        m = 1.0f - smoothS(1.0f - soft, 1.0f, max(abs(qx) / hx, abs(qy) / hy));
    } else {
        float e = max(soft * hy, 1e-4f);
        m = 1.0f - smoothS(-e, e, qy);
    }
    return r2.z > 0.5f ? 1.0f - m : m;
}

// End of a limited Step (PreparedStepMatte.apply): the Step's result over its input `n0`. flags: 1 qualifier, 2 window.
// flags also: 4 mix below 1 (s.d.w), 8 layer branch (branchEndStage).
float stepMatte(float3 n0, Sec s, bool pre, uint flags, float2 uv, float aspect) {
    float m = 1.0f;
    if ((flags & 1u) != 0u) { m = hslMask(pre ? map3(n0, 12) : n0, s); }
    if ((flags & 2u) != 0u) { m *= stepWindowMask(s, uv, aspect); }
    if ((flags & 4u) != 0u) { m *= s.d.w; }
    return m;
}
// km: the key register (1 when the end has no key terms before it, flag 16).
float3 stepEndStage(float3 c, float3 n0, Sec s, bool pre, uint flags, float2 uv, float aspect, float km) {
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
void branchEndStage(float3 c, float3 g0, inout float3 acc, Sec s, bool pre, uint flags, float2 uv, float aspect, float km) {
    float m = stepMatte(g0, s, pre, flags, uv, aspect) * km;
    if ((flags & 8u) != 0u) { acc = acc + (layerComposite(acc, c, (flags >> 5) & 7u) - acc) * m; } else { acc += g0 + (c - g0) * m; }
}
// One key wire (PreparedKeyTerm.apply): flags 1 qualifier, 2 window, 4 outside, bits 5...7 mode (0 set, 1 add, 2 multiply,
// 3 subtract, 4 max) combining it with the key register `km`. Evaluated on the receiving Step's input `n0`.
float keyTermStage(float3 n0, Sec s, bool pre, uint flags, float2 uv, float aspect, float km) {
    float m = 1.0f;
    if ((flags & 1u) != 0u) { m = hslMask(pre ? map3(n0, 12) : n0, s); }
    if ((flags & 2u) != 0u) { m *= stepWindowMask(s, uv, aspect); }
    if ((flags & 4u) != 0u) { m = 1.0f - m; }
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

float gamutChannel(float v, float m) {
    if (v >= m) { return v; }
    float d = (m - v) / m;
    if (d > 0.9f) {
        float x = (d - 0.9f) / 0.1f;
        float l = (1.5f - 0.9f) / 0.1f;
        d = 0.9f + 0.1f * (x * (1.0f + x / (l * l)) / (1.0f + x));
    }
    return m - d * m;
}

// SoftGamutCompression.compress, then the export exposure gain (ToneMapping.trim).
float3 hdrTrim(float3 rgb, float gain, float compress) {
    float m = max(rgb.x, max(rgb.y, rgb.z));
    if (compress > 0.5f && m > 0.0f) {
        rgb = float3(gamutChannel(rgb.x, m), gamutChannel(rgb.y, m), gamutChannel(rgb.z, m));
    }
    return rgb * gain;
}

// MARK: LUTs (CubeLUT.lookup)

// vr bit 0: LUT_IN_VIDEO_RANGE, bit 1: LUT_OUT_VIDEO_RANGE (10-bit: 64…940 of 1023).
float3 videoIn(float3 x, uint vr) { return ((vr & 1u) != 0u) ? x * 876.0f / 1023.0f + float3(64.0f / 1023.0f) : x; }
float3 videoOut(float3 y, uint vr) { return ((vr & 2u) != 0u) ? (y - float3(64.0f / 1023.0f)) * 1023.0f / 876.0f : y; }

float3 lookup3D(uint n, float3 dmin, float3 dmax, float3 rgb, uint vr) {
    float3 tt = clamp((videoIn(rgb, vr) - dmin) / (dmax - dmin), 0.0f, 1.0f);
    float3 p = tt * float(n - 1);
    uint ir = min(uint(p.x), n - 2), ig = min(uint(p.y), n - 2), ib = min(uint(p.z), n - 2);
    float fr = p.x - float(ir), fg = p.y - float(ig), fb = p.z - float(ib);
    uint3 base = uint3(ir, ig, ib);
    if ((vr & 4u) != 0u) {
        float3 x00 = lerp(lut3Read(base), lut3Read(base + uint3(1,0,0)), fr);
        float3 x10 = lerp(lut3Read(base + uint3(0,1,0)), lut3Read(base + uint3(1,1,0)), fr);
        float3 x01 = lerp(lut3Read(base + uint3(0,0,1)), lut3Read(base + uint3(1,0,1)), fr);
        float3 x11 = lerp(lut3Read(base + uint3(0,1,1)), lut3Read(base + uint3(1,1,1)), fr);
        return videoOut(lerp(lerp(x00, x10, fg), lerp(x01, x11, fg), fb), vr);
    }
    float3 c000 = lut3Read(base);
    float3 c111 = lut3Read(base + uint3(1, 1, 1));
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
    float3 p1 = lut3Read(base + o1), p2 = lut3Read(base + o2);
    return videoOut(c000 + w0 * (p1 - c000) + w1 * (p2 - p1) + w2 * (c111 - p2), vr);
}

float3 fetch1D(uint i) {
    return in3.Load(int3(int(i & 4095u), int(i >> 12), 0)).rgb;
}

float lut1DChannel(uint n, float p, int ch) {
    uint i0 = min(uint(p), n - 2);
    float f = p - float(i0);
    float a = fetch1D(i0)[ch], b = fetch1D(i0 + 1)[ch];
    return a + (b - a) * f;
}

float3 lookup1D(uint n, float3 dmin, float3 dmax, float3 rgb, uint vr) {
    float3 tt = clamp((videoIn(rgb, vr) - dmin) / (dmax - dmin), 0.0f, 1.0f);
    float3 p = tt * float(n - 1);
    float3 o = float3(lut1DChannel(n, p.x, 0), lut1DChannel(n, p.y, 1), lut1DChannel(n, p.z, 2));
    return videoOut(o, vr);
}

// MARK: chain (ColorPipeline.process)

float3 lookupLUT(uint flags, uint size, float4 dmin, float4 dmax, float3 x) {
    uint vr = ((flags >> 2) & 3u) | ((flags & kLutTrilinear) != 0u ? 4u : 0u);   // bit 2: trilinear
    return (flags & kLut1D) != 0u ? lookup1D(size, dmin.xyz, dmax.xyz, x, vr) : lookup3D(size, dmin.xyz, dmax.xyz, x, vr);
}

// The conversion block (`src`: SourceColorSpace index, `flags`: s.head.z).
float3 conversionStage(float3 c, Sec s, int src, uint flags) {
    if ((flags & kLutPresent) != 0u) {
        float3 e = map3(c, src + 10);
        return lookupLUT(flags, s.head.w, s.a, s.b, e);
    }
    float3 d = src == 2 ? c : mulM(s, c);
    if (src != 2 && s.c.w > -0.5f) { d = toneMap(hdrTrim(d, s.c.z, s.c.w), s.c.x, s.c.y); }
    return map3(max(d, float3(0.0f)), 12);
}

float3 lookStage(float3 c, Sec s, bool pre, uint flags) {
    float3 t = pre ? map3(c, 12) : c;
    float3 graded = lookupLUT(flags, s.head.w, s.a, s.b, t);
    float k = s.c.x;
    t = k >= 1.0f ? graded : t + (graded - t) * k;
    return pre ? map3(t, 2) : t;
}

float3 processPixel(float3 px, float2 uv, float aspect) {
    int src = int(cc.ints.w);  // SourceColorSpace case order (2 = Rec.709)
    float3 c = cc.ints.y == 0u ? map3(px, src) : px;
    float3 n0 = c;
    float3 acc = float3(0.0f);
    float km = 1.0f;
    for (uint i = 0; i < cc.ints.x; i++) {
        Sec s = cc.secs[i];
        bool pre = s.head.y != 0u;
        bool keyed = (s.head.z & 16u) != 0u;
        switch (s.head.x) {
        case 0: c = conversionStage(c, s, src, s.head.z); break;
        case 1: c = basicStage(c, s, pre); break;
        case 2: c = creativeStage(c, s, pre); break;
        case 3: c = lookStage(c, s, pre, s.head.z); break;
        case 4: c = curvesStage(c, s, pre); break;
        case 5: c = wheelsStage(c, s, pre); break;
        case 6: c = vignetteStage(c, s, pre, uv, aspect); break;
        case 7: c = hueCurvesStage(c, s, pre); break;
        case 8: c = hslSecondaryStage(c, s, pre); break;
        case 9: c = primariesStage(c, s, pre, s.head.z); break;
        case 10: n0 = c; break;
        case 11: c = stepEndStage(c, n0, s, pre, s.head.z, uv, aspect, keyed ? km : 1.0f); if (keyed) { km = 1.0f; } break;
        case 12: n0 = c; acc = float3(0.0f); break;
        case 13: branchEndStage(c, n0, acc, s, pre, s.head.z, uv, aspect, keyed ? km : 1.0f); if (keyed) { km = 1.0f; } c = n0; break;
        case 14: acc = s.head.z != 0u ? n0 : acc * s.a.x; break;
        case 15: c = acc; break;
        case 16: km = keyTermStage(n0, s, pre, s.head.z, uv, aspect, km); break;
        case 18: c = zoneBoardStage(c, s, pre); break;
        case 17: acc = n0 + (acc - n0) * km; km = 1.0f; break;
        default: break;
        }
    }
    return cc.ints.z == 3u ? map3(c, 2) : c;
}

// One pixel of the chain at `gid` of a `size` texture (uv and aspect of the upright picture for the vignette).
float4 gradePixel(float4 px, uint2 gid, uint2 size) {
    float2 uv = (float2(gid) + 0.5f) / float2(size);
    float aspect = float(size.x) / float(size.y);
    if (cc.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
    return float4(processPixel(px.rgb, uv, aspect), px.a);
}
