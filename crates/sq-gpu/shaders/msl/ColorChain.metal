#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 6 "crates/sq-gpu/shaders-src/Parts/ColorTypes.slang"
struct Sec_0
{
    uint4 head_0;
    float4 a_0;
    float4 b_0;
    float4 c_0;
    float4 d_0;
    float4 m0_0;
    float4 m1_0;
    float4 m2_0;
};


#line 14
struct ColorChainU_0
{
    uint4 ints_0;
    uint4 extra_0;
    array<Sec_0, int(24)> secs_0;
};


struct CurveRows_0
{
    array<float4, int(192)> rows_0;
};


#line 22
struct KernelContext_0
{
    ColorChainU_0 constant* cc_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in3_0;
    texture3d<float, access::sample> lut0_0;
    CurveRows_0 constant* curves_0;
};


#line 40 "crates/sq-gpu/shaders-src/Bindings.slang"
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
float hlgInverseOETF_0(float e_0)
{

#line 26
    float _S2 = max(e_0, 0.0f);
    if(_S2 <= 0.5f)
    {

#line 27
        return _S2 * _S2 / 3.0f;
    }

#line 28
    return (exp((_S2 - 0.55991071462631226f) / 0.1788327693939209f) + 0.28466892242431641f) / 12.0f;
}


#line 36
float hlgScale_0()
{

#line 37
    float e_1 = hlgInverseOETF_0(0.75f);
    return 1.0f / (e_1 * pow(e_1, 0.20000004768371582f));
}


