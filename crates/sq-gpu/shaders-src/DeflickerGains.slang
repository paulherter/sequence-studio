// Deflicker gains from the tile means (was TemporalShaderSource.msl in SQRender; engine SQRender TemporalPass). Means at u2,
// gains at u3.
// Mirrors Compositor.DeflickerUniforms (32 bytes).
struct DeflickerU {
    uint frames, tiles, dfBefore, dfAfter;
    uint statsBefore, local;
    float strength, pad;
};
ConstantBuffer<DeflickerU> du : register(b0);
RWByteAddressBuffer means : register(u2);
RWByteAddressBuffer gains : register(u3);
#include "Bindings.slang"

float frameMean(uint j, uint tiles) {
    float s = 0.0f;
    for (uint i = 0; i < tiles; i++) { s += asfloat(means.Load((j * tiles + i) * 4u)); }
    return max(s / float(tiles), 1e-3f);
}

// One thread per tile (x of a one-row grid): the brightness to aim for and every frame's gain toward it.
[shader("compute")][numthreads(16, 16, 1)]
void deflickerGains(uint3 tid : SV_DispatchThreadID) {
    DeflickerU d = du;
    uint tile = tid.x;
    if (tid.y != 0 || tile >= d.tiles) { return; }
    bool local = d.local != 0u;
    float m0 = local ? max(asfloat(means.Load((tile) * 4u)), 1e-3f) : frameMean(0, d.tiles);
    float sum = m0, n = 1.0f;
    for (uint k = 0; k < d.dfBefore + d.dfAfter; k++) {
        uint j = k < d.dfBefore ? 1u + k : 1u + d.statsBefore + (k - d.dfBefore);
        float mj = local ? max(asfloat(means.Load((j * d.tiles + tile) * 4u)), 1e-3f) : frameMean(j, d.tiles);
        if (local) {
            float lr = log(mj / m0);
            uint agree = 0;
            for (uint i = 0; i < d.tiles; i++) {
                float r = log(max(asfloat(means.Load((j * d.tiles + i) * 4u)), 1e-3f) / max(asfloat(means.Load((i) * 4u)), 1e-3f));
                if (abs(r - lr) < 0.12f) { agree++; }
            }
            if (agree * 2u < d.tiles) { continue; }
        }
        sum += mj; n += 1.0f;
    }
    float target = sum / n;
    for (uint j = 0; j < d.frames; j++) {
        float mj = local ? max(asfloat(means.Load((j * d.tiles + tile) * 4u)), 1e-3f) : frameMean(j, d.tiles);
        float g = clamp(target / mj, 0.5f, 2.0f);
        gains.Store((j * d.tiles + tile) * 4u, asuint(1.0f + (g - 1.0f) * d.strength));
    }
}

