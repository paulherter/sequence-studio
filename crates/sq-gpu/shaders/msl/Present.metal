#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 90 "core"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 90
struct pixelInput_0
{
    float2 uv_0 [[user(UV)]];
};


#line 4 "crates/sq-gpu/shaders-src/Present.slang"
struct PresentU_0
{
    float4 m0_0;
    float4 m1_0;
    float4 m2_0;
    float mode_0;
    float peak_0;
    float knee_0;
    float exponent_0;
    uint nearest_0;
};


#line 37 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    PresentU_0 constant* pu_0;
    texture2d<float, access::sample> in0_0;
    sampler nearestSampler_0;
    sampler edgeSampler_0;
};


#line 29 "crates/sq-gpu/shaders-src/Present.slang"
[[fragment]] pixelOutput_0 presentFragment(pixelInput_0 _S1 [[stage_in]], float4 position_0 [[position]], PresentU_0 constant* pu_1 [[buffer(0)]], texture2d<float, access::sample> in0_1 [[texture(0)]], sampler nearestSampler_1 [[sampler(2)]], sampler edgeSampler_1 [[sampler(1)]])
{

#line 29
    thread KernelContext_0 kernelContext_0;

#line 29
    (&kernelContext_0)->pu_0 = pu_1;

#line 29
    (&kernelContext_0)->in0_0 = in0_1;

#line 29
    (&kernelContext_0)->nearestSampler_0 = nearestSampler_1;

#line 29
    (&kernelContext_0)->edgeSampler_0 = edgeSampler_1;
    PresentU_0 v_0 = *pu_1;

#line 30
    float4 px_0;
    if(((*pu_1).nearest_0) != 0U)
    {

#line 31
        px_0 = (((&kernelContext_0)->in0_0).sample(((&kernelContext_0)->nearestSampler_0), (_S1.uv_0), level((0.0f))));

#line 31
    }
    else
    {

#line 31
        px_0 = (((&kernelContext_0)->in0_0).sample(((&kernelContext_0)->edgeSampler_0), (_S1.uv_0), level((0.0f))));

#line 31
    }
    float3 _S2 = px_0.xyz;

#line 32
    float3 lin_0;
    if((v_0.mode_0) != 0.0f)
    {

#line 33
        lin_0 = max(v_0.m0_0.xyz * float3(px_0.x)  + v_0.m1_0.xyz * float3(px_0.y)  + v_0.m2_0.xyz * float3(px_0.z) , float3(0.0f) );

#line 33
    }
    else
    {

#line 33
        lin_0 = _S2;

#line 33
    }

    bool _S3 = (v_0.mode_0) < 1.5f;

#line 35
    float3 code_0;

#line 35
    float checker_0;

#line 35
    if(_S3)
    {

#line 36
        float3 _S4 = max(lin_0, float3(0.0f) );
        float3 code_1 = saturate(select(float3(1.0992968082427979f)  * pow(_S4, float3(0.44999998807907104f) ) - float3(0.099296823143959045f) , float3(4.5f)  * _S4, _S4 < (float3(0.018053969368338585f) )));
        if((v_0.exponent_0) != 1.0f)
        {

#line 38
            code_0 = pow(code_1, float3(v_0.exponent_0) );

#line 38
        }
        else
        {

#line 38
            code_0 = code_1;

#line 38
        }

#line 35
    }
    else
    {



        float _S5 = max(lin_0.x, max(lin_0.y, lin_0.z));

#line 41
        bool _S6;
        if((v_0.mode_0) == 2.0f)
        {

#line 42
            _S6 = _S5 > 0.0f;

#line 42
        }
        else
        {

#line 42
            _S6 = false;

#line 42
        }

#line 42
        if(_S6)
        {

#line 43
            float m_0 = _S5 / v_0.peak_0;
            if(m_0 > (v_0.knee_0))
            {

#line 44
                float r_0 = 1.0f - v_0.knee_0;

#line 44
                checker_0 = v_0.knee_0 + r_0 * (1.0f - exp(- (m_0 - v_0.knee_0) / r_0));

#line 44
            }
            else
            {

#line 44
                checker_0 = m_0;

#line 44
            }

#line 44
            code_0 = lin_0 * float3((checker_0 * v_0.peak_0 / _S5)) ;

#line 42
        }
        else
        {

#line 42
            code_0 = lin_0;

#line 42
        }

#line 35
    }

#line 50
    float a_0 = saturate(px_0.w);
    if(a_0 < 1.0f)
    {

#line 52
        uint2 cell_0 = uint2(position_0.xy) / uint2(16U) ;
        if(((cell_0.x + cell_0.y) & 1U) == 0U)
        {

#line 53
            checker_0 = 0.20000000298023224f;

#line 53
        }
        else
        {

#line 53
            checker_0 = 0.31999999284744263f;

#line 53
        }

#line 53
        code_0 = code_0 + float3(((1.0f - a_0) * checker_0)) ;

#line 51
    }

#line 56
    if(_S3)
    {

#line 56
        lin_0 = saturate(code_0);

#line 56
    }
    else
    {

#line 56
        lin_0 = code_0;

#line 56
    }

#line 56
    pixelOutput_0 _S7 = { float4(lin_0, 1.0f) };

#line 56
    return _S7;
}


#line 56
struct presentVertex_Result_0
{
    float4 position_1 [[position]];
    float2 uv_1 [[user(UV)]];
};


#line 14
struct PresentOut_0
{
    float4 position_2;
    float2 uv_2;
};


#line 14
[[vertex]] presentVertex_Result_0 presentVertex(uint vid_0 [[vertex_id]], PresentU_0 constant* pu_2 [[buffer(0)]], texture2d<float, access::sample> in0_2 [[texture(0)]], sampler nearestSampler_2 [[sampler(2)]], sampler edgeSampler_2 [[sampler(1)]])
{

#line 14
    thread KernelContext_0 kernelContext_1;

#line 14
    (&kernelContext_1)->pu_0 = pu_2;

#line 14
    (&kernelContext_1)->in0_0 = in0_2;

#line 14
    (&kernelContext_1)->nearestSampler_0 = nearestSampler_2;

#line 14
    (&kernelContext_1)->edgeSampler_0 = edgeSampler_2;

#line 21
    float _S8 = float((vid_0 << 1U) & 2U);

#line 21
    float _S9 = float(vid_0 & 2U);
    thread PresentOut_0 o_0;
    (&o_0)->position_2 = float4(float2(_S8, _S9) * float2(2.0f)  - float2(1.0f) , 0.0f, 1.0f);
    (&o_0)->uv_2 = float2(_S8, 1.0f - _S9);

#line 24
    thread presentVertex_Result_0 _S10;

#line 24
    (&_S10)->position_1 = o_0.position_2;

#line 24
    (&_S10)->uv_1 = o_0.uv_2;

#line 24
    return _S10;
}

