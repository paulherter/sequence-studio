#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 5 "crates/sq-gpu/shaders-src/TransitionCover.slang"
struct CoverU_0
{
    uint slot_0;
    uint pad0_0;
    uint pad1_0;
    uint pad2_0;
};


#line 17
struct KernelContext_0
{
    texture2d<float, access::sample> in0_0;
    CoverU_0 constant* vu_0;
    uint32_t device* cover_0;
    array<float, int(256)> threadgroup* lowest_0;
};


#line 41 "crates/sq-gpu/shaders-src/Bindings.slang"
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


#line 13 "crates/sq-gpu/shaders-src/TransitionCover.slang"
[[kernel]] void transitionCoverMin(uint3 sv_groupthreadid_0 [[thread_position_in_threadgroup]], uint3 tid_0 [[thread_position_in_grid]], texture2d<float, access::sample> in0_1 [[texture(0)]], CoverU_0 constant* vu_1 [[buffer(0)]], uint32_t device* cover_1 [[buffer(2)]])
{

#line 13
    thread KernelContext_0 kernelContext_1;

#line 13
    (&kernelContext_1)->in0_0 = in0_1;

#line 13
    (&kernelContext_1)->vu_0 = vu_1;

#line 13
    (&kernelContext_1)->cover_0 = cover_1;

#line 13
    threadgroup array<float, int(256)> lowest_1;

#line 13
    (&kernelContext_1)->lowest_0 = &lowest_1;

#line 13
    uint sv_groupindex_0 = (sv_groupthreadid_0[int(2)] * 16U + sv_groupthreadid_0[int(1)]) * 16U + sv_groupthreadid_0[int(0)];

#line 13
    uint2 _S2 = inSize_0(&kernelContext_1);

#line 13
    bool _S3;


    if((tid_0.x) < (_S2.x))
    {

#line 16
        _S3 = (tid_0.y) < (_S2.y);

#line 16
    }
    else
    {

#line 16
        _S3 = false;

#line 16
    }

#line 16
    float a_0;

#line 16
    if(_S3)
    {

#line 16
        int3 _S4 = int3(int2(tid_0.xy), int(0));

#line 16
        a_0 = max((((&kernelContext_1)->in0_0).read(vec<uint,2>(((_S4)).xy), uint(((_S4)).z))).w, 0.0f);

#line 16
    }
    else
    {

#line 16
        a_0 = 1.0f;

#line 16
    }
    (*(&kernelContext_1)->lowest_0)[sv_groupindex_0] = a_0;
    threadgroup_barrier(mem_flags::mem_threadgroup);

#line 18
    uint w_1 = 128U;
    for(;;)
    {

#line 19
        if(w_1 > 0U)
        {
        }
        else
        {

#line 19
            break;
        }

#line 20
        if(sv_groupindex_0 < w_1)
        {

#line 20
            (*(&kernelContext_1)->lowest_0)[sv_groupindex_0] = min((*(&kernelContext_1)->lowest_0)[sv_groupindex_0], (*(&kernelContext_1)->lowest_0)[sv_groupindex_0 + w_1]);

#line 20
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

#line 19
        w_1 = w_1 >> 1U;

#line 19
    }



    if(sv_groupindex_0 == 0U)
    {

#line 23
        uint _S5 = atomic_fetch_min_explicit(((atomic_uint device*)((&kernelContext_1)->cover_0+(&kernelContext_1)->vu_0->slot_0 * 4U / 4U)), (as_type<uint>(((*(&kernelContext_1)->lowest_0)[int(0)]))), memory_order_relaxed);

#line 23
    }
    return;
}

