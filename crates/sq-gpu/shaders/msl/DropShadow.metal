#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 3 "crates/sq-gpu/shaders-src/DropShadow.slang"
struct ShadowU_0
{
    float2 offset_0;
    float4 color_0;
    int shadowOnly_0;
    float spread_0;
};


#line 37 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    texture2d<float, access::write> out0_0;
    ShadowU_0 constant* su_0;
    texture2d<float, access::sample> in0_0;
    sampler zeroSampler_0;
    texture2d<float, access::sample> in1_0;
    sampler edgeSampler_0;
};


#line 40
uint2 outSize_0(KernelContext_0 thread* kernelContext_0)
{

#line 40
    texture2d<float, access::write> _S1 = kernelContext_0->out0_0;

#line 40
    thread uint w_0;

#line 40
    thread uint h_0;

#line 40
    (*((&w_0)) = (_S1).get_width(0)),(*((&h_0)) = (_S1).get_height(0));

#line 40
    return uint2(w_0, h_0);
}


#line 41
uint2 inSize_0(KernelContext_0 thread* kernelContext_1)
{

#line 41
    texture2d<float, access::sample> _S2 = kernelContext_1->in0_0;

#line 41
    thread uint w_1;

#line 41
    thread uint h_1;

#line 41
    (*((&w_1)) = (_S2).get_width(0)),(*((&h_1)) = (_S2).get_height(0));

#line 41
    return uint2(w_1, h_1);
}


#line 10 "crates/sq-gpu/shaders-src/DropShadow.slang"
[[kernel]] void shadowExtract(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::write> out0_1 [[texture(25)]], ShadowU_0 constant* su_1 [[buffer(0)]], texture2d<float, access::sample> in0_1 [[texture(0)]], sampler zeroSampler_1 [[sampler(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], sampler edgeSampler_1 [[sampler(1)]])
{

#line 10
    thread KernelContext_0 kernelContext_2;

#line 10
    (&kernelContext_2)->out0_0 = out0_1;

#line 10
    (&kernelContext_2)->su_0 = su_1;

#line 10
    (&kernelContext_2)->in0_0 = in0_1;

#line 10
    (&kernelContext_2)->zeroSampler_0 = zeroSampler_1;

#line 10
    (&kernelContext_2)->in1_0 = in1_1;

#line 10
    (&kernelContext_2)->edgeSampler_0 = edgeSampler_1;

#line 10
    uint2 _S3 = outSize_0(&kernelContext_2);

    uint2 gid_0 = tid_0.xy;

#line 12
    bool _S4;
    if((gid_0.x) >= (_S3.x))
    {

#line 13
        _S4 = true;

#line 13
    }
    else
    {

#line 13
        _S4 = (gid_0.y) >= (_S3.y);

#line 13
    }

#line 13
    if(_S4)
    {

#line 13
        return;
    }

#line 14
    float2 _S5 = (float2(gid_0) + float2(0.5f) ) / float2(_S3);

#line 14
    float2 _S6 = (&kernelContext_2)->su_0->offset_0;

#line 14
    uint2 _S7 = inSize_0(&kernelContext_2);
    (&kernelContext_2)->out0_0.write(float4((((&kernelContext_2)->in0_0).sample(((&kernelContext_2)->zeroSampler_0), (_S5 - _S6 / float2(_S7)), level((0.0f)))).w) ,gid_0);
    return;
}


[[kernel]] void shadowComposite(uint3 tid_1 [[thread_position_in_grid]], texture2d<float, access::write> out0_2 [[texture(25)]], ShadowU_0 constant* su_2 [[buffer(0)]], texture2d<float, access::sample> in0_2 [[texture(0)]], sampler zeroSampler_2 [[sampler(0)]], texture2d<float, access::sample> in1_2 [[texture(1)]], sampler edgeSampler_2 [[sampler(1)]])
{

#line 20
    thread KernelContext_0 kernelContext_3;

#line 20
    (&kernelContext_3)->out0_0 = out0_2;

#line 20
    (&kernelContext_3)->su_0 = su_2;

#line 20
    (&kernelContext_3)->in0_0 = in0_2;

#line 20
    (&kernelContext_3)->zeroSampler_0 = zeroSampler_2;

#line 20
    (&kernelContext_3)->in1_0 = in1_2;

#line 20
    (&kernelContext_3)->edgeSampler_0 = edgeSampler_2;

#line 20
    uint2 _S8 = outSize_0(&kernelContext_3);

    uint2 gid_1 = tid_1.xy;

#line 22
    bool _S9;
    if((gid_1.x) >= (_S8.x))
    {

#line 23
        _S9 = true;

#line 23
    }
    else
    {

#line 23
        _S9 = (gid_1.y) >= (_S8.y);

#line 23
    }

#line 23
    if(_S9)
    {

#line 23
        return;
    }
    float a_0 = min(1.0f, (((&kernelContext_3)->in1_0).sample(((&kernelContext_3)->edgeSampler_0), ((float2(gid_1) + float2(0.5f) ) / float2(_S8)), level((0.0f)))).x / max(1.0f - (&kernelContext_3)->su_0->spread_0, 0.0099999997764825821f)) * (&kernelContext_3)->su_0->color_0.w;
    float4 sh_0 = float4((&kernelContext_3)->su_0->color_0.xyz * float3(a_0) , a_0);
    int3 _S10 = int3(int2(gid_1), int(0));

#line 27
    float4 p_0 = (((&kernelContext_3)->in0_0).read(vec<uint,2>(((_S10)).xy), uint(((_S10)).z)));

#line 27
    float4 _S11;
    if(((&kernelContext_3)->su_0->shadowOnly_0) != int(0))
    {

#line 28
        _S11 = sh_0;

#line 28
    }
    else
    {

#line 28
        _S11 = p_0 + sh_0 * float4((1.0f - p_0.w)) ;

#line 28
    }

#line 28
    (&kernelContext_3)->out0_0.write(_S11,gid_1);
    return;
}

