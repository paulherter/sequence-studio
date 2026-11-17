#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 3 "crates/sq-gpu/shaders-src/SpatialDenoise.slang"
struct SpatialU_0
{
    int radius_0;
    int step_0;
    float lumaS_0;
    float colorS_0;
    uint linearize_0;
    uint pad0_0;
    uint pad1_0;
    uint pad2_0;
};


#line 6 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    SpatialU_0 constant* su_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
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


#line 42
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S2 = int3(p_0, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S2)).xy), uint(((_S2)).z)));
}


#line 3 "crates/sq-gpu/shaders-src/Parts/YCC.slang"
float3 toYCC_0(float3 c_0)
{

#line 4
    float y_0 = dot(c_0, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f));
    return float3(y_0, (c_0.z - y_0) / 1.8555999994277954f, (c_0.x - y_0) / 1.5748000144958496f);
}


#line 7
float3 fromYCC_0(float3 v_0)
{

#line 8
    float _S3 = v_0.x;

#line 8
    float r_0 = _S3 + 1.5748000144958496f * v_0.z;

#line 8
    float b_0 = _S3 + 1.8555999994277954f * v_0.y;

    return float3(r_0, (_S3 - 0.2125999927520752f * r_0 - 0.072200000286102295f * b_0) / 0.71520000696182251f, b_0);
}


#line 11 "crates/sq-gpu/shaders-src/SpatialDenoise.slang"
float3 inverseOETF709_0(float3 e_0)
{

#line 12
    float3 _S4 = max(e_0, float3(0.0f) );
    return select(pow((_S4 + float3(0.099296823143959045f) ) / float3(1.0992968082427979f) , float3(2.2222223281860352f) ), _S4 / float3(4.5f) , _S4 < (float3(0.081242859363555908f) ));
}




[[kernel]] void spatialDenoise(uint3 tid_0 [[thread_position_in_grid]], SpatialU_0 constant* su_1 [[buffer(0)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]])
{

#line 19
    thread KernelContext_0 kernelContext_2;

#line 19
    (&kernelContext_2)->su_0 = su_1;

#line 19
    (&kernelContext_2)->out0_0 = out0_1;

#line 19
    (&kernelContext_2)->in0_0 = in0_1;
    SpatialU_0 s_0 = *su_1;

#line 20
    uint2 _S5 = outSize_0(&kernelContext_2);

    uint2 gid_0 = tid_0.xy;

#line 22
    bool _S6;
    if((gid_0.x) >= (_S5.x))
    {

#line 23
        _S6 = true;

#line 23
    }
    else
    {

#line 23
        _S6 = (gid_0.y) >= (_S5.y);

#line 23
    }

#line 23
    if(_S6)
    {

#line 23
        return;
    }

#line 24
    int2 _S7 = int2(gid_0);

#line 24
    float4 _S8 = read0_0(_S7, &kernelContext_2);
    float3 yc0_0 = toYCC_0(_S8.xyz);
    float _S9 = yc0_0.x;
    float2 _S10 = yc0_0.yz;

#line 27
    int _S11 = s_0.radius_0;
    float _S12 = float(_S11 * _S11) + 1.0f;
    int _S13 = - s_0.radius_0;

#line 29
    int j_0 = _S13;

#line 29
    float accY_0 = _S9;

#line 29
    float wy_0 = 1.0f;

#line 29
    float2 accC_0 = _S10;

#line 29
    float wc_0 = 1.0f;

#line 29
    for(;;)
    {

#line 29
        if(j_0 <= (s_0.radius_0))
        {
        }
        else
        {

#line 29
            break;
        }

#line 29
        int i_0 = _S13;

#line 29
        float accY_1 = accY_0;

#line 29
        float wy_1 = wy_0;

#line 29
        float2 accC_1 = accC_0;

#line 29
        float wc_1 = wc_0;
        for(;;)
        {

#line 30
            if(i_0 <= (s_0.radius_0))
            {
            }
            else
            {

#line 30
                break;
            }

#line 31
            if(i_0 == int(0))
            {

#line 31
                _S6 = j_0 == int(0);

#line 31
            }
            else
            {

#line 31
                _S6 = false;

#line 31
            }

#line 31
            if(_S6)
            {

#line 31
                i_0 = i_0 + int(1);

#line 30
                continue;
            }

#line 30
            float4 _S14 = read0_0(clamp(_S7 + int2(i_0, j_0) * int2(s_0.step_0) , int2(int(0)) , int2(_S5) - int2(int(1)) ), &kernelContext_2);


            float3 yc_0 = toYCC_0(_S14.xyz);
            float sw_0 = exp(- float(i_0 * i_0 + j_0 * j_0) / _S12);
            float _S15 = yc_0.x;

#line 35
            float dy_0 = _S15 - _S9;

#line 35
            float2 _S16 = yc_0.yz;

#line 35
            float dc_0 = length(_S16 - _S10);

#line 35
            float a_0;
            if((s_0.lumaS_0) > 0.0f)
            {

#line 36
                a_0 = sw_0 * max(0.0f, 1.0f - dy_0 * dy_0 / (s_0.lumaS_0 * s_0.lumaS_0));

#line 36
            }
            else
            {

#line 36
                a_0 = 0.0f;

#line 36
            }

#line 36
            float b_1;
            if((s_0.colorS_0) > 0.0f)
            {

#line 37
                b_1 = sw_0 * max(0.0f, 1.0f - dc_0 * dc_0 / (s_0.colorS_0 * s_0.colorS_0));

#line 37
            }
            else
            {

#line 37
                b_1 = 0.0f;

#line 37
            }
            float wy_2 = wy_1 + a_0;
            float2 accC_2 = accC_1 + _S16 * float2(b_1) ;

#line 39
            float wc_2 = wc_1 + b_1;

#line 39
            accY_1 = accY_1 + _S15 * a_0;

#line 39
            wy_1 = wy_2;

#line 39
            accC_1 = accC_2;

#line 39
            wc_1 = wc_2;

#line 30
            i_0 = i_0 + int(1);

#line 30
        }

#line 29
        j_0 = j_0 + int(1);

#line 29
        accY_0 = accY_1;

#line 29
        wy_0 = wy_1;

#line 29
        accC_0 = accC_1;

#line 29
        wc_0 = wc_1;

#line 29
    }

#line 42
    float3 res_0 = fromYCC_0(float3(accY_0 / wy_0, accC_0 / float2(wc_0) ));

#line 42
    float3 res_1;
    if((s_0.linearize_0) != 0U)
    {

#line 43
        res_1 = inverseOETF709_0(res_0);

#line 43
    }
    else
    {

#line 43
        res_1 = res_0;

#line 43
    }
    (&kernelContext_2)->out0_0.write(float4(res_1, _S8.w),gid_0);
    return;
}

