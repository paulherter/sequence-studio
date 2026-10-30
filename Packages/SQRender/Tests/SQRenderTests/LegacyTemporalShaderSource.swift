@testable import SQRender


/// The old MSL of Video Denoise, Deflicker and Trails (`TemporalPass`). Compiled on first use, apart from the main compositor library, with
/// the same conversion helpers (`CompositorShaderSource.convertMSL`), so every source format converts exactly as the plain path.
enum LegacyTemporalShaderSource {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    \(ColorShaderSource.transferMSL)

    \(CompositorShaderSource.convertMSL)

    // Mirrors `Compositor.TemporalUniforms`.
    struct TemporalU {
        uint count;        // frames bound for the denoise (center + before + after), 1...11
        uint nBefore;      // of them before the center (slots 1...nBefore, nearest first; after-frames follow)
        uint statsBefore;  // before-frames in the deflicker stats list (stats index of after-frame i: 1 + statsBefore + i)
        uint flags;        // 1 temporal denoise, 2 deflicker, 4 best (patch distance + motion search), 8 linearize output
        float lumaS;       // temporal luma threshold (encoded units); 0 = luma left alone
        float colorS;      // temporal color threshold; 0 = color left alone
        float motion;      // differences above this count as motion
        float keep;        // share of the (deflickered) original mixed back in
        int searchStep;    // motion search step in px
        uint searchCount;  // 1, 5 or 9 candidate offsets
        uint tilesX;       // deflicker gain grid
        uint tilesY;
    };

    // Mirrors `Compositor.DeflickerUniforms`.
    struct DeflickerU {
        uint frames;       // frames in the stats list (center, before..., after...)
        uint tiles;        // tiles per frame
        uint dfBefore;     // before-frames averaged (stats 1...dfBefore)
        uint dfAfter;      // after-frames averaged (stats 1 + statsBefore ...)
        uint statsBefore;
        uint local;        // 1 = per-tile gains with motion rejection
        float strength;
        float pad;
    };

    // Mirrors `Compositor.SpatialUniforms`.
    struct SpatialU {
        int radius;        // taps each side (1 or 2)
        int step;          // px between taps
        float lumaS;       // 0 = luma left alone
        float colorS;      // 0 = color left alone
        uint linearize;    // 1 = write working-linear (inverse BT.709 OETF)
        uint pad0, pad1, pad2;
    };

    inline float3 toYCC(float3 c) {
        float y = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        return float3(y, (c.b - y) / 1.8556f, (c.r - y) / 1.5748f);
    }
    inline float3 fromYCC(float3 v) {
        float r = v.x + 1.5748f * v.z, b = v.x + 1.8556f * v.y;
        float g = (v.x - 0.2126f * r - 0.0722f * b) / 0.7152f;
        return float3(r, g, b);
    }

