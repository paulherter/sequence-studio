#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

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


#line 37 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    LookU_0 constant* lu_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
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


#line 13 "crates/sq-gpu/shaders-src/Parts/Look.slang"
uint pcg_0(uint v_0)
{

#line 14
    uint s_0 = v_0 * 747796405U + 2891336653U;
    uint w_1 = ((s_0 >> ((s_0 >> 28U) + 4U)) ^ s_0) * 277803737U;
    return (w_1 >> 22U) ^ w_1;
}


#line 18
float hash2_0(int2 p_0, uint seed_0)
{

#line 19
    return float(pcg_0(uint(p_0.x) + pcg_0(uint(p_0.y) + pcg_0(seed_0)))) * 2.32830643653869629e-10f;
}

float grainNoise_0(float2 p_1, float soft_0, uint seed_1)
{

#line 23
    float2 fl_0 = floor(p_1);
    int2 _S2 = int2(fl_0);
    float2 f_0 = p_1 - fl_0;

    float2 u_0 = mix(step(float2(0.5f) , f_0), f_0 * f_0 * (float2(3.0f)  - float2(2.0f)  * f_0), float2(soft_0) );
    float _S3 = u_0.x;

#line 28
    return mix(mix(hash2_0(_S2, seed_1), hash2_0(_S2 + int2(int(1), int(0)), seed_1), _S3), mix(hash2_0(_S2 + int2(int(0), int(1)), seed_1), hash2_0(_S2 + int2(int(1), int(1)), seed_1), _S3), u_0.y);
}



float4 lookPointwise_0(float4 c_0, float streak_0, uint2 gid_0, const LookU_0 constant* L_0)
{

#line 33
    thread float4 _S4 = c_0;

#line 33
    float4 _S5 = L_0->dims_0;
    float sc_0 = L_0->dims_0.z;

#line 34
    uint4 _S6 = L_0->ids_0;
    uint flags_0 = L_0->ids_0.x;
    float3 lw_0 = float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f);
    _S4.xyz = c_0.xyz + float3((streak_0 * 0.60000002384185791f * c_0.w)) ;

#line 37
    bool _S7;



    if((flags_0 & 1U) != 0U)
    {

#line 41
        _S7 = (_S4.w) > 0.0f;

#line 41
    }
    else
    {

#line 41
        _S7 = false;

#line 41
    }

#line 41
    if(_S7)
    {

#line 42
        float3 col_0 = _S4.xyz / float3(_S4.w) ;

        float _S8 = 2.0f * clamp(sqrt(max(dot(col_0, lw_0), 0.0f)), 0.0f, 1.0f) - 1.0f;

#line 44
        float4 _S9 = L_0->grain_0;
        float w_2 = mix(1.0f, 1.0f - _S8 * _S8, L_0->grain_0.w);

        float2 gp_0 = (float2(gid_0) + float2(0.5f) ) / float2(max(L_0->grain_0.y * sc_0, 0.5f)) ;
        float _S10 = L_0->grain_0.z;

#line 48
        float gain_0 = 1.0f + _S10 * 0.89999997615814209f;
        uint _S11 = _S6.y;
        float3 nv_0 = float3(((grainNoise_0(gp_0, _S10, _S11) * 2.0f - 1.0f) * gain_0)) ;
        float _S12 = _S5.w;

#line 51
        float3 nv_1;

#line 51
        if(_S12 > 0.0f)
        {

#line 51
            nv_1 = mix(nv_0, float3((grainNoise_0(gp_0, _S10, _S11 + 101U) * 2.0f - 1.0f) * gain_0, (grainNoise_0(gp_0, _S10, _S11 + 202U) * 2.0f - 1.0f) * gain_0, (grainNoise_0(gp_0, _S10, _S11 + 303U) * 2.0f - 1.0f) * gain_0), float3(_S12) );

#line 51
        }
        else
        {

#line 51
            nv_1 = nv_0;

#line 51
        }

#line 58
        float3 _S13 = float3(0.0f) ;
        float3 _S14 = max(sqrt(max(col_0, _S13)) + nv_1 * float3(_S9.x)  * float3(0.25f)  * float3(w_2) , _S13);
        _S4.xyz = _S14 * _S14 * float3(_S4.w) ;

#line 41
    }

