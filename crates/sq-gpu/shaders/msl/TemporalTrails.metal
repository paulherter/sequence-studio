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


#line 4 "crates/sq-gpu/shaders-src/TemporalTrails.slang"
struct TrailsU_0
{
    uint count_0;
    uint blend_1;
    uint flags_0;
    uint pad_0;
    float4 w0_0;
    float4 w1_0;
};


#line 23 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    CompositeU_0 constant* cu_0;
    TrailsU_0 constant* ru_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in18_0;
    sampler edgeSampler_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in9_0;
    texture2d<float, access::sample> in1_0;
    texture2d<float, access::sample> in10_0;
    texture2d<float, access::sample> in2_0;
    texture2d<float, access::sample> in11_0;
    texture2d<float, access::sample> in3_0;
    texture2d<float, access::sample> in12_0;
    texture2d<float, access::sample> in4_0;
    texture2d<float, access::sample> in13_0;
    texture2d<float, access::sample> in5_0;
    texture2d<float, access::sample> in14_0;
    texture2d<float, access::sample> in6_0;
    texture2d<float, access::sample> in15_0;
    texture2d<float, access::sample> in7_0;
    texture2d<float, access::sample> in16_0;
    texture2d<float, access::sample> in8_0;
    texture2d<float, access::sample> in17_0;
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


#line 7 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
uint2 texSize_0(texture2d<float, access::sample> t_0)
{

#line 7
    thread uint w_1;

#line 7
    thread uint h_1;

#line 7
    (*((&w_1)) = (t_0).get_width(0)),(*((&h_1)) = (t_0).get_height(0));

#line 7
    return uint2(w_1, h_1);
}


#line 46
float3 inverseOETF709_0(float3 e_0)
{

#line 47
    float3 _S2 = max(e_0, float3(0.0f) );


    return select(pow((_S2 + float3(0.099296823143959045f) ) / float3(1.0992968082427979f) , float3(2.2222223281860352f) ), _S2 / float3(4.5f) , _S2 < (float3(0.081242859363555908f) ));
}


#line 8 "crates/sq-gpu/shaders-src/Parts/Transfer.slang"
float slog3Decode_0(float x_0)
{

#line 9
    if(x_0 >= 0.16736099123954773f)
    {

#line 9
        return pow(10.0f, (x_0 * 1023.0f - 420.0f) / 261.5f) * 0.1900000125169754f - 0.0099999997764825821f;
    }

#line 10
    return (x_0 * 1023.0f - 95.0f) * 0.011250000447034836f / 76.210296630859375f;
}




float slog3DecodeLegal_0(float v_0)
{

#line 16
    return slog3Decode_0((v_0 * 876.0f + 64.0f) / 1023.0f);
}


#line 25
float hlgInverseOETF_0(float e_1)
{

#line 26
    float _S3 = max(e_1, 0.0f);
    if(_S3 <= 0.5f)
    {

#line 27
        return _S3 * _S3 / 3.0f;
    }

#line 28
    return (exp((_S3 - 0.55991071462631226f) / 0.1788327693939209f) + 0.28466892242431641f) / 12.0f;
}


#line 36
float hlgScale_0()
{

#line 37
    float e_2 = hlgInverseOETF_0(0.75f);
    return 1.0f / (e_2 * pow(e_2, 0.20000004768371582f));
}


#line 40
float3 hlgDecode3_0(float3 v_1)
{

#line 41
    float3 e_3 = float3(hlgInverseOETF_0(v_1.x), hlgInverseOETF_0(v_1.y), hlgInverseOETF_0(v_1.z));
    float ys_0 = dot(float3(0.26269999146461487f, 0.67799997329711914f, 0.059300001710653305f), e_3);

#line 42
    float gain_0;
    if(ys_0 > 0.0f)
    {

#line 43
        gain_0 = pow(ys_0, 0.20000004768371582f);

#line 43
    }
    else
    {

#line 43
        gain_0 = 0.0f;

#line 43
    }
    return e_3 * float3(gain_0)  * float3(hlgScale_0()) ;
}


#line 62
float tfBt709InverseOETF_0(float v_2)
{

#line 63
    if(v_2 < 0.081242859363555908f)
    {

#line 63
        return v_2 / 4.5f;
    }

#line 64
    return pow((v_2 + 1.0992968082427979f - 1.0f) / 1.0992968082427979f, 2.2222223281860352f);
}



float vlogDecode_0(float x_1)
{

#line 69
    float _S4;

#line 69
    if(x_1 < 0.1809999942779541f)
    {

#line 69
        _S4 = (x_1 - 0.125f) / 5.5999999046325684f;

#line 69
    }
    else
    {

#line 69
        _S4 = pow(10.0f, (x_1 - 0.59820598363876343f) / 0.24151399731636047f) - 0.0087299998849630356f;

#line 69
    }

#line 69
    return _S4;
}


#line 71
float vlogDecodeLegal_0(float v_3)
{

#line 71
    return vlogDecode_0((v_3 * 876.0f + 64.0f) / 1023.0f);
}


#line 110
float appleLogDecode_0(float p_0)
{
    if(p_0 >= 0.20855531096458435f)
    {

#line 112
        return pow(2.0f, (p_0 - 0.69336944818496704f) / 0.085504792630672455f) - 0.0096405204385519028f;
    }

#line 113
    if(p_0 >= 0.0f)
    {

#line 113
        return sqrt(p_0 / 47.287113189697266f) + -0.056410878896713257f;
    }

#line 114
    return -0.056410878896713257f;
}


#line 125
float pqDecode_0(float e_4)
{

#line 126
    float p_1 = pow(max(e_4, 0.0f), 0.012683313339948654f);

    return pow(max(p_1 - 0.8359375f, 0.0f) / (18.8515625f - 18.6875f * p_1), 6.2773947715759277f) * 10000.0f / 203.0f;
}


#line 74
float dlogDecode_0(float x_2)
{

#line 74
    float _S5;

#line 74
    if(x_2 <= 0.14000000059604645f)
    {

#line 74
        _S5 = (x_2 - 0.092900000512599945f) / 6.0250000953674316f;

#line 74
    }
    else
    {

#line 74
        _S5 = (pow(10.0f, 3.8961598873138428f * x_2 - 2.2775199413299561f) - 0.01080000028014183f) / 0.98919999599456787f;

#line 74
    }

#line 74
    return _S5;
}


