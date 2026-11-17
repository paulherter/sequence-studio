#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 7 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    texture2d<float, access::write> out0_0;
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


#line 42
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S2 = int3(p_0, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S2)).xy), uint(((_S2)).z)));
}


#line 8 "crates/sq-gpu/shaders-src/DisplayGamma.slang"
[[kernel]] void displayGamma(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::sample> in1_1 [[texture(1)]])
{

#line 8
    thread KernelContext_0 kernelContext_2;

#line 8
    (&kernelContext_2)->out0_0 = out0_1;

#line 8
    (&kernelContext_2)->in0_0 = in0_1;

#line 8
    (&kernelContext_2)->in1_0 = in1_1;

#line 8
    uint2 _S3 = outSize_0(&kernelContext_2);

#line 8
    bool _S4;

    if((tid_0.x) >= (_S3.x))
    {

#line 10
        _S4 = true;

#line 10
    }
    else
    {

#line 10
        _S4 = (tid_0.y) >= (_S3.y);

#line 10
    }

#line 10
    if(_S4)
    {

#line 10
        return;
    }

#line 11
    uint2 _S5 = tid_0.xy;

#line 11
    float4 _S6 = read0_0(int2(_S5), &kernelContext_2);
    uint3 _S7 = uint3(round(saturate(_S6.xyz) * float3(255.0f) ));
    int3 _S8 = int3(int(_S7.x), int(0), int(0));
    int3 _S9 = int3(int(_S7.y), int(0), int(0));
    int3 _S10 = int3(int(_S7.z), int(0), int(0));
    (&kernelContext_2)->out0_0.write(float4((((&kernelContext_2)->in1_0).read(vec<uint,2>(((_S8)).xy), uint(((_S8)).z))).x, (((&kernelContext_2)->in1_0).read(vec<uint,2>(((_S9)).xy), uint(((_S9)).z))).x, (((&kernelContext_2)->in1_0).read(vec<uint,2>(((_S10)).xy), uint(((_S10)).z))).x, _S6.w),_S5);
    return;
}

