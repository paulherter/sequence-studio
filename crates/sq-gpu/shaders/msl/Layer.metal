#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 7 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
uint2 texSize_0(texture2d<float, access::sample> t_0)
{

#line 7
    thread uint w_0;

#line 7
    thread uint h_0;

#line 7
    (*((&w_0)) = (t_0).get_width(0)),(*((&h_0)) = (t_0).get_height(0));

#line 7
    return uint2(w_0, h_0);
}


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


#line 12 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    CompositeU_0 constant* cu_0;
    sampler zeroSampler_0;
    sampler edgeSampler_0;
    uint32_t device* maskData_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in1_0;
    texture2d<float, access::sample> in3_0;
    texture2d<float, access::sample> in4_0;
    texture2d<float, access::sample> in5_0;
    texture2d<float, access::sample> in6_0;
};


#line 86 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
float4 samplePartTexels_0(texture2d<float, access::sample> t_1, float2 p_0, KernelContext_0 thread* kernelContext_0)
{

#line 86
    return ((t_1).sample((kernelContext_0->zeroSampler_0), (p_0 / float2(texSize_0(t_1))), level((0.0f))));
}


#line 54 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
float3 oetf709_0(float3 l_0)
{

#line 55
    float3 _S1 = max(l_0, float3(0.0f) );

    return select(float3(1.0992968082427979f)  * pow(_S1, float3(0.44999998807907104f) ) - float3(0.099296823143959045f) , _S1 * float3(4.5f) , _S1 < (float3(0.018053969368338585f) ));
}


#line 13 "crates/sq-gpu/shaders-src/Parts/Mask.slang"
float2 maskAt_0(uint i_0, KernelContext_0 thread* kernelContext_1)
{

#line 13
    uint _S2 = 2U * i_0;

#line 13
    uint _S3 = as_type<uint>(kernelContext_1->maskData_0[(uint(int(_S2 * 4U)))>>2]);

#line 13
    float _S4 = (as_type<float>((_S3)));

#line 13
    uint _S5 = as_type<uint>(kernelContext_1->maskData_0[(uint(int((_S2 + 1U) * 4U)))>>2]);

#line 13
    return float2(_S4, (as_type<float>((_S5))));
}


#line 13
float2 maskAt_1(uint i_1, KernelContext_0 thread* kernelContext_2)
{

#line 13
    uint _S6 = 2U * i_1;

#line 13
    uint _S7 = as_type<uint>(kernelContext_2->maskData_0[(uint(int(_S6 * 4U)))>>2]);

#line 13
    float _S8 = (as_type<float>((_S7)));

#line 13
    uint _S9 = as_type<uint>(kernelContext_2->maskData_0[(uint(int((_S6 + 1U) * 4U)))>>2]);

#line 13
    return float2(_S8, (as_type<float>((_S9))));
}


#line 39
float colorRangeValue_0(uint start_0, float3 pc_0, KernelContext_0 thread* kernelContext_3)
{

#line 39
    float2 _S10 = maskAt_1(start_0, kernelContext_3);
    float _S11 = _S10.x;

#line 40
    float2 _S12 = maskAt_1(start_0, kernelContext_3);

#line 40
    float _S13 = _S12.y;

#line 40
    uint _S14 = start_0 + 1U;

#line 40
    float2 _S15 = maskAt_1(_S14, kernelContext_3);

#line 40
    float3 key_0 = float3(_S11, _S13, _S15.x);

#line 40
    float2 _S16 = maskAt_1(_S14, kernelContext_3);
    float tol_0 = _S16.y;

#line 41
    float2 _S17 = maskAt_1(start_0 + 2U, kernelContext_3);

#line 41
    float soft_0 = _S17.x;
    float d_0 = length(pc_0 - key_0) * 0.57735025882720947f;
    if(soft_0 <= 9.99999997475242708e-07f)
    {

#line 43
        float _S18;

#line 43
        if(d_0 <= tol_0)
        {

#line 43
            _S18 = 1.0f;

#line 43
        }
        else
        {

#line 43
            _S18 = 0.0f;

#line 43
        }

#line 43
        return _S18;
    }

#line 44
    float x_0 = clamp((d_0 - tol_0) / soft_0, 0.0f, 1.0f);
    return 1.0f - x_0 * x_0 * (3.0f - 2.0f * x_0);
}


#line 15
float pictureSample_0(float2 p_1, uint start_1, uint flag_0, texture2d<float, access::sample> pm0_0, texture2d<float, access::sample> pm1_0, KernelContext_0 thread* kernelContext_4)
{

#line 15
    float2 _S19 = maskAt_0(start_1, kernelContext_4);

#line 15
    float2 _S20 = maskAt_0(start_1 + 1U, kernelContext_4);

#line 15
    float2 _S21 = maskAt_0(start_1 + 2U, kernelContext_4);

#line 15
    float2 _S22 = maskAt_0(start_1 + 3U, kernelContext_4);

    float2 sp_0 = float2(dot(_S19, p_1), dot(_S20, p_1)) + _S21;

#line 17
    float2 _S23 = maskAt_0(start_1 + 6U, kernelContext_4);
    float focal_0 = _S23.x;

#line 18
    float2 sp_1;
    if(focal_0 > 0.0f)
    {

#line 19
        float2 _S24 = maskAt_0(start_1 + 4U, kernelContext_4);

#line 19
        float2 _S25 = maskAt_0(start_1 + 5U, kernelContext_4);

        float2 v_0 = sp_0 - _S24;
        float _S26 = _S25.x;

#line 22
        float _S27 = _S25.y;

#line 22
        float cb_0 = cos(_S27);

#line 22
        float sb_0 = sin(_S27);
        float _S28 = v_0.y;

#line 23
        float z1_0 = - _S28 * sin(_S26);
        float _S29 = v_0.x;

#line 24
        sp_1 = _S24 + float2(_S29 * cb_0 - z1_0 * sb_0, _S28 * cos(_S26)) / float2(max((focal_0 + _S29 * sb_0 + z1_0 * cb_0) / focal_0, 0.0010000000474974513f)) ;

#line 19
    }
    else
    {

#line 19
        sp_1 = sp_0;

#line 19
    }

#line 27
    float2 uv_0 = sp_1 * _S22;

#line 27
    bool _S30;
    if(any(uv_0 < (float2(0.0f) )))
    {

#line 28
        _S30 = true;

#line 28
    }
    else
    {

#line 28
        _S30 = any(uv_0 > (float2(1.0f) ));

#line 28
    }

#line 28
    if(_S30)
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
    float _S31 = s_0.w;

#line 32
    if(_S31 <= 0.0f)
    {

#line 32
        return 0.0f;
    }
    return clamp(dot(oetf709_0(clamp(s_0.xyz / float3(_S31) , float3(0.0f) , float3(1.0f) )), float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f)) * _S31, 0.0f, 1.0f);
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


#line 11 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
float shapeMatte_0(float kk_0, float4 m_0, float4 sh_0)
{
    float _S32 = m_0.y;

#line 13
    float r_0;

#line 13
    if(_S32 > 0.0f)
    {

#line 13
        r_0 = clamp((kk_0 - _S32) / max(1.0f - _S32, 9.9999997473787516e-05f), 0.0f, 1.0f);

#line 13
    }
    else
    {

#line 13
        r_0 = kk_0;

#line 13
    }
    float _S33 = m_0.x;

#line 14
    bool _S34;

#line 14
    if(_S33 != 0.0f)
    {

#line 14
        _S34 = true;

#line 14
    }
    else
    {

#line 14
        _S34 = (sh_0.x) > 0.0f;

#line 14
    }

#line 14
    if(_S34)
    {

#line 15
        float c_1 = 1.0f - r_0;

#line 15
        float c_2;
        if(_S33 > 0.0f)
        {

#line 17
            float s_1 = 0.89999997615814209f * min(_S33, 1.0f);

#line 17
            c_2 = clamp((c_1 - s_1) / max(1.0f - s_1, 9.9999997473787516e-05f), 0.0f, 1.0f);

#line 16
        }
        else
        {
            if(_S33 < 0.0f)
            {

#line 19
                c_2 = min(c_1 / max(1.0f - 0.89999997615814209f * min(- _S33, 1.0f), 9.9999997473787516e-05f), 1.0f);

#line 19
            }
            else
            {

#line 19
                c_2 = c_1;

#line 19
            }

#line 16
        }

#line 23
        float _S35 = sh_0.x;

#line 23
        if(_S35 > 0.0f)
        {

#line 23
            float _S36 = sh_0.y;

#line 23
            c_2 = clamp((c_2 - _S36) * (1.0f + 9.0f * min(_S35, 1.0f)) + _S36, 0.0f, 1.0f);

#line 23
        }

#line 23
        r_0 = 1.0f - c_2;

#line 14
    }

#line 26
    return r_0;
}