#line 76
float dlogDecodeLegal_0(float v_4)
{

#line 76
    return dlogDecode_0((v_4 * 876.0f + 64.0f) / 1023.0f);
}


float canonMirroredDecode_0(float x_3, float a_0, float k_0, float c_0)
{

#line 80
    float _S6;
    if(x_3 < c_0)
    {

#line 81
        _S6 = - (pow(10.0f, (c_0 - x_3) / a_0) - 1.0f) / k_0;

#line 81
    }
    else
    {

#line 81
        _S6 = (pow(10.0f, (x_3 - c_0) / a_0) - 1.0f) / k_0;

#line 81
    }

#line 81
    return _S6 * 0.89999997615814209f;
}




float canonLogDecodeLegal_0(float v_5)
{

#line 87
    return canonMirroredDecode_0((v_5 * 876.0f + 64.0f) / 1023.0f, 0.45310178399085999f, 10.159600257873535f, 0.12512247264385223f);
}


#line 89
float canonLog2DecodeLegal_0(float v_6)
{

#line 89
    return canonMirroredDecode_0((v_6 * 876.0f + 64.0f) / 1023.0f, 0.24136076867580414f, 87.099372863769531f, 0.092864125967025757f);
}

float canonLog3Decode_0(float x_4)
{

#line 92
    float l_0;

    if(x_4 < 0.097465470433235168f)
    {

#line 94
        l_0 = - (pow(10.0f, (0.12783901393413544f - x_4) / 0.36726844310760498f) - 1.0f) / 14.983249664306641f;

#line 94
    }
    else
    {

#line 95
        if(x_4 <= 0.15277890861034393f)
        {

#line 95
            l_0 = (x_4 - 0.12512218952178955f) / 1.9754798412322998f;

#line 95
        }
        else
        {

#line 95
            l_0 = (pow(10.0f, (x_4 - 0.12240537256002426f) / 0.36726844310760498f) - 1.0f) / 14.983249664306641f;

#line 95
        }

#line 94
    }


    return l_0 * 0.89999997615814209f;
}


#line 105
float canonLog3DecodeLegal_0(float v_7)
{

#line 105
    return canonLog3Decode_0((v_7 * 876.0f + 64.0f) / 1023.0f);
}


#line 12
float slog3Encode_0(float y_0)
{

#line 13
    if(y_0 >= 0.011250000447034836f)
    {

#line 13
        return (420.0f + log10((y_0 + 0.0099999997764825821f) / 0.1900000125169754f) * 261.5f) / 1023.0f;
    }

#line 14
    return (y_0 * 76.210296630859375f / 0.011250000447034836f + 95.0f) / 1023.0f;
}

float slog3EncodeLegal_0(float y_1)
{

#line 17
    return (slog3Encode_0(y_1) * 1023.0f - 64.0f) / 876.0f;
}


#line 30
float hlgOETF_0(float s_0)
{

#line 31
    float _S7 = max(s_0, 0.0f);
    if(_S7 <= 0.083333335816860199f)
    {

#line 32
        return sqrt(3.0f * _S7);
    }

#line 33
    return 0.1788327693939209f * log(12.0f * _S7 - 0.28466892242431641f) + 0.55991071462631226f;
}


#line 46
float3 hlgEncode3_0(float3 v_8)
{

#line 47
    float3 fd_0 = v_8 / float3(hlgScale_0()) ;
    float yd_0 = dot(float3(0.26269999146461487f, 0.67799997329711914f, 0.059300001710653305f), fd_0);
    if(!(yd_0 > 0.0f))
    {

#line 49
        return float3(hlgOETF_0(0.0f)) ;
    }
    float3 e_5 = fd_0 / float3(pow(pow(yd_0, 0.83333331346511841f), 0.20000004768371582f)) ;
    return float3(hlgOETF_0(e_5.x), hlgOETF_0(e_5.y), hlgOETF_0(e_5.z));
}




float tfBt709OETF_0(float l_1)
{

#line 59
    if(l_1 < 0.018053969368338585f)
    {

#line 59
        return 4.5f * l_1;
    }

#line 60
    return 1.0992968082427979f * pow(l_1, 0.44999998807907104f) - 0.099296808242797852f;
}


#line 70
float vlogEncode_0(float y_2)
{

#line 70
    float _S8;

#line 70
    if(y_2 < 0.0099999997764825821f)
    {

#line 70
        _S8 = 5.5999999046325684f * y_2 + 0.125f;

#line 70
    }
    else
    {

#line 70
        _S8 = 0.24151399731636047f * log10(y_2 + 0.0087299998849630356f) + 0.59820598363876343f;

#line 70
    }

#line 70
    return _S8;
}


#line 72
float vlogEncodeLegal_0(float y_3)
{

#line 72
    return (vlogEncode_0(y_3) * 1023.0f - 64.0f) / 876.0f;
}


#line 116
float appleLogEncode_0(float x_5)
{

#line 117
    if(x_5 >= 0.0099999997764825821f)
    {

#line 117
        return 0.085504792630672455f * log2(x_5 + 0.0096405204385519028f) + 0.69336944818496704f;
    }

#line 118
    if(x_5 >= -0.056410878896713257f)
    {

#line 118
        float _S9 = x_5 - -0.056410878896713257f;

#line 118
        return 47.287113189697266f * _S9 * _S9;
    }

#line 119
    return 0.0f;
}


#line 130
float pqEncode_0(float l_2)
{

#line 131
    float y_4 = pow(max(l_2, 0.0f) * 203.0f / 10000.0f, 0.1593017578125f);
    return pow((0.8359375f + 18.8515625f * y_4) / (1.0f + 18.6875f * y_4), 78.84375f);
}


