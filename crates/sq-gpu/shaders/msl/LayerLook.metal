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


#line 3 "crates/sq-gpu/shaders-src/Parts/Look.slang"
struct LookU_0
{
    float4 dims_0;
    uint4 ids_0;
    float4 grain_0;
    float4 scan_0;
    float4 chroma_0;
    float4 track_0;
    float4 aged_0;
};


#line 3
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
    LookU_0 constant* lu_0;
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


#line 19 "crates/sq-gpu/shaders-src/Parts/LayerVertex.slang"
float targetHalf_0(float x_1)
{

#line 20
    uint h_2 = (as_type<ushort>((half)((x_1))));

#line 20
    bool _S49;
    if(!isinf(x_1))
    {

#line 21
        _S49 = !isnan(x_1);

#line 21
    }
    else
    {

#line 21
        _S49 = false;

#line 21
    }

#line 21
    if(_S49)
    {

#line 21
        _S49 = (abs((as_type<half>((ushort)((h_2)))))) > (abs(x_1));

#line 21
    }
    else
    {

#line 21
        _S49 = false;

#line 21
    }

#line 21
    uint h_3;

#line 21
    if(_S49)
    {

#line 21
        h_3 = h_2 - 1U;

#line 21
    }
    else
    {

#line 21
        h_3 = h_2;

#line 21
    }
    return (as_type<half>((ushort)((h_3))));
}


#line 13 "crates/sq-gpu/shaders-src/Parts/Look.slang"
uint pcg_0(uint v_1)
{

#line 14
    uint s_2 = v_1 * 747796405U + 2891336653U;
    uint w_1 = ((s_2 >> ((s_2 >> 28U) + 4U)) ^ s_2) * 277803737U;
    return (w_1 >> 22U) ^ w_1;
}


#line 18
float hash2_0(int2 p_2, uint seed_0)
{

#line 19
    return float(pcg_0(uint(p_2.x) + pcg_0(uint(p_2.y) + pcg_0(seed_0)))) * 2.32830643653869629e-10f;
}

float grainNoise_0(float2 p_3, float soft_1, uint seed_1)
{

#line 23
    float2 fl_0 = floor(p_3);
    int2 _S50 = int2(fl_0);
    float2 f_1 = p_3 - fl_0;

    float2 u_0 = mix(step(float2(0.5f) , f_1), f_1 * f_1 * (float2(3.0f)  - float2(2.0f)  * f_1), float2(soft_1) );
    float _S51 = u_0.x;

#line 28
    return mix(mix(hash2_0(_S50, seed_1), hash2_0(_S50 + int2(int(1), int(0)), seed_1), _S51), mix(hash2_0(_S50 + int2(int(0), int(1)), seed_1), hash2_0(_S50 + int2(int(1), int(1)), seed_1), _S51), u_0.y);
}



float4 lookPointwise_0(float4 c_4, float streak_0, uint2 gid_0, const LookU_0 constant* L_0)
{

#line 33
    thread float4 _S52 = c_4;

#line 33
    float4 _S53 = L_0->dims_0;
    float sc_0 = L_0->dims_0.z;

#line 34
    uint4 _S54 = L_0->ids_0;
    uint flags_0 = L_0->ids_0.x;
    float3 lw_0 = float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f);
    _S52.xyz = c_4.xyz + float3((streak_0 * 0.60000002384185791f * c_4.w)) ;

#line 37
    bool _S55;



    if((flags_0 & 1U) != 0U)
    {

#line 41
        _S55 = (_S52.w) > 0.0f;

#line 41
    }
    else
    {

#line 41
        _S55 = false;

#line 41
    }

#line 41
    if(_S55)
    {

#line 42
        float3 col_0 = _S52.xyz / float3(_S52.w) ;

        float _S56 = 2.0f * clamp(sqrt(max(dot(col_0, lw_0), 0.0f)), 0.0f, 1.0f) - 1.0f;

#line 44
        float4 _S57 = L_0->grain_0;
        float w_2 = mix(1.0f, 1.0f - _S56 * _S56, L_0->grain_0.w);

        float2 gp_0 = (float2(gid_0) + float2(0.5f) ) / float2(max(L_0->grain_0.y * sc_0, 0.5f)) ;
        float _S58 = L_0->grain_0.z;

#line 48
        float gain_0 = 1.0f + _S58 * 0.89999997615814209f;
        uint _S59 = _S54.y;
        float3 nv_0 = float3(((grainNoise_0(gp_0, _S58, _S59) * 2.0f - 1.0f) * gain_0)) ;
        float _S60 = _S53.w;

#line 51
        float3 nv_1;

#line 51
        if(_S60 > 0.0f)
        {

#line 51
            nv_1 = mix(nv_0, float3((grainNoise_0(gp_0, _S58, _S59 + 101U) * 2.0f - 1.0f) * gain_0, (grainNoise_0(gp_0, _S58, _S59 + 202U) * 2.0f - 1.0f) * gain_0, (grainNoise_0(gp_0, _S58, _S59 + 303U) * 2.0f - 1.0f) * gain_0), float3(_S60) );

#line 51
        }
        else
        {

#line 51
            nv_1 = nv_0;

#line 51
        }

#line 58
        float3 _S61 = float3(0.0f) ;
        float3 _S62 = max(sqrt(max(col_0, _S61)) + nv_1 * float3(_S57.x)  * float3(0.25f)  * float3(w_2) , _S61);
        _S52.xyz = _S62 * _S62 * float3(_S52.w) ;

#line 41
    }

