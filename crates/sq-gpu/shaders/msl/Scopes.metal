#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 6 "crates/sq-gpu/shaders-src/Scopes.slang"
struct ScopeU_0
{
    uint width_0;
    uint height_0;
    uint stride_0;
    uint flags_0;
    uint waveW_0;
    uint waveL_0;
    uint vecN_0;
    uint rowWidth_0;
    uint offWaveLuma_0;
    uint offParade_0;
    uint offVector_0;
    uint offHist_0;
    uint offset_0;
    uint count_0;
    uint maxIndex_0;
    uint pad0_0;
    uint outW_0;
    uint outH_0;
    uint pad1_0;
    uint pad2_0;
};


#line 78
struct KernelContext_0
{
    ScopeU_0 constant* u_0;
    uint32_t device* counts_0;
    texture2d<float, access::sample> in0_0;
    texture2d<float, access::write> out0_0;
    array<uint, int(256)> threadgroup* groupMax_0;
};


#line 29
[[kernel]] void scopeClear(uint3 tid_0 [[thread_position_in_grid]], ScopeU_0 constant* u_1 [[buffer(0)]], uint32_t device* counts_1 [[buffer(2)]], texture2d<float, access::sample> in0_1 [[texture(0)]], texture2d<float, access::write> out0_1 [[texture(25)]])
{

#line 29
    thread KernelContext_0 kernelContext_0;

#line 29
    (&kernelContext_0)->u_0 = u_1;

#line 29
    (&kernelContext_0)->counts_0 = counts_1;

#line 29
    (&kernelContext_0)->in0_0 = in0_1;

#line 29
    (&kernelContext_0)->out0_0 = out0_1;

#line 29
    threadgroup array<uint, int(256)> groupMax_1;

#line 29
    (&kernelContext_0)->groupMax_0 = &groupMax_1;
    uint _S1 = tid_0.x;

#line 30
    uint i_0 = tid_0.y * u_1->rowWidth_0 + _S1;

#line 30
    bool _S2;
    if(_S1 < (u_1->rowWidth_0))
    {

#line 31
        _S2 = i_0 < ((&kernelContext_0)->u_0->count_0);

#line 31
    }
    else
    {

#line 31
        _S2 = false;

#line 31
    }

#line 31
    if(_S2)
    {

#line 31
        (&kernelContext_0)->counts_0[(((&kernelContext_0)->u_0->offset_0 + i_0) * 4U)>>2] = as_type<uint32_t>(0U);

#line 31
    }
    return;
}


#line 42 "crates/sq-gpu/shaders-src/Bindings.slang"
float4 read0_0(int2 p_0, KernelContext_0 thread* kernelContext_1)
{

#line 42
    int3 _S3 = int3(p_0, int(0));

#line 42
    return ((kernelContext_1->in0_0).read(vec<uint,2>(((_S3)).xy), uint(((_S3)).z)));
}


#line 21 "crates/sq-gpu/shaders-src/Scopes.slang"
float bt709OETF_0(float l_0)
{

#line 22
    if(l_0 < 0.018053969368338585f)
    {

#line 22
        return 4.5f * l_0;
    }

#line 23
    return 1.0992968082427979f * pow(l_0, 0.44999998807907104f) - 0.099296808242797852f;
}

uint levelOf_0(float v_0, uint levels_0)
{

#line 26
    return min(uint(v_0 * float(levels_0)), levels_0 - 1U);
}


