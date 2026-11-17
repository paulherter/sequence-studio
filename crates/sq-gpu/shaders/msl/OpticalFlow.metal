#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 4 "crates/sq-gpu/shaders-src/OpticalFlow.slang"
struct FlowU_0
{
    int radius_0;
    float lambda_0;
    float invTwoSigma2_0;
    float maxStep_0;
    float t_0;
    uint linearize_0;
    float2 flowScale_0;
    float sigma_0;
    uint hasPrev_0;
    float2 pad_0;
};


#line 8 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
    sampler edgeSampler_0;
    FlowU_0 constant* u_0;
    texture2d<float, access::sample> in4_0;
    texture2d<float, access::sample> in1_0;
    texture2d<float, access::sample> in3_0;
    texture2d<float, access::sample> in2_0;
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


#line 14 "crates/sq-gpu/shaders-src/OpticalFlow.slang"
float2 sizeOf_0(texture2d<float, access::sample> t_1)
{

#line 14
    thread uint w_1;

#line 14
    thread uint h_1;

#line 14
    (*((&w_1)) = (t_1).get_width(0)),(*((&h_1)) = (t_1).get_height(0));

#line 14
    return float2(float(w_1), float(h_1));
}


#line 24
[[kernel]] void ofLuma(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], sampler edgeSampler_1 [[sampler(1)]], FlowU_0 constant* u_1 [[buffer(0)]], texture2d<float, access::sample> in4_1 [[texture(4)]], texture2d<float, access::sample> in1_1 [[texture(1)]], texture2d<float, access::sample> in3_1 [[texture(3)]], texture2d<float, access::sample> in2_1 [[texture(2)]])
{

#line 24
    thread KernelContext_0 kernelContext_1;

#line 24
    (&kernelContext_1)->out0_0 = out0_1;

#line 24
    (&kernelContext_1)->in0_0 = in0_1;

#line 24
    (&kernelContext_1)->edgeSampler_0 = edgeSampler_1;

#line 24
    (&kernelContext_1)->u_0 = u_1;

#line 24
    (&kernelContext_1)->in4_0 = in4_1;

#line 24
    (&kernelContext_1)->in1_0 = in1_1;

#line 24
    (&kernelContext_1)->in3_0 = in3_1;

#line 24
    (&kernelContext_1)->in2_0 = in2_1;

#line 24
    uint2 _S2 = outSize_0(&kernelContext_1);

#line 24
    bool _S3;

    if((tid_0.x) >= (_S2.x))
    {

#line 26
        _S3 = true;

#line 26
    }
    else
    {

#line 26
        _S3 = (tid_0.y) >= (_S2.y);

#line 26
    }

#line 26
    if(_S3)
    {

#line 26
        return;
    }

#line 27
    float2 ss_0 = sizeOf_0((&kernelContext_1)->in0_0);
    float2 scale_0 = ss_0 / float2(_S2);
    uint2 _S4 = tid_0.xy;

#line 29
    float2 _S5 = float2(_S4) * scale_0;

#line 29
    int j_0 = int(0);

#line 29
    float acc_0 = 0.0f;

    for(;;)
    {

#line 31
        if(j_0 < int(3))
        {
        }
        else
        {

#line 31
            break;
        }

#line 31
        int i_0 = int(0);

#line 31
        for(;;)
        {

#line 31
            if(i_0 < int(3))
            {
            }
            else
            {

#line 31
                break;
            }
            float acc_1 = acc_0 + dot(clamp((((&kernelContext_1)->in0_0).sample(((&kernelContext_1)->edgeSampler_0), ((_S5 + (float2(float(i_0), float(j_0)) + float2(0.5f) ) / float2(3.0f)  * scale_0) / ss_0), level((0.0f)))).xyz, float3(0.0f) , float3(1.5f) ), float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f));

#line 31
            i_0 = i_0 + int(1);

#line 31
            acc_0 = acc_1;

#line 31
        }

#line 31
        j_0 = j_0 + int(1);

#line 31
    }



    (&kernelContext_1)->out0_0.write(float4((acc_0 / 9.0f)) ,_S4);
    return;
}