#line 75
float dlogEncode_0(float y_5)
{

#line 75
    float _S10;

#line 75
    if(y_5 <= 0.007799999788403511f)
    {

#line 75
        _S10 = 6.0250000953674316f * y_5 + 0.092900000512599945f;

#line 75
    }
    else
    {

#line 75
        _S10 = log10(y_5 * 0.98919999599456787f + 0.01080000028014183f) * 0.2566629946231842f + 0.58455497026443481f;

#line 75
    }

#line 75
    return _S10;
}


#line 77
float dlogEncodeLegal_0(float y_6)
{

#line 77
    return (dlogEncode_0(y_6) * 1023.0f - 64.0f) / 876.0f;
}




float canonMirroredEncode_0(float y_7, float a_1, float k_1, float c_1)
{

#line 84
    float l_3 = y_7 / 0.89999997615814209f;

#line 84
    float _S11;
    if(l_3 < 0.0f)
    {

#line 85
        _S11 = - (a_1 * log10(- l_3 * k_1 + 1.0f) - c_1);

#line 85
    }
    else
    {

#line 85
        _S11 = a_1 * log10(l_3 * k_1 + 1.0f) + c_1;

#line 85
    }

#line 85
    return _S11;
}

float canonLogEncodeLegal_0(float y_8)
{

#line 88
    return (canonMirroredEncode_0(y_8, 0.45310178399085999f, 10.159600257873535f, 0.12512247264385223f) * 1023.0f - 64.0f) / 876.0f;
}


#line 90
float canonLog2EncodeLegal_0(float y_9)
{

#line 90
    return (canonMirroredEncode_0(y_9, 0.24136076867580414f, 87.099372863769531f, 0.092864125967025757f) * 1023.0f - 64.0f) / 876.0f;
}


#line 99
float canonLog3Encode_0(float y_10)
{

#line 100
    float l_4 = y_10 / 0.89999997615814209f;
    if(l_4 < -0.014000000432133675f)
    {

#line 101
        return -0.36726844310760498f * log10(- l_4 * 14.983249664306641f + 1.0f) + 0.12783901393413544f;
    }

#line 102
    if(l_4 <= 0.014000000432133675f)
    {

#line 102
        return 1.9754798412322998f * l_4 + 0.12512218952178955f;
    }

#line 103
    return 0.36726844310760498f * log10(l_4 * 14.983249664306641f + 1.0f) + 0.12240537256002426f;
}

float canonLog3EncodeLegal_0(float y_11)
{

#line 106
    return (canonLog3Encode_0(y_11) * 1023.0f - 64.0f) / 876.0f;
}


#line 137
float legalToCode_0(float v_9)
{

#line 137
    return (v_9 * 876.0f + 64.0f) / 1023.0f;
}


#line 139
float logC3Decode_0(float x_6)
{

#line 139
    float _S12;

#line 139
    if(x_6 > 0.14965783059597015f)
    {

#line 139
        _S12 = (pow(10.0f, (x_6 - 0.38553699851036072f) / 0.24718999862670898f) - 0.052271999418735504f) / 5.5555558204650879f;

#line 139
    }
    else
    {

#line 139
        _S12 = (x_6 - 0.092808999121189117f) / 5.3676548004150391f;

#line 139
    }

#line 139
    return _S12;
}


float logC4Decode_0(float x_7)
{

#line 143
    float _S13;

#line 143
    if(x_7 >= 0.0f)
    {

#line 143
        _S13 = (pow(2.0f, 14.0f * (x_7 - 0.092864125967025757f) / 0.90713590383529663f + 6.0f) - 64.0f) / 2231.826416015625f;

#line 143
    }
    else
    {

#line 143
        _S13 = x_7 * 0.11359720677137375f + -0.018056996166706085f;

#line 143
    }

#line 143
    return _S13;
}


#line 145
float log3G10Decode_0(float y_12)
{

#line 145
    float _S14;

#line 145
    if(y_12 < 0.0f)
    {

#line 145
        _S14 = y_12 / 15.192700386047363f - 0.0099999997764825821f;

#line 145
    }
    else
    {

#line 145
        _S14 = (pow(10.0f, y_12 / 0.22428199648857117f) - 1.0f) / 155.97532653808594f - 0.0099999997764825821f;

#line 145
    }

#line 145
    return _S14;
}


#line 147
float bmdDecode_0(float y_13)
{

#line 147
    float _S15;

#line 147
    if(y_13 < 0.1338837742805481f)
    {

#line 147
        _S15 = (y_13 - 0.092465750873088837f) / 8.2836055755615234f;

#line 147
    }
    else
    {

#line 147
        _S15 = exp((y_13 - 0.5300133228302002f) / 0.086928762495517731f) - 0.0054940725676715374f;

#line 147
    }

#line 147
    return _S15;
}


#line 149
float nLogDecode_0(float x_8)
{

#line 150
    float cv_0 = x_8 * 1023.0f;
    if(cv_0 < (150.0f * log(0.32800000905990601f) + 619.0f))
    {

#line 151
        float t_1 = cv_0 / 650.0f;

#line 151
        return t_1 * t_1 * t_1 - 0.0074999998323619366f;
    }

#line 152
    return exp((cv_0 - 619.0f) / 150.0f);
}

float fLog2Decode_0(float x_9)
{

#line 155
    float _S16;

#line 155
    if(x_9 >= 0.1006866842508316f)
    {

#line 155
        _S16 = (pow(10.0f, (x_9 - 0.38431599736213684f) / 0.24528099596500397f) - 0.06482899934053421f) / 5.5555558204650879f;

#line 155
    }
    else
    {

#line 155
        _S16 = (x_9 - 0.092863999307155609f) / 8.7994613647460938f;

#line 155
    }

#line 155
    return _S16;
}


#line 157
float acesCCTDecode_0(float y_14)
{

#line 157
    float _S17;

#line 157
    if(y_14 <= 0.155251145362854f)
    {

#line 157
        _S17 = (y_14 - 0.072905533015727997f) / 10.540237426757812f;

#line 157
    }
    else
    {

#line 157
        _S17 = pow(2.0f, y_14 * 17.520000457763672f - 9.7200002670288086f);

#line 157
    }

#line 157
    return _S17;
}


