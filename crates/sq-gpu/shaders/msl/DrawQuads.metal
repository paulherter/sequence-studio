#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 9 "crates/sq-gpu/shaders-src/DrawQuads.slang"
struct Quad_0
{
    float4 rect_0;
    float4 uv_0;
    float4 color_0;
    float radius_0;
    float stroke_0;
    float kind_0;
    float pad_0;
    float4 clip_0;
};


#line 11
struct SLANG_ParameterGroup_C_0
{
    float2 screen_0;
    float fullRange_0;
    float hasVideo_0;
    float viewExponent_0;
    float viewScale_0;
    float2 pad0_0;
};


#line 20
struct KernelContext_0
{
    uint32_t device* quads_0;
    SLANG_ParameterGroup_C_0 constant* C_0;
    texture2d<float, access::sample> luma_0;
    sampler smp_0;
    texture2d<float, access::sample> chroma_0;
    texture2d<float, access::sample> image0_0;
    texture2d<float, access::sample> image1_0;
    texture2d<float, access::sample> image2_0;
    texture2d<float, access::sample> image3_0;
    texture2d<float, access::sample> image4_0;
    texture2d<float, access::sample> image5_0;
    texture2d<float, access::sample> atlas_0;
};


#line 33
Quad_0 loadQuad_0(uint i_0, KernelContext_0 thread* kernelContext_0)
{

#line 34
    uint o_0 = i_0 * 80U;
    thread Quad_0 q_0;

#line 35
    uint _S1 = as_type<uint>(kernelContext_0->quads_0[(o_0)>>2]);

#line 35
    uint _S2 = as_type<uint>(kernelContext_0->quads_0[(o_0 + 4U)>>2]);

#line 35
    uint _S3 = as_type<uint>(kernelContext_0->quads_0[(o_0 + 8U)>>2]);

#line 35
    uint _S4 = as_type<uint>(kernelContext_0->quads_0[(o_0 + 12U)>>2]);
    (&q_0)->rect_0 = (as_type<float4>((uint4(_S1, _S2, _S3, _S4))));
    uint _S5 = o_0 + 16U;

#line 37
    uint _S6 = as_type<uint>(kernelContext_0->quads_0[(_S5)>>2]);

#line 37
    uint _S7 = as_type<uint>(kernelContext_0->quads_0[(_S5 + 4U)>>2]);

#line 37
    uint _S8 = as_type<uint>(kernelContext_0->quads_0[(_S5 + 8U)>>2]);

#line 37
    uint _S9 = as_type<uint>(kernelContext_0->quads_0[(_S5 + 12U)>>2]);

#line 37
    (&q_0)->uv_0 = (as_type<float4>((uint4(_S6, _S7, _S8, _S9))));
    uint _S10 = o_0 + 32U;

#line 38
    uint _S11 = as_type<uint>(kernelContext_0->quads_0[(_S10)>>2]);

#line 38
    uint _S12 = as_type<uint>(kernelContext_0->quads_0[(_S10 + 4U)>>2]);

#line 38
    uint _S13 = as_type<uint>(kernelContext_0->quads_0[(_S10 + 8U)>>2]);

#line 38
    uint _S14 = as_type<uint>(kernelContext_0->quads_0[(_S10 + 12U)>>2]);

#line 38
    (&q_0)->color_0 = (as_type<float4>((uint4(_S11, _S12, _S13, _S14))));
    uint _S15 = o_0 + 48U;

#line 39
    uint _S16 = as_type<uint>(kernelContext_0->quads_0[(_S15)>>2]);

#line 39
    uint _S17 = as_type<uint>(kernelContext_0->quads_0[(_S15 + 4U)>>2]);

#line 39
    uint _S18 = as_type<uint>(kernelContext_0->quads_0[(_S15 + 8U)>>2]);

#line 39
    uint _S19 = as_type<uint>(kernelContext_0->quads_0[(_S15 + 12U)>>2]);

#line 39
    float4 m_0 = (as_type<float4>((uint4(_S16, _S17, _S18, _S19))));
    (&q_0)->radius_0 = m_0.x;

#line 40
    (&q_0)->stroke_0 = m_0.y;

#line 40
    (&q_0)->kind_0 = m_0.z;

#line 40
    (&q_0)->pad_0 = m_0.w;
    uint _S20 = o_0 + 64U;

#line 41
    uint _S21 = as_type<uint>(kernelContext_0->quads_0[(_S20)>>2]);

#line 41
    uint _S22 = as_type<uint>(kernelContext_0->quads_0[(_S20 + 4U)>>2]);

#line 41
    uint _S23 = as_type<uint>(kernelContext_0->quads_0[(_S20 + 8U)>>2]);

#line 41
    uint _S24 = as_type<uint>(kernelContext_0->quads_0[(_S20 + 12U)>>2]);

#line 41
    (&q_0)->clip_0 = (as_type<float4>((uint4(_S21, _S22, _S23, _S24))));
    return q_0;
}