[[kernel]] void ofDown(uint3 tid_1 [[thread_position_in_grid]], texture2d<float, access::write> out0_2 [[texture(25)]], texture2d<float, access::sample> in0_2 [[texture(0)]], sampler edgeSampler_2 [[sampler(1)]], FlowU_0 constant* u_2 [[buffer(0)]], texture2d<float, access::sample> in4_2 [[texture(4)]], texture2d<float, access::sample> in1_2 [[texture(1)]], texture2d<float, access::sample> in3_2 [[texture(3)]], texture2d<float, access::sample> in2_2 [[texture(2)]])
{

#line 41
    thread KernelContext_0 kernelContext_2;

#line 41
    (&kernelContext_2)->out0_0 = out0_2;

#line 41
    (&kernelContext_2)->in0_0 = in0_2;

#line 41
    (&kernelContext_2)->edgeSampler_0 = edgeSampler_2;

#line 41
    (&kernelContext_2)->u_0 = u_2;

#line 41
    (&kernelContext_2)->in4_0 = in4_2;

#line 41
    (&kernelContext_2)->in1_0 = in1_2;

#line 41
    (&kernelContext_2)->in3_0 = in3_2;

#line 41
    (&kernelContext_2)->in2_0 = in2_2;

#line 41
    uint2 _S6 = outSize_0(&kernelContext_2);
    float2 _S7 = float2(_S6);

#line 42
    bool _S8;
    if((tid_1.x) >= uint(_S7.x))
    {

#line 43
        _S8 = true;

#line 43
    }
    else
    {

#line 43
        _S8 = (tid_1.y) >= uint(_S7.y);

#line 43
    }

#line 43
    if(_S8)
    {

#line 43
        return;
    }

#line 44
    float2 ss_1 = sizeOf_0((&kernelContext_2)->in0_0);
    float2 r_0 = ss_1 / _S7;
    uint2 _S9 = tid_1.xy;

#line 46
    float2 _S10 = float2(0.5f) ;

#line 46
    float2 c_0 = (float2(_S9) + _S10) * r_0;

#line 46
    float2 o_0 = _S10 * r_0;
    float _S11 = o_0.x;

#line 47
    float _S12 = - _S11;

#line 47
    float _S13 = o_0.y;

#line 47
    float _S14 = - _S13;



    (&kernelContext_2)->out0_0.write(float4((((((&kernelContext_2)->in0_0).sample(((&kernelContext_2)->edgeSampler_0), ((c_0 + float2(_S12, _S14)) / ss_1), level((0.0f)))).x + (((&kernelContext_2)->in0_0).sample(((&kernelContext_2)->edgeSampler_0), ((c_0 + float2(_S11, _S14)) / ss_1), level((0.0f)))).x + (((&kernelContext_2)->in0_0).sample(((&kernelContext_2)->edgeSampler_0), ((c_0 + float2(_S12, _S13)) / ss_1), level((0.0f)))).x + (((&kernelContext_2)->in0_0).sample(((&kernelContext_2)->edgeSampler_0), ((c_0 + float2(_S11, _S13)) / ss_1), level((0.0f)))).x) * 0.25f)) ,_S9);
    return;
}


#line 41 "crates/sq-gpu/shaders-src/Bindings.slang"
uint2 inSize_0(KernelContext_0 thread* kernelContext_3)
{

#line 41
    texture2d<float, access::sample> _S15 = kernelContext_3->in0_0;

#line 41
    thread uint w_2;

#line 41
    thread uint h_2;

#line 41
    (*((&w_2)) = (_S15).get_width(0)),(*((&h_2)) = (_S15).get_height(0));

#line 41
    return uint2(w_2, h_2);
}


#line 42
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_4)
{

#line 42
    int3 _S16 = int3(p_0, int(0));

#line 42
    return ((kernelContext_4->in0_0).read(vec<uint,2>(((_S16)).xy), uint(((_S16)).z)));
}


#line 55 "crates/sq-gpu/shaders-src/OpticalFlow.slang"
[[kernel]] void ofGrad(uint3 tid_2 [[thread_position_in_grid]], texture2d<float, access::write> out0_3 [[texture(25)]], texture2d<float, access::sample> in0_3 [[texture(0)]], sampler edgeSampler_3 [[sampler(1)]], FlowU_0 constant* u_3 [[buffer(0)]], texture2d<float, access::sample> in4_3 [[texture(4)]], texture2d<float, access::sample> in1_3 [[texture(1)]], texture2d<float, access::sample> in3_3 [[texture(3)]], texture2d<float, access::sample> in2_3 [[texture(2)]])
{

#line 55
    thread KernelContext_0 kernelContext_5;

#line 55
    (&kernelContext_5)->out0_0 = out0_3;

#line 55
    (&kernelContext_5)->in0_0 = in0_3;

#line 55
    (&kernelContext_5)->edgeSampler_0 = edgeSampler_3;

#line 55
    (&kernelContext_5)->u_0 = u_3;

#line 55
    (&kernelContext_5)->in4_0 = in4_3;

#line 55
    (&kernelContext_5)->in1_0 = in1_3;

#line 55
    (&kernelContext_5)->in3_0 = in3_3;

#line 55
    (&kernelContext_5)->in2_0 = in2_3;

#line 55
    uint2 _S17 = inSize_0(&kernelContext_5);
    int2 _S18 = int2(_S17);

#line 56
    bool _S19;
    if(int(tid_2.x) >= (_S18.x))
    {

#line 57
        _S19 = true;

#line 57
    }
    else
    {

#line 57
        _S19 = int(tid_2.y) >= (_S18.y);

#line 57
    }

#line 57
    if(_S19)
    {

#line 57
        return;
    }

#line 58
    uint2 _S20 = tid_2.xy;

#line 58
    int2 _S21 = int2(_S20);
    int2 _S22 = int2(int(0)) ;

#line 59
    int2 _S23 = _S18 - int2(int(1)) ;

#line 59
    float4 _S24 = read0_0(clamp(_S21 + int2(int(-1), int(0)), _S22, _S23), &kernelContext_5);

#line 59
    float l_0 = _S24.x;

#line 59
    float4 _S25 = read0_0(clamp(_S21 + int2(int(1), int(0)), _S22, _S23), &kernelContext_5);

#line 59
    float r_1 = _S25.x;

#line 59
    float4 _S26 = read0_0(clamp(_S21 + int2(int(0), int(-1)), _S22, _S23), &kernelContext_5);
    float t_2 = _S26.x;

#line 60
    float4 _S27 = read0_0(clamp(_S21 + int2(int(0), int(1)), _S22, _S23), &kernelContext_5);
    (&kernelContext_5)->out0_0.write(float4(0.5f * (r_1 - l_0), 0.5f * (_S27.x - t_2), 0.0f, 0.0f),_S20);
    return;
}


