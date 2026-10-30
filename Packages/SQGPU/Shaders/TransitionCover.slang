// Smallest alpha of a transition side, exactly (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor): a
// group minimum, then one atomic min per group into cover[slot] (init 1.0f; non-negative floats order like their bits, so
// the result does not depend on the order the groups finish). in0 = the side. Out-of-range threads count as opaque; the
// grid must be whole 16 x 16 groups (Metal shrinks edge groups, which would leave part of the reduction unset).
struct CoverU { uint slot, pad0, pad1, pad2; };
ConstantBuffer<CoverU> vu : register(b0);
RWStructuredBuffer<uint> cover : register(u2);
#include "Bindings.slang"

groupshared float lowest[256];

[shader("compute")][numthreads(16, 16, 1)]
void transitionCoverMin(uint3 tid : SV_DispatchThreadID, uint li : SV_GroupIndex) {
    uint2 size = inSize();
    float a = 1.0f;
    if (tid.x < size.x && tid.y < size.y) { a = max(in0.Load(int3(int2(tid.xy), 0)).a, 0.0f); }
    lowest[li] = a;
    GroupMemoryBarrierWithGroupSync();
    for (uint w = 128; w > 0; w >>= 1) {
        if (li < w) { lowest[li] = min(lowest[li], lowest[li + w]); }
        GroupMemoryBarrierWithGroupSync();
    }
    if (li == 0) { InterlockedMin(cover[vu.slot], asuint(lowest[0])); }
}
