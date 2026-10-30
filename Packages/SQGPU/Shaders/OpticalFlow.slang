// Optical flow for Frame Interpolation (was OpticalFlow.msl in SQRender): luma pyramid, gradients, coarse-to-fine
// Lucas-Kanade, median, trust, and the picture at t. Engine: SQRender OpticalFlowEngine. Pixel-coordinate taps of the
// old MSL (coord::pixel, clamp, linear) are edgeSampler taps at p / size.
struct FlowU {
    int radius; float lambda; float invTwoSigma2; float maxStep;   // ofLK
    float t; uint linearize; float2 flowScale;                       // ofInterpolate
    float sigma; uint hasPrev; float2 pad;                           // ofInterpolate, ofUp
};
ConstantBuffer<FlowU> u : register(b0);
#include "Bindings.slang"

static const float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);

float2 sizeOf(Texture2D<float4> t) { uint w, h; t.GetDimensions(w, h); return float2(float(w), float(h)); }
float4 tapPx(Texture2D<float4> t, float2 p) { return t.SampleLevel(edgeSampler, p / sizeOf(t), 0.0f); }

float3 ofLinear709(float3 e) {
    e = max(e, 0.0f);
    return select(e < 0.081242858f, e / 4.5f, pow((e + 0.09929682680944f) / 1.09929682680944f, float3(1.0f / 0.45f)));
}

// Luma of the full frame at the working size: 3 x 3 bilinear taps over each output pixel's footprint (box filter).
[shader("compute")][numthreads(16, 16, 1)]
void ofLuma(uint3 tid : SV_DispatchThreadID) {
    uint2 ds = outSize();
    if (tid.x >= ds.x || tid.y >= ds.y) return;
    float2 ss = sizeOf(in0);
    float2 scale = ss / float2(ds);
    float2 base = float2(tid.xy) * scale;
    float acc = 0.0f;
    for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) {
        float2 p = base + (float2(float(i), float(j)) + 0.5f) / 3.0f * scale;
        acc += dot(clamp(in0.SampleLevel(edgeSampler, p / ss, 0.0f).rgb, 0.0f, 1.5f), kLuma);
    }
    out0.Store(tid.xy, float4(acc / 9.0f));
}

// Next pyramid level: about a 4 x 4 box (four bilinear taps around the pixel's center). The center follows the real
// size ratio, so odd sizes (75 -> 38) stay aligned with `ofUp`.
[shader("compute")][numthreads(16, 16, 1)]
void ofDown(uint3 tid : SV_DispatchThreadID) {
    float2 ds = float2(outSize());
    if (tid.x >= uint(ds.x) || tid.y >= uint(ds.y)) return;
    float2 ss = sizeOf(in0);
    float2 r = ss / ds;
    float2 c = (float2(tid.xy) + 0.5f) * r, o = 0.5f * r;
    float v = in0.SampleLevel(edgeSampler, (c + float2(-o.x, -o.y)) / ss, 0.0f).x
            + in0.SampleLevel(edgeSampler, (c + float2(o.x, -o.y)) / ss, 0.0f).x
            + in0.SampleLevel(edgeSampler, (c + float2(-o.x, o.y)) / ss, 0.0f).x
            + in0.SampleLevel(edgeSampler, (c + float2(o.x, o.y)) / ss, 0.0f).x;
    out0.Store(tid.xy, float4(v * 0.25f));
}

[shader("compute")][numthreads(16, 16, 1)]
void ofGrad(uint3 tid : SV_DispatchThreadID) {
    int2 s = int2(inSize());
    if (int(tid.x) >= s.x || int(tid.y) >= s.y) return;
    int2 g = int2(tid.xy);
    float l = read0(clamp(g + int2(-1, 0), int2(0), s - 1)).x, r = read0(clamp(g + int2(1, 0), int2(0), s - 1)).x;
    float t = read0(clamp(g + int2(0, -1), int2(0), s - 1)).x, d = read0(clamp(g + int2(0, 1), int2(0), s - 1)).x;
    out0.Store(tid.xy, float4(0.5f * (r - l), 0.5f * (d - t), 0.0f, 0.0f));
}