[[kernel]] void ofUp(uint3 tid_3 [[thread_position_in_grid]], texture2d<float, access::write> out0_4 [[texture(25)]], texture2d<float, access::sample> in0_4 [[texture(0)]], sampler edgeSampler_4 [[sampler(1)]], FlowU_0 constant* u_4 [[buffer(0)]], texture2d<float, access::sample> in4_4 [[texture(4)]], texture2d<float, access::sample> in1_4 [[texture(1)]], texture2d<float, access::sample> in3_4 [[texture(3)]], texture2d<float, access::sample> in2_4 [[texture(2)]])
{

#line 66
    thread KernelContext_0 kernelContext_6;

#line 66
    (&kernelContext_6)->out0_0 = out0_4;

#line 66
    (&kernelContext_6)->in0_0 = in0_4;

#line 66
    (&kernelContext_6)->edgeSampler_0 = edgeSampler_4;

#line 66
    (&kernelContext_6)->u_0 = u_4;

#line 66
    (&kernelContext_6)->in4_0 = in4_4;

#line 66
    (&kernelContext_6)->in1_0 = in1_4;

#line 66
    (&kernelContext_6)->in3_0 = in3_4;

#line 66
    (&kernelContext_6)->in2_0 = in2_4;

#line 66
    uint2 _S28 = outSize_0(&kernelContext_6);
    float2 _S29 = float2(_S28);

#line 67
    bool _S30;
    if((tid_3.x) >= uint(_S29.x))
    {

#line 68
        _S30 = true;

#line 68
    }
    else
    {

#line 68
        _S30 = (tid_3.y) >= uint(_S29.y);

#line 68
    }

#line 68
    if(_S30)
    {

#line 68
        return;
    }

#line 69
    if(((&kernelContext_6)->u_0->hasPrev_0) == 0U)
    {

#line 69
        (&kernelContext_6)->out0_0.write(float4(0.0f) ,tid_3.xy);

#line 69
        return;
    }
    uint2 _S31 = tid_3.xy;
    (&kernelContext_6)->out0_0.write(float4((((&kernelContext_6)->in0_0).sample(((&kernelContext_6)->edgeSampler_0), ((float2(_S31) + float2(0.5f) ) / _S29), level((0.0f)))).xy * (_S29 / sizeOf_0((&kernelContext_6)->in0_0)), 0.0f, 0.0f),_S31);
    return;
}




