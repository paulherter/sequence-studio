/// The scopes MSL before Scopes.slang (parity reference).
/// Mirrors `ScopesReference` exactly (same constants, binning, row orientation).
enum LegacyScopeShaderSource {
    static let msl = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ScopeUniforms {
        uint width, height, stride, flags;
        uint waveW, waveL, vecN, pad;
        uint offWaveLuma, offParade, offVector, offHist;
        uint offMax, pad1, pad2, pad3;
    };
    constant uint kWaveLuma = 1, kParade = 2, kVector = 4, kHist = 8;

    constant float kBt709Alpha = 1.09929682680944f;
    constant float kBt709Beta = 0.018053968510807f;
    float bt709OETF(float l) {
        if (l < kBt709Beta) { return 4.5f * l; }
        return kBt709Alpha * pow(l, 0.45f) - (kBt709Alpha - 1.0f);
    }

    uint levelOf(float v, uint levels) { return min(uint(v * float(levels)), levels - 1); }

    kernel void scopeClear(device uint *counts [[buffer(0)]], constant uint &n [[buffer(1)]],
                           uint i [[thread_position_in_grid]]) {
        if (i < n) { counts[i] = 0; }
    }

    kernel void scopeAccumulate(texture2d<float, access::read> src [[texture(0)]],
                                device atomic_uint *counts [[buffer(0)]],
                                constant ScopeUniforms &u [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint x = gid.x * u.stride, y = gid.y * u.stride;
        if (x >= u.width || y >= u.height) { return; }
        float3 lin = src.read(uint2(x, y)).rgb;
        float3 c = clamp(lin, 0.0f, 1.0f);
        float3 s = float3(bt709OETF(c.x), bt709OETF(c.y), bt709OETF(c.z));
        float luma = s.x * 0.2126f + s.y * 0.7152f + s.z * 0.0722f;
        uint W = u.waveW, L = u.waveL;
        uint col = min(x * W / u.width, W - 1);
        if (u.flags & kWaveLuma) {
            uint row = L - 1 - levelOf(luma, L);
            atomic_fetch_add_explicit(&counts[u.offWaveLuma + row * W + col], 1u, memory_order_relaxed);
        }
        if (u.flags & kParade) {
            for (uint ch = 0; ch < 3; ch++) {
                uint row = L - 1 - levelOf(s[ch], L);
                atomic_fetch_add_explicit(&counts[u.offParade + row * 3 * W + ch * W + col], 1u, memory_order_relaxed);
            }
        }
        if (u.flags & kVector) {
            float cb = (s.z - luma) / 1.8556f, cr = (s.x - luma) / 1.5748f;
            float nf = float(u.vecN);
            float cx = min(max(floor(cb * nf + nf / 2.0f + 0.5f), 0.0f), nf - 1.0f);
            float cy = min(max(floor(nf / 2.0f - cr * nf + 0.5f), 0.0f), nf - 1.0f);
            atomic_fetch_add_explicit(&counts[u.offVector + uint(cy) * u.vecN + uint(cx)], 1u, memory_order_relaxed);
        }
        if (u.flags & kHist) {
            for (uint ch = 0; ch < 3; ch++) {
                atomic_fetch_add_explicit(&counts[u.offHist + ch * 256 + levelOf(s[ch], 256)], 1u, memory_order_relaxed);
            }
            atomic_fetch_add_explicit(&counts[u.offHist + 3 * 256 + levelOf(luma, 256)], 1u, memory_order_relaxed);
        }
    }

    struct MaxParams { uint offset, count, maxIndex, pad; };

    kernel void scopeFindMax(device atomic_uint *counts [[buffer(0)]], constant MaxParams &p [[buffer(1)]],
                             uint i [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]]) {
        uint v = i < p.count ? atomic_load_explicit(&counts[p.offset + i], memory_order_relaxed) : 0u;
        uint m = simd_max(v);
        if (lane == 0 && m > 0) { atomic_fetch_max_explicit(&counts[p.maxIndex], m, memory_order_relaxed); }
    }

    struct ResolveParams { uint offset, maxIndex, width, height; };

    kernel void scopeResolve(device atomic_uint *counts [[buffer(0)]], constant ResolveParams &p [[buffer(1)]],
                             texture2d<float, access::write> out [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) { return; }
        uint c = atomic_load_explicit(&counts[p.offset + gid.y * p.width + gid.x], memory_order_relaxed);
        uint m = atomic_load_explicit(&counts[p.maxIndex], memory_order_relaxed);
        out.write(float4(m == 0 ? 0.0f : float(c) / float(m), 0, 0, 1), gid);
    }
    """#
}
