// The SQDrawKit draw-list quad shader (was the HLSL string in Windows CSQWinApp ui.cpp): one instanced draw of
// `DrawQuad`s, six vertices per instance. Mirrors SQDrawKit.SoftwareRenderer.shade (keep both in step). The D3D12 UI
// shim (ui.cpp) and the Mac `MetalDrawListRenderer` (SQDrawKit) draw with it. Own fixed layout (not Bindings.slang):
// t0 atlas (R8 glyph coverage), t1 luma or the RGBA picture, t2 chroma, t3 the quads, t4...t8 image slots 0...4,
// t9 image slot 5, b0 the constants, s0 linear clamp. Quads are in frame pixels; `viewScale` (target pixels per frame
// pixel, <= 0 or 1 = unchanged) shows the frame reduced for a window on a display with a smaller scale: vertices scale, the
// fragment works back in frame pixels, and shapes, glyphs and lines are supersampled so the reduced picture stays crisp. Metal: texture(n) per tn, buffer(0) the constants, the quads at
// buffer(1) (Slang numbers Metal buffers by declaration order).
struct Quad { float4 rect; float4 uv; float4 color; float radius; float stroke; float kind; float pad; float4 clip; };

cbuffer C : register(b0) { float2 screen; float fullRange; float hasVideo; float viewExponent; float viewScale; float2 pad0; };
StructuredBuffer<Quad> quads : register(t3);
Texture2D<float> atlas : register(t0);
Texture2D<float4> luma : register(t1);   // NV12 luma (.r), or the RGBA8 picture (fullRange 2)
Texture2D<float2> chroma : register(t2);
Texture2D<float4> image0 : register(t4);
Texture2D<float4> image1 : register(t5);
Texture2D<float4> image2 : register(t6);
Texture2D<float4> image3 : register(t7);
Texture2D<float4> image4 : register(t8);
Texture2D<float4> image5 : register(t9);
SamplerState smp : register(s0);

struct QuadOut { float4 pos : SV_Position; nointerpolation uint id : QUADID; };

[shader("vertex")]
QuadOut quadVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 corner = float2((vid == 1u || vid == 4u || vid == 5u) ? 1.0f : 0.0f, (vid == 2u || vid == 3u || vid == 5u) ? 1.0f : 0.0f);
    Quad q = quads[iid];
    float2 px = q.rect.xy + corner * q.rect.zw;
    QuadOut o;
    px *= viewScale > 0.0f ? viewScale : 1.0f;
    o.pos = float4(px.x / screen.x * 2.0f - 1.0f, 1.0f - px.y / screen.y * 2.0f, 0.0f, 1.0f);
    o.id = iid;
    return o;
}

float roundBox(float2 c, float2 h, float r) {
    float2 q = abs(c) - h + r;
    float d = length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - r;
    return saturate(0.5f - d);
}

float4 sampleImage(float slot, float2 uv) {
    if (slot < 0.5f) return image0.SampleLevel(smp, uv, 0.0f);
    if (slot < 1.5f) return image1.SampleLevel(smp, uv, 0.0f);
    if (slot < 2.5f) return image2.SampleLevel(smp, uv, 0.0f);
    if (slot < 3.5f) return image3.SampleLevel(smp, uv, 0.0f);
    if (slot < 4.5f) return image4.SampleLevel(smp, uv, 0.0f);
    return image5.SampleLevel(smp, uv, 0.0f);
}

