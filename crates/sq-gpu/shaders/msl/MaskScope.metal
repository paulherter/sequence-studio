#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 5 "crates/sq-gpu/shaders-src/Parts/CompositeU.slang"
struct CompositeU_0
{
    float4 m0_0;
    float4 m1_0;
    float4 m2_0;
    float4 solid_0;
    float4 range_0;
    float2 canvas_0;
    float2 size_0;
    float2 position_0;
    float2 anchor_0;
    float2 scale_0;
    float rotCos_0;
    float rotSin_0;
    float opacity_0;
    uint mode_0;
    uint linearize_0;
    float cornerRadius_0;
    uint quarter_0;
    uint blend_0;
    float2 maskSize_0;
    float4 crop_0;
    float4 key0_0;
    float4 key1_0;
    float4 matte0_0;
    float4 matte1_0;
    float4 shape0_0;
    float4 shape1_0;
    float4 cc0_0;
    float4 cc1_0;
    uint keyCount_0;
    uint roundFirst_0;
    uint alphaMode_0;
    uint maskCount_0;
    float cropFeather_0;
    float4 part_0;
    float4 tilt_0;
};


#line 11 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    CompositeU_0 constant* cu_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in1_0;
    uint32_t device* maskData_0;
    sampler edgeSampler_0;
    texture2d<float, access::sample> in3_0;
    texture2d<float, access::sample> in4_0;
    texture2d<float, access::sample> in5_0;
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


#line 54 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
float3 oetf709_0(float3 l_0)
{

#line 55
    float3 _S2 = max(l_0, float3(0.0f) );

    return select(float3(1.0992968082427979f)  * pow(_S2, float3(0.44999998807907104f) ) - float3(0.099296823143959045f) , _S2 * float3(4.5f) , _S2 < (float3(0.018053969368338585f) ));
}


#line 13 "crates/sq-gpu/shaders-src/Parts/Mask.slang"
float2 maskAt_0(uint i_0, KernelContext_0 thread* kernelContext_1)
{

#line 13
    uint _S3 = 2U * i_0;

#line 13
    uint _S4 = as_type<uint>(kernelContext_1->maskData_0[(uint(int(_S3 * 4U)))>>2]);

#line 13
    float _S5 = (as_type<float>((_S4)));

#line 13
    uint _S6 = as_type<uint>(kernelContext_1->maskData_0[(uint(int((_S3 + 1U) * 4U)))>>2]);

#line 13
    return float2(_S5, (as_type<float>((_S6))));
}


#line 13
float2 maskAt_1(uint i_1, KernelContext_0 thread* kernelContext_2)
{

#line 13
    uint _S7 = 2U * i_1;

#line 13
    uint _S8 = as_type<uint>(kernelContext_2->maskData_0[(uint(int(_S7 * 4U)))>>2]);

#line 13
    float _S9 = (as_type<float>((_S8)));

#line 13
    uint _S10 = as_type<uint>(kernelContext_2->maskData_0[(uint(int((_S7 + 1U) * 4U)))>>2]);

#line 13
    return float2(_S9, (as_type<float>((_S10))));
}


#line 39
float colorRangeValue_0(uint start_0, float3 pc_0, KernelContext_0 thread* kernelContext_3)
{

#line 39
    float2 _S11 = maskAt_1(start_0, kernelContext_3);
    float _S12 = _S11.x;

#line 40
    float2 _S13 = maskAt_1(start_0, kernelContext_3);

#line 40
    float _S14 = _S13.y;

#line 40
    uint _S15 = start_0 + 1U;

#line 40
    float2 _S16 = maskAt_1(_S15, kernelContext_3);

#line 40
    float3 key_0 = float3(_S12, _S14, _S16.x);

#line 40
    float2 _S17 = maskAt_1(_S15, kernelContext_3);
    float tol_0 = _S17.y;

#line 41
    float2 _S18 = maskAt_1(start_0 + 2U, kernelContext_3);

#line 41
    float soft_0 = _S18.x;
    float d_0 = length(pc_0 - key_0) * 0.57735025882720947f;
    if(soft_0 <= 9.99999997475242708e-07f)
    {

#line 43
        float _S19;

#line 43
        if(d_0 <= tol_0)
        {

#line 43
            _S19 = 1.0f;

#line 43
        }
        else
        {

#line 43
            _S19 = 0.0f;

#line 43
        }

#line 43
        return _S19;
    }

#line 44
    float x_0 = clamp((d_0 - tol_0) / soft_0, 0.0f, 1.0f);
    return 1.0f - x_0 * x_0 * (3.0f - 2.0f * x_0);
}