float applyChromaKey_0(float4 k_0, float4 matte_0, float4 sh_1, float4 cc_0, float3 thread* c_3)
{

#line 30
    if((matte_0.z) == 2.0f)
    {

#line 30
        return 0.0f;
    }

#line 30
    float yy_0;

#line 30
    float tt_0;
    if((matte_0.w) == 1.0f)
    {

#line 32
        float y_0 = sqrt(clamp(dot(*c_3, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f)), 0.0f, 1.0f));
        bool br_0 = (k_0.z) > 0.5f;
        if(br_0)
        {

#line 34
            yy_0 = 1.0f - y_0;

#line 34
        }
        else
        {

#line 34
            yy_0 = y_0;

#line 34
        }
        if(br_0)
        {

#line 35
            tt_0 = 1.0f - k_0.x;

#line 35
        }
        else
        {

#line 35
            tt_0 = k_0.x;

#line 35
        }
        return shapeMatte_0(1.0f - smoothstep(tt_0, tt_0 + max(k_0.y, 9.9999997473787516e-05f), yy_0), matte_0, sh_1);
    }
    float _S37 = max((*c_3).x, max((*c_3).y, (*c_3).z));

#line 38
    float d_1 = _S37 - min((*c_3).x, min((*c_3).y, (*c_3).z));

    if(d_1 > 0.0f)
    {

#line 41
        if(_S37 == ((*c_3).x))
        {

#line 41
            yy_0 = fmod(((*c_3).y - (*c_3).z) / d_1, 6.0f);

#line 41
        }
        else
        {

#line 42
            if(_S37 == ((*c_3).y))
            {

#line 42
                yy_0 = ((*c_3).z - (*c_3).x) / d_1 + 2.0f;

#line 42
            }
            else
            {

#line 42
                yy_0 = ((*c_3).x - (*c_3).y) / d_1 + 4.0f;

#line 42
            }

#line 41
        }


        float h_1 = yy_0 * 60.0f;
        if(h_1 < 0.0f)
        {

#line 45
            yy_0 = h_1 + 360.0f;

#line 45
        }
        else
        {

#line 45
            yy_0 = h_1;

#line 45
        }

#line 40
    }
    else
    {

#line 40
        yy_0 = 0.0f;

#line 40
    }

#line 47
    if(_S37 > 0.0f)
    {

#line 47
        tt_0 = d_1 / _S37;

#line 47
    }
    else
    {

#line 47
        tt_0 = 0.0f;

#line 47
    }
    float dist_0 = abs(yy_0 - k_0.x);
    float _S38 = min(dist_0, 360.0f - dist_0);
    float weight_0 = smoothstep(0.079999998211860657f, 0.30000001192092896f, tt_0) * smoothstep(0.0010000000474974513f, 0.0099999997764825821f, _S37);
    float _S39 = k_0.y;

#line 51
    float _S40 = k_0.z;

#line 51
    float _S41 = _S39 + _S40;
    float raw_0 = (1.0f - smoothstep(_S39, _S41, _S38)) * weight_0;
    float _S42 = sh_1.z;

#line 53
    bool _S43;

#line 53
    if(_S42 > 0.0f)
    {

#line 53
        _S43 = true;

#line 53
    }
    else
    {

#line 53
        _S43 = (sh_1.w) > 0.0f;

#line 53
    }

#line 53
    float raw_1;

#line 53
    if(_S43)
    {

#line 53
        raw_1 = raw_0 * (1.0f - min(_S42 * smoothstep(0.5f, 1.0f, _S37) + sh_1.w * (1.0f - smoothstep(0.019999999552965164f, 0.30000001192092896f, _S37)), 1.0f));

#line 53
    }
    else
    {

#line 53
        raw_1 = raw_0;

#line 53
    }



    float key_1 = shapeMatte_0(raw_1, matte_0, sh_1);


    float3 _S44 = float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f);
    *c_3 = *c_3 + (float3(dot(*c_3, _S44))  - *c_3) * float3((k_0.w * (1.0f - smoothstep(_S41, 2.0f * _S39 + _S40 + cc_0.w * 40.0f, _S38)) * weight_0 * (1.0f - raw_1))) ;
    float _S45 = cc_0.x;

#line 62
    if(_S45 != 1.0f)
    {

#line 62
        _S43 = true;

#line 62
    }
    else
    {

#line 62
        _S43 = (cc_0.y) != 0.0f;

#line 62
    }

#line 62
    if(_S43)
    {

#line 62
        _S43 = true;

#line 62
    }
    else
    {

#line 62
        _S43 = (cc_0.z) != 1.0f;

#line 62
    }

#line 62
    if(_S43)
    {
        float3 _S46 = float3(dot(*c_3, _S44)) ;

#line 64
        *c_3 = _S46 + (*c_3 - _S46) * float3(_S45) ;
        float _S47 = cc_0.y;

#line 65
        if(_S47 != 0.0f)
        {

#line 66
            float cs_0 = cos(_S47);
            float3 ax_0 = float3(0.57735025882720947f) ;
            *c_3 = *c_3 * float3(cs_0)  + cross(ax_0, *c_3) * float3(sin(_S47))  + ax_0 * float3((dot(ax_0, *c_3) * (1.0f - cs_0))) ;

#line 65
        }

#line 70
        *c_3 = *c_3 * float3(cc_0.z) ;

#line 62
    }

#line 72
    return key_1;
}


#line 46 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
float3 inverseOETF709_0(float3 e_0)
{

#line 47
    float3 _S48 = max(e_0, float3(0.0f) );


    return select(pow((_S48 + float3(0.099296823143959045f) ) / float3(1.0992968082427979f) , float3(2.2222223281860352f) ), _S48 / float3(4.5f) , _S48 < (float3(0.081242859363555908f) ));
}


#line 50
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 50
struct pixelInput_0
{
    float2 local_0 [[user(LOCAL)]];
};


#line 5 "crates/sq-gpu/shaders-src/Parts/LayerVertex.slang"
struct VOut_0
{
    float4 position_1;
    float2 local_1;
};


#line 5
bool hasCrop_0(KernelContext_0 thread* kernelContext_5)
{

#line 12
    return any((kernelContext_5->cu_0->crop_0) != (float4(0.0f) ));
}


#line 12
bool edgeAA_0(KernelContext_0 thread* kernelContext_6)
{

#line 12
    bool _S49;

    if((kernelContext_6->cu_0->cornerRadius_0) > 0.0f)
    {

#line 14
        _S49 = true;

#line 14
    }
    else
    {

#line 14
        _S49 = (kernelContext_6->cu_0->rotSin_0) != 0.0f;

#line 14
    }

#line 14
    if(_S49)
    {

#line 14
        _S49 = true;

#line 14
    }
    else
    {

#line 14
        _S49 = (kernelContext_6->cu_0->tilt_0.z) > 0.0f;

#line 14
    }

#line 14
    if(_S49)
    {

#line 14
        _S49 = true;

#line 14
    }
    else
    {

#line 14
        bool _S50 = hasCrop_0(kernelContext_6);

#line 14
        _S49 = _S50;

#line 14
    }

#line 14
    if(_S49)
    {

#line 14
        _S49 = true;

#line 14
    }
    else
    {

#line 14
        _S49 = (kernelContext_6->cu_0->cropFeather_0) > 0.0f;

#line 14
    }

#line 14
    return _S49;
}