#line 40
float3 hlgDecode3_0(float3 v_1)
{

#line 41
    float3 e_2 = float3(hlgInverseOETF_0(v_1.x), hlgInverseOETF_0(v_1.y), hlgInverseOETF_0(v_1.z));
    float ys_0 = dot(float3(0.26269999146461487f, 0.67799997329711914f, 0.059300001710653305f), e_2);

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
    return e_2 * float3(gain_0)  * float3(hlgScale_0()) ;
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
    float _S3;

#line 69
    if(x_1 < 0.1809999942779541f)
    {

#line 69
        _S3 = (x_1 - 0.125f) / 5.5999999046325684f;

#line 69
    }
    else
    {

#line 69
        _S3 = pow(10.0f, (x_1 - 0.59820598363876343f) / 0.24151399731636047f) - 0.0087299998849630356f;

#line 69
    }

#line 69
    return _S3;
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
float pqDecode_0(float e_3)
{

#line 126
    float p_1 = pow(max(e_3, 0.0f), 0.012683313339948654f);

    return pow(max(p_1 - 0.8359375f, 0.0f) / (18.8515625f - 18.6875f * p_1), 6.2773947715759277f) * 10000.0f / 203.0f;
}


#line 74
float dlogDecode_0(float x_2)
{

#line 74
    float _S4;

#line 74
    if(x_2 <= 0.14000000059604645f)
    {

#line 74
        _S4 = (x_2 - 0.092900000512599945f) / 6.0250000953674316f;

#line 74
    }
    else
    {

#line 74
        _S4 = (pow(10.0f, 3.8961598873138428f * x_2 - 2.2775199413299561f) - 0.01080000028014183f) / 0.98919999599456787f;

#line 74
    }

#line 74
    return _S4;
}


#line 76
float dlogDecodeLegal_0(float v_4)
{

#line 76
    return dlogDecode_0((v_4 * 876.0f + 64.0f) / 1023.0f);
}


float canonMirroredDecode_0(float x_3, float a_1, float k_0, float c_1)
{

#line 80
    float _S5;
    if(x_3 < c_1)
    {

#line 81
        _S5 = - (pow(10.0f, (c_1 - x_3) / a_1) - 1.0f) / k_0;

#line 81
    }
    else
    {

#line 81
        _S5 = (pow(10.0f, (x_3 - c_1) / a_1) - 1.0f) / k_0;

#line 81
    }

#line 81
    return _S5 * 0.89999997615814209f;
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
    float _S6 = max(s_0, 0.0f);
    if(_S6 <= 0.083333335816860199f)
    {

#line 32
        return sqrt(3.0f * _S6);
    }

#line 33
    return 0.1788327693939209f * log(12.0f * _S6 - 0.28466892242431641f) + 0.55991071462631226f;
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
    float3 e_4 = fd_0 / float3(pow(pow(yd_0, 0.83333331346511841f), 0.20000004768371582f)) ;
    return float3(hlgOETF_0(e_4.x), hlgOETF_0(e_4.y), hlgOETF_0(e_4.z));
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
    float _S7;

#line 70
    if(y_2 < 0.0099999997764825821f)
    {

#line 70
        _S7 = 5.5999999046325684f * y_2 + 0.125f;

#line 70
    }
    else
    {

#line 70
        _S7 = 0.24151399731636047f * log10(y_2 + 0.0087299998849630356f) + 0.59820598363876343f;

#line 70
    }

#line 70
    return _S7;
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
        float _S8 = x_5 - -0.056410878896713257f;

#line 118
        return 47.287113189697266f * _S8 * _S8;
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
    float _S9;

#line 75
    if(y_5 <= 0.007799999788403511f)
    {

#line 75
        _S9 = 6.0250000953674316f * y_5 + 0.092900000512599945f;

#line 75
    }
    else
    {

#line 75
        _S9 = log10(y_5 * 0.98919999599456787f + 0.01080000028014183f) * 0.2566629946231842f + 0.58455497026443481f;

#line 75
    }

#line 75
    return _S9;
}


#line 77
float dlogEncodeLegal_0(float y_6)
{

#line 77
    return (dlogEncode_0(y_6) * 1023.0f - 64.0f) / 876.0f;
}




float canonMirroredEncode_0(float y_7, float a_2, float k_1, float c_2)
{

#line 84
    float l_3 = y_7 / 0.89999997615814209f;

#line 84
    float _S10;
    if(l_3 < 0.0f)
    {

#line 85
        _S10 = - (a_2 * log10(- l_3 * k_1 + 1.0f) - c_2);

#line 85
    }
    else
    {

#line 85
        _S10 = a_2 * log10(l_3 * k_1 + 1.0f) + c_2;

#line 85
    }

#line 85
    return _S10;
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
    float _S11;

#line 139
    if(x_6 > 0.14965783059597015f)
    {

#line 139
        _S11 = (pow(10.0f, (x_6 - 0.38553699851036072f) / 0.24718999862670898f) - 0.052271999418735504f) / 5.5555558204650879f;

#line 139
    }
    else
    {

#line 139
        _S11 = (x_6 - 0.092808999121189117f) / 5.3676548004150391f;

#line 139
    }

#line 139
    return _S11;
}


float logC4Decode_0(float x_7)
{

#line 143
    float _S12;

#line 143
    if(x_7 >= 0.0f)
    {

#line 143
        _S12 = (pow(2.0f, 14.0f * (x_7 - 0.092864125967025757f) / 0.90713590383529663f + 6.0f) - 64.0f) / 2231.826416015625f;

#line 143
    }
    else
    {

#line 143
        _S12 = x_7 * 0.11359720677137375f + -0.018056996166706085f;

#line 143
    }

#line 143
    return _S12;
}


#line 145
float log3G10Decode_0(float y_12)
{

#line 145
    float _S13;

#line 145
    if(y_12 < 0.0f)
    {

#line 145
        _S13 = y_12 / 15.192700386047363f - 0.0099999997764825821f;

#line 145
    }
    else
    {

#line 145
        _S13 = (pow(10.0f, y_12 / 0.22428199648857117f) - 1.0f) / 155.97532653808594f - 0.0099999997764825821f;

#line 145
    }

#line 145
    return _S13;
}


#line 147
float bmdDecode_0(float y_13)
{

#line 147
    float _S14;

#line 147
    if(y_13 < 0.1338837742805481f)
    {

#line 147
        _S14 = (y_13 - 0.092465750873088837f) / 8.2836055755615234f;

#line 147
    }
    else
    {

#line 147
        _S14 = exp((y_13 - 0.5300133228302002f) / 0.086928762495517731f) - 0.0054940725676715374f;

#line 147
    }

#line 147
    return _S14;
}


#line 149
float nLogDecode_0(float x_8)
{

#line 150
    float cv_0 = x_8 * 1023.0f;
    if(cv_0 < (150.0f * log(0.32800000905990601f) + 619.0f))
    {

#line 151
        float t_0 = cv_0 / 650.0f;

#line 151
        return t_0 * t_0 * t_0 - 0.0074999998323619366f;
    }

#line 152
    return exp((cv_0 - 619.0f) / 150.0f);
}

float fLog2Decode_0(float x_9)
{

#line 155
    float _S15;

#line 155
    if(x_9 >= 0.1006866842508316f)
    {

#line 155
        _S15 = (pow(10.0f, (x_9 - 0.38431599736213684f) / 0.24528099596500397f) - 0.06482899934053421f) / 5.5555558204650879f;

#line 155
    }
    else
    {

#line 155
        _S15 = (x_9 - 0.092863999307155609f) / 8.7994613647460938f;

#line 155
    }

#line 155
    return _S15;
}


#line 157
float acesCCTDecode_0(float y_14)
{

#line 157
    float _S16;

#line 157
    if(y_14 <= 0.155251145362854f)
    {

#line 157
        _S16 = (y_14 - 0.072905533015727997f) / 10.540237426757812f;

#line 157
    }
    else
    {

#line 157
        _S16 = pow(2.0f, y_14 * 17.520000457763672f - 9.7200002670288086f);

#line 157
    }

#line 157
    return _S16;
}


#line 140
float logC3Encode_0(float y_15)
{

#line 140
    float _S17;

#line 140
    if(y_15 > 0.010591000318527222f)
    {

#line 140
        _S17 = 0.24718999862670898f * log10(5.5555558204650879f * y_15 + 0.052271999418735504f) + 0.38553699851036072f;

#line 140
    }
    else
    {

#line 140
        _S17 = 5.3676548004150391f * y_15 + 0.092808999121189117f;

#line 140
    }

#line 140
    return _S17;
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
    float _S18;

#line 144
    if(y_16 >= -0.018056996166706085f)
    {

#line 144
        _S18 = (log2(2231.826416015625f * y_16 + 64.0f) - 6.0f) / 14.0f * 0.90713590383529663f + 0.092864125967025757f;

#line 144
    }
    else
    {

#line 144
        _S18 = (y_16 - -0.018056996166706085f) / 0.11359720677137375f;

#line 144
    }

#line 144
    return _S18;
}


#line 146
float log3G10Encode_0(float x_11)
{

#line 146
    float s_1 = x_11 + 0.0099999997764825821f;

#line 146
    float _S19;

#line 146
    if(s_1 < 0.0f)
    {

#line 146
        _S19 = s_1 * 15.192700386047363f;

#line 146
    }
    else
    {

#line 146
        _S19 = 0.22428199648857117f * log10(s_1 * 155.97532653808594f + 1.0f);

#line 146
    }

#line 146
    return _S19;
}


#line 148
float bmdEncode_0(float x_12)
{

#line 148
    float _S20;

#line 148
    if(x_12 < 0.004999999888241291f)
    {

#line 148
        _S20 = 8.2836055755615234f * x_12 + 0.092465750873088837f;

#line 148
    }
    else
    {

#line 148
        _S20 = 0.086928762495517731f * log(x_12 + 0.0054940725676715374f) + 0.5300133228302002f;

#line 148
    }

#line 148
    return _S20;
}




float nLogEncode_0(float y_17)
{

#line 154
    float _S21;

#line 154
    if(y_17 < 0.32800000905990601f)
    {

#line 154
        _S21 = 650.0f * pow(max(y_17 + 0.0074999998323619366f, 0.0f), 0.3333333432674408f) / 1023.0f;

#line 154
    }
    else
    {

#line 154
        _S21 = (150.0f * log(y_17) + 619.0f) / 1023.0f;

#line 154
    }

#line 154
    return _S21;
}


#line 156
float fLog2Encode_0(float y_18)
{

#line 156
    float _S22;

#line 156
    if(y_18 >= 0.00088900001719594002f)
    {

#line 156
        _S22 = 0.24528099596500397f * log10(5.5555558204650879f * y_18 + 0.06482899934053421f) + 0.38431599736213684f;

#line 156
    }
    else
    {

#line 156
        _S22 = 8.7994613647460938f * y_18 + 0.092863999307155609f;

#line 156
    }

#line 156
    return _S22;
}


#line 158
float acesCCTEncode_0(float x_13)
{

#line 158
    float _S23;

#line 158
    if(x_13 <= 0.0078125f)
    {

#line 158
        _S23 = 10.540237426757812f * x_13 + 0.072905533015727997f;

#line 158
    }
    else
    {

#line 158
        _S23 = (log2(x_13) + 9.7200002670288086f) / 17.520000457763672f;

#line 158
    }

#line 158
    return _S23;
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


#line 437 "crates/sq-gpu/shaders-src/Parts/Color.slang"
float3 videoIn_0(float3 x_14, uint vr_0)
{

#line 437
    float3 _S24;

#line 437
    if((vr_0 & 1U) != 0U)
    {

#line 437
        _S24 = x_14 * float3(876.0f)  / float3(1023.0f)  + float3(0.062561094760894775f) ;

#line 437
    }
    else
    {

#line 437
        _S24 = x_14;

#line 437
    }

#line 437
    return _S24;
}


#line 470
float3 fetch1D_0(uint i_0, KernelContext_0 thread* kernelContext_1)
{

#line 471
    int3 _S25 = int3(int(i_0 & 4095U), int(i_0 >> 12U), int(0));

#line 471
    return ((kernelContext_1->in3_0).read(vec<uint,2>(((_S25)).xy), uint(((_S25)).z))).xyz;
}

float lut1DChannel_0(uint n_0, float p_2, int ch_0, KernelContext_0 thread* kernelContext_2)
{

#line 475
    uint _S26 = min(uint(p_2), n_0 - 2U);
    float f_0 = p_2 - float(_S26);

#line 476
    float3 _S27 = fetch1D_0(_S26, kernelContext_2);

#line 476
    float3 _S28 = fetch1D_0(_S26 + 1U, kernelContext_2);

    return _S27[ch_0] + (_S28[ch_0] - _S27[ch_0]) * f_0;
}


#line 438
float3 videoOut_0(float3 y_19, uint vr_1)
{

#line 438
    float3 _S29;

#line 438
    if((vr_1 & 2U) != 0U)
    {

#line 438
        _S29 = (y_19 - float3(0.062561094760894775f) ) * float3(1023.0f)  / float3(876.0f) ;

#line 438
    }
    else
    {

#line 438
        _S29 = y_19;

#line 438
    }

#line 438
    return _S29;
}


#line 481
float3 lookup1D_0(uint n_1, float3 dmin_0, float3 dmax_0, float3 rgb_0, uint vr_2, KernelContext_0 thread* kernelContext_3)
{
    float3 p_3 = clamp((videoIn_0(rgb_0, vr_2) - dmin_0) / (dmax_0 - dmin_0), float3(0.0f) , float3(1.0f) ) * float3(float(n_1 - 1U)) ;

#line 483
    float _S30 = lut1DChannel_0(n_1, p_3.x, int(0), kernelContext_3);

#line 483
    float _S31 = lut1DChannel_0(n_1, p_3.y, int(1), kernelContext_3);

#line 483
    float _S32 = lut1DChannel_0(n_1, p_3.z, int(2), kernelContext_3);

    return videoOut_0(float3(_S30, _S31, _S32), vr_2);
}


#line 14
float3 lut3Read_0(uint3 p_4, KernelContext_0 thread* kernelContext_4)
{

#line 14
    int4 _S33 = int4(int3(p_4), int(0));

#line 14
    return ((kernelContext_4->lut0_0).read(vec<uint,3>(((_S33)).xyz), uint(((_S33)).w))).xyz;
}


#line 440
float3 lookup3D_0(uint n_2, float3 dmin_1, float3 dmax_1, float3 rgb_1, uint vr_3, KernelContext_0 thread* kernelContext_5)
{
    float3 p_5 = clamp((videoIn_0(rgb_1, vr_3) - dmin_1) / (dmax_1 - dmin_1), float3(0.0f) , float3(1.0f) ) * float3(float(n_2 - 1U)) ;
    float _S34 = p_5.x;

#line 443
    uint _S35 = n_2 - 2U;

#line 443
    uint _S36 = min(uint(_S34), _S35);

#line 443
    float _S37 = p_5.y;

#line 443
    uint _S38 = min(uint(_S37), _S35);

#line 443
    float _S39 = p_5.z;

#line 443
    uint _S40 = min(uint(_S39), _S35);
    float fr_0 = _S34 - float(_S36);

#line 444
    float fg_0 = _S37 - float(_S38);

#line 444
    float fb_0 = _S39 - float(_S40);
    uint3 base_0 = uint3(_S36, _S38, _S40);
    if((vr_3 & 4U) != 0U)
    {

#line 446
        float3 _S41 = lut3Read_0(base_0, kernelContext_5);

#line 446
        float3 _S42 = lut3Read_0(base_0 + uint3(1U, 0U, 0U), kernelContext_5);
        float3 _S43 = float3(fr_0) ;

#line 447
        float3 x00_0 = mix(_S41, _S42, _S43);

#line 447
        float3 _S44 = lut3Read_0(base_0 + uint3(0U, 1U, 0U), kernelContext_5);

#line 447
        float3 _S45 = lut3Read_0(base_0 + uint3(1U, 1U, 0U), kernelContext_5);
        float3 x10_0 = mix(_S44, _S45, _S43);

#line 448
        float3 _S46 = lut3Read_0(base_0 + uint3(0U, 0U, 1U), kernelContext_5);

#line 448
        float3 _S47 = lut3Read_0(base_0 + uint3(1U, 0U, 1U), kernelContext_5);
        float3 x01_0 = mix(_S46, _S47, _S43);

#line 449
        float3 _S48 = lut3Read_0(base_0 + uint3(0U, 1U, 1U), kernelContext_5);

#line 449
        float3 _S49 = lut3Read_0(base_0 + uint3(1U, 1U, 1U), kernelContext_5);

        float3 _S50 = float3(fg_0) ;

#line 451
        return videoOut_0(mix(mix(x00_0, x10_0, _S50), mix(x01_0, mix(_S48, _S49, _S43), _S50), float3(fb_0) ), vr_3);
    }

#line 451
    float3 _S51 = lut3Read_0(base_0, kernelContext_5);

#line 451
    float3 _S52 = lut3Read_0(base_0 + uint3(1U, 1U, 1U), kernelContext_5);

#line 451
    uint3 o1_0;

#line 451
    uint3 o2_0;

#line 451
    float w0_0;

#line 451
    float w1_0;

#line 451
    float w2_0;

#line 457
    if(fr_0 >= fg_0)
    {

#line 458
        if(fg_0 >= fb_0)
        {

#line 458
            uint3 _S53 = uint3(1U, 1U, 0U);

#line 458
            o1_0 = uint3(1U, 0U, 0U);

#line 458
            o2_0 = _S53;

#line 458
            w0_0 = fr_0;

#line 458
            w1_0 = fg_0;

#line 458
            w2_0 = fb_0;

#line 458
        }
        else
        {

#line 459
            if(fr_0 >= fb_0)
            {

#line 459
                uint3 _S54 = uint3(1U, 0U, 1U);

#line 459
                o1_0 = uint3(1U, 0U, 0U);

#line 459
                o2_0 = _S54;

#line 459
                w0_0 = fr_0;

#line 459
                w1_0 = fb_0;

#line 459
            }
            else
            {

#line 460
                uint3 _S55 = uint3(1U, 0U, 1U);

#line 460
                o1_0 = uint3(0U, 0U, 1U);

#line 460
                o2_0 = _S55;

#line 460
                w0_0 = fb_0;

#line 460
                w1_0 = fr_0;

#line 459
            }

#line 459
            w2_0 = fg_0;

#line 458
        }

#line 457
    }
    else
    {


        if(fb_0 >= fg_0)
        {

#line 462
            uint3 _S56 = uint3(0U, 1U, 1U);

#line 462
            o1_0 = uint3(0U, 0U, 1U);

#line 462
            o2_0 = _S56;

#line 462
            w0_0 = fb_0;

#line 462
            w1_0 = fg_0;

#line 462
            w2_0 = fr_0;

#line 462
        }
        else
        {

#line 463
            if(fb_0 >= fr_0)
            {

#line 463
                uint3 _S57 = uint3(0U, 1U, 1U);

#line 463
                o1_0 = uint3(0U, 1U, 0U);

#line 463
                o2_0 = _S57;

#line 463
                w0_0 = fb_0;

#line 463
                w1_0 = fr_0;

#line 463
            }
            else
            {

#line 464
                uint3 _S58 = uint3(1U, 1U, 0U);

#line 464
                o1_0 = uint3(0U, 1U, 0U);

#line 464
                o2_0 = _S58;

#line 464
                w0_0 = fr_0;

#line 464
                w1_0 = fb_0;

#line 463
            }

#line 456
            float _S59 = w0_0;

#line 456
            float _S60 = w1_0;

#line 456
            w0_0 = fg_0;

#line 456
            w1_0 = _S59;

#line 456
            w2_0 = _S60;

#line 462
        }

#line 457
    }

#line 457
    float3 _S61 = lut3Read_0(base_0 + o1_0, kernelContext_5);

#line 457
    float3 _S62 = lut3Read_0(base_0 + o2_0, kernelContext_5);

#line 467
    return videoOut_0(_S51 + float3(w0_0)  * (_S61 - _S51) + float3(w1_0)  * (_S62 - _S61) + float3(w2_0)  * (_S52 - _S62), vr_3);
}


#line 490
float3 lookupLUT_0(uint flags_0, uint size_0, float4 dmin_2, float4 dmax_2, float3 x_15, KernelContext_0 thread* kernelContext_6)
{

#line 491
    uint _S63 = (flags_0 >> 2U) & 3U;

#line 491
    uint _S64;

#line 491
    if((flags_0 & 16U) != 0U)
    {

#line 491
        _S64 = 4U;

#line 491
    }
    else
    {

#line 491
        _S64 = 0U;

#line 491
    }

#line 491
    uint vr_4 = _S63 | _S64;

#line 491
    float3 _S65;
    if((flags_0 & 2U) != 0U)
    {

#line 492
        float3 _S66 = lookup1D_0(size_0, dmin_2.xyz, dmax_2.xyz, x_15, vr_4, kernelContext_6);

#line 492
        _S65 = _S66;

#line 492
    }
    else
    {

#line 492
        float3 _S67 = lookup3D_0(size_0, dmin_2.xyz, dmax_2.xyz, x_15, vr_4, kernelContext_6);

#line 492
        _S65 = _S67;

#line 492
    }

#line 492
    return _S65;
}


#line 12
float3 mulM_0(const Sec_0 constant* s_2, float3 v_11)
{

#line 12
    return s_2->m0_0.xyz * float3(v_11.x)  + s_2->m1_0.xyz * float3(v_11.y)  + s_2->m2_0.xyz * float3(v_11.z) ;
}


#line 414
float gamutChannel_0(float v_12, float m_0)
{

#line 415
    if(v_12 >= m_0)
    {

#line 415
        return v_12;
    }

#line 416
    float d_1 = (m_0 - v_12) / m_0;

#line 416
    float d_2;
    if(d_1 > 0.89999997615814209f)
    {

#line 418
        float x_16 = (d_1 - 0.89999997615814209f) / 0.10000000149011612f;

#line 418
        d_2 = 0.89999997615814209f + 0.10000000149011612f * (x_16 * (1.0f + x_16 / 36.0f) / (1.0f + x_16));

#line 417
    }
    else
    {

#line 417
        d_2 = d_1;

#line 417
    }

#line 422
    return m_0 - d_2 * m_0;
}


float3 hdrTrim_0(float3 rgb_2, float gain_1, float compress_0)
{

#line 427
    float _S68 = rgb_2.x;

#line 427
    float _S69 = rgb_2.y;

#line 427
    float _S70 = rgb_2.z;

#line 427
    float _S71 = max(_S68, max(_S69, _S70));

#line 427
    bool _S72;
    if(compress_0 > 0.5f)
    {

#line 428
        _S72 = _S71 > 0.0f;

#line 428
    }
    else
    {

#line 428
        _S72 = false;

#line 428
    }

#line 428
    float3 _S73;

#line 428
    if(_S72)
    {

#line 428
        _S73 = float3(gamutChannel_0(_S68, _S71), gamutChannel_0(_S69, _S71), gamutChannel_0(_S70, _S71));

#line 428
    }
    else
    {

#line 428
        _S73 = rgb_2;

#line 428
    }


    return _S73 * float3(gain_1) ;
}


#line 396
float3 toneMap_0(float3 rgb_3, float knee_0, float peak_0)
{

#line 397
    float _S74 = max(rgb_3.x, max(rgb_3.y, rgb_3.z));
    if(_S74 <= knee_0)
    {

#line 398
        return rgb_3;
    }

#line 399
    float r_0 = 1.0f - knee_0;

#line 399
    float mapped_0;

    if(peak_0 > (knee_0 + 9.9999997473787516e-05f))
    {

#line 402
        if(_S74 >= peak_0)
        {

#line 402
            mapped_0 = 1.0f;

#line 402
        }
        else
        {

#line 404
            float w_1 = (peak_0 - knee_0) / r_0;
            float x_17 = (_S74 - knee_0) / r_0;

#line 405
            mapped_0 = knee_0 + r_0 * (x_17 * (1.0f + x_17 / (w_1 * w_1)) / (1.0f + x_17));

#line 402
        }

#line 401
    }
    else
    {

#line 401
        mapped_0 = knee_0 + r_0 * (1.0f - exp(- (_S74 - knee_0) / r_0));

#line 401
    }

#line 411
    return rgb_3 * float3((mapped_0 / _S74)) ;
}


#line 496
float3 conversionStage_0(float3 c_3, const Sec_0 constant* s_3, int src_0, uint flags_1, KernelContext_0 thread* kernelContext_7)
{

#line 497
    if((flags_1 & 1U) != 0U)
    {

#line 497
        float3 _S75 = lookupLUT_0(flags_1, s_3->head_0.w, s_3->a_0, s_3->b_0, map3_0(c_3, src_0 + int(10)), kernelContext_7);

        return _S75;
    }

#line 499
    float3 d_3;

    if(src_0 == int(2))
    {

#line 501
        d_3 = c_3;

#line 501
    }
    else
    {

#line 501
        float3 _S76 = mulM_0(s_3, c_3);

#line 501
        d_3 = _S76;

#line 501
    }

#line 501
    bool _S77;
    if(src_0 != int(2))
    {

#line 502
        _S77 = (s_3->c_0.w) > -0.5f;

#line 502
    }
    else
    {

#line 502
        _S77 = false;

#line 502
    }

#line 502
    if(_S77)
    {

#line 502
        d_3 = toneMap_0(hdrTrim_0(d_3, s_3->c_0.z, s_3->c_0.w), s_3->c_0.x, s_3->c_0.y);

#line 502
    }
    return map3_0(max(d_3, float3(0.0f) ), int(12));
}


#line 43
float lumExposure_0(float l_5, float g_0, float knee_1)
{

#line 44
    float m_1 = l_5 * g_0;
    if(m_1 <= knee_1)
    {

#line 45
        return m_1;
    }

#line 46
    float _S78 = 1.0f - knee_1;

#line 46
    float a_3 = (g_0 - 1.0f) / _S78;
    float u_0 = (m_1 - knee_1) / (g_0 - knee_1);
    if(u_0 <= 1.0f)
    {

#line 48
        return knee_1 + _S78 * u_0 * (1.0f + a_3) / (1.0f + a_3 * u_0);
    }

#line 49
    return 1.0f + (m_1 - g_0);
}


#line 51
float lumBias_0(float u_1, float k_2)
{

#line 51
    return u_1 / (k_2 * (1.0f - u_1) + 1.0f);
}


#line 52
float lumContrast_0(float x_18, float k_3, float p_6)
{

#line 53
    if(x_18 < 0.0f)
    {

#line 53
        return x_18 / (1.0f + k_3);
    }

#line 54
    if(x_18 > 1.0f)
    {

#line 54
        return 1.0f + (x_18 - 1.0f) / (1.0f + k_3);
    }

#line 55
    if(x_18 <= p_6)
    {

#line 55
        return p_6 * lumBias_0(x_18 / p_6, k_3);
    }

#line 56
    float _S79 = 1.0f - p_6;

#line 56
    return 1.0f - _S79 * lumBias_0((1.0f - x_18) / _S79, k_3);
}


#line 58
float lumTone_0(float x_19, const Sec_0 constant* s_4, uint f_1)
{

#line 58
    float t_1;

    if((f_1 & 4U) != 0U)
    {

#line 60
        t_1 = lumContrast_0(x_19, s_4->a_0.y, s_4->d_0.x);

#line 60
    }
    else
    {

#line 60
        t_1 = x_19;

#line 60
    }

#line 60
    bool _S80;
    if((f_1 & 64U) != 0U)
    {

#line 61
        _S80 = t_1 > 0.0f;

#line 61
    }
    else
    {

#line 61
        _S80 = false;

#line 61
    }

#line 61
    if(_S80)
    {

#line 61
        _S80 = t_1 < 1.0f;

#line 61
    }
    else
    {

#line 61
        _S80 = false;

#line 61
    }

#line 61
    if(_S80)
    {

#line 61
        t_1 = t_1 + s_4->a_0.z * 6.75f * t_1 * t_1 * (1.0f - t_1);

#line 61
    }
    if((f_1 & 8U) != 0U)
    {

#line 62
        _S80 = t_1 > 0.0f;

#line 62
    }
    else
    {

#line 62
        _S80 = false;

#line 62
    }

#line 62
    if(_S80)
    {

#line 62
        _S80 = t_1 < 1.0f;

#line 62
    }
    else
    {

#line 62
        _S80 = false;

#line 62
    }

#line 62
    if(_S80)
    {

#line 62
        float _S81 = 1.0f - t_1;

#line 62
        t_1 = t_1 + s_4->a_0.w * 6.75f * t_1 * _S81 * _S81;

#line 62
    }
    if((f_1 & 16U) != 0U)
    {

#line 64
        float t_2 = t_1 * s_4->b_0.y;
        float d_4 = s_4->b_0.x;
        if(t_2 < 0.0f)
        {

#line 66
            t_1 = d_4 + t_2 * (1.0f - 2.0f * d_4);

#line 66
        }
        else
        {

#line 67
            if(t_2 < 1.0f)
            {

#line 67
                float _S82 = 1.0f - t_2;

#line 67
                t_1 = t_2 + d_4 * _S82 * _S82;

#line 67
            }
            else
            {

#line 67
                t_1 = t_2;

#line 67
            }

#line 66
        }

#line 63
    }

#line 69
    return t_1;
}


#line 18
float smoothS_0(float a_4, float b_1, float x_20)
{

#line 19
    float t_3 = clamp((x_20 - a_4) / (b_1 - a_4), 0.0f, 1.0f);
    return t_3 * t_3 * (3.0f - 2.0f * t_3);
}

float skinWeight_0(float3 t_4)
{

#line 24
    float _S83 = t_4.x;

#line 24
    float _S84 = t_4.y;

#line 24
    bool _S85;

#line 24
    if(_S83 >= _S84)
    {

#line 24
        _S85 = _S84 >= (t_4.z);

#line 24
    }
    else
    {

#line 24
        _S85 = false;

#line 24
    }

#line 24
    if(_S85)
    {

#line 24
        _S85 = _S83 > (t_4.z);

#line 24
    }
    else
    {

#line 24
        _S85 = false;

#line 24
    }

#line 24
    if(!_S85)
    {

#line 24
        return 0.0f;
    }

#line 25
    float _S86 = t_4.z;

#line 25
    float f_2 = (_S84 - _S86) / (_S83 - _S86);
    return smoothS_0(0.10000000149011612f, 0.30000001192092896f, f_2) * (1.0f - smoothS_0(0.69999998807907104f, 0.94999998807907104f, f_2));
}

float3 satVib_0(float3 t_5, float sat_0, float vib_0, float3 luma_0)
{

#line 29
    float s_5;

    if(vib_0 != 0.0f)
    {

#line 32
        float _S87 = t_5.x;

#line 32
        float _S88 = t_5.y;

#line 32
        float _S89 = t_5.z;

#line 32
        float _S90 = max(_S87, max(_S88, _S89));

#line 32
        float _S91 = min(_S87, min(_S88, _S89));

#line 32
        float sv_0;
        if(_S90 > 9.9999997473787516e-05f)
        {

#line 33
            sv_0 = clamp((_S90 - _S91) / _S90, 0.0f, 1.0f);

#line 33
        }
        else
        {

#line 33
            sv_0 = 0.0f;

#line 33
        }
        if(vib_0 > 0.0f)
        {

#line 34
            s_5 = sat_0 * (1.0f + vib_0 * (1.0f - sv_0) * (1.0f - 0.5f * skinWeight_0(t_5)));

#line 34
        }
        else
        {

#line 34
            s_5 = sat_0 * (1.0f + vib_0 * (0.30000001192092896f + 0.69999998807907104f * sv_0));

#line 34
        }

#line 31
    }
    else
    {

#line 31
        s_5 = sat_0;

#line 31
    }

#line 37
    if(s_5 == 1.0f)
    {

#line 37
        return t_5;
    }
    float3 _S92 = float3(dot(luma_0, t_5)) ;

#line 39
    return _S92 + (t_5 - _S92) * float3(s_5) ;
}


#line 76
float3 basicStageF_0(float3 c_4, const Sec_0 constant* s_6, bool pre_0, uint f_3, bool lum_0)
{

#line 76
    float3 x_21;

#line 76
    bool _S93;

    if((f_3 & 3U) != 0U)
    {

#line 79
        if(pre_0)
        {

#line 79
            x_21 = c_4;

#line 79
        }
        else
        {

#line 79
            x_21 = map3_0(c_4, int(2));

#line 79
        }
        if((f_3 & 1U) != 0U)
        {

#line 80
            float3 _S94 = mulM_0(s_6, x_21);

#line 80
            x_21 = _S94;

#line 80
        }
        if((f_3 & 2U) != 0U)
        {

#line 82
            if(lum_0)
            {

#line 82
                _S93 = (s_6->c_0.w) > 0.5f;

#line 82
            }
            else
            {

#line 82
                _S93 = false;

#line 82
            }

#line 82
            if(_S93)
            {

#line 83
                float _S95 = s_6->a_0.x;

#line 83
                float _S96 = s_6->d_0.y;

#line 83
                x_21 = float3(lumExposure_0(x_21.x, _S95, _S96), lumExposure_0(x_21.y, _S95, _S96), lumExposure_0(x_21.z, _S95, _S96));

#line 82
            }
            else
            {

#line 82
                x_21 = x_21 * float3(s_6->a_0.x) ;

#line 82
            }

#line 81
        }

#line 88
        if(pre_0)
        {
        }
        else
        {

#line 88
            x_21 = map3_0(x_21, int(12));

#line 88
        }

#line 78
    }
    else
    {

#line 78
        x_21 = c_4;

#line 78
    }

#line 90
    bool _S97 = (f_3 & 124U) != 0U;

#line 90
    if(_S97)
    {

#line 90
        _S93 = lum_0;

#line 90
    }
    else
    {

#line 90
        _S93 = false;

#line 90
    }

#line 90
    float3 t_6;

#line 90
    if(_S93)
    {

#line 91
        if(pre_0)
        {

#line 91
            t_6 = map3_0(x_21, int(12));

#line 91
        }
        else
        {

#line 91
            t_6 = x_21;

#line 91
        }

#line 91
        float _S98 = lumTone_0(t_6.x, s_6, f_3);

#line 91
        float _S99 = lumTone_0(t_6.y, s_6, f_3);

#line 91
        float _S100 = lumTone_0(t_6.z, s_6, f_3);

        float3 t_7 = satVib_0(float3(_S98, _S99, _S100), s_6->b_0.z, s_6->b_0.w, s_6->c_0.xyz);
        if(pre_0)
        {

#line 94
            x_21 = map3_0(t_7, int(2));

#line 94
        }
        else
        {

#line 94
            x_21 = t_7;

#line 94
        }

#line 90
    }
    else
    {


        if(_S97)
        {

#line 96
            if(pre_0)
            {

#line 96
                t_6 = map3_0(x_21, int(12));

#line 96
            }
            else
            {

#line 96
                t_6 = x_21;

#line 96
            }
            if((f_3 & 4U) != 0U)
            {

#line 97
                float3 _S101 = float3(0.44999998807907104f) ;

#line 97
                t_6 = _S101 + (t_6 - _S101) * float3(s_6->a_0.y) ;

#line 97
            }
            if((f_3 & 8U) != 0U)
            {

#line 98
                t_6 = t_6 * float3((1.0f + s_6->a_0.w * (1.0f - smoothS_0(0.0f, 0.60000002384185791f, dot(s_6->c_0.xyz, t_6))))) ;

#line 98
            }



            if((f_3 & 64U) != 0U)
            {

#line 102
                t_6 = t_6 + float3((s_6->a_0.z * smoothS_0(0.30000001192092896f, 1.0f, dot(s_6->c_0.xyz, t_6)))) ;

#line 102
            }



            if((f_3 & 16U) != 0U)
            {

#line 106
                float _S102 = s_6->b_0.x;

#line 106
                t_6 = (t_6 - float3(_S102) ) / float3((s_6->b_0.y - _S102)) ;

#line 106
            }
            float3 t_8 = satVib_0(t_6, s_6->b_0.z, s_6->b_0.w, s_6->c_0.xyz);
            if(pre_0)
            {

#line 108
                x_21 = map3_0(t_8, int(2));

#line 108
            }
            else
            {

#line 108
                x_21 = t_8;

#line 108
            }

#line 95
        }

#line 90
    }

#line 110
    return x_21;
}


#line 112
float3 basicStage_0(float3 c_5, const Sec_0 constant* s_7, bool pre_1)
{

#line 112
    float3 _S103 = basicStageF_0(c_5, s_7, pre_1, s_7->head_0.z, (s_7->head_0.w) == 1U);

#line 112
    return _S103;
}


#line 114
float3 creativeStageF_0(float3 c_6, const Sec_0 constant* s_8, bool pre_2, bool tint_0)
{

#line 114
    float3 t_9;
    if(pre_2)
    {

#line 115
        t_9 = map3_0(c_6, int(12));

#line 115
    }
    else
    {

#line 115
        t_9 = c_6;

#line 115
    }

#line 115
    float4 _S104 = s_8->a_0;
    float fade_0 = s_8->a_0.x;
    if(fade_0 != 0.0f)
    {

#line 117
        t_9 = t_9 * float3((1.0f - fade_0))  + float3((fade_0 * 0.85000002384185791f)) ;

#line 117
    }
    if(tint_0)
    {
        float y_20 = dot(s_8->d_0.xyz, t_9);
        float _S105 = 0.25f * _S104.w;

#line 121
        t_9 = t_9 + (float3((1.0f - smoothS_0(0.15000000596046448f + _S105, 0.64999997615814209f + _S105, y_20)))  * s_8->b_0.xyz + float3(smoothS_0(0.34999999403953552f + _S105, 0.85000002384185791f + _S105, y_20))  * s_8->c_0.xyz);

#line 118
    }

#line 125
    float3 t_10 = satVib_0(t_9, _S104.y, _S104.z, s_8->d_0.xyz);
    if(pre_2)
    {

#line 126
        t_9 = map3_0(t_10, int(2));

#line 126
    }
    else
    {

#line 126
        t_9 = t_10;

#line 126
    }

#line 126
    return t_9;
}


#line 128
float3 creativeStage_0(float3 c_7, const Sec_0 constant* s_9, bool pre_3)
{

#line 128
    float3 _S106 = creativeStageF_0(c_7, s_9, pre_3, ((s_9->head_0.z) & 1U) != 0U);

#line 128
    return _S106;
}


#line 506
float3 lookStage_0(float3 c_8, const Sec_0 constant* s_10, bool pre_4, uint flags_2, KernelContext_0 thread* kernelContext_8)
{

#line 506
    float3 t_11;
    if(pre_4)
    {

#line 507
        t_11 = map3_0(c_8, int(12));

#line 507
    }
    else
    {

#line 507
        t_11 = c_8;

#line 507
    }

#line 507
    float3 _S107 = lookupLUT_0(flags_2, s_10->head_0.w, s_10->a_0, s_10->b_0, t_11, kernelContext_8);

    float k_4 = s_10->c_0.x;
    if(k_4 >= 1.0f)
    {

#line 510
        t_11 = _S107;

#line 510
    }
    else
    {

#line 510
        t_11 = t_11 + (_S107 - t_11) * float3(k_4) ;

#line 510
    }
    if(pre_4)
    {

#line 511
        t_11 = map3_0(t_11, int(2));

#line 511
    }

#line 511
    return t_11;
}


#line 13
float4 curveRow_0(uint i_1, KernelContext_0 thread* kernelContext_9)
{

#line 13
    return kernelContext_9->curves_0->rows_0[i_1];
}


#line 155
float curveChannel_0(uint base_1, float v_13, int ch_1, KernelContext_0 thread* kernelContext_10)
{

#line 156
    float x_22 = clamp(v_13, 0.0f, 1.0f);
    float p_7 = x_22 * 63.0f;
    uint _S108 = min(uint(p_7), 62U);
    float f_4 = p_7 - float(_S108);
    uint _S109 = base_1 + _S108;

#line 160
    float4 _S110 = curveRow_0(_S109, kernelContext_10);

#line 160
    float4 _S111 = curveRow_0(_S109 + 1U, kernelContext_10);
    return _S110[ch_1] + (_S111[ch_1] - _S110[ch_1]) * f_4 + (v_13 - x_22);
}

float3 curvesStage_0(float3 c_9, const Sec_0 constant* s_11, bool pre_5, KernelContext_0 thread* kernelContext_11)
{

#line 164
    float3 t_12;
    if(pre_5)
    {

#line 165
        t_12 = map3_0(c_9, int(12));

#line 165
    }
    else
    {

#line 165
        t_12 = c_9;

#line 165
    }
    uint base_2 = s_11->head_0.w * 64U;

#line 166
    float _S112 = curveChannel_0(base_2, t_12.x, int(0), kernelContext_11);

#line 166
    float _S113 = curveChannel_0(base_2, t_12.y, int(1), kernelContext_11);

#line 166
    float _S114 = curveChannel_0(base_2, t_12.z, int(2), kernelContext_11);
    float3 o_0 = float3(_S112, _S113, _S114);
    if(pre_5)
    {

#line 168
        t_12 = map3_0(o_0, int(2));

#line 168
    }
    else
    {

#line 168
        t_12 = o_0;

#line 168
    }

#line 168
    return t_12;
}


#line 130
float3 wheelsStageF_0(float3 c_10, const Sec_0 constant* s_12, bool pre_6, bool gamma_0)
{

#line 130
    float3 t_13;
    if(pre_6)
    {

#line 131
        t_13 = map3_0(c_10, int(12));

#line 131
    }
    else
    {

#line 131
        t_13 = c_10;

#line 131
    }
    float3 _S115 = s_12->d_0.xyz;

#line 132
    float4 _S116 = s_12->a_0;

#line 132
    float3 t_14 = t_13 + float3((1.0f - smoothS_0(0.0f, 0.5f, dot(_S115, t_13))))  * s_12->a_0.xyz;
    if(gamma_0)
    {

#line 134
        float y_21 = dot(_S115, t_14);

#line 134
        t_13 = t_14 + (float3(pow(max(t_14.x, 0.0f), s_12->b_0.x), pow(max(t_14.y, 0.0f), s_12->b_0.y), pow(max(t_14.z, 0.0f), s_12->b_0.z)) - t_14) * float3((smoothS_0(0.0f, 0.5f, y_21) * (1.0f - smoothS_0(0.5f, 1.0f, y_21)))) ;

#line 133
    }
    else
    {

#line 133
        t_13 = t_14;

#line 133
    }

#line 140
    float3 t_15 = satVib_0(t_13 * (float3(1.0f)  + float3(smoothS_0(0.34999999403953552f, 1.1499999761581421f, dot(_S115, t_13)))  * s_12->c_0.xyz), _S116.w, 0.0f, _S115);
    if(pre_6)
    {

#line 141
        t_13 = map3_0(t_15, int(2));

#line 141
    }
    else
    {

#line 141
        t_13 = t_15;

#line 141
    }

#line 141
    return t_13;
}


#line 143
float3 wheelsStage_0(float3 c_11, const Sec_0 constant* s_13, bool pre_7)
{

#line 143
    float3 _S117 = wheelsStageF_0(c_11, s_13, pre_7, ((s_13->head_0.z) & 1U) != 0U);

#line 143
    return _S117;
}


#line 145
float3 vignetteStage_0(float3 c_12, const Sec_0 constant* s_14, bool pre_8, float2 uv_0, float aspect_0)
{

#line 146
    float px_0 = (uv_0.x - 0.5f) * 2.0f * (1.0f + (aspect_0 - 1.0f) * s_14->b_0.x);

#line 146
    float py_0 = (uv_0.y - 0.5f) * 2.0f;

#line 146
    float4 _S118 = s_14->a_0;
    float n_3 = s_14->a_0.w;

#line 147
    float e_5;
    if(n_3 > 2.0000998973846436f)
    {

#line 148
        e_5 = pow(pow(abs(px_0), n_3) + pow(abs(py_0), n_3), 1.0f / n_3);

#line 148
    }
    else
    {

#line 148
        e_5 = sqrt(px_0 * px_0 + py_0 * py_0);

#line 148
    }
    float _S119 = _S118.y;

#line 149
    float m_2 = smoothS_0(_S119, _S119 + _S118.z, e_5);

#line 149
    float3 _S120;
    if(pre_8)
    {

#line 150
        _S120 = c_12 * float3(exp2(_S118.x * m_2)) ;

#line 150
    }
    else
    {

#line 150
        _S120 = c_12 * float3(exp2(0.44999998807907104f * _S118.x * m_2)) ;

#line 150
    }

#line 150
    return _S120;
}


#line 172
float hueSample_0(uint base_3, int column_0, float h_1, KernelContext_0 thread* kernelContext_12)
{

#line 173
    float p_8 = h_1 * 64.0f;
    uint _S121 = min(uint(p_8), 63U);
    float f_5 = p_8 - float(_S121);

#line 175
    float4 _S122 = curveRow_0(base_3 + _S121, kernelContext_12);

#line 175
    float4 _S123 = curveRow_0(base_3 + (_S121 + 1U) % 64U, kernelContext_12);

    return _S122[column_0] + (_S123[column_0] - _S122[column_0]) * f_5;
}


#line 179
float linearSample_0(uint row0_0, int column_1, float x_23, KernelContext_0 thread* kernelContext_13)
{

#line 180
    float p_9 = clamp(x_23, 0.0f, 1.0f) * 63.0f;
    uint _S124 = min(uint(p_9), 62U);
    float f_6 = p_9 - float(_S124);
    uint _S125 = row0_0 + _S124;

#line 183
    float4 _S126 = curveRow_0(_S125, kernelContext_13);

#line 183
    float4 _S127 = curveRow_0(_S125 + 1U, kernelContext_13);
    return _S126[column_1] + (_S127[column_1] - _S126[column_1]) * f_6;
}


#line 186
float3 hueCurvesStage_0(float3 c_13, const Sec_0 constant* s_15, bool pre_9, KernelContext_0 thread* kernelContext_14)
{

#line 186
    float3 t_16;
    if(pre_9)
    {

#line 187
        t_16 = map3_0(c_13, int(12));

#line 187
    }
    else
    {

#line 187
        t_16 = c_13;

#line 187
    }
    uint base_4 = s_15->head_0.w * 64U;
    float _S128 = t_16.x;

#line 189
    float _S129 = t_16.y;

#line 189
    float _S130 = t_16.z;

#line 189
    float _S131 = max(_S128, max(_S129, _S130));
    float d_5 = _S131 - min(_S128, min(_S129, _S130));

#line 190
    float hue_0;

    if(d_5 > 9.99999997475242708e-07f)
    {
        if(_S131 == _S128)
        {

#line 194
            hue_0 = (_S129 - _S130) / d_5;

#line 194
        }
        else
        {

#line 194
            if(_S131 == _S129)
            {

#line 194
                hue_0 = (_S130 - _S128) / d_5 + 2.0f;

#line 194
            }
            else
            {

#line 194
                hue_0 = (_S128 - _S129) / d_5 + 4.0f;

#line 194
            }

#line 194
        }
        float h_2 = hue_0 / 6.0f;

#line 195
        hue_0 = h_2 - floor(h_2);

#line 192
    }
    else
    {

#line 192
        hue_0 = 0.0f;

#line 192
    }

#line 198
    float w_2 = smoothS_0(0.004999999888241291f, 0.05000000074505806f, d_5);

#line 198
    float sv_1;
    if(_S131 > 9.9999997473787516e-05f)
    {

#line 199
        sv_1 = clamp(d_5 / _S131, 0.0f, 1.0f);

#line 199
    }
    else
    {

#line 199
        sv_1 = 0.0f;

#line 199
    }
    float3 _S132 = s_15->d_0.xyz;

#line 200
    float y0_0 = dot(_S132, t_16);

#line 200
    float _S133 = hueSample_0(base_4, int(0), hue_0, kernelContext_14);

#line 200
    float _S134 = hueSample_0(base_4, int(1), hue_0, kernelContext_14);

#line 200
    float _S135 = hueSample_0(base_4, int(2), hue_0, kernelContext_14);

#line 200
    float _S136 = linearSample_0(base_4, int(3), y0_0, kernelContext_14);

#line 200
    float _S137 = linearSample_0(base_4 + 64U, int(0), sv_1, kernelContext_14);


    float theta_0 = (_S134 - 0.5f) * 2.0f * 1.0471975803375244f * w_2;
    if(theta_0 != 0.0f)
    {
        float3 _S138 = float3(((_S128 + _S129 + _S130) / 3.0f)) ;

#line 206
        float3 dv_0 = t_16 - _S138;
        float _S139 = dv_0.z;

#line 207
        float _S140 = dv_0.y;

#line 207
        float _S141 = dv_0.x;

#line 207
        t_16 = _S138 + dv_0 * float3(cos(theta_0))  + float3(_S139 - _S140, _S141 - _S139, _S140 - _S141) * float3(0.57735025882720947f)  * float3(sin(theta_0)) ;

#line 204
    }

#line 210
    float sat_1 = (1.0f + (2.0f * _S133 - 1.0f) * w_2) * (2.0f * _S136) * (2.0f * _S137);
    if(sat_1 != 1.0f)
    {
        float3 _S142 = float3(dot(_S132, t_16)) ;

#line 213
        t_16 = _S142 + (t_16 - _S142) * float3(max(sat_1, 0.0f)) ;

#line 211
    }



    float g_1 = exp2((_S135 - 0.5f) * 2.0f * w_2);
    if(g_1 != 1.0f)
    {

#line 216
        t_16 = t_16 * float3(g_1) ;

#line 216
    }
    if(pre_9)
    {

#line 217
        t_16 = map3_0(t_16, int(2));

#line 217
    }

#line 217
    return t_16;
}


float hslMask_0(float3 t_17, const Sec_0 constant* s_16)
{

#line 221
    float hue_1;

#line 221
    float sv_2;
    if((s_16->head_0.w) == 1U)
    {

#line 223
        float _S143 = t_17.x;

#line 223
        float _S144 = t_17.y;

#line 223
        float _S145 = t_17.z;

#line 223
        float _S146 = max(_S143, max(_S144, _S145));
        float d_6 = _S146 - min(_S143, min(_S144, _S145));
        if(_S146 > 9.9999997473787516e-05f)
        {

#line 225
            sv_2 = clamp(d_6 / _S146, 0.0f, 1.0f);

#line 225
        }
        else
        {

#line 225
            sv_2 = 0.0f;

#line 225
        }

        if(d_6 > 9.99999997475242708e-07f)
        {
            if(_S146 == _S143)
            {

#line 229
                hue_1 = (_S144 - _S145) / d_6;

#line 229
            }
            else
            {

#line 229
                if(_S146 == _S144)
                {

#line 229
                    hue_1 = (_S145 - _S143) / d_6 + 2.0f;

#line 229
                }
                else
                {

#line 229
                    hue_1 = (_S143 - _S144) / d_6 + 4.0f;

#line 229
                }

#line 229
            }
            float h_3 = hue_1 / 6.0f;

#line 230
            hue_1 = h_3 - floor(h_3);

#line 227
        }
        else
        {

#line 227
            hue_1 = 0.0f;

#line 227
        }

#line 233
        float ang_0 = hue_1 * 6.2831854820251465f;

        float _S147 = s_16->a_0.w;

#line 235
        float vm_0 = 1.0f - smoothS_0(_S147, _S147 + s_16->b_0.x, length(float3(sv_2 * cos(ang_0), sv_2 * sin(ang_0), dot(s_16->d_0.xyz, t_17)) - s_16->a_0.xyz));
        if((s_16->b_0.w) > 0.5f)
        {

#line 236
            hue_1 = 1.0f - vm_0;

#line 236
        }
        else
        {

#line 236
            hue_1 = vm_0;

#line 236
        }

#line 236
        return hue_1;
    }
    float _S148 = t_17.x;

#line 238
    float _S149 = t_17.y;

#line 238
    float _S150 = t_17.z;

#line 238
    float _S151 = max(_S148, max(_S149, _S150));
    float d_7 = _S151 - min(_S148, min(_S149, _S150));

#line 239
    float4 _S152 = s_16->a_0;

    if((s_16->a_0.w) < 0.5f)
    {
        if(d_7 > 9.99999997475242708e-07f)
        {
            if(_S151 == _S148)
            {

#line 245
                hue_1 = (_S149 - _S150) / d_7;

#line 245
            }
            else
            {

#line 245
                if(_S151 == _S149)
                {

#line 245
                    hue_1 = (_S150 - _S148) / d_7 + 2.0f;

#line 245
                }
                else
                {

#line 245
                    hue_1 = (_S148 - _S149) / d_7 + 4.0f;

#line 245
                }

#line 245
            }
            float h_4 = hue_1 / 6.0f;

#line 246
            hue_1 = h_4 - floor(h_4);

#line 243
        }
        else
        {

#line 243
            hue_1 = 0.0f;

#line 243
        }

#line 249
        float dh_0 = hue_1 - _S152.x;

        float _S153 = _S152.y;

#line 251
        hue_1 = (1.0f - smoothS_0(_S153, _S153 + _S152.z, abs(dh_0 - floor(dh_0 + 0.5f)))) * smoothS_0(0.004999999888241291f, 0.05000000074505806f, d_7);

#line 241
    }
    else
    {

#line 241
        hue_1 = 1.0f;

#line 241
    }

#line 253
    if(_S151 > 9.9999997473787516e-05f)
    {

#line 253
        sv_2 = clamp(d_7 / _S151, 0.0f, 1.0f);

#line 253
    }
    else
    {

#line 253
        sv_2 = 0.0f;

#line 253
    }

#line 253
    float4 _S154 = s_16->b_0;
    float _S155 = s_16->b_0.x;

#line 254
    float _S156 = s_16->b_0.z;

#line 254
    float _S157 = s_16->b_0.y;

#line 254
    float ws_0 = smoothS_0(_S155 - _S156, _S155, sv_2) * (1.0f - smoothS_0(_S157, _S157 + _S156, sv_2));
    float y_22 = dot(s_16->d_0.xyz, t_17);

#line 255
    float4 _S158 = s_16->c_0;
    float _S159 = s_16->c_0.x;

#line 256
    if(_S159 > 0.0f)
    {

#line 256
        sv_2 = smoothS_0(_S159 - _S158.z, _S159, y_22);

#line 256
    }
    else
    {

#line 256
        sv_2 = 1.0f;

#line 256
    }

#line 256
    float _S160 = _S158.y;

#line 256
    float _S161;

#line 256
    if(_S160 < 1.0f)
    {

#line 256
        _S161 = 1.0f - smoothS_0(_S160, _S160 + _S158.z, y_22);

#line 256
    }
    else
    {

#line 256
        _S161 = 1.0f;

#line 256
    }
    float m_3 = hue_1 * ws_0 * (sv_2 * _S161);
    if((_S154.w) > 0.5f)
    {

#line 258
        hue_1 = 1.0f - m_3;

#line 258
    }
    else
    {

#line 258
        hue_1 = m_3;

#line 258
    }

#line 258
    return hue_1;
}


#line 221
float hslMask_1(float3 t_18, const Sec_0 constant* s_17)
{

#line 221
    float hue_2;

#line 221
    float sv_3;
    if((s_17->head_0.w) == 1U)
    {

#line 223
        float _S162 = t_18.x;

#line 223
        float _S163 = t_18.y;

#line 223
        float _S164 = t_18.z;

#line 223
        float _S165 = max(_S162, max(_S163, _S164));
        float d_8 = _S165 - min(_S162, min(_S163, _S164));
        if(_S165 > 9.9999997473787516e-05f)
        {

#line 225
            sv_3 = clamp(d_8 / _S165, 0.0f, 1.0f);

#line 225
        }
        else
        {

#line 225
            sv_3 = 0.0f;

#line 225
        }

        if(d_8 > 9.99999997475242708e-07f)
        {
            if(_S165 == _S162)
            {

#line 229
                hue_2 = (_S163 - _S164) / d_8;

#line 229
            }
            else
            {

#line 229
                if(_S165 == _S163)
                {

#line 229
                    hue_2 = (_S164 - _S162) / d_8 + 2.0f;

#line 229
                }
                else
                {

#line 229
                    hue_2 = (_S162 - _S163) / d_8 + 4.0f;

#line 229
                }

#line 229
            }
            float h_5 = hue_2 / 6.0f;

#line 230
            hue_2 = h_5 - floor(h_5);

#line 227
        }
        else
        {

#line 227
            hue_2 = 0.0f;

#line 227
        }

#line 233
        float ang_1 = hue_2 * 6.2831854820251465f;

        float _S166 = s_17->a_0.w;

#line 235
        float vm_1 = 1.0f - smoothS_0(_S166, _S166 + s_17->b_0.x, length(float3(sv_3 * cos(ang_1), sv_3 * sin(ang_1), dot(s_17->d_0.xyz, t_18)) - s_17->a_0.xyz));
        if((s_17->b_0.w) > 0.5f)
        {

#line 236
            hue_2 = 1.0f - vm_1;

#line 236
        }
        else
        {

#line 236
            hue_2 = vm_1;

#line 236
        }

#line 236
        return hue_2;
    }
    float _S167 = t_18.x;

#line 238
    float _S168 = t_18.y;

#line 238
    float _S169 = t_18.z;

#line 238
    float _S170 = max(_S167, max(_S168, _S169));
    float d_9 = _S170 - min(_S167, min(_S168, _S169));

#line 239
    float4 _S171 = s_17->a_0;

    if((s_17->a_0.w) < 0.5f)
    {
        if(d_9 > 9.99999997475242708e-07f)
        {
            if(_S170 == _S167)
            {

#line 245
                hue_2 = (_S168 - _S169) / d_9;

#line 245
            }
            else
            {

#line 245
                if(_S170 == _S168)
                {

#line 245
                    hue_2 = (_S169 - _S167) / d_9 + 2.0f;

#line 245
                }
                else
                {

#line 245
                    hue_2 = (_S167 - _S168) / d_9 + 4.0f;

#line 245
                }

#line 245
            }
            float h_6 = hue_2 / 6.0f;

#line 246
            hue_2 = h_6 - floor(h_6);

#line 243
        }
        else
        {

#line 243
            hue_2 = 0.0f;

#line 243
        }

#line 249
        float dh_1 = hue_2 - _S171.x;

        float _S172 = _S171.y;

#line 251
        hue_2 = (1.0f - smoothS_0(_S172, _S172 + _S171.z, abs(dh_1 - floor(dh_1 + 0.5f)))) * smoothS_0(0.004999999888241291f, 0.05000000074505806f, d_9);

#line 241
    }
    else
    {

#line 241
        hue_2 = 1.0f;

#line 241
    }

#line 253
    if(_S170 > 9.9999997473787516e-05f)
    {

#line 253
        sv_3 = clamp(d_9 / _S170, 0.0f, 1.0f);

#line 253
    }
    else
    {

#line 253
        sv_3 = 0.0f;

#line 253
    }

#line 253
    float4 _S173 = s_17->b_0;
    float _S174 = s_17->b_0.x;

#line 254
    float _S175 = s_17->b_0.z;

#line 254
    float _S176 = s_17->b_0.y;

#line 254
    float ws_1 = smoothS_0(_S174 - _S175, _S174, sv_3) * (1.0f - smoothS_0(_S176, _S176 + _S175, sv_3));
    float y_23 = dot(s_17->d_0.xyz, t_18);

#line 255
    float4 _S177 = s_17->c_0;
    float _S178 = s_17->c_0.x;

#line 256
    if(_S178 > 0.0f)
    {

#line 256
        sv_3 = smoothS_0(_S178 - _S177.z, _S178, y_23);

#line 256
    }
    else
    {

#line 256
        sv_3 = 1.0f;

#line 256
    }

#line 256
    float _S179 = _S177.y;

#line 256
    float _S180;

#line 256
    if(_S179 < 1.0f)
    {

#line 256
        _S180 = 1.0f - smoothS_0(_S179, _S179 + _S177.z, y_23);

#line 256
    }
    else
    {

#line 256
        _S180 = 1.0f;

#line 256
    }
    float m_4 = hue_2 * ws_1 * (sv_3 * _S180);
    if((_S173.w) > 0.5f)
    {

#line 258
        hue_2 = 1.0f - m_4;

#line 258
    }
    else
    {

#line 258
        hue_2 = m_4;

#line 258
    }

#line 258
    return hue_2;
}


#line 260
float3 hslSecondaryStage_0(float3 c_14, const Sec_0 constant* s_18, bool pre_10)
{

#line 260
    float3 t_19;
    if(pre_10)
    {

#line 261
        t_19 = map3_0(c_14, int(12));

#line 261
    }
    else
    {

#line 261
        t_19 = c_14;

#line 261
    }

#line 261
    float _S181 = hslMask_0(t_19, s_18);

    if(!(_S181 > 0.0f))
    {

#line 263
        return c_14;
    }

#line 264
    float3 o_1 = t_19 * float3(s_18->m0_0.x, s_18->m1_0.y, s_18->m2_0.z);

#line 264
    float4 _S182 = s_18->d_0;
    float theta_1 = s_18->d_0.w;

#line 265
    float3 o_2;
    if(theta_1 != 0.0f)
    {
        float3 _S183 = float3(((o_1.x + o_1.y + o_1.z) / 3.0f)) ;

#line 268
        float3 dv_1 = o_1 - _S183;
        float _S184 = dv_1.z;

#line 269
        float _S185 = dv_1.y;

#line 269
        float _S186 = dv_1.x;

#line 269
        o_2 = _S183 + dv_1 * float3(cos(theta_1))  + float3(_S184 - _S185, _S186 - _S184, _S185 - _S186) * float3(0.57735025882720947f)  * float3(sin(theta_1)) ;

#line 266
    }
    else
    {

#line 266
        o_2 = o_1;

#line 266
    }

#line 272
    float _S187 = s_18->c_0.w;

#line 272
    if(_S187 != 1.0f)
    {
        float3 _S188 = float3(dot(_S182.xyz, o_2)) ;

#line 274
        o_2 = _S188 + (o_2 - _S188) * float3(_S187) ;

#line 272
    }



    float3 r_1 = t_19 + (o_2 - t_19) * float3(_S181) ;
    if(pre_10)
    {

#line 277
        t_19 = map3_0(r_1, int(2));

#line 277
    }
    else
    {

#line 277
        t_19 = r_1;

#line 277
    }

#line 277
    return t_19;
}


#line 307
float gammaChannel_0(float v_14, float e_6)
{

#line 307
    bool _S189;

#line 307
    if(v_14 > 0.0f)
    {

#line 307
        _S189 = e_6 != 1.0f;

#line 307
    }
    else
    {

#line 307
        _S189 = false;

#line 307
    }

#line 307
    float _S190;

#line 307
    if(_S189)
    {

#line 307
        _S190 = pow(v_14, e_6);

#line 307
    }
    else
    {

#line 307
        _S190 = v_14;

#line 307
    }

#line 307
    return _S190;
}

float3 primariesStage_0(float3 c_15, const Sec_0 constant* s_19, bool pre_11, uint flags_3)
{

#line 310
    float3 t_20;
    if(pre_11)
    {

#line 311
        t_20 = map3_0(c_15, int(12));

#line 311
    }
    else
    {

#line 311
        t_20 = c_15;

#line 311
    }

#line 311
    float4 _S191 = s_19->a_0;

#line 311
    float4 _S192 = s_19->c_0;

    float3 t_21 = (t_20 + s_19->a_0.xyz * (float3(1.0f)  - t_20)) * s_19->c_0.xyz + s_19->d_0.xyz;
    if((flags_3 & 1U) != 0U)
    {

#line 314
        t_20 = float3(gammaChannel_0(t_21.x, s_19->b_0.x), gammaChannel_0(t_21.y, s_19->b_0.y), gammaChannel_0(t_21.z, s_19->b_0.z));

#line 314
    }
    else
    {

#line 314
        t_20 = t_21;

#line 314
    }


    if((flags_3 & 2U) != 0U)
    {

#line 317
        float3 _S193 = float3(s_19->b_0.w) ;

#line 317
        t_20 = (t_20 - _S193) * float3(_S191.w)  + _S193;

#line 317
    }
    if((flags_3 & 4U) != 0U)
    {
        float3 _S194 = float3(dot(float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f), t_20)) ;

#line 320
        t_20 = _S194 + (t_20 - _S194) * float3(_S192.w) ;

#line 318
    }



    if(pre_11)
    {

#line 322
        t_20 = map3_0(t_20, int(2));

#line 322
    }

#line 322
    return t_20;
}


float stepWindowMask_0(const Sec_0 constant* s_20, float2 uv_1, float aspect_1)
{

#line 327
    float3 r0_0 = s_20->m0_0.xyz;

#line 327
    float3 r1_0 = s_20->m1_0.xyz;

#line 327
    float3 r2_0 = s_20->m2_0.xyz;
    float px_1 = (uv_1.x - r0_0.x) * aspect_1;

#line 328
    float py_1 = uv_1.y - r0_0.y;
    float _S195 = r1_0.y;

#line 329
    float _S196 = r1_0.z;

#line 329
    float qx_0 = px_1 * _S195 + py_1 * _S196;

#line 329
    float qy_0 = - px_1 * _S196 + py_1 * _S195;
    float _S197 = max(r0_0.z * aspect_1, 9.9999997473787516e-06f);

#line 330
    float _S198 = max(r1_0.x, 9.9999997473787516e-06f);
    float soft_0 = r2_0.x;

    float _S199 = r2_0.y;

#line 333
    float m_5;

#line 333
    if(_S199 < 0.5f)
    {

#line 334
        float ex_0 = qx_0 / _S197;

#line 334
        float ey_0 = qy_0 / _S198;

#line 334
        m_5 = 1.0f - smoothS_0(1.0f - soft_0, 1.0f, sqrt(ex_0 * ex_0 + ey_0 * ey_0));

#line 333
    }
    else
    {
        if(_S199 < 1.5f)
        {

#line 336
            m_5 = 1.0f - smoothS_0(1.0f - soft_0, 1.0f, max(abs(qx_0) / _S197, abs(qy_0) / _S198));

#line 336
        }
        else
        {
            float _S200 = max(soft_0 * _S198, 9.9999997473787516e-05f);

#line 339
            m_5 = 1.0f - smoothS_0(- _S200, _S200, qy_0);

#line 336
        }

#line 333
    }

#line 342
    if((r2_0.z) > 0.5f)
    {

#line 342
        m_5 = 1.0f - m_5;

#line 342
    }

#line 342
    return m_5;
}


#line 326
float stepWindowMask_1(const Sec_0 constant* s_21, float2 uv_2, float aspect_2)
{

#line 327
    float3 r0_1 = s_21->m0_0.xyz;

#line 327
    float3 r1_1 = s_21->m1_0.xyz;

#line 327
    float3 r2_1 = s_21->m2_0.xyz;
    float px_2 = (uv_2.x - r0_1.x) * aspect_2;

#line 328
    float py_2 = uv_2.y - r0_1.y;
    float _S201 = r1_1.y;

#line 329
    float _S202 = r1_1.z;

#line 329
    float qx_1 = px_2 * _S201 + py_2 * _S202;

#line 329
    float qy_1 = - px_2 * _S202 + py_2 * _S201;
    float _S203 = max(r0_1.z * aspect_2, 9.9999997473787516e-06f);

#line 330
    float _S204 = max(r1_1.x, 9.9999997473787516e-06f);
    float soft_1 = r2_1.x;

    float _S205 = r2_1.y;

#line 333
    float m_6;

#line 333
    if(_S205 < 0.5f)
    {

#line 334
        float ex_1 = qx_1 / _S203;

#line 334
        float ey_1 = qy_1 / _S204;

#line 334
        m_6 = 1.0f - smoothS_0(1.0f - soft_1, 1.0f, sqrt(ex_1 * ex_1 + ey_1 * ey_1));

#line 333
    }
    else
    {
        if(_S205 < 1.5f)
        {

#line 336
            m_6 = 1.0f - smoothS_0(1.0f - soft_1, 1.0f, max(abs(qx_1) / _S203, abs(qy_1) / _S204));

#line 336
        }
        else
        {
            float _S206 = max(soft_1 * _S204, 9.9999997473787516e-05f);

#line 339
            m_6 = 1.0f - smoothS_0(- _S206, _S206, qy_1);

#line 336
        }

#line 333
    }

#line 342
    if((r2_1.z) > 0.5f)
    {

#line 342
        m_6 = 1.0f - m_6;

#line 342
    }

#line 342
    return m_6;
}



float stepMatte_0(float3 n0_0, const Sec_0 constant* s_22, bool pre_12, uint flags_4, float2 uv_3, float aspect_3)
{

#line 347
    float m_7;

    if((flags_4 & 1U) != 0U)
    {

#line 349
        float3 _S207;

#line 349
        if(pre_12)
        {

#line 349
            _S207 = map3_0(n0_0, int(12));

#line 349
        }
        else
        {

#line 349
            _S207 = n0_0;

#line 349
        }

#line 349
        float _S208 = hslMask_0(_S207, s_22);

#line 349
        m_7 = _S208;

#line 349
    }
    else
    {

#line 349
        m_7 = 1.0f;

#line 349
    }
    if((flags_4 & 2U) != 0U)
    {

#line 350
        float _S209 = stepWindowMask_0(s_22, uv_3, aspect_3);

#line 350
        m_7 = m_7 * _S209;

#line 350
    }
    if((flags_4 & 4U) != 0U)
    {

#line 351
        m_7 = m_7 * s_22->d_0.w;

#line 351
    }
    return m_7;
}

float3 stepEndStage_0(float3 c_16, float3 n0_1, const Sec_0 constant* s_23, bool pre_13, uint flags_5, float2 uv_4, float aspect_4, float km_0)
{

#line 355
    float _S210 = stepMatte_0(n0_1, s_23, pre_13, flags_5, uv_4, aspect_4);

    return n0_1 + (c_16 - n0_1) * float3((_S210 * km_0)) ;
}



float3 layerComposite_0(float3 acc_0, float3 c_17, uint mode_0)
{

#line 363
    switch(mode_0)
    {
    case 1U:
        {

#line 364
            return acc_0 + c_17;
        }
    case 2U:
        {

#line 365
            return acc_0 - c_17;
        }
    case 3U:
        {

#line 366
            return acc_0 * c_17;
        }
    case 4U:
        {

#line 367
            float3 _S211 = float3(1.0f) ;

#line 367
            return _S211 - (_S211 - acc_0) * (_S211 - c_17);
        }
    case 5U:
        {

#line 368
            return max(acc_0, c_17);
        }
    case 6U:
        {

#line 369
            return min(acc_0, c_17);
        }
    default:
        {

#line 370
            return c_17;
        }
    }

#line 370
}


void branchEndStage_0(float3 c_18, float3 g0_0, float3 thread* acc_1, const Sec_0 constant* s_24, bool pre_14, uint flags_6, float2 uv_5, float aspect_5, float km_1)
{

#line 373
    float _S212 = stepMatte_0(g0_0, s_24, pre_14, flags_6, uv_5, aspect_5);
    float m_8 = _S212 * km_1;
    if((flags_6 & 8U) != 0U)
    {

#line 375
        *acc_1 = *acc_1 + (layerComposite_0(*acc_1, c_18, (flags_6 >> 5U) & 7U) - *acc_1) * float3(m_8) ;

#line 375
    }
    else
    {

#line 375
        *acc_1 = *acc_1 + (g0_0 + (c_18 - g0_0) * float3(m_8) );

#line 375
    }
    return;
}

float keyTermStage_0(float3 n0_2, const Sec_0 constant* s_25, bool pre_15, uint flags_7, float2 uv_6, float aspect_6, float km_2)
{

#line 379
    float m_9;

    if((flags_7 & 1U) != 0U)
    {

#line 381
        float3 _S213;

#line 381
        if(pre_15)
        {

#line 381
            _S213 = map3_0(n0_2, int(12));

#line 381
        }
        else
        {

#line 381
            _S213 = n0_2;

#line 381
        }

#line 381
        float _S214 = hslMask_1(_S213, s_25);

#line 381
        m_9 = _S214;

#line 381
    }
    else
    {

#line 381
        m_9 = 1.0f;

#line 381
    }
    if((flags_7 & 2U) != 0U)
    {

#line 382
        float _S215 = stepWindowMask_1(s_25, uv_6, aspect_6);

#line 382
        m_9 = m_9 * _S215;

#line 382
    }
    if((flags_7 & 4U) != 0U)
    {

#line 383
        m_9 = 1.0f - m_9;

#line 383
    }
    switch((flags_7 >> 5U) & 7U)
    {
    case 1U:
        {

#line 385
            return min(km_2 + m_9, 1.0f);
        }
    case 2U:
        {

#line 386
            return km_2 * m_9;
        }
    case 3U:
        {

#line 387
            return max(km_2 - m_9, 0.0f);
        }
    case 4U:
        {

#line 388
            return max(km_2, m_9);
        }
    default:
        {

#line 389
            return m_9;
        }
    }

#line 389
}


#line 281
float3 zoneBoardStage_0(float3 c_19, const Sec_0 constant* s_26, bool pre_16)
{

#line 281
    float3 t_22;
    if(pre_16)
    {

#line 282
        t_22 = map3_0(c_19, int(12));

#line 282
    }
    else
    {

#line 282
        t_22 = c_19;

#line 282
    }
    float3 lum_1 = float3(s_26->m1_0.y, s_26->m1_0.z, s_26->m2_0.x);
    float y_24 = dot(lum_1, t_22);
    float _S216 = smoothS_0(0.0f, 0.5f, y_24);


    float4 _S217 = float4(1.0f, 1.0f - _S216, _S216 * (1.0f - smoothS_0(0.5f, 1.0f, y_24)), smoothS_0(0.34999999403953552f, 1.1499999761581421f, y_24));
    array<float, int(4)> _S218 = { { s_26->m0_0.x, s_26->m0_0.y, s_26->m0_0.z, s_26->m1_0.x } };
    float4 _S219 = float4(s_26->a_0.w, s_26->b_0.w, s_26->c_0.w, s_26->d_0.w);
    array<float3, int(4)> _S220 = { { s_26->a_0.xyz, s_26->b_0.xyz, s_26->c_0.xyz, s_26->d_0.xyz } };

    float3 _S221 = float3(0.0f) ;

#line 293
    int z_0 = int(0);

#line 293
    float gain_2 = 1.0f;

#line 293
    float sat_2 = 1.0f;

#line 293
    float3 off_0 = _S221;
    for(;;)
    {

#line 294
        if(z_0 < int(4))
        {
        }
        else
        {

#line 294
            break;
        }

#line 295
        float gain_3 = gain_2 * (1.0f + _S217[z_0] * (_S218[z_0] - 1.0f));
        float sat_3 = sat_2 + _S217[z_0] * (_S219[z_0] - 1.0f);
        float3 off_1 = off_0 + float3(_S217[z_0])  * _S220[z_0];

#line 294
        z_0 = z_0 + int(1);

#line 294
        gain_2 = gain_3;

#line 294
        sat_2 = sat_3;

#line 294
        off_0 = off_1;

#line 294
    }

#line 299
    float3 t_23 = t_22 * float3(gain_2)  + off_0;
    if(sat_2 != 1.0f)
    {
        float3 _S222 = float3(dot(lum_1, t_23)) ;

#line 302
        t_22 = _S222 + (t_23 - _S222) * float3(max(sat_2, 0.0f)) ;

#line 300
    }
    else
    {

#line 300
        t_22 = t_23;

#line 300
    }



    if(pre_16)
    {

#line 304
        t_22 = map3_0(t_22, int(2));

#line 304
    }

#line 304
    return t_22;
}


#line 514
float3 processPixel_0(float3 px_3, float2 uv_7, float aspect_7, KernelContext_0 thread* kernelContext_15)
{

#line 515
    int src_1 = int(kernelContext_15->cc_0->ints_0.w);

#line 515
    float3 c_20;
    if((kernelContext_15->cc_0->ints_0.y) == 0U)
    {

#line 516
        c_20 = map3_0(px_3, src_1);

#line 516
    }
    else
    {

#line 516
        c_20 = px_3;

#line 516
    }

    float3 _S223 = float3(0.0f) ;

#line 518
    thread float3 acc_2 = _S223;

#line 518
    float3 n0_3 = c_20;

#line 518
    float km_3 = 1.0f;

#line 518
    uint i_2 = 0U;

    for(;;)
    {

#line 520
        if(i_2 < (kernelContext_15->cc_0->ints_0.x))
        {
        }
        else
        {

#line 520
            break;
        }

#line 521
        Sec_0 s_27 = kernelContext_15->cc_0->secs_0[i_2];
        bool pre_17 = (kernelContext_15->cc_0->secs_0[i_2].head_0.y) != 0U;
        uint _S224 = kernelContext_15->cc_0->secs_0[i_2].head_0.z;

#line 523
        bool keyed_0 = (_S224 & 16U) != 0U;

#line 523
        float _S225;

#line 523
        float km_4;
        switch(kernelContext_15->cc_0->secs_0[i_2].head_0.x)
        {
        case 0U:
            {

#line 524
                float3 _S226 = conversionStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], src_1, _S224, kernelContext_15);

#line 524
                c_20 = _S226;

#line 524
                km_4 = km_3;
                break;
            }
        case 1U:
            {

#line 525
                float3 _S227 = basicStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17);

#line 525
                c_20 = _S227;

#line 525
                km_4 = km_3;
                break;
            }
        case 2U:
            {

#line 526
                float3 _S228 = creativeStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17);

#line 526
                c_20 = _S228;

#line 526
                km_4 = km_3;
                break;
            }
        case 3U:
            {

#line 527
                float3 _S229 = lookStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17, _S224, kernelContext_15);

