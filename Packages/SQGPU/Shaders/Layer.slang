// The compositor's layer draws (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor): plain (fixed
// blending: premultiplied over or additive, set by the pipeline) and with a blend mode. Fragment inputs: see Parts/Layer.slang;
// mask data at u2.
#include "Parts/CompositeU.slang"
ConstantBuffer<CompositeU> cu : register(b0);
RWStructuredBuffer<uint> maskData : register(u2);
#include "Parts/LayerVertex.slang"
#include "Bindings.slang"
#include "Parts/Transfer.slang"
#include "Parts/Convert.slang"
#include "Parts/Mask.slang"
#include "Parts/Layer.slang"

[shader("fragment")]
float4 compositeFragment(VOut i) : SV_Target {
    return shadeLayer(i, cu, in0, in1, in3, in4, in5);
}

// B(cd, cs) of the separable blend modes, one channel; mirrors BlendModes.scalar (CPU reference).
float blendScalar(uint mode, float cd, float cs) {
    switch (mode) {
    case 1u: return cd * cs;
    case 2u: return cd + cs - cd * cs;
    case 3u: return cd + cs;
    case 4u: return cd <= 0.5f ? 2.0f * cs * cd : cs + (2.0f * cd - 1.0f) - cs * (2.0f * cd - 1.0f);
    case 5u: return min(cd, cs);
    case 6u: return max(cd, cs);
    case 7u: return cd <= 0.0f ? 0.0f : (cs >= 1.0f ? 1.0f : min(1.0f, cd / (1.0f - cs)));
    case 8u: return cd >= 1.0f ? 1.0f : (cs <= 0.0f ? 0.0f : 1.0f - min(1.0f, (1.0f - cd) / cs));
    case 9u: return max(0.0f, cd + cs - 1.0f);
    case 10u: return cs <= 0.5f ? cd * 2.0f * cs : cd + (2.0f * cs - 1.0f) - cd * (2.0f * cs - 1.0f);
    case 11u: {
        if (cs <= 0.5f) { return cd - (1.0f - 2.0f * cs) * cd * (1.0f - cd); }
        float d = cd <= 0.25f ? ((16.0f * cd - 12.0f) * cd + 4.0f) * cd : sqrt(max(cd, 0.0f));
        return cd + (2.0f * cs - 1.0f) * (d - cd);
    }
    case 12u: return abs(cd - cs);
    case 13u: return cd + cs - 2.0f * cd * cs;
    case 15u: {   // Vivid Light: Color Burn with 2cs below half, Color Dodge with 2cs - 1 above
        if (cs <= 0.5f) {
            float s2 = 2.0f * cs;
            return cd >= 1.0f ? 1.0f : (s2 <= 0.0f ? 0.0f : 1.0f - min(1.0f, (1.0f - cd) / s2));
        }
        float s2 = 2.0f * cs - 1.0f;
        return cd <= 0.0f ? 0.0f : (s2 >= 1.0f ? 1.0f : min(1.0f, cd / (1.0f - s2)));
    }
    case 16u: return max(0.0f, cd + 2.0f * cs - 1.0f);
    case 17u: return cs <= 0.5f ? min(cd, 2.0f * cs) : max(cd, 2.0f * cs - 1.0f);
    case 18u: return cd + cs >= 1.0f ? 1.0f : 0.0f;
    case 19u: return max(0.0f, cd - cs);
    case 20u: return cs <= 0.0f ? (cd > 0.0f ? 1.0f : 0.0f) : min(cd / cs, max(1.0f, cd));
    default: return cs;
    }
}