#line 14
float maskCoverage_0(float2 _S51, texture2d<float, access::sample> _S52, texture2d<float, access::sample> _S53, texture2d<float, access::sample> _S54, float3 _S55, KernelContext_0 thread* kernelContext_7)
{

#line 56 "crates/sq-gpu/shaders-src/Parts/Mask.slang"
    float _S56 = 1.0f / max(min(kernelContext_7->cu_0->scale_0.x, kernelContext_7->cu_0->scale_0.y), 9.9999997473787516e-05f);

#line 56
    float acc_1 = 0.0f;

#line 56
    uint m_1 = 0U;

    for(;;)
    {

#line 58
        if(m_1 < (kernelContext_7->cu_0->maskCount_0))
        {
        }
        else
        {

#line 58
            break;
        }

#line 59
        uint _S57 = m_1 * 4U;

#line 59
        float2 _S58 = maskAt_0(_S57, kernelContext_7);

#line 59
        float2 _S59 = maskAt_0(_S57 + 1U, kernelContext_7);

#line 59
        float2 _S60 = maskAt_0(_S57 + 2U, kernelContext_7);

#line 59
        float2 _S61 = maskAt_0(_S57 + 3U, kernelContext_7);
        uint start_2 = uint(_S58.x);

#line 60
        uint count_0 = uint(_S58.y);

#line 60
        uint mode_2 = uint(_S59.x);

#line 60
        bool _S62;
        if(m_1 == 0U)
        {

#line 61
            if(mode_2 == 1U)
            {

#line 61
                _S62 = true;

#line 61
            }
            else
            {

#line 61
                _S62 = mode_2 == 2U;

#line 61
            }

#line 61
        }
        else
        {

#line 61
            _S62 = false;

#line 61
        }

#line 61
        float acc_2;

#line 61
        if(_S62)
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
        float _S63 = _S61.y;

#line 62
        float d2_0;

#line 62
        float c_4;

#line 62
        float c_5;

#line 62
        bool inFrame_0;

#line 62
        bool _S64;

#line 62
        if(_S63 != 0.0f)
        {

#line 62
            float2 _S65 = kernelContext_7->cu_0->maskSize_0;

#line 62
            float2 ms_0;

            if((kernelContext_7->cu_0->maskSize_0.x) > 0.0f)
            {

#line 64
                ms_0 = _S65;

#line 64
            }
            else
            {

#line 64
                ms_0 = kernelContext_7->cu_0->size_0;

#line 64
            }
            float2 uv_1 = _S51 / ms_0 + float2(0.5f) ;
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


            if(_S63 == 10.0f)
            {

#line 69
                float _S66 = colorRangeValue_0(start_2, _S55, kernelContext_7);

#line 69
                c_4 = _S66;

#line 69
            }
            else
            {

#line 70
                if(_S63 >= 6.0f)
                {

#line 70
                    float _S67 = pictureSample_0(_S51, start_2, uint(_S63), _S53, _S54, kernelContext_7);

#line 70
                    c_4 = _S67;

#line 70
                }
                else
                {

#line 71
                    if(_S63 != 2.0f)
                    {

#line 71
                        _S64 = inFrame_0;

#line 71
                    }
                    else
                    {

#line 71
                        _S64 = false;

#line 71
                    }

#line 71
                    if(_S64)
                    {

#line 72
                        float4 s_2 = ((_S52).sample((kernelContext_7->edgeSampler_0), (uv_1), level((0.0f))));
                        if(_S63 == 1.0f)
                        {

#line 73
                            d2_0 = s_2.x;

#line 73
                        }
                        else
                        {

#line 73
                            if(_S63 == 3.0f)
                            {

#line 73
                                d2_0 = s_2.y;

#line 73
                            }
                            else
                            {

#line 73
                                if(_S63 == 4.0f)
                                {

#line 73
                                    d2_0 = s_2.z;

#line 73
                                }
                                else
                                {

#line 73
                                    d2_0 = s_2.w;

#line 73
                                }

#line 73
                            }

#line 73
                        }

#line 73
                        c_4 = clamp(d2_0, 0.0f, 1.0f);

#line 71
                    }
                    else
                    {

#line 71
                        c_4 = 0.0f;

#line 71
                    }

#line 70
                }

#line 69
            }

#line 75
            if((_S59.y) != 0.0f)
            {

#line 75
                c_5 = 1.0f - c_4;

#line 75
            }
            else
            {

#line 75
                c_5 = c_4;

#line 75
            }

#line 75
            acc_1 = maskCombine_0(acc_2, c_5 * _S61.x, mode_2);


            m_1 = m_1 + 1U;

#line 58
            continue;
        }

#line 58
        float d_2;

#line 82
        if(count_0 >= 2U)
        {

#line 83
            uint _S68 = start_2 + count_0;

#line 83
            uint j_0 = _S68 - 1U;

#line 83
            d2_0 = 1.00000001504746622e+30f;

#line 83
            inFrame_0 = false;

#line 83
            uint i_2 = start_2;
            for(;;)
            {

#line 84
                if(i_2 < _S68)
                {
                }
                else
                {

#line 84
                    break;
                }

#line 84
                float2 _S69 = maskAt_0(j_0, kernelContext_7);

#line 84
                float2 _S70 = maskAt_0(i_2, kernelContext_7);

                float2 e_1 = _S70 - _S69;

#line 86
                float2 w_1 = _S51 - _S69;
                float ee_0 = dot(e_1, e_1);
                if(ee_0 > 0.0f)
                {

#line 88
                    d_2 = clamp(dot(w_1, e_1) / ee_0, 0.0f, 1.0f);

#line 88
                }
                else
                {

#line 88
                    d_2 = 0.0f;

#line 88
                }
                float2 q_0 = w_1 - e_1 * float2(d_2) ;
                float _S71 = min(d2_0, dot(q_0, q_0));
                float _S72 = _S70.y;

#line 91
                float _S73 = _S51.y;

#line 91
                float _S74 = _S69.y;

#line 91
                if((_S72 > _S73) != (_S74 > _S73))
                {

#line 91
                    float _S75 = _S70.x;

#line 91
                    _S64 = (_S51.x) < ((_S69.x - _S75) * (_S73 - _S72) / (_S74 - _S72) + _S75);

#line 91
                }
                else
                {

#line 91
                    _S64 = false;

#line 91
                }

#line 91
                if(_S64)
                {

#line 91
                    inFrame_0 = !inFrame_0;

#line 91
                }

#line 84
                uint _S76 = i_2 + 1U;

#line 84
                j_0 = i_2;

#line 84
                i_2 = _S76;

#line 84
                d2_0 = _S71;

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
        float d_3 = sqrt(d2_0);
        if(inFrame_0)
        {

#line 96
            d_2 = - d_3;

#line 96
        }
        else
        {

#line 96
            d_2 = d_3;

#line 96
        }
        float d_4 = d_2 - _S60.y;

        float _S77 = _S60.x;

#line 99
        if(_S77 > _S56)
        {

#line 100
            float hh_0 = _S77 * 0.5f;
            float x_1 = clamp((d_4 + hh_0) / (2.0f * hh_0), 0.0f, 1.0f);

#line 101
            c_4 = 1.0f - x_1 * x_1 * (3.0f - 2.0f * x_1);

#line 99
        }
        else
        {

#line 99
            c_4 = clamp(0.5f - d_4 / _S56, 0.0f, 1.0f);

#line 99
        }

#line 106
        if((_S59.y) != 0.0f)
        {

#line 106
            c_5 = 1.0f - c_4;

#line 106
        }
        else
        {

#line 106
            c_5 = c_4;

#line 106
        }

#line 106
        acc_1 = maskCombine_0(acc_2, c_5 * _S61.x, mode_2);

#line 58
        m_1 = m_1 + 1U;

#line 58
    }

#line 110
    return acc_1;
}


#line 110
bool keyMatteView_0(KernelContext_0 thread* kernelContext_8)
{

#line 110
    bool _S78;

#line 89 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
    if((kernelContext_8->cu_0->matte0_0.z) == 1.0f)
    {

#line 89
        _S78 = true;

#line 89
    }
    else
    {

#line 89
        if((kernelContext_8->cu_0->keyCount_0) > 1U)
        {

#line 89
            _S78 = (kernelContext_8->cu_0->matte1_0.z) == 1.0f;

#line 89
        }
        else
        {

#line 89
            _S78 = false;

#line 89
        }

#line 89
    }

#line 89
    return _S78;
}


#line 89
bool alphaSource_0(KernelContext_0 thread* kernelContext_9)
{

#line 89
    uint _S79 = kernelContext_9->cu_0->mode_0;

#line 89
    bool _S80;

#line 44 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
    if((kernelContext_9->cu_0->mode_0) == 4U)
    {

#line 44
        _S80 = true;

#line 44
    }
    else
    {

#line 44
        if(_S79 == 1U)
        {

#line 44
            _S80 = (kernelContext_9->cu_0->alphaMode_0) != 0U;

#line 44
        }
        else
        {

#line 44
            _S80 = false;

#line 44
        }

#line 44
    }

#line 44
    return _S80;
}


#line 44
float3 ycbcrToRGB_0(float3 _S81, KernelContext_0 thread* kernelContext_10)
{

#line 5
    return kernelContext_10->cu_0->m0_0.xyz * float3(_S81.x)  + kernelContext_10->cu_0->m1_0.xyz * float3(_S81.y)  + kernelContext_10->cu_0->m2_0.xyz * float3(_S81.z) ;
}


#line 5
float4 texelPremul_0(texture2d<float, access::sample> _S82, uint2 _S83, KernelContext_0 thread* kernelContext_11)
{

#line 19
    int3 _S84 = int3(int2(_S83), int(0));

#line 19
    float4 t_2 = ((_S82).read(vec<uint,2>(((_S84)).xy), uint(((_S84)).z)));
    thread float4 c_6;
    if((kernelContext_11->cu_0->mode_0) == 4U)
    {

#line 22
        float _S85 = kernelContext_11->cu_0->range_0.z;

#line 22
        float _S86 = kernelContext_11->cu_0->range_0.w;

#line 22
        float3 _S87 = ycbcrToRGB_0(float3(t_2.y * kernelContext_11->cu_0->range_0.x + kernelContext_11->cu_0->range_0.y, t_2.z * _S85 + _S86, t_2.w * _S85 + _S86), kernelContext_11);
        c_6 = float4(_S87, t_2.x);

#line 21
    }
    else
    {

        c_6 = t_2;

#line 21
    }

#line 28
    if((kernelContext_11->cu_0->alphaMode_0) == 2U)
    {

#line 28
        c_6.xyz = clamp(c_6.xyz, float3(0.0f) , float3(c_6.w) );

#line 28
    }
    else
    {

#line 28
        c_6.xyz = c_6.xyz * float3(c_6.w) ;

#line 28
    }
    return c_6;
}


#line 29
float4 samplePremul_0(texture2d<float, access::sample> _S88, float2 _S89, KernelContext_0 thread* kernelContext_12)
{

#line 29
    int2 _S90 = int2(int(1)) ;

#line 34
    int2 mx_0 = int2(texSize_0(_S88)) - _S90;
    float2 p_2 = _S89 * float2(mx_0 + _S90) - float2(0.5f) ;
    float2 fl_0 = floor(p_2);

#line 36
    float2 f_1 = p_2 - fl_0;
    int2 _S91 = int2(fl_0);
    int2 _S92 = int2(int(0)) ;

#line 38
    uint2 _S93 = uint2(clamp(_S91, _S92, mx_0));

#line 38
    uint2 _S94 = uint2(clamp(_S91 + _S90, _S92, mx_0));

#line 38
    float4 _S95 = texelPremul_0(_S88, _S93, kernelContext_12);

#line 38
    float4 _S96 = texelPremul_0(_S88, uint2(_S94.x, _S93.y), kernelContext_12);

#line 38
    float4 _S97 = texelPremul_0(_S88, uint2(_S93.x, _S94.y), kernelContext_12);

#line 38
    float4 _S98 = texelPremul_0(_S88, _S94, kernelContext_12);


    float4 _S99 = float4(f_1.x) ;

#line 41
    return mix(mix(_S95, _S96, _S99), mix(_S97, _S98, _S99), float4(f_1.y) );
}


#line 41
float3 sourceEncoded_0(texture2d<float, access::sample> _S100, texture2d<float, access::sample> _S101, float2 _S102, KernelContext_0 thread* kernelContext_13)
{

#line 10
    if((kernelContext_13->cu_0->mode_0) == 1U)
    {

#line 10
        return ((_S100).sample((kernelContext_13->edgeSampler_0), (_S102), level((0.0f)))).xyz;
    }
    float2 c_7 = ((_S101).sample((kernelContext_13->edgeSampler_0), (_S102), level((0.0f)))).xy * float2(kernelContext_13->cu_0->range_0.z)  + float2(kernelContext_13->cu_0->range_0.w) ;

#line 12
    float3 _S103 = ycbcrToRGB_0(float3(((_S100).sample((kernelContext_13->edgeSampler_0), (_S102), level((0.0f)))).x * kernelContext_13->cu_0->range_0.x + kernelContext_13->cu_0->range_0.y, c_7.x, c_7.y), kernelContext_13);
    return _S103;
}


#line 13
float4 shadeLayer_0(const VOut_0 thread* _S104, texture2d<float, access::sample> _S105, texture2d<float, access::sample> _S106, texture2d<float, access::sample> _S107, texture2d<float, access::sample> _S108, texture2d<float, access::sample> _S109, KernelContext_0 thread* kernelContext_14)
{

#line 13
    bool _S110 = edgeAA_0(kernelContext_14);

#line 13
    float2 uv_2;

#line 13
    float cover_0;

#line 94 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
    if(_S110)
    {

#line 94
        float2 _S111 = kernelContext_14->cu_0->maskSize_0;

        if((kernelContext_14->cu_0->maskSize_0.x) > 0.0f)
        {

#line 96
            uv_2 = _S111;

#line 96
        }
        else
        {

#line 96
            uv_2 = kernelContext_14->cu_0->size_0;

#line 96
        }
        float2 lo_0 = float2(-0.5f)  * uv_2 + kernelContext_14->cu_0->crop_0.xy * uv_2;

#line 97
        float2 _S112 = float2(0.5f) ;
        float2 _S113 = _S112 * uv_2;

#line 98
        float2 hi_0 = _S113 - kernelContext_14->cu_0->crop_0.zw * uv_2;
        float2 c_8 = _S112 * (lo_0 + hi_0);
        float2 h_2 = _S112 * (hi_0 - lo_0);

        if((kernelContext_14->cu_0->roundFirst_0) != 0U)
        {

            float _S114 = min(kernelContext_14->cu_0->cornerRadius_0, min(_S113.x, _S113.y));
            float2 q0_0 = abs(_S104->local_1) - _S113 + float2(_S114) ;
            float2 _S115 = float2(0.0f) ;
            float2 q1_0 = abs(_S104->local_1 - c_8) - h_2;

#line 108
            cover_0 = max(length(max(q0_0, _S115)) + min(max(q0_0.x, q0_0.y), 0.0f) - _S114, length(max(q1_0, _S115)) + min(max(q1_0.x, q1_0.y), 0.0f));

#line 102
        }
        else
        {

#line 112
            float _S116 = min(kernelContext_14->cu_0->cornerRadius_0, min(h_2.x, h_2.y));
            float2 q_1 = abs(_S104->local_1 - c_8) - h_2 + float2(_S116) ;

#line 113
            cover_0 = length(max(q_1, float2(0.0f) )) + min(max(q_1.x, q_1.y), 0.0f) - _S116;

#line 102
        }

#line 116
        float w_2 = 1.0f / max(min(kernelContext_14->cu_0->scale_0.x, kernelContext_14->cu_0->scale_0.y), 9.9999997473787516e-05f);

#line 116
        float _S117 = kernelContext_14->cu_0->cropFeather_0;

        if((kernelContext_14->cu_0->cropFeather_0) > 0.0f)
        {

#line 118
            cover_0 = clamp((0.5f * w_2 - cover_0) / (w_2 + _S117), 0.0f, 1.0f);

#line 118
        }
        else
        {

#line 118
            cover_0 = clamp(0.5f - cover_0 / w_2, 0.0f, 1.0f);

#line 118
        }

#line 94
    }
    else
    {

#line 94
        cover_0 = 1.0f;

#line 94
    }

#line 94
    float2 _S118 = _S104->local_1;

#line 94
    float2 _S119 = float2(0.5f) ;

#line 121
    float2 uv_3 = _S104->local_1 / kernelContext_14->cu_0->size_0 + _S119;

#line 121
    uint _S120 = kernelContext_14->cu_0->mode_0;

#line 121
    bool _S121;
    if((kernelContext_14->cu_0->mode_0) != 3U)
    {

#line 122
        _S121 = (kernelContext_14->cu_0->quarter_0) != 0U;

#line 122
    }
    else
    {

#line 122
        _S121 = false;

#line 122
    }

#line 122
    if(_S121)
    {

#line 122
        uint _S122 = kernelContext_14->cu_0->quarter_0;

        if((kernelContext_14->cu_0->quarter_0) == 1U)
        {

#line 124
            uv_2 = float2(uv_3.y, 1.0f - uv_3.x);

#line 124
        }
        else
        {

#line 125
            if(_S122 == 2U)
            {

#line 125
                uv_2 = float2(1.0f - uv_3.x, 1.0f - uv_3.y);

#line 125
            }
            else
            {

#line 125
                uv_2 = float2(1.0f - uv_3.y, uv_3.x);

#line 125
            }

#line 124
        }

#line 122
    }
    else
    {

#line 122
        uv_2 = uv_3;

#line 122
    }

#line 122
    float kept_0;

#line 122
    float3 pc_1;

#line 128
    if(_S120 == 3U)
    {

#line 128
        float4 _S123 = kernelContext_14->cu_0->part_0;

#line 128
        float4 g_0;

        if((kernelContext_14->cu_0->part_0.z) > 0.0f)
        {

            float2 _S124 = _S123.zw;

#line 133
            float4 _S125 = samplePartTexels_0(_S105, clamp(uv_2 * _S124, float2(0.5f) , _S124 - _S119) - _S123.xy, kernelContext_14);

#line 133
            g_0 = _S125;

#line 130
        }
        else
        {

#line 130
            g_0 = ((_S105).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));

#line 130
        }

#line 138
        if((kernelContext_14->cu_0->maskCount_0) > 0U)
        {

#line 139
            float _S126 = g_0.w;

#line 139
            if(_S126 > 0.0f)
            {

#line 139
                pc_1 = oetf709_0(clamp(g_0.xyz / float3(_S126) , float3(0.0f) , float3(1.0f) ));

#line 139
            }
            else
            {

#line 139
                pc_1 = float3(0.0f) ;

#line 139
            }

#line 139
            float _S127 = maskCoverage_0(_S118, _S107, _S108, _S109, pc_1, kernelContext_14);

#line 139
            cover_0 = cover_0 * _S127;

#line 138
        }

#line 138
        uint _S128 = kernelContext_14->cu_0->keyCount_0;



        if((kernelContext_14->cu_0->keyCount_0) > 0U)
        {

#line 142
            _S121 = (g_0.w) > 0.0f;

#line 142
        }
        else
        {

#line 142
            _S121 = false;

#line 142
        }

#line 142
        if(_S121)
        {
            float _S129 = g_0.w;

#line 144
            float3 _S130 = float3(_S129) ;

#line 144
            thread float3 c_9 = g_0.xyz / _S130;
            float _S131 = applyChromaKey_0(kernelContext_14->cu_0->key0_0, kernelContext_14->cu_0->matte0_0, kernelContext_14->cu_0->shape0_0, kernelContext_14->cu_0->cc0_0, &c_9);

#line 145
            float kept_1 = 1.0f - _S131;
            if(_S128 > 1U)
            {

#line 146
                float _S132 = applyChromaKey_0(kernelContext_14->cu_0->key1_0, kernelContext_14->cu_0->matte1_0, kernelContext_14->cu_0->shape1_0, kernelContext_14->cu_0->cc1_0, &c_9);

#line 146
                kept_0 = kept_1 * (1.0f - _S132);

#line 146
            }
            else
            {

#line 146
                kept_0 = kept_1;

#line 146
            }

#line 146
            bool _S133 = keyMatteView_0(kernelContext_14);
            if(_S133)
            {

#line 147
                g_0 = float4(float3(kept_0)  * _S130, _S129);

#line 147
            }
            else
            {

#line 147
                g_0 = float4(c_9 * _S130 * float3(kept_0) , _S129 * kept_0);

#line 147
            }

#line 142
        }

#line 151
        return g_0 * float4((kernelContext_14->cu_0->opacity_0 * cover_0)) ;
    }

    thread float3 rgb_0;

#line 154
    float texA_0;
    if(_S120 == 2U)
    {

#line 156
        rgb_0 = kernelContext_14->cu_0->solid_0.xyz;

#line 156
        texA_0 = 1.0f;

#line 155
    }
    else
    {

#line 155
        bool _S134 = alphaSource_0(kernelContext_14);

        if(_S134)
        {

#line 157
            float4 _S135 = samplePremul_0(_S105, uv_2, kernelContext_14);



            float texA_1 = _S135.w;
            if(texA_1 > 0.0f)
            {

#line 162
                pc_1 = _S135.xyz / float3(texA_1) ;

#line 162
            }
            else
            {

#line 162
                pc_1 = float3(0.0f) ;

#line 162
            }

#line 162
            rgb_0 = pc_1;

#line 162
            texA_0 = texA_1;

#line 157
        }
        else
        {



            bool _S136 = _S120 == 1U;

#line 163
            if(_S136)
            {

#line 163
                _S121 = (kernelContext_14->cu_0->linearize_0) != 0U;

#line 163
            }
            else
            {

#line 163
                _S121 = false;

#line 163
            }

#line 163
            if(_S121)
            {
                float4 c_10 = ((_S105).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));
                float texA_2 = c_10.w;
                if(texA_2 > 0.0f)
                {

#line 167
                    pc_1 = c_10.xyz / float3(texA_2) ;

#line 167
                }
                else
                {

#line 167
                    pc_1 = float3(0.0f) ;

#line 167
                }

#line 167
                rgb_0 = pc_1;

#line 167
                texA_0 = texA_2;

#line 163
            }
            else
            {


                if(_S136)
                {
                    float4 c_11 = ((_S105).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));
                    float _S137 = c_11.w;
                    rgb_0 = c_11.xyz;

#line 172
                    texA_0 = _S137;

#line 168
                }
                else
                {

#line 168
                    float3 _S138 = sourceEncoded_0(_S105, _S106, uv_2, kernelContext_14);

#line 174
                    rgb_0 = _S138;

#line 174
                    texA_0 = 1.0f;

#line 168
                }

#line 163
            }

#line 157
        }

#line 155
    }