// The coarser field scaled up to this level (in this level's pixels); zero when there is none (u.hasPrev == 0).
[shader("compute")][numthreads(16, 16, 1)]
void ofUp(uint3 tid : SV_DispatchThreadID) {
    float2 ds = float2(outSize());
    if (tid.x >= uint(ds.x) || tid.y >= uint(ds.y)) return;
    if (u.hasPrev == 0) { out0.Store(tid.xy, float4(0.0f)); return; }
    float2 ss = sizeOf(in0);
    float2 f = in0.SampleLevel(edgeSampler, (float2(tid.xy) + 0.5f) / ds, 0.0f).xy * (ds / ss);
    out0.Store(tid.xy, float4(f, 0.0f, 0.0f));
}

// One Lucas-Kanade step: the window's flow update from the gradients of both frames (the second one moved by the
// current estimate) and their difference; Gauss-weighted window, Tikhonov term for flat areas, step capped.
// in0 = i0, in1 = g0, in2 = i1, in3 = g1, in4 = current field.
[shader("compute")][numthreads(16, 16, 1)]
void ofLK(uint3 tid : SV_DispatchThreadID) {
    int2 s = int2(inSize());
    if (int(tid.x) >= s.x || int(tid.y) >= s.y) return;
    float2 v = in4.Load(int3(int2(tid.xy), 0)).xy;
    float a11 = 0.0f, a12 = 0.0f, a22 = 0.0f, b1 = 0.0f, b2 = 0.0f;
    float2 fs = float2(s);
    for (int dy = -u.radius; dy <= u.radius; dy++) for (int dx = -u.radius; dx <= u.radius; dx++) {
        int2 q = int2(tid.xy) + int2(dx, dy);
        if (q.x < 0 || q.y < 0 || q.x >= s.x || q.y >= s.y) continue;
        float2 at = float2(q) + 0.5f + v;
        if (at.x < 0.0f || at.y < 0.0f || at.x > fs.x || at.y > fs.y) continue;
        float w = exp(-float(dx * dx + dy * dy) * u.invTwoSigma2);
        float2 g = 0.5f * (in1.Load(int3(q, 0)).xy + in3.SampleLevel(edgeSampler, at / fs, 0.0f).xy);
        float it = in2.SampleLevel(edgeSampler, at / fs, 0.0f).x - in0.Load(int3(q, 0)).x;
        a11 += w * g.x * g.x; a12 += w * g.x * g.y; a22 += w * g.y * g.y;
        b1 += w * g.x * it; b2 += w * g.y * it;
    }
    a11 += u.lambda; a22 += u.lambda;
    float det = a11 * a22 - a12 * a12;
    float2 d = det > 1e-12f ? -float2(a22 * b1 - a12 * b2, a11 * b2 - a12 * b1) / det : float2(0.0f);
    float len = length(d);
    if (len > u.maxStep) d *= u.maxStep / len;
    out0.Store(tid.xy, float4(v + d, 0.0f, 0.0f));
}

float med9(float v[9]) {
    for (int i = 0; i < 5; i++) for (int j = i + 1; j < 9; j++) if (v[j] < v[i]) { float t = v[i]; v[i] = v[j]; v[j] = t; }
    return v[4];
}

[shader("compute")][numthreads(16, 16, 1)]
void ofMedian(uint3 tid : SV_DispatchThreadID) {
    int2 s = int2(inSize());
    if (int(tid.x) >= s.x || int(tid.y) >= s.y) return;
    float x[9], y[9];
    int n = 0;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        float2 f = read0(clamp(int2(tid.xy) + int2(dx, dy), int2(0), s - 1)).xy;
        x[n] = f.x; y[n] = f.y; n++;
    }
    out0.Store(tid.xy, float4(med9(x), med9(y), 0.0f, 0.0f));
}

