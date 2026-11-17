#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 4 "crates/sq-gpu/shaders-src/DeflickerGains.slang"
struct DeflickerU_0
{
    uint frames_0;
    uint tiles_0;
    uint dfBefore_0;
    uint dfAfter_0;
    uint statsBefore_0;
    uint local_0;
    float strength_0;
    float pad_0;
};


#line 11
struct KernelContext_0
{
    DeflickerU_0 constant* du_0;
    uint32_t device* means_0;
    uint32_t device* gains_0;
};


#line 14
float frameMean_0(uint j_0, uint tiles_1, KernelContext_0 thread* kernelContext_0)
{

#line 14
    uint i_0 = 0U;

#line 14
    float s_0 = 0.0f;

    for(;;)
    {

#line 16
        if(i_0 < tiles_1)
        {
        }
        else
        {

#line 16
            break;
        }

#line 16
        uint _S1 = as_type<uint>(kernelContext_0->means_0[(uint(int((j_0 * tiles_1 + i_0) * 4U)))>>2]);

#line 16
        float s_1 = s_0 + (as_type<float>((_S1)));

#line 16
        i_0 = i_0 + 1U;

#line 16
        s_0 = s_1;

#line 16
    }
    return max(s_0 / float(tiles_1), 0.0010000000474974513f);
}



[[kernel]] void deflickerGains(uint3 tid_0 [[thread_position_in_grid]], DeflickerU_0 constant* du_1 [[buffer(0)]], uint32_t device* means_1 [[buffer(2)]], uint32_t device* gains_1 [[buffer(3)]])
{

#line 22
    float mj_0;

#line 22
    uint j_1;

#line 22
    uint _S2;

#line 22
    thread KernelContext_0 kernelContext_1;

#line 22
    (&kernelContext_1)->du_0 = du_1;

#line 22
    (&kernelContext_1)->means_0 = means_1;

#line 22
    (&kernelContext_1)->gains_0 = gains_1;
    DeflickerU_0 d_0 = *du_1;
    uint tile_0 = tid_0.x;

#line 24
    bool _S3;
    if((tid_0.y) != 0U)
    {

#line 25
        _S3 = true;

#line 25
    }
    else
    {

#line 25
        _S3 = tile_0 >= (d_0.tiles_0);

#line 25
    }

#line 25
    if(_S3)
    {

#line 25
        return;
    }

#line 26
    bool local_1 = (d_0.local_0) != 0U;

#line 26
    float m0_0;
    if(local_1)
    {

#line 27
        uint _S4 = as_type<uint>((&kernelContext_1)->means_0[(uint(int(tile_0 * 4U)))>>2]);

#line 27
        m0_0 = max((as_type<float>((_S4))), 0.0010000000474974513f);

#line 27
    }
    else
    {

#line 27
        float _S5 = frameMean_0(0U, d_0.tiles_0, &kernelContext_1);

#line 27
        m0_0 = _S5;

#line 27
    }

#line 27
    uint k_0 = 0U;

#line 27
    float sum_0 = m0_0;

#line 27
    float n_0 = 1.0f;

    for(;;)
    {

#line 29
        if(k_0 < (d_0.dfBefore_0 + d_0.dfAfter_0))
        {
        }
        else
        {

#line 29
            break;
        }

#line 30
        if(k_0 < (d_0.dfBefore_0))
        {

#line 30
            j_1 = 1U + k_0;

#line 30
        }
        else
        {

#line 30
            j_1 = 1U + d_0.statsBefore_0 + (k_0 - d_0.dfBefore_0);

#line 30
        }
        if(local_1)
        {

#line 31
            uint _S6 = as_type<uint>((&kernelContext_1)->means_0[(uint(int((j_1 * d_0.tiles_0 + tile_0) * 4U)))>>2]);

#line 31
            mj_0 = max((as_type<float>((_S6))), 0.0010000000474974513f);

#line 31
        }
        else
        {

#line 31
            float _S7 = frameMean_0(j_1, d_0.tiles_0, &kernelContext_1);

#line 31
            mj_0 = _S7;

#line 31
        }
        if(local_1)
        {

#line 33
            float _S8 = log(mj_0 / m0_0);

#line 33
            uint i_1 = 0U;

#line 33
            uint agree_0 = 0U;

            for(;;)
            {

#line 35
                _S2 = d_0.tiles_0;

#line 35
                if(i_1 < (d_0.tiles_0))
                {
                }
                else
                {

#line 35
                    break;
                }

#line 36
                uint _S9 = as_type<uint>((&kernelContext_1)->means_0[(uint(int((j_1 * d_0.tiles_0 + i_1) * 4U)))>>2]);

#line 36
                float _S10 = max((as_type<float>((_S9))), 0.0010000000474974513f);

#line 36
                uint _S11 = as_type<uint>((&kernelContext_1)->means_0[(uint(int(i_1 * 4U)))>>2]);
                if((abs(log(_S10 / max((as_type<float>((_S11))), 0.0010000000474974513f)) - _S8)) < 0.11999999731779099f)
                {

#line 37
                    agree_0 = agree_0 + 1U;

#line 37
                }

#line 35
                i_1 = i_1 + 1U;

#line 35
            }



            if((agree_0 * 2U) < _S2)
            {

#line 39
                k_0 = k_0 + 1U;

#line 29
                continue;
            }

        }

#line 41
        float n_1 = n_0 + 1.0f;

#line 41
        sum_0 = sum_0 + mj_0;

#line 41
        n_0 = n_1;

#line 29
        k_0 = k_0 + 1U;

#line 29
    }

#line 43
    float _S12 = sum_0 / n_0;

#line 43
    j_1 = 0U;
    for(;;)
    {

#line 44
        if(j_1 < (d_0.frames_0))
        {
        }
        else
        {

#line 44
            break;
        }

#line 45
        if(local_1)
        {

#line 45
            uint _S13 = as_type<uint>((&kernelContext_1)->means_0[(uint(int((j_1 * d_0.tiles_0 + tile_0) * 4U)))>>2]);

#line 45
            mj_0 = max((as_type<float>((_S13))), 0.0010000000474974513f);

#line 45
        }
        else
        {

#line 45
            float _S14 = frameMean_0(j_1, d_0.tiles_0, &kernelContext_1);

#line 45
            mj_0 = _S14;

#line 45
        }

        (&kernelContext_1)->gains_0[((j_1 * d_0.tiles_0 + tile_0) * 4U)>>2] = as_type<uint32_t>((as_type<uint>((1.0f + (clamp(_S12 / mj_0, 0.5f, 2.0f) - 1.0f) * d_0.strength_0))));

#line 44
        j_1 = j_1 + 1U;

#line 44
    }

#line 49
    return;
}

