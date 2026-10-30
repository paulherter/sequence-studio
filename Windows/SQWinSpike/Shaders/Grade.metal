#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 90 "core"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


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


struct KernelContext_0
{
    Params_0 constant* params_0;
    texture2d<float, access::sample> src_0;
};


#line 33
[[fragment]] pixelOutput_0 psMain(float4 pos_0 [[position]], Params_0 constant* params_1 [[buffer(0)]], texture2d<float, access::sample> src_1 [[texture(0)]])
{

#line 33
    thread KernelContext_0 kernelContext_0;

#line 33
    (&kernelContext_0)->params_0 = params_1;

#line 33
    (&kernelContext_0)->src_0 = src_1;

    float2 _S1 = pos_0.xy;

#line 35
    int3 _S2 = int3(int2((_S1 - params_1->origin_0) * params_1->texScale_0), int(0));

#line 35
    float4 c_0 = ((src_1).read(vec<uint,2>(((_S2)).xy), uint(((_S2)).z)));
    float3 rgb_0 = c_0.xyz * float3(exp2(params_1->exposure_0)) ;


    float2 d_0 = ((_S1 - params_1->origin_0) / params_1->size_0 - float2(0.5f) ) * float2(2.0f) ;

#line 39
    pixelOutput_0 _S3 = { float4(saturate(mix(float3(dot(rgb_0, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f))) , rgb_0, float3(params_1->saturation_0) ) * float3((1.0f - params_1->vignette_0 * saturate(dot(d_0, d_0) * 0.5f))) ), c_0.w) };


    return _S3;
}


#line 42
struct vsMain_Result_0
{
    float4 pos_1 [[position]];
};


#line 18
struct VSOut_0
{
    float4 pos_2;
};


#line 18
[[vertex]] vsMain_Result_0 vsMain(uint id_0 [[vertex_id]], Params_0 constant* params_2 [[buffer(0)]], texture2d<float, access::sample> src_2 [[texture(0)]])
{

#line 18
    thread KernelContext_0 kernelContext_1;

#line 18
    (&kernelContext_1)->params_0 = params_2;

#line 18
    (&kernelContext_1)->src_0 = src_2;

#line 27
    thread VSOut_0 o_0;
    (&o_0)->pos_2 = float4(float2(float((id_0 << 1U) & 2U), float(id_0 & 2U)) * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);

#line 28
    thread vsMain_Result_0 _S4;

#line 28
    (&_S4)->pos_1 = o_0.pos_2;

#line 28
    return _S4;
}