#line 35
[[kernel]] void scopeAccumulate(uint3 tid_1 [[thread_position_in_grid]], ScopeU_0 constant* u_2 [[buffer(0)]], uint32_t device* counts_2 [[buffer(2)]], texture2d<float, access::sample> in0_2 [[texture(0)]], texture2d<float, access::write> out0_2 [[texture(25)]])
{

#line 35
    thread KernelContext_0 kernelContext_2;

#line 35
    (&kernelContext_2)->u_0 = u_2;

#line 35
    (&kernelContext_2)->counts_0 = counts_2;

#line 35
    (&kernelContext_2)->in0_0 = in0_2;

#line 35
    (&kernelContext_2)->out0_0 = out0_2;

#line 35
    threadgroup array<uint, int(256)> groupMax_2;

#line 35
    (&kernelContext_2)->groupMax_0 = &groupMax_2;
    uint x_0 = tid_1.x * u_2->stride_0;

#line 36
    uint y_0 = tid_1.y * u_2->stride_0;

#line 36
    bool _S4;
    if(x_0 >= (u_2->width_0))
    {

#line 37
        _S4 = true;

#line 37
    }
    else
    {

#line 37
        _S4 = y_0 >= ((&kernelContext_2)->u_0->height_0);

#line 37
    }

#line 37
    if(_S4)
    {

#line 37
        return;
    }

#line 37
    float4 _S5 = read0_0(int2(int(x_0), int(y_0)), &kernelContext_2);

    float3 c_0 = clamp(_S5.xyz, float3(0.0f) , float3(1.0f) );
    float _S6 = bt709OETF_0(c_0.x);

#line 40
    float _S7 = bt709OETF_0(c_0.y);

#line 40
    float _S8 = bt709OETF_0(c_0.z);

#line 40
    float3 s_0 = float3(_S6, _S7, _S8);
    float luma_0 = _S6 * 0.2125999927520752f + _S7 * 0.71520000696182251f + _S8 * 0.072200000286102295f;
    uint W_0 = (&kernelContext_2)->u_0->waveW_0;

#line 42
    uint L_0 = (&kernelContext_2)->u_0->waveL_0;
    uint _S9 = x_0 * (&kernelContext_2)->u_0->waveW_0 / u_2->width_0;

#line 43
    uint _S10 = min(_S9, W_0 - 1U);

    if((((&kernelContext_2)->u_0->flags_0) & 1U) != 0U)
    {
        uint _S11 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_2)->counts_0+((&kernelContext_2)->u_0->offWaveLuma_0 + (L_0 - 1U - levelOf_0(luma_0, L_0)) * W_0 + _S10) * 4U / 4U)), 1U, memory_order_relaxed);

#line 45
    }

#line 45
    uint ch_0;



    if((((&kernelContext_2)->u_0->flags_0) & 2U) != 0U)
    {

#line 49
        ch_0 = 0U;
        for(;;)
        {

#line 50
            if(ch_0 < 3U)
            {
            }
            else
            {

#line 50
                break;
            }
            uint _S12 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_2)->counts_0+((&kernelContext_2)->u_0->offParade_0 + (L_0 - 1U - levelOf_0(s_0[ch_0], L_0)) * 3U * W_0 + ch_0 * W_0 + _S10) * 4U / 4U)), 1U, memory_order_relaxed);

#line 50
            ch_0 = ch_0 + 1U;

#line 50
        }

#line 49
    }

#line 55
    if((((&kernelContext_2)->u_0->flags_0) & 4U) != 0U)
    {
        float nf_0 = float((&kernelContext_2)->u_0->vecN_0);
        float _S13 = nf_0 - 1.0f;

        uint _S14 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_2)->counts_0+((&kernelContext_2)->u_0->offVector_0 + uint(min(max(floor(nf_0 / 2.0f - (_S6 - luma_0) / 1.5748000144958496f * nf_0 + 0.5f), 0.0f), _S13)) * (&kernelContext_2)->u_0->vecN_0 + uint(min(max(floor((_S8 - luma_0) / 1.8555999994277954f * nf_0 + nf_0 / 2.0f + 0.5f), 0.0f), _S13))) * 4U / 4U)), 1U, memory_order_relaxed);

#line 55
    }

#line 62
    if((((&kernelContext_2)->u_0->flags_0) & 8U) != 0U)
    {

#line 62
        ch_0 = 0U;
        for(;;)
        {

#line 63
            if(ch_0 < 3U)
            {
            }
            else
            {

#line 63
                break;
            }

#line 64
            uint _S15 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_2)->counts_0+((&kernelContext_2)->u_0->offHist_0 + ch_0 * 256U + levelOf_0(s_0[ch_0], 256U)) * 4U / 4U)), 1U, memory_order_relaxed);

#line 63
            ch_0 = ch_0 + 1U;

#line 63
        }


        uint _S16 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_2)->counts_0+((&kernelContext_2)->u_0->offHist_0 + 768U + levelOf_0(luma_0, 256U)) * 4U / 4U)), 1U, memory_order_relaxed);

#line 62
    }

#line 68
    return;
}


