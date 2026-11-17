// Film / tape look with neighbor reads (was CompositorShaderSource.msl in SQRender; engine SQRender FilmLookPass). in0 = the
// layer's upright picture.
#include "Parts/Look.slang"
ConstantBuffer<LookU> lu : register(b0);
#include "Bindings.slang"

[shader("compute")][numthreads(16, 16, 1)]
void filmLook(uint3 tid : SV_DispatchThreadID) {
    LookU L = lu;
    uint2 dims = outSize();
    uint2 gid = tid.xy;
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    float2 size = float2(dims);
    float2 uv = (float2(gid) + 0.5f) / size;
    float sc = L.dims.z;
    uint flags = L.ids.x;
    const float3 lw = float3(0.2126f, 0.7152f, 0.0722f);

    // Tracking noise: rows are shifted sideways inside a band that rolls up the frame, the bottom edge is always noisy,
    // and bright streaks flare on some rows.
    float dx = 0.0f, streak = 0.0f;
    if ((flags & 32u) != 0u) {
        float yn = 1.0f - uv.y;
        float amount = L.track.x, bh = L.track.y, phase = L.track.z;
        float w = 1.0f - smoothstep(0.0f, bh * 0.5f, abs(yn - phase));
        w = max(w, 0.8f * (1.0f - smoothstep(0.0f, 0.05f, yn)));
        w = max(w, 0.1f);
        float lh = float(pcg(gid.y + pcg(L.ids.z))) * (1.0f / 4294967295.0f);
        dx = ((lh - 0.5f) * 56.0f + sin(yn * 60.0f + phase * 40.0f) * 10.0f) * w * amount * sc;
        float n = hash2(int2(gid), L.ids.z + 17u);
        streak = w * amount * step(0.8f, lh) * (0.4f + 0.6f * n) * smoothstep(0.3f, 1.0f, w);
    }
    float2 suv = uv + float2(dx / size.x, 0.0f);
    float4 c = in0.SampleLevel(edgeSampler, suv, 0.0f);

    // Chroma bleed: the color (rgb minus luma) is averaged over a horizontal span and offset against the brightness.
    if ((flags & 16u) != 0u) {
        float bleed = L.chroma.x * sc, shift = L.chroma.y * sc;
        float y = dot(c.rgb, lw);
        float3 acc = float3(0.0f);
        for (int k = -4; k <= 4; k++) {
            float ox = shift + float(k) * bleed * 0.25f;
            float3 t = in0.SampleLevel(edgeSampler, suv - float2(ox / size.x, 0.0f), 0.0f).rgb;
            acc += t - dot(t, lw);
        }
        c.rgb = float3(y) + acc * (1.0f / 9.0f);
    }

    out0.Store(gid, lookPointwise(c, streak, gid, L));
}