#line 65
    if((flags_0 & 64U) != 0U)
    {

#line 65
        _S55 = (_S52.w) > 0.0f;

#line 65
    }
    else
    {

#line 65
        _S55 = false;

#line 65
    }

#line 65
    if(_S55)
    {
        uint fs_0 = _S54.w;

#line 67
        float4 _S63 = L_0->aged_0;
        _S52.xyz = _S52.xyz * float3((1.0f + (float(pcg_0(fs_0 * 3U + 7U)) * 2.32830643653869629e-10f * 2.0f - 1.0f) * L_0->aged_0.z * 0.34999999403953552f)) ;
        float _S64 = L_0->aged_0.x;

#line 69
        if(_S64 > 0.0f)
        {
            float2 p_4 = float2(gid_0) + float2(0.5f) ;

#line 71
            float2 _S65 = float2((64.0f * sc_0)) ;
            int2 _S66 = int2(floor(p_4 / _S65));
            if((hash2_0(_S66, fs_0 ^ 40503U)) < (_S64 * 0.079999998211860657f))
            {
                float r_1 = (1.0f + 2.5f * hash2_0(_S66, fs_0 + 3U)) * sc_0;
                float a_0 = 1.0f - smoothstep(r_1 * 0.5f, r_1, length(p_4 - (float2(_S66) + float2(0.10000000149011612f)  + float2(0.80000001192092896f)  * float2(hash2_0(_S66, fs_0 + 1U), hash2_0(_S66, fs_0 + 2U))) * _S65));
                if((hash2_0(_S66, fs_0 + 4U)) > 0.5f)
                {

#line 77
                    _S52.xyz = mix(_S52.xyz, float3(0.89999997615814209f)  * float3(_S52.w) , float3(a_0) );

#line 77
                }
                else
                {

#line 78
                    _S52.xyz = _S52.xyz * float3((1.0f - 0.89999997615814209f * a_0)) ;

#line 77
                }

#line 73
            }

#line 69
        }

#line 81
        float _S67 = _S63.y;

#line 81
        if(_S67 > 0.0f)
        {

#line 82
            float _S68 = (float(gid_0.y) + 0.5f) / _S53.y;

#line 82
            uint k_1 = 0U;
            for(;;)
            {

#line 83
                if(k_1 < 3U)
                {
                }
                else
                {

#line 83
                    break;
                }

#line 84
                uint s_3 = pcg_0(fs_0 / 3U * 5U + k_1 * 977U + 13U);
                if((float(pcg_0(s_3 + 1U)) * 2.32830643653869629e-10f) >= _S67)
                {

#line 85
                    k_1 = k_1 + 1U;

#line 83
                    continue;
                }



                float y0_0 = float(pcg_0(s_3 + 4U)) * 2.32830643653869629e-10f;

                _S52.xyz = mix(_S52.xyz, float3(0.85000002384185791f)  * float3(_S52.w) , float3(((1.0f - smoothstep(0.0f, (0.80000001192092896f + float(pcg_0(s_3 + 3U)) * 2.32830643653869629e-10f) * sc_0, abs(float(gid_0.x) + 0.5f - float(pcg_0(s_3 + 2U)) * 2.32830643653869629e-10f * _S53.x))) * step(y0_0, _S68) * step(_S68, y0_0 + (0.40000000596046448f + 0.60000002384185791f * float(pcg_0(s_3 + 5U)) * 2.32830643653869629e-10f)) * 0.69999998807907104f)) );

#line 83
                k_1 = k_1 + 1U;

#line 83
            }

#line 81
        }

#line 65
    }

#line 96
    if((flags_0 & 8U) != 0U)
    {
        float f_2 = fract(float(gid_0.y) / max(L_0->scan_0.y * sc_0, 2.0f));

        float gapHalf_0 = L_0->scan_0.z * 0.5f;

        _S52.xyz = _S52.xyz * float3(mix(1.0f, smoothstep(gapHalf_0 - 0.11999999731779099f, gapHalf_0 + 0.11999999731779099f, min(f_2, 1.0f - f_2)), L_0->scan_0.x)) ;

#line 96
    }

#line 104
    return _S52;
}


#line 104
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 104
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
    bool _S69;

    if((kernelContext_6->cu_0->cornerRadius_0) > 0.0f)
    {

#line 14
        _S69 = true;

#line 14
    }
    else
    {

#line 14
        _S69 = (kernelContext_6->cu_0->rotSin_0) != 0.0f;

#line 14
    }

#line 14
    if(_S69)
    {

#line 14
        _S69 = true;

#line 14
    }
    else
    {

#line 14
        _S69 = (kernelContext_6->cu_0->tilt_0.z) > 0.0f;

#line 14
    }