#line 15
float pictureSample_0(float2 p_0, uint start_1, uint flag_0, texture2d<float, access::sample> pm0_0, texture2d<float, access::sample> pm1_0, KernelContext_0 thread* kernelContext_4)
{

#line 15
    float2 _S20 = maskAt_0(start_1, kernelContext_4);

#line 15
    float2 _S21 = maskAt_0(start_1 + 1U, kernelContext_4);

#line 15
    float2 _S22 = maskAt_0(start_1 + 2U, kernelContext_4);

#line 15
    float2 _S23 = maskAt_0(start_1 + 3U, kernelContext_4);

    float2 sp_0 = float2(dot(_S20, p_0), dot(_S21, p_0)) + _S22;

#line 17
    float2 _S24 = maskAt_0(start_1 + 6U, kernelContext_4);
    float focal_0 = _S24.x;

#line 18
    float2 sp_1;
    if(focal_0 > 0.0f)
    {

#line 19
        float2 _S25 = maskAt_0(start_1 + 4U, kernelContext_4);

#line 19
        float2 _S26 = maskAt_0(start_1 + 5U, kernelContext_4);

        float2 v_0 = sp_0 - _S25;
        float _S27 = _S26.x;

#line 22
        float _S28 = _S26.y;

#line 22
        float cb_0 = cos(_S28);

#line 22
        float sb_0 = sin(_S28);
        float _S29 = v_0.y;

#line 23
        float z1_0 = - _S29 * sin(_S27);
        float _S30 = v_0.x;

#line 24
        sp_1 = _S25 + float2(_S30 * cb_0 - z1_0 * sb_0, _S29 * cos(_S27)) / float2(max((focal_0 + _S30 * sb_0 + z1_0 * cb_0) / focal_0, 0.0010000000474974513f)) ;

#line 19
    }
    else
    {

#line 19
        sp_1 = sp_0;

#line 19
    }

#line 27
    float2 uv_0 = sp_1 * _S23;

#line 27
    bool _S31;
    if(any(uv_0 < (float2(0.0f) )))
    {

#line 28
        _S31 = true;

#line 28
    }
    else
    {

#line 28
        _S31 = any(uv_0 > (float2(1.0f) ));

#line 28
    }

#line 28
    if(_S31)
    {

#line 28
        return 0.0f;
    }

#line 29
    uint f_0 = flag_0 - 6U;

#line 29
    float4 s_0;
    if(f_0 < 2U)
    {

#line 30
        s_0 = ((pm0_0).sample((kernelContext_4->edgeSampler_0), (uv_0), level((0.0f))));

#line 30
    }
    else
    {

#line 30
        s_0 = ((pm1_0).sample((kernelContext_4->edgeSampler_0), (uv_0), level((0.0f))));

#line 30
    }
    if((f_0 & 1U) == 0U)
    {

#line 31
        return clamp(s_0.w, 0.0f, 1.0f);
    }

#line 32
    float _S32 = s_0.w;

#line 32
    if(_S32 <= 0.0f)
    {

#line 32
        return 0.0f;
    }
    return clamp(dot(oetf709_0(clamp(s_0.xyz / float3(_S32) , float3(0.0f) , float3(1.0f) )), float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f)) * _S32, 0.0f, 1.0f);
}