[[kernel]] void ofLK(uint3 tid_4 [[thread_position_in_grid]], texture2d<float, access::write> out0_5 [[texture(25)]], texture2d<float, access::sample> in0_5 [[texture(0)]], sampler edgeSampler_5 [[sampler(1)]], FlowU_0 constant* u_5 [[buffer(0)]], texture2d<float, access::sample> in4_5 [[texture(4)]], texture2d<float, access::sample> in1_5 [[texture(1)]], texture2d<float, access::sample> in3_5 [[texture(3)]], texture2d<float, access::sample> in2_5 [[texture(2)]])
{

#line 79
    thread KernelContext_0 kernelContext_7;

#line 79
    (&kernelContext_7)->out0_0 = out0_5;

#line 79
    (&kernelContext_7)->in0_0 = in0_5;

#line 79
    (&kernelContext_7)->edgeSampler_0 = edgeSampler_5;

#line 79
    (&kernelContext_7)->u_0 = u_5;

#line 79
    (&kernelContext_7)->in4_0 = in4_5;

#line 79
    (&kernelContext_7)->in1_0 = in1_5;

#line 79
    (&kernelContext_7)->in3_0 = in3_5;

#line 79
    (&kernelContext_7)->in2_0 = in2_5;

#line 79
    uint2 _S32 = inSize_0(&kernelContext_7);
    int2 _S33 = int2(_S32);
    int _S34 = _S33.x;

#line 81
    bool _S35;

#line 81
    if(int(tid_4.x) >= _S34)
    {

#line 81
        _S35 = true;

#line 81
    }
    else
    {

#line 81
        _S35 = int(tid_4.y) >= (_S33.y);

#line 81
    }

#line 81
    if(_S35)
    {

#line 81
        return;
    }

#line 82
    uint2 _S36 = tid_4.xy;

#line 82
    int2 _S37 = int2(_S36);

#line 82
    int3 _S38 = int3(_S37, int(0));

#line 82
    float2 v_0 = (((&kernelContext_7)->in4_0).read(vec<uint,2>(((_S38)).xy), uint(((_S38)).z))).xy;

    float2 _S39 = float2(_S33);

#line 84
    int dy_0 = - (&kernelContext_7)->u_0->radius_0;

#line 84
    float a11_0 = 0.0f;

#line 84
    float a12_0 = 0.0f;

#line 84
    float a22_0 = 0.0f;

#line 84
    float b1_0 = 0.0f;

#line 84
    float b2_0 = 0.0f;
    for(;;)
    {

#line 85
        if(dy_0 <= ((&kernelContext_7)->u_0->radius_0))
        {
        }
        else
        {

#line 85
            break;
        }

#line 85
        int dx_0 = - (&kernelContext_7)->u_0->radius_0;

#line 85
        float a11_1 = a11_0;

#line 85
        float a12_1 = a12_0;

#line 85
        float a22_1 = a22_0;

#line 85
        float b1_1 = b1_0;

#line 85
        float b2_1 = b2_0;

#line 85
        for(;;)
        {

#line 85
            if(dx_0 <= ((&kernelContext_7)->u_0->radius_0))
            {
            }
            else
            {

#line 85
                break;
            }

#line 86
            int2 q_0 = _S37 + int2(dx_0, dy_0);
            int _S40 = q_0.x;

#line 87
            if(_S40 < int(0))
            {

#line 87
                _S35 = true;

#line 87
            }
            else
            {

#line 87
                _S35 = (q_0.y) < int(0);

#line 87
            }

#line 87
            bool _S41;

#line 87
            if(_S35)
            {

#line 87
                _S41 = true;

#line 87
            }
            else
            {

#line 87
                _S41 = _S40 >= _S34;

#line 87
            }

#line 87
            bool _S42;

#line 87
            if(_S41)
            {

#line 87
                _S42 = true;

#line 87
            }
            else
            {

#line 87
                _S42 = (q_0.y) >= (_S33.y);

#line 87
            }

#line 87
            if(_S42)
            {

#line 87
                dx_0 = dx_0 + int(1);

#line 85
                continue;
            }

#line 85
            float2 _S43 = float2(0.5f) ;


            float2 at_0 = float2(q_0) + _S43 + v_0;
            float _S44 = at_0.x;

#line 89
            bool _S45;

#line 89
            if(_S44 < 0.0f)
            {

#line 89
                _S45 = true;

#line 89
            }
            else
            {

#line 89
                _S45 = (at_0.y) < 0.0f;

#line 89
            }

#line 89
            bool _S46;

#line 89
            if(_S45)
            {

#line 89
                _S46 = true;

#line 89
            }
            else
            {

#line 89
                _S46 = _S44 > (_S39.x);

#line 89
            }

#line 89
            bool _S47;

#line 89
            if(_S46)
            {

#line 89
                _S47 = true;

#line 89
            }
            else
            {

#line 89
                _S47 = (at_0.y) > (_S39.y);

#line 89
            }

#line 89
            if(_S47)
            {

#line 89
                dx_0 = dx_0 + int(1);

#line 85
                continue;
            }



            float w_3 = exp(- float(dx_0 * dx_0 + dy_0 * dy_0) * (&kernelContext_7)->u_0->invTwoSigma2_0);
            int3 _S48 = int3(q_0, int(0));

#line 91
            float2 g_0 = _S43 * ((((&kernelContext_7)->in1_0).read(vec<uint,2>(((_S48)).xy), uint(((_S48)).z))).xy + (((&kernelContext_7)->in3_0).sample(((&kernelContext_7)->edgeSampler_0), (at_0 / _S39), level((0.0f)))).xy);
            float it_0 = (((&kernelContext_7)->in2_0).sample(((&kernelContext_7)->edgeSampler_0), (at_0 / _S39), level((0.0f)))).x - (((&kernelContext_7)->in0_0).read(vec<uint,2>(((_S48)).xy), uint(((_S48)).z))).x;
            float _S49 = g_0.x;

#line 93
            float _S50 = w_3 * _S49;

#line 93
            float _S51 = g_0.y;

#line 93
            float a12_2 = a12_1 + _S50 * _S51;

#line 93
            float _S52 = w_3 * _S51;

#line 93
            float a22_2 = a22_1 + _S52 * _S51;
            float b1_2 = b1_1 + _S50 * it_0;

#line 94
            float b2_2 = b2_1 + _S52 * it_0;

#line 94
            a11_1 = a11_1 + _S50 * _S49;

#line 94
            a12_1 = a12_2;

#line 94
            a22_1 = a22_2;

#line 94
            b1_1 = b1_2;

#line 94
            b2_1 = b2_2;

#line 85
            dx_0 = dx_0 + int(1);

#line 85
        }

#line 85
        dy_0 = dy_0 + int(1);

#line 85
        a11_0 = a11_1;

#line 85
        a12_0 = a12_1;

#line 85
        a22_0 = a22_1;

#line 85
        b1_0 = b1_1;

#line 85
        b2_0 = b2_1;

#line 85
    }

#line 96
    float a11_2 = a11_0 + (&kernelContext_7)->u_0->lambda_0;

#line 96
    float a22_3 = a22_0 + (&kernelContext_7)->u_0->lambda_0;
    float det_0 = a11_2 * a22_3 - a12_0 * a12_0;

#line 97
    float2 d_0;
    if(det_0 > 9.999999960041972e-13f)
    {

#line 98
        d_0 = - float2(a22_3 * b1_0 - a12_0 * b2_0, a11_2 * b2_0 - a12_0 * b1_0) / float2(det_0) ;

#line 98
    }
    else
    {

#line 98
        d_0 = float2(0.0f) ;

#line 98
    }
    float len_0 = length(d_0);
    if(len_0 > ((&kernelContext_7)->u_0->maxStep_0))
    {

#line 100
        d_0 = d_0 * float2(((&kernelContext_7)->u_0->maxStep_0 / len_0)) ;

#line 100
    }
    (&kernelContext_7)->out0_0.write(float4(v_0 + d_0, 0.0f, 0.0f),_S36);
    return;
}