#line 65
    if((flags_0 & 64U) != 0U)
    {

#line 65
        _S7 = (_S4.w) > 0.0f;

#line 65
    }
    else
    {

#line 65
        _S7 = false;

#line 65
    }

#line 65
    if(_S7)
    {
        uint fs_0 = _S6.w;

#line 67
        float4 _S15 = L_0->aged_0;
        _S4.xyz = _S4.xyz * float3((1.0f + (float(pcg_0(fs_0 * 3U + 7U)) * 2.32830643653869629e-10f * 2.0f - 1.0f) * L_0->aged_0.z * 0.34999999403953552f)) ;
        float _S16 = L_0->aged_0.x;

#line 69
        if(_S16 > 0.0f)
        {
            float2 p_2 = float2(gid_0) + float2(0.5f) ;

#line 71
            float2 _S17 = float2((64.0f * sc_0)) ;
            int2 _S18 = int2(floor(p_2 / _S17));
            if((hash2_0(_S18, fs_0 ^ 40503U)) < (_S16 * 0.079999998211860657f))
            {
                float r_0 = (1.0f + 2.5f * hash2_0(_S18, fs_0 + 3U)) * sc_0;
                float a_0 = 1.0f - smoothstep(r_0 * 0.5f, r_0, length(p_2 - (float2(_S18) + float2(0.10000000149011612f)  + float2(0.80000001192092896f)  * float2(hash2_0(_S18, fs_0 + 1U), hash2_0(_S18, fs_0 + 2U))) * _S17));
                if((hash2_0(_S18, fs_0 + 4U)) > 0.5f)
                {

#line 77
                    _S4.xyz = mix(_S4.xyz, float3(0.89999997615814209f)  * float3(_S4.w) , float3(a_0) );

#line 77
                }
                else
                {

#line 78
                    _S4.xyz = _S4.xyz * float3((1.0f - 0.89999997615814209f * a_0)) ;

#line 77
                }

#line 73
            }

#line 69
        }

#line 81
        float _S19 = _S15.y;

#line 81
        if(_S19 > 0.0f)
        {

#line 82
            float _S20 = (float(gid_0.y) + 0.5f) / _S5.y;

#line 82
            uint k_0 = 0U;
            for(;;)
            {

#line 83
                if(k_0 < 3U)
                {
                }
                else
                {

#line 83
                    break;
                }

#line 84
                uint s_1 = pcg_0(fs_0 / 3U * 5U + k_0 * 977U + 13U);
                if((float(pcg_0(s_1 + 1U)) * 2.32830643653869629e-10f) >= _S19)
                {

#line 85
                    k_0 = k_0 + 1U;

#line 83
                    continue;
                }



                float y0_0 = float(pcg_0(s_1 + 4U)) * 2.32830643653869629e-10f;

                _S4.xyz = mix(_S4.xyz, float3(0.85000002384185791f)  * float3(_S4.w) , float3(((1.0f - smoothstep(0.0f, (0.80000001192092896f + float(pcg_0(s_1 + 3U)) * 2.32830643653869629e-10f) * sc_0, abs(float(gid_0.x) + 0.5f - float(pcg_0(s_1 + 2U)) * 2.32830643653869629e-10f * _S5.x))) * step(y0_0, _S20) * step(_S20, y0_0 + (0.40000000596046448f + 0.60000002384185791f * float(pcg_0(s_1 + 5U)) * 2.32830643653869629e-10f)) * 0.69999998807907104f)) );

#line 83
                k_0 = k_0 + 1U;

#line 83
            }

#line 81
        }

#line 65
    }

#line 96
    if((flags_0 & 8U) != 0U)
    {
        float f_1 = fract(float(gid_0.y) / max(L_0->scan_0.y * sc_0, 2.0f));

        float gapHalf_0 = L_0->scan_0.z * 0.5f;

        _S4.xyz = _S4.xyz * float3(mix(1.0f, smoothstep(gapHalf_0 - 0.11999999731779099f, gapHalf_0 + 0.11999999731779099f, min(f_1, 1.0f - f_1)), L_0->scan_0.x)) ;

#line 96
    }

#line 104
    return _S4;
}


