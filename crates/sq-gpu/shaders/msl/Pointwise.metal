#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 2 "crates/sq-gpu/shaders-src/Pointwise.slang"
struct PointU_0
{
    float2 p_0;
    float2 pad_0;
};


#line 1134 "core"
struct KernelContext_0
{
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::sample> in1_0;
    PointU_0 constant* u_0;
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


#line 42
float4 read0_0(int2 p_1, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S2 = int3(p_1, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S2)).xy), uint(((_S2)).z)));
}


#line 14 "crates/sq-gpu/shaders-src/Pointwise.slang"
float3 oetf709_0(float3 l_0)
{

#line 15
    float3 _S3 = max(l_0, float3(0.0f) );

    return select(float3(1.0992968082427979f)  * pow(_S3, float3(0.44999998807907104f) ) - float3(0.099296823143959045f) , _S3 * float3(4.5f) , _S3 < (float3(0.018053969368338585f) ));
}



[[kernel]] void premultipliedLinearToEncoded709(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]], PointU_0 constant* u_1 [[buffer(0)]])
{

#line 22
    thread KernelContext_0 kernelContext_2;

#line 22
    (&kernelContext_2)->out0_0 = out0_1;

#line 22
    (&kernelContext_2)->in0_0 = in0_1;

#line 22
    (&kernelContext_2)->in1_0 = in1_1;

#line 22
    (&kernelContext_2)->u_0 = u_1;

#line 22
    uint2 _S4 = outSize_0(&kernelContext_2);

#line 22
    bool _S5;

    if((tid_0.x) >= (_S4.x))
    {

#line 24
        _S5 = true;

#line 24
    }
    else
    {

#line 24
        _S5 = (tid_0.y) >= (_S4.y);

#line 24
    }

#line 24
    if(_S5)
    {

#line 24
        return;
    }

#line 25
    uint2 _S6 = tid_0.xy;

#line 25
    float4 _S7 = read0_0(int2(_S6), &kernelContext_2);
    float _S8 = _S7.w;

#line 26
    float3 st_0;

#line 26
    if(_S8 > 0.0f)
    {

#line 26
        st_0 = _S7.xyz / float3(_S8) ;

#line 26
    }
    else
    {

#line 26
        st_0 = float3(0.0f) ;

#line 26
    }
    (&kernelContext_2)->out0_0.write(float4(oetf709_0(st_0), _S8),_S6);
    return;
}


[[kernel]] void straightToPremultiplied(uint3 tid_1 [[thread_position_in_grid]], texture2d<float, access::write> out0_2 [[texture(25)]], texture2d<float, access::sample> in0_2 [[texture(0)]], texture2d<float, access::sample> in1_2 [[texture(1)]], PointU_0 constant* u_2 [[buffer(0)]])
{

#line 32
    thread KernelContext_0 kernelContext_3;

#line 32
    (&kernelContext_3)->out0_0 = out0_2;

#line 32
    (&kernelContext_3)->in0_0 = in0_2;

#line 32
    (&kernelContext_3)->in1_0 = in1_2;

#line 32
    (&kernelContext_3)->u_0 = u_2;

#line 32
    uint2 _S9 = outSize_0(&kernelContext_3);

#line 32
    bool _S10;

    if((tid_1.x) >= (_S9.x))
    {

#line 34
        _S10 = true;

#line 34
    }
    else
    {

#line 34
        _S10 = (tid_1.y) >= (_S9.y);

#line 34
    }

#line 34
    if(_S10)
    {

#line 34
        return;
    }

#line 35
    uint2 _S11 = tid_1.xy;

#line 35
    float4 _S12 = read0_0(int2(_S11), &kernelContext_3);
    float _S13 = _S12.w;

#line 36
    (&kernelContext_3)->out0_0.write(float4(_S12.xyz * float3(_S13) , _S13),_S11);
    return;
}


#line 43 "crates/sq-gpu/shaders-src/Bindings.slang"
float4 read1_0(int2 p_2, KernelContext_0 thread* kernelContext_4)
{

#line 43
    int3 _S14 = int3(p_2, int(0));

#line 43
    return ((kernelContext_4->in1_0).read(vec<uint,2>(((_S14)).xy), uint(((_S14)).z)));
}


#line 6 "crates/sq-gpu/shaders-src/Pointwise.slang"
float3 inverseOETF709_0(float3 e_0)
{

#line 7
    float3 _S15 = max(e_0, float3(0.0f) );


    return select(pow((_S15 + float3(0.099296823143959045f) ) / float3(1.0992968082427979f) , float3(2.2222223281860352f) ), _S15 / float3(4.5f) , _S15 < (float3(0.081242859363555908f) ));
}


