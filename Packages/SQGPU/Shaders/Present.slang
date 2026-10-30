// The monitor's final draw into the drawable (was Presenter.shaderSource in SQRender; engine SQRender Presenter): a
// full-viewport triangle samples in0 (nearest or linear, clamp to edge) and converts working-linear Rec.709 to the view's
// code values. Mirrors Presenter.PresentUniforms at b0.
struct PresentU {
    float4 m0, m1, m2;    // Rec.709 -> view primaries, columns
    float mode;           // 0 SDR, 1 Display P3, 2 HDR with roll-off, 3 HDR extended
    float peak, knee;
    float exponent;       // monitor preview gamma; 1 = unchanged
    uint nearest;         // 1 = nearest sampling (zoom >= 100 %)
};
ConstantBuffer<PresentU> pu : register(b0);
#include "Bindings.slang"

struct PresentOut {
    float4 position : SV_Position;
    float2 uv : UV;
};

[shader("vertex")]
PresentOut presentVertex(uint vid : SV_VertexID) {
    float2 p = float2(float((vid << 1u) & 2u), float(vid & 2u));   // full-viewport triangle
    PresentOut o;
    o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv = float2(p.x, 1.0f - p.y);
    return o;
}

[shader("fragment")]
float4 presentFragment(PresentOut i) : SV_Target {
    PresentU v = pu;
    float4 px = v.nearest != 0u ? in0.SampleLevel(nearestSampler, i.uv, 0.0f) : in0.SampleLevel(edgeSampler, i.uv, 0.0f);
    float3 lin = px.rgb;
    if (v.mode != 0.0f) { lin = max(v.m0.xyz * px.r + v.m1.xyz * px.g + v.m2.xyz * px.b, 0.0f); }
    float3 code;
    if (v.mode < 1.5f) {                                  // SDR / Display P3: BT.709 code values
        float3 l = max(lin, 0.0f);
        code = saturate(select(l < 0.018053968510807f, 4.5f * l, 1.09929682680944f * pow(l, float3(0.45f)) - 0.09929682680944f));
        if (v.exponent != 1.0f) { code = pow(code, float3(v.exponent)); }
    } else {                                              // HDR views: extended linear, may exceed 1
        code = lin;
        float mx = max(lin.x, max(lin.y, lin.z));
        if (v.mode == 2.0f && mx > 0.0f) {                // hue-preserving roll-off on the maximum, in units of the peak
            float m = mx / v.peak;
            if (m > v.knee) { float r = 1.0f - v.knee; m = v.knee + r * (1.0f - exp(-(m - v.knee) / r)); }
            code = lin * (m * v.peak / mx);
        }
    }
    // Opaque pictures (alpha 1) are unchanged. Transparent areas (Transparency Grid: the composite has a transparent
    // backdrop, rgb premultiplied) show a gray checkerboard of 16 px squares.
    float a = saturate(px.a);
    if (a < 1.0f) {
        uint2 cell = uint2(i.position.xy) / 16u;
        float checker = ((cell.x + cell.y) & 1u) == 0u ? 0.20f : 0.32f;
        code = code + (1.0f - a) * checker;
    }
    return float4(v.mode < 1.5f ? saturate(code) : code, 1.0f);
}