#line 527
                c_20 = _S229;

#line 527
                km_4 = km_3;
                break;
            }
        case 4U:
            {

#line 528
                float3 _S230 = curvesStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17, kernelContext_15);

#line 528
                c_20 = _S230;

#line 528
                km_4 = km_3;
                break;
            }
        case 5U:
            {

#line 529
                float3 _S231 = wheelsStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17);

#line 529
                c_20 = _S231;

#line 529
                km_4 = km_3;
                break;
            }
        case 6U:
            {

#line 530
                float3 _S232 = vignetteStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17, uv_7, aspect_7);

#line 530
                c_20 = _S232;

#line 530
                km_4 = km_3;
                break;
            }
        case 7U:
            {

#line 531
                float3 _S233 = hueCurvesStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17, kernelContext_15);

#line 531
                c_20 = _S233;

#line 531
                km_4 = km_3;
                break;
            }
        case 8U:
            {

#line 532
                float3 _S234 = hslSecondaryStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17);

#line 532
                c_20 = _S234;

#line 532
                km_4 = km_3;
                break;
            }
        case 9U:
            {

#line 533
                float3 _S235 = primariesStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17, _S224);

#line 533
                c_20 = _S235;

#line 533
                km_4 = km_3;
                break;
            }
        case 10U:
            {

#line 534
                n0_3 = c_20;

#line 534
                km_4 = km_3;
                break;
            }
        case 11U:
            {

#line 536
                if(keyed_0)
                {

#line 536
                    _S225 = km_3;

#line 536
                }
                else
                {

#line 536
                    _S225 = 1.0f;

#line 536
                }

#line 536
                float3 _S236 = stepEndStage_0(c_20, n0_3, &kernelContext_15->cc_0->secs_0[i_2], pre_17, _S224, uv_7, aspect_7, _S225);

#line 536
                if(keyed_0)
                {

#line 536
                    km_4 = 1.0f;

#line 536
                }
                else
                {

#line 536
                    km_4 = km_3;

#line 536
                }

#line 536
                c_20 = _S236;

#line 536
                break;
            }
        case 12U:
            {

#line 537
                acc_2 = _S223;

#line 537
                n0_3 = c_20;

#line 537
                km_4 = km_3;

#line 537
                break;
            }
        case 13U:
            {

#line 538
                if(keyed_0)
                {

#line 538
                    _S225 = km_3;

#line 538
                }
                else
                {

#line 538
                    _S225 = 1.0f;

#line 538
                }

#line 538
                branchEndStage_0(c_20, n0_3, &acc_2, &kernelContext_15->cc_0->secs_0[i_2], pre_17, _S224, uv_7, aspect_7, _S225);

#line 538
                if(keyed_0)
                {

#line 538
                    km_4 = 1.0f;

#line 538
                }
                else
                {

#line 538
                    km_4 = km_3;

#line 538
                }

#line 538
                c_20 = n0_3;

#line 538
                break;
            }
        case 14U:
            {

#line 538
                float3 _S237;
                if(_S224 != 0U)
                {

#line 539
                    _S237 = n0_3;

#line 539
                }
                else
                {

#line 539
                    _S237 = acc_2 * float3(s_27.a_0.x) ;

#line 539
                }

#line 539
                acc_2 = _S237;

#line 539
                km_4 = km_3;

#line 539
                break;
            }
        case 15U:
            {

#line 539
                c_20 = acc_2;

#line 539
                km_4 = km_3;
                break;
            }
        case 16U:
            {

#line 540
                float _S238 = keyTermStage_0(n0_3, &kernelContext_15->cc_0->secs_0[i_2], pre_17, _S224, uv_7, aspect_7, km_3);

#line 540
                km_4 = _S238;
                break;
            }
        case 18U:
            {

#line 541
                float3 _S239 = zoneBoardStage_0(c_20, &kernelContext_15->cc_0->secs_0[i_2], pre_17);

#line 541
                c_20 = _S239;

#line 541
                km_4 = km_3;
                break;
            }
        case 17U:
            {

#line 543
                acc_2 = n0_3 + (acc_2 - n0_3) * float3(km_3) ;

#line 543
                km_4 = 1.0f;

#line 543
                break;
            }
        default:
            {

#line 543
                km_4 = km_3;
                break;
            }
        }

