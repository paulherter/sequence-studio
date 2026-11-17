#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 19 "crates/sq-gpu/shaders-src/Parts/Transition.slang"
struct TransitionRows_0
{
    float4 r0_0;
    float4 r1_0;
    float4 r2_0;
    float4 r3_0;
    float4 r4_0;
    float4 r5_0;
    float4 r6_0;
    float2 r7_0;
};


#line 7 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    texture2d<float, access::write> out0_0;
    uint32_t device* cover_0;
    TransitionRows_0 constant* tr_0;
    sampler zeroSampler_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in1_0;
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


#line 10 "crates/sq-gpu/shaders-src/Parts/Transition.slang"
struct TransitionSideU_0
{
    float2 offset_0;
    float2 blur_0;
    float scale_0;
    float opacity_0;
    float zoomBlur_0;
    float taps_0;
    float rotation_0;
    float mirror_0;
};


#line 11
struct TransitionU_0
{
    TransitionSideU_0 a_0;
    TransitionSideU_0 b_0;
    float2 wipeDir_0;
    float wipeFront_0;
    float wipeSoft_0;
    uint compose_0;
    float borderWidth_0;
    float borderR_0;
    float borderG_0;
    float borderB_0;
};


#line 29
TransitionU_0 transitionFromRows_0(const TransitionRows_0 constant* r_0)
{

#line 30
    thread TransitionU_0 u_0;
    (&(&u_0)->a_0)->offset_0 = r_0->r0_0.xy;

#line 31
    (&(&u_0)->a_0)->blur_0 = r_0->r0_0.zw;
    (&(&u_0)->a_0)->scale_0 = r_0->r1_0.x;

#line 32
    (&(&u_0)->a_0)->opacity_0 = r_0->r1_0.y;

#line 32
    (&(&u_0)->a_0)->zoomBlur_0 = r_0->r1_0.z;

#line 32
    (&(&u_0)->a_0)->taps_0 = r_0->r1_0.w;
    (&(&u_0)->a_0)->rotation_0 = r_0->r2_0.x;

#line 33
    (&(&u_0)->a_0)->mirror_0 = r_0->r2_0.y;
    (&(&u_0)->b_0)->offset_0 = r_0->r2_0.zw;

#line 34
    (&(&u_0)->b_0)->blur_0 = r_0->r3_0.xy;
    (&(&u_0)->b_0)->scale_0 = r_0->r3_0.z;

#line 35
    (&(&u_0)->b_0)->opacity_0 = r_0->r3_0.w;

#line 35
    (&(&u_0)->b_0)->zoomBlur_0 = r_0->r4_0.x;

#line 35
    (&(&u_0)->b_0)->taps_0 = r_0->r4_0.y;
    (&(&u_0)->b_0)->rotation_0 = r_0->r4_0.z;

#line 36
    (&(&u_0)->b_0)->mirror_0 = r_0->r4_0.w;
    (&u_0)->wipeDir_0 = r_0->r5_0.xy;

#line 37
    (&u_0)->wipeFront_0 = r_0->r5_0.z;

#line 37
    (&u_0)->wipeSoft_0 = r_0->r5_0.w;
    (&u_0)->compose_0 = (as_type<uint>((r_0->r6_0.x)));

#line 38
    (&u_0)->borderWidth_0 = r_0->r6_0.y;

#line 38
    (&u_0)->borderR_0 = r_0->r6_0.z;

#line 38
    (&u_0)->borderG_0 = r_0->r6_0.w;

#line 38
    (&u_0)->borderB_0 = r_0->r7_0.x;
    return u_0;
}

float4 sideSample_0(texture2d<float, access::sample> t_0, float2 q_0, bool mirror_1, KernelContext_0 thread* kernelContext_1)
{

#line 42
    float2 _S2;

#line 42
    float2 _S3;


    if(mirror_1)
    {

#line 46
        thread uint w_1;

#line 46
        thread uint h_1;
        (*((&w_1)) = (t_0).get_width(0)),(*((&h_1)) = (t_0).get_height(0));
        float2 hf_0 = float2(0.5f)  / float2(float(w_1), float(h_1));
        float2 _S4 = abs(q_0);

#line 49
        for(;;)
        {

#line 49
            thread float2 result_0;

#line 49
            int i_0 = int(0);

#line 49
            for(;;)
            {

#line 49
                if(i_0 < int(2))
                {
                }
                else
                {

#line 49
                    break;
                }

#line 49
                result_0[i_0] = fmod(_S4[i_0], 2.0f);

#line 49
                i_0 = i_0 + int(1);

#line 49
            }

#line 49
            _S2 = result_0;

#line 49
            break;
        }

#line 49
        float2 _S5 = float2(1.0f) ;

#line 49
        _S3 = clamp(_S5 - abs(_S5 - _S2), hf_0, _S5 - hf_0);

#line 45
    }
    else
    {

#line 45
        _S3 = q_0;

#line 45
    }

#line 51
    return ((t_0).sample((kernelContext_1->zeroSampler_0), (_S3), level((0.0f))));
}

