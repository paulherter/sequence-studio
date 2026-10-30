#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 3 "Grade.slang"
struct Params_0
{
    float exposure_0;
    float saturation_0;
    float vignette_0;
    float _pad_0;
    float2 size_0;
    float2 origin_0;
    float2 texScale_0;
    float2 _pad2_0;
};

cbuffer params_0 : register(b0)
{
    Params_0 params_0;
}

#line 16
Texture2D<float4 > src_0 : register(t0);

struct VSOut_0
{
    float4 pos_0 : SV_Position;
};


#line 33
float4 psMain(VSOut_0 i_0) : SV_TARGET
{
    float4 c_0 = src_0.Load(int3(int2((i_0.pos_0.xy - params_0.origin_0) * params_0.texScale_0), int(0)));
    float3 rgb_0 = c_0.xyz * (exp2((params_0.exposure_0)));


    float2 d_0 = ((i_0.pos_0.xy - params_0.origin_0) / params_0.size_0 - 0.5f) * 2.0f;


    return float4(saturate(lerp((float3)dot(rgb_0, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f)), rgb_0, (float3)params_0.saturation_0) * (1.0f - params_0.vignette_0 * saturate(dot(d_0, d_0) * 0.5f))), c_0.w);
}