    // Brightness of one texel as a number comparable between frames of the same source (Y' straight from the plane for
    // bi-planar sources, the luma of the converted color otherwise).
    inline float texLuma(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, int2 p, uint2 size) {
        uint2 q = uint2(clamp(p, int2(0), int2(size) - 1));
        if (u.mode == 0) return ty.read(q).r * u.range.x + u.range.y;
        return dot(convertTexel(u, ty, tc, 0xFFFFFFFFu, q, size).rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }
    // 5-tap patch (center and the four diagonal neighbors): less noisy than one texel, so motion and noise separate better.
    inline float patchLuma(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, int2 p, uint2 size) {
        return (texLuma(u, ty, tc, p, size) + texLuma(u, ty, tc, p + int2(1, 1), size) + texLuma(u, ty, tc, p + int2(-1, 1), size)
              + texLuma(u, ty, tc, p + int2(1, -1), size) + texLuma(u, ty, tc, p + int2(-1, -1), size)) * 0.2f;
    }

    // Mean brightness of one tile of one frame: 16 x 16 threads, 2 x 2 samples each, spread over the tile.
    kernel void temporalStats(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                              constant CompositeUniforms& u [[buffer(0)]], device float* means [[buffer(1)]],
                              constant uint4& p [[buffer(2)]],   // frame, tilesX, tilesY, -
                              uint2 tg [[threadgroup_position_in_grid]], uint2 lt [[thread_position_in_threadgroup]],
                              uint li [[thread_index_in_threadgroup]]) {
        threadgroup float part[256];
        uint2 size = uint2(ty.get_width(), ty.get_height());
        float2 tile = float2(size) / float2(p.y, p.z);
        float s = 0.0f;
        for (uint k = 0; k < 4; k++) {
            float2 f = (float2(lt * 2u + uint2(k & 1u, k >> 1u)) + 0.5f) / 32.0f;
            int2 q = int2((float2(tg) + f) * tile);
            s += texLuma(u, ty, tc, q, size);
        }
        part[li] = s * 0.25f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint w = 128; w > 0; w >>= 1) {
            if (li < w) part[li] += part[li + w];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (li == 0) means[p.x * p.y * p.z + tg.y * p.y + tg.x] = part[0] / 256.0f;
    }

    inline float frameMean(device const float* means, uint j, uint tiles) {
        float s = 0.0f;
        for (uint i = 0; i < tiles; i++) s += means[j * tiles + i];
        return max(s / float(tiles), 1e-3f);
    }

    // One thread per tile: the brightness to aim for (average of the window) and every frame's gain toward it. Fast: one
    // gain per frame (the frame's mean, every tile the same). Best: per tile; a tile whose change against a neighbor is not
    // shared by most of the frame is motion (or a real light change), not flicker, and that neighbor is left out of its average.
    kernel void deflickerGains(device const float* means [[buffer(0)]], device float* gains [[buffer(1)]],
                               constant DeflickerU& d [[buffer(2)]], uint tile [[thread_position_in_grid]]) {
        if (tile >= d.tiles) return;
        bool local = d.local != 0u;
        float m0 = local ? max(means[tile], 1e-3f) : frameMean(means, 0, d.tiles);
        float sum = m0, n = 1.0f;
        for (uint k = 0; k < d.dfBefore + d.dfAfter; k++) {
            uint j = k < d.dfBefore ? 1u + k : 1u + d.statsBefore + (k - d.dfBefore);
            float mj = local ? max(means[j * d.tiles + tile], 1e-3f) : frameMean(means, j, d.tiles);
            if (local) {
                float lr = log(mj / m0);
                uint agree = 0;
                for (uint i = 0; i < d.tiles; i++) {
                    float r = log(max(means[j * d.tiles + i], 1e-3f) / max(means[i], 1e-3f));
                    if (abs(r - lr) < 0.12f) agree++;
                }
                if (agree * 2u < d.tiles) continue;
            }
            sum += mj; n += 1.0f;
        }
        float target = sum / n;
        for (uint j = 0; j < d.frames; j++) {
            float mj = local ? max(means[j * d.tiles + tile], 1e-3f) : frameMean(means, j, d.tiles);
            float g = clamp(target / mj, 0.5f, 2.0f);
            gains[j * d.tiles + tile] = 1.0f + (g - 1.0f) * d.strength;
        }
    }

    inline float gainAt(device const float* gains, uint frame, float2 uv, constant TemporalU& t) {
        uint n = t.tilesX * t.tilesY;
        float2 p = clamp(uv * float2(t.tilesX, t.tilesY) - 0.5f, float2(0.0f), float2(t.tilesX - 1, t.tilesY - 1));
        uint2 i0 = uint2(floor(p));
        uint2 i1 = min(i0 + 1u, uint2(t.tilesX - 1, t.tilesY - 1));
        float2 f = p - float2(i0);
        uint b = frame * n;
        float a = mix(gains[b + i0.y * t.tilesX + i0.x], gains[b + i0.y * t.tilesX + i1.x], f.x);
        float c = mix(gains[b + i1.y * t.tilesX + i0.x], gains[b + i1.y * t.tilesX + i1.x], f.x);
        return mix(a, c, f.y);
    }

    inline int2 searchOffset(uint c) {
        switch (c) {
            case 1: return int2(1, 0);   case 2: return int2(-1, 0);  case 3: return int2(0, 1);  case 4: return int2(0, -1);
            case 5: return int2(1, 1);   case 6: return int2(-1, 1);  case 7: return int2(1, -1); case 8: return int2(-1, -1);
            default: return int2(0);
        }
    }

    // Deflicker + temporal denoise of the center frame (slot 0) with its neighbors. Writes straight encoded color (or
    // working-linear with flag 8) + the center's alpha.
    kernel void temporalDenoise(array<texture2d<float>, 11> ys [[texture(0)]], array<texture2d<float>, 11> cs [[texture(11)]],
                                texture2d<float, access::write> out [[texture(22)]],
                                constant CompositeUniforms& u [[buffer(0)]], constant TemporalU& t [[buffer(1)]],
                                device const float* gains [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        float2 uv = (float2(gid) + 0.5f) / float2(size);
        bool df = (t.flags & 2u) != 0u, best = (t.flags & 4u) != 0u;
        float4 c0 = convertTexel(u, ys[0], cs[0], 0xFFFFFFFFu, gid, size);
        float g0 = df ? gainAt(gains, 0, uv, t) : 1.0f;
        float3 x0 = c0.rgb * g0;
        float3 res = x0;
        if ((t.flags & 1u) != 0u) {
            float3 yc0 = toYCC(x0);
            float accY = yc0.x, wy = 1.0f, wc = 1.0f;
            float2 accC = yc0.yz;
            float p0 = best ? patchLuma(u, ys[0], cs[0], int2(gid), size) * g0 : 0.0f;
            for (uint k = 1; k < t.count; k++) {
                uint si = k <= t.nBefore ? k : 1u + t.statsBefore + (k - 1u - t.nBefore);
                float gk = df ? gainAt(gains, si, uv, t) : 1.0f;
                int2 off = int2(0);
                float dp = 0.0f;
                if (best) {
                    dp = 1e9f;
                    for (uint c = 0; c < t.searchCount; c++) {
                        int2 o = searchOffset(c) * t.searchStep;
                        float d = abs(patchLuma(u, ys[k], cs[k], int2(gid) + o, size) * gk - p0);
                        if (d < dp) { dp = d; off = o; }
                    }
                }
                uint2 q = uint2(clamp(int2(gid) + off, int2(0), int2(size) - 1));
                float3 yck = toYCC(convertTexel(u, ys[k], cs[k], 0xFFFFFFFFu, q, size).rgb * gk);
                float dy = best ? dp : abs(yck.x - yc0.x);
                float m = 1.0f - smoothstep(0.7f * t.motion, t.motion, dy);
                float wyk = t.lumaS > 0.0f ? m * max(0.0f, 1.0f - (dy * dy) / (t.lumaS * t.lumaS)) : 0.0f;
                float dc = length(yck.yz - yc0.yz);
                float wck = t.colorS > 0.0f ? m * max(0.0f, 1.0f - (dc * dc) / (t.colorS * t.colorS)) : 0.0f;
                accY += yck.x * wyk; wy += wyk;
                accC += yck.yz * wck; wc += wck;
            }
            res = mix(fromYCC(float3(accY / wy, accC / wc)), x0, t.keep);
        }
        if ((t.flags & 8u) != 0u) res = inverseOETF709(res);
        out.write(float4(res, c0.a), gid);
    }

    // Spatial edge-keeping smooth (luma and color on their own) of the temporal result.
    kernel void spatialDenoise(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                               constant SpatialU& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(dst.get_width(), dst.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        float4 c = src.read(gid);
        float3 yc0 = toYCC(c.rgb);
        float accY = yc0.x, wy = 1.0f, wc = 1.0f;
        float2 accC = yc0.yz;
        float sig = float(s.radius * s.radius) + 1.0f;
        for (int j = -s.radius; j <= s.radius; j++) {
            for (int i = -s.radius; i <= s.radius; i++) {
                if (i == 0 && j == 0) continue;
                uint2 q = uint2(clamp(int2(gid) + int2(i, j) * s.step, int2(0), int2(size) - 1));
                float3 yc = toYCC(src.read(q).rgb);
                float sw = exp(-float(i * i + j * j) / sig);
                float dy = yc.x - yc0.x, dc = length(yc.yz - yc0.yz);
                float a = s.lumaS > 0.0f ? sw * max(0.0f, 1.0f - dy * dy / (s.lumaS * s.lumaS)) : 0.0f;
                float b = s.colorS > 0.0f ? sw * max(0.0f, 1.0f - dc * dc / (s.colorS * s.colorS)) : 0.0f;
                accY += yc.x * a; wy += a;
                accC += yc.yz * b; wc += b;
            }
        }
        float3 res = fromYCC(float3(accY / wy, accC / wc));
        if (s.linearize != 0u) res = inverseOETF709(res);
        dst.write(float4(res, c.a), gid);
    }

    // Mirrors `Compositor.TrailsUniforms`.
    struct TrailsU {
        uint count;        // echoes bound (slots 1...count), 0...8
        uint blend;        // 0 add, 1 screen, 2 lighten
        uint flags;        // 1 = the center is `base` (filtered straight encoded color), else slot 0 converted; 2 linearize output
        uint pad;
        float4 w0, w1;     // echo weights, nearest first
    };

    // Trails: earlier frames laid over the center, each weighted by its fade and its own alpha, blended in premultiplied
    // straight encoded color (so a cutout's echoes show where the center is transparent).
    kernel void temporalTrails(array<texture2d<float>, 9> ys [[texture(0)]], array<texture2d<float>, 9> cs [[texture(9)]],
                               texture2d<float> base [[texture(18)]], texture2d<float, access::write> out [[texture(19)]],
                               constant CompositeUniforms& u [[buffer(0)]], constant TrailsU& t [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        float4 c0 = (t.flags & 1u) != 0u ? base.read(gid) : convertTexel(u, ys[0], cs[0], 0xFFFFFFFFu, gid, size);
        float3 p = c0.rgb * c0.a;
        float a = c0.a;
        float3 sumAdd = p, prodScr = 1.0f - clamp(p, 0.0f, 1.0f), mx = p;
        float aInv = 1.0f - a;
        for (uint k = 1; k <= t.count; k++) {
            float w = k <= 4u ? t.w0[k - 1u] : t.w1[k - 5u];
            float4 ck = convertTexel(u, ys[k], cs[k], 0xFFFFFFFFu, gid, size);
            float ak = clamp(ck.a, 0.0f, 1.0f) * w;
            float3 pk = ck.rgb * ak;
            sumAdd += pk;
            prodScr *= 1.0f - clamp(pk, 0.0f, 1.0f);
            mx = max(mx, pk);
            aInv *= 1.0f - ak;
        }
        float alpha = 1.0f - aInv;
        float3 r;
        if (t.blend == 0u) r = min(sumAdd, max(p, float3(alpha)));
        else if (t.blend == 1u) r = max(p, 1.0f - prodScr);
        else r = mx;
        float3 res = alpha > 1e-5f ? r / alpha : float3(0.0f);
        if ((t.flags & 2u) != 0u) res = inverseOETF709(res);
        out.write(float4(res, alpha), gid);
    }
    """
}