float4 transitionSide_0(texture2d<float, access::sample> t_1, float2 uv_0, const TransitionSideU_0 thread* s_0, float2 px_0, KernelContext_0 thread* kernelContext_2)
{

#line 54
    float _S6 = s_0->opacity_0;
    if((s_0->opacity_0) <= 0.0f)
    {

#line 55
        return float4(0.0f) ;
    }

#line 56
    bool m_0 = (s_0->mirror_0) > 0.5f;
    float _S7 = max(s_0->scale_0, 9.9999997473787516e-05f);

#line 57
    float2 _S8 = float2(0.5f) ;
    float2 q0_0 = uv_0 - _S8 - s_0->offset_0;

#line 58
    float _S9 = s_0->rotation_0;

#line 58
    float2 q0_1;
    if((s_0->rotation_0) != 0.0f)
    {
        float cr_0 = cos(_S9);

#line 61
        float sr_0 = sin(_S9);
        float2 pp_0 = q0_0 * px_0;
        float _S10 = pp_0.x;

#line 63
        float _S11 = pp_0.y;

#line 63
        q0_1 = float2(cr_0 * _S10 + sr_0 * _S11, - sr_0 * _S10 + cr_0 * _S11) / px_0;

#line 59
    }
    else
    {

#line 59
        q0_1 = q0_0;

#line 59
    }

#line 59
    float2 _S12 = float2(_S7) ;

#line 65
    float2 q_1 = q0_1 / _S12 + _S8;
    float2 bl_0 = s_0->blur_0 / _S12;

#line 66
    float _S13 = s_0->zoomBlur_0;

    float _S14 = abs(s_0->zoomBlur_0);

#line 68
    float _S15 = max(length(bl_0 * px_0), length((q_1 - _S8) * px_0) * _S14);

#line 68
    float _S16 = s_0->taps_0;

#line 68
    bool heavy_0;


    if((s_0->taps_0) <= 0.0f)
    {

#line 71
        heavy_0 = _S14 > 0.10000000149011612f;

#line 71
    }
    else
    {

#line 71
        heavy_0 = false;

#line 71
    }

#line 71
    int n_0;
    if(_S16 > 0.0f)
    {

#line 72
        n_0 = int(_S16);

#line 72
    }
    else
    {

#line 72
        int _S17 = int(ceil(_S15 / 1.5f)) + int(1);

#line 72
        if(heavy_0)
        {

#line 72
            n_0 = int(24);

#line 72
        }
        else
        {

#line 72
            n_0 = int(256);

#line 72
        }

#line 72
        n_0 = clamp(_S17, int(1), n_0);

#line 72
    }
    if(n_0 <= int(1))
    {

#line 73
        float4 _S18 = sideSample_0(t_1, q_1, m_0, kernelContext_2);

#line 73
        return _S18 * float4(_S6) ;
    }

#line 74
    float4 _S19 = float4(0.0f) ;

    float _S20 = fract(52.982917785644531f * fract(dot(uv_0 * px_0, float2(0.067110560834407806f, 0.0058371499180793762f))));

#line 76
    int k_0 = int(0);

#line 76
    float4 acc_0 = _S19;
    for(;;)
    {

#line 77
        if(k_0 < n_0)
        {
        }
        else
        {

#line 77
            break;
        }

#line 77
        float f_0;
        if(heavy_0)
        {

#line 78
            f_0 = (float(k_0) + _S20) / float(n_0) - 0.5f;

#line 78
        }
        else
        {

#line 78
            f_0 = float(k_0) / float(n_0 - int(1)) - 0.5f;

#line 78
        }

#line 78
        float4 _S21 = sideSample_0(t_1, _S8 + (q_1 + bl_0 * float2(f_0)  - _S8) * float2((1.0f + _S13 * f_0)) , m_0, kernelContext_2);


        float4 acc_1 = acc_0 + _S21;

#line 77
        k_0 = k_0 + int(1);

#line 77
        acc_0 = acc_1;

#line 77
    }

#line 83
    return acc_0 / float4(float(n_0))  * float4(_S6) ;
}


float4 sideOf_0(bool second_0, texture2d<float, access::sample> ta_0, texture2d<float, access::sample> tb_0, float2 uv_1, const TransitionU_0 thread* u_1, float2 px_1, KernelContext_0 thread* kernelContext_3)
{

#line 88
    if(second_0)
    {

#line 88
        float4 _S22 = transitionSide_0(tb_0, uv_1, &u_1->b_0, px_1, kernelContext_3);

#line 88
        return _S22;
    }

#line 88
    float4 _S23 = transitionSide_0(ta_0, uv_1, &u_1->a_0, px_1, kernelContext_3);
    return _S23;
}

float lnHash_0(float2 p_0)
{

#line 93
    uint2 _S24 = uint2(int2(p_0) + int2(int(4096)) );
    uint h_2 = (_S24.x * 2654435761U) ^ (_S24.y * 2246822507U);
    uint h_3 = (h_2 ^ (h_2 >> 15U)) * 739982445U;

#line 95
    uint h_4 = (h_3 ^ (h_3 >> 12U)) * 695872825U;
    return float((h_4 ^ (h_4 >> 15U)) & 65535U) / 65535.0f;
}