#line 104
float med9_0(const array<float, int(9)> thread* v_1)
{

#line 104
    thread array<float, int(9)> _S53 = *v_1;

#line 104
    int i_1 = int(0);
    for(;;)
    {

#line 105
        if(i_1 < int(5))
        {
        }
        else
        {

#line 105
            break;
        }

#line 105
        int _S54 = i_1 + int(1);

#line 105
        int j_1 = _S54;

#line 105
        for(;;)
        {

#line 105
            if(j_1 < int(9))
            {
            }
            else
            {

#line 105
                break;
            }

#line 105
            if((_S53[j_1]) < _S53[i_1])
            {

#line 105
                float t_3 = _S53[i_1];

#line 105
                _S53[i_1] = _S53[j_1];

#line 105
                _S53[j_1] = t_3;

#line 105
            }

#line 105
            j_1 = j_1 + int(1);

#line 105
        }

#line 105
        i_1 = _S54;

#line 105
    }
    return _S53[int(4)];
}


[[kernel]] void ofMedian(uint3 tid_5 [[thread_position_in_grid]], texture2d<float, access::write> out0_6 [[texture(25)]], texture2d<float, access::sample> in0_6 [[texture(0)]], sampler edgeSampler_6 [[sampler(1)]], FlowU_0 constant* u_6 [[buffer(0)]], texture2d<float, access::sample> in4_6 [[texture(4)]], texture2d<float, access::sample> in1_6 [[texture(1)]], texture2d<float, access::sample> in3_6 [[texture(3)]], texture2d<float, access::sample> in2_6 [[texture(2)]])
{

#line 110
    thread KernelContext_0 kernelContext_8;

#line 110
    (&kernelContext_8)->out0_0 = out0_6;

#line 110
    (&kernelContext_8)->in0_0 = in0_6;

#line 110
    (&kernelContext_8)->edgeSampler_0 = edgeSampler_6;

#line 110
    (&kernelContext_8)->u_0 = u_6;

#line 110
    (&kernelContext_8)->in4_0 = in4_6;

#line 110
    (&kernelContext_8)->in1_0 = in1_6;

#line 110
    (&kernelContext_8)->in3_0 = in3_6;

#line 110
    (&kernelContext_8)->in2_0 = in2_6;

#line 110
    uint2 _S55 = inSize_0(&kernelContext_8);
    int2 _S56 = int2(_S55);

#line 111
    bool _S57;
    if(int(tid_5.x) >= (_S56.x))
    {

#line 112
        _S57 = true;

#line 112
    }
    else
    {

#line 112
        _S57 = int(tid_5.y) >= (_S56.y);

#line 112
    }

#line 112
    if(_S57)
    {

#line 112
        return;
    }

#line 113
    thread array<float, int(9)> x_0;

#line 113
    thread array<float, int(9)> y_0;

#line 113
    int dy_1 = int(-1);

#line 113
    int n_0 = int(0);

    for(;;)
    {

#line 115
        if(dy_1 <= int(1))
        {
        }
        else
        {

#line 115
            break;
        }

#line 115
        int dx_1 = int(-1);

#line 115
        for(;;)
        {

#line 115
            if(dx_1 <= int(1))
            {
            }
            else
            {

#line 115
                break;
            }

#line 115
            float4 _S58 = read0_0(clamp(int2(tid_5.xy) + int2(dx_1, dy_1), int2(int(0)) , _S56 - int2(int(1)) ), &kernelContext_8);
            float2 f_0 = _S58.xy;
            x_0[n_0] = f_0.x;

#line 117
            y_0[n_0] = f_0.y;

#line 117
            int _S59 = n_0 + int(1);

#line 115
            dx_1 = dx_1 + int(1);

#line 115
            n_0 = _S59;

#line 115
        }

#line 115
        dy_1 = dy_1 + int(1);

#line 115
    }



    uint2 _S60 = tid_5.xy;

#line 119
    thread array<float, int(9)> _S61 = x_0;

#line 119
    float _S62 = med9_0(&_S61);

#line 119
    thread array<float, int(9)> _S63 = y_0;

#line 119
    float _S64 = med9_0(&_S63);

#line 119
    (&kernelContext_8)->out0_0.write(float4(_S62, _S64, 0.0f, 0.0f),_S60);
    return;
}



