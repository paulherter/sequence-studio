#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 3 "crates/sq-gpu/shaders-src/Blur.slang"
struct BlurU_0
{
    int2 axis_0;
    int radius_0;
    int clampEdges_0;
    int2 lo_0;
    int2 hi_0;
};


#line 10
struct BlurW_0
{
    array<float4, int(32)> w_0;
};


#line 5811 "hlsl.meta.slang"
struct KernelContext_0
{
    texture2d<float, access::sample> in0_0;
    BlurU_0 constant* u_0;
    BlurW_0 constant* wts_0;
    texture2d<float, access::write> out0_0;
};


#line 41 "crates/sq-gpu/shaders-src/Bindings.slang"
uint2 inSize_0(KernelContext_0 thread* kernelContext_0)
{

#line 41
    texture2d<float, access::sample> _S1 = kernelContext_0->in0_0;

#line 41
    thread uint w_1;

#line 41
    thread uint h_0;

#line 41
    (*((&w_1)) = (_S1).get_width(0)),(*((&h_0)) = (_S1).get_height(0));

#line 41
    return uint2(w_1, h_0);
}


#line 42
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S2 = int3(p_0, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S2)).xy), uint(((_S2)).z)));
}


#line 19 "crates/sq-gpu/shaders-src/Blur.slang"
float weight_0(int j_0, KernelContext_0 thread* kernelContext_2)
{

#line 19
    return kernelContext_2->wts_0->w_0[j_0 >> 2U][j_0 & int(3)];
}


[[kernel]] void gaussianBlur1D(uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::sample> in0_1 [[texture(0)]], BlurU_0 constant* u_1 [[buffer(0)]], BlurW_0 constant* wts_1 [[buffer(1)]], texture2d<float, access::write> out0_1 [[texture(25)]])
{

#line 23
    thread KernelContext_0 kernelContext_3;

#line 23
    (&kernelContext_3)->in0_0 = in0_1;

#line 23
    (&kernelContext_3)->u_0 = u_1;

#line 23
    (&kernelContext_3)->wts_0 = wts_1;

#line 23
    (&kernelContext_3)->out0_0 = out0_1;

#line 23
    uint2 _S3 = inSize_0(&kernelContext_3);

    int W_0 = int(_S3.x);

#line 25
    int H_0 = int(_S3.y);
    uint2 _S4 = tid_0.xy;

#line 26
    int2 _S5 = int2(_S4);

#line 26
    bool _S6;
    if((_S5.x) >= W_0)
    {

#line 27
        _S6 = true;

#line 27
    }
    else
    {

#line 27
        _S6 = (_S5.y) >= H_0;

#line 27
    }

#line 27
    if(_S6)
    {

#line 27
        return;
    }

#line 28
    float4 _S7 = float4(0.0f) ;

#line 28
    int k_0;

#line 28
    float4 acc_0;
    if(((&kernelContext_3)->u_0->clampEdges_0) != int(0))
    {

#line 29
        k_0 = - (&kernelContext_3)->u_0->radius_0;

#line 29
        acc_0 = _S7;
        for(;;)
        {

#line 30
            if(k_0 <= ((&kernelContext_3)->u_0->radius_0))
            {
            }
            else
            {

#line 30
                break;
            }

#line 30
            float4 _S8 = read0_0(clamp(_S5 + (&kernelContext_3)->u_0->axis_0 * int2(k_0) , (&kernelContext_3)->u_0->lo_0, (&kernelContext_3)->u_0->hi_0), &kernelContext_3);

#line 30
            float _S9 = weight_0(k_0 + (&kernelContext_3)->u_0->radius_0, &kernelContext_3);

            float4 acc_1 = acc_0 + _S8 * float4(_S9) ;

#line 30
            k_0 = k_0 + int(1);

#line 30
            acc_0 = acc_1;

#line 30
        }

#line 29
    }
    else
    {

#line 29
        k_0 = - (&kernelContext_3)->u_0->radius_0;

#line 29
        acc_0 = _S7;

#line 35
        for(;;)
        {

#line 35
            if(k_0 <= ((&kernelContext_3)->u_0->radius_0))
            {
            }
            else
            {

#line 35
                break;
            }

#line 36
            int2 p_1 = _S5 + (&kernelContext_3)->u_0->axis_0 * int2(k_0) ;
            int _S10 = p_1.x;

#line 37
            if(_S10 < int(0))
            {

#line 37
                _S6 = true;

#line 37
            }
            else
            {

#line 37
                _S6 = (p_1.y) < int(0);

#line 37
            }

#line 37
            bool _S11;

#line 37
            if(_S6)
            {

#line 37
                _S11 = true;

#line 37
            }
            else
            {

#line 37
                _S11 = _S10 >= W_0;

#line 37
            }

#line 37
            bool _S12;

#line 37
            if(_S11)
            {

#line 37
                _S12 = true;

#line 37
            }
            else
            {

#line 37
                _S12 = (p_1.y) >= H_0;

#line 37
            }

#line 37
            if(_S12)
            {

#line 37
                k_0 = k_0 + int(1);

#line 35
                continue;
            }

#line 35
            float4 _S13 = read0_0(p_1, &kernelContext_3);

#line 35
            float _S14 = weight_0(k_0 + (&kernelContext_3)->u_0->radius_0, &kernelContext_3);

#line 35
            acc_0 = acc_0 + _S13 * float4(_S14) ;

#line 35
            k_0 = k_0 + int(1);

#line 35
        }

#line 29
    }

#line 41
    (&kernelContext_3)->out0_0.write(acc_0,_S4);
    return;
}