#line 76
[[kernel]] void scopeFindMax(uint3 sv_groupthreadid_0 [[thread_position_in_threadgroup]], uint3 tid_2 [[thread_position_in_grid]], ScopeU_0 constant* u_3 [[buffer(0)]], uint32_t device* counts_3 [[buffer(2)]], texture2d<float, access::sample> in0_3 [[texture(0)]], texture2d<float, access::write> out0_3 [[texture(25)]])
{

#line 76
    thread KernelContext_0 kernelContext_3;

#line 76
    (&kernelContext_3)->u_0 = u_3;

#line 76
    (&kernelContext_3)->counts_0 = counts_3;

#line 76
    (&kernelContext_3)->in0_0 = in0_3;

#line 76
    (&kernelContext_3)->out0_0 = out0_3;

#line 76
    threadgroup array<uint, int(256)> groupMax_3;

#line 76
    (&kernelContext_3)->groupMax_0 = &groupMax_3;

#line 76
    uint sv_groupindex_0 = (sv_groupthreadid_0[int(2)] * 16U + sv_groupthreadid_0[int(1)]) * 16U + sv_groupthreadid_0[int(0)];
    uint _S17 = tid_2.x;

#line 77
    uint i_1 = tid_2.y * u_3->rowWidth_0 + _S17;

#line 77
    bool _S18;
    if(_S17 < (u_3->rowWidth_0))
    {

#line 78
        _S18 = i_1 < ((&kernelContext_3)->u_0->count_0);

#line 78
    }
    else
    {

#line 78
        _S18 = false;

#line 78
    }

#line 78
    uint s_1;

#line 78
    if(_S18)
    {

#line 78
        uint _S19 = as_type<uint>((&kernelContext_3)->counts_0[(uint(int(((&kernelContext_3)->u_0->offset_0 + i_1) * 4U)))>>2]);

#line 78
        s_1 = _S19;

#line 78
    }
    else
    {

#line 78
        s_1 = 0U;

#line 78
    }

#line 78
    groupMax_3[sv_groupindex_0] = s_1;
    threadgroup_barrier(mem_flags::mem_threadgroup);

#line 79
    s_1 = 128U;
    for(;;)
    {

#line 80
        if(s_1 > 0U)
        {
        }
        else
        {

#line 80
            break;
        }

#line 81
        if(sv_groupindex_0 < s_1)
        {

#line 81
            (*(&kernelContext_3)->groupMax_0)[sv_groupindex_0] = max((*(&kernelContext_3)->groupMax_0)[sv_groupindex_0], (*(&kernelContext_3)->groupMax_0)[sv_groupindex_0 + s_1]);

#line 81
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

#line 80
        s_1 = s_1 >> 1U;

#line 80
    }

#line 85
    if(sv_groupindex_0 == 0U)
    {

#line 85
        _S18 = ((*(&kernelContext_3)->groupMax_0)[int(0)]) > 0U;

#line 85
    }
    else
    {

#line 85
        _S18 = false;

#line 85
    }

#line 85
    if(_S18)
    {

#line 85
        uint _S20 = atomic_fetch_max_explicit(((atomic_uint device*)((&kernelContext_3)->counts_0+(&kernelContext_3)->u_0->maxIndex_0 * 4U / 4U)), (*(&kernelContext_3)->groupMax_0)[int(0)], memory_order_relaxed);

#line 85
    }
    return;
}

[[kernel]] void scopeResolve(uint3 tid_3 [[thread_position_in_grid]], ScopeU_0 constant* u_4 [[buffer(0)]], uint32_t device* counts_4 [[buffer(2)]], texture2d<float, access::sample> in0_4 [[texture(0)]], texture2d<float, access::write> out0_4 [[texture(25)]])
{

#line 89
    thread KernelContext_0 kernelContext_4;

#line 89
    (&kernelContext_4)->u_0 = u_4;

#line 89
    (&kernelContext_4)->counts_0 = counts_4;

#line 89
    (&kernelContext_4)->in0_0 = in0_4;

#line 89
    (&kernelContext_4)->out0_0 = out0_4;

#line 89
    threadgroup array<uint, int(256)> groupMax_4;

#line 89
    (&kernelContext_4)->groupMax_0 = &groupMax_4;
    uint _S21 = tid_3.x;

#line 90
    bool _S22;

#line 90
    if(_S21 >= (u_4->outW_0))
    {

#line 90
        _S22 = true;

#line 90
    }
    else
    {

#line 90
        _S22 = (tid_3.y) >= ((&kernelContext_4)->u_0->outH_0);

#line 90
    }

#line 90
    if(_S22)
    {

#line 90
        return;
    }

#line 91
    uint _S23 = as_type<uint>((&kernelContext_4)->counts_0[(uint(int(((&kernelContext_4)->u_0->offset_0 + tid_3.y * u_4->outW_0 + _S21) * 4U)))>>2]);
    uint _S24 = as_type<uint>((&kernelContext_4)->counts_0[(uint(int((&kernelContext_4)->u_0->maxIndex_0 * 4U)))>>2]);
    uint2 _S25 = tid_3.xy;

#line 93
    float _S26;

#line 93
    if(_S24 == 0U)
    {

#line 93
        _S26 = 0.0f;

#line 93
    }
    else
    {

#line 93
        _S26 = float(_S23) / float(_S24);

#line 93
    }

#line 93
    (&kernelContext_4)->out0_0.write(float4(_S26, 0.0f, 0.0f, 1.0f),_S25);
    return;
}