#line 140
float logC3Encode_0(float y_15)
{

#line 140
    float _S18;

#line 140
    if(y_15 > 0.010591000318527222f)
    {

#line 140
        _S18 = 0.24718999862670898f * log10(5.5555558204650879f * y_15 + 0.052271999418735504f) + 0.38553699851036072f;

#line 140
    }
    else
    {

#line 140
        _S18 = 5.3676548004150391f * y_15 + 0.092808999121189117f;

#line 140
    }

#line 140
    return _S18;
}


#line 138
float codeToLegal_0(float x_10)
{

#line 138
    return (x_10 * 1023.0f - 64.0f) / 876.0f;
}




float logC4Encode_0(float y_16)
{

#line 144
    float _S19;

#line 144
    if(y_16 >= -0.018056996166706085f)
    {

#line 144
        _S19 = (log2(2231.826416015625f * y_16 + 64.0f) - 6.0f) / 14.0f * 0.90713590383529663f + 0.092864125967025757f;

#line 144
    }
    else
    {

#line 144
        _S19 = (y_16 - -0.018056996166706085f) / 0.11359720677137375f;

#line 144
    }

#line 144
    return _S19;
}


#line 146
float log3G10Encode_0(float x_11)
{

#line 146
    float s_1 = x_11 + 0.0099999997764825821f;

#line 146
    float _S20;

#line 146
    if(s_1 < 0.0f)
    {

#line 146
        _S20 = s_1 * 15.192700386047363f;

#line 146
    }
    else
    {

#line 146
        _S20 = 0.22428199648857117f * log10(s_1 * 155.97532653808594f + 1.0f);

#line 146
    }

#line 146
    return _S20;
}


#line 148
float bmdEncode_0(float x_12)
{

#line 148
    float _S21;

#line 148
    if(x_12 < 0.004999999888241291f)
    {

#line 148
        _S21 = 8.2836055755615234f * x_12 + 0.092465750873088837f;

#line 148
    }
    else
    {

#line 148
        _S21 = 0.086928762495517731f * log(x_12 + 0.0054940725676715374f) + 0.5300133228302002f;

#line 148
    }

#line 148
    return _S21;
}




float nLogEncode_0(float y_17)
{

#line 154
    float _S22;

#line 154
    if(y_17 < 0.32800000905990601f)
    {

#line 154
        _S22 = 650.0f * pow(max(y_17 + 0.0074999998323619366f, 0.0f), 0.3333333432674408f) / 1023.0f;

#line 154
    }
    else
    {

#line 154
        _S22 = (150.0f * log(y_17) + 619.0f) / 1023.0f;

#line 154
    }

#line 154
    return _S22;
}


#line 156
float fLog2Encode_0(float y_18)
{

#line 156
    float _S23;

#line 156
    if(y_18 >= 0.00088900001719594002f)
    {

#line 156
        _S23 = 0.24528099596500397f * log10(5.5555558204650879f * y_18 + 0.06482899934053421f) + 0.38431599736213684f;

#line 156
    }
    else
    {

#line 156
        _S23 = 8.7994613647460938f * y_18 + 0.092863999307155609f;

#line 156
    }

#line 156
    return _S23;
}


#line 158
float acesCCTEncode_0(float x_13)
{

#line 158
    float _S24;

#line 158
    if(x_13 <= 0.0078125f)
    {

#line 158
        _S24 = 10.540237426757812f * x_13 + 0.072905533015727997f;

#line 158
    }
    else
    {

#line 158
        _S24 = (log2(x_13) + 9.7200002670288086f) / 17.520000457763672f;

#line 158
    }

#line 158
    return _S24;
}


