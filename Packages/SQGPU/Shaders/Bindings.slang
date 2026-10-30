// Fixed binding layout shared by every SQGPU kernel (the Windows port plan, seam 4). Each module declares its constant
// buffers first with explicit registers (b0, b1; Metal buffer(0), (1)) and its data buffers at u2...u4 (Metal buffer(2...4)),
// then includes this file. Read textures in0...in23 = t0...t23 (Metal texture(0...23)), a 3D table lut0 = t24 (texture(24)),
// out0 = u0 (Metal texture(25)), samplers s0...s2. Unused parameters are dropped from an entry point but keep their index.
// A module that reads its output in place defines SQ_OUT_READ before the include (out0 becomes read-write everywhere in it).
Texture2D<float4> in0 : register(t0);
Texture2D<float4> in1 : register(t1);
Texture2D<float4> in2 : register(t2);
Texture2D<float4> in3 : register(t3);
Texture2D<float4> in4 : register(t4);
Texture2D<float4> in5 : register(t5);
Texture2D<float4> in6 : register(t6);
Texture2D<float4> in7 : register(t7);
Texture2D<float4> in8 : register(t8);
Texture2D<float4> in9 : register(t9);
Texture2D<float4> in10 : register(t10);
Texture2D<float4> in11 : register(t11);
Texture2D<float4> in12 : register(t12);
Texture2D<float4> in13 : register(t13);
Texture2D<float4> in14 : register(t14);
Texture2D<float4> in15 : register(t15);
Texture2D<float4> in16 : register(t16);
Texture2D<float4> in17 : register(t17);
Texture2D<float4> in18 : register(t18);
Texture2D<float4> in19 : register(t19);
Texture2D<float4> in20 : register(t20);
Texture2D<float4> in21 : register(t21);
Texture2D<float4> in22 : register(t22);
Texture2D<float4> in23 : register(t23);
Texture3D<float4> lut0 : register(t24);
#ifdef SQ_OUT_READ
RWTexture2D<float4> out0 : register(u0);
#else
WTexture2D<float4> out0 : register(u0);
#endif
SamplerState zeroSampler : register(s0);   // linear, normalized, transparent black outside (Metal clamp_to_zero)
SamplerState edgeSampler : register(s1);   // linear, normalized, clamp to edge
SamplerState nearestSampler : register(s2);   // nearest, normalized, clamp to edge

uint2 outSize() { uint w, h; out0.GetDimensions(w, h); return uint2(w, h); }
uint2 inSize() { uint w, h; in0.GetDimensions(w, h); return uint2(w, h); }
float4 read0(int2 p) { return in0.Load(int3(p, 0)); }
float4 read1(int2 p) { return in1.Load(int3(p, 0)); }