#line 65
float4 sampleImage_0(float slot_0, float2 uv_1, KernelContext_0 thread* kernelContext_1)
{

#line 66
    if(slot_0 < 0.5f)
    {

#line 66
        return ((kernelContext_1->image0_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
    }

#line 67
    if(slot_0 < 1.5f)
    {

#line 67
        return ((kernelContext_1->image1_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
    }

#line 68
    if(slot_0 < 2.5f)
    {

#line 68
        return ((kernelContext_1->image2_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
    }

#line 69
    if(slot_0 < 3.5f)
    {

#line 69
        return ((kernelContext_1->image3_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
    }

#line 70
    if(slot_0 < 4.5f)
    {

#line 70
        return ((kernelContext_1->image4_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
    }

#line 71
    return ((kernelContext_1->image5_0).sample((kernelContext_1->smp_0), (uv_1), level((0.0f))));
}


#line 59
float roundBox_0(float2 c_0, float2 h_0, float r_0)
{

#line 60
    float2 q_1 = abs(c_0) - h_0 + float2(r_0) ;

    return saturate(0.5f - (length(max(q_1, float2(0.0f) )) + min(max(q_1.x, q_1.y), 0.0f) - r_0));
}


#line 76
float4 shadeAt_0(const Quad_0 thread* q_2, float2 p_0, bool guardRect_0, KernelContext_0 thread* kernelContext_2)
{

#line 77
    float _S25 = p_0.x;

#line 77
    float4 _S26 = q_2->clip_0;

#line 77
    bool _S27;

#line 77
    if(_S25 < (q_2->clip_0.x))
    {

#line 77
        _S27 = true;

#line 77
    }
    else
    {

#line 77
        _S27 = (p_0.y) < (_S26.y);

#line 77
    }

#line 77
    if(_S27)
    {

#line 77
        _S27 = true;

#line 77
    }
    else
    {

#line 77
        _S27 = _S25 >= (_S26.z);

#line 77
    }

#line 77
    if(_S27)
    {

#line 77
        _S27 = true;

#line 77
    }
    else
    {

#line 77
        _S27 = (p_0.y) >= (_S26.w);

#line 77
    }

#line 77
    if(_S27)
    {

#line 77
        return float4(0.0f) ;
    }

#line 77
    float4 _S28 = q_2->rect_0;
    float2 l_0 = p_0 - q_2->rect_0.xy;

#line 78
    float _S29 = q_2->kind_0;

#line 78
    float cov_0;

    if((q_2->kind_0) < 0.5f)
    {

#line 81
        float2 h_1 = _S28.zw / float2(2.0f) ;
        float _S30 = min(q_2->radius_0, min(h_1.x, h_1.y));
        float2 _S31 = l_0 - h_1;

#line 83
        float cov_1 = roundBox_0(_S31, h_1, _S30);

#line 83
        float _S32 = q_2->stroke_0;
        if((q_2->stroke_0) > 0.0f)
        {

#line 85
            float2 ih_0 = h_1 - float2(_S32) ;
            if((ih_0.x) > 0.0f)
            {

#line 86
                _S27 = (ih_0.y) > 0.0f;

#line 86
            }
            else
            {

#line 86
                _S27 = false;

#line 86
            }

#line 86
            if(_S27)
            {

#line 86
                cov_0 = cov_1 - roundBox_0(_S31, ih_0, max(_S30 - _S32, 0.0f));

#line 86
            }
            else
            {

#line 86
                cov_0 = cov_1;

#line 86
            }

#line 84
        }
        else
        {

#line 84
            cov_0 = cov_1;

#line 84
        }

#line 84
        cov_0 = max(cov_0, 0.0f);

#line 80
    }
    else
    {

#line 89
        if(_S29 < 1.5f)
        {

#line 90
            float _S33 = l_0.x;

#line 90
            float _S34 = l_0.y;
            int3 _S35 = int3(int2(int(q_2->uv_0.x) + int(_S33), int(q_2->uv_0.y) + int(_S34)), int(0));

#line 91
            float _S36 = ((kernelContext_2->atlas_0).read(vec<uint,2>(((_S35)).xy), uint(((_S35)).z)).x);
            if(guardRect_0)
            {

#line 92
                if(_S33 < 0.0f)
                {

#line 92
                    _S27 = true;

#line 92
                }
                else
                {

#line 92
                    _S27 = _S34 < 0.0f;

#line 92
                }

#line 92
                if(_S27)
                {

#line 92
                    _S27 = true;

#line 92
                }
                else
                {

#line 92
                    _S27 = _S33 >= (_S28.z);

#line 92
                }

#line 92
                if(_S27)
                {

#line 92
                    _S27 = true;

#line 92
                }
                else
                {

#line 92
                    _S27 = _S34 >= (_S28.w);

#line 92
                }

#line 92
            }
            else
            {

#line 92
                _S27 = false;

#line 92
            }

#line 92
            if(_S27)
            {

#line 92
                cov_0 = 0.0f;

#line 92
            }
            else
            {

#line 92
                cov_0 = _S36;

#line 92
            }

#line 89
        }
        else
        {

            if(_S29 > 3.5f)
            {

#line 94
                float2 _S37 = q_2->uv_0.xy;

#line 94
                float2 d_0 = q_2->uv_0.zw - _S37;
                float len2_0 = dot(d_0, d_0);
                if(len2_0 > 0.0f)
                {

#line 96
                    cov_0 = saturate(dot(p_0 - _S37, d_0) / len2_0);

#line 96
                }
                else
                {

#line 96
                    cov_0 = 0.0f;

#line 96
                }

#line 96
                cov_0 = saturate(q_2->stroke_0 / 2.0f + 0.5f - length(p_0 - (_S37 + d_0 * float2(cov_0) )));

#line 93
            }
            else
            {



                if((q_2->uv_0.x) > 0.5f)
                {

#line 99
                    cov_0 = _S28.z - l_0.x;

#line 99
                }
                else
                {

#line 99
                    cov_0 = l_0.x;

#line 99
                }
                float w_0 = _S28.z;

#line 100
                float h_2 = _S28.w;
                float n_0 = sqrt(w_0 * w_0 + h_2 * h_2 / 4.0f);
                float _S38 = l_0.y;

#line 102
                float _S39 = cov_0 * h_2;

#line 102
                cov_0 = saturate(min(cov_0, min((_S38 * w_0 - _S39 / 2.0f) / n_0, ((h_2 - _S38) * w_0 - _S39 / 2.0f) / n_0)) + 0.5f);

#line 93
            }

#line 89
        }

#line 80
    }

#line 106
    return float4(q_2->color_0.xyz, q_2->color_0.w * cov_0);
}


#line 106
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 106
struct pixelInput_0
{
    [[flat]] uint id_0 [[user(QUADID)]];
};


#line 110
[[fragment]] pixelOutput_0 quadFragment(pixelInput_0 _S40 [[stage_in]], float4 pos_0 [[position]], uint32_t device* quads_1 [[buffer(1)]], SLANG_ParameterGroup_C_0 constant* C_1 [[buffer(0)]], texture2d<float, access::sample> luma_1 [[texture(1)]], sampler smp_1 [[sampler(1)]], texture2d<float, access::sample> chroma_1 [[texture(2)]], texture2d<float, access::sample> image0_1 [[texture(3)]], texture2d<float, access::sample> image1_1 [[texture(4)]], texture2d<float, access::sample> image2_1 [[texture(5)]], texture2d<float, access::sample> image3_1 [[texture(6)]], texture2d<float, access::sample> image4_1 [[texture(7)]], texture2d<float, access::sample> image5_1 [[texture(8)]], texture2d<float, access::sample> atlas_1 [[texture(0)]])
{

#line 110
    thread KernelContext_0 kernelContext_3;

#line 110
    (&kernelContext_3)->quads_0 = quads_1;

#line 110
    (&kernelContext_3)->C_0 = C_1;

#line 110
    (&kernelContext_3)->luma_0 = luma_1;

#line 110
    (&kernelContext_3)->smp_0 = smp_1;

#line 110
    (&kernelContext_3)->chroma_0 = chroma_1;

#line 110
    (&kernelContext_3)->image0_0 = image0_1;

#line 110
    (&kernelContext_3)->image1_0 = image1_1;

#line 110
    (&kernelContext_3)->image2_0 = image2_1;

#line 110
    (&kernelContext_3)->image3_0 = image3_1;

#line 110
    (&kernelContext_3)->image4_0 = image4_1;

#line 110
    (&kernelContext_3)->image5_0 = image5_1;

#line 110
    (&kernelContext_3)->atlas_0 = atlas_1;

#line 110
    Quad_0 _S41 = loadQuad_0(_S40.id_0, &kernelContext_3);

#line 110
    float vs_0;

    if(((&kernelContext_3)->C_0->viewScale_0) > 0.0f)
    {

#line 112
        vs_0 = (&kernelContext_3)->C_0->viewScale_0;

#line 112
    }
    else
    {

#line 112
        vs_0 = 1.0f;

#line 112
    }
    float2 _S42 = pos_0.xy;

#line 113
    float2 p_1 = _S42 / float2(vs_0) ;

#line 113
    bool _S43;
    if((_S41.kind_0) > 1.5f)
    {

#line 114
        _S43 = (_S41.kind_0) < 2.5f;

#line 114
    }
    else
    {

#line 114
        _S43 = false;

#line 114
    }

#line 114
    float y_0;

#line 114
    if(_S43)
    {
        float _S44 = p_1.x;

#line 116
        if(_S44 < (_S41.clip_0.x))
        {

#line 116
            _S43 = true;

#line 116
        }
        else
        {

#line 116
            _S43 = (p_1.y) < (_S41.clip_0.y);

#line 116
        }

#line 116
        if(_S43)
        {

#line 116
            _S43 = true;

#line 116
        }
        else
        {

#line 116
            _S43 = _S44 >= (_S41.clip_0.z);

#line 116
        }

#line 116
        if(_S43)
        {

#line 116
            _S43 = true;

#line 116
        }
        else
        {

#line 116
            _S43 = (p_1.y) >= (_S41.clip_0.w);

#line 116
        }

#line 116
        if(_S43)
        {

#line 116
            discard_fragment();

#line 116
        }
        if(((&kernelContext_3)->C_0->hasVideo_0) < 0.5f)
        {

#line 117
            pixelOutput_0 _S45 = { float4(0.0f, 0.0f, 0.0f, 1.0f) };

#line 117
            return _S45;
        }
        float2 _S46 = _S41.uv_0.xy;

#line 119
        float2 uv_2 = _S46 + (_S41.uv_0.zw - _S46) * (p_1 - _S41.rect_0.xy) / _S41.rect_0.zw;

        if(((&kernelContext_3)->C_0->fullRange_0) > 1.5f)
        {

#line 121
            pixelOutput_0 _S47 = { float4(pow(max((((&kernelContext_3)->luma_0).sample(((&kernelContext_3)->smp_0), (uv_2), level((0.0f)))).xyz, float3(0.0f) ), float3((&kernelContext_3)->C_0->viewExponent_0) ), 1.0f) };

#line 121
            return _S47;
        }

#line 122
        float y_1 = (((&kernelContext_3)->luma_0).sample(((&kernelContext_3)->smp_0), (uv_2), level((0.0f)))).x;
        float2 cbcr_0 = (((&kernelContext_3)->chroma_0).sample(((&kernelContext_3)->smp_0), (uv_2), level((0.0f))).xy);

#line 123
        float2 cbcr_1;
        if(((&kernelContext_3)->C_0->fullRange_0) > 0.5f)
        {

#line 124
            float2 cbcr_2 = cbcr_0 - float2(0.50196081399917603f) ;

#line 124
            y_0 = y_1;

#line 124
            cbcr_1 = cbcr_2;

#line 124
        }
        else
        {

#line 125
            float2 _S48 = (cbcr_0 * float2(255.0f)  - float2(128.0f) ) / float2(224.0f) ;

#line 125
            y_0 = (y_1 * 255.0f - 16.0f) / 219.0f;

#line 125
            cbcr_1 = _S48;

#line 124
        }

        float _S49 = cbcr_1.y;

#line 126
        float _S50 = cbcr_1.x;

#line 126
        pixelOutput_0 _S51 = { float4(pow(saturate(float3(y_0 + 1.5748000144958496f * _S49, y_0 - 0.18729999661445618f * _S50 - 0.46810001134872437f * _S49, y_0 + 1.8555999994277954f * _S50)), float3((&kernelContext_3)->C_0->viewExponent_0) ), 1.0f) };
        return _S51;
    }
    if((_S41.kind_0) > 4.5f)
    {

#line 130
        float _S52 = p_1.x;

#line 130
        if(_S52 < (_S41.clip_0.x))
        {

#line 130
            _S43 = true;

#line 130
        }
        else
        {

#line 130
            _S43 = (p_1.y) < (_S41.clip_0.y);

#line 130
        }

#line 130
        if(_S43)
        {

#line 130
            _S43 = true;

#line 130
        }
        else
        {

#line 130
            _S43 = _S52 >= (_S41.clip_0.z);

#line 130
        }

#line 130
        if(_S43)
        {

#line 130
            _S43 = true;

#line 130
        }
        else
        {

#line 130
            _S43 = (p_1.y) >= (_S41.clip_0.w);

#line 130
        }

#line 130
        if(_S43)
        {

#line 130
            discard_fragment();

#line 130
        }

        float2 _S53 = _S41.uv_0.xy;

#line 132
        float4 _S54 = sampleImage_0(_S41.pad_0, _S53 + (_S41.uv_0.zw - _S53) * (p_1 - _S41.rect_0.xy) / _S41.rect_0.zw, &kernelContext_3);

        float a_0 = _S41.color_0.w * _S54.w;
        if(a_0 <= 0.0f)
        {

#line 135
            discard_fragment();

#line 135
        }

#line 135
        pixelOutput_0 _S55 = { float4(_S41.color_0.xyz * _S54.xyz, a_0) };
        return _S55;
    }

#line 136
    int n_1;


    if(vs_0 >= 1.0f)
    {

#line 139
        n_1 = int(1);

#line 139
    }
    else
    {

#line 139
        n_1 = min(int(ceil(1.0f / vs_0)), int(4));

#line 139
    }
    if(n_1 == int(1))
    {

#line 140
        thread Quad_0 _S56 = _S41;

#line 140
        float4 _S57 = shadeAt_0(&_S56, p_1, false, &kernelContext_3);

        if((_S57.w) <= 0.0f)
        {

#line 142
            discard_fragment();

#line 142
        }

#line 142
        pixelOutput_0 _S58 = { _S57 };
        return _S58;
    }
    float2 _S59 = floor(_S42);

#line 145
    int y_2 = int(0);

#line 145
    y_0 = 0.0f;

    for(;;)
    {

#line 147
        if(y_2 < n_1)
        {
        }
        else
        {

#line 147
            break;
        }

#line 147
        int x_0 = int(0);
        for(;;)
        {

#line 148
            if(x_0 < n_1)
            {
            }
            else
            {

#line 148
                break;
            }

#line 149
            float2 _S60 = (_S59 + (float2(float(x_0), float(y_2)) + float2(0.5f) ) / float2(float(n_1)) ) / float2(vs_0) ;

#line 149
            thread Quad_0 _S61 = _S41;

#line 149
            float4 _S62 = shadeAt_0(&_S61, _S60, true, &kernelContext_3);

#line 149
            float sum_0 = y_0 + _S62.w;

#line 148
            x_0 = x_0 + int(1);

#line 148
            y_0 = sum_0;

#line 148
        }

#line 147
        y_2 = y_2 + int(1);

#line 147
    }

#line 152
    float a_1 = y_0 / float(n_1 * n_1);
    if(a_1 <= 0.0f)
    {

#line 153
        discard_fragment();

#line 153
    }

#line 153
    pixelOutput_0 _S63 = { float4(_S41.color_0.xyz, a_1) };
    return _S63;
}


#line 154
struct pixelOutput_1
{
    float4 output_1 [[color(0)]];
};


#line 154
struct pixelInput_1
{
    [[flat]] uint id_1 [[user(QUADID)]];
};


[[fragment]] pixelOutput_1 quadClear(pixelInput_1 _S64 [[stage_in]], float4 pos_1 [[position]], uint32_t device* quads_2 [[buffer(1)]], SLANG_ParameterGroup_C_0 constant* C_2 [[buffer(0)]], texture2d<float, access::sample> luma_2 [[texture(1)]], sampler smp_2 [[sampler(1)]], texture2d<float, access::sample> chroma_2 [[texture(2)]], texture2d<float, access::sample> image0_2 [[texture(3)]], texture2d<float, access::sample> image1_2 [[texture(4)]], texture2d<float, access::sample> image2_2 [[texture(5)]], texture2d<float, access::sample> image3_2 [[texture(6)]], texture2d<float, access::sample> image4_2 [[texture(7)]], texture2d<float, access::sample> image5_2 [[texture(8)]], texture2d<float, access::sample> atlas_2 [[texture(0)]])
{

#line 160
    thread KernelContext_0 kernelContext_4;

#line 160
    (&kernelContext_4)->quads_0 = quads_2;

#line 160
    (&kernelContext_4)->C_0 = C_2;

#line 160
    (&kernelContext_4)->luma_0 = luma_2;

#line 160
    (&kernelContext_4)->smp_0 = smp_2;

#line 160
    (&kernelContext_4)->chroma_0 = chroma_2;

#line 160
    (&kernelContext_4)->image0_0 = image0_2;

#line 160
    (&kernelContext_4)->image1_0 = image1_2;

#line 160
    (&kernelContext_4)->image2_0 = image2_2;

#line 160
    (&kernelContext_4)->image3_0 = image3_2;

#line 160
    (&kernelContext_4)->image4_0 = image4_2;

#line 160
    (&kernelContext_4)->image5_0 = image5_2;

#line 160
    (&kernelContext_4)->atlas_0 = atlas_2;

#line 160
    Quad_0 _S65 = loadQuad_0(_S64.id_1, &kernelContext_4);

    float2 _S66 = pos_1.xy;

#line 162
    float _S67;

#line 162
    if(((&kernelContext_4)->C_0->viewScale_0) > 0.0f)
    {

#line 162
        _S67 = (&kernelContext_4)->C_0->viewScale_0;

#line 162
    }
    else
    {

#line 162
        _S67 = 1.0f;

#line 162
    }

#line 162
    float2 p_2 = _S66 / float2(_S67) ;
    float _S68 = p_2.x;

#line 163
    bool _S69;

#line 163
    if(_S68 < (_S65.clip_0.x))
    {

#line 163
        _S69 = true;

#line 163
    }
    else
    {

#line 163
        _S69 = (p_2.y) < (_S65.clip_0.y);

#line 163
    }

#line 163
    if(_S69)
    {

#line 163
        _S69 = true;

#line 163
    }
    else
    {

#line 163
        _S69 = _S68 >= (_S65.clip_0.z);

#line 163
    }

#line 163
    if(_S69)
    {

#line 163
        _S69 = true;

#line 163
    }
    else
    {

#line 163
        _S69 = (p_2.y) >= (_S65.clip_0.w);

#line 163
    }

#line 163
    if(_S69)
    {

#line 163
        discard_fragment();

#line 163
    }

#line 163
    pixelOutput_1 _S70 = { float4(0.0f, 0.0f, 0.0f, 0.0f) };
    return _S70;
}


#line 164
struct quadVertex_Result_0
{
    float4 pos_2 [[position]];
    uint id_2 [[user(QUADID)]];
};


#line 45
struct QuadOut_0
{
    float4 pos_3;
    [[flat]] uint id_3;
};


#line 45
[[vertex]] quadVertex_Result_0 quadVertex(uint vid_0 [[vertex_id]], uint iid_0 [[instance_id]], uint base_instance_0 [[base_instance]], uint32_t device* quads_3 [[buffer(1)]], SLANG_ParameterGroup_C_0 constant* C_3 [[buffer(0)]], texture2d<float, access::sample> luma_3 [[texture(1)]], sampler smp_3 [[sampler(1)]], texture2d<float, access::sample> chroma_3 [[texture(2)]], texture2d<float, access::sample> image0_3 [[texture(3)]], texture2d<float, access::sample> image1_3 [[texture(4)]], texture2d<float, access::sample> image2_3 [[texture(5)]], texture2d<float, access::sample> image3_3 [[texture(6)]], texture2d<float, access::sample> image4_3 [[texture(7)]], texture2d<float, access::sample> image5_3 [[texture(8)]], texture2d<float, access::sample> atlas_3 [[texture(0)]])
{

#line 45
    thread KernelContext_0 kernelContext_5;

#line 45
    (&kernelContext_5)->quads_0 = quads_3;

#line 45
    (&kernelContext_5)->C_0 = C_3;

#line 45
    (&kernelContext_5)->luma_0 = luma_3;

#line 45
    (&kernelContext_5)->smp_0 = smp_3;

#line 45
    (&kernelContext_5)->chroma_0 = chroma_3;

#line 45
    (&kernelContext_5)->image0_0 = image0_3;

#line 45
    (&kernelContext_5)->image1_0 = image1_3;

#line 45
    (&kernelContext_5)->image2_0 = image2_3;

#line 45
    (&kernelContext_5)->image3_0 = image3_3;

#line 45
    (&kernelContext_5)->image4_0 = image4_3;

#line 45
    (&kernelContext_5)->image5_0 = image5_3;

#line 45
    (&kernelContext_5)->atlas_0 = atlas_3;

#line 45
    uint _S71 = iid_0 - base_instance_0;

#line 45
    bool _S72;



    if(vid_0 == 1U)
    {

#line 49
        _S72 = true;

#line 49
    }
    else
    {

#line 49
        _S72 = vid_0 == 4U;

#line 49
    }

#line 49
    if(_S72)
    {

#line 49
        _S72 = true;

#line 49
    }
    else
    {

#line 49
        _S72 = vid_0 == 5U;

#line 49
    }

#line 49
    float _S73;

#line 49
    if(_S72)
    {

#line 49
        _S73 = 1.0f;

#line 49
    }
    else
    {

#line 49
        _S73 = 0.0f;

#line 49
    }

#line 49
    if(vid_0 == 2U)
    {

#line 49
        _S72 = true;

#line 49
    }
    else
    {

#line 49
        _S72 = vid_0 == 3U;

#line 49
    }

#line 49
    if(_S72)
    {

#line 49
        _S72 = true;

#line 49
    }
    else
    {

#line 49
        _S72 = vid_0 == 5U;

#line 49
    }

#line 49
    float _S74;

#line 49
    if(_S72)
    {

#line 49
        _S74 = 1.0f;

#line 49
    }
    else
    {

#line 49
        _S74 = 0.0f;

#line 49
    }

#line 49
    float2 corner_0 = float2(_S73, _S74);

#line 49
    Quad_0 _S75 = loadQuad_0(_S71, &kernelContext_5);

    float2 px_0 = _S75.rect_0.xy + corner_0 * _S75.rect_0.zw;
    thread QuadOut_0 o_1;
    if(((&kernelContext_5)->C_0->viewScale_0) > 0.0f)
    {

#line 53
        _S73 = (&kernelContext_5)->C_0->viewScale_0;

#line 53
    }
    else
    {

#line 53
        _S73 = 1.0f;

#line 53
    }

#line 53
    float2 px_1 = px_0 * float2(_S73) ;
    (&o_1)->pos_3 = float4(px_1.x / (&kernelContext_5)->C_0->screen_0.x * 2.0f - 1.0f, 1.0f - px_1.y / (&kernelContext_5)->C_0->screen_0.y * 2.0f, 0.0f, 1.0f);
    (&o_1)->id_3 = _S71;
    QuadOut_0 _S76 = o_1;

#line 56
    thread quadVertex_Result_0 _S77;

#line 56
    (&_S77)->pos_2 = _S76.pos_3;

#line 56
    (&_S77)->id_2 = _S76.id_3;

#line 56
    return _S77;
}