#line 160
float3 map3_0(float3 v_10, int fn_0)
{

#line 161
    switch(fn_0)
    {
    case int(0):
        {

#line 162
            return float3(slog3DecodeLegal_0(v_10.x), slog3DecodeLegal_0(v_10.y), slog3DecodeLegal_0(v_10.z));
        }
    case int(1):
        {

#line 163
            return hlgDecode3_0(v_10);
        }
    case int(2):
        {

#line 164
            return float3(tfBt709InverseOETF_0(v_10.x), tfBt709InverseOETF_0(v_10.y), tfBt709InverseOETF_0(v_10.z));
        }
    case int(3):
        {

#line 165
            return float3(vlogDecodeLegal_0(v_10.x), vlogDecodeLegal_0(v_10.y), vlogDecodeLegal_0(v_10.z));
        }
    case int(4):
        {

#line 166
            return float3(appleLogDecode_0(v_10.x), appleLogDecode_0(v_10.y), appleLogDecode_0(v_10.z));
        }
    case int(5):
        {

#line 167
            return float3(pqDecode_0(v_10.x), pqDecode_0(v_10.y), pqDecode_0(v_10.z));
        }
    case int(6):
        {

#line 168
            return float3(dlogDecodeLegal_0(v_10.x), dlogDecodeLegal_0(v_10.y), dlogDecodeLegal_0(v_10.z));
        }
    case int(7):
        {

#line 169
            return float3(canonLogDecodeLegal_0(v_10.x), canonLogDecodeLegal_0(v_10.y), canonLogDecodeLegal_0(v_10.z));
        }
    case int(8):
        {

#line 170
            return float3(canonLog2DecodeLegal_0(v_10.x), canonLog2DecodeLegal_0(v_10.y), canonLog2DecodeLegal_0(v_10.z));
        }
    case int(9):
        {

#line 171
            return float3(canonLog3DecodeLegal_0(v_10.x), canonLog3DecodeLegal_0(v_10.y), canonLog3DecodeLegal_0(v_10.z));
        }
    case int(10):
        {

#line 172
            return float3(slog3EncodeLegal_0(v_10.x), slog3EncodeLegal_0(v_10.y), slog3EncodeLegal_0(v_10.z));
        }
    case int(11):
        {

#line 173
            return hlgEncode3_0(v_10);
        }
    case int(12):
        {

#line 174
            return float3(tfBt709OETF_0(v_10.x), tfBt709OETF_0(v_10.y), tfBt709OETF_0(v_10.z));
        }
    case int(13):
        {

#line 175
            return float3(vlogEncodeLegal_0(v_10.x), vlogEncodeLegal_0(v_10.y), vlogEncodeLegal_0(v_10.z));
        }
    case int(14):
        {

#line 176
            return float3(appleLogEncode_0(v_10.x), appleLogEncode_0(v_10.y), appleLogEncode_0(v_10.z));
        }
    case int(15):
        {

#line 177
            return float3(pqEncode_0(v_10.x), pqEncode_0(v_10.y), pqEncode_0(v_10.z));
        }
    case int(16):
        {

#line 178
            return float3(dlogEncodeLegal_0(v_10.x), dlogEncodeLegal_0(v_10.y), dlogEncodeLegal_0(v_10.z));
        }
    case int(17):
        {

#line 179
            return float3(canonLogEncodeLegal_0(v_10.x), canonLogEncodeLegal_0(v_10.y), canonLogEncodeLegal_0(v_10.z));
        }
    case int(18):
        {

#line 180
            return float3(canonLog2EncodeLegal_0(v_10.x), canonLog2EncodeLegal_0(v_10.y), canonLog2EncodeLegal_0(v_10.z));
        }
    case int(19):
        {

#line 181
            return float3(canonLog3EncodeLegal_0(v_10.x), canonLog3EncodeLegal_0(v_10.y), canonLog3EncodeLegal_0(v_10.z));
        }
    case int(20):
        {

#line 182
            return float3(logC3Decode_0(legalToCode_0(v_10.x)), logC3Decode_0(legalToCode_0(v_10.y)), logC3Decode_0(legalToCode_0(v_10.z)));
        }
    case int(21):
        {

#line 183
            return float3(logC4Decode_0(legalToCode_0(v_10.x)), logC4Decode_0(legalToCode_0(v_10.y)), logC4Decode_0(legalToCode_0(v_10.z)));
        }
    case int(22):
        {

#line 184
            return float3(log3G10Decode_0(v_10.x), log3G10Decode_0(v_10.y), log3G10Decode_0(v_10.z));
        }
    case int(23):
        {

#line 185
            return float3(bmdDecode_0(legalToCode_0(v_10.x)), bmdDecode_0(legalToCode_0(v_10.y)), bmdDecode_0(legalToCode_0(v_10.z)));
        }
    case int(24):
        {

#line 186
            return float3(nLogDecode_0(legalToCode_0(v_10.x)), nLogDecode_0(legalToCode_0(v_10.y)), nLogDecode_0(legalToCode_0(v_10.z)));
        }
    case int(25):
        {

#line 187
            return float3(fLog2Decode_0(legalToCode_0(v_10.x)), fLog2Decode_0(legalToCode_0(v_10.y)), fLog2Decode_0(legalToCode_0(v_10.z)));
        }
    case int(26):
        {

#line 188
            return float3(acesCCTDecode_0(v_10.x), acesCCTDecode_0(v_10.y), acesCCTDecode_0(v_10.z));
        }
    case int(30):
        {

#line 189
            return float3(codeToLegal_0(logC3Encode_0(v_10.x)), codeToLegal_0(logC3Encode_0(v_10.y)), codeToLegal_0(logC3Encode_0(v_10.z)));
        }
    case int(31):
        {

#line 190
            return float3(codeToLegal_0(logC4Encode_0(v_10.x)), codeToLegal_0(logC4Encode_0(v_10.y)), codeToLegal_0(logC4Encode_0(v_10.z)));
        }
    case int(32):
        {

#line 191
            return float3(log3G10Encode_0(v_10.x), log3G10Encode_0(v_10.y), log3G10Encode_0(v_10.z));
        }
    case int(33):
        {

#line 192
            return float3(codeToLegal_0(bmdEncode_0(v_10.x)), codeToLegal_0(bmdEncode_0(v_10.y)), codeToLegal_0(bmdEncode_0(v_10.z)));
        }
    case int(34):
        {

#line 193
            return float3(codeToLegal_0(nLogEncode_0(v_10.x)), codeToLegal_0(nLogEncode_0(v_10.y)), codeToLegal_0(nLogEncode_0(v_10.z)));
        }
    case int(35):
        {

#line 194
            return float3(codeToLegal_0(fLog2Encode_0(v_10.x)), codeToLegal_0(fLog2Encode_0(v_10.y)), codeToLegal_0(fLog2Encode_0(v_10.z)));
        }
    case int(36):
        {

#line 195
            return float3(acesCCTEncode_0(v_10.x), acesCCTEncode_0(v_10.y), acesCCTEncode_0(v_10.z));
        }
    default:
        {

#line 196
            return v_10;
        }
    }

#line 196
}


#line 77 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
float3 decodeCurve_0(float3 e_6, uint transfer_0)
{

#line 77
    float3 _S25;
    if(transfer_0 == 2U)
    {

#line 78
        _S25 = float3((vec<int,3>(sign((e_6))))) * inverseOETF709_0(abs(e_6));

#line 78
    }
    else
    {

#line 78
        if(transfer_0 < 30U)
        {

#line 78
            _S25 = map3_0(e_6, int(transfer_0));

#line 78
        }
        else
        {

#line 78
            _S25 = e_6;

#line 78
        }

#line 78
    }

#line 78
    return _S25;
}


#line 54
float3 oetf709_0(float3 l_5)
{

#line 55
    float3 _S26 = max(l_5, float3(0.0f) );

    return select(float3(1.0992968082427979f)  * pow(_S26, float3(0.44999998807907104f) ) - float3(0.099296823143959045f) , _S26 * float3(4.5f) , _S26 < (float3(0.018053969368338585f) ));
}


#line 80
float3 encodeCurve_0(float3 m_0, uint transfer_1)
{

#line 80
    float3 _S27;
    if(transfer_1 == 2U)
    {

#line 81
        _S27 = float3((vec<int,3>(sign((m_0))))) * oetf709_0(abs(m_0));

#line 81
    }
    else
    {

#line 81
        if(transfer_1 < 30U)
        {

#line 81
            _S27 = map3_0(m_0, int(transfer_1) + int(10));

#line 81
        }
        else
        {

#line 81
            _S27 = m_0;

#line 81
        }

#line 81
    }

#line 81
    return _S27;
}