#line 48
float maskCombine_0(float acc_0, float c_0, uint mode_1)
{

#line 49
    if(mode_1 == 0U)
    {

#line 49
        return min(acc_0 + c_0, 1.0f);
    }

#line 50
    if(mode_1 == 1U)
    {

#line 50
        return max(acc_0 - c_0, 0.0f);
    }

#line 51
    if(mode_1 == 2U)
    {

#line 51
        return acc_0 * c_0;
    }

#line 52
    return abs(acc_0 - c_0);
}


#line 2798 "core.meta.slang"
float maskCoverage_0(float2 _S33, texture2d<float, access::sample> _S34, texture2d<float, access::sample> _S35, texture2d<float, access::sample> _S36, float3 _S37, KernelContext_0 thread* kernelContext_5)
{

#line 56 "crates/sq-gpu/shaders-src/Parts/Mask.slang"
    float _S38 = 1.0f / max(min(kernelContext_5->cu_0->scale_0.x, kernelContext_5->cu_0->scale_0.y), 9.9999997473787516e-05f);

#line 56
    float acc_1 = 0.0f;

#line 56
    uint m_0 = 0U;

    for(;;)
    {

#line 58
        if(m_0 < (kernelContext_5->cu_0->maskCount_0))
        {
        }
        else
        {

#line 58
            break;
        }

#line 59
        uint _S39 = m_0 * 4U;

#line 59
        float2 _S40 = maskAt_0(_S39, kernelContext_5);

#line 59
        float2 _S41 = maskAt_0(_S39 + 1U, kernelContext_5);

#line 59
        float2 _S42 = maskAt_0(_S39 + 2U, kernelContext_5);

#line 59
        float2 _S43 = maskAt_0(_S39 + 3U, kernelContext_5);
        uint start_2 = uint(_S40.x);

#line 60
        uint count_0 = uint(_S40.y);

#line 60
        uint mode_2 = uint(_S41.x);

#line 60
        bool _S44;
        if(m_0 == 0U)
        {

#line 61
            if(mode_2 == 1U)
            {

#line 61
                _S44 = true;

#line 61
            }
            else
            {

#line 61
                _S44 = mode_2 == 2U;

#line 61
            }

#line 61
        }
        else
        {

#line 61
            _S44 = false;

#line 61
        }

#line 61
        float acc_2;

#line 61
        if(_S44)
        {

#line 61
            acc_2 = 1.0f;

#line 61
        }
        else
        {

#line 61
            acc_2 = acc_1;

#line 61
        }
        float _S45 = _S43.y;

#line 62
        float d2_0;

#line 62
        float c_1;

#line 62
        float c_2;

#line 62
        bool inFrame_0;

#line 62
        bool _S46;

#line 62
        if(_S45 != 0.0f)
        {

#line 62
            float2 _S47 = kernelContext_5->cu_0->maskSize_0;

#line 62
            float2 ms_0;

            if((kernelContext_5->cu_0->maskSize_0.x) > 0.0f)
            {

#line 64
                ms_0 = _S47;

#line 64
            }
            else
            {

#line 64
                ms_0 = kernelContext_5->cu_0->size_0;

#line 64
            }
            float2 uv_1 = _S33 / ms_0 + float2(0.5f) ;
            if(all(uv_1 >= (float2(0.0f) )))
            {

#line 66
                inFrame_0 = all(uv_1 <= (float2(1.0f) ));

#line 66
            }
            else
            {

#line 66
                inFrame_0 = false;

#line 66
            }


            if(_S45 == 10.0f)
            {

#line 69
                float _S48 = colorRangeValue_0(start_2, _S37, kernelContext_5);

#line 69
                c_1 = _S48;

#line 69
            }
            else
            {

#line 70
                if(_S45 >= 6.0f)
                {

#line 70
                    float _S49 = pictureSample_0(_S33, start_2, uint(_S45), _S35, _S36, kernelContext_5);

#line 70
                    c_1 = _S49;

#line 70
                }
                else
                {

#line 71
                    if(_S45 != 2.0f)
                    {

#line 71
                        _S46 = inFrame_0;

#line 71
                    }
                    else
                    {

#line 71
                        _S46 = false;

#line 71
                    }

#line 71
                    if(_S46)
                    {

#line 72
                        float4 s_1 = ((_S34).sample((kernelContext_5->edgeSampler_0), (uv_1), level((0.0f))));
                        if(_S45 == 1.0f)
                        {

#line 73
                            d2_0 = s_1.x;

#line 73
                        }
                        else
                        {

#line 73
                            if(_S45 == 3.0f)
                            {

#line 73
                                d2_0 = s_1.y;

#line 73
                            }
                            else
                            {

#line 73
                                if(_S45 == 4.0f)
                                {

#line 73
                                    d2_0 = s_1.z;

#line 73
                                }
                                else
                                {

#line 73
                                    d2_0 = s_1.w;

#line 73
                                }

#line 73
                            }

#line 73
                        }

#line 73
                        c_1 = clamp(d2_0, 0.0f, 1.0f);

#line 71
                    }
                    else
                    {

#line 71
                        c_1 = 0.0f;

#line 71
                    }

#line 70
                }

#line 69
            }

#line 75
            if((_S41.y) != 0.0f)
            {

#line 75
                c_2 = 1.0f - c_1;

#line 75
            }
            else
            {

#line 75
                c_2 = c_1;

#line 75
            }

#line 75
            acc_1 = maskCombine_0(acc_2, c_2 * _S43.x, mode_2);


            m_0 = m_0 + 1U;

#line 58
            continue;
        }

#line 58
        float d_1;

#line 82
        if(count_0 >= 2U)
        {

#line 83
            uint _S50 = start_2 + count_0;

#line 83
            uint j_0 = _S50 - 1U;

#line 83
            d2_0 = 1.00000001504746622e+30f;

#line 83
            inFrame_0 = false;

#line 83
            uint i_2 = start_2;
            for(;;)
            {

#line 84
                if(i_2 < _S50)
                {
                }
                else
                {

#line 84
                    break;
                }

#line 84
                float2 _S51 = maskAt_0(j_0, kernelContext_5);

#line 84
                float2 _S52 = maskAt_0(i_2, kernelContext_5);

                float2 e_0 = _S52 - _S51;

#line 86
                float2 w_1 = _S33 - _S51;
                float ee_0 = dot(e_0, e_0);
                if(ee_0 > 0.0f)
                {

#line 88
                    d_1 = clamp(dot(w_1, e_0) / ee_0, 0.0f, 1.0f);

#line 88
                }
                else
                {

#line 88
                    d_1 = 0.0f;

#line 88
                }
                float2 q_0 = w_1 - e_0 * float2(d_1) ;
                float _S53 = min(d2_0, dot(q_0, q_0));
                float _S54 = _S52.y;

#line 91
                float _S55 = _S33.y;

#line 91
                float _S56 = _S51.y;

#line 91
                if((_S54 > _S55) != (_S56 > _S55))
                {

#line 91
                    float _S57 = _S52.x;

#line 91
                    _S46 = (_S33.x) < ((_S51.x - _S57) * (_S55 - _S54) / (_S56 - _S54) + _S57);

#line 91
                }
                else
                {

#line 91
                    _S46 = false;

#line 91
                }

#line 91
                if(_S46)
                {

#line 91
                    inFrame_0 = !inFrame_0;

#line 91
                }

#line 84
                uint _S58 = i_2 + 1U;

#line 84
                j_0 = i_2;

#line 84
                i_2 = _S58;

#line 84
                d2_0 = _S53;

#line 84
            }

#line 82
        }
        else
        {

#line 82
            d2_0 = 1.00000001504746622e+30f;

#line 82
            inFrame_0 = false;

#line 82
        }

#line 95
        float d_2 = sqrt(d2_0);
        if(inFrame_0)
        {

#line 96
            d_1 = - d_2;

#line 96
        }
        else
        {

#line 96
            d_1 = d_2;

#line 96
        }
        float d_3 = d_1 - _S42.y;

        float _S59 = _S42.x;

#line 99
        if(_S59 > _S38)
        {

#line 100
            float hh_0 = _S59 * 0.5f;
            float x_1 = clamp((d_3 + hh_0) / (2.0f * hh_0), 0.0f, 1.0f);

#line 101
            c_1 = 1.0f - x_1 * x_1 * (3.0f - 2.0f * x_1);

#line 99
        }
        else
        {

#line 99
            c_1 = clamp(0.5f - d_3 / _S38, 0.0f, 1.0f);

#line 99
        }

#line 106
        if((_S41.y) != 0.0f)
        {

#line 106
            c_2 = 1.0f - c_1;

#line 106
        }
        else
        {

#line 106
            c_2 = c_1;

#line 106
        }

#line 106
        acc_1 = maskCombine_0(acc_2, c_2 * _S43.x, mode_2);

#line 58
        m_0 = m_0 + 1U;

#line 58
    }

#line 110
    return acc_1;
}


