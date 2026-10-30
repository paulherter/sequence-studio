/// The hand-written MSL of the kernels that moved to Slang (Packages/SQGPU/Shaders), kept verbatim as the reference of
/// SlangParityTests: the Slang-generated MSL must match it within 1/255 per channel.
enum LegacyKernelSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    struct FilterU { float4 a; float4 b; float2 center; float2 frame; int4 i; float4 c; float4 d; };

    inline float hash01(uint x, uint y, uint seed, uint ch) {
        uint h = x * 1973u + y * 9277u + seed * 26699u + ch * 104729u;
        h = h * 747796405u + 2891336453u;
        uint w = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
        w = (w >> 22u) ^ w;
        return float(w >> 8u) / 16777216.0f;
    }

    inline float3 inverseOETF709(float3 e) {
        e = max(e, 0.0f);
        float3 lo = e / 4.5f;
        float3 hi = pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f);
        return select(hi, lo, e < 0.081242858f);
    }

    inline float3 oetf709(float3 l) {
        l = max(l, 0.0f);
        float3 hi = 1.09929682680944f * pow(l, 0.45f) - 0.09929682680944f;
        return select(hi, l * 4.5f, l < 0.018053968510807f);
    }

    // Adjustment Layer grade input: premultiplied working-linear -> straight BT.709-encoded color, alpha kept.
    kernel void premultipliedLinearToEncoded709(texture2d<float, access::read> src [[texture(0)]],
                                                texture2d<float, access::write> dst [[texture(1)]],
                                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(gid);
        float3 s = c.a > 0.0f ? c.rgb / c.a : float3(0.0f);
        dst.write(float4(oetf709(s), c.a), gid);
    }

    // Masked Color effect pass: straight working-linear (the color pipeline's output) -> premultiplied.
    kernel void straightToPremultiplied(texture2d<float, access::read> src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(gid);
        dst.write(float4(c.rgb * c.a, c.a), gid);
    }

    // Frame Blending in light-linear space: out = mix(lin(a), lin(b), w). p.y = 1: the inputs are source-encoded BT.709 (apply the
    // inverse OETF first); 0: already working-linear (the color pipeline ran).
    kernel void blendFrames(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            constant float2& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float4 x = a.read(gid), y = b.read(gid);
        if (p.y != 0.0f) { x.rgb = inverseOETF709(x.rgb); y.rgb = inverseOETF709(y.rgb); }
        if (x.a < 1.0f || y.a < 1.0f) {
            // Straight color with alpha (alpha video): mix premultiplied, hand back straight.
            float4 m = mix(float4(x.rgb * x.a, x.a), float4(y.rgb * y.a, y.a), p.x);
            out.write(float4(m.a > 0.0f ? m.rgb / m.a : float3(0.0f), m.a), gid);
            return;
        }
        out.write(mix(x, y, p.x), gid);
    }


    // clampEdges != 0 (Repeat Edge Pixels): every read is clamped into lo...hi (the fully covered px of the clip's frame), so
    // the edge pixels repeat outwards and the whole texture holds the extended picture; the next draw cuts it to the frame.
    // Mirrors Compositor.BlurUniforms (32 bytes).
    struct BlurUniforms { int2 axis; int radius; int clampEdges; int2 lo; int2 hi; };

    kernel void gaussianBlur1D(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant BlurUniforms& b [[buffer(0)]], constant float* w [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int W = int(src.get_width()), H = int(src.get_height());
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        float4 acc = float4(0.0f);
        if (b.clampEdges != 0) {
            for (int k = -b.radius; k <= b.radius; k++) {
                int2 p = clamp(int2(gid) + b.axis * k, b.lo, b.hi);
                acc += src.read(uint2(p)) * w[k + b.radius];
            }
        } else {
            for (int k = -b.radius; k <= b.radius; k++) {
                int2 p = int2(gid) + b.axis * k;
                if (p.x < 0 || p.y < 0 || p.x >= W || p.y >= H) continue;
                acc += src.read(uint2(p)) * w[k + b.radius];
            }
        }
        dst.write(acc, gid);
    }


    // i = picture pixel rect (minX, minY, maxX, maxY): inside it the neighborhood is clamped to it, outside to the texture.
    kernel void filterSharpen(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                              constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int W = int(src.get_width()), H = int(src.get_height());
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        int2 g = int2(gid);
        bool inside = g.x >= u.i.x && g.y >= u.i.y && g.x <= u.i.z && g.y <= u.i.w;
        int2 lo = inside ? u.i.xy : int2(0), hi = inside ? u.i.zw : int2(W - 1, H - 1);
        float4 box = float4(0.0f);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) box += src.read(uint2(clamp(g + int2(i, j), lo, hi)));
        float4 p = src.read(gid);
        float4 o = max(p + u.a.x * (p - box / 9.0f), float4(0.0f));
        o.a = min(o.a, 1.0f);
        dst.write(o, gid);
    }


    kernel void filterDirectionalBlur(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                      constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 c = float2(gid) + 0.5f;
        int n = u.i.x;
        float4 acc = float4(0.0f);
        for (int k = 0; k < n; k++) acc += src.sample(z, (c + u.a.xy * (float(k) / float(n - 1) - 0.5f)) / size);
        dst.write(acc / float(n), gid);
    }

    // One comb pass of a long smear: `n` = i.x taps `step` = a.xy apart, centered; `shift` = b.xy maps a dst pixel into src
    // pixels (the intermediate is padded so the second pass still finds the picture beyond the edge).
    kernel void filterSmearComb(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 size = float2(src.get_width(), src.get_height());
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 c = float2(gid) + 0.5f + u.b.xy;
        int n = u.i.x;
        float2 start = c - u.a.xy * (0.5f * float(n - 1));
        float4 acc = float4(0.0f);
        for (int k = 0; k < n; k++) acc += src.sample(z, (start + u.a.xy * float(k)) / size);
        dst.write(acc / float(n), gid);
    }

    kernel void filterMirror(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 q = float2(gid) + 0.5f;
        float d = dot(q - u.center, u.a.xy);
        if (d > 0.0f) q -= 2.0f * d * u.a.xy;
        dst.write(src.sample(z, q / size), gid);
    }


    // i.x color noise, i.y clip, i.z seed (bit pattern).
    kernel void filterNoise(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 p = src.read(gid), o = p;
        uint seed = as_type<uint>(u.i.z);
        for (uint c = 0; c < 3; c++) {
            float v = p[c] + u.a.x * (hash01(gid.x, gid.y, seed, u.i.x != 0 ? c : 0u) - 0.5f) * p.a;
            o[c] = u.i.y != 0 ? clamp(v, 0.0f, max(p.a, p[c])) : max(v, 0.0f);
        }
        dst.write(o, gid);
    }


    // Mosaic: pixels [start, end) whose centers fall in block b (mirrors ImageFilters.blockRange).
    inline int2 blockRange(float o, float bs, int b, int limit) {
        int s = int(ceil(o + float(b) * bs - 0.5f)), e = int(ceil(o + float(b + 1) * bs - 0.5f));
        return clamp(int2(s, e), int2(0), int2(limit));
    }

    // Mosaic, step 1: the mean of each block's part of each picture row, one thread per (block column, row).
    // Output columns x (rows of picture pixels), row j = picture row i.w + j. i.x columns, i.y rows, i.z sharp, i.w first row.
    kernel void filterMosaicRows(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= u.i.x || gid.y >= dst.get_height()) return;
        float o = u.center.x - u.frame.x * 0.5f, bw = u.frame.x / float(u.i.x);
        int2 r = blockRange(o, bw, int(gid.x), int(src.get_width()));
        uint y = uint(u.i.w) + gid.y;
        float4 acc = float4(0.0f);
        for (int x = r.x; x < r.y; x++) acc += src.read(uint2(x, y));
        dst.write(r.y > r.x ? acc / float(r.y - r.x) : float4(0.0f), gid);
    }

    // Step 2: one thread per block, the mean of its row means (or the pixel under its center: Sharp Colors, or a block
    // holding no pixel center).
    kernel void filterMosaicBlocks(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> rowMeans [[texture(1)]],
                                   texture2d<float, access::write> dst [[texture(2)]], constant FilterU& u [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= u.i.x || int(gid.y) >= u.i.y) return;
        float2 o = u.center - u.frame * 0.5f, bs = u.frame / float2(u.i.xy);
        int W = int(src.get_width()), H = int(src.get_height());
        int2 rx = blockRange(o.x, bs.x, int(gid.x), W), ry = blockRange(o.y, bs.y, int(gid.y), H);
        if (u.i.z != 0 || rx.y <= rx.x || ry.y <= ry.x) {
            int2 p = int2(floor(o + (float2(gid) + 0.5f) * bs));
            bool inside = p.x >= 0 && p.y >= 0 && p.x < W && p.y < H;
            dst.write(inside ? src.read(uint2(p)) : float4(0.0f), gid);
            return;
        }
        float4 acc = float4(0.0f);
        for (int y = ry.x; y < ry.y; y++) acc += rowMeans.read(uint2(gid.x, uint(y - u.i.w)));
        dst.write(acc / float(ry.y - ry.x), gid);
    }

    kernel void filterMosaicApply(texture2d<float, access::read> img [[texture(0)]], texture2d<float, access::read> blocks [[texture(1)]],
                                  texture2d<float, access::write> dst [[texture(2)]], constant FilterU& u [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 q = float2(gid) + 0.5f - (u.center - u.frame * 0.5f);
        if (q.x < 0.0f || q.y < 0.0f || q.x >= u.frame.x || q.y >= u.frame.y) { dst.write(img.read(gid), gid); return; }
        float2 bs = u.frame / float2(u.i.xy);
        uint2 b = uint2(min(int2(q / bs), u.i.xy - 1));
        dst.write(blocks.read(b), gid);
    }

    // src = picture, blur = its Gaussian blur. a.x amount, a.y threshold, i = picture pixel rect: outside it src passes through.
    kernel void filterUnsharp(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::read> blur [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]],
                              constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
        int2 g = int2(gid);
        float4 p = src.read(gid);
        bool inside = g.x >= u.i.x && g.y >= u.i.y && g.x <= u.i.z && g.y <= u.i.w;
        float4 d = p - blur.read(gid);
        if (inside && max(max(abs(d.x), abs(d.y)), abs(d.z)) > u.a.y) {
            p = max(p + u.a.x * d, float4(0.0f));
            p.a = min(p.a, 1.0f);
        }
        dst.write(p, gid);
    }

    // Glow, step 1 into a plane reduced by i.y: each texel is the mean bright pass of its i.y x i.y block of picture pixels
    // (a box, not one tap, so a 1 px highlight neither vanishes nor flickers as it moves). a.x threshold, b.xyz linear tint,
    // i.x = 1 when tinted.
    inline float4 glowBright(float4 p, constant FilterU& u) {
        if (p.a <= 0.0f) return float4(0.0f);
        float luma = dot(p.rgb / p.a, float3(0.2126f, 0.7152f, 0.0722f));
        float w = clamp((luma - u.a.x) / max(1.0f - u.a.x, 1e-3f), 0.0f, 1.0f);
        return (u.i.x != 0 ? float4(u.b.rgb * p.a, p.a) : p) * w;
    }

    kernel void filterGlowBright(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int r = max(u.i.y, 1), W = int(src.get_width()), H = int(src.get_height());
        int2 o = int2(gid) * r;
        float4 acc = float4(0.0f);
        for (int j = 0; j < r; j++) for (int i = 0; i < r; i++) {
            int2 p = o + int2(i, j);
            if (p.x < W && p.y < H) acc += glowBright(src.read(uint2(p)), u);
        }
        dst.write(acc / float(r * r), gid);
    }

    // Step 3: a.y intensity; the reduced plane covers (its size x i.y) picture px.
    kernel void filterGlowAdd(texture2d<float, access::read> img [[texture(0)]], texture2d<float, access::sample> glow [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]], constant FilterU& u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 covered = float2(glow.get_width(), glow.get_height()) * float(max(u.i.y, 1));
        float4 g = glow.sample(s, (float2(gid) + 0.5f) / covered) * u.a.y;
        float4 p = img.read(gid);
        dst.write(float4(p.rgb + g.rgb, min(1.0f, p.a + g.a * (1.0f - p.a))), gid);
    }

    // ---- FB-T2 style filters (StyleFilters.swift; same maths as its CPU references) ----
    inline float sqEnc(float x) { x = max(x, 0.0f); return x < 0.018053968f ? x * 4.5f : 1.09929682680944f * pow(x, 0.45f) - 0.09929682680944f; }
    inline float sqDec(float e) { e = max(e, 0.0f); return e < 0.081242858f ? e / 4.5f : pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f); }
    inline float sqSmooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0f, 1.0f); return t * t * (3.0f - 2.0f * t); }

    inline float vignetteFalloff(float2 q, constant FilterU& u) {
        float2 d = q - u.center;
        float2 e = d / (u.frame * 0.5f);
        float2 circle = d / (sqrt(u.frame.x * u.frame.y) * 0.5f);
        float r;
        if (u.a.z >= 0.0f) { r = length(e + (circle - e) * u.a.z); }
        else { float n = 2.0f + 8.0f * -u.a.z; r = pow(pow(abs(e.x), n) + pow(abs(e.y), n), 1.0f / n); }
        float m = 0.35f + 0.9f * u.a.y, w = 0.05f + 0.6f * u.a.w;
        return sqSmooth(m - w, m + w, r);
    }

    inline float sqHalftone(float2 q, float y, constant FilterU& u) {
        float2 d = q - u.center; float c = cos(u.a.y), s = sin(u.a.y);
        float2 r = float2(c * d.x + s * d.y, -s * d.x + c * d.y) / u.a.x;
        float2 f = r - floor(r) - float2(0.5f);
        float rn = length(f) / 0.70710678f;
        float soft = 0.02f + 0.3f * u.a.z;
        bool color = u.i.x != 0;
        float rho = sqrt(color ? y : 1.0f - y) * (1.0f + 2.0f * soft) - soft;
        float edge = sqSmooth(rho - soft, rho + soft, rn);
        return color ? 1.0f - edge : edge;
    }

    kernel void filterStylePixel(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 p = src.read(gid);
        float2 q = float2(gid) + 0.5f;
        int op = u.i.w;
        if (op == 1 && u.a.x < 0.0f) { float k = exp2(u.a.x * vignetteFalloff(q, u)); dst.write(float4(p.rgb * k, p.a), gid); return; }
        if (op == 12) {
            float2 o = u.center - u.frame * 0.5f;
            float d = min(min(q.x - o.x, o.x + u.frame.x - q.x), min(q.y - o.y, o.y + u.frame.y - q.y));
            dst.write(p * sqSmooth(0.0f, u.a.x, max(d, 0.0f)), gid); return;
        }
        if (op == 8) {
            float3 c = p.a > 0.0f ? p.rgb / p.a : float3(0.0f);
            float a = u.i.x != 0 ? 1.0f : p.a;
            if (u.i.y != 0) a = 1.0f - a;
            a *= u.a.x;
            float3 col = u.i.z != 0 ? float3(1.0f) : c;
            dst.write(float4(col * a, a), gid); return;
        }
        if (op == 7 && u.i.y != 0) { dst.write(p * u.a.w, gid); return; }
        if (op == 3 && u.i.x == 4) {
            float a = p.a + ((1.0f - p.a) - p.a) * (1.0f - u.a.x);
            float3 c = p.a > 0.0f ? p.rgb / p.a : float3(0.0f);
            dst.write(float4(c * a, a), gid); return;
        }
        if (p.a <= 0.0f) { dst.write(p, gid); return; }
        float3 lin = p.rgb / p.a;
        float3 e = float3(sqEnc(lin.r), sqEnc(lin.g), sqEnc(lin.b));
        float3 o = e;
        const float3 lw = float3(0.2126f, 0.7152f, 0.0722f);
        if (op == 1) {
            float k = exp2(-u.a.x * vignetteFalloff(q, u));
            o = max(float3(1.0f) - (float3(1.0f) - min(e, float3(1.0f))) * k, e);
        } else if (op == 3) {
            float3 ce = clamp(e, 0.0f, 1.0f), inv = e;
            if (u.i.x == 0) inv = float3(1.0f) - ce; else inv[u.i.x - 1] = 1.0f - ce[u.i.x - 1];
            o = inv + (e - inv) * u.a.x;
        } else if (op == 4) {
            float l = u.a.x - 1.0f;
            o = round(clamp(e, 0.0f, 1.0f) * l) / l;
        } else if (op == 5) {
            float y = clamp(dot(e, lw), 0.0f, 1.0f);
            float3 target = u.a.rgb + (u.b.rgb - u.a.rgb) * y;
            o = e + (target - e) * u.a.w;
        } else if (op == 6) {
            o = (e - 0.5f) * u.a.y + 0.5f + u.a.x * 0.4f;
        } else if (op == 9) {
            float2 d = (q - u.center) / u.b.w;
            float g = u.a.w * exp(-2.0f * dot(d, d));
            float t = clamp(0.5f + 0.5f * dot(d, u.frame), 0.0f, 1.0f);
            float3 light = min((u.a.rgb + (u.b.rgb - u.a.rgb) * t) * g, float3(1.0f));
            o = e + light * max(float3(1.0f) - e, float3(0.0f));
        } else if (op == 10) {
            float2 d = q - u.center; float len2 = dot(u.frame, u.frame);
            float t = 0.0f;
            if (len2 > 1e-12f) t = u.i.x != 0 ? length(d) / sqrt(len2) : dot(d, u.frame) / len2;
            t = clamp(t, 0.0f, 1.0f);
            o = e + ((u.a.rgb + (u.b.rgb - u.a.rgb) * t) - e) * u.a.w;
        } else if (op == 11) {
            float y = clamp(dot(e, lw), 0.0f, 1.0f);
            float m = sqHalftone(q, y, u);
            float3 target = u.i.x != 0 ? e * m : float3(m);
            o = e + (target - e) * u.a.w;
        } else if (op == 7) {
            float3 s = u.a.rgb, r = s;
            if (u.i.x == 1) r = e + s;
            else if (u.i.x == 2) r = e * s;
            else if (u.i.x == 3) r = float3(1.0f) - (float3(1.0f) - e) * (float3(1.0f) - s);
            else if (u.i.x == 4) r = abs(e - s);
            o = r + (e - r) * u.a.w;
        } else { dst.write(p, gid); return; }
        dst.write(float4(float3(sqDec(o.r), sqDec(o.g), sqDec(o.b)) * p.a, p.a), gid);
    }

    inline float sqWave(float x, int type) {
        if (type == 1) return x - floor(x) < 0.5f ? 1.0f : -1.0f;
        if (type == 2) { float f = x - 0.25f - floor(x - 0.25f); return 4.0f * abs(f - 0.5f) - 1.0f; }
        if (type == 3) { float f = x + 0.5f - floor(x + 0.5f); return 2.0f * f - 1.0f; }
        return sin(2.0f * M_PI_F * x);
    }

    inline float2 sqFoldIntoFrame(float2 s, constant FilterU& u) {
        float2 lo = u.center - u.frame * 0.5f;
        float2 t = (s - lo) / u.frame;
        float2 m = t - 2.0f * floor(t / 2.0f);
        float2 f = float2(m.x > 1.0f ? 2.0f - m.x : m.x, m.y > 1.0f ? 2.0f - m.y : m.y);
        float2 inner = lo + 0.5f, outer = lo + u.frame - 0.5f;   // half a texel inside: no blend with the outside at the fold line
        return min(max(lo + f * u.frame, inner), max(inner, outer));
    }

    inline float2 warpSource(float2 q, constant FilterU& u) {
        int op = u.i.w;
        if (op == 29) {
            float2 d = q - u.center;
            return sqFoldIntoFrame(u.center + float2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + u.b.xy, u);
        }
        if (op == 20) return float2(u.i.x != 0 ? 2.0f * u.center.x - q.x : q.x, u.i.y != 0 ? 2.0f * u.center.y - q.y : q.y);
        if (op == 21) {
            float2 d = q - u.center; float r = length(d), big = u.a.y;
            if (r >= big || big <= 0.0f) return q;
            float k = 1.0f - r / big, th = -u.a.x * k * k, c = cos(th), s = sin(th);
            return u.center + float2(c * d.x - s * d.y, s * d.x + c * d.y);
        }
        if (op == 22) {
            float2 o = u.center - u.frame * 0.5f, dir = u.a.zw, across = float2(-u.a.w, u.a.z);
            float x = dot(q - o, dir) / u.a.y + u.b.x;
            float2 n = (q - o) / u.frame;
            float ex = sqSmooth(0.0f, 0.1f, min(n.x, 1.0f - n.x)), ey = sqSmooth(0.0f, 0.1f, min(n.y, 1.0f - n.y));
            float pin = u.i.y == 1 ? ex * ey : (u.i.y == 2 ? ey : (u.i.y == 3 ? ex : 1.0f));
            return q - across * (u.a.x * sqWave(x, u.i.x) * pin);
        }
        if (op == 23) {
            float2 d = q - u.center; float r = length(d), big = u.a.x;
            if (r >= big || r <= 0.0f) return q;
            float n = r / big, s = u.a.y;
            float f = s > 0.0f ? n + (2.0f / M_PI_F * asin(n) - n) * s : n + (sin(n * M_PI_F / 2.0f) - n) * -s;
            return u.center + d * (f / n);
        }
        if (op == 25) {
            float2 o = u.center - u.frame * 0.5f;
            float2 t = (q - o) / u.frame * u.a.xy + u.a.zw;
            float2 f = t - floor(t);
            if (u.b.x != 0.0f) {
                float2 m = t - 2.0f * floor(t / 2.0f);
                f = float2(m.x > 1.0f ? 2.0f - m.x : m.x, m.y > 1.0f ? 2.0f - m.y : m.y);
            }
            return o + f * u.frame;
        }
        if (op == 26) {
            float2 d = q - u.center; float r = length(d);
            if (r <= 0.0f) return q;
            float w = u.a.x, th = atan2(d.y, d.x);
            float m = th - w * floor(th / w);
            float a = abs(m - w / 2.0f) + u.a.y;
            return u.center + r * u.a.z * float2(cos(a), sin(a));
        }
        if (op == 24) {
            float2 d = q - u.center;
            return u.center + float2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + u.b.xy;
        }
        if (op == 28) {
            float2 d = q - u.center;
            float den = u.b.z * d.x + u.b.w * d.y + 1.0f;
            if (u.i.x != 0 || den <= 1e-6f) return float2(-1e6f, -1e6f);
            return u.center + float2(u.a.x * d.x + u.a.y * d.y + u.a.z, u.a.w * d.x + u.b.x * d.y + u.b.y) / den;
        }
        if (op == 27) {
            if (u.i.y != 0) {
                float2 d = q - u.center;
                float den = u.d.z * d.x + u.d.w * d.y + 1.0f;
                if (den <= 1e-6f) return float2(-1e6f, -1e6f);
                q = u.center + float2(u.c.x * d.x + u.c.y * d.y + u.c.z, u.c.w * d.x + u.d.x * d.y + u.d.y) / den;
            }
            float2 s = u.a.xy; float ext = max(u.a.z, 1.0f); bool alongX = u.i.x != 0;
            float v0 = (alongX ? q.x - u.center.x : q.y - u.center.y) / ext;
            float v = v0 / max(1.0f - (alongX ? s.x : s.y) / ext, 0.5f);
            float2 lo = u.center - u.frame * 0.5f + 0.5f, hi = u.center + u.frame * 0.5f - 0.5f;
            return min(max(q + s * v, lo), max(lo, hi));
        }
        return q;
    }

    kernel void filterStyleWarp(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float gain = u.i.w == 24 ? u.b.z : 1.0f;
        float2 q = float2(gid) + 0.5f;
        if (u.i.w == 29) {      // Edge Fill: the margin outside the frame passes through; reads past the edge are mirrored
            float2 d = abs(q - u.center);
            if (d.x > u.frame.x * 0.5f || d.y > u.frame.y * 0.5f) { dst.write(src.sample(z, q / size), gid); return; }
            float2 d0 = q - u.center;
            float2 raw = u.center + float2(u.a.x * d0.x + u.a.y * d0.y, u.a.z * d0.x + u.a.w * d0.y) + u.b.xy;
            float4 sharp = src.sample(z, sqFoldIntoFrame(raw, u) / size);
            float2 lo = u.center - u.frame * 0.5f, hi = u.center + u.frame * 0.5f;
            float ov = length(max(max(lo - raw, raw - hi), float2(0.0f)));
            if (u.i.x != 2 || ov <= 0.0f) { dst.write(sharp, gid); return; }
            // Blur Edge: the further past the edge, the wider the blur (a 9 x 9 spread of mirrored taps, half-width up to 3 % of the frame).
            float big = max(u.frame.x, u.frame.y);
            float w = smoothstep(0.0f, 0.02f * big, ov), r = 0.03f * big * w * 0.25f;
            float4 acc = float4(0.0f);
            for (int j = -4; j <= 4; j++) for (int i = -4; i <= 4; i++)
                acc += src.sample(z, sqFoldIntoFrame(raw + float2(i, j) * r, u) / size);
            dst.write(mix(sharp, acc / 81.0f, w), gid);
            return;
        }
        if (u.i.w == 27) {      // Rolling Shutter: the margin around the clip's own frame passes through
            float2 d = abs(q - u.center);
            if (d.x > u.frame.x * 0.5f || d.y > u.frame.y * 0.5f) { dst.write(src.sample(z, q / size), gid); return; }
        }
        dst.write(src.sample(z, warpSource(q, u) / size) * gain, gid);
    }

    inline bool sqInPicture(float2 q, constant FilterU& u) {
        float2 o = u.a.zw;
        return q.x >= o.x && q.y >= o.y && q.x <= o.x + u.frame.x && q.y <= o.y + u.frame.y;
    }

    inline float4 sqCubicW(float t) {
        return float4(((-0.5f * t + 1.0f) * t - 0.5f) * t, (1.5f * t - 2.5f) * t * t + 1.0f, ((-1.5f * t + 2.0f) * t + 0.5f) * t, (0.5f * t - 0.5f) * t * t);
    }
    // StyleFilters.lensHold.
    inline float2 sqLensHold(float2 p, constant FilterU& u, thread float& cover) {
        float2 o = u.a.zw, e = o + u.frame;
        cover = 1.0f;
        if (u.i.y != 0) return clamp(p, o + 0.5f, e - 0.5f);
        float2 m = clamp(min(p - o, e - p) + 0.5f, 0.0f, 1.0f);
        cover = m.x * m.y;
        return p;
    }
    // StyleFilters.lensTap: Catmull-Rom without the block's corners as five bilinear fetches (the two middle texels of
    // each axis share one fetch at their weighted position).
    inline float4 sqLensTap(texture2d<float, access::sample> src, float2 p, constant FilterU& u) {
        constexpr sampler l(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 o = u.a.zw, e = o + u.frame;
        float cover;
        p = sqLensHold(p, u, cover);
        if (cover <= 0.0f) return u.b;
        float2 lo = ceil(o - 0.5f) + 0.5f, hi = floor(e - 0.5f) + 0.5f;
        float2 q = p - 0.5f, b = floor(q);
        float4 wx = sqCubicW(q.x - b.x), wy = sqCubicW(q.y - b.y);
        float2 w12 = float2(wx.y + wx.z, wy.y + wy.z);
        float2 c0 = clamp(b - 0.5f, lo, hi), c12 = clamp(b + 0.5f + float2(wx.z, wy.z) / w12, lo, hi), c3 = clamp(b + 2.5f, lo, hi);
        float4 acc = src.sample(l, float2(c12.x, c0.y)) * (w12.x * wy.x) + src.sample(l, float2(c0.x, c12.y)) * (wx.x * w12.y)
            + src.sample(l, c12) * (w12.x * w12.y) + src.sample(l, float2(c3.x, c12.y)) * (wx.w * w12.y)
            + src.sample(l, float2(c12.x, c3.y)) * (w12.x * wy.w);
        acc /= 1.0f - (wx.x + wx.w) * (wy.x + wy.w);
        return acc * cover + u.b * (1.0f - cover);
    }
    // StyleFilters.lensTapLinear.
    inline float4 sqLensLinear(texture2d<float, access::sample> src, float2 p, constant FilterU& u) {
        constexpr sampler l(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 o = u.a.zw, e = o + u.frame;
        float cover;
        p = sqLensHold(p, u, cover);
        if (cover <= 0.0f) return u.b;
        return src.sample(l, clamp(p, ceil(o - 0.5f) + 0.5f, floor(e - 0.5f) + 0.5f)) * cover + u.b * (1.0f - cover);
    }

    kernel void filterLens(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                           constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 q = float2(gid) + 0.5f;
        if (!sqInPicture(q, u)) { dst.write(src.sample(z, q / size), gid); return; }
        if (u.i.z == 0) {       // the look of effects saved before F7.15 (StyleFilters.lensLegacySource)
            float2 d = q - u.center; float r = length(d) / u.a.y, k = u.a.x;
            float f = k >= 0.0f ? 1.0f + k * r * r : 1.0f / (1.0f - k * r * r);
            float2 s = u.center + d * f;
            dst.write(u.b.w > 0.0f && !sqInPicture(s, u) ? u.b : src.sample(z, s / size), gid);
            return;
        }
        float zoom = as_type<float>(u.i.x);
        float2 d = q - u.center; float len = length(d), rho = len / u.a.y * zoom, k = u.a.x;
        float f, g;
        if (k >= 0.0f) { f = 1.0f + k * rho * rho; g = 1.0f + 3.0f * k * rho * rho; }
        else {
            float a = -k, x = rho / (1.0f + a * rho * rho);
            for (int n = 0; n < 4; n++) x -= (x * (1.0f + a * x * x) - rho) / (1.0f + 3.0f * a * x * x);
            f = rho > 1e-6f ? x / rho : 1.0f; g = 1.0f / (1.0f + 3.0f * a * x * x);
        }
        float2 s = u.center + d * (zoom * f);
        float2 o = u.a.zw, e = o + u.frame;
        if (u.i.y == 0 && (s.x < o.x - 3.0f || s.y < o.y - 3.0f || s.x > e.x + 3.0f || s.y > e.y + 3.0f)) { dst.write(u.b, gid); return; }
        float2 stretch = float2(zoom * g, zoom * f);
        float t = clamp((max(stretch.x, stretch.y) - 1.15f) / 0.25f, 0.0f, 1.0f);
        float4 c = float4(0.0f);
        if (t < 1.0f) c += sqLensTap(src, s, u) * (1.0f - t);
        if (t > 0.0f) {
            float2 spread = clamp(stretch - 1.0f, 0.0f, 2.0f) * 0.5f;
            float2 er = len > 1e-6f ? d / len : float2(1.0f, 0.0f), et = float2(-er.y, er.x);
            float2 a = er * spread.x, b = et * spread.y;
            c += (sqLensLinear(src, s + a + b, u) + sqLensLinear(src, s + a - b, u) + sqLensLinear(src, s - a + b, u)
                + sqLensLinear(src, s - a - b, u)) * (0.25f * t);
        }
        // StyleFilters.premultipliedHeld.
        float hold = c.a > 1.0f ? 1.0f / c.a : 1.0f;
        dst.write(c.a <= 0.0f ? float4(0.0f) : float4(max(c.rgb, float3(0.0f)) * hold, min(c.a, 1.0f)), gid);
    }

    kernel void filterGlitch(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                             constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 q = float2(gid) + 0.5f;
        uint id = uint(int((q.y - (u.center.y - u.frame.y * 0.5f)) / u.a.y)), seed = uint(u.i.x);
        float sx = hash01(id, 0u, seed, 0u) < u.a.w ? (hash01(id, 1u, seed, 1u) * 2.0f - 1.0f) * u.a.x : 0.0f;
        float4 r = src.sample(z, (q + float2(sx - u.a.z, 0.0f)) / size);
        float4 g = src.sample(z, (q + float2(sx, 0.0f)) / size);
        float4 b = src.sample(z, (q + float2(sx + u.a.z, 0.0f)) / size);
        dst.write(float4(r.r, g.g, b.b, max(r.a, max(g.a, b.a))), gid);
    }

    kernel void filterRGBSplit(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 q = float2(gid) + 0.5f, d = u.a.xy;
        if (u.i.x != 0) d = length(d) * (q - u.center) / u.a.w;
        float4 p = src.sample(z, q / size), r = src.sample(z, (q - d) / size), b = src.sample(z, (q + d) / size);
        float4 s = float4(r.r, p.g, b.b, max(r.a, max(p.a, b.a)));
        dst.write(s + (p - s) * u.a.z, gid);
    }

    kernel void filterRadialBlur(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 q = float2(gid) + 0.5f, d = q - u.center;
        int n = u.i.y;
        float4 acc = float4(0.0f);
        for (int k = 0; k < n; k++) {
            float t = (float(k) / float(n - 1) - 0.5f) * u.a.x;
            float2 s;
            if (u.i.x != 0) s = u.center + d * (1.0f + t);
            else { float c = cos(t), sn = sin(t); s = u.center + float2(c * d.x - sn * d.y, sn * d.x + c * d.y); }
            acc += src.sample(z, s / size);
        }
        dst.write(acc / float(n), gid);
    }


    // MARK: C5 Outline

    inline float outlineAlpha(texture2d<float, access::read> src, int2 p) {
        if (p.x < 0 || p.y < 0 || p.x >= int(src.get_width()) || p.y >= int(src.get_height())) return 0.0f;
        return src.read(uint2(p)).a;
    }

    // Seed: the nearest alpha 0.5 crossing toward a 4-neighbor on the other side, as (0, 0, sub-pixel offset).
    kernel void filterOutlineSeed(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                  constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int2 g = int2(gid);
        float a = outlineAlpha(src, g);
        bool in0 = a >= 0.5f;
        float bestT = 2.0f;
        float2 off = float2(0.0f);
        const int2 nb[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
        for (int k = 0; k < 4; k++) {
            float an = outlineAlpha(src, g + nb[k]);
            if ((an >= 0.5f) == in0) continue;
            float t = clamp((0.5f - a) / (an - a), 0.0f, 1.0f);
            if (t < bestT) { bestT = t; off = float2(nb[k]) * t; }
        }
        dst.write(bestT <= 1.0f ? float4(0.0f, 0.0f, off) : float4(30000.0, 0.0f, 0.0f, 0.0f), gid);
    }

    // One jump-flood pass, step i.x px: keep the nearest of the 9 seeds at step distance.
    kernel void filterOutlineJump(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                  constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int W = int(dst.get_width()), H = int(dst.get_height());
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        int2 g = int2(gid);
        float4 best = src.read(gid);
        float bd = best.x < 10000.0f ? length(best.xy + best.zw) : 1e9f;
        int step = u.i.x;
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            if (i == 0 && j == 0) continue;
            int2 q = g + int2(i, j) * step;
            if (q.x < 0 || q.y < 0 || q.x >= W || q.y >= H) continue;
            float4 s = src.read(uint2(q));
            if (s.x >= 10000.0f) continue;
            float2 ip = float2(q - g) + s.xy;
            float d = length(ip + s.zw);
            if (d < bd) { bd = d; best = float4(ip, s.zw); }
        }
        dst.write(best, gid);
    }

    // a.x width, a.y softness (texture px), b.rgb linear color, i.x position (0 outside, 1 inside, 2 center).
    kernel void filterOutlineApply(texture2d<float, access::read> img [[texture(0)]], texture2d<float, access::read> seeds [[texture(1)]],
                                   texture2d<float, access::write> dst [[texture(2)]], constant FilterU& u [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 p = img.read(gid);
        float4 s = seeds.read(gid);
        float d = s.x < 10000.0f ? length(s.xy + s.zw) : 1e9f;
        float sd = p.a >= 0.5f ? -d : d;           // signed distance to the edge, < 0 inside the picture
        float w = u.a.x, soft = max(u.a.y, 1.0f);
        float3 col = u.b.rgb;
        if (u.i.x == 1) {
            // Inside: the band within `w` of the edge takes the color, the picture's alpha stays.
            float cov = clamp((w + sd) / soft + 0.5f, 0.0f, 1.0f);
            dst.write(float4(mix(p.rgb, col * p.a, cov), p.a), gid);
        } else if (u.i.x == 2) {
            float cov = clamp((0.5f * w - abs(sd)) / soft + 0.5f, 0.0f, 1.0f);
            dst.write(float4(col * cov, cov) + p * (1.0f - cov), gid);
        } else {
            // Outside: under the picture, from just inside the edge out to `w`.
            float cov = clamp((w - sd) / soft + 0.5f, 0.0f, 1.0f) * clamp(sd + 1.0f, 0.0f, 1.0f);
            dst.write(p + float4(col * cov, cov) * (1.0f - p.a), gid);
        }
    }

    // MARK: C5 Long Shadow

    // One doubling pass: a.xy the step back along the shadow (texture px), a.z the fade over that step; i.x = 1 reads the
    // picture's alpha (first pass), else the plane's red.
    kernel void filterLongShadowStep(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                     constant FilterU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 size = float2(dst.get_width(), dst.get_height());     // plane px (src may be the larger picture)
        float2 c = float2(gid) + 0.5f;
        float4 s0 = src.sample(z, c / size), s1 = src.sample(z, (c - u.a.xy) / size);
        float a0 = u.i.x == 1 ? s0.a : s0.r, a1 = u.i.x == 1 ? s1.a : s1.r;
        dst.write(float4(max(a0, a1 - u.a.z)), gid);
    }

    // b.rgb linear color, a.w opacity.
    // The plane may be smaller than the picture: sampled (linear) at the same normalized spot.
    kernel void filterLongShadowApply(texture2d<float, access::read> img [[texture(0)]], texture2d<float, access::sample> plane [[texture(1)]],
                                      texture2d<float, access::write> dst [[texture(2)]], constant FilterU& u [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler z(coord::normalized, address::clamp_to_zero, filter::linear);
        float4 p = img.read(gid);
        float2 n = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
        float s = clamp(plane.sample(z, n).r, 0.0f, 1.0f) * u.a.w;
        dst.write(p + float4(u.b.rgb * s, s) * (1.0f - p.a), gid);
    }

    kernel void antiFlickerVertical(texture2d<float, access::read> src [[texture(0)]],
                                    texture2d<float, access::write> dst [[texture(1)]],
                                    constant float& k [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int W = int(src.get_width()), H = int(src.get_height());
        if (int(gid.x) >= W || int(gid.y) >= H) return;
        int y = int(gid.y);
        float4 up = src.read(uint2(gid.x, uint(max(y - 1, 0))));
        float4 mid = src.read(gid);
        float4 down = src.read(uint2(gid.x, uint(min(y + 1, H - 1))));
        dst.write(k * up + (1.0f - 2.0f * k) * mid + k * down, gid);
    }
    """

    /// Was OpticalFlowEngine.msl (own library: it defines its own samplers and helpers).
    static let opticalFlow = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler pix(coord::pixel, address::clamp_to_edge, filter::linear);
    constexpr sampler nrm(coord::normalized, address::clamp_to_edge, filter::linear);
    constant float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);

    struct LKParams { int radius; float lambda; float invTwoSigma2; float maxStep; };
    struct InterpParams { float t; uint linearize; float2 flowScale; float sigma; };

    inline float3 ofLinear709(float3 e) {
        e = max(e, 0.0f);
        return select(pow((e + 0.09929682680944f) / 1.09929682680944f, float3(1.0f / 0.45f)), e / 4.5f, e < 0.081242858f);
    }

    // Luma of the full frame at the working size: 3 x 3 bilinear taps over each output pixel's footprint (box filter).
    kernel void ofLuma(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
        uint2 ds = uint2(dst.get_width(), dst.get_height());
        if (gid.x >= ds.x || gid.y >= ds.y) return;
        float2 scale = float2(src.get_width(), src.get_height()) / float2(ds);
        float2 base = float2(gid) * scale;
        float acc = 0.0f;
        for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) {
            float2 p = base + (float2(i, j) + 0.5f) / 3.0f * scale;
            acc += dot(clamp(src.sample(pix, p).rgb, 0.0f, 1.5f), kLuma);
        }
        dst.write(float4(acc / 9.0f), gid);
    }

    // Next pyramid level: about a 4 x 4 box (four bilinear taps around the pixel's center). The center follows the real
    // size ratio, so odd sizes (75 -> 38) stay aligned with `ofUp`.
    kernel void ofDown(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
        float2 ds = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(ds.x) || gid.y >= uint(ds.y)) return;
        float2 r = float2(src.get_width(), src.get_height()) / ds;
        float2 c = (float2(gid) + 0.5f) * r, o = 0.5f * r;
        float v = src.sample(pix, c + float2(-o.x, -o.y)).x + src.sample(pix, c + float2(o.x, -o.y)).x
                + src.sample(pix, c + float2(-o.x, o.y)).x + src.sample(pix, c + float2(o.x, o.y)).x;
        dst.write(float4(v * 0.25f), gid);
    }

    kernel void ofGrad(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
        int2 s = int2(src.get_width(), src.get_height());
        if (int(gid.x) >= s.x || int(gid.y) >= s.y) return;
        int2 g = int2(gid);
        float l = src.read(uint2(clamp(g + int2(-1, 0), int2(0), s - 1))).x, r = src.read(uint2(clamp(g + int2(1, 0), int2(0), s - 1))).x;
        float u = src.read(uint2(clamp(g + int2(0, -1), int2(0), s - 1))).x, d = src.read(uint2(clamp(g + int2(0, 1), int2(0), s - 1))).x;
        dst.write(float4(0.5f * (r - l), 0.5f * (d - u), 0, 0), gid);
    }

    // The coarser field scaled up to this level (in this level's pixels); zero when there is none.
    kernel void ofUp(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                     constant uint& hasPrev [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 ds = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(ds.x) || gid.y >= uint(ds.y)) return;
        if (hasPrev == 0) { dst.write(float4(0), gid); return; }
        float2 ss = float2(src.get_width(), src.get_height());
        float2 f = src.sample(nrm, (float2(gid) + 0.5f) / ds).xy * (ds / ss);
        dst.write(float4(f, 0, 0), gid);
    }

    // One Lucas-Kanade step: the window's flow update from the gradients of both frames (the second one moved by the
    // current estimate) and their difference; Gauss-weighted window, Tikhonov term for flat areas, step capped.
    kernel void ofLK(texture2d<float, access::read> i0 [[texture(0)]], texture2d<float, access::read> g0 [[texture(1)]],
                     texture2d<float, access::sample> i1 [[texture(2)]], texture2d<float, access::sample> g1 [[texture(3)]],
                     texture2d<float, access::read> fin [[texture(4)]], texture2d<float, access::write> fout [[texture(5)]],
                     constant LKParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 s = int2(i0.get_width(), i0.get_height());
        if (int(gid.x) >= s.x || int(gid.y) >= s.y) return;
        float2 u = fin.read(gid).xy;
        float a11 = 0, a12 = 0, a22 = 0, b1 = 0, b2 = 0;
        float2 fs = float2(s);
        for (int dy = -p.radius; dy <= p.radius; dy++) for (int dx = -p.radius; dx <= p.radius; dx++) {
            int2 q = int2(gid) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= s.x || q.y >= s.y) continue;
            float2 at = float2(q) + 0.5f + u;
            if (at.x < 0.0f || at.y < 0.0f || at.x > fs.x || at.y > fs.y) continue;
            float w = exp(-float(dx * dx + dy * dy) * p.invTwoSigma2);
            float2 g = 0.5f * (g0.read(uint2(q)).xy + g1.sample(pix, at).xy);
            float it = i1.sample(pix, at).x - i0.read(uint2(q)).x;
            a11 += w * g.x * g.x; a12 += w * g.x * g.y; a22 += w * g.y * g.y;
            b1 += w * g.x * it; b2 += w * g.y * it;
        }
        a11 += p.lambda; a22 += p.lambda;
        float det = a11 * a22 - a12 * a12;
        float2 d = det > 1e-12f ? -float2(a22 * b1 - a12 * b2, a11 * b2 - a12 * b1) / det : float2(0);
        float len = length(d);
        if (len > p.maxStep) d *= p.maxStep / len;
        fout.write(float4(u + d, 0, 0), gid);
    }

    inline float med9(thread float* v) {
        for (int i = 0; i < 5; i++) for (int j = i + 1; j < 9; j++) if (v[j] < v[i]) { float t = v[i]; v[i] = v[j]; v[j] = t; }
        return v[4];
    }

    kernel void ofMedian(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
        int2 s = int2(src.get_width(), src.get_height());
        if (int(gid.x) >= s.x || int(gid.y) >= s.y) return;
        float x[9], y[9];
        int n = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            float2 f = src.read(uint2(clamp(int2(gid) + int2(dx, dy), int2(0), s - 1))).xy;
            x[n] = f.x; y[n] = f.y; n++;
        }
        dst.write(float4(med9(x), med9(y), 0, 0), gid);
    }

    // Trust of field f (frame i0 to i1) at each pixel, written with the vector: rgba = (flow, trust, 0).
    kernel void ofConfidence(texture2d<float, access::read> i0 [[texture(0)]], texture2d<float, access::sample> i1 [[texture(1)]],
                             texture2d<float, access::read> f [[texture(2)]], texture2d<float, access::sample> back [[texture(3)]],
                             texture2d<float, access::write> out [[texture(4)]], uint2 gid [[thread_position_in_grid]]) {
        int2 s = int2(i0.get_width(), i0.get_height());
        if (int(gid.x) >= s.x || int(gid.y) >= s.y) return;
        float2 u = f.read(gid).xy;
        float sum = 0, wsum = 0;
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
            int2 q = clamp(int2(gid) + int2(dx, dy), int2(0), s - 1);
            float w = exp(-float(dx * dx + dy * dy) / 4.5f);
            float e = i1.sample(pix, float2(q) + 0.5f + u).x - i0.read(uint2(q)).x;
            sum += w * e * e; wsum += w;
        }
        float mse = sum / wsum;
        float2 at = float2(gid) + 0.5f + u;
        bool inside = at.x >= 0.0f && at.y >= 0.0f && at.x <= float(s.x) && at.y <= float(s.y);
        float2 fb = u + back.sample(pix, at).xy;
        float trust = inside ? exp(-mse / 0.005f) * exp(-dot(fb, fb) / 4.5f) : 0.0f;
        out.write(float4(u, trust, 0), gid);
    }

    inline float4 premul(float4 c, bool lin) {
        float3 rgb = lin ? ofLinear709(c.rgb) : c.rgb;
        return float4(rgb * c.a, c.a);
    }
    inline float lumaOf(float4 c, bool lin) {
        float y = dot(c.rgb, kLuma);
        return lin ? y : sqrt(max(y, 0.0f));     // compare in a roughly perceptual scale
    }

    // The picture at t. Two candidates move A and B along the flow to the instant: the forward field and the reversed
    // backward field. Each counts by how well its A and B samples agree; little agreement falls back to the plain blend.
    kernel void ofInterpolate(texture2d<float, access::sample> a [[texture(0)]], texture2d<float, access::sample> b [[texture(1)]],
                              texture2d<float, access::sample> ff [[texture(2)]], texture2d<float, access::sample> fb [[texture(3)]],
                              texture2d<float, access::write> out [[texture(4)]],
                              constant InterpParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(out.get_width(), out.get_height());
        if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
        bool lin = p.linearize != 0;
        float t = p.t;
        float2 pc = float2(gid) + 0.5f, uv = pc / size;
        float4 fv = ff.sample(nrm, uv), gv = fb.sample(nrm, uv);
        float2 f = fv.xy * p.flowScale;
        float2 g = -gv.xy * p.flowScale;    // backward field reversed: motion A to B
        float4 a1 = a.sample(pix, pc - t * f), b1 = b.sample(pix, pc + (1.0f - t) * f);
        float4 a2 = a.sample(pix, pc - t * g), b2 = b.sample(pix, pc + (1.0f - t) * g);
        float e1 = lumaOf(a1, lin) - lumaOf(b1, lin), e2 = lumaOf(a2, lin) - lumaOf(b2, lin);
        float is2 = 1.0f / (p.sigma * p.sigma);
        float w1 = fv.z * exp(-e1 * e1 * is2), w2 = gv.z * exp(-e2 * e2 * is2);
        float4 m1 = mix(premul(a1, lin), premul(b1, lin), t), m2 = mix(premul(a2, lin), premul(b2, lin), t);
        float4 plain = mix(premul(a.sample(pix, pc), lin), premul(b.sample(pix, pc), lin), t);
        float ws = w1 + w2;
        float4 warped = ws > 1e-6f ? (m1 * w1 + m2 * w2) / ws : plain;
        float4 m = mix(plain, warped, max(w1, w2));
        out.write(float4(m.a > 0.0f ? m.rgb / m.a : float3(0.0f), m.a), gid);
    }
    """
}