float4 transitionCompose_0(texture2d<float, access::sample> ta_1, texture2d<float, access::sample> tb_1, const TransitionU_0 thread* u_2, uint2 gid_0, float2 px_2, float2 cover_1, KernelContext_0 thread* kernelContext_4)
{

#line 101
    thread TransitionU_0 _S25 = *u_2;
    if((cover_1.x) < 0.99900001287460327f)
    {

#line 102
        (&(&_S25)->a_0)->mirror_0 = 0.0f;

#line 102
    }
    if((cover_1.y) < 0.99900001287460327f)
    {

#line 103
        (&(&_S25)->b_0)->mirror_0 = 0.0f;

#line 103
    }
    float2 _S26 = float2(gid_0);

#line 104
    float2 _S27 = float2(0.5f) ;

#line 104
    float2 uv_2 = (_S26 + _S27) / px_2;

#line 104
    thread TransitionSideU_0 _S28 = (&_S25)->a_0;

#line 104
    float4 _S29 = transitionSide_0(ta_1, uv_2, &_S28, px_2, kernelContext_4);

#line 104
    thread TransitionSideU_0 _S30 = (&_S25)->b_0;

#line 104
    float4 _S31 = transitionSide_0(tb_1, uv_2, &_S30, px_2, kernelContext_4);

    thread float4 c_0;
    if(((&_S25)->compose_0) == 1U)
    {

#line 107
        c_0 = _S31 + _S29 * float4((1.0f - _S31.w)) ;

#line 107
    }
    else
    {

#line 108
        if(((&_S25)->compose_0) == 2U)
        {

#line 108
            c_0 = _S29 + _S31 * float4((1.0f - _S29.w)) ;

#line 108
        }
        else
        {

#line 109
            if(((&_S25)->compose_0) == 3U)
            {

                float _S32 = max((&_S25)->wipeSoft_0, 0.5f / max(dot(abs((&_S25)->wipeDir_0), px_2), 1.0f));
                float m_1 = 1.0f - smoothstep((&_S25)->wipeFront_0 - _S32, (&_S25)->wipeFront_0 + _S32, dot(uv_2 - _S27, (&_S25)->wipeDir_0) + 0.5f);
                c_0 = _S29 * float4((1.0f - m_1))  + _S31 * float4(m_1) ;

#line 109
            }
            else
            {

#line 109
                float shift_0;

#line 115
                if(((&_S25)->compose_0) == 4U)
                {


                    uint h_5 = (min(uint(uv_2.y * 24.0f), 23U) * 2654435761U) ^ ((as_type<uint>(((&_S25)->wipeDir_0.x))) * 2246822507U);
                    uint h_6 = (h_5 ^ (h_5 >> 15U)) * 739982445U;

#line 120
                    uint h_7 = (h_6 ^ (h_6 >> 12U)) * 695872825U;

#line 120
                    uint h_8 = h_7 ^ (h_7 >> 15U);

                    if((float(h_8 & 255U) / 255.0f) < (0.44999998807907104f * (&_S25)->wipeSoft_0))
                    {

#line 122
                        shift_0 = (float((h_8 >> 8U) & 65535U) / 65535.0f * 2.0f - 1.0f) * 0.11999999731779099f * (&_S25)->wipeSoft_0;

#line 122
                    }
                    else
                    {

#line 122
                        shift_0 = 0.0f;

#line 122
                    }
                    float split_0 = 0.02500000037252903f * clamp((&_S25)->wipeSoft_0, 0.0f, 1.0f);
                    bool second_1 = ((&_S25)->wipeFront_0) >= 0.5f;
                    float2 _S33 = uv_2 + float2(shift_0 + split_0, 0.0f);

#line 125
                    thread TransitionU_0 _S34 = _S25;

#line 125
                    float4 _S35 = sideOf_0(second_1, ta_1, tb_1, _S33, &_S34, px_2, kernelContext_4);
                    float2 _S36 = uv_2 + float2(shift_0, 0.0f);

#line 126
                    thread TransitionU_0 _S37 = _S25;

#line 126
                    float4 _S38 = sideOf_0(second_1, ta_1, tb_1, _S36, &_S37, px_2, kernelContext_4);
                    float2 _S39 = uv_2 + float2(shift_0 - split_0, 0.0f);

#line 127
                    thread TransitionU_0 _S40 = _S25;

#line 127
                    float4 _S41 = sideOf_0(second_1, ta_1, tb_1, _S39, &_S40, px_2, kernelContext_4);
                    c_0 = float4(_S35.x, _S38.y, _S41.z, _S38.w);

#line 115
                }
                else
                {

#line 129
                    if(((&_S25)->compose_0) == 5U)
                    {


                        float _S42 = max((&_S25)->wipeSoft_0, 0.5f / max(min(px_2.x, px_2.y), 1.0f));
                        float m_2 = 1.0f - smoothstep((&_S25)->wipeFront_0 - _S42, (&_S25)->wipeFront_0 + _S42, length((uv_2 - _S27) * float2(2.0f) ) / 1.4142135381698608f);
                        c_0 = _S29 * float4((1.0f - m_2))  + _S31 * float4(m_2) ;

#line 129
                    }
                    else
                    {

#line 136
                        if(((&_S25)->compose_0) == 6U)
                        {
                            float p_1 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);
                            float w_2 = smoothstep(0.34999999403953552f, 0.64999997615814209f, p_1);
                            float4 _S43 = _S29 * float4((1.0f - w_2))  + _S31 * float4(w_2) ;

#line 140
                            c_0 = _S43;
                            float2 o_0 = uv_2 - _S27;
                            float _S44 = o_0.x;

#line 142
                            float _S45 = (&_S25)->wipeDir_0.x;

#line 142
                            float _S46 = o_0.y;

#line 142
                            float _S47 = (&_S25)->wipeDir_0.y;
                            float k_1 = (_S44 * _S45 + _S46 * _S47 + 0.5f - (-0.30000001192092896f + 1.6000000238418579f * p_1)) / (0.15000000596046448f + 1.5f * (&_S25)->wipeSoft_0);
                            float f_1 = exp(- k_1 * k_1);
                            float _S48 = max(0.0f, sin(p_1 * 3.1415927410125732f));
                            float t_2 = clamp(- _S44 * _S47 + _S46 * _S45 + 0.5f, 0.0f, 1.0f);
                            float aa_0 = f_1 * _S48 * 1.2000000476837158f;

#line 147
                            float core_0 = f_1 * f_1 * f_1 * _S48;

                            float3 _S49 = _S43.xyz;

#line 149
                            c_0.xyz = _S49 + min(float3(aa_0 + 0.40000000596046448f * core_0, (0.55000001192092896f - 0.34999999403953552f * t_2) * aa_0 + 0.30000001192092896f * core_0, (0.15000000596046448f + 0.30000001192092896f * t_2) * aa_0 + 0.20000000298023224f * core_0), float3(1.0f) ) * float3(_S43.w)  * (float3(1.0f)  - _S49);

#line 136
                        }
                        else
                        {

#line 150
                            if(((&_S25)->compose_0) == 7U)
                            {
                                float rpx_0 = (&_S25)->wipeSoft_0 * px_2.y;
                                if(rpx_0 < 0.5f)
                                {

#line 154
                                    c_0 = _S29 * float4((1.0f - (&_S25)->wipeFront_0))  + _S31 * float4((&_S25)->wipeFront_0) ;

#line 153
                                }
                                else
                                {

                                    int n_1 = clamp(int(rpx_0 * 0.25f), int(6), int(10));
                                    float4 _S50 = float4(0.0f) ;
                                    float _S51 = 6.2831854820251465f * fract(52.982917785644531f * fract(dot(uv_2 * px_2, float2(0.067110560834407806f, 0.0058371499180793762f))));

#line 159
                                    int k_2 = int(0);

#line 159
                                    float4 sa_0 = _S50;

#line 159
                                    float4 sb_0 = _S50;
                                    for(;;)
                                    {

#line 160
                                        if(k_2 < n_1)
                                        {
                                        }
                                        else
                                        {

#line 160
                                            break;
                                        }

#line 161
                                        float _S52 = float(k_2);

#line 161
                                        float th_0 = _S52 * 2.3999631404876709f + _S51;

                                        float2 uk_0 = clamp(uv_2 + float2(cos(th_0), sin(th_0)) * float2(sqrt((_S52 + 0.5f) / float(n_1)))  * float2(rpx_0)  / px_2, _S27 / px_2, float2(1.0f)  - _S27 / px_2);

#line 163
                                        thread TransitionSideU_0 _S53 = (&_S25)->a_0;

#line 163
                                        float4 _S54 = transitionSide_0(ta_1, uk_0, &_S53, px_2, kernelContext_4);
                                        float4 sa_1 = sa_0 + _S54;

#line 164
                                        thread TransitionSideU_0 _S55 = (&_S25)->b_0;

#line 164
                                        float4 _S56 = transitionSide_0(tb_1, uk_0, &_S55, px_2, kernelContext_4);
                                        float4 sb_1 = sb_0 + _S56;

#line 160
                                        k_2 = k_2 + int(1);

#line 160
                                        sa_0 = sa_1;

#line 160
                                        sb_0 = sb_1;

#line 160
                                    }

#line 160
                                    float4 _S57 = float4(float(n_1)) ;

#line 168
                                    c_0 = sa_0 / _S57 * float4((1.0f - (&_S25)->wipeFront_0))  + sb_0 / _S57 * float4((&_S25)->wipeFront_0) ;

#line 153
                                }

#line 150
                            }
                            else
                            {

#line 170
                                if(((&_S25)->compose_0) == 8U)
                                {

                                    uint seed_0 = (as_type<uint>(((&_S25)->wipeDir_0.x)));
                                    float k_3 = clamp((&_S25)->wipeSoft_0, 0.0f, 1.0f);
                                    uint _S58 = gid_0.y;
                                    uint hr_0 = (_S58 / 2U * 2654435761U) ^ (seed_0 * 2246822507U);
                                    uint hr_1 = (hr_0 ^ (hr_0 >> 15U)) * 739982445U;

                                    bool second_2 = ((&_S25)->wipeFront_0) >= 0.5f;
                                    float _S59 = px_2.x;

#line 180
                                    float2 _S60 = float2(clamp(uv_2.x + (float((hr_1 ^ (hr_1 >> 12U)) & 65535U) / 65535.0f * 2.0f - 1.0f) * 0.039999999105930328f * k_3 * k_3, 0.5f / _S59, 1.0f - 0.5f / _S59), uv_2.y);

#line 180
                                    thread TransitionU_0 _S61 = _S25;

#line 180
                                    float4 _S62 = sideOf_0(second_2, ta_1, tb_1, _S60, &_S61, px_2, kernelContext_4);
                                    uint h_9 = ((gid_0.x * 73856093U) ^ (_S58 * 19349663U)) ^ (seed_0 * 83492791U);
                                    uint h_10 = (h_9 ^ (h_9 >> 13U)) * 1540483477U;

#line 182
                                    uint h_11 = (h_10 ^ (h_10 >> 15U)) * 668265261U;

                                    float m_3 = 0.85000002384185791f * k_3;
                                    float _S63 = _S62.w;

#line 185
                                    c_0 = float4(_S62.xyz * float3((1.0f - m_3))  + float3((float((h_11 ^ (h_11 >> 13U)) & 65535U) / 65535.0f))  * float3(m_3)  * float3(_S63) , _S63);

#line 170
                                }
                                else
                                {

#line 186
                                    if(((&_S25)->compose_0) == 9U)
                                    {
                                        float p_2 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);
                                        float w_3 = smoothstep(0.30000001192092896f, 0.69999998807907104f, p_2);
                                        float4 _S64 = _S29 * float4((1.0f - w_3))  + _S31 * float4(w_3) ;

#line 190
                                        c_0 = _S64;

                                        float2 g_0 = uv_2 * float2(px_2.x / px_2.y, 1.0f) * float2(4.0f)  + float2(p_2 * 3.0f, - p_2 * 2.0f);
                                        float2 gi_0 = floor(g_0);

#line 193
                                        float2 gf_0 = fract(g_0);
                                        float2 gf_1 = gf_0 * gf_0 * (float2(3.0f)  - float2(2.0f)  * gf_0);

                                        float _S65 = gf_1.x;


                                        float3 _S66 = _S64.xyz;

#line 199
                                        c_0.xyz = _S66 + float3(1.0f, 0.87999999523162842f, 0.64999997615814209f) * float3((max(0.0f, sin(p_2 * 3.1415927410125732f)) * smoothstep(0.25f, 0.94999998807907104f, mix(mix(lnHash_0(gi_0), lnHash_0(gi_0 + float2(1.0f, 0.0f)), _S65), mix(lnHash_0(gi_0 + float2(0.0f, 1.0f)), lnHash_0(gi_0 + float2(1.0f, 1.0f)), _S65), gf_1.y)) * 0.89999997615814209f))  * float3(_S64.w)  * (float3(1.0f)  - _S66);

#line 186
                                    }
                                    else
                                    {

#line 200
                                        if(((&_S25)->compose_0) == 10U)
                                        {
                                            float2 q_2 = (uv_2 - _S27) * float2(2.0f) ;
                                            int shape_0 = int((&_S25)->wipeDir_0.x + 0.5f);

                                            if(shape_0 == int(0))
                                            {

#line 206
                                                float d_0 = atan2(q_2.x, - q_2.y) * 0.15915493667125702f;
                                                if(d_0 < 0.0f)
                                                {

#line 207
                                                    shift_0 = d_0 + 1.0f;

#line 207
                                                }
                                                else
                                                {

#line 207
                                                    shift_0 = d_0;

#line 207
                                                }

#line 205
                                            }
                                            else
                                            {
                                                if(shape_0 == int(1))
                                                {

#line 208
                                                    shift_0 = max(abs(q_2.x), abs(q_2.y));

#line 208
                                                }
                                                else
                                                {

#line 209
                                                    if(shape_0 == int(2))
                                                    {

#line 209
                                                        shift_0 = (abs(q_2.x) + abs(q_2.y)) * 0.5f;

#line 209
                                                    }
                                                    else
                                                    {

#line 210
                                                        if(shape_0 == int(3))
                                                        {

#line 210
                                                            shift_0 = min(abs(q_2.x), abs(q_2.y));

#line 210
                                                        }
                                                        else
                                                        {

#line 211
                                                            if(shape_0 == int(4))
                                                            {

#line 211
                                                                shift_0 = abs(q_2.x);

#line 211
                                                            }
                                                            else
                                                            {

#line 212
                                                                if(shape_0 == int(5))
                                                                {

#line 212
                                                                    shift_0 = abs(q_2.y);

#line 212
                                                                }
                                                                else
                                                                {

#line 213
                                                                    if(shape_0 == int(6))
                                                                    {

#line 213
                                                                        float t_3 = uv_2.y * 8.0f;

#line 213
                                                                        shift_0 = t_3 - floor(t_3);

#line 213
                                                                    }
                                                                    else
                                                                    {

#line 214
                                                                        if(shape_0 == int(7))
                                                                        {

#line 214
                                                                            shift_0 = atan2(uv_2.x, uv_2.y) * 0.63661974668502808f;

#line 214
                                                                        }
                                                                        else
                                                                        {

#line 215
                                                                            if(shape_0 == int(8))
                                                                            {

#line 215
                                                                                shift_0 = atan2(abs(q_2.x), - q_2.y) * 0.31830990314483643f;

#line 215
                                                                            }
                                                                            else
                                                                            {

#line 216
                                                                                if(shape_0 == int(9))
                                                                                {

#line 217
                                                                                    float cc_0 = atan2(q_2.x, - q_2.y) * 0.15915493667125702f;
                                                                                    if(cc_0 < 0.0f)
                                                                                    {

#line 218
                                                                                        shift_0 = cc_0 + 1.0f;

#line 218
                                                                                    }
                                                                                    else
                                                                                    {

#line 218
                                                                                        shift_0 = cc_0;

#line 218
                                                                                    }
                                                                                    float cc_1 = shift_0 * 4.0f;

#line 219
                                                                                    shift_0 = cc_1 - floor(cc_1);

#line 216
                                                                                }
                                                                                else
                                                                                {


                                                                                    if(shape_0 == int(10))
                                                                                    {

#line 222
                                                                                        float cu_0 = uv_2.x * 8.0f;
                                                                                        float _S67 = floor(cu_0);

#line 223
                                                                                        float f_2 = cu_0 - _S67;

                                                                                        if(((int(_S67) + int(floor(uv_2.y * 6.0f))) % int(2)) == int(0))
                                                                                        {

#line 225
                                                                                            shift_0 = f_2;

#line 225
                                                                                        }
                                                                                        else
                                                                                        {

#line 225
                                                                                            shift_0 = 1.0f - f_2;

#line 225
                                                                                        }

#line 221
                                                                                    }
                                                                                    else
                                                                                    {


                                                                                        if(shape_0 == int(11))
                                                                                        {

#line 227
                                                                                            float _S68 = min(floor(uv_2.y * 8.0f), 7.0f);

                                                                                            float along_0 = (min(floor(uv_2.x * 8.0f), 7.0f) + 0.5f) / 8.0f;
                                                                                            if((int(_S68) % int(2)) == int(0))
                                                                                            {

#line 230
                                                                                                shift_0 = along_0;

#line 230
                                                                                            }
                                                                                            else
                                                                                            {

#line 230
                                                                                                shift_0 = 1.0f - along_0;

#line 230
                                                                                            }

#line 230
                                                                                            shift_0 = (_S68 + shift_0) / 8.0f;

#line 226
                                                                                        }
                                                                                        else
                                                                                        {


                                                                                            if(shape_0 == int(12))
                                                                                            {

#line 231
                                                                                                shift_0 = max(uv_2.x, uv_2.y);

#line 231
                                                                                            }
                                                                                            else
                                                                                            {

#line 232
                                                                                                if(shape_0 == int(14))
                                                                                                {

#line 232
                                                                                                    if((int(floor(uv_2.y * 10.0f)) % int(2)) == int(0))
                                                                                                    {

#line 232
                                                                                                        shift_0 = uv_2.x;

#line 232
                                                                                                    }
                                                                                                    else
                                                                                                    {

#line 232
                                                                                                        shift_0 = 1.0f - uv_2.x;

#line 232
                                                                                                    }

#line 232
                                                                                                }
                                                                                                else
                                                                                                {

#line 233
                                                                                                    if(shape_0 == int(13))
                                                                                                    {

                                                                                                        uint h_12 = (uint(min(floor(uv_2.x * 12.0f), 11.0f)) * 73856093U) ^ (uint(min(floor(uv_2.y * 8.0f), 7.0f)) * 19349663U);
                                                                                                        uint h_13 = (h_12 ^ (h_12 >> 13U)) * 1274126177U;

#line 237
                                                                                                        shift_0 = float((h_13 ^ (h_13 >> 16U)) & 65535U) / 6.5536e+04f;

#line 233
                                                                                                    }
                                                                                                    else
                                                                                                    {

#line 233
                                                                                                        shift_0 = 0.0f;

#line 233
                                                                                                    }

#line 232
                                                                                                }

#line 231
                                                                                            }

#line 226
                                                                                        }

#line 221
                                                                                    }

#line 216
                                                                                }

#line 215
                                                                            }

#line 214
                                                                        }

#line 213
                                                                    }

#line 212
                                                                }

#line 211
                                                            }

#line 210
                                                        }

#line 209
                                                    }

#line 208
                                                }

#line 205
                                            }

#line 241
                                            float _S69 = max((&_S25)->wipeSoft_0, 0.5f / max(min(px_2.x, px_2.y), 1.0f));
                                            float m_4 = 1.0f - smoothstep((&_S25)->wipeFront_0 - _S69, (&_S25)->wipeFront_0 + _S69, shift_0);
                                            c_0 = _S29 * float4((1.0f - m_4))  + _S31 * float4(m_4) ;

#line 200
                                        }
                                        else
                                        {

#line 244
                                            if(((&_S25)->compose_0) == 11U)
                                            {
                                                float p_3 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);

#line 246
                                                float2 _S70 = float2(max(1.0f, sin(p_3 * 3.1415927410125732f) * px_2.y / 6.0f)) ;



                                                float2 quv_0 = clamp((floor(_S26 / _S70) + _S27) * _S70 / px_2, float2(0.0f) , float2(1.0f) );

#line 250
                                                thread TransitionSideU_0 _S71 = (&_S25)->a_0;

#line 250
                                                float4 _S72 = transitionSide_0(ta_1, quv_0, &_S71, px_2, kernelContext_4);

#line 250
                                                thread TransitionSideU_0 _S73 = (&_S25)->b_0;

#line 250
                                                float4 _S74 = transitionSide_0(tb_1, quv_0, &_S73, px_2, kernelContext_4);

                                                c_0 = _S72 * float4((1.0f - p_3))  + _S74 * float4(p_3) ;

#line 244
                                            }
                                            else
                                            {

#line 253
                                                if(((&_S25)->compose_0) == 12U)
                                                {
                                                    float p_4 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);
                                                    bool vert_0 = (abs((&_S25)->wipeDir_0.y)) > (abs((&_S25)->wipeDir_0.x));
                                                    if(((&_S25)->wipeDir_0.x + (&_S25)->wipeDir_0.y) > 0.0f)
                                                    {

#line 257
                                                        shift_0 = 1.0f;

#line 257
                                                    }
                                                    else
                                                    {

#line 257
                                                        shift_0 = -1.0f;

#line 257
                                                    }
                                                    bool second_3 = p_4 >= 0.5f;
                                                    float _S75 = p_4 * 3.1415927410125732f;

#line 259
                                                    float _S76;

#line 259
                                                    if(second_3)
                                                    {

#line 259
                                                        _S76 = 3.1415927410125732f;

#line 259
                                                    }
                                                    else
                                                    {

#line 259
                                                        _S76 = 0.0f;

#line 259
                                                    }

#line 259
                                                    float ang_0 = shift_0 * (_S75 - _S76);
                                                    float2 X_0 = (uv_2 - _S27) * float2(2.0f) ;

#line 260
                                                    float2 X_1;
                                                    if(vert_0)
                                                    {

#line 261
                                                        X_1 = X_0.yx;

#line 261
                                                    }
                                                    else
                                                    {

#line 261
                                                        X_1 = X_0;

#line 261
                                                    }
                                                    float sa_2 = sin(ang_0);
                                                    float _S77 = X_1.x;

#line 263
                                                    float den_0 = 3.0f * cos(ang_0) + _S77 * sa_2;
                                                    c_0 = float4(0.0f) ;
                                                    if(den_0 > 0.05000000074505806f)
                                                    {

#line 266
                                                        float x_0 = _S77 * 3.0f / den_0;
                                                        float y_0 = X_1.y * (3.0f - x_0 * sa_2) / 3.0f;

#line 267
                                                        bool _S78;
                                                        if((abs(x_0)) <= 1.0f)
                                                        {

#line 268
                                                            _S78 = (abs(y_0)) <= 1.0f;

#line 268
                                                        }
                                                        else
                                                        {

#line 268
                                                            _S78 = false;

#line 268
                                                        }

#line 268
                                                        if(_S78)
                                                        {

#line 268
                                                            float2 sq_0;
                                                            if(vert_0)
                                                            {

#line 269
                                                                sq_0 = float2(y_0, x_0);

#line 269
                                                            }
                                                            else
                                                            {

#line 269
                                                                sq_0 = float2(x_0, y_0);

#line 269
                                                            }
                                                            float2 _S79 = sq_0 * _S27 + _S27;

#line 270
                                                            thread TransitionU_0 _S80 = _S25;

#line 270
                                                            float4 _S81 = sideOf_0(second_3, ta_1, tb_1, _S79, &_S80, px_2, kernelContext_4);

#line 270
                                                            c_0 = _S81;

#line 268
                                                        }

#line 265
                                                    }

#line 253
                                                }
                                                else
                                                {

#line 273
                                                    if(((&_S25)->compose_0) == 13U)
                                                    {

                                                        float _S82 = px_2.x;

#line 276
                                                        float _S83 = px_2.y;

#line 276
                                                        float2 g_1 = uv_2 * float2(_S82 / _S83, 1.0f) * float2(4.0f) ;
                                                        float2 gi_1 = floor(g_1);

#line 277
                                                        float2 gf_2 = fract(g_1);
                                                        float2 gf_3 = gf_2 * gf_2 * (float2(3.0f)  - float2(2.0f)  * gf_2);
                                                        float _S84 = gf_3.x;
                                                        float d_1 = 0.69999998807907104f * mix(mix(lnHash_0(gi_1), lnHash_0(gi_1 + float2(1.0f, 0.0f)), _S84), mix(lnHash_0(gi_1 + float2(0.0f, 1.0f)), lnHash_0(gi_1 + float2(1.0f, 1.0f)), _S84), gf_3.y) + 0.30000001192092896f * (dot(uv_2 - _S27, (&_S25)->wipeDir_0) + 0.5f);

                                                        float t_4 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f) * 1.1200000047683716f;
                                                        float aa_1 = 0.5f / max(min(_S82, _S83), 1.0f);
                                                        float m_5 = 1.0f - smoothstep(t_4 - aa_1, t_4 + aa_1, d_1);
                                                        float4 _S85 = _S29 * float4((1.0f - m_5))  + _S31 * float4(m_5) ;

#line 285
                                                        c_0 = _S85;
                                                        float _S86 = d_1 - t_4;
                                                        float _S87 = 1.0f - clamp(_S86 / 0.11999999731779099f, 0.0f, 1.0f);

#line 287
                                                        float fire_0 = _S87 * _S87 * step(0.0f, _S86 + aa_1);

                                                        float _S88 = _S29.w;

#line 289
                                                        c_0.xyz = _S85.xyz * float3((1.0f - 0.69999998807907104f * fire_0))  + mix(float3(1.0f, 0.34999999403953552f, 0.05000000074505806f), float3(1.0f, 0.89999997615814209f, 0.60000002384185791f), float3((fire_0 * fire_0)) ) * float3(fire_0)  * float3(1.6000000238418579f)  * float3(_S88) ;
                                                        c_0.w = max(c_0.w, fire_0 * _S88);

#line 273
                                                    }
                                                    else
                                                    {

#line 291
                                                        if(((&_S25)->compose_0) == 14U)
                                                        {
                                                            float p_5 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);
                                                            float w_4 = smoothstep(0.34999999403953552f, 0.64999997615814209f, p_5);
                                                            float4 _S89 = _S29 * float4((1.0f - w_4))  + _S31 * float4(w_4) ;

#line 295
                                                            c_0 = _S89;


                                                            float2 dd_0 = (uv_2 - (float2(0.5f)  + (&_S25)->wipeDir_0 * float2((p_5 - 0.5f))  * float2(0.60000002384185791f) )) * float2(px_2.x / px_2.y, 1.0f);

                                                            c_0.xyz = _S89.xyz + float3(1.0f, 0.81999999284744263f, 0.55000001192092896f) * float3((sin(p_5 * 3.1415927410125732f) * (exp(- dot(dd_0, dd_0) * 6.0f) * 1.2000000476837158f + 0.25f)))  * float3(_S89.w) ;

#line 291
                                                        }
                                                        else
                                                        {

#line 301
                                                            if(((&_S25)->compose_0) == 15U)
                                                            {
                                                                float p_6 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);


                                                                float2 uw_0 = clamp(uv_2 + float2(sin(uv_2.y * 14.0f + p_6 * 10.0f), cos(uv_2.x * 11.0f - p_6 * 8.0f)) * float2(0.05000000074505806f)  * float2(sin(p_6 * 3.1415927410125732f)) , _S27 / px_2, float2(1.0f)  - _S27 / px_2);
                                                                float w_5 = smoothstep(0.30000001192092896f, 0.69999998807907104f, p_6);

#line 307
                                                                thread TransitionSideU_0 _S90 = (&_S25)->a_0;

#line 307
                                                                float4 _S91 = transitionSide_0(ta_1, uw_0, &_S90, px_2, kernelContext_4);
                                                                float4 _S92 = _S91 * float4((1.0f - w_5)) ;

#line 308
                                                                thread TransitionSideU_0 _S93 = (&_S25)->b_0;

#line 308
                                                                float4 _S94 = transitionSide_0(tb_1, uw_0, &_S93, px_2, kernelContext_4);

#line 308
                                                                c_0 = _S92 + _S94 * float4(w_5) ;

#line 301
                                                            }
                                                            else
                                                            {

#line 309
                                                                if(((&_S25)->compose_0) == 16U)
                                                                {
                                                                    float p_7 = clamp((&_S25)->wipeFront_0, 0.0f, 1.0f);
                                                                    float bell_0 = sin(p_7 * 3.1415927410125732f);
                                                                    uint h_14 = (uint(p_7 * 30.0f) + 1U) * 2654435761U;
                                                                    uint h_15 = (h_14 ^ (h_14 >> 15U)) * 739982445U;

#line 314
                                                                    uint h_16 = h_15 ^ (h_15 >> 12U);

                                                                    uint h_17 = h_16 * 695872825U;



                                                                    bool second_4 = p_7 >= 0.5f;
                                                                    float2 lo_0 = _S27 / px_2;

#line 321
                                                                    float2 hi_0 = float2(1.0f)  - _S27 / px_2;
                                                                    float2 _S95 = uv_2 + float2(float(h_16 & 65535U) / 32767.5f - 1.0f, float((h_17 ^ (h_17 >> 15U)) & 65535U) / 32767.5f - 1.0f) * float2(0.039999999105930328f)  * float2(bell_0) ;

#line 322
                                                                    float2 _S96 = float2(0.012000000104308128f * bell_0, 0.0f);

#line 322
                                                                    float2 _S97 = clamp(_S95 + _S96, lo_0, hi_0);

#line 322
                                                                    thread TransitionU_0 _S98 = _S25;

#line 322
                                                                    float4 _S99 = sideOf_0(second_4, ta_1, tb_1, _S97, &_S98, px_2, kernelContext_4);
                                                                    float2 _S100 = clamp(_S95, lo_0, hi_0);

#line 323
                                                                    thread TransitionU_0 _S101 = _S25;

#line 323
                                                                    float4 _S102 = sideOf_0(second_4, ta_1, tb_1, _S100, &_S101, px_2, kernelContext_4);
                                                                    float2 _S103 = clamp(_S95 - _S96, lo_0, hi_0);

#line 324
                                                                    thread TransitionU_0 _S104 = _S25;

#line 324
                                                                    float4 _S105 = sideOf_0(second_4, ta_1, tb_1, _S103, &_S104, px_2, kernelContext_4);
                                                                    c_0 = float4(_S99.x, _S102.y, _S105.z, _S102.w);

#line 309
                                                                }
                                                                else
                                                                {

#line 326
                                                                    c_0 = _S29 + _S31;

#line 309
                                                                }

#line 301
                                                            }

#line 291
                                                        }

#line 273
                                                    }

#line 253
                                                }

#line 244
                                            }

#line 200
                                        }

#line 186
                                    }

#line 170
                                }

#line 150
                            }

