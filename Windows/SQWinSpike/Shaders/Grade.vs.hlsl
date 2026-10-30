#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 18 "Grade.slang"
struct VSOut_0
{
    float4 pos_0 : SV_Position;
};


VSOut_0 vsMain(uint id_0 : SV_VertexID)
{

    VSOut_0 o_0;
    o_0.pos_0 = float4(float2(float((id_0 << int(1)) & 2U), float(id_0 & 2U)) * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    return o_0;
}