#line 176
    bool _S139 = _S120 != 2U;

#line 176
    if(_S139)
    {

#line 176
        _S121 = (kernelContext_14->cu_0->linearize_0) != 0U;

#line 176
    }
    else
    {

#line 176
        _S121 = false;

#line 176
    }

#line 176
    if(_S121)
    {

#line 176
        rgb_0 = inverseOETF709_0(rgb_0);

#line 176
    }
    float3 _S140 = float3(0.0f) ;

#line 177
    rgb_0 = max(rgb_0, _S140);

    if((kernelContext_14->cu_0->maskCount_0) > 0U)
    {

#line 179
        float _S141 = maskCoverage_0(_S118, _S107, _S108, _S109, oetf709_0(clamp(rgb_0, _S140, float3(1.0f) )), kernelContext_14);

#line 179
        cover_0 = cover_0 * _S141;

#line 179
    }
    if(_S139)
    {

#line 180
        _S121 = (kernelContext_14->cu_0->keyCount_0) > 0U;

#line 180
    }
    else
    {

#line 180
        _S121 = false;

#line 180
    }

#line 180
    if(_S121)
    {

#line 181
        float _S142 = applyChromaKey_0(kernelContext_14->cu_0->key0_0, kernelContext_14->cu_0->matte0_0, kernelContext_14->cu_0->shape0_0, kernelContext_14->cu_0->cc0_0, &rgb_0);

#line 181
        float kept_2 = 1.0f - _S142;
        if((kernelContext_14->cu_0->keyCount_0) > 1U)
        {

#line 182
            float _S143 = applyChromaKey_0(kernelContext_14->cu_0->key1_0, kernelContext_14->cu_0->matte1_0, kernelContext_14->cu_0->shape1_0, kernelContext_14->cu_0->cc1_0, &rgb_0);

#line 182
            kept_0 = kept_2 * (1.0f - _S143);

#line 182
        }
        else
        {

#line 182
            kept_0 = kept_2;

#line 182
        }

#line 182
        bool _S144 = keyMatteView_0(kernelContext_14);
        if(_S144)
        {

#line 183
            rgb_0 = float3(kept_0) ;

#line 183
        }
        else
        {

#line 183
            texA_0 = texA_0 * kept_0;

#line 183
        }

#line 180
    }