#line 136
                        }

#line 129
                    }

#line 115
                }

#line 109
            }

#line 108
        }

#line 107
    }

#line 327
    if(((&_S25)->borderWidth_0) > 0.0f)
    {

        float _S106 = max(0.5f / max(dot(abs((&_S25)->wipeDir_0), px_2), 1.0f), 9.99999997475242708e-07f);
        float h_18 = 0.5f * (&_S25)->borderWidth_0;

        float cov_0 = (1.0f - smoothstep(h_18 - _S106, h_18 + _S106, abs(dot(uv_2 - _S27, (&_S25)->wipeDir_0) + 0.5f - (&_S25)->wipeFront_0))) * smoothstep(0.0f, h_18, (&_S25)->wipeFront_0) * smoothstep(0.0f, h_18, 1.0f - (&_S25)->wipeFront_0);
        c_0 = c_0 * float4((1.0f - cov_0))  + float4((&_S25)->borderR_0, (&_S25)->borderG_0, (&_S25)->borderB_0, 1.0f) * float4(cov_0) ;

#line 327
    }

#line 336
    return c_0;
}


#line 9 "crates/sq-gpu/shaders-src/TransitionMix.slang"
[[kernel]] void transitionMix(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::write> out0_1 [[texture(25)]], uint32_t device* cover_2 [[buffer(2)]], TransitionRows_0 constant* tr_1 [[buffer(0)]], sampler zeroSampler_1 [[sampler(0)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]])
{

#line 9
    thread KernelContext_0 kernelContext_5;

#line 9
    (&kernelContext_5)->out0_0 = out0_1;

#line 9
    (&kernelContext_5)->cover_0 = cover_2;

#line 9
    (&kernelContext_5)->tr_0 = tr_1;

#line 9
    (&kernelContext_5)->zeroSampler_0 = zeroSampler_1;

#line 9
    (&kernelContext_5)->in0_0 = in0_1;

#line 9
    (&kernelContext_5)->in1_0 = in1_1;

#line 9
    uint2 _S107 = outSize_0(&kernelContext_5);

    uint2 gid_1 = tid_0.xy;

#line 11
    bool _S108;
    if((gid_1.x) >= (_S107.x))
    {

#line 12
        _S108 = true;

#line 12
    }
    else
    {

#line 12
        _S108 = (gid_1.y) >= (_S107.y);

#line 12
    }

#line 12
    if(_S108)
    {

#line 12
        return;
    }

#line 13
    uint _S109 = as_type<uint>((&kernelContext_5)->cover_0[(0U)>>2]);

#line 13
    float _S110 = (as_type<float>((_S109)));

#line 13
    uint _S111 = as_type<uint>((&kernelContext_5)->cover_0[(4U)>>2]);

#line 13
    float2 cv_0 = float2(_S110, (as_type<float>((_S111))));

#line 13
    TransitionU_0 _S112 = transitionFromRows_0((&kernelContext_5)->tr_0);
    float2 _S113 = float2(_S107);

#line 14
    thread TransitionU_0 _S114 = _S112;

#line 14
    float4 _S115 = transitionCompose_0((&kernelContext_5)->in0_0, (&kernelContext_5)->in1_0, &_S114, gid_1, _S113, cv_0, &kernelContext_5);

#line 14
    (&kernelContext_5)->out0_0.write(_S115,gid_1);
    return;
}

