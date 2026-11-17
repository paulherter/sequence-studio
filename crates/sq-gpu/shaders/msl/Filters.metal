#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 3 "crates/sq-gpu/shaders-src/Filters.slang"
struct FilterU_0
{
    float4 a_0;
    float4 b_0;
    float2 center_0;
    float2 frame_0;
    int4 i_0;
    float4 c_0;
    float4 d_0;
};


#line 37 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    texture2d<float, access::sample> in0_0;
    FilterU_0 constant* u_0;
    texture2d<float, access::write> out0_0;
    sampler zeroSampler_0;
    texture2d<float, access::sample> in1_0;
    sampler edgeSampler_0;
};


#line 41
uint2 inSize_0(KernelContext_0 thread* kernelContext_0)
{

#line 41
    texture2d<float, access::sample> _S1 = kernelContext_0->in0_0;

#line 41
    thread uint w_0;

#line 41
    thread uint h_0;

#line 41
    (*((&w_0)) = (_S1).get_width(0)),(*((&h_0)) = (_S1).get_height(0));

#line 41
    return uint2(w_0, h_0);
}


#line 41
uint2 inSize_1(KernelContext_0 thread* kernelContext_1)
{

#line 41
    texture2d<float, access::sample> _S2 = kernelContext_1->in0_0;

#line 41
    thread uint w_1;

#line 41
    thread uint h_1;

#line 41
    (*((&w_1)) = (_S2).get_width(0)),(*((&h_1)) = (_S2).get_height(0));

#line 41
    return uint2(w_1, h_1);
}


#line 42
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_2)
{

#line 42
    int3 _S3 = int3(p_0, int(0));

#line 42
    return ((kernelContext_2->in0_0).read(vec<uint,2>(((_S3)).xy), uint(((_S3)).z)));
}


#line 42
float4 read0_1(int2 p_1, KernelContext_0 thread* kernelContext_3)
{

#line 42
    int3 _S4 = int3(p_1, int(0));

#line 42
    return ((kernelContext_3->in0_0).read(vec<uint,2>(((_S4)).xy), uint(((_S4)).z)));
}