// Trust of field f (frame i0 to i1) at each pixel, written with the vector: rgba = (flow, trust, 0).
// in0 = i0, in1 = i1, in2 = f, in3 = back.
[shader("compute")][numthreads(16, 16, 1)]
void ofConfidence(uint3 tid : SV_DispatchThreadID) {
    int2 s = int2(inSize());
    if (int(tid.x) >= s.x || int(tid.y) >= s.y) return;
    float2 fs = float2(s);
    float2 v = in2.Load(int3(int2(tid.xy), 0)).xy;
    float sum = 0.0f, wsum = 0.0f;
    for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
        int2 q = clamp(int2(tid.xy) + int2(dx, dy), int2(0), s - 1);
        float w = exp(-float(dx * dx + dy * dy) / 4.5f);
        float e = in1.SampleLevel(edgeSampler, (float2(q) + 0.5f + v) / fs, 0.0f).x - in0.Load(int3(q, 0)).x;
        sum += w * e * e; wsum += w;
    }
    float mse = sum / wsum;
    float2 at = float2(tid.xy) + 0.5f + v;
    bool inside = at.x >= 0.0f && at.y >= 0.0f && at.x <= fs.x && at.y <= fs.y;
    float2 fb = v + in3.SampleLevel(edgeSampler, at / fs, 0.0f).xy;
    float trust = inside ? exp(-mse / 0.005f) * exp(-dot(fb, fb) / 4.5f) : 0.0f;
    out0.Store(tid.xy, float4(v, trust, 0.0f));
}

float4 premul(float4 c, bool lin) {
    float3 rgb = lin ? ofLinear709(c.rgb) : c.rgb;
    return float4(rgb * c.a, c.a);
}
float lumaOf(float4 c, bool lin) {
    float y = dot(c.rgb, kLuma);
    return lin ? y : sqrt(max(y, 0.0f));     // compare in a roughly perceptual scale
}

// The picture at t. Two candidates move A and B along the flow to the instant: the forward field and the reversed
// backward field. Each counts by how well its A and B samples agree; little agreement falls back to the plain blend.
// in0 = a, in1 = b, in2 = forward field, in3 = backward field.
[shader("compute")][numthreads(16, 16, 1)]
void ofInterpolate(uint3 tid : SV_DispatchThreadID) {
    float2 size = float2(outSize());
    if (tid.x >= uint(size.x) || tid.y >= uint(size.y)) return;
    bool lin = u.linearize != 0;
    float t = u.t;
    float2 pc = float2(tid.xy) + 0.5f, uv = pc / size;
    float4 fv = in2.SampleLevel(edgeSampler, uv, 0.0f), gv = in3.SampleLevel(edgeSampler, uv, 0.0f);
    float2 f = fv.xy * u.flowScale;
    float2 g = -gv.xy * u.flowScale;    // backward field reversed: motion A to B
    float4 a1 = tapPx(in0, pc - t * f), b1 = tapPx(in1, pc + (1.0f - t) * f);
    float4 a2 = tapPx(in0, pc - t * g), b2 = tapPx(in1, pc + (1.0f - t) * g);
    float e1 = lumaOf(a1, lin) - lumaOf(b1, lin), e2 = lumaOf(a2, lin) - lumaOf(b2, lin);
    float is2 = 1.0f / (u.sigma * u.sigma);
    float w1 = fv.z * exp(-e1 * e1 * is2), w2 = gv.z * exp(-e2 * e2 * is2);
    float4 m1 = lerp(premul(a1, lin), premul(b1, lin), t), m2 = lerp(premul(a2, lin), premul(b2, lin), t);
    float4 plain = lerp(premul(tapPx(in0, pc), lin), premul(tapPx(in1, pc), lin), t);
    float ws = w1 + w2;
    float4 warped = ws > 1e-6f ? (m1 * w1 + m2 * w2) / ws : plain;
    float4 m = lerp(plain, warped, max(w1, w2));
    out0.Store(tid.xy, float4(m.a > 0.0f ? m.rgb / m.a : float3(0.0f), m.a));
}