#line 41
[[kernel]] void blendFrames(uint3 tid_2 [[thread_position_in_grid]], texture2d<float, access::write> out0_3 [[texture(25)]], texture2d<float, access::sample> in0_3 [[texture(0)]], texture2d<float, access::sample> in1_3 [[texture(1)]], PointU_0 constant* u_3 [[buffer(0)]])
{

#line 41
    thread KernelContext_0 kernelContext_5;

#line 41
    (&kernelContext_5)->out0_0 = out0_3;

#line 41
    (&kernelContext_5)->in0_0 = in0_3;

#line 41
    (&kernelContext_5)->in1_0 = in1_3;

#line 41
    (&kernelContext_5)->u_0 = u_3;

#line 41
    uint2 _S16 = outSize_0(&kernelContext_5);

#line 41
    bool _S17;

    if((tid_2.x) >= (_S16.x))
    {

#line 43
        _S17 = true;

#line 43
    }
    else
    {

#line 43
        _S17 = (tid_2.y) >= (_S16.y);

#line 43
    }

#line 43
    if(_S17)
    {

#line 43
        return;
    }

#line 44
    uint2 _S18 = tid_2.xy;

#line 44
    int2 _S19 = int2(_S18);

#line 44
    float4 _S20 = read0_0(_S19, &kernelContext_5);

#line 44
    thread float4 x_0 = _S20;

#line 44
    float4 _S21 = read1_0(_S19, &kernelContext_5);

#line 44
    thread float4 y_0 = _S21;
    if(((&kernelContext_5)->u_0->p_0.y) != 0.0f)
    {

#line 45
        x_0.xyz = inverseOETF709_0(x_0.xyz);

#line 45
        y_0.xyz = inverseOETF709_0(y_0.xyz);

#line 45
    }
    if((x_0.w) < 1.0f)
    {

#line 46
        _S17 = true;

#line 46
    }
    else
    {

#line 46
        _S17 = (y_0.w) < 1.0f;

#line 46
    }

#line 46
    if(_S17)
    {
        float4 m_0 = mix(float4(x_0.xyz * float3(x_0.w) , x_0.w), float4(y_0.xyz * float3(y_0.w) , y_0.w), float4((&kernelContext_5)->u_0->p_0.x) );
        float _S22 = m_0.w;

#line 49
        float3 _S23;

#line 49
        if(_S22 > 0.0f)
        {

#line 49
            _S23 = m_0.xyz / float3(_S22) ;

#line 49
        }
        else
        {

#line 49
            _S23 = float3(0.0f) ;

#line 49
        }

#line 49
        (&kernelContext_5)->out0_0.write(float4(_S23, _S22),_S18);
        return;
    }
    (&kernelContext_5)->out0_0.write(mix(x_0, y_0, float4((&kernelContext_5)->u_0->p_0.x) ),_S18);
    return;
}


#line 41 "crates/sq-gpu/shaders-src/Bindings.slang"
uint2 inSize_0(KernelContext_0 thread* kernelContext_6)
{

#line 41
    texture2d<float, access::sample> _S24 = kernelContext_6->in0_0;

#line 41
    thread uint w_1;

#line 41
    thread uint h_1;

#line 41
    (*((&w_1)) = (_S24).get_width(0)),(*((&h_1)) = (_S24).get_height(0));

#line 41
    return uint2(w_1, h_1);
}


#line 57 "crates/sq-gpu/shaders-src/Pointwise.slang"
[[kernel]] void antiFlickerVertical(uint3 tid_3 [[thread_position_in_grid]], texture2d<float, access::write> out0_4 [[texture(25)]], texture2d<float, access::sample> in0_4 [[texture(0)]], texture2d<float, access::sample> in1_4 [[texture(1)]], PointU_0 constant* u_4 [[buffer(0)]])
{

#line 57
    thread KernelContext_0 kernelContext_7;

#line 57
    (&kernelContext_7)->out0_0 = out0_4;

#line 57
    (&kernelContext_7)->in0_0 = in0_4;

#line 57
    (&kernelContext_7)->in1_0 = in1_4;

#line 57
    (&kernelContext_7)->u_0 = u_4;

#line 57
    uint2 _S25 = inSize_0(&kernelContext_7);

    int H_0 = int(_S25.y);
    uint _S26 = tid_3.x;

#line 60
    bool _S27;

#line 60
    if(_S26 >= (_S25.x))
    {

#line 60
        _S27 = true;

#line 60
    }
    else
    {

#line 60
        _S27 = int(tid_3.y) >= H_0;

#line 60
    }

#line 60
    if(_S27)
    {

#line 60
        return;
    }

#line 61
    int y_1 = int(tid_3.y);

#line 61
    int x_1 = int(_S26);
    float k_0 = (&kernelContext_7)->u_0->p_0.x;

#line 62
    float4 _S28 = read0_0(int2(x_1, max(y_1 - int(1), int(0))), &kernelContext_7);

#line 62
    float4 _S29 = read0_0(int2(x_1, y_1), &kernelContext_7);

#line 62
    float4 _S30 = read0_0(int2(x_1, min(y_1 + int(1), H_0 - int(1))), &kernelContext_7);

#line 62
    float4 _S31 = float4(k_0) ;

    (&kernelContext_7)->out0_0.write(_S31 * _S28 + float4((1.0f - 2.0f * k_0))  * _S29 + _S31 * _S30,tid_3.xy);
    return;
}