#line 186
    float a_0 = kernelContext_14->cu_0->opacity_0 * cover_0 * texA_0;
    return float4(rgb_0 * float3(a_0) , a_0);
}


#line 15 "crates/sq-gpu/shaders-src/Layer.slang"
[[fragment]] pixelOutput_0 compositeFragment(pixelInput_0 _S145 [[stage_in]], float4 position_2 [[position]], CompositeU_0 constant* cu_1 [[buffer(0)]], sampler zeroSampler_1 [[sampler(0)]], sampler edgeSampler_1 [[sampler(1)]], uint32_t device* maskData_1 [[buffer(2)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture2d<float, access::sample> in4_1 [[texture(4)]], texture2d<float, access::sample> in5_1 [[texture(5)]], texture2d<float, access::sample> in6_1 [[texture(6)]])
{

#line 15
    thread KernelContext_0 kernelContext_15;

#line 15
    (&kernelContext_15)->cu_0 = cu_1;

#line 15
    (&kernelContext_15)->zeroSampler_0 = zeroSampler_1;

#line 15
    (&kernelContext_15)->edgeSampler_0 = edgeSampler_1;

#line 15
    (&kernelContext_15)->maskData_0 = maskData_1;

#line 15
    (&kernelContext_15)->in0_0 = in0_1;

#line 15
    (&kernelContext_15)->in1_0 = in1_1;

#line 15
    (&kernelContext_15)->in3_0 = in3_1;

#line 15
    (&kernelContext_15)->in4_0 = in4_1;

#line 15
    (&kernelContext_15)->in5_0 = in5_1;

#line 15
    (&kernelContext_15)->in6_0 = in6_1;

#line 15
    thread VOut_0 _S146;

#line 15
    (&_S146)->position_1 = position_2;

#line 15
    (&_S146)->local_1 = _S145.local_0;

#line 15
    float4 _S147 = shadeLayer_0(&_S146, in0_1, in1_1, in3_1, in4_1, in5_1, &kernelContext_15);

#line 15
    pixelOutput_0 _S148 = { _S147 };
    return _S148;
}


#line 101
float4 destinationPixel_0(float4 position_3, KernelContext_0 thread* kernelContext_16)
{

#line 101
    int3 _S149 = int3(int2(position_3.xy), int(0));

#line 101
    return ((kernelContext_16->in6_0).read(vec<uint,2>(((_S149)).xy), uint(((_S149)).z)));
}


#line 87
float dissolveThreshold_0(uint2 p_3)
{

#line 88
    uint h_3 = (p_3.x * 2654435769U) ^ (p_3.y * 2246822507U);
    uint h_4 = (h_3 ^ (h_3 >> 16U)) * 2146121005U;
    uint h_5 = (h_4 ^ (h_4 >> 15U)) * 2221713035U;

    return float((h_5 ^ (h_5 >> 16U)) >> 8U) / 1.6777216e+07f;
}


#line 57
float blendLum_0(float3 c_12)
{

#line 57
    return c_12.x * 0.2125999927520752f + c_12.y * 0.71520000696182251f + c_12.z * 0.072200000286102295f;
}


#line 66
float blendSat_0(float3 c_13)
{

#line 66
    float _S150 = c_13.x;

#line 66
    float _S151 = c_13.y;

#line 66
    float _S152 = c_13.z;

#line 66
    return max(_S150, max(_S151, _S152)) - min(_S150, min(_S151, _S152));
}


#line 67
float3 blendSetSat_0(float3 c_14, float s_3)
{

#line 68
    float _S153 = c_14.x;

#line 68
    float _S154 = c_14.y;

#line 68
    float _S155 = c_14.z;

#line 68
    float _S156 = min(_S153, min(_S154, _S155));
    float range_1 = max(_S153, max(_S154, _S155)) - _S156;

#line 69
    float3 _S157;
    if(range_1 > 0.0f)
    {

#line 70
        _S157 = (c_14 - float3(_S156) ) * float3((s_3 / range_1)) ;

#line 70
    }
    else
    {

#line 70
        _S157 = float3(0.0f) ;

#line 70
    }

#line 70
    return _S157;
}


#line 58
float3 blendClipColor_0(float3 c_15)
{

#line 59
    float l_1 = blendLum_0(c_15);
    float _S158 = c_15.x;

#line 60
    float _S159 = c_15.y;

#line 60
    float _S160 = c_15.z;

#line 60
    float _S161 = min(_S158, min(_S159, _S160));

#line 60
    float _S162 = max(_S158, max(_S159, _S160));

#line 60
    float3 _S163;
    if(_S161 < 0.0f)
    {

#line 61
        float3 _S164 = float3(l_1) ;

#line 61
        _S163 = _S164 + (c_15 - _S164) * float3((l_1 / max(l_1 - _S161, 9.99999997475242708e-07f))) ;

#line 61
    }
    else
    {

#line 61
        _S163 = c_15;

#line 61
    }

#line 61
    bool _S165;
    if(l_1 < 1.0f)
    {

#line 62
        _S165 = _S162 > 1.0f;

#line 62
    }
    else
    {

#line 62
        _S165 = false;

#line 62
    }

#line 62
    if(_S165)
    {

#line 62
        float3 _S166 = float3(l_1) ;

#line 62
        _S163 = _S166 + (_S163 - _S166) * float3(((1.0f - l_1) / max(_S162 - l_1, 9.99999997475242708e-07f))) ;

#line 62
    }
    return _S163;
}


#line 65
float3 blendSetLum_0(float3 c_16, float l_2)
{

#line 65
    return blendClipColor_0(c_16 + float3((l_2 - blendLum_0(c_16))) );
}


#line 20
float blendScalar_0(uint mode_3, float cd_0, float cs_1)
{

#line 20
    float d_5;
    switch(mode_3)
    {
    case 1U:
        {

#line 22
            return cd_0 * cs_1;
        }
    case 2U:
        {

#line 23
            return cd_0 + cs_1 - cd_0 * cs_1;
        }
    case 3U:
        {

#line 24
            return cd_0 + cs_1;
        }
    case 4U:
        {

#line 25
            if(cd_0 <= 0.5f)
            {

#line 25
                d_5 = 2.0f * cs_1 * cd_0;

#line 25
            }
            else
            {

#line 25
                float _S167 = 2.0f * cd_0 - 1.0f;

#line 25
                d_5 = cs_1 + _S167 - cs_1 * _S167;

#line 25
            }

#line 25
            return d_5;
        }
    case 5U:
        {

#line 26
            return min(cd_0, cs_1);
        }
    case 6U:
        {

#line 27
            return max(cd_0, cs_1);
        }
    case 7U:
        {

#line 28
            if(cd_0 <= 0.0f)
            {

#line 28
                d_5 = 0.0f;

#line 28
            }
            else
            {

#line 28
                if(cs_1 >= 1.0f)
                {

#line 28
                    d_5 = 1.0f;

#line 28
                }
                else
                {

#line 28
                    d_5 = min(1.0f, cd_0 / (1.0f - cs_1));

#line 28
                }

#line 28
            }

#line 28
            return d_5;
        }
    case 8U:
        {

#line 29
            if(cd_0 >= 1.0f)
            {

#line 29
                d_5 = 1.0f;

#line 29
            }
            else
            {

#line 29
                if(cs_1 <= 0.0f)
                {

#line 29
                    d_5 = 0.0f;

#line 29
                }
                else
                {

#line 29
                    d_5 = 1.0f - min(1.0f, (1.0f - cd_0) / cs_1);

#line 29
                }

#line 29
            }

#line 29
            return d_5;
        }
    case 9U:
        {

#line 30
            return max(0.0f, cd_0 + cs_1 - 1.0f);
        }
    case 10U:
        {

#line 31
            if(cs_1 <= 0.5f)
            {

#line 31
                d_5 = cd_0 * 2.0f * cs_1;

#line 31
            }
            else
            {

#line 31
                float _S168 = 2.0f * cs_1 - 1.0f;

#line 31
                d_5 = cd_0 + _S168 - cd_0 * _S168;

#line 31
            }

#line 31
            return d_5;
        }
    case 11U:
        {

#line 33
            if(cs_1 <= 0.5f)
            {

#line 33
                return cd_0 - (1.0f - 2.0f * cs_1) * cd_0 * (1.0f - cd_0);
            }

#line 34
            if(cd_0 <= 0.25f)
            {

#line 34
                d_5 = ((16.0f * cd_0 - 12.0f) * cd_0 + 4.0f) * cd_0;

#line 34
            }
            else
            {

#line 34
                d_5 = sqrt(max(cd_0, 0.0f));

#line 34
            }
            return cd_0 + (2.0f * cs_1 - 1.0f) * (d_5 - cd_0);
        }
    case 12U:
        {

#line 37
            return abs(cd_0 - cs_1);
        }
    case 13U:
        {

#line 38
            return cd_0 + cs_1 - 2.0f * cd_0 * cs_1;
        }
    case 15U:
        {

#line 40
            if(cs_1 <= 0.5f)
            {

#line 41
                float s2_0 = 2.0f * cs_1;
                if(cd_0 >= 1.0f)
                {

#line 42
                    d_5 = 1.0f;

#line 42
                }
                else
                {

#line 42
                    if(s2_0 <= 0.0f)
                    {

#line 42
                        d_5 = 0.0f;

#line 42
                    }
                    else
                    {

#line 42
                        d_5 = 1.0f - min(1.0f, (1.0f - cd_0) / s2_0);

#line 42
                    }

#line 42
                }

#line 42
                return d_5;
            }
            float s2_1 = 2.0f * cs_1 - 1.0f;
            if(cd_0 <= 0.0f)
            {

#line 45
                d_5 = 0.0f;

#line 45
            }
            else
            {

#line 45
                if(s2_1 >= 1.0f)
                {

#line 45
                    d_5 = 1.0f;

#line 45
                }
                else
                {

#line 45
                    d_5 = min(1.0f, cd_0 / (1.0f - s2_1));

#line 45
                }

#line 45
            }

#line 45
            return d_5;
        }
    case 16U:
        {

#line 47
            return max(0.0f, cd_0 + 2.0f * cs_1 - 1.0f);
        }
    case 17U:
        {

#line 48
            if(cs_1 <= 0.5f)
            {

#line 48
                d_5 = min(cd_0, 2.0f * cs_1);

#line 48
            }
            else
            {

#line 48
                d_5 = max(cd_0, 2.0f * cs_1 - 1.0f);

#line 48
            }

#line 48
            return d_5;
        }
    case 18U:
        {

#line 49
            if((cd_0 + cs_1) >= 1.0f)
            {

#line 49
                d_5 = 1.0f;

#line 49
            }
            else
            {

#line 49
                d_5 = 0.0f;

#line 49
            }

#line 49
            return d_5;
        }
    case 19U:
        {

#line 50
            return max(0.0f, cd_0 - cs_1);
        }
    case 20U:
        {

#line 51
            if(cs_1 <= 0.0f)
            {

#line 51
                if(cd_0 > 0.0f)
                {

#line 51
                    d_5 = 1.0f;

#line 51
                }
                else
                {

#line 51
                    d_5 = 0.0f;

#line 51
                }

#line 51
            }
            else
            {

#line 51
                d_5 = min(cd_0 / cs_1, max(1.0f, cd_0));

#line 51
            }

#line 51
            return d_5;
        }
    default:
        {

#line 52
            return cs_1;
        }
    }

#line 52
}


#line 74
float3 blendChannel_0(uint mode_4, float3 cd_1, float3 cs_2)
{

#line 74
    float3 _S169;
    switch(mode_4)
    {
    case 21U:
        {

#line 76
            if((blendLum_0(cs_2)) < (blendLum_0(cd_1)))
            {

#line 76
                _S169 = cs_2;

#line 76
            }
            else
            {

#line 76
                _S169 = cd_1;

#line 76
            }

#line 76
            return _S169;
        }
    case 22U:
        {

#line 77
            if((blendLum_0(cs_2)) > (blendLum_0(cd_1)))
            {

#line 77
                _S169 = cs_2;

#line 77
            }
            else
            {

#line 77
                _S169 = cd_1;

#line 77
            }

#line 77
            return _S169;
        }
    case 23U:
        {

#line 78
            return blendSetLum_0(blendSetSat_0(cs_2, blendSat_0(cd_1)), blendLum_0(cd_1));
        }
    case 24U:
        {

#line 79
            return blendSetLum_0(blendSetSat_0(cd_1, blendSat_0(cs_2)), blendLum_0(cd_1));
        }
    case 25U:
        {

#line 80
            return blendSetLum_0(cs_2, blendLum_0(cd_1));
        }
    case 26U:
        {

#line 81
            return blendSetLum_0(cd_1, blendLum_0(cs_2));
        }
    default:
        {

#line 82
            return float3(blendScalar_0(mode_4, cd_1.x, cs_2.x), blendScalar_0(mode_4, cd_1.y, cs_2.y), blendScalar_0(mode_4, cd_1.z, cs_2.z));
        }
    }

#line 82
}


#line 82
struct pixelOutput_1
{
    float4 output_1 [[color(0)]];
};


#line 82
struct pixelInput_1
{
    float2 local_2 [[user(LOCAL)]];
};


#line 107
[[fragment]] pixelOutput_1 compositeFragmentBlend(pixelInput_1 _S170 [[stage_in]], float4 position_4 [[position]], CompositeU_0 constant* cu_2 [[buffer(0)]], sampler zeroSampler_2 [[sampler(0)]], sampler edgeSampler_2 [[sampler(1)]], uint32_t device* maskData_2 [[buffer(2)]], texture2d<float, access::sample> in0_2 [[texture(0)]], texture2d<float, access::sample> in1_2 [[texture(1)]], texture2d<float, access::sample> in3_2 [[texture(3)]], texture2d<float, access::sample> in4_2 [[texture(4)]], texture2d<float, access::sample> in5_2 [[texture(5)]], texture2d<float, access::sample> in6_2 [[texture(6)]])
{

#line 107
    thread KernelContext_0 kernelContext_17;

#line 107
    (&kernelContext_17)->cu_0 = cu_2;

#line 107
    (&kernelContext_17)->zeroSampler_0 = zeroSampler_2;

#line 107
    (&kernelContext_17)->edgeSampler_0 = edgeSampler_2;

#line 107
    (&kernelContext_17)->maskData_0 = maskData_2;

#line 107
    (&kernelContext_17)->in0_0 = in0_2;

#line 107
    (&kernelContext_17)->in1_0 = in1_2;

#line 107
    (&kernelContext_17)->in3_0 = in3_2;

#line 107
    (&kernelContext_17)->in4_0 = in4_2;

#line 107
    (&kernelContext_17)->in5_0 = in5_2;

#line 107
    (&kernelContext_17)->in6_0 = in6_2;

#line 107
    float4 _S171 = destinationPixel_0(position_4, &kernelContext_17);

#line 107
    thread VOut_0 _S172;

#line 107
    (&_S172)->position_1 = position_4;

#line 107
    (&_S172)->local_1 = _S170.local_2;

#line 107
    float4 _S173 = shadeLayer_0(&_S172, (&kernelContext_17)->in0_0, (&kernelContext_17)->in1_0, (&kernelContext_17)->in3_0, (&kernelContext_17)->in4_0, (&kernelContext_17)->in5_0, &kernelContext_17);

#line 107
    uint _S174 = (&kernelContext_17)->cu_0->blend_0;



    if(((&kernelContext_17)->cu_0->blend_0) == 27U)
    {

#line 111
        pixelOutput_1 _S175 = { _S171 * float4((1.0f - (&kernelContext_17)->cu_0->opacity_0 + _S173.w))  };

#line 111
        return _S175;
    }

#line 112
    float _S176 = _S173.w;

#line 112
    float3 cs_3;

#line 112
    if(_S176 > 0.0f)
    {

#line 112
        cs_3 = _S173.xyz / float3(_S176) ;

#line 112
    }
    else
    {

#line 112
        cs_3 = float3(0.0f) ;

#line 112
    }

#line 112
    float4 s_4;
    if(_S174 == 14U)
    {

#line 114
        bool on_0 = (dissolveThreshold_0(uint2(position_4.xy))) < _S176;
        if(on_0)
        {

#line 115
            s_4 = float4(cs_3, 1.0f);

#line 115
        }
        else
        {

#line 115
            s_4 = float4(0.0f) ;

#line 115
        }
        if(on_0)
        {
        }
        else
        {

#line 116
            cs_3 = float3(0.0f) ;

#line 116
        }

#line 113
    }
    else
    {

#line 113
        s_4 = _S173;

#line 113
    }

#line 118
    float _S177 = _S171.w;

#line 118
    float3 cd_2;

#line 118
    if(_S177 > 0.0f)
    {

#line 118
        cd_2 = _S171.xyz / float3(_S177) ;

#line 118
    }
    else
    {

#line 118
        cd_2 = float3(0.0f) ;

#line 118
    }

    float _S178 = s_4.w;

#line 120
    float _S179 = 1.0f - _S178;

#line 120
    pixelOutput_1 _S180 = { float4(s_4.xyz * float3((1.0f - _S177))  + _S171.xyz * float3(_S179)  + float3((_S178 * _S177))  * blendChannel_0(_S174, cd_2, cs_3), _S178 + _S177 * _S179) };
    return _S180;
}


#line 121
struct compositeVertex_Result_0
{
    float4 position_5 [[position]];
    float2 local_3 [[user(LOCAL)]];
};


#line 121
[[vertex]] compositeVertex_Result_0 compositeVertex(uint vid_0 [[vertex_id]], CompositeU_0 constant* cu_3 [[buffer(0)]], sampler zeroSampler_3 [[sampler(0)]], sampler edgeSampler_3 [[sampler(1)]], uint32_t device* maskData_3 [[buffer(2)]], texture2d<float, access::sample> in0_3 [[texture(0)]], texture2d<float, access::sample> in1_3 [[texture(1)]], texture2d<float, access::sample> in3_3 [[texture(3)]], texture2d<float, access::sample> in4_3 [[texture(4)]], texture2d<float, access::sample> in5_3 [[texture(5)]], texture2d<float, access::sample> in6_3 [[texture(6)]])
{

#line 121
    thread KernelContext_0 kernelContext_18;

#line 121
    (&kernelContext_18)->cu_0 = cu_3;

#line 121
    (&kernelContext_18)->zeroSampler_0 = zeroSampler_3;

#line 121
    (&kernelContext_18)->edgeSampler_0 = edgeSampler_3;

#line 121
    (&kernelContext_18)->maskData_0 = maskData_3;

#line 121
    (&kernelContext_18)->in0_0 = in0_3;

#line 121
    (&kernelContext_18)->in1_0 = in1_3;

#line 121
    (&kernelContext_18)->in3_0 = in3_3;

#line 121
    (&kernelContext_18)->in4_0 = in4_3;

#line 121
    (&kernelContext_18)->in5_0 = in5_3;

#line 121
    (&kernelContext_18)->in6_0 = in6_3;

#line 28 "crates/sq-gpu/shaders-src/Parts/LayerVertex.slang"
    float2 uv_4 = float2(float(vid_0 & 1U), float(vid_0 >> 1U));

#line 28
    float2 _S181 = float2(0.5f) ;
    float2 local_4 = (uv_4 - _S181) * cu_3->size_0;

#line 29
    bool _S182 = edgeAA_0(&kernelContext_18);

#line 29
    float2 local_5;
    if(_S182)
    {

#line 30
        float2 _S183 = float2(1.0f) ;

#line 30
        local_5 = local_4 + (uv_4 * float2(2.0f)  - _S183) * (_S183 / max((&kernelContext_18)->cu_0->scale_0, float2(9.9999997473787516e-05f) ));

#line 30
    }
    else
    {

#line 30
        local_5 = local_4;

#line 30
    }
    float2 p_4 = (local_5 - (&kernelContext_18)->cu_0->anchor_0) * (&kernelContext_18)->cu_0->scale_0;
    float _S184 = p_4.x;

#line 32
    float _S185 = p_4.y;

#line 32
    float _S186 = (&kernelContext_18)->cu_0->rotCos_0 * _S184 - (&kernelContext_18)->cu_0->rotSin_0 * _S185;

#line 32
    float _S187 = (&kernelContext_18)->cu_0->rotSin_0 * _S184 + (&kernelContext_18)->cu_0->rotCos_0 * _S185;

#line 32
    float2 r_1 = float2(_S186, _S187);

#line 32
    float4 _S188 = (&kernelContext_18)->cu_0->tilt_0;

    float _S189 = (&kernelContext_18)->cu_0->tilt_0.z;

#line 34
    float2 r_2;

#line 34
    float w_3;

#line 34
    if(_S189 > 0.0f)
    {
        float _S190 = _S188.x;

#line 36
        float _S191 = _S188.y;

#line 36
        float cb_1 = cos(_S191);

#line 36
        float sb_1 = sin(_S191);
        float z1_1 = - _S187 * sin(_S190);

        float _S192 = max((_S189 + (_S186 * sb_1 + z1_1 * cb_1)) / _S189, 0.0010000000474974513f);

#line 39
        r_2 = float2(_S186 * cb_1 - z1_1 * sb_1, _S187 * cos(_S190)) / float2(_S192) ;

#line 39
        w_3 = _S192;

#line 34
    }
    else
    {

#line 34
        r_2 = r_1;

#line 34
        w_3 = 1.0f;

#line 34
    }

#line 42
    float2 px_0 = (&kernelContext_18)->cu_0->canvas_0 * _S181 + (&kernelContext_18)->cu_0->position_0 + r_2;
    thread VOut_0 o_0;

    (&o_0)->position_1 = float4(float2(px_0.x / (&kernelContext_18)->cu_0->canvas_0.x * 2.0f - 1.0f, 1.0f - px_0.y / (&kernelContext_18)->cu_0->canvas_0.y * 2.0f) * float2(w_3) , 0.0f, w_3);
    (&o_0)->local_1 = local_5;
    VOut_0 _S193 = o_0;

#line 47
    thread compositeVertex_Result_0 _S194;

#line 47
    (&_S194)->position_5 = _S193.position_1;

#line 47
    (&_S194)->local_3 = _S193.local_1;

#line 47
    return _S194;
}

