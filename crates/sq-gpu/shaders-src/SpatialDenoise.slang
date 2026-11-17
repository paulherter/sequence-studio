// Spatial edge-keeping smooth of the temporal result (was TemporalShaderSource.msl in SQRender; engine SQRender TemporalPass).
// Mirrors Compositor.SpatialUniforms (32 bytes).
struct SpatialU {
    int radius, step;
    float lumaS, colorS;
    uint linearize, pad0, pad1, pad2;
};
ConstantBuffer<SpatialU> su : register(b0);
#include "Bindings.slang"

float3 inverseOETF709(float3 e) {
    e = max(e, 0.0f);
    return select(e < 0.081242858f, e / 4.5f, pow((e + 0.09929682680944f) / 1.09929682680944f, float3(1.0f / 0.45f)));
}
#include "Parts/YCC.slang"

// Spatial edge-keeping smooth (luma and color on their own) of the temporal result in0.
[shader("compute")][numthreads(16, 16, 1)]
void spatialDenoise(uint3 tid : SV_DispatchThreadID) {
    SpatialU s = su;
    uint2 size = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    float4 c = read0(int2(gid));
    float3 yc0 = toYCC(c.rgb);
    float accY = yc0.x, wy = 1.0f, wc = 1.0f;
    float2 accC = yc0.yz;
    float sig = float(s.radius * s.radius) + 1.0f;
    for (int j = -s.radius; j <= s.radius; j++) {
        for (int i = -s.radius; i <= s.radius; i++) {
            if (i == 0 && j == 0) { continue; }
            int2 q = clamp(int2(gid) + int2(i, j) * s.step, int2(0), int2(size) - 1);
            float3 yc = toYCC(read0(q).rgb);
            float sw = exp(-float(i * i + j * j) / sig);
            float dy = yc.x - yc0.x, dc = length(yc.yz - yc0.yz);
            float a = s.lumaS > 0.0f ? sw * max(0.0f, 1.0f - dy * dy / (s.lumaS * s.lumaS)) : 0.0f;
            float b = s.colorS > 0.0f ? sw * max(0.0f, 1.0f - dc * dc / (s.colorS * s.colorS)) : 0.0f;
            accY += yc.x * a; wy += a;
            accC += yc.yz * b; wc += b;
        }
    }
    float3 res = fromYCC(float3(accY / wy, accC / wc));
    if (s.linearize != 0u) { res = inverseOETF709(res); }
    out0.Store(gid, float4(res, c.a));
}