#line 520
        uint _S240 = i_2 + 1U;

#line 520
        km_3 = km_4;

#line 520
        i_2 = _S240;

#line 520
    }

#line 547
    if((kernelContext_15->cc_0->ints_0.z) == 3U)
    {

#line 547
        c_20 = map3_0(c_20, int(2));

#line 547
    }

#line 547
    return c_20;
}


float4 gradePixel_0(float4 px_4, uint2 gid_0, uint2 size_1, KernelContext_0 thread* kernelContext_16)
{

#line 552
    float2 uv_8 = (float2(gid_0) + float2(0.5f) ) / float2(size_1);
    float aspect_8 = float(size_1.x) / float(size_1.y);

#line 553
    float2 uv_9;

#line 553
    float aspect_9;
    if((kernelContext_16->cc_0->extra_0.x) != 0U)
    {

#line 554
        float _S241 = 1.0f / aspect_8;

#line 554
        uv_9 = uv_8.yx;

#line 554
        aspect_9 = _S241;

#line 554
    }
    else
    {

#line 554
        uv_9 = uv_8;

#line 554
        aspect_9 = aspect_8;

#line 554
    }

#line 554
    float3 _S242 = processPixel_0(px_4.xyz, uv_9, aspect_9, kernelContext_16);
    return float4(_S242, px_4.w);
}