[[kernel]] void ofConfidence(uint3 tid_6 [[thread_position_in_grid]], texture2d<float, access::write> out0_7 [[texture(25)]], texture2d<float, access::sample> in0_7 [[texture(0)]], sampler edgeSampler_7 [[sampler(1)]], FlowU_0 constant* u_7 [[buffer(0)]], texture2d<float, access::sample> in4_7 [[texture(4)]], texture2d<float, access::sample> in1_7 [[texture(1)]], texture2d<float, access::sample> in3_7 [[texture(3)]], texture2d<float, access::sample> in2_7 [[texture(2)]])
{

#line 125
    thread KernelContext_0 kernelContext_9;

#line 125
    (&kernelContext_9)->out0_0 = out0_7;

#line 125
    (&kernelContext_9)->in0_0 = in0_7;

#line 125
    (&kernelContext_9)->edgeSampler_0 = edgeSampler_7;

#line 125
    (&kernelContext_9)->u_0 = u_7;

#line 125
    (&kernelContext_9)->in4_0 = in4_7;

#line 125
    (&kernelContext_9)->in1_0 = in1_7;

#line 125
    (&kernelContext_9)->in3_0 = in3_7;

#line 125
    (&kernelContext_9)->in2_0 = in2_7;

#line 125
    uint2 _S65 = inSize_0(&kernelContext_9);
    int2 _S66 = int2(_S65);

#line 126
    bool inside_0;
    if(int(tid_6.x) >= (_S66.x))
    {

#line 127
        inside_0 = true;

#line 127
    }
    else
    {

#line 127
        inside_0 = int(tid_6.y) >= (_S66.y);

#line 127
    }

#line 127
    if(inside_0)
    {

#line 127
        return;
    }

#line 128
    float2 _S67 = float2(_S66);
    uint2 _S68 = tid_6.xy;

#line 129
    int2 _S69 = int2(_S68);

#line 129
    int3 _S70 = int3(_S69, int(0));

#line 129
    float2 v_2 = (((&kernelContext_9)->in2_0).read(vec<uint,2>(((_S70)).xy), uint(((_S70)).z))).xy;

#line 129
    int dy_2 = int(-2);

#line 129
    float sum_0 = 0.0f;

#line 129
    float wsum_0 = 0.0f;

    for(;;)
    {

#line 131
        if(dy_2 <= int(2))
        {
        }
        else
        {

#line 131
            break;
        }

#line 131
        int dx_2 = int(-2);

#line 131
        for(;;)
        {

#line 131
            if(dx_2 <= int(2))
            {
            }
            else
            {

#line 131
                break;
            }

#line 132
            int2 q_1 = clamp(_S69 + int2(dx_2, dy_2), int2(int(0)) , _S66 - int2(int(1)) );
            float w_4 = exp(- float(dx_2 * dx_2 + dy_2 * dy_2) / 4.5f);
            int3 _S71 = int3(q_1, int(0));

#line 134
            float e_0 = (((&kernelContext_9)->in1_0).sample(((&kernelContext_9)->edgeSampler_0), ((float2(q_1) + float2(0.5f)  + v_2) / _S67), level((0.0f)))).x - (((&kernelContext_9)->in0_0).read(vec<uint,2>(((_S71)).xy), uint(((_S71)).z))).x;
            float sum_1 = sum_0 + w_4 * e_0 * e_0;

#line 135
            float wsum_1 = wsum_0 + w_4;

#line 131
            dx_2 = dx_2 + int(1);

#line 131
            sum_0 = sum_1;

#line 131
            wsum_0 = wsum_1;

#line 131
        }

#line 131
        dy_2 = dy_2 + int(1);

#line 131
    }

#line 137
    float mse_0 = sum_0 / wsum_0;
    float2 at_1 = float2(_S68) + float2(0.5f)  + v_2;
    float _S72 = at_1.x;

#line 139
    if(_S72 >= 0.0f)
    {

#line 139
        inside_0 = (at_1.y) >= 0.0f;

#line 139
    }
    else
    {

#line 139
        inside_0 = false;

#line 139
    }

#line 139
    if(inside_0)
    {

#line 139
        inside_0 = _S72 <= (_S67.x);

#line 139
    }
    else
    {

#line 139
        inside_0 = false;

#line 139
    }

#line 139
    if(inside_0)
    {

#line 139
        inside_0 = (at_1.y) <= (_S67.y);

#line 139
    }
    else
    {

#line 139
        inside_0 = false;

#line 139
    }
    float2 fb_0 = v_2 + (((&kernelContext_9)->in3_0).sample(((&kernelContext_9)->edgeSampler_0), (at_1 / _S67), level((0.0f)))).xy;

#line 140
    float trust_0;
    if(inside_0)
    {

#line 141
        trust_0 = exp(- mse_0 / 0.004999999888241291f) * exp(- dot(fb_0, fb_0) / 4.5f);

#line 141
    }
    else
    {

#line 141
        trust_0 = 0.0f;

#line 141
    }
    (&kernelContext_9)->out0_0.write(float4(v_2, trust_0, 0.0f),_S68);
    return;
}