#line 2899 "core.meta.slang"
bool alphaSource_0(KernelContext_0 thread* kernelContext_1)
{

#line 2899
    uint _S28 = kernelContext_1->cu_0->mode_0;

#line 2899
    bool _S29;

#line 44 "crates/sq-gpu/shaders-src/Parts/Convert.slang"
    if((kernelContext_1->cu_0->mode_0) == 4U)
    {

#line 44
        _S29 = true;

#line 44
    }
    else
    {

#line 44
        if(_S28 == 1U)
        {

#line 44
            _S29 = (kernelContext_1->cu_0->alphaMode_0) != 0U;

#line 44
        }
        else
        {

#line 44
            _S29 = false;

#line 44
        }

#line 44
    }

#line 44
    return _S29;
}


#line 44
float3 ycbcrToRGB_0(float3 _S30, KernelContext_0 thread* kernelContext_2)
{

#line 5
    return kernelContext_2->cu_0->m0_0.xyz * float3(_S30.x)  + kernelContext_2->cu_0->m1_0.xyz * float3(_S30.y)  + kernelContext_2->cu_0->m2_0.xyz * float3(_S30.z) ;
}


#line 5
float4 texelPremul_0(texture2d<float, access::sample> _S31, uint2 _S32, KernelContext_0 thread* kernelContext_3)
{

#line 19
    int3 _S33 = int3(int2(_S32), int(0));

#line 19
    float4 t_2 = ((_S31).read(vec<uint,2>(((_S33)).xy), uint(((_S33)).z)));
    thread float4 c_2;
    if((kernelContext_3->cu_0->mode_0) == 4U)
    {

#line 22
        float _S34 = kernelContext_3->cu_0->range_0.z;

#line 22
        float _S35 = kernelContext_3->cu_0->range_0.w;

#line 22
        float3 _S36 = ycbcrToRGB_0(float3(t_2.y * kernelContext_3->cu_0->range_0.x + kernelContext_3->cu_0->range_0.y, t_2.z * _S34 + _S35, t_2.w * _S34 + _S35), kernelContext_3);
        c_2 = float4(_S36, t_2.x);

#line 21
    }
    else
    {

        c_2 = t_2;

#line 21
    }

#line 28
    if((kernelContext_3->cu_0->alphaMode_0) == 2U)
    {

#line 28
        c_2.xyz = clamp(c_2.xyz, float3(0.0f) , float3(c_2.w) );

#line 28
    }
    else
    {

#line 28
        c_2.xyz = c_2.xyz * float3(c_2.w) ;

#line 28
    }
    return c_2;
}


#line 29
float4 samplePremul_0(texture2d<float, access::sample> _S37, float2 _S38, KernelContext_0 thread* kernelContext_4)
{

#line 29
    int2 _S39 = int2(int(1)) ;

#line 34
    int2 mx_0 = int2(texSize_0(_S37)) - _S39;
    float2 p_2 = _S38 * float2(mx_0 + _S39) - float2(0.5f) ;
    float2 fl_0 = floor(p_2);

#line 36
    float2 f_0 = p_2 - fl_0;
    int2 _S40 = int2(fl_0);
    int2 _S41 = int2(int(0)) ;

#line 38
    uint2 _S42 = uint2(clamp(_S40, _S41, mx_0));

#line 38
    uint2 _S43 = uint2(clamp(_S40 + _S39, _S41, mx_0));

#line 38
    float4 _S44 = texelPremul_0(_S37, _S42, kernelContext_4);

#line 38
    float4 _S45 = texelPremul_0(_S37, uint2(_S43.x, _S42.y), kernelContext_4);

#line 38
    float4 _S46 = texelPremul_0(_S37, uint2(_S42.x, _S43.y), kernelContext_4);

#line 38
    float4 _S47 = texelPremul_0(_S37, _S43, kernelContext_4);


    float4 _S48 = float4(f_0.x) ;

#line 41
    return mix(mix(_S44, _S45, _S48), mix(_S46, _S47, _S48), float4(f_0.y) );
}


#line 41
float3 sourceEncoded_0(texture2d<float, access::sample> _S49, texture2d<float, access::sample> _S50, float2 _S51, KernelContext_0 thread* kernelContext_5)
{

#line 10
    if((kernelContext_5->cu_0->mode_0) == 1U)
    {

#line 10
        return ((_S49).sample((kernelContext_5->edgeSampler_0), (_S51), level((0.0f)))).xyz;
    }
    float2 c_3 = ((_S50).sample((kernelContext_5->edgeSampler_0), (_S51), level((0.0f)))).xy * float2(kernelContext_5->cu_0->range_0.z)  + float2(kernelContext_5->cu_0->range_0.w) ;

#line 12
    float3 _S52 = ycbcrToRGB_0(float3(((_S49).sample((kernelContext_5->edgeSampler_0), (_S51), level((0.0f)))).x * kernelContext_5->cu_0->range_0.x + kernelContext_5->cu_0->range_0.y, c_3.x, c_3.y), kernelContext_5);
    return _S52;
}


#line 13
float4 convertPoint_0(texture2d<float, access::sample> _S53, texture2d<float, access::sample> _S54, float2 _S55, KernelContext_0 thread* kernelContext_6)
{

#line 62
    if((kernelContext_6->cu_0->mode_0) == 1U)
    {

#line 63
        float4 c_4 = ((_S53).sample((kernelContext_6->edgeSampler_0), (_S55), level((0.0f))));
        float _S56 = c_4.w;

#line 64
        float3 _S57;

#line 64
        if(_S56 > 0.0f)
        {

#line 64
            _S57 = c_4.xyz / float3(_S56) ;

#line 64
        }
        else
        {

#line 64
            _S57 = float3(0.0f) ;

#line 64
        }

#line 64
        return float4(_S57, _S56);
    }

#line 64
    float3 _S58 = sourceEncoded_0(_S53, _S54, _S55, kernelContext_6);

    return float4(_S58, 1.0f);
}


