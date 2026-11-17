#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 8 "crates/sq-gpu/shaders-src/GyroWarp.slang"
struct GyroWarpU_0
{
    uint2 dstSize_0;
    uint2 srcSize_0;
    uint2 mapSize_0;
    uint2 pad_0;
    float4 background_0;
};


#line 6 "crates/sq-gpu/shaders-src/Bindings.slang"
struct KernelContext_0
{
    GyroWarpU_0 constant* gu_0;
    uint32_t device* gyroMap_0;
    texture2d<float, access::write> out0_0;
    texture2d<float, access::sample> in0_0;
};


#line 19 "crates/sq-gpu/shaders-src/GyroWarp.slang"
float4 mapTexel_0(uint2 p_0, uint w_0, KernelContext_0 thread* kernelContext_0)
{

#line 19
    uint _S1 = (p_0.y * w_0 + p_0.x) * 16U;

#line 19
    uint _S2 = as_type<uint>(kernelContext_0->gyroMap_0[(_S1)>>2]);

#line 19
    uint _S3 = as_type<uint>(kernelContext_0->gyroMap_0[(_S1 + 4U)>>2]);

#line 19
    uint _S4 = as_type<uint>(kernelContext_0->gyroMap_0[(_S1 + 8U)>>2]);

#line 19
    uint _S5 = as_type<uint>(kernelContext_0->gyroMap_0[(_S1 + 12U)>>2]);

#line 19
    return (as_type<float4>((uint4(_S2, _S3, _S4, _S5))));
}


#line 21
void lanczos4_0(float x_0, array<float, int(8)> thread* c_0)
{

#line 21
    int i_0;
    if(x_0 < 1.1920928955078125e-07f)
    {

#line 22
        i_0 = int(0);
        for(;;)
        {

#line 23
            if(i_0 < int(8))
            {
            }
            else
            {

#line 23
                break;
            }

#line 23
            (*c_0)[i_0] = 0.0f;

#line 23
            i_0 = i_0 + int(1);

#line 23
        }
        (*c_0)[int(3)] = 1.0f;
        return;
    }

    array<float2, int(8)> _S6 = { { float2(1.0f, 0.0f), float2(-0.70710676908493042f, -0.70710676908493042f), float2(0.0f, 1.0f), float2(0.70710676908493042f, -0.70710676908493042f), float2(-1.0f, 0.0f), float2(0.70710676908493042f, 0.70710676908493042f), float2(0.0f, -1.0f), float2(-0.70710676908493042f, 0.70710676908493042f) } };

    float _S7 = x_0 + 3.0f;

#line 30
    float y0_0 = - _S7 * 0.78539818525314331f;
    float _S8 = sin(y0_0);

#line 31
    float _S9 = cos(y0_0);

#line 31
    i_0 = int(0);

#line 31
    float sum_0 = 0.0f;
    for(;;)
    {

#line 32
        if(i_0 < int(8))
        {
        }
        else
        {

#line 32
            break;
        }

#line 33
        float y_0 = - (_S7 - float(i_0)) * 0.78539818525314331f;
        float _S10 = (_S6[i_0].x * _S8 + _S6[i_0].y * _S9) / (y_0 * y_0);

#line 34
        (*c_0)[i_0] = _S10;
        float sum_1 = sum_0 + _S10;

#line 32
        i_0 = i_0 + int(1);

#line 32
        sum_0 = sum_1;

#line 32
    }

#line 37
    float _S11 = 1.0f / sum_0;

#line 37
    i_0 = int(0);
    for(;;)
    {

#line 38
        if(i_0 < int(8))
        {
        }
        else
        {

#line 38
            break;
        }

#line 38
        (*c_0)[i_0] = (*c_0)[i_0] * _S11;

#line 38
        i_0 = i_0 + int(1);

#line 38
    }
    return;
}


#line 42 "crates/sq-gpu/shaders-src/Bindings.slang"
float4 read0_0(int2 p_1, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S12 = int3(p_1, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S12)).xy), uint(((_S12)).z)));
}