#line 15
float4 tapPx_0(texture2d<float, access::sample> t_4, float2 p_1, KernelContext_0 thread* kernelContext_10)
{

#line 15
    return ((t_4).sample((kernelContext_10->edgeSampler_0), (p_1 / sizeOf_0(t_4)), level((0.0f))));
}


#line 149
float lumaOf_0(float4 c_1, bool lin_0)
{

#line 150
    float y_1 = dot(c_1.xyz, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f));

#line 150
    float _S73;
    if(lin_0)
    {

#line 151
        _S73 = y_1;

#line 151
    }
    else
    {

#line 151
        _S73 = sqrt(max(y_1, 0.0f));

#line 151
    }

#line 151
    return _S73;
}


#line 17
float3 ofLinear709_0(float3 e_1)
{

#line 18
    float3 _S74 = max(e_1, float3(0.0f) );
    return select(pow((_S74 + float3(0.099296823143959045f) ) / float3(1.0992968082427979f) , float3(2.2222223281860352f) ), _S74 / float3(4.5f) , _S74 < (float3(0.081242859363555908f) ));
}


#line 145
float4 premul_0(float4 c_2, bool lin_1)
{

#line 145
    float3 rgb_0;
    if(lin_1)
    {

#line 146
        rgb_0 = ofLinear709_0(c_2.xyz);

#line 146
    }
    else
    {

#line 146
        rgb_0 = c_2.xyz;

#line 146
    }
    float _S75 = c_2.w;

#line 147
    return float4(rgb_0 * float3(_S75) , _S75);
}