#line 9 "crates/sq-gpu/shaders-src/Filters.slang"
[[kernel]] void filterSharpen(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::sample> in0_1 [[texture(0)]], FilterU_0 constant* u_1 [[buffer(0)]], texture2d<float, access::write> out0_1 [[texture(25)]], sampler zeroSampler_1 [[sampler(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], sampler edgeSampler_1 [[sampler(1)]])
{

#line 9
    thread KernelContext_0 kernelContext_4;

#line 9
    (&kernelContext_4)->in0_0 = in0_1;

#line 9
    (&kernelContext_4)->u_0 = u_1;

#line 9
    (&kernelContext_4)->out0_0 = out0_1;

#line 9
    (&kernelContext_4)->zeroSampler_0 = zeroSampler_1;

#line 9
    (&kernelContext_4)->in1_0 = in1_1;

#line 9
    (&kernelContext_4)->edgeSampler_0 = edgeSampler_1;

#line 9
    uint2 _S5 = inSize_0(&kernelContext_4);

    int W_0 = int(_S5.x);

#line 11
    int H_0 = int(_S5.y);
    uint2 _S6 = tid_0.xy;

#line 12
    int2 _S7 = int2(_S6);
    int _S8 = _S7.x;

#line 13
    bool inside_0;

#line 13
    if(_S8 >= W_0)
    {

#line 13
        inside_0 = true;

#line 13
    }
    else
    {

#line 13
        inside_0 = (_S7.y) >= H_0;

#line 13
    }

#line 13
    if(inside_0)
    {

#line 13
        return;
    }

#line 14
    if(_S8 >= ((&kernelContext_4)->u_0->i_0.x))
    {

#line 14
        inside_0 = (_S7.y) >= ((&kernelContext_4)->u_0->i_0.y);

#line 14
    }
    else
    {

#line 14
        inside_0 = false;

#line 14
    }

#line 14
    if(inside_0)
    {

#line 14
        inside_0 = _S8 <= ((&kernelContext_4)->u_0->i_0.z);

#line 14
    }
    else
    {

#line 14
        inside_0 = false;

#line 14
    }

#line 14
    if(inside_0)
    {

#line 14
        inside_0 = (_S7.y) <= ((&kernelContext_4)->u_0->i_0.w);

#line 14
    }
    else
    {

#line 14
        inside_0 = false;

#line 14
    }

#line 14
    int2 _S9;
    if(inside_0)
    {

#line 15
        _S9 = (&kernelContext_4)->u_0->i_0.xy;

#line 15
    }
    else
    {

#line 15
        _S9 = int2(int(0)) ;

#line 15
    }

#line 15
    int2 _S10;

#line 15
    if(inside_0)
    {

#line 15
        _S10 = (&kernelContext_4)->u_0->i_0.zw;

#line 15
    }
    else
    {

#line 15
        _S10 = int2(W_0 - int(1), H_0 - int(1));

#line 15
    }
    float4 _S11 = float4(0.0f) ;

#line 16
    int j_0 = int(-1);

#line 16
    float4 box_0 = _S11;
    for(;;)
    {

#line 17
        if(j_0 <= int(1))
        {
        }
        else
        {

#line 17
            break;
        }

#line 17
        int i_1 = int(-1);

#line 17
        for(;;)
        {

#line 17
            if(i_1 <= int(1))
            {
            }
            else
            {

#line 17
                break;
            }

#line 17
            float4 _S12 = read0_0(clamp(_S7 + int2(i_1, j_0), _S9, _S10), &kernelContext_4);

#line 17
            float4 box_1 = box_0 + _S12;

#line 17
            i_1 = i_1 + int(1);

#line 17
            box_0 = box_1;

#line 17
        }

#line 17
        j_0 = j_0 + int(1);

#line 17
    }

#line 17
    float4 _S13 = read0_0(_S7, &kernelContext_4);

    float4 _S14 = max(_S13 + float4((&kernelContext_4)->u_0->a_0.x)  * (_S13 - box_0 / float4(9.0f) ), _S11);

#line 19
    thread float4 o_0 = _S14;
    o_0.w = min(_S14.w, 1.0f);
    (&kernelContext_4)->out0_0.write(o_0,_S6);
    return;
}


#line 40 "crates/sq-gpu/shaders-src/Bindings.slang"
uint2 outSize_0(KernelContext_0 thread* kernelContext_5)
{

#line 40
    texture2d<float, access::write> _S15 = kernelContext_5->out0_0;

#line 40
    thread uint w_2;

#line 40
    thread uint h_2;

#line 40
    (*((&w_2)) = (_S15).get_width(0)),(*((&h_2)) = (_S15).get_height(0));

#line 40
    return uint2(w_2, h_2);
}


#line 25 "crates/sq-gpu/shaders-src/Filters.slang"
[[kernel]] void filterDirectionalBlur(uint3 tid_1 [[thread_position_in_grid]], texture2d<float, access::sample> in0_2 [[texture(0)]], FilterU_0 constant* u_2 [[buffer(0)]], texture2d<float, access::write> out0_2 [[texture(25)]], sampler zeroSampler_2 [[sampler(0)]], texture2d<float, access::sample> in1_2 [[texture(1)]], sampler edgeSampler_2 [[sampler(1)]])
{

#line 25
    thread KernelContext_0 kernelContext_6;

#line 25
    (&kernelContext_6)->in0_0 = in0_2;

#line 25
    (&kernelContext_6)->u_0 = u_2;

#line 25
    (&kernelContext_6)->out0_0 = out0_2;

#line 25
    (&kernelContext_6)->zeroSampler_0 = zeroSampler_2;

#line 25
    (&kernelContext_6)->in1_0 = in1_2;

#line 25
    (&kernelContext_6)->edgeSampler_0 = edgeSampler_2;

#line 25
    uint2 _S16 = outSize_0(&kernelContext_6);

#line 25
    bool _S17;

    if((tid_1.x) >= (_S16.x))
    {

#line 27
        _S17 = true;

#line 27
    }
    else
    {

#line 27
        _S17 = (tid_1.y) >= (_S16.y);

#line 27
    }

#line 27
    if(_S17)
    {

#line 27
        return;
    }

#line 28
    float2 _S18 = float2(_S16);
    uint2 _S19 = tid_1.xy;

#line 29
    float2 _S20 = float2(_S19) + float2(0.5f) ;
    int n_0 = (&kernelContext_6)->u_0->i_0.x;
    float4 _S21 = float4(0.0f) ;

#line 31
    int k_0 = int(0);

#line 31
    float4 acc_0 = _S21;
    for(;;)
    {

#line 32
        if(k_0 < n_0)
        {
        }
        else
        {

#line 32
            break;
        }

#line 32
        float4 acc_1 = acc_0 + (((&kernelContext_6)->in0_0).sample(((&kernelContext_6)->zeroSampler_0), ((_S20 + (&kernelContext_6)->u_0->a_0.xy * float2((float(k_0) / float(n_0 - int(1)) - 0.5f)) ) / _S18), level((0.0f))));

#line 32
        k_0 = k_0 + int(1);

#line 32
        acc_0 = acc_1;

#line 32
    }
    (&kernelContext_6)->out0_0.write(acc_0 / float4(float(n_0)) ,_S19);
    return;
}


[[kernel]] void filterSmearComb(uint3 tid_2 [[thread_position_in_grid]], texture2d<float, access::sample> in0_3 [[texture(0)]], FilterU_0 constant* u_3 [[buffer(0)]], texture2d<float, access::write> out0_3 [[texture(25)]], sampler zeroSampler_3 [[sampler(0)]], texture2d<float, access::sample> in1_3 [[texture(1)]], sampler edgeSampler_3 [[sampler(1)]])
{

#line 38
    thread KernelContext_0 kernelContext_7;

#line 38
    (&kernelContext_7)->in0_0 = in0_3;

#line 38
    (&kernelContext_7)->u_0 = u_3;

#line 38
    (&kernelContext_7)->out0_0 = out0_3;

#line 38
    (&kernelContext_7)->zeroSampler_0 = zeroSampler_3;

#line 38
    (&kernelContext_7)->in1_0 = in1_3;

#line 38
    (&kernelContext_7)->edgeSampler_0 = edgeSampler_3;

#line 38
    uint2 _S22 = outSize_0(&kernelContext_7);

#line 38
    bool _S23;

    if((tid_2.x) >= (_S22.x))
    {

#line 40
        _S23 = true;

#line 40
    }
    else
    {

#line 40
        _S23 = (tid_2.y) >= (_S22.y);

#line 40
    }

#line 40
    if(_S23)
    {

#line 40
        return;
    }

#line 40
    uint2 _S24 = inSize_0(&kernelContext_7);
    float2 _S25 = float2(_S24);
    uint2 _S26 = tid_2.xy;
    int n_1 = (&kernelContext_7)->u_0->i_0.x;
    float2 _S27 = float2(_S26) + float2(0.5f)  + (&kernelContext_7)->u_0->b_0.xy - (&kernelContext_7)->u_0->a_0.xy * float2((0.5f * float(n_1 - int(1)))) ;
    float4 _S28 = float4(0.0f) ;

#line 45
    int k_1 = int(0);

#line 45
    float4 acc_2 = _S28;
    for(;;)
    {

#line 46
        if(k_1 < n_1)
        {
        }
        else
        {

#line 46
            break;
        }

#line 46
        float4 acc_3 = acc_2 + (((&kernelContext_7)->in0_0).sample(((&kernelContext_7)->zeroSampler_0), ((_S27 + (&kernelContext_7)->u_0->a_0.xy * float2(float(k_1)) ) / _S25), level((0.0f))));

#line 46
        k_1 = k_1 + int(1);

#line 46
        acc_2 = acc_3;

#line 46
    }
    (&kernelContext_7)->out0_0.write(acc_2 / float4(float(n_1)) ,_S26);
    return;
}

[[kernel]] void filterMirror(uint3 tid_3 [[thread_position_in_grid]], texture2d<float, access::sample> in0_4 [[texture(0)]], FilterU_0 constant* u_4 [[buffer(0)]], texture2d<float, access::write> out0_4 [[texture(25)]], sampler zeroSampler_4 [[sampler(0)]], texture2d<float, access::sample> in1_4 [[texture(1)]], sampler edgeSampler_4 [[sampler(1)]])
{

#line 51
    thread KernelContext_0 kernelContext_8;

#line 51
    (&kernelContext_8)->in0_0 = in0_4;

#line 51
    (&kernelContext_8)->u_0 = u_4;

#line 51
    (&kernelContext_8)->out0_0 = out0_4;

#line 51
    (&kernelContext_8)->zeroSampler_0 = zeroSampler_4;

#line 51
    (&kernelContext_8)->in1_0 = in1_4;

#line 51
    (&kernelContext_8)->edgeSampler_0 = edgeSampler_4;

#line 51
    uint2 _S29 = outSize_0(&kernelContext_8);

#line 51
    bool _S30;

    if((tid_3.x) >= (_S29.x))
    {

#line 53
        _S30 = true;

#line 53
    }
    else
    {

#line 53
        _S30 = (tid_3.y) >= (_S29.y);

#line 53
    }

#line 53
    if(_S30)
    {

#line 53
        return;
    }

#line 54
    float2 _S31 = float2(_S29);
    uint2 _S32 = tid_3.xy;

#line 55
    float2 q_0 = float2(_S32) + float2(0.5f) ;
    float d_1 = dot(q_0 - (&kernelContext_8)->u_0->center_0, (&kernelContext_8)->u_0->a_0.xy);

#line 56
    float2 q_1;
    if(d_1 > 0.0f)
    {

#line 57
        q_1 = q_0 - float2((2.0f * d_1))  * (&kernelContext_8)->u_0->a_0.xy;

#line 57
    }
    else
    {

#line 57
        q_1 = q_0;

#line 57
    }
    (&kernelContext_8)->out0_0.write((((&kernelContext_8)->in0_0).sample(((&kernelContext_8)->zeroSampler_0), (q_1 / _S31), level((0.0f)))),_S32);
    return;
}


#line 61
float hash01_0(uint x_0, uint y_0, uint seed_0, uint ch_0)
{
    uint h_3 = (x_0 * 1973U + y_0 * 9277U + seed_0 * 26699U + ch_0 * 104729U) * 747796405U + 2891336453U;
    uint w_3 = ((h_3 >> ((h_3 >> 28U) + 4U)) ^ h_3) * 277803737U;

    return float(((w_3 >> 22U) ^ w_3) >> 8U) / 1.6777216e+07f;
}



[[kernel]] void filterNoise(uint3 tid_4 [[thread_position_in_grid]], texture2d<float, access::sample> in0_5 [[texture(0)]], FilterU_0 constant* u_5 [[buffer(0)]], texture2d<float, access::write> out0_5 [[texture(25)]], sampler zeroSampler_5 [[sampler(0)]], texture2d<float, access::sample> in1_5 [[texture(1)]], sampler edgeSampler_5 [[sampler(1)]])
{

#line 71
    thread KernelContext_0 kernelContext_9;

#line 71
    (&kernelContext_9)->in0_0 = in0_5;

#line 71
    (&kernelContext_9)->u_0 = u_5;

#line 71
    (&kernelContext_9)->out0_0 = out0_5;

#line 71
    (&kernelContext_9)->zeroSampler_0 = zeroSampler_5;

#line 71
    (&kernelContext_9)->in1_0 = in1_5;

#line 71
    (&kernelContext_9)->edgeSampler_0 = edgeSampler_5;

#line 71
    uint2 _S33 = outSize_0(&kernelContext_9);

    uint _S34 = tid_4.x;

#line 73
    bool _S35;

#line 73
    if(_S34 >= (_S33.x))
    {

#line 73
        _S35 = true;

#line 73
    }
    else
    {

#line 73
        _S35 = (tid_4.y) >= (_S33.y);

#line 73
    }

#line 73
    if(_S35)
    {

#line 73
        return;
    }

#line 74
    uint2 _S36 = tid_4.xy;

#line 74
    float4 _S37 = read0_0(int2(_S36), &kernelContext_9);

#line 74
    thread float4 o_1 = _S37;
    uint _S38 = (as_type<uint>(((&kernelContext_9)->u_0->i_0.z)));

#line 75
    uint c_1 = 0U;
    for(;;)
    {

#line 76
        if(c_1 < 3U)
        {
        }
        else
        {

#line 76
            break;
        }

#line 76
        uint _S39 = c_1;
        float _S40 = (&kernelContext_9)->u_0->a_0.x;

#line 77
        uint _S41 = tid_4.y;

#line 77
        uint _S42;

#line 77
        if(((&kernelContext_9)->u_0->i_0.x) != int(0))
        {

#line 77
            _S42 = c_1;

#line 77
        }
        else
        {

#line 77
            _S42 = 0U;

#line 77
        }

#line 77
        float _S43 = _S37.w;

#line 77
        float v_0 = _S37[_S39] + _S40 * (hash01_0(_S34, _S41, _S38, _S42) - 0.5f) * _S43;

#line 77
        float _S44;
        if(((&kernelContext_9)->u_0->i_0.y) != int(0))
        {

#line 78
            _S44 = clamp(v_0, 0.0f, max(_S43, _S37[_S39]));

#line 78
        }
        else
        {

#line 78
            _S44 = max(v_0, 0.0f);

#line 78
        }

#line 78
        o_1[c_1] = _S44;

#line 76
        c_1 = c_1 + 1U;

#line 76
    }



    (&kernelContext_9)->out0_0.write(o_1,_S36);
    return;
}

int2 blockRange_0(float o_2, float bs_0, int b_1, int limit_0)
{
    return clamp(int2(int(ceil(o_2 + float(b_1) * bs_0 - 0.5f)), int(ceil(o_2 + float(b_1 + int(1)) * bs_0 - 0.5f))), int2(int(0)) , int2(limit_0) );
}


#line 94
[[kernel]] void filterMosaicRows(uint3 tid_5 [[thread_position_in_grid]], texture2d<float, access::sample> in0_6 [[texture(0)]], FilterU_0 constant* u_6 [[buffer(0)]], texture2d<float, access::write> out0_6 [[texture(25)]], sampler zeroSampler_6 [[sampler(0)]], texture2d<float, access::sample> in1_6 [[texture(1)]], sampler edgeSampler_6 [[sampler(1)]])
{

#line 94
    int _S45;

#line 94
    thread KernelContext_0 kernelContext_10;

#line 94
    (&kernelContext_10)->in0_0 = in0_6;

#line 94
    (&kernelContext_10)->u_0 = u_6;

#line 94
    (&kernelContext_10)->out0_0 = out0_6;

#line 94
    (&kernelContext_10)->zeroSampler_0 = zeroSampler_6;

#line 94
    (&kernelContext_10)->in1_0 = in1_6;

#line 94
    (&kernelContext_10)->edgeSampler_0 = edgeSampler_6;
    int _S46 = int(tid_5.x);

#line 95
    bool _S47;

#line 95
    if(_S46 >= (u_6->i_0.x))
    {

#line 95
        _S47 = true;

#line 95
    }
    else
    {

#line 95
        uint _S48 = tid_5.y;

#line 95
        uint2 _S49 = outSize_0(&kernelContext_10);

#line 95
        _S47 = _S48 >= (_S49.y);

#line 95
    }

#line 95
    if(_S47)
    {

#line 95
        return;
    }

#line 96
    float o_3 = (&kernelContext_10)->u_0->center_0.x - (&kernelContext_10)->u_0->frame_0.x * 0.5f;

#line 96
    float bw_0 = (&kernelContext_10)->u_0->a_0.x;

#line 96
    uint2 _S50 = inSize_0(&kernelContext_10);
    int2 r_0 = blockRange_0(o_3, bw_0, _S46, int(_S50.x));
    int _S51 = u_6->i_0.w + int(tid_5.y);
    float4 _S52 = float4(0.0f) ;
    int _S53 = r_0.x;

#line 100
    int x_1 = _S53;

#line 100
    float4 acc_4 = _S52;

#line 100
    for(;;)
    {

#line 100
        int _S54 = r_0.y;

#line 100
        _S45 = _S54;

#line 100
        if(x_1 < _S54)
        {
        }
        else
        {

#line 100
            break;
        }

#line 100
        float4 _S55 = read0_0(int2(x_1, _S51), &kernelContext_10);

#line 100
        float4 acc_5 = acc_4 + _S55;

#line 100
        x_1 = x_1 + int(1);

#line 100
        acc_4 = acc_5;

#line 100
    }
    uint2 _S56 = tid_5.xy;

#line 101
    if(_S45 > _S53)
    {

#line 101
        acc_4 = acc_4 / float4(float(_S45 - _S53)) ;

#line 101
    }
    else
    {

#line 101
        acc_4 = _S52;

#line 101
    }

#line 101
    (&kernelContext_10)->out0_0.write(acc_4,_S56);
    return;
}


#line 43 "crates/sq-gpu/shaders-src/Bindings.slang"
float4 read1_0(int2 p_2, KernelContext_0 thread* kernelContext_11)
{

#line 43
    int3 _S57 = int3(p_2, int(0));

#line 43
    return ((kernelContext_11->in1_0).read(vec<uint,2>(((_S57)).xy), uint(((_S57)).z)));
}


#line 107 "crates/sq-gpu/shaders-src/Filters.slang"
[[kernel]] void filterMosaicBlocks(uint3 tid_6 [[thread_position_in_grid]], texture2d<float, access::sample> in0_7 [[texture(0)]], FilterU_0 constant* u_7 [[buffer(0)]], texture2d<float, access::write> out0_7 [[texture(25)]], sampler zeroSampler_7 [[sampler(0)]], texture2d<float, access::sample> in1_7 [[texture(1)]], sampler edgeSampler_7 [[sampler(1)]])
{

#line 107
    int _S58;

#line 107
    thread KernelContext_0 kernelContext_12;

#line 107
    (&kernelContext_12)->in0_0 = in0_7;

#line 107
    (&kernelContext_12)->u_0 = u_7;

#line 107
    (&kernelContext_12)->out0_0 = out0_7;

#line 107
    (&kernelContext_12)->zeroSampler_0 = zeroSampler_7;

#line 107
    (&kernelContext_12)->in1_0 = in1_7;

#line 107
    (&kernelContext_12)->edgeSampler_0 = edgeSampler_7;
    int _S59 = int(tid_6.x);

#line 108
    bool inside_1;

#line 108
    if(_S59 >= (u_7->i_0.x))
    {

#line 108
        inside_1 = true;

#line 108
    }
    else
    {

#line 108
        inside_1 = int(tid_6.y) >= (u_7->i_0.y);

#line 108
    }

#line 108
    if(inside_1)
    {

#line 108
        return;
    }

#line 108
    float2 _S60 = float2(0.5f) ;
    float2 o_4 = (&kernelContext_12)->u_0->center_0 - (&kernelContext_12)->u_0->frame_0 * _S60;

#line 109
    float2 bs_1 = (&kernelContext_12)->u_0->a_0.xy;

#line 109
    uint2 _S61 = inSize_0(&kernelContext_12);

    int W_1 = int(_S61.x);

#line 111
    int H_1 = int(_S61.y);
    int2 rx_0 = blockRange_0(o_4.x, bs_1.x, _S59, W_1);

#line 112
    int2 ry_0 = blockRange_0(o_4.y, bs_1.y, int(tid_6.y), H_1);
    if((u_7->i_0.z) != int(0))
    {

#line 113
        inside_1 = true;

#line 113
    }
    else
    {

#line 113
        inside_1 = (rx_0.y) <= (rx_0.x);

#line 113
    }

#line 113
    if(inside_1)
    {

#line 113
        inside_1 = true;

#line 113
    }
    else
    {

#line 113
        inside_1 = (ry_0.y) <= (ry_0.x);

#line 113
    }

#line 113
    float4 acc_6;

#line 113
    if(inside_1)
    {

#line 114
        uint2 _S62 = tid_6.xy;

#line 114
        int2 _S63 = int2(floor(o_4 + (float2(_S62) + _S60) * bs_1));
        int _S64 = _S63.x;

#line 115
        if(_S64 >= int(0))
        {

#line 115
            inside_1 = (_S63.y) >= int(0);

#line 115
        }
        else
        {

#line 115
            inside_1 = false;

#line 115
        }

#line 115
        if(inside_1)
        {

#line 115
            inside_1 = _S64 < W_1;

#line 115
        }
        else
        {

#line 115
            inside_1 = false;

#line 115
        }

#line 115
        if(inside_1)
        {

#line 115
            inside_1 = (_S63.y) < H_1;

#line 115
        }
        else
        {

#line 115
            inside_1 = false;

#line 115
        }
        if(inside_1)
        {

#line 116
            float4 _S65 = read0_0(_S63, &kernelContext_12);

#line 116
            acc_6 = _S65;

#line 116
        }
        else
        {

#line 116
            acc_6 = float4(0.0f) ;

#line 116
        }

#line 116
        (&kernelContext_12)->out0_0.write(acc_6,_S62);
        return;
    }
    float4 _S66 = float4(0.0f) ;
    int _S67 = ry_0.x;

#line 120
    int y_1 = _S67;

#line 120
    acc_6 = _S66;

#line 120
    for(;;)
    {

#line 120
        int _S68 = ry_0.y;

#line 120
        _S58 = _S68;

#line 120
        if(y_1 < _S68)
        {
        }
        else
        {

#line 120
            break;
        }

#line 120
        float4 _S69 = read1_0(int2(_S59, y_1 - u_7->i_0.w), &kernelContext_12);

#line 120
        float4 acc_7 = acc_6 + _S69;

#line 120
        y_1 = y_1 + int(1);

#line 120
        acc_6 = acc_7;

#line 120
    }
    (&kernelContext_12)->out0_0.write(acc_6 / float4(float(_S58 - _S67)) ,tid_6.xy);
    return;
}


[[kernel]] void filterMosaicApply(uint3 tid_7 [[thread_position_in_grid]], texture2d<float, access::sample> in0_8 [[texture(0)]], FilterU_0 constant* u_8 [[buffer(0)]], texture2d<float, access::write> out0_8 [[texture(25)]], sampler zeroSampler_8 [[sampler(0)]], texture2d<float, access::sample> in1_8 [[texture(1)]], sampler edgeSampler_8 [[sampler(1)]])
{

#line 126
    thread KernelContext_0 kernelContext_13;

#line 126
    (&kernelContext_13)->in0_0 = in0_8;

#line 126
    (&kernelContext_13)->u_0 = u_8;

#line 126
    (&kernelContext_13)->out0_0 = out0_8;

#line 126
    (&kernelContext_13)->zeroSampler_0 = zeroSampler_8;

#line 126
    (&kernelContext_13)->in1_0 = in1_8;

#line 126
    (&kernelContext_13)->edgeSampler_0 = edgeSampler_8;

#line 126
    uint2 _S70 = outSize_0(&kernelContext_13);

#line 126
    bool _S71;

    if((tid_7.x) >= (_S70.x))
    {

#line 128
        _S71 = true;

#line 128
    }
    else
    {

#line 128
        _S71 = (tid_7.y) >= (_S70.y);

#line 128
    }

#line 128
    if(_S71)
    {

#line 128
        return;
    }

#line 129
    uint2 _S72 = tid_7.xy;

#line 129
    float2 _S73 = float2(0.5f) ;

#line 129
    float2 q_2 = float2(_S72) + _S73 - ((&kernelContext_13)->u_0->center_0 - (&kernelContext_13)->u_0->frame_0 * _S73);
    float _S74 = q_2.x;

#line 130
    if(_S74 < 0.0f)
    {

#line 130
        _S71 = true;

#line 130
    }
    else
    {

#line 130
        _S71 = (q_2.y) < 0.0f;

#line 130
    }

#line 130
    if(_S71)
    {

#line 130
        _S71 = true;

#line 130
    }
    else
    {

#line 130
        _S71 = _S74 >= ((&kernelContext_13)->u_0->frame_0.x);

#line 130
    }

#line 130
    if(_S71)
    {

#line 130
        _S71 = true;

#line 130
    }
    else
    {

#line 130
        _S71 = (q_2.y) >= ((&kernelContext_13)->u_0->frame_0.y);

#line 130
    }

#line 130
    if(_S71)
    {

#line 130
        float4 _S75 = read0_0(int2(_S72), &kernelContext_13);

#line 130
        (&kernelContext_13)->out0_0.write(_S75,_S72);

#line 130
        return;
    }

#line 131
    float2 bs_2 = (&kernelContext_13)->u_0->a_0.xy;
    thread int2 b_2 = int2(q_2 / bs_2);

#line 132
    int c_2 = int(0);

    for(;;)
    {

#line 134
        if(c_2 < int(2))
        {
        }
        else
        {

#line 134
            break;
        }

#line 134
        int _S76 = c_2;

#line 134
        int _S77 = c_2;
        if((float(b_2[c_2]) * bs_2[c_2]) > (q_2[c_2]))
        {

#line 135
            b_2[c_2] = b_2[c_2] - int(1);

#line 135
        }
        else
        {

#line 136
            if((float(b_2[c_2] + int(1)) * bs_2[_S76]) <= (q_2[_S77]))
            {

#line 136
                b_2[c_2] = b_2[c_2] + int(1);

#line 136
            }

#line 135
        }

#line 134
        c_2 = c_2 + int(1);

#line 134
    }



    int2 _S78 = min(b_2, (&kernelContext_13)->u_0->i_0.xy - int2(int(1)) );

#line 138
    b_2 = _S78;

#line 138
    float4 _S79 = read1_0(_S78, &kernelContext_13);
    (&kernelContext_13)->out0_0.write(_S79,_S72);
    return;
}




[[kernel]] void filterUnsharp(uint3 tid_8 [[thread_position_in_grid]], texture2d<float, access::sample> in0_9 [[texture(0)]], FilterU_0 constant* u_9 [[buffer(0)]], texture2d<float, access::write> out0_9 [[texture(25)]], sampler zeroSampler_9 [[sampler(0)]], texture2d<float, access::sample> in1_9 [[texture(1)]], sampler edgeSampler_9 [[sampler(1)]])
{

#line 146
    thread KernelContext_0 kernelContext_14;

#line 146
    (&kernelContext_14)->in0_0 = in0_9;

#line 146
    (&kernelContext_14)->u_0 = u_9;

#line 146
    (&kernelContext_14)->out0_0 = out0_9;

#line 146
    (&kernelContext_14)->zeroSampler_0 = zeroSampler_9;

#line 146
    (&kernelContext_14)->in1_0 = in1_9;

#line 146
    (&kernelContext_14)->edgeSampler_0 = edgeSampler_9;

#line 146
    uint2 _S80 = inSize_0(&kernelContext_14);

#line 146
    bool inside_2;

    if((tid_8.x) >= (_S80.x))
    {

#line 148
        inside_2 = true;

#line 148
    }
    else
    {

#line 148
        inside_2 = (tid_8.y) >= (_S80.y);

#line 148
    }

#line 148
    if(inside_2)
    {

#line 148
        return;
    }

#line 149
    uint2 _S81 = tid_8.xy;

#line 149
    int2 _S82 = int2(_S81);

#line 149
    float4 _S83 = read0_0(_S82, &kernelContext_14);
    thread float4 p_3 = _S83;
    int _S84 = _S82.x;

#line 151
    if(_S84 >= ((&kernelContext_14)->u_0->i_0.x))
    {

#line 151
        inside_2 = (_S82.y) >= ((&kernelContext_14)->u_0->i_0.y);

#line 151
    }
    else
    {

#line 151
        inside_2 = false;

#line 151
    }

#line 151
    if(inside_2)
    {

#line 151
        inside_2 = _S84 <= ((&kernelContext_14)->u_0->i_0.z);

#line 151
    }
    else
    {

#line 151
        inside_2 = false;

#line 151
    }

#line 151
    if(inside_2)
    {

#line 151
        inside_2 = (_S82.y) <= ((&kernelContext_14)->u_0->i_0.w);

#line 151
    }
    else
    {

#line 151
        inside_2 = false;

#line 151
    }

#line 151
    float4 _S85 = read1_0(_S82, &kernelContext_14);
    float4 d_2 = p_3 - _S85;
    if(inside_2)
    {

#line 153
        inside_2 = (max(max(abs(d_2.x), abs(d_2.y)), abs(d_2.z))) > ((&kernelContext_14)->u_0->a_0.y);

#line 153
    }
    else
    {

#line 153
        inside_2 = false;

#line 153
    }

#line 153
    if(inside_2)
    {

#line 154
        float4 _S86 = max(p_3 + float4((&kernelContext_14)->u_0->a_0.x)  * d_2, float4(0.0f) );

#line 154
        p_3 = _S86;
        p_3.w = min(_S86.w, 1.0f);

#line 153
    }



    (&kernelContext_14)->out0_0.write(p_3,_S81);
    return;
}



float4 glowBright_0(float4 p_4, KernelContext_0 thread* kernelContext_15)
{

#line 164
    float _S87 = p_4.w;

#line 164
    if(_S87 <= 0.0f)
    {

#line 164
        return float4(0.0f) ;
    }

#line 164
    float3 _S88 = float3(_S87) ;

    float w_4 = clamp((dot(p_4.xyz / _S88, float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f)) - kernelContext_15->u_0->a_0.x) / max(1.0f - kernelContext_15->u_0->a_0.x, 0.0010000000474974513f), 0.0f, 1.0f);

#line 166
    float4 _S89;
    if((kernelContext_15->u_0->i_0.x) != int(0))
    {

#line 167
        _S89 = float4(kernelContext_15->u_0->b_0.xyz * _S88, _S87);

#line 167
    }
    else
    {

#line 167
        _S89 = p_4;

#line 167
    }

#line 167
    return _S89 * float4(w_4) ;
}


[[kernel]] void filterGlowBright(uint3 tid_9 [[thread_position_in_grid]], texture2d<float, access::sample> in0_10 [[texture(0)]], FilterU_0 constant* u_10 [[buffer(0)]], texture2d<float, access::write> out0_10 [[texture(25)]], sampler zeroSampler_10 [[sampler(0)]], texture2d<float, access::sample> in1_10 [[texture(1)]], sampler edgeSampler_10 [[sampler(1)]])
{

#line 171
    thread KernelContext_0 kernelContext_16;

#line 171
    (&kernelContext_16)->in0_0 = in0_10;

#line 171
    (&kernelContext_16)->u_0 = u_10;

#line 171
    (&kernelContext_16)->out0_0 = out0_10;

#line 171
    (&kernelContext_16)->zeroSampler_0 = zeroSampler_10;

#line 171
    (&kernelContext_16)->in1_0 = in1_10;

#line 171
    (&kernelContext_16)->edgeSampler_0 = edgeSampler_10;

#line 171
    uint2 _S90 = outSize_0(&kernelContext_16);

#line 171
    uint2 _S91 = inSize_0(&kernelContext_16);

#line 171
    bool _S92;

    if((tid_9.x) >= (_S90.x))
    {

#line 173
        _S92 = true;

#line 173
    }
    else
    {

#line 173
        _S92 = (tid_9.y) >= (_S90.y);

#line 173
    }

#line 173
    if(_S92)
    {

#line 173
        return;
    }

#line 174
    int _S93 = max((&kernelContext_16)->u_0->i_0.y, int(1));

#line 174
    int _S94 = int(_S91.x);

#line 174
    int _S95 = int(_S91.y);
    uint2 _S96 = tid_9.xy;

#line 175
    int2 _S97 = int2(_S96) * int2(_S93) ;
    float4 _S98 = float4(0.0f) ;

#line 176
    int j_1 = int(0);

#line 176
    float4 acc_8 = _S98;
    for(;;)
    {

#line 177
        if(j_1 < _S93)
        {
        }
        else
        {

#line 177
            break;
        }

#line 177
        int i_2 = int(0);

#line 177
        float4 acc_9 = acc_8;

#line 177
        for(;;)
        {

#line 177
            if(i_2 < _S93)
            {
            }
            else
            {

#line 177
                break;
            }

#line 178
            int2 p_5 = _S97 + int2(i_2, j_1);
            if((p_5.x) < _S94)
            {

#line 179
                _S92 = (p_5.y) < _S95;

#line 179
            }
            else
            {

#line 179
                _S92 = false;

#line 179
            }

#line 179
            if(_S92)
            {

#line 179
                float4 _S99 = read0_0(p_5, &kernelContext_16);

#line 179
                float4 _S100 = glowBright_0(_S99, &kernelContext_16);

#line 179
                acc_9 = acc_9 + _S100;

#line 179
            }

#line 177
            i_2 = i_2 + int(1);

#line 177
        }

#line 177
        j_1 = j_1 + int(1);

#line 177
        acc_8 = acc_9;

#line 177
    }



    (&kernelContext_16)->out0_0.write(acc_8 / float4(float(_S93 * _S93)) ,_S96);
    return;
}


[[kernel]] void filterGlowAdd(uint3 tid_10 [[thread_position_in_grid]], texture2d<float, access::sample> in0_11 [[texture(0)]], FilterU_0 constant* u_11 [[buffer(0)]], texture2d<float, access::write> out0_11 [[texture(25)]], sampler zeroSampler_11 [[sampler(0)]], texture2d<float, access::sample> in1_11 [[texture(1)]], sampler edgeSampler_11 [[sampler(1)]])
{

#line 186
    thread KernelContext_0 kernelContext_17;

#line 186
    (&kernelContext_17)->in0_0 = in0_11;

#line 186
    (&kernelContext_17)->u_0 = u_11;

#line 186
    (&kernelContext_17)->out0_0 = out0_11;

#line 186
    (&kernelContext_17)->zeroSampler_0 = zeroSampler_11;

#line 186
    (&kernelContext_17)->in1_0 = in1_11;

#line 186
    (&kernelContext_17)->edgeSampler_0 = edgeSampler_11;

#line 186
    uint2 _S101 = outSize_0(&kernelContext_17);

#line 186
    bool _S102;

    if((tid_10.x) >= (_S101.x))
    {

#line 188
        _S102 = true;

#line 188
    }
    else
    {

#line 188
        _S102 = (tid_10.y) >= (_S101.y);

#line 188
    }

#line 188
    if(_S102)
    {

#line 188
        return;
    }

#line 188
    texture2d<float, access::sample> _S103 = (&kernelContext_17)->in1_0;
    thread uint gw_0;

#line 189
    thread uint gh_0;
    (*((&gw_0)) = (_S103).get_width(0)),(*((&gh_0)) = (_S103).get_height(0));

    uint2 _S104 = tid_10.xy;

#line 192
    float4 g_0 = (((&kernelContext_17)->in1_0).sample(((&kernelContext_17)->edgeSampler_0), ((float2(_S104) + float2(0.5f) ) / (float2(float(gw_0), float(gh_0)) * float2(float(max((&kernelContext_17)->u_0->i_0.y, int(1)))) )), level((0.0f)))) * float4((&kernelContext_17)->u_0->a_0.y) ;

#line 192
    float4 _S105 = read0_0(int2(_S104), &kernelContext_17);

    float _S106 = _S105.w;

#line 194
    (&kernelContext_17)->out0_0.write(float4(_S105.xyz + g_0.xyz, min(1.0f, _S106 + g_0.w * (1.0f - _S106))),_S104);
    return;
}


#line 6 "crates/sq-gpu/shaders-src/Parts/Style.slang"
float sqSmooth_0(float a_1, float b_3, float x_2)
{

#line 6
    float t_0 = clamp((x_2 - a_1) / (b_3 - a_1), 0.0f, 1.0f);

#line 6
    return t_0 * t_0 * (3.0f - 2.0f * t_0);
}


#line 8
float vignetteFalloff_0(float2 q_3, KernelContext_0 thread* kernelContext_18)
{

#line 9
    float2 d_3 = q_3 - kernelContext_18->u_0->center_0;
    float2 e_0 = d_3 / (kernelContext_18->u_0->frame_0 * float2(0.5f) );
    float2 circle_0 = d_3 / float2((sqrt(kernelContext_18->u_0->frame_0.x * kernelContext_18->u_0->frame_0.y) * 0.5f)) ;

#line 11
    float r_1;

    if((kernelContext_18->u_0->a_0.z) >= 0.0f)
    {

#line 13
        r_1 = length(e_0 + (circle_0 - e_0) * float2(kernelContext_18->u_0->a_0.z) );

#line 13
    }
    else
    {

#line 14
        float n_2 = 2.0f + 8.0f * - kernelContext_18->u_0->a_0.z;

#line 14
        r_1 = pow(pow(abs(e_0.x), n_2) + pow(abs(e_0.y), n_2), 1.0f / n_2);

#line 13
    }

    float m_0 = 0.34999999403953552f + 0.89999997615814209f * kernelContext_18->u_0->a_0.y;

#line 15
    float w_5 = 0.05000000074505806f + 0.60000002384185791f * kernelContext_18->u_0->a_0.w;
    return sqSmooth_0(m_0 - w_5, m_0 + w_5, r_1);
}


#line 4
float sqEnc_0(float x_3)
{

#line 4
    float _S107 = max(x_3, 0.0f);

#line 4
    float _S108;

#line 4
    if(_S107 < 0.018053967505693436f)
    {

#line 4
        _S108 = _S107 * 4.5f;

#line 4
    }
    else
    {

#line 4
        _S108 = 1.0992968082427979f * pow(_S107, 0.44999998807907104f) - 0.099296823143959045f;

#line 4
    }

#line 4
    return _S108;
}


#line 19
float sqHalftone_0(float2 q_4, float y_2, KernelContext_0 thread* kernelContext_19)
{

#line 20
    float2 d_4 = q_4 - kernelContext_19->u_0->center_0;

#line 20
    float c_3 = cos(kernelContext_19->u_0->a_0.y);

#line 20
    float s_0 = sin(kernelContext_19->u_0->a_0.y);
    float _S109 = d_4.x;

#line 21
    float _S110 = d_4.y;

#line 21
    float2 r_2 = float2(c_3 * _S109 + s_0 * _S110, - s_0 * _S109 + c_3 * _S110) / float2(kernelContext_19->u_0->a_0.x) ;

    float rn_0 = length(r_2 - floor(r_2) - float2(0.5f) ) / 0.70710676908493042f;
    float soft_0 = 0.019999999552965164f + 0.30000001192092896f * kernelContext_19->u_0->a_0.z;
    bool color_0 = (kernelContext_19->u_0->i_0.x) != int(0);

#line 25
    float _S111;
    if(color_0)
    {

#line 26
        _S111 = y_2;

#line 26
    }
    else
    {

#line 26
        _S111 = 1.0f - y_2;

#line 26
    }

#line 26
    float rho_0 = sqrt(_S111) * (1.0f + 2.0f * soft_0) - soft_0;
    float edge_0 = sqSmooth_0(rho_0 - soft_0, rho_0 + soft_0, rn_0);
    if(color_0)
    {

#line 28
        _S111 = 1.0f - edge_0;

#line 28
    }
    else
    {

#line 28
        _S111 = edge_0;

#line 28
    }

#line 28
    return _S111;
}


#line 5
float sqDec_0(float e_1)
{

#line 5
    float _S112 = max(e_1, 0.0f);

#line 5
    float _S113;

#line 5
    if(_S112 < 0.081242859363555908f)
    {

#line 5
        _S113 = _S112 / 4.5f;

#line 5
    }
    else
    {

#line 5
        _S113 = pow((_S112 + 0.099296823143959045f) / 1.0992968082427979f, 2.2222223281860352f);

#line 5
    }

#line 5
    return _S113;
}


#line 32
[[kernel]] void filterStylePixel(uint3 tid_11 [[thread_position_in_grid]], texture2d<float, access::sample> in0_12 [[texture(0)]], FilterU_0 constant* u_12 [[buffer(0)]], texture2d<float, access::write> out0_12 [[texture(25)]], sampler zeroSampler_12 [[sampler(0)]], texture2d<float, access::sample> in1_12 [[texture(1)]], sampler edgeSampler_12 [[sampler(1)]])
{

#line 32
    thread KernelContext_0 kernelContext_20;

#line 32
    (&kernelContext_20)->in0_0 = in0_12;

#line 32
    (&kernelContext_20)->u_0 = u_12;

#line 32
    (&kernelContext_20)->out0_0 = out0_12;

#line 32
    (&kernelContext_20)->zeroSampler_0 = zeroSampler_12;

#line 32
    (&kernelContext_20)->in1_0 = in1_12;

#line 32
    (&kernelContext_20)->edgeSampler_0 = edgeSampler_12;

#line 32
    uint2 _S114 = outSize_0(&kernelContext_20);

#line 32
    bool _S115;

    if((tid_11.x) >= (_S114.x))
    {

#line 34
        _S115 = true;

#line 34
    }
    else
    {

#line 34
        _S115 = (tid_11.y) >= (_S114.y);

#line 34
    }

#line 34
    if(_S115)
    {

#line 34
        return;
    }

#line 35
    uint2 _S116 = tid_11.xy;

#line 35
    float4 _S117 = read0_0(int2(_S116), &kernelContext_20);

#line 35
    float2 _S118 = float2(0.5f) ;
    float2 q_5 = float2(_S116) + _S118;
    int op_0 = (&kernelContext_20)->u_0->i_0.w;
    bool _S119 = op_0 == int(1);

#line 38
    if(_S119)
    {

#line 38
        _S115 = ((&kernelContext_20)->u_0->a_0.x) < 0.0f;

#line 38
    }
    else
    {

#line 38
        _S115 = false;

#line 38
    }

#line 38
    if(_S115)
    {

#line 38
        float _S120 = (&kernelContext_20)->u_0->a_0.x;

#line 38
        float _S121 = vignetteFalloff_0(q_5, &kernelContext_20);

#line 38
        (&kernelContext_20)->out0_0.write(float4(_S117.xyz * float3(exp2(_S120 * _S121)) , _S117.w),_S116);

#line 38
        return;
    }

#line 39
    if(op_0 == int(12))
    {

#line 40
        float2 o_5 = (&kernelContext_20)->u_0->center_0 - (&kernelContext_20)->u_0->frame_0 * _S118;
        float _S122 = q_5.x;

#line 41
        float _S123 = o_5.x;

#line 41
        float _S124 = q_5.y;

#line 41
        float _S125 = o_5.y;
        (&kernelContext_20)->out0_0.write(_S117 * float4(sqSmooth_0(0.0f, (&kernelContext_20)->u_0->a_0.x, max(min(min(_S122 - _S123, _S123 + (&kernelContext_20)->u_0->frame_0.x - _S122), min(_S124 - _S125, _S125 + (&kernelContext_20)->u_0->frame_0.y - _S124)), 0.0f))) ,_S116);

#line 42
        return;
    }

#line 42
    float3 c_4;

#line 42
    float a_2;

    if(op_0 == int(8))
    {

#line 45
        float _S126 = _S117.w;

#line 45
        if(_S126 > 0.0f)
        {

#line 45
            c_4 = _S117.xyz / float3(_S126) ;

#line 45
        }
        else
        {

#line 45
            c_4 = float3(0.0f) ;

#line 45
        }
        if(((&kernelContext_20)->u_0->i_0.x) != int(0))
        {

#line 46
            a_2 = 1.0f;

#line 46
        }
        else
        {

#line 46
            a_2 = _S126;

#line 46
        }
        if(((&kernelContext_20)->u_0->i_0.y) != int(0))
        {

#line 47
            a_2 = 1.0f - a_2;

#line 47
        }
        float a_3 = a_2 * (&kernelContext_20)->u_0->a_0.x;

#line 48
        float3 col_0;
        if(((&kernelContext_20)->u_0->i_0.z) != int(0))
        {

#line 49
            col_0 = float3(1.0f) ;

#line 49
        }
        else
        {

#line 49
            col_0 = c_4;

#line 49
        }
        (&kernelContext_20)->out0_0.write(float4(col_0 * float3(a_3) , a_3),_S116);

#line 50
        return;
    }
    bool _S127 = op_0 == int(7);

#line 52
    if(_S127)
    {

#line 52
        _S115 = ((&kernelContext_20)->u_0->i_0.y) != int(0);

#line 52
    }
    else
    {

#line 52
        _S115 = false;

#line 52
    }

#line 52
    if(_S115)
    {

#line 52
        (&kernelContext_20)->out0_0.write(_S117 * float4((&kernelContext_20)->u_0->a_0.w) ,_S116);

#line 52
        return;
    }

#line 53
    bool _S128 = op_0 == int(3);

#line 53
    if(_S128)
    {

#line 53
        _S115 = ((&kernelContext_20)->u_0->i_0.x) == int(4);

#line 53
    }
    else
    {

#line 53
        _S115 = false;

#line 53
    }

#line 53
    if(_S115)
    {

#line 54
        float _S129 = _S117.w;

#line 54
        float a_4 = _S129 + (1.0f - _S129 - _S129) * (1.0f - (&kernelContext_20)->u_0->a_0.x);
        if(_S129 > 0.0f)
        {

#line 55
            c_4 = _S117.xyz / float3(_S129) ;

#line 55
        }
        else
        {

#line 55
            c_4 = float3(0.0f) ;

#line 55
        }
        (&kernelContext_20)->out0_0.write(float4(c_4 * float3(a_4) , a_4),_S116);

#line 56
        return;
    }
    float _S130 = _S117.w;

#line 58
    if(_S130 <= 0.0f)
    {

#line 58
        (&kernelContext_20)->out0_0.write(_S117,_S116);

#line 58
        return;
    }

#line 58
    float3 _S131 = float3(_S130) ;
    float3 lin_0 = _S117.xyz / _S131;
    float3 e_2 = float3(sqEnc_0(lin_0.x), sqEnc_0(lin_0.y), sqEnc_0(lin_0.z));

    float3 lw_0 = float3(0.2125999927520752f, 0.71520000696182251f, 0.072200000286102295f);
    if(_S119)
    {

#line 64
        float _S132 = - (&kernelContext_20)->u_0->a_0.x;

#line 64
        float _S133 = vignetteFalloff_0(q_5, &kernelContext_20);
        float3 _S134 = float3(1.0f) ;

#line 65
        c_4 = max(_S134 - (_S134 - min(e_2, _S134)) * float3(exp2(_S132 * _S133)) , e_2);

#line 63
    }
    else
    {
        if(_S128)
        {

#line 67
            float3 _S135 = float3(1.0f) ;

#line 67
            float3 ce_0 = clamp(e_2, float3(0.0f) , _S135);

#line 67
            bool3 pick_0;

            if(((&kernelContext_20)->u_0->i_0.x) == int(0))
            {

#line 69
                pick_0 = bool3(true, true, true);

#line 69
            }
            else
            {

#line 69
                pick_0 = bool3(((&kernelContext_20)->u_0->i_0.x) == int(1), ((&kernelContext_20)->u_0->i_0.x) == int(2), ((&kernelContext_20)->u_0->i_0.x) == int(3));

#line 69
            }
            float3 inv_0 = select(e_2, _S135 - ce_0, pick_0);

#line 70
            c_4 = inv_0 + (e_2 - inv_0) * float3((&kernelContext_20)->u_0->a_0.x) ;

#line 66
        }
        else
        {



            if(op_0 == int(4))
            {

#line 72
                float3 _S136 = float3(((&kernelContext_20)->u_0->a_0.x - 1.0f)) ;

#line 72
                c_4 = round(clamp(e_2, float3(0.0f) , float3(1.0f) ) * _S136) / _S136;

#line 72
            }
            else
            {
                if(op_0 == int(5))
                {

#line 75
                    c_4 = e_2 + ((&kernelContext_20)->u_0->a_0.xyz + ((&kernelContext_20)->u_0->b_0.xyz - (&kernelContext_20)->u_0->a_0.xyz) * float3(clamp(dot(e_2, lw_0), 0.0f, 1.0f))  - e_2) * float3((&kernelContext_20)->u_0->a_0.w) ;

#line 75
                }
                else
                {

                    if(op_0 == int(6))
                    {

#line 79
                        float3 _S137 = float3(0.5f) ;

#line 79
                        c_4 = (e_2 - _S137) * float3((&kernelContext_20)->u_0->a_0.y)  + _S137 + float3(((&kernelContext_20)->u_0->a_0.x * 0.40000000596046448f)) ;

#line 79
                    }
                    else
                    {

#line 81
                        if(op_0 == int(9))
                        {

#line 82
                            float2 d_5 = (q_5 - (&kernelContext_20)->u_0->center_0) / float2((&kernelContext_20)->u_0->b_0.w) ;


                            float3 _S138 = float3(1.0f) ;

#line 85
                            c_4 = e_2 + min(((&kernelContext_20)->u_0->a_0.xyz + ((&kernelContext_20)->u_0->b_0.xyz - (&kernelContext_20)->u_0->a_0.xyz) * float3(clamp(0.5f + 0.5f * dot(d_5, (&kernelContext_20)->u_0->frame_0), 0.0f, 1.0f)) ) * float3(((&kernelContext_20)->u_0->a_0.w * exp(-2.0f * dot(d_5, d_5)))) , _S138) * max(_S138 - e_2, float3(0.0f) );

#line 81
                        }
                        else
                        {



                            if(op_0 == int(10))
                            {

#line 88
                                float2 d_6 = q_5 - (&kernelContext_20)->u_0->center_0;

#line 88
                                float len2_0 = dot((&kernelContext_20)->u_0->frame_0, (&kernelContext_20)->u_0->frame_0);

                                if(len2_0 > 9.999999960041972e-13f)
                                {

#line 90
                                    if(((&kernelContext_20)->u_0->i_0.x) != int(0))
                                    {

#line 90
                                        a_2 = length(d_6) / sqrt(len2_0);

#line 90
                                    }
                                    else
                                    {

#line 90
                                        a_2 = dot(d_6, (&kernelContext_20)->u_0->frame_0) / len2_0;

#line 90
                                    }

#line 90
                                }
                                else
                                {

#line 90
                                    a_2 = 0.0f;

#line 90
                                }

#line 90
                                c_4 = e_2 + ((&kernelContext_20)->u_0->a_0.xyz + ((&kernelContext_20)->u_0->b_0.xyz - (&kernelContext_20)->u_0->a_0.xyz) * float3(clamp(a_2, 0.0f, 1.0f))  - e_2) * float3((&kernelContext_20)->u_0->a_0.w) ;

#line 87
                            }
                            else
                            {



                                if(op_0 == int(11))
                                {

#line 93
                                    float _S139 = sqHalftone_0(q_5, clamp(dot(e_2, lw_0), 0.0f, 1.0f), &kernelContext_20);


                                    if(((&kernelContext_20)->u_0->i_0.x) != int(0))
                                    {

#line 96
                                        c_4 = e_2 * float3(_S139) ;

#line 96
                                    }
                                    else
                                    {

#line 96
                                        c_4 = float3(_S139) ;

#line 96
                                    }

#line 96
                                    c_4 = e_2 + (c_4 - e_2) * float3((&kernelContext_20)->u_0->a_0.w) ;

#line 93
                                }
                                else
                                {

#line 93
                                    float3 _S140;

#line 98
                                    if(_S127)
                                    {

#line 99
                                        float3 s_1 = (&kernelContext_20)->u_0->a_0.xyz;
                                        if(((&kernelContext_20)->u_0->i_0.x) == int(1))
                                        {

#line 100
                                            c_4 = e_2 + s_1;

#line 100
                                        }
                                        else
                                        {

#line 101
                                            if(((&kernelContext_20)->u_0->i_0.x) == int(2))
                                            {

#line 101
                                                c_4 = e_2 * s_1;

#line 101
                                            }
                                            else
                                            {

#line 102
                                                if(((&kernelContext_20)->u_0->i_0.x) == int(3))
                                                {

#line 102
                                                    float3 _S141 = float3(1.0f) ;

#line 102
                                                    c_4 = _S141 - (_S141 - e_2) * (_S141 - s_1);

#line 102
                                                }
                                                else
                                                {

#line 103
                                                    if(((&kernelContext_20)->u_0->i_0.x) == int(4))
                                                    {

#line 103
                                                        c_4 = abs(e_2 - s_1);

#line 103
                                                    }
                                                    else
                                                    {

#line 103
                                                        c_4 = s_1;

#line 103
                                                    }

#line 102
                                                }

#line 101
                                            }

#line 100
                                        }

#line 100
                                        _S140 = c_4 + (e_2 - c_4) * float3((&kernelContext_20)->u_0->a_0.w) ;

#line 98
                                    }
                                    else
                                    {

#line 105
                                        (&kernelContext_20)->out0_0.write(_S117,_S116);

#line 105
                                        return;
                                    }

#line 105
                                    c_4 = _S140;

#line 93
                                }

#line 87
                            }

#line 81
                        }

#line 79
                    }

#line 75
                }

#line 72
            }

#line 66
        }

#line 63
    }

#line 106
    (&kernelContext_20)->out0_0.write(float4(float3(sqDec_0(c_4.x), sqDec_0(c_4.y), sqDec_0(c_4.z)) * _S131, _S130),_S116);
    return;
}


#line 197
float4 sampleZ_0(float2 uv_0, KernelContext_0 thread* kernelContext_21)
{

#line 197
    return ((kernelContext_21->in0_0).sample((kernelContext_21->zeroSampler_0), (uv_0), level((0.0f))));
}


#line 116
float2 sqFoldIntoFrame_0(float2 s_2, KernelContext_0 thread* kernelContext_22)
{

#line 116
    float2 _S142 = float2(0.5f) ;
    float2 lo_0 = kernelContext_22->u_0->center_0 - kernelContext_22->u_0->frame_0 * _S142;
    float2 t_1 = (s_2 - lo_0) / kernelContext_22->u_0->frame_0;

#line 118
    float2 _S143 = float2(2.0f) ;
    float2 m_1 = t_1 - _S143 * floor(t_1 / _S143);
    float _S144 = m_1.x;

#line 120
    float _S145;

#line 120
    if(_S144 > 1.0f)
    {

#line 120
        _S145 = 2.0f - _S144;

#line 120
    }
    else
    {

#line 120
        _S145 = _S144;

#line 120
    }

#line 120
    float _S146 = m_1.y;

#line 120
    float _S147;

#line 120
    if(_S146 > 1.0f)
    {

#line 120
        _S147 = 2.0f - _S146;

#line 120
    }
    else
    {

#line 120
        _S147 = _S146;

#line 120
    }
    float2 inner_0 = lo_0 + _S142;
    return min(max(lo_0 + float2(_S145, _S147) * kernelContext_22->u_0->frame_0, inner_0), max(inner_0, lo_0 + kernelContext_22->u_0->frame_0 - _S142));
}


#line 109
float sqWave_0(float x_4, int type_0)
{

#line 110
    if(type_0 == int(1))
    {

#line 110
        float _S148;

#line 110
        if((x_4 - floor(x_4)) < 0.5f)
        {

#line 110
            _S148 = 1.0f;

#line 110
        }
        else
        {

#line 110
            _S148 = -1.0f;

#line 110
        }

#line 110
        return _S148;
    }

#line 111
    if(type_0 == int(2))
    {

#line 111
        float _S149 = x_4 - 0.25f;

#line 111
        return 4.0f * abs(_S149 - floor(_S149) - 0.5f) - 1.0f;
    }

#line 112
    if(type_0 == int(3))
    {

#line 112
        float _S150 = x_4 + 0.5f;

#line 112
        return 2.0f * (_S150 - floor(_S150)) - 1.0f;
    }

#line 113
    return sin(6.2831854820251465f * x_4);
}


#line 125
float2 warpSource_0(float2 q_6, KernelContext_0 thread* kernelContext_23)
{

#line 126
    int op_1 = kernelContext_23->u_0->i_0.w;
    if(op_1 == int(29))
    {

#line 128
        float2 d_7 = q_6 - kernelContext_23->u_0->center_0;
        float _S151 = d_7.x;

#line 129
        float _S152 = d_7.y;

#line 129
        float2 _S153 = sqFoldIntoFrame_0(kernelContext_23->u_0->center_0 + float2(kernelContext_23->u_0->a_0.x * _S151 + kernelContext_23->u_0->a_0.y * _S152, kernelContext_23->u_0->a_0.z * _S151 + kernelContext_23->u_0->a_0.w * _S152) + kernelContext_23->u_0->b_0.xy, kernelContext_23);

#line 129
        return _S153;
    }

#line 129
    float pin_0;

#line 129
    float _S154;

    if(op_1 == int(20))
    {

#line 131
        if((kernelContext_23->u_0->i_0.x) != int(0))
        {

#line 131
            pin_0 = 2.0f * kernelContext_23->u_0->center_0.x - q_6.x;

#line 131
        }
        else
        {

#line 131
            pin_0 = q_6.x;

#line 131
        }

#line 131
        if((kernelContext_23->u_0->i_0.y) != int(0))
        {

#line 131
            _S154 = 2.0f * kernelContext_23->u_0->center_0.y - q_6.y;

#line 131
        }
        else
        {

#line 131
            _S154 = q_6.y;

#line 131
        }

#line 131
        return float2(pin_0, _S154);
    }

#line 131
    bool _S155;
    if(op_1 == int(21))
    {

#line 133
        float2 d_8 = q_6 - kernelContext_23->u_0->center_0;

#line 133
        float r_3 = length(d_8);

#line 133
        float big_0 = kernelContext_23->u_0->a_0.y;
        if(r_3 >= big_0)
        {

#line 134
            _S155 = true;

#line 134
        }
        else
        {

#line 134
            _S155 = big_0 <= 0.0f;

#line 134
        }

#line 134
        if(_S155)
        {

#line 134
            return q_6;
        }

#line 135
        float k_2 = 1.0f - r_3 / big_0;

#line 135
        float th_0 = - kernelContext_23->u_0->a_0.x * k_2 * k_2;

#line 135
        float c_5 = cos(th_0);

#line 135
        float s_3 = sin(th_0);
        float _S156 = d_8.x;

#line 136
        float _S157 = d_8.y;

#line 136
        return kernelContext_23->u_0->center_0 + float2(c_5 * _S156 - s_3 * _S157, s_3 * _S156 + c_5 * _S157);
    }
    if(op_1 == int(22))
    {

#line 139
        float2 across_0 = float2(- kernelContext_23->u_0->a_0.w, kernelContext_23->u_0->a_0.z);
        float2 _S158 = q_6 - (kernelContext_23->u_0->center_0 - kernelContext_23->u_0->frame_0 * float2(0.5f) );

#line 140
        float x_5 = dot(_S158, kernelContext_23->u_0->a_0.zw) / kernelContext_23->u_0->a_0.y + kernelContext_23->u_0->b_0.x;
        float2 n_3 = _S158 / kernelContext_23->u_0->frame_0;
        float _S159 = n_3.x;

#line 142
        float ex_0 = sqSmooth_0(0.0f, 0.10000000149011612f, min(_S159, 1.0f - _S159));

#line 142
        float _S160 = n_3.y;

#line 142
        float ey_0 = sqSmooth_0(0.0f, 0.10000000149011612f, min(_S160, 1.0f - _S160));
        if((kernelContext_23->u_0->i_0.y) == int(1))
        {

#line 143
            pin_0 = ex_0 * ey_0;

#line 143
        }
        else
        {

#line 143
            if((kernelContext_23->u_0->i_0.y) == int(2))
            {

#line 143
                pin_0 = ey_0;

#line 143
            }
            else
            {

#line 143
                if((kernelContext_23->u_0->i_0.y) == int(3))
                {

#line 143
                    pin_0 = ex_0;

#line 143
                }
                else
                {

#line 143
                    pin_0 = 1.0f;

#line 143
                }

#line 143
            }

#line 143
        }
        return q_6 - across_0 * float2((kernelContext_23->u_0->a_0.x * sqWave_0(x_5, kernelContext_23->u_0->i_0.x) * pin_0)) ;
    }
    if(op_1 == int(23))
    {

#line 147
        float2 d_9 = q_6 - kernelContext_23->u_0->center_0;

#line 147
        float r_4 = length(d_9);

#line 147
        float big_1 = kernelContext_23->u_0->a_0.x;
        if(r_4 >= big_1)
        {

#line 148
            _S155 = true;

#line 148
        }
        else
        {

#line 148
            _S155 = r_4 <= 0.0f;

#line 148
        }

#line 148
        if(_S155)
        {

#line 148
            return q_6;
        }

#line 149
        float n_4 = r_4 / big_1;

#line 149
        float s_4 = kernelContext_23->u_0->a_0.y;
        if(s_4 > 0.0f)
        {

#line 150
            pin_0 = n_4 + (0.63661974668502808f * asin(n_4) - n_4) * s_4;

#line 150
        }
        else
        {

#line 150
            pin_0 = n_4 + (sin(n_4 * 3.1415927410125732f / 2.0f) - n_4) * - s_4;

#line 150
        }
        return kernelContext_23->u_0->center_0 + d_9 * float2((pin_0 / n_4)) ;
    }

#line 151
    float2 f_0;

    if(op_1 == int(25))
    {

#line 154
        float2 o_6 = kernelContext_23->u_0->center_0 - kernelContext_23->u_0->frame_0 * float2(0.5f) ;
        float2 t_2 = (q_6 - o_6) / kernelContext_23->u_0->frame_0 * kernelContext_23->u_0->a_0.xy + kernelContext_23->u_0->a_0.zw;
        float2 _S161 = t_2 - floor(t_2);
        if((kernelContext_23->u_0->b_0.x) != 0.0f)
        {

#line 157
            float2 _S162 = float2(2.0f) ;
            float2 m_2 = t_2 - _S162 * floor(t_2 / _S162);
            float _S163 = m_2.x;

#line 159
            if(_S163 > 1.0f)
            {

#line 159
                pin_0 = 2.0f - _S163;

#line 159
            }
            else
            {

#line 159
                pin_0 = _S163;

#line 159
            }

#line 159
            float _S164 = m_2.y;

#line 159
            if(_S164 > 1.0f)
            {

#line 159
                _S154 = 2.0f - _S164;

#line 159
            }
            else
            {

#line 159
                _S154 = _S164;

#line 159
            }

#line 159
            f_0 = float2(pin_0, _S154);

#line 157
        }
        else
        {

#line 157
            f_0 = _S161;

#line 157
        }



        return o_6 + f_0 * kernelContext_23->u_0->frame_0;
    }
    if(op_1 == int(26))
    {

#line 164
        float2 d_10 = q_6 - kernelContext_23->u_0->center_0;

#line 164
        float r_5 = length(d_10);
        if(r_5 <= 0.0f)
        {

#line 165
            return q_6;
        }

#line 166
        float w_6 = kernelContext_23->u_0->a_0.x;

#line 166
        float th_1 = atan2(d_10.y, d_10.x);

        float a_5 = abs(th_1 - w_6 * floor(th_1 / w_6) - w_6 / 2.0f) + kernelContext_23->u_0->a_0.y;
        return kernelContext_23->u_0->center_0 + float2((r_5 * kernelContext_23->u_0->a_0.z))  * float2(cos(a_5), sin(a_5));
    }
    if(op_1 == int(24))
    {

#line 172
        float2 d_11 = q_6 - kernelContext_23->u_0->center_0;
        float _S165 = d_11.x;

#line 173
        float _S166 = d_11.y;

#line 173
        return kernelContext_23->u_0->center_0 + float2(kernelContext_23->u_0->a_0.x * _S165 + kernelContext_23->u_0->a_0.y * _S166, kernelContext_23->u_0->a_0.z * _S165 + kernelContext_23->u_0->a_0.w * _S166) + kernelContext_23->u_0->b_0.xy;
    }
    if(op_1 == int(28))
    {

#line 176
        float2 d_12 = q_6 - kernelContext_23->u_0->center_0;
        float _S167 = d_12.x;

#line 177
        float _S168 = d_12.y;

#line 177
        float den_0 = kernelContext_23->u_0->b_0.z * _S167 + kernelContext_23->u_0->b_0.w * _S168 + 1.0f;
        if((kernelContext_23->u_0->i_0.x) != int(0))
        {

#line 178
            _S155 = true;

#line 178
        }
        else
        {

#line 178
            _S155 = den_0 <= 9.99999997475242708e-07f;

#line 178
        }

#line 178
        if(_S155)
        {

#line 178
            return float2(-1.0e+06f, -1.0e+06f);
        }

#line 179
        return kernelContext_23->u_0->center_0 + float2(kernelContext_23->u_0->a_0.x * _S167 + kernelContext_23->u_0->a_0.y * _S168 + kernelContext_23->u_0->a_0.z, kernelContext_23->u_0->a_0.w * _S167 + kernelContext_23->u_0->b_0.x * _S168 + kernelContext_23->u_0->b_0.y) / float2(den_0) ;
    }
    if(op_1 == int(27))
    {

#line 182
        if((kernelContext_23->u_0->i_0.y) != int(0))
        {

#line 183
            float2 d_13 = q_6 - kernelContext_23->u_0->center_0;
            float _S169 = d_13.x;

#line 184
            float _S170 = d_13.y;

#line 184
            float den_1 = kernelContext_23->u_0->d_0.z * _S169 + kernelContext_23->u_0->d_0.w * _S170 + 1.0f;
            if(den_1 <= 9.99999997475242708e-07f)
            {

#line 185
                return float2(-1.0e+06f, -1.0e+06f);
            }

#line 185
            f_0 = kernelContext_23->u_0->center_0 + float2(kernelContext_23->u_0->c_0.x * _S169 + kernelContext_23->u_0->c_0.y * _S170 + kernelContext_23->u_0->c_0.z, kernelContext_23->u_0->c_0.w * _S169 + kernelContext_23->u_0->d_0.x * _S170 + kernelContext_23->u_0->d_0.y) / float2(den_1) ;

#line 182
        }
        else
        {

#line 182
            f_0 = q_6;

#line 182
        }

#line 188
        float2 s_5 = kernelContext_23->u_0->a_0.xy;

#line 188
        float _S171 = max(kernelContext_23->u_0->a_0.z, 1.0f);

#line 188
        bool alongX_0 = (kernelContext_23->u_0->i_0.x) != int(0);
        if(alongX_0)
        {

#line 189
            pin_0 = f_0.x - kernelContext_23->u_0->center_0.x;

#line 189
        }
        else
        {

#line 189
            pin_0 = f_0.y - kernelContext_23->u_0->center_0.y;

#line 189
        }

#line 189
        float v0_0 = pin_0 / _S171;
        if(alongX_0)
        {

#line 190
            pin_0 = s_5.x;

#line 190
        }
        else
        {

#line 190
            pin_0 = s_5.y;

#line 190
        }

#line 190
        float2 _S172 = float2(0.5f) ;
        float2 lo_1 = kernelContext_23->u_0->center_0 - kernelContext_23->u_0->frame_0 * _S172 + _S172;
        return min(max(f_0 + s_5 * float2((v0_0 / max(1.0f - pin_0 / _S171, 0.5f))) , lo_1), max(lo_1, kernelContext_23->u_0->center_0 + kernelContext_23->u_0->frame_0 * _S172 - _S172));
    }
    return q_6;
}




[[kernel]] void filterStyleWarp(uint3 tid_12 [[thread_position_in_grid]], texture2d<float, access::sample> in0_13 [[texture(0)]], FilterU_0 constant* u_13 [[buffer(0)]], texture2d<float, access::write> out0_13 [[texture(25)]], sampler zeroSampler_13 [[sampler(0)]], texture2d<float, access::sample> in1_13 [[texture(1)]], sampler edgeSampler_13 [[sampler(1)]])
{

#line 200
    thread KernelContext_0 kernelContext_24;

#line 200
    (&kernelContext_24)->in0_0 = in0_13;

#line 200
    (&kernelContext_24)->u_0 = u_13;

#line 200
    (&kernelContext_24)->out0_0 = out0_13;

#line 200
    (&kernelContext_24)->zeroSampler_0 = zeroSampler_13;

#line 200
    (&kernelContext_24)->in1_0 = in1_13;

#line 200
    (&kernelContext_24)->edgeSampler_0 = edgeSampler_13;

#line 200
    uint2 _S173 = outSize_0(&kernelContext_24);

    float2 _S174 = float2(_S173);

#line 202
    bool _S175;
    if((tid_12.x) >= (_S173.x))
    {

#line 203
        _S175 = true;

#line 203
    }
    else
    {

#line 203
        _S175 = (tid_12.y) >= (_S173.y);

#line 203
    }

#line 203
    if(_S175)
    {

#line 203
        return;
    }

#line 203
    float gain_0;
    if(((&kernelContext_24)->u_0->i_0.w) == int(24))
    {

#line 204
        gain_0 = (&kernelContext_24)->u_0->b_0.z;

#line 204
    }
    else
    {

#line 204
        gain_0 = 1.0f;

#line 204
    }
    uint2 _S176 = tid_12.xy;

#line 205
    float2 _S177 = float2(0.5f) ;

#line 205
    float2 q_7 = float2(_S176) + _S177;
    if(((&kernelContext_24)->u_0->i_0.w) == int(29))
    {

#line 207
        float2 d_14 = abs(q_7 - (&kernelContext_24)->u_0->center_0);
        if((d_14.x) > ((&kernelContext_24)->u_0->frame_0.x * 0.5f))
        {

#line 208
            _S175 = true;

#line 208
        }
        else
        {

#line 208
            _S175 = (d_14.y) > ((&kernelContext_24)->u_0->frame_0.y * 0.5f);

#line 208
        }

#line 208
        if(_S175)
        {

#line 208
            float4 _S178 = sampleZ_0(q_7 / _S174, &kernelContext_24);

#line 208
            (&kernelContext_24)->out0_0.write(_S178,_S176);

#line 208
            return;
        }

#line 209
        float2 d0_0 = q_7 - (&kernelContext_24)->u_0->center_0;
        float _S179 = d0_0.x;

#line 210
        float _S180 = d0_0.y;

#line 210
        float2 raw_0 = (&kernelContext_24)->u_0->center_0 + float2((&kernelContext_24)->u_0->a_0.x * _S179 + (&kernelContext_24)->u_0->a_0.y * _S180, (&kernelContext_24)->u_0->a_0.z * _S179 + (&kernelContext_24)->u_0->a_0.w * _S180) + (&kernelContext_24)->u_0->b_0.xy;

#line 210
        float2 _S181 = sqFoldIntoFrame_0(raw_0, &kernelContext_24);

#line 210
        float4 _S182 = sampleZ_0(_S181 / _S174, &kernelContext_24);


        float ov_0 = length(max(max((&kernelContext_24)->u_0->center_0 - (&kernelContext_24)->u_0->frame_0 * _S177 - raw_0, raw_0 - ((&kernelContext_24)->u_0->center_0 + (&kernelContext_24)->u_0->frame_0 * _S177)), float2(0.0f) ));
        if(((&kernelContext_24)->u_0->i_0.x) != int(2))
        {

#line 214
            _S175 = true;

#line 214
        }
        else
        {

#line 214
            _S175 = ov_0 <= 0.0f;

#line 214
        }

#line 214
        if(_S175)
        {

#line 214
            (&kernelContext_24)->out0_0.write(_S182,_S176);

#line 214
            return;
        }
        float _S183 = max((&kernelContext_24)->u_0->frame_0.x, (&kernelContext_24)->u_0->frame_0.y);
        float w_7 = smoothstep(0.0f, 0.019999999552965164f * _S183, ov_0);

#line 217
        float _S184 = 0.029999999329447746f * _S183 * w_7 * 0.25f;
        float4 _S185 = float4(0.0f) ;

#line 218
        int j_2 = int(-4);

#line 218
        float4 acc_10 = _S185;
        for(;;)
        {

#line 219
            if(j_2 <= int(4))
            {
            }
            else
            {

#line 219
                break;
            }

#line 219
            int i_3 = int(-4);

#line 219
            for(;;)
            {

#line 219
                if(i_3 <= int(4))
                {
                }
                else
                {

#line 219
                    break;
                }

#line 219
                float2 _S186 = sqFoldIntoFrame_0(raw_0 + float2(float(i_3), float(j_2)) * float2(_S184) , &kernelContext_24);

#line 219
                float4 _S187 = sampleZ_0(_S186 / _S174, &kernelContext_24);
                float4 acc_11 = acc_10 + _S187;

#line 219
                i_3 = i_3 + int(1);

#line 219
                acc_10 = acc_11;

#line 219
            }

#line 219
            j_2 = j_2 + int(1);

#line 219
        }

        (&kernelContext_24)->out0_0.write(mix(_S182, acc_10 / float4(81.0f) , float4(w_7) ),_S176);
        return;
    }
    if(((&kernelContext_24)->u_0->i_0.w) == int(27))
    {

#line 225
        float2 d_15 = abs(q_7 - (&kernelContext_24)->u_0->center_0);
        if((d_15.x) > ((&kernelContext_24)->u_0->frame_0.x * 0.5f))
        {

#line 226
            _S175 = true;

#line 226
        }
        else
        {

#line 226
            _S175 = (d_15.y) > ((&kernelContext_24)->u_0->frame_0.y * 0.5f);

#line 226
        }

#line 226
        if(_S175)
        {

#line 226
            float4 _S188 = sampleZ_0(q_7 / _S174, &kernelContext_24);

#line 226
            (&kernelContext_24)->out0_0.write(_S188,_S176);

#line 226
            return;
        }

#line 224
    }

#line 224
    float2 _S189 = warpSource_0(q_7, &kernelContext_24);

#line 224
    float4 _S190 = sampleZ_0(_S189 / _S174, &kernelContext_24);



    (&kernelContext_24)->out0_0.write(_S190 * float4(gain_0) ,_S176);
    return;
}


#line 231
bool sqInPicture_0(float2 q_8, KernelContext_0 thread* kernelContext_25)
{

#line 232
    float2 o_7 = kernelContext_25->u_0->a_0.zw;
    float _S191 = q_8.x;

#line 233
    float _S192 = o_7.x;

#line 233
    bool _S193;

#line 233
    if(_S191 >= _S192)
    {

#line 233
        _S193 = (q_8.y) >= (o_7.y);

#line 233
    }
    else
    {

#line 233
        _S193 = false;

#line 233
    }

#line 233
    if(_S193)
    {

#line 233
        _S193 = _S191 <= (_S192 + kernelContext_25->u_0->frame_0.x);

#line 233
    }
    else
    {

#line 233
        _S193 = false;

#line 233
    }

#line 233
    if(_S193)
    {

#line 233
        _S193 = (q_8.y) <= (o_7.y + kernelContext_25->u_0->frame_0.y);

#line 233
    }
    else
    {

#line 233
        _S193 = false;

#line 233
    }

#line 233
    return _S193;
}


#line 240
float2 sqLensHold_0(float2 p_6, float thread* cover_0, KernelContext_0 thread* kernelContext_26)
{

#line 241
    float2 o_8 = kernelContext_26->u_0->a_0.zw;

#line 241
    float2 e_3 = o_8 + kernelContext_26->u_0->frame_0;
    *cover_0 = 1.0f;
    if((kernelContext_26->u_0->i_0.y) != int(0))
    {

#line 243
        float2 _S194 = float2(0.5f) ;

#line 243
        return clamp(p_6, o_8 + _S194, e_3 - _S194);
    }

#line 244
    float2 m_3 = clamp(min(p_6 - o_8, e_3 - p_6) + float2(0.5f) , float2(0.0f) , float2(1.0f) );
    *cover_0 = m_3.x * m_3.y;
    return p_6;
}


#line 236
float4 sqCubicW_0(float t_3)
{

#line 237
    return float4(((-0.5f * t_3 + 1.0f) * t_3 - 0.5f) * t_3, (1.5f * t_3 - 2.5f) * t_3 * t_3 + 1.0f, ((-1.5f * t_3 + 2.0f) * t_3 + 0.5f) * t_3, (0.5f * t_3 - 0.5f) * t_3 * t_3);
}


#line 249
float4 sqEdgeTap_0(float2 p_7, KernelContext_0 thread* kernelContext_27)
{

#line 249
    uint2 _S195 = inSize_0(kernelContext_27);

#line 249
    return ((kernelContext_27->in0_0).sample((kernelContext_27->edgeSampler_0), (p_7 / float2(_S195)), level((0.0f))));
}

float4 sqLensTap_0(float2 p_8, KernelContext_0 thread* kernelContext_28)
{

#line 253
    float2 o_9 = kernelContext_28->u_0->a_0.zw;

#line 253
    float2 e_4 = o_9 + kernelContext_28->u_0->frame_0;
    thread float cover_1;

#line 254
    float2 _S196 = sqLensHold_0(p_8, &cover_1, kernelContext_28);

    if(cover_1 <= 0.0f)
    {

#line 256
        return kernelContext_28->u_0->b_0;
    }

#line 256
    float2 _S197 = float2(0.5f) ;
    float2 lo_2 = ceil(o_9 - _S197) + _S197;

#line 257
    float2 hi_0 = floor(e_4 - _S197) + _S197;
    float2 q_9 = _S196 - _S197;

#line 258
    float2 b_4 = floor(q_9);
    float4 wx_0 = sqCubicW_0(q_9.x - b_4.x);

#line 259
    float4 wy_0 = sqCubicW_0(q_9.y - b_4.y);
    float _S198 = wx_0.z;

#line 260
    float _S199 = wx_0.y + _S198;

#line 260
    float _S200 = wy_0.z;

#line 260
    float _S201 = wy_0.y + _S200;
    float2 c0_0 = clamp(b_4 - _S197, lo_2, hi_0);

#line 261
    float2 c12_0 = clamp(b_4 + _S197 + float2(_S198, _S200) / float2(_S199, _S201), lo_2, hi_0);

#line 261
    float2 c3_0 = clamp(b_4 + float2(2.5f) , lo_2, hi_0);
    float _S202 = c12_0.x;

#line 262
    float4 _S203 = sqEdgeTap_0(float2(_S202, c0_0.y), kernelContext_28);

#line 262
    float _S204 = wy_0.x;

#line 262
    float4 _S205 = _S203 * float4((_S199 * _S204)) ;

#line 262
    float _S206 = c12_0.y;

#line 262
    float4 _S207 = sqEdgeTap_0(float2(c0_0.x, _S206), kernelContext_28);

#line 262
    float _S208 = wx_0.x;

#line 262
    float4 _S209 = _S205 + _S207 * float4((_S208 * _S201)) ;

#line 262
    float4 _S210 = sqEdgeTap_0(c12_0, kernelContext_28);
    float4 _S211 = _S209 + _S210 * float4((_S199 * _S201)) ;

#line 263
    float4 _S212 = sqEdgeTap_0(float2(c3_0.x, _S206), kernelContext_28);

#line 263
    float _S213 = wx_0.w;

#line 263
    float4 _S214 = _S211 + _S212 * float4((_S213 * _S201)) ;

#line 263
    float4 _S215 = sqEdgeTap_0(float2(_S202, c3_0.y), kernelContext_28);
    float _S216 = wy_0.w;

    return (_S214 + _S215 * float4((_S199 * _S216)) ) / float4((1.0f - (_S208 + _S213) * (_S204 + _S216)))  * float4(cover_1)  + kernelContext_28->u_0->b_0 * float4((1.0f - cover_1)) ;
}

float4 sqLensLinear_0(float2 p_9, KernelContext_0 thread* kernelContext_29)
{

#line 270
    float2 o_10 = kernelContext_29->u_0->a_0.zw;

#line 270
    float2 e_5 = o_10 + kernelContext_29->u_0->frame_0;
    thread float cover_2;

#line 271
    float2 _S217 = sqLensHold_0(p_9, &cover_2, kernelContext_29);

    if(cover_2 <= 0.0f)
    {

#line 273
        return kernelContext_29->u_0->b_0;
    }

#line 273
    float2 _S218 = float2(0.5f) ;

#line 273
    float4 _S219 = sqEdgeTap_0(clamp(_S217, ceil(o_10 - _S218) + _S218, floor(e_5 - _S218) + _S218), kernelContext_29);
    return _S219 * float4(cover_2)  + kernelContext_29->u_0->b_0 * float4((1.0f - cover_2)) ;
}


[[kernel]] void filterLens(uint3 tid_13 [[thread_position_in_grid]], texture2d<float, access::sample> in0_14 [[texture(0)]], FilterU_0 constant* u_14 [[buffer(0)]], texture2d<float, access::write> out0_14 [[texture(25)]], sampler zeroSampler_14 [[sampler(0)]], texture2d<float, access::sample> in1_14 [[texture(1)]], sampler edgeSampler_14 [[sampler(1)]])
{

#line 278
    thread KernelContext_0 kernelContext_30;

#line 278
    (&kernelContext_30)->in0_0 = in0_14;

#line 278
    (&kernelContext_30)->u_0 = u_14;

#line 278
    (&kernelContext_30)->out0_0 = out0_14;

#line 278
    (&kernelContext_30)->zeroSampler_0 = zeroSampler_14;

#line 278
    (&kernelContext_30)->in1_0 = in1_14;

#line 278
    (&kernelContext_30)->edgeSampler_0 = edgeSampler_14;

#line 278
    uint2 _S220 = outSize_0(&kernelContext_30);

    float2 _S221 = float2(_S220);

#line 280
    bool _S222;
    if((tid_13.x) >= (_S220.x))
    {

#line 281
        _S222 = true;

#line 281
    }
    else
    {

#line 281
        _S222 = (tid_13.y) >= (_S220.y);

#line 281
    }

#line 281
    if(_S222)
    {

#line 281
        return;
    }

#line 282
    uint2 _S223 = tid_13.xy;

#line 282
    float2 _S224 = float2(0.5f) ;

#line 282
    float2 q_10 = float2(_S223) + _S224;

#line 282
    bool _S225 = sqInPicture_0(q_10, &kernelContext_30);
    if(!_S225)
    {

#line 283
        float4 _S226 = sampleZ_0(q_10 / _S221, &kernelContext_30);

#line 283
        (&kernelContext_30)->out0_0.write(_S226,_S223);

#line 283
        return;
    }

#line 283
    float f_1;

#line 283
    float4 c_6;
    if(((&kernelContext_30)->u_0->i_0.z) == int(0))
    {

#line 285
        float2 d_16 = q_10 - (&kernelContext_30)->u_0->center_0;

#line 285
        float r_6 = length(d_16) / (&kernelContext_30)->u_0->a_0.y;

#line 285
        float k_3 = (&kernelContext_30)->u_0->a_0.x;
        if(k_3 >= 0.0f)
        {

#line 286
            f_1 = 1.0f + k_3 * r_6 * r_6;

#line 286
        }
        else
        {

#line 286
            f_1 = 1.0f / (1.0f - k_3 * r_6 * r_6);

#line 286
        }
        float2 s_6 = (&kernelContext_30)->u_0->center_0 + d_16 * float2(f_1) ;
        if(((&kernelContext_30)->u_0->b_0.w) > 0.0f)
        {

#line 288
            bool _S227 = sqInPicture_0(s_6, &kernelContext_30);

#line 288
            _S222 = !_S227;

#line 288
        }
        else
        {

#line 288
            _S222 = false;

#line 288
        }

#line 288
        if(_S222)
        {

#line 288
            c_6 = (&kernelContext_30)->u_0->b_0;

#line 288
        }
        else
        {

#line 288
            float4 _S228 = sampleZ_0(s_6 / _S221, &kernelContext_30);

#line 288
            c_6 = _S228;

#line 288
        }

#line 288
        (&kernelContext_30)->out0_0.write(c_6,_S223);
        return;
    }
    float zoom_0 = (as_type<float>(((&kernelContext_30)->u_0->i_0.x)));
    float2 d_17 = q_10 - (&kernelContext_30)->u_0->center_0;

#line 292
    float len_0 = length(d_17);

#line 292
    float rho_1 = len_0 / (&kernelContext_30)->u_0->a_0.y * zoom_0;

#line 292
    float k_4 = (&kernelContext_30)->u_0->a_0.x;

#line 292
    float g_1;

    if(k_4 >= 0.0f)
    {

#line 294
        float _S229 = 1.0f + 3.0f * k_4 * rho_1 * rho_1;

#line 294
        f_1 = 1.0f + k_4 * rho_1 * rho_1;

#line 294
        g_1 = _S229;

#line 294
    }
    else
    {

#line 296
        float a_6 = - k_4;

#line 296
        float _S230 = rho_1 / (1.0f + a_6 * rho_1 * rho_1);

#line 296
        int n_5 = int(0);

#line 296
        f_1 = _S230;
        for(;;)
        {

#line 297
            if(n_5 < int(4))
            {
            }
            else
            {

#line 297
                break;
            }

#line 297
            float x_6 = f_1 - (f_1 * (1.0f + a_6 * f_1 * f_1) - rho_1) / (1.0f + 3.0f * a_6 * f_1 * f_1);

#line 297
            n_5 = n_5 + int(1);

#line 297
            f_1 = x_6;

#line 297
        }
        if(rho_1 > 9.99999997475242708e-07f)
        {

#line 298
            g_1 = f_1 / rho_1;

#line 298
        }
        else
        {

#line 298
            g_1 = 1.0f;

#line 298
        }

#line 298
        float _S231 = 1.0f / (1.0f + 3.0f * a_6 * f_1 * f_1);

#line 298
        f_1 = g_1;

#line 298
        g_1 = _S231;

#line 294
    }

#line 300
    float _S232 = zoom_0 * f_1;

#line 300
    float2 s_7 = (&kernelContext_30)->u_0->center_0 + d_17 * float2(_S232) ;
    float2 o_11 = (&kernelContext_30)->u_0->a_0.zw;

#line 301
    float2 e_6 = o_11 + (&kernelContext_30)->u_0->frame_0;
    if(((&kernelContext_30)->u_0->i_0.y) == int(0))
    {

#line 302
        float _S233 = s_7.x;

#line 302
        if(_S233 < (o_11.x - 3.0f))
        {

#line 302
            _S222 = true;

#line 302
        }
        else
        {

#line 302
            _S222 = (s_7.y) < (o_11.y - 3.0f);

#line 302
        }

#line 302
        if(_S222)
        {

#line 302
            _S222 = true;

#line 302
        }
        else
        {

#line 302
            _S222 = _S233 > (e_6.x + 3.0f);

#line 302
        }

#line 302
        if(_S222)
        {

#line 302
            _S222 = true;

#line 302
        }
        else
        {

#line 302
            _S222 = (s_7.y) > (e_6.y + 3.0f);

#line 302
        }

#line 302
    }
    else
    {

#line 302
        _S222 = false;

#line 302
    }

#line 302
    if(_S222)
    {

#line 302
        (&kernelContext_30)->out0_0.write((&kernelContext_30)->u_0->b_0,_S223);

#line 302
        return;
    }

#line 303
    float _S234 = zoom_0 * g_1;

#line 303
    float2 stretch_0 = float2(_S234, _S232);
    float t_4 = clamp((max(_S234, _S232) - 1.1499999761581421f) / 0.25f, 0.0f, 1.0f);
    float4 c_7 = float4(0.0f) ;
    if(t_4 < 1.0f)
    {

#line 306
        float4 _S235 = sqLensTap_0(s_7, &kernelContext_30);

#line 306
        c_6 = _S235 * float4((1.0f - t_4)) ;

#line 306
    }
    else
    {

#line 306
        c_6 = c_7;

#line 306
    }
    if(t_4 > 0.0f)
    {

#line 308
        float2 spread_0 = clamp(stretch_0 - float2(1.0f) , float2(0.0f) , float2(2.0f) ) * _S224;

#line 308
        float2 er_0;
        if(len_0 > 9.99999997475242708e-07f)
        {

#line 309
            er_0 = d_17 / float2(len_0) ;

#line 309
        }
        else
        {

#line 309
            er_0 = float2(1.0f, 0.0f);

#line 309
        }
        float2 a_7 = er_0 * float2(spread_0.x) ;

#line 310
        float2 b_5 = float2(- er_0.y, er_0.x) * float2(spread_0.y) ;
        float2 _S236 = s_7 + a_7;

#line 311
        float4 _S237 = sqLensLinear_0(_S236 + b_5, &kernelContext_30);

#line 311
        float4 _S238 = sqLensLinear_0(_S236 - b_5, &kernelContext_30);

#line 311
        float4 _S239 = _S237 + _S238;

#line 311
        float2 _S240 = s_7 - a_7;

#line 311
        float4 _S241 = sqLensLinear_0(_S240 + b_5, &kernelContext_30);

#line 311
        float4 _S242 = _S239 + _S241;

#line 311
        float4 _S243 = sqLensLinear_0(_S240 - b_5, &kernelContext_30);

#line 311
        c_6 = c_6 + (_S242 + _S243) * float4((0.25f * t_4)) ;

#line 307
    }

#line 314
    float _S244 = c_6.w;

#line 314
    float hold_0;

#line 314
    if(_S244 > 1.0f)
    {

#line 314
        hold_0 = 1.0f / _S244;

#line 314
    }
    else
    {

#line 314
        hold_0 = 1.0f;

#line 314
    }
    if(_S244 <= 0.0f)
    {

#line 315
        c_6 = c_7;

#line 315
    }
    else
    {

#line 315
        c_6 = float4(max(c_6.xyz, float3(0.0f) ) * float3(hold_0) , min(_S244, 1.0f));

#line 315
    }

#line 315
    (&kernelContext_30)->out0_0.write(c_6,_S223);
    return;
}

[[kernel]] void filterGlitch(uint3 tid_14 [[thread_position_in_grid]], texture2d<float, access::sample> in0_15 [[texture(0)]], FilterU_0 constant* u_15 [[buffer(0)]], texture2d<float, access::write> out0_15 [[texture(25)]], sampler zeroSampler_15 [[sampler(0)]], texture2d<float, access::sample> in1_15 [[texture(1)]], sampler edgeSampler_15 [[sampler(1)]])
{

#line 319
    thread KernelContext_0 kernelContext_31;

#line 319
    (&kernelContext_31)->in0_0 = in0_15;

#line 319
    (&kernelContext_31)->u_0 = u_15;

#line 319
    (&kernelContext_31)->out0_0 = out0_15;

#line 319
    (&kernelContext_31)->zeroSampler_0 = zeroSampler_15;

#line 319
    (&kernelContext_31)->in1_0 = in1_15;

#line 319
    (&kernelContext_31)->edgeSampler_0 = edgeSampler_15;

#line 319
    uint2 _S245 = outSize_0(&kernelContext_31);

    float2 _S246 = float2(_S245);

#line 321
    bool _S247;
    if((tid_14.x) >= (_S245.x))
    {

#line 322
        _S247 = true;

#line 322
    }
    else
    {

#line 322
        _S247 = (tid_14.y) >= (_S245.y);

#line 322
    }

#line 322
    if(_S247)
    {

#line 322
        return;
    }

#line 323
    uint2 _S248 = tid_14.xy;

#line 323
    float2 q_11 = float2(_S248) + float2(0.5f) ;
    uint id_0 = uint(int((q_11.y - ((&kernelContext_31)->u_0->center_0.y - (&kernelContext_31)->u_0->frame_0.y * 0.5f)) / (&kernelContext_31)->u_0->a_0.y));

#line 324
    uint seed_1 = uint((&kernelContext_31)->u_0->i_0.x);

#line 324
    float sx_0;
    if((hash01_0(id_0, 0U, seed_1, 0U)) < ((&kernelContext_31)->u_0->a_0.w))
    {

#line 325
        sx_0 = (hash01_0(id_0, 1U, seed_1, 1U) * 2.0f - 1.0f) * (&kernelContext_31)->u_0->a_0.x;

#line 325
    }
    else
    {

#line 325
        sx_0 = 0.0f;

#line 325
    }

#line 325
    float4 _S249 = sampleZ_0((q_11 + float2(sx_0 - (&kernelContext_31)->u_0->a_0.z, 0.0f)) / _S246, &kernelContext_31);

#line 325
    float4 _S250 = sampleZ_0((q_11 + float2(sx_0, 0.0f)) / _S246, &kernelContext_31);

#line 325
    float4 _S251 = sampleZ_0((q_11 + float2(sx_0 + (&kernelContext_31)->u_0->a_0.z, 0.0f)) / _S246, &kernelContext_31);



    (&kernelContext_31)->out0_0.write(float4(_S249.x, _S250.y, _S251.z, max(_S249.w, max(_S250.w, _S251.w))),_S248);
    return;
}

[[kernel]] void filterRGBSplit(uint3 tid_15 [[thread_position_in_grid]], texture2d<float, access::sample> in0_16 [[texture(0)]], FilterU_0 constant* u_16 [[buffer(0)]], texture2d<float, access::write> out0_16 [[texture(25)]], sampler zeroSampler_16 [[sampler(0)]], texture2d<float, access::sample> in1_16 [[texture(1)]], sampler edgeSampler_16 [[sampler(1)]])
{

#line 333
    thread KernelContext_0 kernelContext_32;

#line 333
    (&kernelContext_32)->in0_0 = in0_16;

#line 333
    (&kernelContext_32)->u_0 = u_16;

#line 333
    (&kernelContext_32)->out0_0 = out0_16;

#line 333
    (&kernelContext_32)->zeroSampler_0 = zeroSampler_16;

#line 333
    (&kernelContext_32)->in1_0 = in1_16;

#line 333
    (&kernelContext_32)->edgeSampler_0 = edgeSampler_16;

#line 333
    uint2 _S252 = outSize_0(&kernelContext_32);

    float2 _S253 = float2(_S252);

#line 335
    bool _S254;
    if((tid_15.x) >= (_S252.x))
    {

#line 336
        _S254 = true;

#line 336
    }
    else
    {

#line 336
        _S254 = (tid_15.y) >= (_S252.y);

#line 336
    }

#line 336
    if(_S254)
    {

#line 336
        return;
    }

#line 337
    uint2 _S255 = tid_15.xy;

#line 337
    float2 q_12 = float2(_S255) + float2(0.5f) ;

#line 337
    float2 d_18 = (&kernelContext_32)->u_0->a_0.xy;

#line 337
    float2 d_19;
    if(((&kernelContext_32)->u_0->i_0.x) != int(0))
    {

#line 338
        d_19 = float2(length(d_18))  * (q_12 - (&kernelContext_32)->u_0->center_0) / float2((&kernelContext_32)->u_0->a_0.w) ;

#line 338
    }
    else
    {

#line 338
        d_19 = d_18;

#line 338
    }

#line 338
    float4 _S256 = sampleZ_0(q_12 / _S253, &kernelContext_32);

#line 338
    float4 _S257 = sampleZ_0((q_12 - d_19) / _S253, &kernelContext_32);

#line 338
    float4 _S258 = sampleZ_0((q_12 + d_19) / _S253, &kernelContext_32);

    float4 s_8 = float4(_S257.x, _S256.y, _S258.z, max(_S257.w, max(_S256.w, _S258.w)));
    (&kernelContext_32)->out0_0.write(s_8 + (_S256 - s_8) * float4((&kernelContext_32)->u_0->a_0.z) ,_S255);
    return;
}

[[kernel]] void filterRadialBlur(uint3 tid_16 [[thread_position_in_grid]], texture2d<float, access::sample> in0_17 [[texture(0)]], FilterU_0 constant* u_17 [[buffer(0)]], texture2d<float, access::write> out0_17 [[texture(25)]], sampler zeroSampler_17 [[sampler(0)]], texture2d<float, access::sample> in1_17 [[texture(1)]], sampler edgeSampler_17 [[sampler(1)]])
{

#line 345
    thread KernelContext_0 kernelContext_33;

#line 345
    (&kernelContext_33)->in0_0 = in0_17;

#line 345
    (&kernelContext_33)->u_0 = u_17;

#line 345
    (&kernelContext_33)->out0_0 = out0_17;

#line 345
    (&kernelContext_33)->zeroSampler_0 = zeroSampler_17;

#line 345
    (&kernelContext_33)->in1_0 = in1_17;

#line 345
    (&kernelContext_33)->edgeSampler_0 = edgeSampler_17;

#line 345
    uint2 _S259 = outSize_0(&kernelContext_33);

    float2 _S260 = float2(_S259);

#line 347
    bool _S261;
    if((tid_16.x) >= (_S259.x))
    {

#line 348
        _S261 = true;

#line 348
    }
    else
    {

#line 348
        _S261 = (tid_16.y) >= (_S259.y);

#line 348
    }

#line 348
    if(_S261)
    {

#line 348
        return;
    }

#line 349
    uint2 _S262 = tid_16.xy;

#line 349
    float2 _S263 = float2(_S262) + float2(0.5f)  - (&kernelContext_33)->u_0->center_0;
    int n_6 = (&kernelContext_33)->u_0->i_0.y;
    float4 _S264 = float4(0.0f) ;

#line 351
    int k_5 = int(0);

#line 351
    float4 acc_12 = _S264;
    for(;;)
    {

#line 352
        if(k_5 < n_6)
        {
        }
        else
        {

#line 352
            break;
        }

#line 353
        float t_5 = (float(k_5) / float(n_6 - int(1)) - 0.5f) * (&kernelContext_33)->u_0->a_0.x;

#line 353
        float2 s_9;

        if(((&kernelContext_33)->u_0->i_0.x) != int(0))
        {

#line 355
            s_9 = (&kernelContext_33)->u_0->center_0 + _S263 * float2((1.0f + t_5)) ;

#line 355
        }
        else
        {

#line 356
            float c_8 = cos(t_5);

#line 356
            float sn_0 = sin(t_5);

#line 356
            float _S265 = _S263.x;

#line 356
            float _S266 = _S263.y;

#line 356
            s_9 = (&kernelContext_33)->u_0->center_0 + float2(c_8 * _S265 - sn_0 * _S266, sn_0 * _S265 + c_8 * _S266);

#line 355
        }

#line 355
        float4 _S267 = sampleZ_0(s_9 / _S260, &kernelContext_33);

        float4 acc_13 = acc_12 + _S267;

#line 352
        k_5 = k_5 + int(1);

#line 352
        acc_12 = acc_13;

#line 352
    }

#line 359
    (&kernelContext_33)->out0_0.write(acc_12 / float4(float(n_6)) ,_S262);
    return;
}


#line 5 "crates/sq-gpu/shaders-src/Parts/Outline.slang"
float outlineAlpha_0(int2 p_10, KernelContext_0 thread* kernelContext_34)
{

#line 5
    uint2 _S268 = inSize_1(kernelContext_34);

    int _S269 = p_10.x;

#line 7
    bool _S270;

#line 7
    if(_S269 < int(0))
    {

#line 7
        _S270 = true;

#line 7
    }
    else
    {

#line 7
        _S270 = (p_10.y) < int(0);

#line 7
    }

#line 7
    if(_S270)
    {

#line 7
        _S270 = true;

#line 7
    }
    else
    {

#line 7
        _S270 = _S269 >= int(_S268.x);

#line 7
    }

#line 7
    if(_S270)
    {

#line 7
        _S270 = true;

#line 7
    }
    else
    {

#line 7
        _S270 = (p_10.y) >= int(_S268.y);

#line 7
    }

#line 7
    if(_S270)
    {

#line 7
        return 0.0f;
    }

#line 7
    float4 _S271 = read0_1(p_10, kernelContext_34);
    return _S271.w;
}



[[kernel]] void filterOutlineSeed(uint3 tid_17 [[thread_position_in_grid]], texture2d<float, access::sample> in0_18 [[texture(0)]], FilterU_0 constant* u_18 [[buffer(0)]], texture2d<float, access::write> out0_18 [[texture(25)]], sampler zeroSampler_18 [[sampler(0)]], texture2d<float, access::sample> in1_18 [[texture(1)]], sampler edgeSampler_18 [[sampler(1)]])
{

#line 13
    thread KernelContext_0 kernelContext_35;

#line 13
    (&kernelContext_35)->in0_0 = in0_18;

#line 13
    (&kernelContext_35)->u_0 = u_18;

#line 13
    (&kernelContext_35)->out0_0 = out0_18;

#line 13
    (&kernelContext_35)->zeroSampler_0 = zeroSampler_18;

#line 13
    (&kernelContext_35)->in1_0 = in1_18;

#line 13
    (&kernelContext_35)->edgeSampler_0 = edgeSampler_18;

#line 13
    uint2 _S272 = outSize_0(&kernelContext_35);

#line 13
    bool _S273;

    if((tid_17.x) >= (_S272.x))
    {

#line 15
        _S273 = true;

#line 15
    }
    else
    {

#line 15
        _S273 = (tid_17.y) >= (_S272.y);

#line 15
    }

#line 15
    if(_S273)
    {

#line 15
        return;
    }

#line 16
    uint2 _S274 = tid_17.xy;

#line 16
    int2 _S275 = int2(_S274);

#line 16
    float _S276 = outlineAlpha_0(_S275, &kernelContext_35);

    bool _S277 = _S276 >= 0.5f;

    float2 _S278 = float2(0.0f) ;
    array<int2, int(4)> _S279 = { { int2(int(1), int(0)), int2(int(-1), int(0)), int2(int(0), int(1)), int2(int(0), int(-1)) } };

#line 21
    float bestT_0 = 2.0f;

#line 21
    float2 off_0 = _S278;

#line 21
    int k_6 = int(0);
    for(;;)
    {

#line 22
        if(k_6 < int(4))
        {
        }
        else
        {

#line 22
            break;
        }

#line 22
        int _S280 = k_6;

#line 22
        float _S281 = outlineAlpha_0(_S275 + _S279[k_6], &kernelContext_35);

        if((_S281 >= 0.5f) == _S277)
        {

#line 24
            k_6 = k_6 + int(1);

#line 22
            continue;
        }

        float t_6 = clamp((0.5f - _S276) / (_S281 - _S276), 0.0f, 1.0f);

#line 25
        float bestT_1;

#line 25
        float2 off_1;
        if(t_6 < bestT_0)
        {

#line 26
            float2 _S282 = float2(_S279[_S280]) * float2(t_6) ;

#line 26
            bestT_1 = t_6;

#line 26
            off_1 = _S282;

#line 26
        }
        else
        {

#line 26
            bestT_1 = bestT_0;

#line 26
            off_1 = off_0;

#line 26
        }

#line 26
        bestT_0 = bestT_1;

#line 26
        off_0 = off_1;

#line 22
        k_6 = k_6 + int(1);

#line 22
    }

#line 22
    float4 _S283;

#line 28
    if(bestT_0 <= 1.0f)
    {

#line 28
        _S283 = float4(0.0f, 0.0f, off_0);

#line 28
    }
    else
    {

#line 28
        _S283 = float4(30000.0f, 0.0f, 0.0f, 0.0f);

#line 28
    }

#line 28
    (&kernelContext_35)->out0_0.write(_S283,_S274);
    return;
}


[[kernel]] void filterOutlineJump(uint3 tid_18 [[thread_position_in_grid]], texture2d<float, access::sample> in0_19 [[texture(0)]], FilterU_0 constant* u_19 [[buffer(0)]], texture2d<float, access::write> out0_19 [[texture(25)]], sampler zeroSampler_19 [[sampler(0)]], texture2d<float, access::sample> in1_19 [[texture(1)]], sampler edgeSampler_19 [[sampler(1)]])
{

#line 33
    thread KernelContext_0 kernelContext_36;

#line 33
    (&kernelContext_36)->in0_0 = in0_19;

#line 33
    (&kernelContext_36)->u_0 = u_19;

#line 33
    (&kernelContext_36)->out0_0 = out0_19;

#line 33
    (&kernelContext_36)->zeroSampler_0 = zeroSampler_19;

#line 33
    (&kernelContext_36)->in1_0 = in1_19;

#line 33
    (&kernelContext_36)->edgeSampler_0 = edgeSampler_19;

#line 33
    uint2 _S284 = outSize_0(&kernelContext_36);

    int W_2 = int(_S284.x);

#line 35
    int H_2 = int(_S284.y);

#line 35
    bool _S285;
    if(int(tid_18.x) >= W_2)
    {

#line 36
        _S285 = true;

#line 36
    }
    else
    {

#line 36
        _S285 = int(tid_18.y) >= H_2;

#line 36
    }

#line 36
    if(_S285)
    {

#line 36
        return;
    }

#line 37
    uint2 _S286 = tid_18.xy;

#line 37
    int2 _S287 = int2(_S286);

#line 37
    float4 _S288 = read0_0(_S287, &kernelContext_36);

#line 37
    float bd_0;

    if((_S288.x) < 10000.0f)
    {

#line 39
        bd_0 = length(_S288.xy + _S288.zw);

#line 39
    }
    else
    {

#line 39
        bd_0 = 1.0e+09f;

#line 39
    }
    int _S289 = (&kernelContext_36)->u_0->i_0.x;

#line 40
    float4 best_0 = _S288;

#line 40
    int j_3 = int(-1);
    for(;;)
    {

#line 41
        if(j_3 <= int(1))
        {
        }
        else
        {

#line 41
            break;
        }

#line 41
        float bd_1 = bd_0;

#line 41
        float4 best_1 = best_0;

#line 41
        int i_4 = int(-1);

#line 41
        for(;;)
        {

#line 41
            if(i_4 <= int(1))
            {
            }
            else
            {

#line 41
                break;
            }

#line 42
            if(i_4 == int(0))
            {

#line 42
                _S285 = j_3 == int(0);

#line 42
            }
            else
            {

#line 42
                _S285 = false;

#line 42
            }

#line 42
            if(_S285)
            {

#line 42
                i_4 = i_4 + int(1);

#line 41
                continue;
            }
            int2 q_13 = _S287 + int2(i_4, j_3) * int2(_S289) ;
            int _S290 = q_13.x;

#line 44
            bool _S291;

#line 44
            if(_S290 < int(0))
            {

#line 44
                _S291 = true;

#line 44
            }
            else
            {

#line 44
                _S291 = (q_13.y) < int(0);

#line 44
            }

#line 44
            bool _S292;

#line 44
            if(_S291)
            {

#line 44
                _S292 = true;

#line 44
            }
            else
            {

#line 44
                _S292 = _S290 >= W_2;

#line 44
            }

#line 44
            bool _S293;

#line 44
            if(_S292)
            {

#line 44
                _S293 = true;

#line 44
            }
            else
            {

#line 44
                _S293 = (q_13.y) >= H_2;

#line 44
            }

#line 44
            if(_S293)
            {

#line 44
                i_4 = i_4 + int(1);

#line 41
                continue;
            }

#line 41
            float4 _S294 = read0_0(q_13, &kernelContext_36);

#line 46
            if((_S294.x) >= 10000.0f)
            {

#line 46
                i_4 = i_4 + int(1);

#line 41
                continue;
            }

#line 47
            float2 ip_0 = float2(q_13 - _S287) + _S294.xy;
            float2 _S295 = _S294.zw;

#line 48
            float d_20 = length(ip_0 + _S295);

#line 48
            float bd_2;

#line 48
            float4 best_2;
            if(d_20 < bd_1)
            {

#line 49
                float4 _S296 = float4(ip_0, _S295);

#line 49
                bd_2 = d_20;

#line 49
                best_2 = _S296;

#line 49
            }
            else
            {

#line 49
                bd_2 = bd_1;

#line 49
                best_2 = best_1;

#line 49
            }

#line 49
            bd_1 = bd_2;

#line 49
            best_1 = best_2;

#line 41
            i_4 = i_4 + int(1);

#line 41
        }

#line 41
        int _S297 = j_3 + int(1);

#line 41
        bd_0 = bd_1;

#line 41
        best_0 = best_1;

#line 41
        j_3 = _S297;

#line 41
    }

#line 51
    (&kernelContext_36)->out0_0.write(best_0,_S286);
    return;
}



[[kernel]] void filterOutlineApply(uint3 tid_19 [[thread_position_in_grid]], texture2d<float, access::sample> in0_20 [[texture(0)]], FilterU_0 constant* u_20 [[buffer(0)]], texture2d<float, access::write> out0_20 [[texture(25)]], sampler zeroSampler_20 [[sampler(0)]], texture2d<float, access::sample> in1_20 [[texture(1)]], sampler edgeSampler_20 [[sampler(1)]])
{

#line 57
    thread KernelContext_0 kernelContext_37;

#line 57
    (&kernelContext_37)->in0_0 = in0_20;

#line 57
    (&kernelContext_37)->u_0 = u_20;

#line 57
    (&kernelContext_37)->out0_0 = out0_20;

#line 57
    (&kernelContext_37)->zeroSampler_0 = zeroSampler_20;

#line 57
    (&kernelContext_37)->in1_0 = in1_20;

#line 57
    (&kernelContext_37)->edgeSampler_0 = edgeSampler_20;

#line 57
    uint2 _S298 = outSize_0(&kernelContext_37);

#line 57
    bool _S299;

    if((tid_19.x) >= (_S298.x))
    {

#line 59
        _S299 = true;

#line 59
    }
    else
    {

#line 59
        _S299 = (tid_19.y) >= (_S298.y);

#line 59
    }

#line 59
    if(_S299)
    {

#line 59
        return;
    }

#line 60
    uint2 _S300 = tid_19.xy;

#line 60
    int2 _S301 = int2(_S300);

#line 60
    float4 _S302 = read0_0(_S301, &kernelContext_37);

#line 60
    float4 _S303 = read1_0(_S301, &kernelContext_37);

#line 60
    float d_21;

    if((_S303.x) < 10000.0f)
    {

#line 62
        d_21 = length(_S303.xy + _S303.zw);

#line 62
    }
    else
    {

#line 62
        d_21 = 1.0e+09f;

#line 62
    }
    float _S304 = _S302.w;

#line 63
    float sd_0;

#line 63
    if(_S304 >= 0.5f)
    {

#line 63
        sd_0 = - d_21;

#line 63
    }
    else
    {

#line 63
        sd_0 = d_21;

#line 63
    }
    float w_8 = (&kernelContext_37)->u_0->a_0.x;

#line 64
    float _S305 = max((&kernelContext_37)->u_0->a_0.y, 1.0f);
    float3 col_1 = (&kernelContext_37)->u_0->b_0.xyz;
    if(((&kernelContext_37)->u_0->i_0.x) == int(1))
    {

        (&kernelContext_37)->out0_0.write(float4(mix(_S302.xyz, col_1 * float3(_S304) , float3(clamp((w_8 + sd_0) / _S305 + 0.5f, 0.0f, 1.0f)) ), _S304),_S300);

#line 66
    }
    else
    {

        if(((&kernelContext_37)->u_0->i_0.x) == int(2))
        {

#line 71
            float cov_0 = clamp((0.5f * w_8 - abs(sd_0)) / _S305 + 0.5f, 0.0f, 1.0f);
            (&kernelContext_37)->out0_0.write(float4(col_1 * float3(cov_0) , cov_0) + _S302 * float4((1.0f - cov_0)) ,_S300);

#line 70
        }
        else
        {


            float cov_1 = clamp((w_8 - sd_0) / _S305 + 0.5f, 0.0f, 1.0f) * clamp(sd_0 + 1.0f, 0.0f, 1.0f);
            (&kernelContext_37)->out0_0.write(_S302 + float4(col_1 * float3(cov_1) , cov_1) * float4((1.0f - _S304)) ,_S300);

#line 70
        }

#line 66
    }

#line 78
    return;
}



[[kernel]] void filterLongShadowStep(uint3 tid_20 [[thread_position_in_grid]], texture2d<float, access::sample> in0_21 [[texture(0)]], FilterU_0 constant* u_21 [[buffer(0)]], texture2d<float, access::write> out0_21 [[texture(25)]], sampler zeroSampler_21 [[sampler(0)]], texture2d<float, access::sample> in1_21 [[texture(1)]], sampler edgeSampler_21 [[sampler(1)]])
{

#line 83
    thread KernelContext_0 kernelContext_38;

#line 83
    (&kernelContext_38)->in0_0 = in0_21;

#line 83
    (&kernelContext_38)->u_0 = u_21;

#line 83
    (&kernelContext_38)->out0_0 = out0_21;

#line 83
    (&kernelContext_38)->zeroSampler_0 = zeroSampler_21;

#line 83
    (&kernelContext_38)->in1_0 = in1_21;

#line 83
    (&kernelContext_38)->edgeSampler_0 = edgeSampler_21;

#line 83
    uint2 _S306 = outSize_0(&kernelContext_38);

#line 83
    bool _S307;

    if((tid_20.x) >= (_S306.x))
    {

#line 85
        _S307 = true;

#line 85
    }
    else
    {

#line 85
        _S307 = (tid_20.y) >= (_S306.y);

#line 85
    }

#line 85
    if(_S307)
    {

#line 85
        return;
    }

#line 86
    float2 _S308 = float2(_S306);
    uint2 _S309 = tid_20.xy;

#line 87
    float2 c_9 = float2(_S309) + float2(0.5f) ;
    float4 s0_0 = (((&kernelContext_38)->in0_0).sample(((&kernelContext_38)->zeroSampler_0), (c_9 / _S308), level((0.0f))));

#line 88
    float4 s1_0 = (((&kernelContext_38)->in0_0).sample(((&kernelContext_38)->zeroSampler_0), ((c_9 - (&kernelContext_38)->u_0->a_0.xy) / _S308), level((0.0f))));

#line 88
    float a0_0;
    if(((&kernelContext_38)->u_0->i_0.x) == int(1))
    {

#line 89
        a0_0 = s0_0.w;

#line 89
    }
    else
    {

#line 89
        a0_0 = s0_0.x;

#line 89
    }

#line 89
    float a1_0;

#line 89
    if(((&kernelContext_38)->u_0->i_0.x) == int(1))
    {

#line 89
        a1_0 = s1_0.w;

#line 89
    }
    else
    {

#line 89
        a1_0 = s1_0.x;

#line 89
    }
    (&kernelContext_38)->out0_0.write(float4(max(a0_0, a1_0 - (&kernelContext_38)->u_0->a_0.z)) ,_S309);
    return;
}


[[kernel]] void filterLongShadowApply(uint3 tid_21 [[thread_position_in_grid]], texture2d<float, access::sample> in0_22 [[texture(0)]], FilterU_0 constant* u_22 [[buffer(0)]], texture2d<float, access::write> out0_22 [[texture(25)]], sampler zeroSampler_22 [[sampler(0)]], texture2d<float, access::sample> in1_22 [[texture(1)]], sampler edgeSampler_22 [[sampler(1)]])
{

#line 95
    thread KernelContext_0 kernelContext_39;

#line 95
    (&kernelContext_39)->in0_0 = in0_22;

#line 95
    (&kernelContext_39)->u_0 = u_22;

#line 95
    (&kernelContext_39)->out0_0 = out0_22;

#line 95
    (&kernelContext_39)->zeroSampler_0 = zeroSampler_22;

#line 95
    (&kernelContext_39)->in1_0 = in1_22;

#line 95
    (&kernelContext_39)->edgeSampler_0 = edgeSampler_22;

#line 95
    uint2 _S310 = outSize_0(&kernelContext_39);

#line 95
    bool _S311;

    if((tid_21.x) >= (_S310.x))
    {

#line 97
        _S311 = true;

#line 97
    }
    else
    {

#line 97
        _S311 = (tid_21.y) >= (_S310.y);

#line 97
    }

#line 97
    if(_S311)
    {

#line 97
        return;
    }

#line 98
    uint2 _S312 = tid_21.xy;

#line 98
    float4 _S313 = read0_0(int2(_S312), &kernelContext_39);

    float s_10 = clamp((((&kernelContext_39)->in1_0).sample(((&kernelContext_39)->zeroSampler_0), ((float2(_S312) + float2(0.5f) ) / float2(_S310)), level((0.0f)))).x, 0.0f, 1.0f) * (&kernelContext_39)->u_0->a_0.w;
    (&kernelContext_39)->out0_0.write(_S313 + float4((&kernelContext_39)->u_0->b_0.xyz * float3(s_10) , s_10) * float4((1.0f - _S313.w)) ,_S312);
    return;
}