// Coverage-shaded kinds (shape, glyph, segment, triangle) at one point p (frame pixels): the quad's color, alpha scaled by
// the coverage. `guardRect` keeps a supersample just outside the quad from reading a neighbor's atlas texel.
float4 shadeAt(Quad q, float2 p, bool guardRect) {
    if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.z || p.y >= q.clip.w) return float4(0.0f);
    float2 l = p - q.rect.xy;
    float cov = 0.0f;
    if (q.kind < 0.5f) {
        float2 h = q.rect.zw / 2.0f;
        float r = min(q.radius, min(h.x, h.y));
        cov = roundBox(l - h, h, r);
        if (q.stroke > 0.0f) {
            float2 ih = h - q.stroke;
            if (ih.x > 0.0f && ih.y > 0.0f) cov -= roundBox(l - h, ih, max(r - q.stroke, 0.0f));
        }
        cov = max(cov, 0.0f);
    } else if (q.kind < 1.5f) {
        int2 t = int2(int(q.uv.x) + int(l.x), int(q.uv.y) + int(l.y));
        cov = atlas.Load(int3(t, 0));
        if (guardRect && (l.x < 0.0f || l.y < 0.0f || l.x >= q.rect.z || l.y >= q.rect.w)) cov = 0.0f;
    } else if (q.kind > 3.5f) {
        float2 d = q.uv.zw - q.uv.xy;
        float len2 = dot(d, d);
        float t = len2 > 0.0f ? saturate(dot(p - q.uv.xy, d) / len2) : 0.0f;
        cov = saturate(q.stroke / 2.0f + 0.5f - length(p - (q.uv.xy + d * t)));
    } else {
        float lx = q.uv.x > 0.5f ? q.rect.z - l.x : l.x;
        float w = q.rect.z, h = q.rect.w;
        float n = sqrt(w * w + h * h / 4.0f);
        float dTop = (l.y * w - lx * h / 2.0f) / n;
        float dBottom = ((h - l.y) * w - lx * h / 2.0f) / n;
        cov = saturate(min(lx, min(dTop, dBottom)) + 0.5f);
    }
    return float4(q.color.rgb, q.color.a * cov);
}

[shader("fragment")]
float4 quadFragment(QuadOut i) : SV_Target {
    Quad q = quads[i.id];
    float vs = viewScale > 0.0f ? viewScale : 1.0f;
    float2 p = i.pos.xy / vs;
    if (q.kind > 1.5f && q.kind < 2.5f) {
        // The picture: sampled (filtered) once per pixel, never supersampled.
        if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.z || p.y >= q.clip.w) discard;
        if (hasVideo < 0.5f) return float4(0.0f, 0.0f, 0.0f, 1.0f);
        float2 l = p - q.rect.xy;
        float2 uv = q.uv.xy + (q.uv.zw - q.uv.xy) * l / q.rect.zw;
        // View Gamma: code' = code ^ (gamma / 2.2), a monitor preview only (the swap chain shows code values as sRGB).
        if (fullRange > 1.5f) return float4(pow(max(luma.SampleLevel(smp, uv, 0.0f).rgb, float3(0.0f)), float3(viewExponent)), 1.0f);
        float y = luma.SampleLevel(smp, uv, 0.0f).r;
        float2 cbcr = chroma.SampleLevel(smp, uv, 0.0f);
        if (fullRange > 0.5f) { cbcr -= 128.0f / 255.0f; }
        else { y = (y * 255.0f - 16.0f) / 219.0f; cbcr = (cbcr * 255.0f - 128.0f) / 224.0f; }
        float3 rgb = float3(y + 1.5748f * cbcr.y, y - 0.1873f * cbcr.x - 0.4681f * cbcr.y, y + 1.8556f * cbcr.x);
        return float4(pow(saturate(rgb), float3(viewExponent)), 1.0f);
    }
    if (q.kind > 4.5f) {
        if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.z || p.y >= q.clip.w) discard;
        float2 l = p - q.rect.xy;
        float2 uv = q.uv.xy + (q.uv.zw - q.uv.xy) * l / q.rect.zw;
        float4 t = sampleImage(q.pad, uv);
        float a = q.color.a * t.a;
        if (a <= 0.0f) discard;
        return float4(q.color.rgb * t.rgb, a);
    }
    // Reduced view (vs < 1): n x n coverage samples per target pixel; unchanged (one sample) at 1.
    int n = vs >= 1.0f ? 1 : min(int(ceil(1.0f / vs)), 4);
    if (n == 1) {
        float4 r = shadeAt(q, p, false);
        if (r.a <= 0.0f) discard;
        return r;
    }
    float2 base = floor(i.pos.xy);
    float sum = 0.0f;
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            sum += shadeAt(q, (base + (float2(float(x), float(y)) + 0.5f) / float(n)) / vs, true).a;
        }
    }
    float a = sum / float(n * n);
    if (a <= 0.0f) discard;
    return float4(q.color.rgb, a);
}

/// The Mac's picture punch: the video quad (inside its clip) cleared to transparent, drawn without blending, so the
/// Program picture layer under the see-through draw list shows (`MetalDrawListRenderer`).
[shader("fragment")]
float4 quadClear(QuadOut i) : SV_Target {
    Quad q = quads[i.id];
    float2 p = i.pos.xy / (viewScale > 0.0f ? viewScale : 1.0f);
    if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.z || p.y >= q.clip.w) discard;
    return float4(0.0f, 0.0f, 0.0f, 0.0f);
}