#line 66
float4 straightPoint_0(texture2d<float, access::sample> _S59, texture2d<float, access::sample> _S60, float2 _S61, KernelContext_0 thread* kernelContext_7)
{

#line 66
    bool _S62 = alphaSource_0(kernelContext_7);



    if(_S62)
    {

#line 70
        float4 _S63 = samplePremul_0(_S59, _S61, kernelContext_7);

        float _S64 = _S63.w;

#line 72
        float3 _S65;

#line 72
        if(_S64 > 0.0f)
        {

#line 72
            _S65 = _S63.xyz / float3(_S64) ;

#line 72
        }
        else
        {

#line 72
            _S65 = float3(0.0f) ;

#line 72
        }

#line 72
        return float4(_S65, _S64);
    }

#line 72
    float4 _S66 = convertPoint_0(_S59, _S60, _S61, kernelContext_7);

    return _S66;
}


#line 74
float4 convertTexel_0(texture2d<float, access::sample> _S67, texture2d<float, access::sample> _S68, uint _S69, uint2 _S70, uint2 _S71, KernelContext_0 thread* kernelContext_8)
{

#line 74
    float2 _S72 = float2(0.5f) ;

#line 87
    float2 uv_0 = (float2(_S70) + _S72) / float2(_S71);
    uint2 ts_0 = texSize_0(_S67);
    if((_S71.x) < (ts_0.x))
    {

#line 90
        float2 _S73 = _S72 / float2(ts_0);
        float3 _S74 = float3(0.0f) ;

#line 91
        int k_2 = int(0);

#line 91
        float3 acc_0 = _S74;

#line 91
        float a_2 = 0.0f;

        for(;;)
        {

#line 93
            if(k_2 < int(4))
            {
            }
            else
            {

#line 93
                break;
            }

#line 93
            float _S75;
            if((k_2 & int(1)) != int(0))
            {

#line 94
                _S75 = _S73.x;

#line 94
            }
            else
            {

#line 94
                _S75 = - _S73.x;

#line 94
            }

#line 94
            float _S76;

#line 94
            if((k_2 & int(2)) != int(0))
            {

#line 94
                _S76 = _S73.y;

#line 94
            }
            else
            {

#line 94
                _S76 = - _S73.y;

#line 94
            }

#line 94
            float4 _S77 = straightPoint_0(_S67, _S68, uv_0 + float2(_S75, _S76), kernelContext_8);

            float _S78 = _S77.w;

#line 96
            float3 acc_1 = acc_0 + decodeCurve_0(_S77.xyz, _S69) * float3(_S78) ;
            float a_3 = a_2 + _S78;

#line 93
            k_2 = k_2 + int(1);

#line 93
            acc_0 = acc_1;

#line 93
            a_2 = a_3;

#line 93
        }

#line 93
        float3 m_1;

#line 99
        if(a_2 > 0.0f)
        {

#line 99
            m_1 = acc_0 / float3(a_2) ;

#line 99
        }
        else
        {

#line 99
            m_1 = _S74;

#line 99
        }
        return float4(encodeCurve_0(m_1, _S69), a_2 * 0.25f);
    }

#line 100
    float4 _S79 = straightPoint_0(_S67, _S68, uv_0, kernelContext_8);

    return _S79;
}


