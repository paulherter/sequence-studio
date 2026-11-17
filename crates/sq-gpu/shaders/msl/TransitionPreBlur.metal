#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

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


#line 18
struct TransitionSideRows_0
{
    float4 r0_0;
    float4 r1_0;
    float2 r2_0;
};


#line 21
TransitionSideU_0 sideFromRows_0(const TransitionSideRows_0 constant* r_0)
{

#line 22
    thread TransitionSideU_0 s_0;
    (&s_0)->offset_0 = r_0->r0_0.xy;

#line 23
    (&s_0)->blur_0 = r_0->r0_0.zw;
    (&s_0)->scale_0 = r_0->r1_0.x;

#line 24
    (&s_0)->opacity_0 = r_0->r1_0.y;

#line 24
    (&s_0)->zoomBlur_0 = r_0->r1_0.z;

#line 24
    (&s_0)->taps_0 = r_0->r1_0.w;
    (&s_0)->rotation_0 = r_0->r2_0.x;

#line 25
    (&s_0)->mirror_0 = r_0->r2_0.y;
    return s_0;
}


#line 5 "crates/sq-gpu/shaders-src/TransitionPreBlur.slang"
struct PreBlurU_0
{
    float2 canvas_0;
    float pad_0;
    uint slot_0;
};


#line 6 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    TransitionSideRows_0 constant* sr_0;
    PreBlurU_0 constant* pu_0;
    uint32_t device* cover_0;
    texture2d<float, access::write> out0_0;
    sampler zeroSampler_0;
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


#line 42 "crates/sq-gpu/shaders-src/Parts/Transition.slang"
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

float4 transitionSide_0(texture2d<float, access::sample> t_1, float2 uv_0, const TransitionSideU_0 thread* s_1, float2 px_0, KernelContext_0 thread* kernelContext_2)
{

#line 54
    float _S6 = s_1->opacity_0;
    if((s_1->opacity_0) <= 0.0f)
    {

#line 55
        return float4(0.0f) ;
    }

#line 56
    bool m_0 = (s_1->mirror_0) > 0.5f;
    float _S7 = max(s_1->scale_0, 9.9999997473787516e-05f);

#line 57
    float2 _S8 = float2(0.5f) ;
    float2 q0_0 = uv_0 - _S8 - s_1->offset_0;

#line 58
    float _S9 = s_1->rotation_0;

#line 58
    float2 q0_1;
    if((s_1->rotation_0) != 0.0f)
    {
        float cr_0 = cos(_S9);

#line 61
        float sr_1 = sin(_S9);
        float2 pp_0 = q0_0 * px_0;
        float _S10 = pp_0.x;

#line 63
        float _S11 = pp_0.y;

#line 63
        q0_1 = float2(cr_0 * _S10 + sr_1 * _S11, - sr_1 * _S10 + cr_0 * _S11) / px_0;

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
    float2 bl_0 = s_1->blur_0 / _S12;

#line 66
    float _S13 = s_1->zoomBlur_0;

    float _S14 = abs(s_1->zoomBlur_0);

#line 68
    float _S15 = max(length(bl_0 * px_0), length((q_1 - _S8) * px_0) * _S14);

#line 68
    float _S16 = s_1->taps_0;

#line 68
    bool heavy_0;


    if((s_1->taps_0) <= 0.0f)
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


#line 13 "crates/sq-gpu/shaders-src/TransitionPreBlur.slang"
[[kernel]] void transitionPreBlur(uint3 tid_0 [[thread_position_in_grid]], TransitionSideRows_0 constant* sr_2 [[buffer(0)]], PreBlurU_0 constant* pu_1 [[buffer(1)]], uint32_t device* cover_1 [[buffer(2)]], texture2d<float, access::write> out0_1 [[texture(25)]], sampler zeroSampler_1 [[sampler(0)]], texture2d<float, access::sample> in0_1 [[texture(0)]])
{

#line 13
    thread KernelContext_0 kernelContext_3;

#line 13
    (&kernelContext_3)->sr_0 = sr_2;

#line 13
    (&kernelContext_3)->pu_0 = pu_1;

#line 13
    (&kernelContext_3)->cover_0 = cover_1;

#line 13
    (&kernelContext_3)->out0_0 = out0_1;

#line 13
    (&kernelContext_3)->zeroSampler_0 = zeroSampler_1;

#line 13
    (&kernelContext_3)->in0_0 = in0_1;

#line 13
    TransitionSideU_0 _S22 = sideFromRows_0(sr_2);
    thread TransitionSideU_0 s_2 = _S22;
    uint _S23 = as_type<uint>(cover_1[(uint(int(pu_1->slot_0 * 4U)))>>2]);

#line 15
    if((as_type<float>((_S23))) < 0.99900001287460327f)
    {

#line 15
        (&s_2)->mirror_0 = 0.0f;

#line 15
    }

#line 15
    uint2 _S24 = outSize_0(&kernelContext_3);

    uint2 gid_0 = tid_0.xy;

#line 17
    bool _S25;
    if((gid_0.x) >= (_S24.x))
    {

#line 18
        _S25 = true;

#line 18
    }
    else
    {

#line 18
        _S25 = (gid_0.y) >= (_S24.y);

#line 18
    }

#line 18
    if(_S25)
    {

#line 18
        return;
    }

#line 19
    float2 uv_1 = (float2(gid_0) + float2(0.5f) ) / float2(_S24) * float2((1.0f + 2.0f * (&kernelContext_3)->pu_0->pad_0))  - float2((&kernelContext_3)->pu_0->pad_0) ;
    float2 _S26 = (&kernelContext_3)->pu_0->canvas_0;

#line 20
    thread TransitionSideU_0 _S27 = s_2;

#line 20
    float4 _S28 = transitionSide_0((&kernelContext_3)->in0_0, uv_1, &_S27, _S26, &kernelContext_3);

#line 20
    (&kernelContext_3)->out0_0.write(_S28,gid_0);
    return;
}

