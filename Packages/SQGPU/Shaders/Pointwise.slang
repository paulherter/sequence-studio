// Per-pixel compositor passes (were premultipliedLinearToEncoded709, straightToPremultiplied, blendFrames).
struct PointU { float2 p; float2 pad; };
ConstantBuffer<PointU> u : register(b0);
#include "Bindings.slang"

float3 inverseOETF709(float3 e) {
    e = max(e, 0.0f);
    float3 lo = e / 4.5f;
    float3 hi = pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f);
    return select(e < 0.081242858f, lo, hi);
}

// BT.709 OETF (exact inverse of inverseOETF709, extended above 1 by the same curve).
float3 oetf709(float3 l) {
    l = max(l, 0.0f);
    float3 hi = 1.09929682680944f * pow(l, 0.45f) - 0.09929682680944f;
    return select(l < 0.018053968510807f, l * 4.5f, hi);
}

// Adjustment Layer grade input: premultiplied working-linear -> straight BT.709-encoded color, alpha kept.
[shader("compute")][numthreads(16, 16, 1)]
void premultipliedLinearToEncoded709(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float4 c = read0(int2(tid.xy));
    float3 st = c.a > 0.0f ? c.rgb / c.a : float3(0.0f);
    out0.Store(tid.xy, float4(oetf709(st), c.a));
}

// Masked Color effect pass: straight working-linear -> premultiplied.
[shader("compute")][numthreads(16, 16, 1)]
void straightToPremultiplied(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float4 c = read0(int2(tid.xy));
    out0.Store(tid.xy, float4(c.rgb * c.a, c.a));
}

// Frame Blending in light-linear space: out = mix(lin(a), lin(b), p.x). p.y = 1: the inputs are source-encoded BT.709.
[shader("compute")][numthreads(16, 16, 1)]
void blendFrames(uint3 tid : SV_DispatchThreadID) {
    uint2 s = outSize();
    if (tid.x >= s.x || tid.y >= s.y) return;
    float4 x = read0(int2(tid.xy)), y = read1(int2(tid.xy));
    if (u.p.y != 0.0f) { x.rgb = inverseOETF709(x.rgb); y.rgb = inverseOETF709(y.rgb); }
    if (x.a < 1.0f || y.a < 1.0f) {
        // Straight color with alpha (alpha video): mix premultiplied, hand back straight.
        float4 m = lerp(float4(x.rgb * x.a, x.a), float4(y.rgb * y.a, y.a), u.p.x);
        out0.Store(tid.xy, float4(m.a > 0.0f ? m.rgb / m.a : float3(0.0f), m.a));
        return;
    }
    out0.Store(tid.xy, lerp(x, y, u.p.x));
}

// Anti-flicker: vertical [k, 1 - 2k, k] with the edge rows repeated; k = u.p.x (CPU reference: SQRender AntiFlickerFilter).
[shader("compute")][numthreads(16, 16, 1)]
void antiFlickerVertical(uint3 tid : SV_DispatchThreadID) {
    uint2 s = inSize();
    int H = int(s.y);
    if (tid.x >= s.x || int(tid.y) >= H) return;
    int y = int(tid.y), x = int(tid.x);
    float k = u.p.x;
    float4 up = read0(int2(x, max(y - 1, 0))), mid = read0(int2(x, y)), down = read0(int2(x, min(y + 1, H - 1)));
    out0.Store(tid.xy, k * up + (1.0f - 2.0f * k) * mid + k * down);
}