#line 15 "crates/sq-gpu/shaders-src/MaskScope.slang"
[[kernel]] void maskScopeMix(uint3 tid_0 [[thread_position_in_grid]], CompositeU_0 constant* cu_1 [[buffer(0)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], uint32_t device* maskData_1 [[buffer(2)]], sampler edgeSampler_1 [[sampler(1)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture2d<float, access::sample> in4_1 [[texture(4)]], texture2d<float, access::sample> in5_1 [[texture(5)]])
{

#line 15
    thread KernelContext_0 kernelContext_6;

#line 15
    (&kernelContext_6)->cu_0 = cu_1;

#line 15
    (&kernelContext_6)->out0_0 = out0_1;

#line 15
    (&kernelContext_6)->in0_0 = in0_1;

#line 15
    (&kernelContext_6)->in1_0 = in1_1;

#line 15
    (&kernelContext_6)->maskData_0 = maskData_1;

#line 15
    (&kernelContext_6)->edgeSampler_0 = edgeSampler_1;

#line 15
    (&kernelContext_6)->in3_0 = in3_1;

#line 15
    (&kernelContext_6)->in4_0 = in4_1;

#line 15
    (&kernelContext_6)->in5_0 = in5_1;

#line 15
    uint2 _S60 = outSize_0(&kernelContext_6);


    uint2 gid_0 = tid_0.xy;

#line 18
    bool _S61;
    if((gid_0.x) >= (_S60.x))
    {

#line 19
        _S61 = true;

#line 19
    }
    else
    {

#line 19
        _S61 = (gid_0.y) >= (_S60.y);

#line 19
    }

#line 19
    if(_S61)
    {

#line 19
        return;
    }

#line 19
    float2 _S62 = float2(0.5f) ;
    float2 p_1 = float2(gid_0) + _S62 - _S62 * float2(_S60);
    int3 _S63 = int3(int2(gid_0), int(0));

#line 21
    float4 a_0 = (((&kernelContext_6)->in0_0).read(vec<uint,2>(((_S63)).xy), uint(((_S63)).z)));

#line 21
    float4 b_0 = (((&kernelContext_6)->in1_0).read(vec<uint,2>(((_S63)).xy), uint(((_S63)).z)));
    float _S64 = a_0.w;

#line 22
    float3 pc_1;

#line 22
    if(_S64 > 0.0f)
    {

#line 22
        pc_1 = oetf709_0(clamp(a_0.xyz / float3(_S64) , float3(0.0f) , float3(1.0f) ));

#line 22
    }
    else
    {

#line 22
        pc_1 = float3(0.0f) ;

#line 22
    }

#line 22
    float _S65 = maskCoverage_0(p_1, (&kernelContext_6)->in3_0, (&kernelContext_6)->in4_0, (&kernelContext_6)->in5_0, pc_1, &kernelContext_6);

    (&kernelContext_6)->out0_0.write(a_0 + (b_0 - a_0) * float4(_S65) ,gid_0);
    return;
}

