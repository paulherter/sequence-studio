// One effect shader written once in Slang: exposure (stops), saturation, vignette. Compiled to HLSL and MSL
// by scripts/win-shader-check.sh. Reads the source texel 1:1 (no filtering) so both backends can be compared.
struct Params
{
    float exposure;   // stops
    float saturation; // 1 = unchanged
    float vignette;   // 0 = off, 1 = strong
    float _pad;
    float2 size;      // viewport size in pixels
    float2 origin;    // viewport origin in pixels
    float2 texScale;  // source texels per viewport pixel (1 = 1:1)
    float2 _pad2;
};

[[vk::binding(0, 0)]] ConstantBuffer<Params> params;
[[vk::binding(1, 0)]] Texture2D<float4> src;

struct VSOut
{
    float4 pos : SV_Position;
};

[shader("vertex")]
VSOut vsMain(uint id : SV_VertexID)
{
    float2 uv = float2((id << 1) & 2, id & 2);
    VSOut o;
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

[shader("fragment")]
float4 psMain(VSOut i) : SV_Target
{
    float4 c = src.Load(int3(int2((i.pos.xy - params.origin) * params.texScale), 0));
    float3 rgb = c.rgb * exp2(params.exposure);
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = lerp(float3(luma), rgb, params.saturation);
    float2 d = ((i.pos.xy - params.origin) / params.size - 0.5) * 2.0;
    float v = 1.0 - params.vignette * saturate(dot(d, d) * 0.5);
    rgb *= v;
    return float4(saturate(rgb), c.a);
}