// Non-separable helpers (W3C SetLum / SetSat / ClipColor, Rec.709 weights); mirror BlendModes.
float blendLum(float3 c) { return c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f; }
float3 blendClipColor(float3 c) {
    float l = blendLum(c);
    float n = min(c.x, min(c.y, c.z)), x = max(c.x, max(c.y, c.z));
    if (n < 0.0f) { c = l + (c - l) * (l / max(l - n, 1e-6f)); }
    if (l < 1.0f && x > 1.0f) { c = l + (c - l) * ((1.0f - l) / max(x - l, 1e-6f)); }
    return c;
}
float3 blendSetLum(float3 c, float l) { return blendClipColor(c + (l - blendLum(c))); }
float blendSat(float3 c) { return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)); }
float3 blendSetSat(float3 c, float s) {
    float mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z));
    float range = mx - mn;
    return range > 0.0f ? (c - mn) * (s / range) : float3(0.0f);
}

// B(cd, cs) for the whole color; mirrors BlendModes.channel.
float3 blendChannel(uint mode, float3 cd, float3 cs) {
    switch (mode) {
    case 21u: return blendLum(cs) < blendLum(cd) ? cs : cd;                         // Darker Color
    case 22u: return blendLum(cs) > blendLum(cd) ? cs : cd;                         // Lighter Color
    case 23u: return blendSetLum(blendSetSat(cs, blendSat(cd)), blendLum(cd));      // Hue
    case 24u: return blendSetLum(blendSetSat(cd, blendSat(cs)), blendLum(cd));      // Saturation
    case 25u: return blendSetLum(cs, blendLum(cd));                                 // Color
    case 26u: return blendSetLum(cd, blendLum(cs));                                 // Luminosity
    default: return float3(blendScalar(mode, cd.x, cs.x), blendScalar(mode, cd.y, cs.y), blendScalar(mode, cd.z, cs.z));
    }
}

// Dissolve's fixed per-pixel threshold in [0, 1); mirrors BlendModes.dissolveThreshold (lowbias32, top 24 bits).
float dissolveThreshold(uint2 p) {
    uint h = (p.x * 0x9E3779B9u) ^ (p.y * 0x85EBCA6Bu);
    h ^= h >> 16; h *= 0x7FEB352Du;
    h ^= h >> 15; h *= 0x846CA68Bu;
    h ^= h >> 16;
    return float(h >> 8) / 16777216.0f;
}

// The destination pixel under this fragment. Metal (Apple GPUs): programmable blending reads the render target itself.
// D3D12 has no framebuffer fetch: the caller copies the target to in6 before the draw.
#ifdef SQ_METAL
[[vk::input_attachment_index(0)]] SubpassInput<float4> blendDestination;
[ForceInline] float4 destinationPixel(float4 position) { return blendDestination.SubpassLoad(); }
#else
float4 destinationPixel(float4 position) { return in6.Load(int3(int2(position.xy), 0)); }
#endif

// Single-layer composite with a blend mode: reads the destination and writes the finished pixel, so the pipeline has
// fixed-function blending off.
[shader("fragment")]
float4 compositeFragmentBlend(VOut i) : SV_Target {
    CompositeU u = cu;
    float4 dst = destinationPixel(i.position);
    float4 s = shadeLayer(i, u, in0, in1, in3, in4, in5);
    if (u.blend == 27u) { return dst * (1.0f - u.opacity + s.a); }   // footage fill: mirrors BlendModes.stencil
    float3 cs = s.a > 0.0f ? s.rgb / s.a : float3(0.0f);
    if (u.blend == 14u) {   // Dissolve: full source where the pixel's threshold is below its coverage, else none
        bool on = dissolveThreshold(uint2(i.position.xy)) < s.a;
        s = on ? float4(cs, 1.0f) : float4(0.0f);
        cs = on ? cs : float3(0.0f);
    }
    float3 cd = dst.a > 0.0f ? dst.rgb / dst.a : float3(0.0f);
    float3 b = blendChannel(u.blend, cd, cs);
    float3 rgb = s.rgb * (1.0f - dst.a) + dst.rgb * (1.0f - s.a) + s.a * dst.a * b;
    return float4(rgb, s.a + dst.a * (1.0f - s.a));
}