#line 8 "crates/sq-gpu/shaders-src/FilmLook.slang"
[[kernel]] void filmLook(uint3 tid_0 [[thread_position_in_grid]], LookU_0 constant* lu_1 [[buffer(0)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], sampler edgeSampler_1 [[sampler(1)]])
{

#line 8
    thread KernelContext_0 kernelContext_1;

#line 8
    (&kernelContext_1)->lu_0 = lu_1;

#line 8
    (&kernelContext_1)->out0_0 = out0_1;

#line 8
    (&kernelContext_1)->in0_0 = in0_1;

#line 8
    (&kernelContext_1)->edgeSampler_0 = edgeSampler_1;
    LookU_0 L_1 = *lu_1;

#line 9
    uint2 _S21 = outSize_0(&kernelContext_1);

    uint2 gid_1 = tid_0.xy;

#line 11
    bool _S22;
    if((gid_1.x) >= (_S21.x))
    {

#line 12
        _S22 = true;

#line 12
    }
    else
    {

#line 12
        _S22 = (gid_1.y) >= (_S21.y);

#line 12
    }

#line 12
    if(_S22)
    {

#line 12
        return;
    }

#line 13
    float2 _S23 = float2(_S21);
    float2 uv_0 = (float2(gid_1) + float2(0.5f) ) / _S23;
    float sc_1 = L_1.dims_0.z;
    uint flags_1 = L_1.ids_0.x;
    float3 lw_1 = float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f);

#line 17
    float dx_0;

#line 17
    float streak_1;

#line 22
    if((flags_1 & 32U) != 0U)
    {

#line 23
        float yn_0 = 1.0f - uv_0.y;
        float amount_0 = L_1.track_0.x;

#line 24
        float phase_0 = L_1.track_0.z;


        float _S24 = max(max(1.0f - smoothstep(0.0f, L_1.track_0.y * 0.5f, abs(yn_0 - phase_0)), 0.80000001192092896f * (1.0f - smoothstep(0.0f, 0.05000000074505806f, yn_0))), 0.10000000149011612f);
        uint _S25 = L_1.ids_0.z;

#line 28
        float lh_0 = float(pcg_0(gid_1.y + pcg_0(_S25))) * 2.32830643653869629e-10f;


        float _S26 = _S24 * amount_0 * step(0.80000001192092896f, lh_0) * (0.40000000596046448f + 0.60000002384185791f * hash2_0(int2(gid_1), _S25 + 17U)) * smoothstep(0.30000001192092896f, 1.0f, _S24);

#line 31
        dx_0 = ((lh_0 - 0.5f) * 56.0f + sin(yn_0 * 60.0f + phase_0 * 40.0f) * 10.0f) * _S24 * amount_0 * sc_1;

#line 31
        streak_1 = _S26;

#line 22
    }
    else
    {

#line 22
        dx_0 = 0.0f;

#line 22
        streak_1 = 0.0f;

#line 22
    }

#line 33
    float _S27 = _S23.x;

#line 33
    float2 suv_0 = uv_0 + float2(dx_0 / _S27, 0.0f);
    thread float4 c_1 = (((&kernelContext_1)->in0_0).sample(((&kernelContext_1)->edgeSampler_0), (suv_0), level((0.0f))));


    if((flags_1 & 16U) != 0U)
    {

#line 38
        float _S28 = L_1.chroma_0.x * sc_1;

#line 38
        float _S29 = L_1.chroma_0.y * sc_1;
        float y_0 = dot(c_1.xyz, lw_1);
        float3 _S30 = float3(0.0f) ;

#line 40
        int k_1 = int(-4);

#line 40
        float3 acc_0 = _S30;
        for(;;)
        {

#line 41
            if(k_1 <= int(4))
            {
            }
            else
            {

#line 41
                break;
            }
            float3 t_0 = (((&kernelContext_1)->in0_0).sample(((&kernelContext_1)->edgeSampler_0), (suv_0 - float2((_S29 + float(k_1) * _S28 * 0.25f) / _S27, 0.0f)), level((0.0f)))).xyz;
            float3 acc_1 = acc_0 + (t_0 - float3(dot(t_0, lw_1)) );

#line 41
            k_1 = k_1 + int(1);

#line 41
            acc_0 = acc_1;

#line 41
        }

#line 46
        c_1.xyz = float3(y_0)  + acc_0 * float3(0.1111111119389534f) ;

#line 37
    }

#line 37
    float4 _S31 = lookPointwise_0(c_1, streak_1, gid_1, (&kernelContext_1)->lu_0);

#line 49
    (&kernelContext_1)->out0_0.write(_S31,gid_1);
    return;
}