#line 158
[[kernel]] void ofInterpolate(uint3 tid_7 [[thread_position_in_grid]], texture2d<float, access::write> out0_8 [[texture(25)]], texture2d<float, access::sample> in0_8 [[texture(0)]], sampler edgeSampler_8 [[sampler(1)]], FlowU_0 constant* u_8 [[buffer(0)]], texture2d<float, access::sample> in4_8 [[texture(4)]], texture2d<float, access::sample> in1_8 [[texture(1)]], texture2d<float, access::sample> in3_8 [[texture(3)]], texture2d<float, access::sample> in2_8 [[texture(2)]])
{

#line 158
    thread KernelContext_0 kernelContext_11;

#line 158
    (&kernelContext_11)->out0_0 = out0_8;

#line 158
    (&kernelContext_11)->in0_0 = in0_8;

#line 158
    (&kernelContext_11)->edgeSampler_0 = edgeSampler_8;

#line 158
    (&kernelContext_11)->u_0 = u_8;

#line 158
    (&kernelContext_11)->in4_0 = in4_8;

#line 158
    (&kernelContext_11)->in1_0 = in1_8;

#line 158
    (&kernelContext_11)->in3_0 = in3_8;

#line 158
    (&kernelContext_11)->in2_0 = in2_8;

#line 158
    uint2 _S76 = outSize_0(&kernelContext_11);
    float2 _S77 = float2(_S76);

#line 159
    bool _S78;
    if((tid_7.x) >= uint(_S77.x))
    {

#line 160
        _S78 = true;

#line 160
    }
    else
    {

#line 160
        _S78 = (tid_7.y) >= uint(_S77.y);

#line 160
    }

#line 160
    if(_S78)
    {

#line 160
        return;
    }

#line 161
    bool lin_2 = ((&kernelContext_11)->u_0->linearize_0) != 0U;
    float t_5 = (&kernelContext_11)->u_0->t_0;
    uint2 _S79 = tid_7.xy;

#line 163
    float2 pc_0 = float2(_S79) + float2(0.5f) ;

#line 163
    float2 uv_0 = pc_0 / _S77;
    float4 fv_0 = (((&kernelContext_11)->in2_0).sample(((&kernelContext_11)->edgeSampler_0), (uv_0), level((0.0f))));

#line 164
    float4 gv_0 = (((&kernelContext_11)->in3_0).sample(((&kernelContext_11)->edgeSampler_0), (uv_0), level((0.0f))));
    float2 f_1 = fv_0.xy * (&kernelContext_11)->u_0->flowScale_0;
    float2 g_1 = - gv_0.xy * (&kernelContext_11)->u_0->flowScale_0;

#line 166
    float2 _S80 = float2((&kernelContext_11)->u_0->t_0) ;

#line 166
    float4 _S81 = tapPx_0((&kernelContext_11)->in0_0, pc_0 - _S80 * f_1, &kernelContext_11);

#line 166
    float2 _S82 = float2((1.0f - t_5)) ;

#line 166
    float4 _S83 = tapPx_0((&kernelContext_11)->in1_0, pc_0 + _S82 * f_1, &kernelContext_11);

#line 166
    float4 _S84 = tapPx_0((&kernelContext_11)->in0_0, pc_0 - _S80 * g_1, &kernelContext_11);

#line 166
    float4 _S85 = tapPx_0((&kernelContext_11)->in1_0, pc_0 + _S82 * g_1, &kernelContext_11);


    float e1_0 = lumaOf_0(_S81, lin_2) - lumaOf_0(_S83, lin_2);

#line 169
    float e2_0 = lumaOf_0(_S84, lin_2) - lumaOf_0(_S85, lin_2);
    float is2_0 = 1.0f / ((&kernelContext_11)->u_0->sigma_0 * (&kernelContext_11)->u_0->sigma_0);
    float w1_0 = fv_0.z * exp(- e1_0 * e1_0 * is2_0);

#line 171
    float w2_0 = gv_0.z * exp(- e2_0 * e2_0 * is2_0);
    float4 _S86 = float4(t_5) ;

#line 172
    float4 m1_0 = mix(premul_0(_S81, lin_2), premul_0(_S83, lin_2), _S86);

#line 172
    float4 m2_0 = mix(premul_0(_S84, lin_2), premul_0(_S85, lin_2), _S86);

#line 172
    float4 _S87 = tapPx_0((&kernelContext_11)->in0_0, pc_0, &kernelContext_11);
    float4 _S88 = premul_0(_S87, lin_2);

#line 173
    float4 _S89 = tapPx_0((&kernelContext_11)->in1_0, pc_0, &kernelContext_11);

#line 173
    float4 plain_0 = mix(_S88, premul_0(_S89, lin_2), _S86);
    float ws_0 = w1_0 + w2_0;

#line 174
    float4 warped_0;
    if(ws_0 > 9.99999997475242708e-07f)
    {

#line 175
        warped_0 = (m1_0 * float4(w1_0)  + m2_0 * float4(w2_0) ) / float4(ws_0) ;

#line 175
    }
    else
    {

#line 175
        warped_0 = plain_0;

#line 175
    }
    float4 m_0 = mix(plain_0, warped_0, float4(max(w1_0, w2_0)) );
    float _S90 = m_0.w;

#line 177
    float3 _S91;

#line 177
    if(_S90 > 0.0f)
    {

#line 177
        _S91 = m_0.xyz / float3(_S90) ;

#line 177
    }
    else
    {

#line 177
        _S91 = float3(0.0f) ;

#line 177
    }

#line 177
    (&kernelContext_11)->out0_0.write(float4(_S91, _S90),_S79);
    return;
}