#line 11 "crates/sq-gpu/shaders-src/ColorChain.slang"
[[kernel]] void colorChain(uint3 tid_0 [[thread_position_in_grid]], ColorChainU_0 constant* cc_1 [[buffer(0)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture3d<float, access::sample> lut0_1 [[texture(24)]], CurveRows_0 constant* curves_1 [[buffer(1)]])
{

#line 11
    thread KernelContext_0 kernelContext_17;

#line 11
    (&kernelContext_17)->cc_0 = cc_1;

#line 11
    (&kernelContext_17)->out0_0 = out0_1;

#line 11
    (&kernelContext_17)->in0_0 = in0_1;

#line 11
    (&kernelContext_17)->in3_0 = in3_1;

#line 11
    (&kernelContext_17)->lut0_0 = lut0_1;

#line 11
    (&kernelContext_17)->curves_0 = curves_1;
    uint2 gid_1 = tid_0.xy + cc_1->extra_0.yz;

#line 12
    uint2 _S243 = outSize_0(&kernelContext_17);

#line 12
    bool _S244;

    if((gid_1.x) >= (_S243.x))
    {

#line 14
        _S244 = true;

#line 14
    }
    else
    {

#line 14
        _S244 = (gid_1.y) >= (_S243.y);

#line 14
    }

#line 14
    if(_S244)
    {

#line 14
        return;
    }

#line 15
    int3 _S245 = int3(int2(gid_1), int(0));

#line 15
    float4 _S246 = gradePixel_0((((&kernelContext_17)->in0_0).read(vec<uint,2>(((_S245)).xy), uint(((_S245)).z))), gid_1, _S243, &kernelContext_17);

#line 15
    (&kernelContext_17)->out0_0.write(_S246,gid_1);
    return;
}

