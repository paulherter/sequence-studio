// Deflicker tile means (was TemporalShaderSource.msl in SQRender; engine SQRender TemporalPass). in0 = Y plane, in1 = chroma
// plane of one frame; means at u2. One 16 x 16 group per tile.
struct StatsU { uint frame, tilesX, tilesY, pad; };   // temporalStats: frame index and the tile grid
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
ConstantBuffer<StatsU> stu : register(b1);
RWStructuredBuffer<float> means : register(u2);
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Temporal.slang"

// Mean brightness of one tile of one frame: 16 x 16 threads (one group per tile), 2 x 2 samples each.
groupshared float part[256];

[shader("compute")][numthreads(16, 16, 1)]
void temporalStats(uint3 tg : SV_GroupID, uint3 lt : SV_GroupThreadID, uint li : SV_GroupIndex) {
    CompositeU u = cu;
    uint2 size = texSize(in0);
    float2 tile = float2(size) / float2(float(stu.tilesX), float(stu.tilesY));
    float s = 0.0f;
    for (uint k = 0; k < 4; k++) {
        float2 f = (float2(lt.xy * 2u + uint2(k & 1u, k >> 1u)) + 0.5f) / 32.0f;
        int2 q = int2((float2(tg.xy) + f) * tile);
        s += texLuma(u, in0, in1, q, size);
    }
    part[li] = s * 0.25f;
    GroupMemoryBarrierWithGroupSync();
    for (uint w = 128; w > 0; w >>= 1) {
        if (li < w) { part[li] += part[li + w]; }
        GroupMemoryBarrierWithGroupSync();
    }
    if (li == 0) { means[stu.frame * stu.tilesX * stu.tilesY + tg.y * stu.tilesX + tg.x] = part[0] / 256.0f; }
}