#line 14
    if(_S69)
    {

#line 14
        _S69 = true;

#line 14
    }
    else
    {

#line 14
        bool _S70 = hasCrop_0(kernelContext_6);

#line 14
        _S69 = _S70;

#line 14
    }

#line 14
    if(_S69)
    {

#line 14
        _S69 = true;

#line 14
    }
    else
    {

#line 14
        _S69 = (kernelContext_6->cu_0->cropFeather_0) > 0.0f;

#line 14
    }

#line 14
    return _S69;
}


#line 14
float maskCoverage_0(float2 _S71, texture2d<float, access::sample> _S72, texture2d<float, access::sample> _S73, texture2d<float, access::sample> _S74, float3 _S75, KernelContext_0 thread* kernelContext_7)
{

#line 56 "crates/sq-gpu/shaders-src/Parts/Mask.slang"
    float _S76 = 1.0f / max(min(kernelContext_7->cu_0->scale_0.x, kernelContext_7->cu_0->scale_0.y), 9.9999997473787516e-05f);

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
        uint _S77 = m_1 * 4U;

#line 59
        float2 _S78 = maskAt_0(_S77, kernelContext_7);

#line 59
        float2 _S79 = maskAt_0(_S77 + 1U, kernelContext_7);

#line 59
        float2 _S80 = maskAt_0(_S77 + 2U, kernelContext_7);

#line 59
        float2 _S81 = maskAt_0(_S77 + 3U, kernelContext_7);
        uint start_2 = uint(_S78.x);

#line 60
        uint count_0 = uint(_S78.y);

#line 60
        uint mode_2 = uint(_S79.x);

#line 60
        bool _S82;
        if(m_1 == 0U)
        {

#line 61
            if(mode_2 == 1U)
            {

#line 61
                _S82 = true;

#line 61
            }
            else
            {

#line 61
                _S82 = mode_2 == 2U;

#line 61
            }

#line 61
        }
        else
        {

#line 61
            _S82 = false;

#line 61
        }

#line 61
        float acc_2;

#line 61
        if(_S82)
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
        float _S83 = _S81.y;

#line 62
        float d2_0;

#line 62
        float c_5;

#line 62
        float c_6;

#line 62
        bool inFrame_0;

#line 62
        bool _S84;

#line 62
        if(_S83 != 0.0f)
        {

#line 62
            float2 _S85 = kernelContext_7->cu_0->maskSize_0;

#line 62
            float2 ms_0;

            if((kernelContext_7->cu_0->maskSize_0.x) > 0.0f)
            {

#line 64
                ms_0 = _S85;

#line 64
            }
            else
            {

#line 64
                ms_0 = kernelContext_7->cu_0->size_0;

#line 64
            }
            float2 uv_1 = _S71 / ms_0 + float2(0.5f) ;
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


            if(_S83 == 10.0f)
            {

#line 69
                float _S86 = colorRangeValue_0(start_2, _S75, kernelContext_7);

#line 69
                c_5 = _S86;

#line 69
            }
            else
            {

#line 70
                if(_S83 >= 6.0f)
                {

#line 70
                    float _S87 = pictureSample_0(_S71, start_2, uint(_S83), _S73, _S74, kernelContext_7);

#line 70
                    c_5 = _S87;

#line 70
                }
                else
                {

#line 71
                    if(_S83 != 2.0f)
                    {

#line 71
                        _S84 = inFrame_0;

#line 71
                    }
                    else
                    {

#line 71
                        _S84 = false;

#line 71
                    }

#line 71
                    if(_S84)
                    {

#line 72
                        float4 s_4 = ((_S72).sample((kernelContext_7->edgeSampler_0), (uv_1), level((0.0f))));
                        if(_S83 == 1.0f)
                        {

#line 73
                            d2_0 = s_4.x;

#line 73
                        }
                        else
                        {

#line 73
                            if(_S83 == 3.0f)
                            {

#line 73
                                d2_0 = s_4.y;

#line 73
                            }
                            else
                            {

#line 73
                                if(_S83 == 4.0f)
                                {

#line 73
                                    d2_0 = s_4.z;

#line 73
                                }
                                else
                                {

#line 73
                                    d2_0 = s_4.w;

#line 73
                                }

#line 73
                            }

#line 73
                        }

#line 73
                        c_5 = clamp(d2_0, 0.0f, 1.0f);

#line 71
                    }
                    else
                    {

#line 71
                        c_5 = 0.0f;

#line 71
                    }

#line 70
                }

#line 69
            }

#line 75
            if((_S79.y) != 0.0f)
            {

#line 75
                c_6 = 1.0f - c_5;

#line 75
            }
            else
            {

#line 75
                c_6 = c_5;

#line 75
            }

#line 75
            acc_1 = maskCombine_0(acc_2, c_6 * _S81.x, mode_2);


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
            uint _S88 = start_2 + count_0;

#line 83
            uint j_0 = _S88 - 1U;

#line 83
            d2_0 = 1.00000001504746622e+30f;

#line 83
            inFrame_0 = false;

#line 83
            uint i_2 = start_2;
            for(;;)
            {

#line 84
                if(i_2 < _S88)
                {
                }
                else
                {

#line 84
                    break;
                }

#line 84
                float2 _S89 = maskAt_0(j_0, kernelContext_7);

#line 84
                float2 _S90 = maskAt_0(i_2, kernelContext_7);

                float2 e_1 = _S90 - _S89;

#line 86
                float2 w_3 = _S71 - _S89;
                float ee_0 = dot(e_1, e_1);
                if(ee_0 > 0.0f)
                {

#line 88
                    d_2 = clamp(dot(w_3, e_1) / ee_0, 0.0f, 1.0f);

#line 88
                }
                else
                {

#line 88
                    d_2 = 0.0f;

#line 88
                }
                float2 q_0 = w_3 - e_1 * float2(d_2) ;
                float _S91 = min(d2_0, dot(q_0, q_0));
                float _S92 = _S90.y;

#line 91
                float _S93 = _S71.y;

#line 91
                float _S94 = _S89.y;

#line 91
                if((_S92 > _S93) != (_S94 > _S93))
                {

#line 91
                    float _S95 = _S90.x;

#line 91
                    _S84 = (_S71.x) < ((_S89.x - _S95) * (_S93 - _S92) / (_S94 - _S92) + _S95);

#line 91
                }
                else
                {

#line 91
                    _S84 = false;

#line 91
                }

#line 91
                if(_S84)
                {

#line 91
                    inFrame_0 = !inFrame_0;

#line 91
                }

#line 84
                uint _S96 = i_2 + 1U;

#line 84
                j_0 = i_2;

#line 84
                i_2 = _S96;

#line 84
                d2_0 = _S91;

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
        float d_4 = d_2 - _S80.y;

        float _S97 = _S80.x;

#line 99
        if(_S97 > _S76)
        {

#line 100
            float hh_0 = _S97 * 0.5f;
            float x_2 = clamp((d_4 + hh_0) / (2.0f * hh_0), 0.0f, 1.0f);

#line 101
            c_5 = 1.0f - x_2 * x_2 * (3.0f - 2.0f * x_2);

#line 99
        }
        else
        {

#line 99
            c_5 = clamp(0.5f - d_4 / _S76, 0.0f, 1.0f);

#line 99
        }

#line 106
        if((_S79.y) != 0.0f)
        {

#line 106
            c_6 = 1.0f - c_5;

#line 106
        }
        else
        {

#line 106
            c_6 = c_5;

#line 106
        }

#line 106
        acc_1 = maskCombine_0(acc_2, c_6 * _S81.x, mode_2);

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
    bool _S98;

#line 89 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
    if((kernelContext_8->cu_0->matte0_0.z) == 1.0f)
    {

#line 89
        _S98 = true;

#line 89
    }
    else
    {

#line 89
        if((kernelContext_8->cu_0->keyCount_0) > 1U)
        {

#line 89
            _S98 = (kernelContext_8->cu_0->matte1_0.z) == 1.0f;

#line 89
        }
        else
        {

#line 89
            _S98 = false;

#line 89
        }

#line 89
    }

#line 89
    return _S98;
}


#line 89
bool alphaSource_0(KernelContext_0 thread* kernelContext_9)
{

#line 89
    uint _S99 = kernelContext_9->cu_0->mode_0;

#line 89
    bool _S100;

#line 44 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
    if((kernelContext_9->cu_0->mode_0) == 4U)
    {

#line 44
        _S100 = true;

#line 44
    }
    else
    {

#line 44
        if(_S99 == 1U)
        {

#line 44
            _S100 = (kernelContext_9->cu_0->alphaMode_0) != 0U;

#line 44
        }
        else
        {

#line 44
            _S100 = false;

#line 44
        }

#line 44
    }

#line 44
    return _S100;
}


#line 44
float3 ycbcrToRGB_0(float3 _S101, KernelContext_0 thread* kernelContext_10)
{

#line 5
    return kernelContext_10->cu_0->m0_0.xyz * float3(_S101.x)  + kernelContext_10->cu_0->m1_0.xyz * float3(_S101.y)  + kernelContext_10->cu_0->m2_0.xyz * float3(_S101.z) ;
}


#line 5
float4 texelPremul_0(texture2d<float, access::sample> _S102, uint2 _S103, KernelContext_0 thread* kernelContext_11)
{

#line 19
    int3 _S104 = int3(int2(_S103), int(0));

#line 19
    float4 t_2 = ((_S102).read(vec<uint,2>(((_S104)).xy), uint(((_S104)).z)));
    thread float4 c_7;
    if((kernelContext_11->cu_0->mode_0) == 4U)
    {

#line 22
        float _S105 = kernelContext_11->cu_0->range_0.z;

#line 22
        float _S106 = kernelContext_11->cu_0->range_0.w;

#line 22
        float3 _S107 = ycbcrToRGB_0(float3(t_2.y * kernelContext_11->cu_0->range_0.x + kernelContext_11->cu_0->range_0.y, t_2.z * _S105 + _S106, t_2.w * _S105 + _S106), kernelContext_11);
        c_7 = float4(_S107, t_2.x);

#line 21
    }
    else
    {

        c_7 = t_2;

#line 21
    }

#line 28
    if((kernelContext_11->cu_0->alphaMode_0) == 2U)
    {

#line 28
        c_7.xyz = clamp(c_7.xyz, float3(0.0f) , float3(c_7.w) );

#line 28
    }
    else
    {

#line 28
        c_7.xyz = c_7.xyz * float3(c_7.w) ;

#line 28
    }
    return c_7;
}


#line 29
float4 samplePremul_0(texture2d<float, access::sample> _S108, float2 _S109, KernelContext_0 thread* kernelContext_12)
{

#line 29
    int2 _S110 = int2(int(1)) ;

#line 34
    int2 mx_0 = int2(texSize_0(_S108)) - _S110;
    float2 p_5 = _S109 * float2(mx_0 + _S110) - float2(0.5f) ;
    float2 fl_1 = floor(p_5);

#line 36
    float2 f_3 = p_5 - fl_1;
    int2 _S111 = int2(fl_1);
    int2 _S112 = int2(int(0)) ;

#line 38
    uint2 _S113 = uint2(clamp(_S111, _S112, mx_0));

#line 38
    uint2 _S114 = uint2(clamp(_S111 + _S110, _S112, mx_0));

#line 38
    float4 _S115 = texelPremul_0(_S108, _S113, kernelContext_12);

#line 38
    float4 _S116 = texelPremul_0(_S108, uint2(_S114.x, _S113.y), kernelContext_12);

#line 38
    float4 _S117 = texelPremul_0(_S108, uint2(_S113.x, _S114.y), kernelContext_12);

#line 38
    float4 _S118 = texelPremul_0(_S108, _S114, kernelContext_12);


    float4 _S119 = float4(f_3.x) ;

#line 41
    return mix(mix(_S115, _S116, _S119), mix(_S117, _S118, _S119), float4(f_3.y) );
}


#line 41
float3 sourceEncoded_0(texture2d<float, access::sample> _S120, texture2d<float, access::sample> _S121, float2 _S122, KernelContext_0 thread* kernelContext_13)
{

#line 10
    if((kernelContext_13->cu_0->mode_0) == 1U)
    {

#line 10
        return ((_S120).sample((kernelContext_13->edgeSampler_0), (_S122), level((0.0f)))).xyz;
    }
    float2 c_8 = ((_S121).sample((kernelContext_13->edgeSampler_0), (_S122), level((0.0f)))).xy * float2(kernelContext_13->cu_0->range_0.z)  + float2(kernelContext_13->cu_0->range_0.w) ;

#line 12
    float3 _S123 = ycbcrToRGB_0(float3(((_S120).sample((kernelContext_13->edgeSampler_0), (_S122), level((0.0f)))).x * kernelContext_13->cu_0->range_0.x + kernelContext_13->cu_0->range_0.y, c_8.x, c_8.y), kernelContext_13);
    return _S123;
}


#line 13
float4 shadeLayer_0(const VOut_0 thread* _S124, texture2d<float, access::sample> _S125, texture2d<float, access::sample> _S126, texture2d<float, access::sample> _S127, texture2d<float, access::sample> _S128, texture2d<float, access::sample> _S129, KernelContext_0 thread* kernelContext_14)
{

#line 13
    bool _S130 = edgeAA_0(kernelContext_14);

#line 13
    float2 uv_2;

#line 13
    float cover_0;

#line 94 "crates/sq-gpu/shaders-src/Parts/Layer.slang"
    if(_S130)
    {

#line 94
        float2 _S131 = kernelContext_14->cu_0->maskSize_0;

        if((kernelContext_14->cu_0->maskSize_0.x) > 0.0f)
        {

#line 96
            uv_2 = _S131;

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
        float2 _S132 = float2(0.5f) ;
        float2 _S133 = _S132 * uv_2;

#line 98
        float2 hi_0 = _S133 - kernelContext_14->cu_0->crop_0.zw * uv_2;
        float2 c_9 = _S132 * (lo_0 + hi_0);
        float2 h_4 = _S132 * (hi_0 - lo_0);

        if((kernelContext_14->cu_0->roundFirst_0) != 0U)
        {

            float _S134 = min(kernelContext_14->cu_0->cornerRadius_0, min(_S133.x, _S133.y));
            float2 q0_0 = abs(_S124->local_1) - _S133 + float2(_S134) ;
            float2 _S135 = float2(0.0f) ;
            float2 q1_0 = abs(_S124->local_1 - c_9) - h_4;

#line 108
            cover_0 = max(length(max(q0_0, _S135)) + min(max(q0_0.x, q0_0.y), 0.0f) - _S134, length(max(q1_0, _S135)) + min(max(q1_0.x, q1_0.y), 0.0f));

#line 102
        }
        else
        {

#line 112
            float _S136 = min(kernelContext_14->cu_0->cornerRadius_0, min(h_4.x, h_4.y));
            float2 q_1 = abs(_S124->local_1 - c_9) - h_4 + float2(_S136) ;

#line 113
            cover_0 = length(max(q_1, float2(0.0f) )) + min(max(q_1.x, q_1.y), 0.0f) - _S136;

#line 102
        }

#line 116
        float w_4 = 1.0f / max(min(kernelContext_14->cu_0->scale_0.x, kernelContext_14->cu_0->scale_0.y), 9.9999997473787516e-05f);

#line 116
        float _S137 = kernelContext_14->cu_0->cropFeather_0;

        if((kernelContext_14->cu_0->cropFeather_0) > 0.0f)
        {

#line 118
            cover_0 = clamp((0.5f * w_4 - cover_0) / (w_4 + _S137), 0.0f, 1.0f);

#line 118
        }
        else
        {

#line 118
            cover_0 = clamp(0.5f - cover_0 / w_4, 0.0f, 1.0f);

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
    float2 _S138 = _S124->local_1;

#line 94
    float2 _S139 = float2(0.5f) ;

#line 121
    float2 uv_3 = _S124->local_1 / kernelContext_14->cu_0->size_0 + _S139;

#line 121
    uint _S140 = kernelContext_14->cu_0->mode_0;

#line 121
    bool _S141;
    if((kernelContext_14->cu_0->mode_0) != 3U)
    {

#line 122
        _S141 = (kernelContext_14->cu_0->quarter_0) != 0U;

#line 122
    }
    else
    {

#line 122
        _S141 = false;

#line 122
    }

#line 122
    if(_S141)
    {

#line 122
        uint _S142 = kernelContext_14->cu_0->quarter_0;

        if((kernelContext_14->cu_0->quarter_0) == 1U)
        {

#line 124
            uv_2 = float2(uv_3.y, 1.0f - uv_3.x);

#line 124
        }
        else
        {

#line 125
            if(_S142 == 2U)
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
    if(_S140 == 3U)
    {

#line 128
        float4 _S143 = kernelContext_14->cu_0->part_0;

#line 128
        float4 g_0;

        if((kernelContext_14->cu_0->part_0.z) > 0.0f)
        {

            float2 _S144 = _S143.zw;

#line 133
            float4 _S145 = samplePartTexels_0(_S125, clamp(uv_2 * _S144, float2(0.5f) , _S144 - _S139) - _S143.xy, kernelContext_14);

#line 133
            g_0 = _S145;

#line 130
        }
        else
        {

#line 130
            g_0 = ((_S125).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));

#line 130
        }

#line 138
        if((kernelContext_14->cu_0->maskCount_0) > 0U)
        {

#line 139
            float _S146 = g_0.w;

#line 139
            if(_S146 > 0.0f)
            {

#line 139
                pc_1 = oetf709_0(clamp(g_0.xyz / float3(_S146) , float3(0.0f) , float3(1.0f) ));

#line 139
            }
            else
            {

#line 139
                pc_1 = float3(0.0f) ;

#line 139
            }

#line 139
            float _S147 = maskCoverage_0(_S138, _S127, _S128, _S129, pc_1, kernelContext_14);

#line 139
            cover_0 = cover_0 * _S147;

#line 138
        }

#line 138
        uint _S148 = kernelContext_14->cu_0->keyCount_0;



        if((kernelContext_14->cu_0->keyCount_0) > 0U)
        {

#line 142
            _S141 = (g_0.w) > 0.0f;

#line 142
        }
        else
        {

#line 142
            _S141 = false;

#line 142
        }

#line 142
        if(_S141)
        {
            float _S149 = g_0.w;

#line 144
            float3 _S150 = float3(_S149) ;

#line 144
            thread float3 c_10 = g_0.xyz / _S150;
            float _S151 = applyChromaKey_0(kernelContext_14->cu_0->key0_0, kernelContext_14->cu_0->matte0_0, kernelContext_14->cu_0->shape0_0, kernelContext_14->cu_0->cc0_0, &c_10);

#line 145
            float kept_1 = 1.0f - _S151;
            if(_S148 > 1U)
            {

#line 146
                float _S152 = applyChromaKey_0(kernelContext_14->cu_0->key1_0, kernelContext_14->cu_0->matte1_0, kernelContext_14->cu_0->shape1_0, kernelContext_14->cu_0->cc1_0, &c_10);

#line 146
                kept_0 = kept_1 * (1.0f - _S152);

#line 146
            }
            else
            {

#line 146
                kept_0 = kept_1;

#line 146
            }

#line 146
            bool _S153 = keyMatteView_0(kernelContext_14);
            if(_S153)
            {

#line 147
                g_0 = float4(float3(kept_0)  * _S150, _S149);

#line 147
            }
            else
            {

#line 147
                g_0 = float4(c_10 * _S150 * float3(kept_0) , _S149 * kept_0);

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
    if(_S140 == 2U)
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
        bool _S154 = alphaSource_0(kernelContext_14);

        if(_S154)
        {

#line 157
            float4 _S155 = samplePremul_0(_S125, uv_2, kernelContext_14);



            float texA_1 = _S155.w;
            if(texA_1 > 0.0f)
            {

#line 162
                pc_1 = _S155.xyz / float3(texA_1) ;

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



            bool _S156 = _S140 == 1U;

#line 163
            if(_S156)
            {

#line 163
                _S141 = (kernelContext_14->cu_0->linearize_0) != 0U;

#line 163
            }
            else
            {

#line 163
                _S141 = false;

#line 163
            }

#line 163
            if(_S141)
            {
                float4 c_11 = ((_S125).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));
                float texA_2 = c_11.w;
                if(texA_2 > 0.0f)
                {

#line 167
                    pc_1 = c_11.xyz / float3(texA_2) ;

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


                if(_S156)
                {
                    float4 c_12 = ((_S125).sample((kernelContext_14->edgeSampler_0), (uv_2), level((0.0f))));
                    float _S157 = c_12.w;
                    rgb_0 = c_12.xyz;

#line 172
                    texA_0 = _S157;

#line 168
                }
                else
                {

#line 168
                    float3 _S158 = sourceEncoded_0(_S125, _S126, uv_2, kernelContext_14);

#line 174
                    rgb_0 = _S158;

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
    bool _S159 = _S140 != 2U;

#line 176
    if(_S159)
    {

#line 176
        _S141 = (kernelContext_14->cu_0->linearize_0) != 0U;

#line 176
    }
    else
    {

#line 176
        _S141 = false;

#line 176
    }

#line 176
    if(_S141)
    {

#line 176
        rgb_0 = inverseOETF709_0(rgb_0);

#line 176
    }
    float3 _S160 = float3(0.0f) ;

#line 177
    rgb_0 = max(rgb_0, _S160);

    if((kernelContext_14->cu_0->maskCount_0) > 0U)
    {

#line 179
        float _S161 = maskCoverage_0(_S138, _S127, _S128, _S129, oetf709_0(clamp(rgb_0, _S160, float3(1.0f) )), kernelContext_14);

#line 179
        cover_0 = cover_0 * _S161;

#line 179
    }
    if(_S159)
    {

#line 180
        _S141 = (kernelContext_14->cu_0->keyCount_0) > 0U;

#line 180
    }
    else
    {

#line 180
        _S141 = false;

#line 180
    }

#line 180
    if(_S141)
    {

#line 181
        float _S162 = applyChromaKey_0(kernelContext_14->cu_0->key0_0, kernelContext_14->cu_0->matte0_0, kernelContext_14->cu_0->shape0_0, kernelContext_14->cu_0->cc0_0, &rgb_0);

#line 181
        float kept_2 = 1.0f - _S162;
        if((kernelContext_14->cu_0->keyCount_0) > 1U)
        {

#line 182
            float _S163 = applyChromaKey_0(kernelContext_14->cu_0->key1_0, kernelContext_14->cu_0->matte1_0, kernelContext_14->cu_0->shape1_0, kernelContext_14->cu_0->cc1_0, &rgb_0);

#line 182
            kept_0 = kept_2 * (1.0f - _S163);

#line 182
        }
        else
        {

#line 182
            kept_0 = kept_2;

#line 182
        }

#line 182
        bool _S164 = keyMatteView_0(kernelContext_14);
        if(_S164)
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
    float a_1 = kernelContext_14->cu_0->opacity_0 * cover_0 * texA_0;
    return float4(rgb_0 * float3(a_1) , a_1);
}


#line 17 "crates/sq-gpu/shaders-src/LayerLook.slang"
[[fragment]] pixelOutput_0 compositeFragmentLook(pixelInput_0 _S165 [[stage_in]], float4 position_2 [[position]], CompositeU_0 constant* cu_1 [[buffer(0)]], sampler zeroSampler_1 [[sampler(0)]], sampler edgeSampler_1 [[sampler(1)]], uint32_t device* maskData_1 [[buffer(2)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture2d<float, access::sample> in4_1 [[texture(4)]], texture2d<float, access::sample> in5_1 [[texture(5)]], LookU_0 constant* lu_1 [[buffer(1)]])
{

#line 17
    thread KernelContext_0 kernelContext_15;

#line 17
    (&kernelContext_15)->cu_0 = cu_1;

#line 17
    (&kernelContext_15)->zeroSampler_0 = zeroSampler_1;

#line 17
    (&kernelContext_15)->edgeSampler_0 = edgeSampler_1;

#line 17
    (&kernelContext_15)->maskData_0 = maskData_1;

#line 17
    (&kernelContext_15)->in0_0 = in0_1;

#line 17
    (&kernelContext_15)->in1_0 = in1_1;

#line 17
    (&kernelContext_15)->in3_0 = in3_1;

#line 17
    (&kernelContext_15)->in4_0 = in4_1;

#line 17
    (&kernelContext_15)->in5_0 = in5_1;

#line 17
    (&kernelContext_15)->lu_0 = lu_1;

#line 17
    thread VOut_0 _S166;

#line 17
    (&_S166)->position_1 = position_2;

#line 17
    (&_S166)->local_1 = _S165.local_0;

#line 17
    float4 _S167 = shadeLayer_0(&_S166, in0_1, in1_1, in3_1, in4_1, in5_1, &kernelContext_15);

#line 17
    float4 _S168 = lookPointwise_0(float4(targetHalf_0(_S167.x), targetHalf_0(_S167.y), targetHalf_0(_S167.z), targetHalf_0(_S167.w)), 0.0f, uint2(position_2.xy), (&kernelContext_15)->lu_0);

#line 17
    pixelOutput_0 _S169 = { _S168 };


    return _S169;
}


#line 20
struct compositeVertex_Result_0
{
    float4 position_3 [[position]];
    float2 local_2 [[user(LOCAL)]];
};


#line 20
[[vertex]] compositeVertex_Result_0 compositeVertex(uint vid_0 [[vertex_id]], CompositeU_0 constant* cu_2 [[buffer(0)]], sampler zeroSampler_2 [[sampler(0)]], sampler edgeSampler_2 [[sampler(1)]], uint32_t device* maskData_2 [[buffer(2)]], texture2d<float, access::sample> in0_2 [[texture(0)]], texture2d<float, access::sample> in1_2 [[texture(1)]], texture2d<float, access::sample> in3_2 [[texture(3)]], texture2d<float, access::sample> in4_2 [[texture(4)]], texture2d<float, access::sample> in5_2 [[texture(5)]], LookU_0 constant* lu_2 [[buffer(1)]])
{

#line 20
    thread KernelContext_0 kernelContext_16;

#line 20
    (&kernelContext_16)->cu_0 = cu_2;

#line 20
    (&kernelContext_16)->zeroSampler_0 = zeroSampler_2;

#line 20
    (&kernelContext_16)->edgeSampler_0 = edgeSampler_2;

#line 20
    (&kernelContext_16)->maskData_0 = maskData_2;

#line 20
    (&kernelContext_16)->in0_0 = in0_2;

#line 20
    (&kernelContext_16)->in1_0 = in1_2;

#line 20
    (&kernelContext_16)->in3_0 = in3_2;

#line 20
    (&kernelContext_16)->in4_0 = in4_2;

#line 20
    (&kernelContext_16)->in5_0 = in5_2;

#line 20
    (&kernelContext_16)->lu_0 = lu_2;

#line 28 "crates/sq-gpu/shaders-src/Parts/LayerVertex.slang"
    float2 uv_4 = float2(float(vid_0 & 1U), float(vid_0 >> 1U));

#line 28
    float2 _S170 = float2(0.5f) ;
    float2 local_3 = (uv_4 - _S170) * cu_2->size_0;

#line 29
    bool _S171 = edgeAA_0(&kernelContext_16);

#line 29
    float2 local_4;
    if(_S171)
    {

#line 30
        float2 _S172 = float2(1.0f) ;

#line 30
        local_4 = local_3 + (uv_4 * float2(2.0f)  - _S172) * (_S172 / max((&kernelContext_16)->cu_0->scale_0, float2(9.9999997473787516e-05f) ));

#line 30
    }
    else
    {

#line 30
        local_4 = local_3;

#line 30
    }
    float2 p_6 = (local_4 - (&kernelContext_16)->cu_0->anchor_0) * (&kernelContext_16)->cu_0->scale_0;
    float _S173 = p_6.x;

#line 32
    float _S174 = p_6.y;

#line 32
    float _S175 = (&kernelContext_16)->cu_0->rotCos_0 * _S173 - (&kernelContext_16)->cu_0->rotSin_0 * _S174;

#line 32
    float _S176 = (&kernelContext_16)->cu_0->rotSin_0 * _S173 + (&kernelContext_16)->cu_0->rotCos_0 * _S174;

#line 32
    float2 r_2 = float2(_S175, _S176);

#line 32
    float4 _S177 = (&kernelContext_16)->cu_0->tilt_0;

    float _S178 = (&kernelContext_16)->cu_0->tilt_0.z;

#line 34
    float2 r_3;

#line 34
    float w_5;

#line 34
    if(_S178 > 0.0f)
    {
        float _S179 = _S177.x;

#line 36
        float _S180 = _S177.y;

#line 36
        float cb_1 = cos(_S180);

#line 36
        float sb_1 = sin(_S180);
        float z1_1 = - _S176 * sin(_S179);

        float _S181 = max((_S178 + (_S175 * sb_1 + z1_1 * cb_1)) / _S178, 0.0010000000474974513f);

#line 39
        r_3 = float2(_S175 * cb_1 - z1_1 * sb_1, _S176 * cos(_S179)) / float2(_S181) ;

#line 39
        w_5 = _S181;

#line 34
    }
    else
    {

#line 34
        r_3 = r_2;

#line 34
        w_5 = 1.0f;

#line 34
    }

#line 42
    float2 px_0 = (&kernelContext_16)->cu_0->canvas_0 * _S170 + (&kernelContext_16)->cu_0->position_0 + r_3;
    thread VOut_0 o_0;

    (&o_0)->position_1 = float4(float2(px_0.x / (&kernelContext_16)->cu_0->canvas_0.x * 2.0f - 1.0f, 1.0f - px_0.y / (&kernelContext_16)->cu_0->canvas_0.y * 2.0f) * float2(w_5) , 0.0f, w_5);
    (&o_0)->local_1 = local_4;
    VOut_0 _S182 = o_0;

#line 47
    thread compositeVertex_Result_0 _S183;

#line 47
    (&_S183)->position_3 = _S182.position_1;

#line 47
    (&_S183)->local_2 = _S182.local_1;

#line 47
    return _S183;
}