#line 102
float4 trailTexel_0(uint _S80, uint2 _S81, uint2 _S82, KernelContext_0 thread* kernelContext_9)
{

#line 17 "crates/sq-gpu/shaders-src/TemporalTrails.slang"
    switch(_S80)
    {
    case 0U:
        {

#line 17
            float4 _S83 = convertTexel_0(kernelContext_9->in0_0, kernelContext_9->in9_0, 4294967295U, _S81, _S82, kernelContext_9);
            return _S83;
        }
    case 1U:
        {

#line 18
            float4 _S84 = convertTexel_0(kernelContext_9->in1_0, kernelContext_9->in10_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 18
            return _S84;
        }
    case 2U:
        {

#line 18
            float4 _S85 = convertTexel_0(kernelContext_9->in2_0, kernelContext_9->in11_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 18
            return _S85;
        }
    case 3U:
        {

#line 18
            float4 _S86 = convertTexel_0(kernelContext_9->in3_0, kernelContext_9->in12_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 18
            return _S86;
        }
    case 4U:
        {

#line 18
            float4 _S87 = convertTexel_0(kernelContext_9->in4_0, kernelContext_9->in13_0, 4294967295U, _S81, _S82, kernelContext_9);
            return _S87;
        }
    case 5U:
        {

#line 19
            float4 _S88 = convertTexel_0(kernelContext_9->in5_0, kernelContext_9->in14_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 19
            return _S88;
        }
    case 6U:
        {

#line 19
            float4 _S89 = convertTexel_0(kernelContext_9->in6_0, kernelContext_9->in15_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 19
            return _S89;
        }
    case 7U:
        {

#line 19
            float4 _S90 = convertTexel_0(kernelContext_9->in7_0, kernelContext_9->in16_0, 4294967295U, _S81, _S82, kernelContext_9);

#line 19
            return _S90;
        }
    default:
        {

#line 19
            float4 _S91 = convertTexel_0(kernelContext_9->in8_0, kernelContext_9->in17_0, 4294967295U, _S81, _S82, kernelContext_9);
            return _S91;
        }
    }

#line 20
}


#line 26
[[kernel]] void temporalTrails(uint3 tid_0 [[thread_position_in_grid]], CompositeU_0 constant* cu_1 [[buffer(0)]], TrailsU_0 constant* ru_1 [[buffer(1)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in18_1 [[texture(18)]], sampler edgeSampler_1 [[sampler(1)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in9_1 [[texture(9)]], texture2d<float, access::sample> in1_1 [[texture(1)]], texture2d<float, access::sample> in10_1 [[texture(10)]], texture2d<float, access::sample> in2_1 [[texture(2)]], texture2d<float, access::sample> in11_1 [[texture(11)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture2d<float, access::sample> in12_1 [[texture(12)]], texture2d<float, access::sample> in4_1 [[texture(4)]], texture2d<float, access::sample> in13_1 [[texture(13)]], texture2d<float, access::sample> in5_1 [[texture(5)]], texture2d<float, access::sample> in14_1 [[texture(14)]], texture2d<float, access::sample> in6_1 [[texture(6)]], texture2d<float, access::sample> in15_1 [[texture(15)]], texture2d<float, access::sample> in7_1 [[texture(7)]], texture2d<float, access::sample> in16_1 [[texture(16)]], texture2d<float, access::sample> in8_1 [[texture(8)]], texture2d<float, access::sample> in17_1 [[texture(17)]])
{

#line 26
    thread KernelContext_0 kernelContext_10;

#line 26
    (&kernelContext_10)->cu_0 = cu_1;

#line 26
    (&kernelContext_10)->ru_0 = ru_1;

#line 26
    (&kernelContext_10)->out0_0 = out0_1;

#line 26
    (&kernelContext_10)->in18_0 = in18_1;

#line 26
    (&kernelContext_10)->edgeSampler_0 = edgeSampler_1;

#line 26
    (&kernelContext_10)->in0_0 = in0_1;

#line 26
    (&kernelContext_10)->in9_0 = in9_1;

#line 26
    (&kernelContext_10)->in1_0 = in1_1;

#line 26
    (&kernelContext_10)->in10_0 = in10_1;

#line 26
    (&kernelContext_10)->in2_0 = in2_1;

#line 26
    (&kernelContext_10)->in11_0 = in11_1;

#line 26
    (&kernelContext_10)->in3_0 = in3_1;

#line 26
    (&kernelContext_10)->in12_0 = in12_1;

#line 26
    (&kernelContext_10)->in4_0 = in4_1;

#line 26
    (&kernelContext_10)->in13_0 = in13_1;

#line 26
    (&kernelContext_10)->in5_0 = in5_1;

#line 26
    (&kernelContext_10)->in14_0 = in14_1;

#line 26
    (&kernelContext_10)->in6_0 = in6_1;

#line 26
    (&kernelContext_10)->in15_0 = in15_1;

#line 26
    (&kernelContext_10)->in7_0 = in7_1;

#line 26
    (&kernelContext_10)->in16_0 = in16_1;

#line 26
    (&kernelContext_10)->in8_0 = in8_1;

#line 26
    (&kernelContext_10)->in17_0 = in17_1;

    TrailsU_0 t_3 = *ru_1;

#line 28
    uint2 _S92 = outSize_0(&kernelContext_10);

    uint2 gid_0 = tid_0.xy;

#line 30
    bool _S93;
    if((gid_0.x) >= (_S92.x))
    {

#line 31
        _S93 = true;

#line 31
    }
    else
    {

#line 31
        _S93 = (gid_0.y) >= (_S92.y);

#line 31
    }

#line 31
    if(_S93)
    {

#line 31
        return;
    }

#line 31
    float4 c0_0;
    if(((t_3.flags_0) & 1U) != 0U)
    {

#line 32
        int3 _S94 = int3(int2(gid_0), int(0));

#line 32
        c0_0 = (((&kernelContext_10)->in18_0).read(vec<uint,2>(((_S94)).xy), uint(((_S94)).z)));

#line 32
    }
    else
    {

#line 32
        float4 _S95 = convertTexel_0((&kernelContext_10)->in0_0, (&kernelContext_10)->in9_0, 4294967295U, gid_0, _S92, &kernelContext_10);

#line 32
        c0_0 = _S95;

#line 32
    }
    float _S96 = c0_0.w;

#line 33
    float3 p_3 = c0_0.xyz * float3(_S96) ;

    float3 _S97 = float3(0.0f) ;

#line 35
    float3 _S98 = float3(1.0f) ;

#line 35
    float3 _S99 = float3(1.0f) ;

#line 35
    float3 _S100 = _S99 - clamp(p_3, _S97, _S98);
    float _S101 = 1.0f - _S96;

#line 36
    float3 mx_1 = p_3;

#line 36
    uint k_3 = 1U;

#line 36
    float3 sumAdd_0 = p_3;

#line 36
    float3 prodScr_0 = _S100;

#line 36
    float aInv_0 = _S101;
    for(;;)
    {

#line 37
        if(k_3 <= (t_3.count_0))
        {
        }
        else
        {

#line 37
            break;
        }

#line 37
        float w_2;
        if(k_3 <= 4U)
        {

#line 38
            w_2 = t_3.w0_0[k_3 - 1U];

#line 38
        }
        else
        {

#line 38
            w_2 = t_3.w1_0[k_3 - 5U];

#line 38
        }

#line 38
        float4 _S102 = trailTexel_0(k_3, gid_0, _S92, &kernelContext_10);

        float ak_0 = clamp(_S102.w, 0.0f, 1.0f) * w_2;
        float3 pk_0 = _S102.xyz * float3(ak_0) ;
        float3 sumAdd_1 = sumAdd_0 + pk_0;
        float3 prodScr_1 = prodScr_0 * (_S99 - clamp(pk_0, _S97, _S98));
        float3 _S103 = max(mx_1, pk_0);
        float aInv_1 = aInv_0 * (1.0f - ak_0);

#line 37
        uint _S104 = k_3 + 1U;

#line 37
        mx_1 = _S103;

#line 37
        k_3 = _S104;

#line 37
        sumAdd_0 = sumAdd_1;

#line 37
        prodScr_0 = prodScr_1;

#line 37
        aInv_0 = aInv_1;

#line 37
    }

#line 47
    float alpha_0 = 1.0f - aInv_0;

#line 47
    float3 r_0;

    if((t_3.blend_1) == 0U)
    {

#line 49
        r_0 = min(sumAdd_0, max(p_3, float3(alpha_0) ));

#line 49
    }
    else
    {

#line 50
        if((t_3.blend_1) == 1U)
        {

#line 50
            r_0 = max(p_3, _S99 - prodScr_0);

#line 50
        }
        else
        {

#line 50
            r_0 = mx_1;

#line 50
        }

#line 49
    }

#line 49
    float3 res_0;


    if(alpha_0 > 9.9999997473787516e-06f)
    {

#line 52
        res_0 = r_0 / float3(alpha_0) ;

#line 52
    }
    else
    {

#line 52
        res_0 = _S97;

#line 52
    }
    if(((t_3.flags_0) & 2U) != 0U)
    {

#line 53
        res_0 = inverseOETF709_0(res_0);

#line 53
    }
    (&kernelContext_10)->out0_0.write(float4(res_0, alpha_0),gid_0);
    return;
}