#line 42 "crates/sq-gpu/shaders-src/GyroWarp.slang"
[[kernel]] void gyroWarp(uint3 tid_0 [[thread_position_in_grid]], GyroWarpU_0 constant* gu_1 [[buffer(0)]], uint32_t device* gyroMap_1 [[buffer(2)]], texture2d<float, access::write> out0_1 [[texture(25)]], texture2d<float, access::sample> in0_1 [[texture(0)]])
{

#line 42
    thread KernelContext_0 kernelContext_2;

#line 42
    (&kernelContext_2)->gu_0 = gu_1;

#line 42
    (&kernelContext_2)->gyroMap_0 = gyroMap_1;

#line 42
    (&kernelContext_2)->out0_0 = out0_1;

#line 42
    (&kernelContext_2)->in0_0 = in0_1;
    GyroWarpU_0 p_2 = *gu_1;

#line 43
    bool _S13;
    if((tid_0.x) >= ((*gu_1).dstSize_0.x))
    {

#line 44
        _S13 = true;

#line 44
    }
    else
    {

#line 44
        _S13 = (tid_0.y) >= (p_2.dstSize_0.y);

#line 44
    }

#line 44
    if(_S13)
    {

#line 44
        return;
    }

#line 45
    uint2 gid_0 = tid_0.xy;

#line 45
    float2 _S14 = float2(0.5f) ;
    float2 m_0 = (float2(gid_0) + _S14) * float2(p_2.mapSize_0) / float2(p_2.dstSize_0) - _S14;
    int2 _S15 = int2(int(0), int(0));

#line 47
    int2 _S16 = int2(p_2.mapSize_0);

#line 47
    int2 i0_0 = clamp(int2(floor(m_0)), _S15, max(_S16 - int2(int(2)) , _S15));

#line 47
    int2 _S17 = int2(int(1)) ;
    int2 _S18 = min(i0_0 + _S17, _S16 - _S17);
    float2 t_0 = m_0 - float2(i0_0);
    uint w_1 = p_2.mapSize_0.x;

#line 50
    float4 _S19 = mapTexel_0(uint2(i0_0), w_1, &kernelContext_2);

#line 50
    float4 _S20 = mapTexel_0(uint2(uint(_S18.x), uint(i0_0.y)), w_1, &kernelContext_2);

#line 50
    float4 _S21 = mapTexel_0(uint2(uint(i0_0.x), uint(_S18.y)), w_1, &kernelContext_2);

#line 50
    float4 _S22 = mapTexel_0(uint2(_S18), w_1, &kernelContext_2);


    if((min(min(_S19.z, _S20.z), min(_S21.z, _S22.z))) < 0.5f)
    {

#line 53
        (&kernelContext_2)->out0_0.write(p_2.background_0,gid_0);

#line 53
        return;
    }

#line 54
    float2 _S23 = float2(t_0.x) ;

#line 54
    float2 _S24 = float2(32.0f) ;

    int2 _S25 = int2(round((mix(mix(_S19.xy, _S20.xy, _S23), mix(_S21.xy, _S22.xy, _S23), float2(t_0.y) ) * float2(p_2.srcSize_0) - float2(3.0f) ) * _S24));
    int2 _S26 = _S25 >> (uint2(5U) );
    float2 f_0 = float2(_S25 & (int2(int(31)) )) / _S24;
    thread array<float, int(8)> cx_0;

    lanczos4_0(f_0.x, &cx_0);

#line 60
    thread array<float, int(8)> cy_0;

    lanczos4_0(f_0.y, &cy_0);
    int2 _S27 = int2(p_2.srcSize_0);
    float4 _S28 = float4(0.0f, 0.0f, 0.0f, 0.0f);

#line 64
    int yp_0 = int(0);

#line 64
    float4 sum_2 = _S28;
    for(;;)
    {

#line 65
        if(yp_0 < int(8))
        {
        }
        else
        {

#line 65
            break;
        }

#line 66
        int sy_0 = _S26.y + yp_0;
        if(sy_0 < int(0))
        {

#line 67
            _S13 = true;

#line 67
        }
        else
        {

#line 67
            _S13 = sy_0 >= (_S27.y);

#line 67
        }

#line 67
        if(_S13)
        {

#line 67
            sum_2 = sum_2 + p_2.background_0 * float4(cy_0[yp_0]) ;

#line 67
            yp_0 = yp_0 + int(1);

#line 65
            continue;
        }

#line 65
        int xp_0 = int(0);

#line 65
        float4 row_0 = _S28;



        for(;;)
        {

#line 69
            if(xp_0 < int(8))
            {
            }
            else
            {

#line 69
                break;
            }

#line 70
            int sx_0 = _S26.x + xp_0;

#line 70
            bool _S29;
            if(sx_0 >= int(0))
            {

#line 71
                _S29 = sx_0 < (_S27.x);

#line 71
            }
            else
            {

#line 71
                _S29 = false;

#line 71
            }

#line 71
            float4 px_0;

#line 71
            if(_S29)
            {

#line 71
                float4 _S30 = read0_0(int2(sx_0, sy_0), &kernelContext_2);

#line 71
                px_0 = _S30;

#line 71
            }
            else
            {

#line 71
                px_0 = p_2.background_0;

#line 71
            }
            float4 row_1 = row_0 + px_0 * float4(cx_0[xp_0]) ;

#line 69
            xp_0 = xp_0 + int(1);

#line 69
            row_0 = row_1;

#line 69
        }

#line 69
        sum_2 = sum_2 + row_0 * float4(cy_0[yp_0]) ;

#line 65
        yp_0 = yp_0 + int(1);

#line 65
    }

#line 76
    (&kernelContext_2)->out0_0.write(clamp(sum_2, _S28, float4(1.0f, 1.0f, 1.0f, 1.0f)),gid_0);
    return;
}

