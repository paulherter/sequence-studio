// D3D12 device, flip-model swap chain, one textured fullscreen triangle. Simple on purpose: one frame in flight.
#include "csqwin.h"
#include "png.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include <string>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

using Microsoft::WRL::ComPtr;

static const char *kHLSL = R"(
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
VSOut VS(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = uv;
    return o;
}
Texture2D tex : register(t0);
SamplerState smp : register(s0);
float4 PS(VSOut i) : SV_Target { return tex.Sample(smp, i.uv); }
)";

static const char *kRectHLSL = R"(
cbuffer C : register(b0) { float2 screen; };
ByteAddressBuffer rects : register(t0);
struct VSOut { float4 pos : SV_Position; float4 col : COLOR; };
static const float2 corner[6] = { float2(0,0), float2(1,0), float2(0,1), float2(0,1), float2(1,0), float2(1,1) };
VSOut VS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 r = asfloat(rects.Load4(iid * 32));
    float4 c = asfloat(rects.Load4(iid * 32 + 16));
    float2 px = r.xy + corner[vid] * r.zw;
    VSOut o;
    o.pos = float4(px.x / screen.x * 2 - 1, 1 - px.y / screen.y * 2, 0, 1);
    o.col = c;
    return o;
}
float4 PS(VSOut i) : SV_Target { return i.col; }
)";

static const UINT kBuffers = 2;
static const UINT kMaxRects = 65536;
static const DXGI_FORMAT kBackFormat = DXGI_FORMAT_B8G8R8A8_UNORM;

struct SQGpu {
    HWND hwnd = nullptr;
    int width = 0, height = 0;
    char adapter[128] = {};
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<IDXGISwapChain3> swap;
    ComPtr<ID3D12Resource> back[kBuffers];
    ComPtr<ID3D12DescriptorHeap> rtvHeap, srvHeap;
    UINT rtvSize = 0;
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    UINT64 fenceValue = 0;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pso;
    ComPtr<ID3D12Resource> tex;
    int texW = 0, texH = 0;
    ComPtr<ID3D12PipelineState> gradePso;
    float grade[3] = {};
    ComPtr<ID3D12RootSignature> rectRoot;
    ComPtr<ID3D12PipelineState> rectPso;
    ComPtr<ID3D12Resource> rectBuf;
    uint8_t *rectMap = nullptr;
    int rectCount = 0;
};

static void waitIdle(SQGpu *g) {
    g->queue->Signal(g->fence.Get(), ++g->fenceValue);
    if (g->fence->GetCompletedValue() < g->fenceValue) {
        g->fence->SetEventOnCompletion(g->fenceValue, g->event);
        WaitForSingleObject(g->event, INFINITE);
    }
}

static void makeTargets(SQGpu *g) {
    D3D12_CPU_DESCRIPTOR_HANDLE h = g->rtvHeap->GetCPUDescriptorHandleForHeapStart();
    for (UINT i = 0; i < kBuffers; i++) {
        g->swap->GetBuffer(i, IID_PPV_ARGS(&g->back[i]));
        g->dev->CreateRenderTargetView(g->back[i].Get(), nullptr, h);
        h.ptr += g->rtvSize;
    }
}

static D3D12_RESOURCE_BARRIER barrier(ID3D12Resource *r, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b) {
    D3D12_RESOURCE_BARRIER x = {};
    x.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    x.Transition.pResource = r;
    x.Transition.StateBefore = a;
    x.Transition.StateAfter = b;
    x.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    return x;
}

static D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE t) {
    D3D12_HEAP_PROPERTIES p = {};
    p.Type = t;
    return p;
}

static D3D12_RESOURCE_DESC bufferDesc(UINT64 size) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    d.Width = size; d.Height = 1; d.DepthOrArraySize = 1; d.MipLevels = 1;
    d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return d;
}

#define CHECK(expr, msg) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { snprintf(err, errLen, "%s (0x%08lx)", msg, (unsigned long)hr_); destroyOnFail(g); return nullptr; } } while (0)
static void destroyOnFail(SQGpu *g) { sq_gpu_destroy(g); }

SQGpu *sq_gpu_create(void *hwnd, int width, int height, char *err, int errLen) {
    SQGpu *g = new SQGpu();
    g->hwnd = (HWND)hwnd; g->width = width; g->height = height;
    ComPtr<IDXGIFactory6> factory;
    CHECK(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter)) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 d; adapter->GetDesc1(&d);
        if (!(d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
            SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&g->dev)))) {
            WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, g->adapter, sizeof g->adapter, nullptr, nullptr);
            break;
        }
        adapter.Reset();
    }
    if (!g->dev) { snprintf(err, errLen, "no D3D12 adapter"); sq_gpu_destroy(g); return nullptr; }

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    CHECK(g->dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&g->queue)), "queue");

    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = width; sd.Height = height; sd.Format = kBackFormat;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = kBuffers; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> sc1;
    CHECK(factory->CreateSwapChainForHwnd(g->queue.Get(), g->hwnd, &sd, nullptr, nullptr, &sc1), "swap chain");
    factory->MakeWindowAssociation(g->hwnd, DXGI_MWA_NO_ALT_ENTER);
    CHECK(sc1.As(&g->swap), "swap chain 3");

    D3D12_DESCRIPTOR_HEAP_DESC hd = {};
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = kBuffers;
    CHECK(g->dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&g->rtvHeap)), "rtv heap");
    g->rtvSize = g->dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.NumDescriptors = 1;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    CHECK(g->dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&g->srvHeap)), "srv heap");
    makeTargets(g);

    CHECK(g->dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g->alloc)), "allocator");
    CHECK(g->dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g->alloc.Get(), nullptr, IID_PPV_ARGS(&g->list)), "list");
    g->list->Close();
    CHECK(g->dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g->fence)), "fence");
    g->event = CreateEvent(nullptr, FALSE, FALSE, nullptr);

    // Root signature: one SRV table + static linear sampler.
    D3D12_DESCRIPTOR_RANGE range = {};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; range.NumDescriptors = 1;
    range.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
    D3D12_ROOT_PARAMETER rp[2] = {};
    rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    rp[0].DescriptorTable.NumDescriptorRanges = 1; rp[0].DescriptorTable.pDescriptorRanges = &range;
    rp[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;  // Slang "Params" (b0), 12 floats
    rp[1].Constants.ShaderRegister = 0; rp[1].Constants.Num32BitValues = 12;
    rp[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC ss = {};
    ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    ss.MaxLOD = D3D12_FLOAT32_MAX; ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rsd = {};
    rsd.NumParameters = 2; rsd.pParameters = rp; rsd.NumStaticSamplers = 1; rsd.pStaticSamplers = &ss;
    ComPtr<ID3DBlob> sig, serr;
    CHECK(D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &serr), "root signature");
    CHECK(g->dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&g->root)), "root signature create");

    ComPtr<ID3DBlob> vs, ps, cerr;
    if (FAILED(D3DCompile(kHLSL, strlen(kHLSL), "quad", nullptr, nullptr, "VS", "vs_5_0", 0, 0, &vs, &cerr)) ||
        FAILED(D3DCompile(kHLSL, strlen(kHLSL), "quad", nullptr, nullptr, "PS", "ps_5_0", 0, 0, &ps, &cerr))) {
        snprintf(err, errLen, "HLSL: %s", cerr ? (const char *)cerr->GetBufferPointer() : "?");
        sq_gpu_destroy(g); return nullptr;
    }
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
    pd.pRootSignature = g->root.Get();
    pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
    pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = UINT_MAX; pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1; pd.RTVFormats[0] = kBackFormat; pd.SampleDesc.Count = 1;
    CHECK(g->dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&g->pso)), "pipeline state");
    // Rect pipeline (shared draw list): root constants (screen size) + root SRV with the rect array.
    {
        D3D12_ROOT_PARAMETER q[2] = {};
        q[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        q[0].Constants.Num32BitValues = 2; q[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        q[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
        q[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        D3D12_ROOT_SIGNATURE_DESC rd2 = {};
        rd2.NumParameters = 2; rd2.pParameters = q;
        ComPtr<ID3DBlob> sig2, e2;
        CHECK(D3D12SerializeRootSignature(&rd2, D3D_ROOT_SIGNATURE_VERSION_1, &sig2, &e2), "rect root signature");
        CHECK(g->dev->CreateRootSignature(0, sig2->GetBufferPointer(), sig2->GetBufferSize(), IID_PPV_ARGS(&g->rectRoot)), "rect root create");
        ComPtr<ID3DBlob> rvs, rps, re;
        if (FAILED(D3DCompile(kRectHLSL, strlen(kRectHLSL), "rect", nullptr, nullptr, "VS", "vs_5_0", 0, 0, &rvs, &re)) ||
            FAILED(D3DCompile(kRectHLSL, strlen(kRectHLSL), "rect", nullptr, nullptr, "PS", "ps_5_0", 0, 0, &rps, &re))) {
            snprintf(err, errLen, "rect HLSL: %s", re ? (const char *)re->GetBufferPointer() : "?");
            sq_gpu_destroy(g); return nullptr;
        }
        D3D12_GRAPHICS_PIPELINE_STATE_DESC rpd = pd;
        rpd.pRootSignature = g->rectRoot.Get();
        rpd.VS = {rvs->GetBufferPointer(), rvs->GetBufferSize()};
        rpd.PS = {rps->GetBufferPointer(), rps->GetBufferSize()};
        D3D12_RENDER_TARGET_BLEND_DESC &bl = rpd.BlendState.RenderTarget[0];
        bl.BlendEnable = TRUE;
        bl.SrcBlend = D3D12_BLEND_SRC_ALPHA; bl.DestBlend = D3D12_BLEND_INV_SRC_ALPHA; bl.BlendOp = D3D12_BLEND_OP_ADD;
        bl.SrcBlendAlpha = D3D12_BLEND_ONE; bl.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA; bl.BlendOpAlpha = D3D12_BLEND_OP_ADD;
        CHECK(g->dev->CreateGraphicsPipelineState(&rpd, IID_PPV_ARGS(&g->rectPso)), "rect pipeline state");
        D3D12_HEAP_PROPERTIES uh = heap(D3D12_HEAP_TYPE_UPLOAD);
        D3D12_RESOURCE_DESC bd = bufferDesc((UINT64)kMaxRects * 32);
        CHECK(g->dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&g->rectBuf)), "rect buffer");
        g->rectBuf->Map(0, nullptr, (void **)&g->rectMap);
    }
    return g;
}

static bool readFile(const char *path, std::string &out) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    fclose(f);
    return true;
}

int sq_gpu_set_grade(SQGpu *g, const char *vsPath, const char *psPath, float exposure, float saturation, float vignette, char *err, int errLen) {
    std::string vsSrc, psSrc;
    if (!readFile(vsPath, vsSrc) || !readFile(psPath, psSrc)) { snprintf(err, errLen, "cannot read shader files"); return -1; }
    ComPtr<ID3DBlob> vs, ps, e;
    if (FAILED(D3DCompile(vsSrc.data(), vsSrc.size(), "grade.vs", nullptr, nullptr, "vsMain", "vs_5_0", 0, 0, &vs, &e)) ||
        FAILED(D3DCompile(psSrc.data(), psSrc.size(), "grade.ps", nullptr, nullptr, "psMain", "ps_5_0", 0, 0, &ps, &e))) {
        snprintf(err, errLen, "Slang HLSL: %s", e ? (const char *)e->GetBufferPointer() : "?");
        return -2;
    }
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
    pd.pRootSignature = g->root.Get();
    pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
    pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = UINT_MAX; pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1; pd.RTVFormats[0] = kBackFormat; pd.SampleDesc.Count = 1;
    g->gradePso.Reset();
    HRESULT hr = g->dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&g->gradePso));
    if (FAILED(hr)) { snprintf(err, errLen, "grade pipeline (0x%08lx)", (unsigned long)hr); return -3; }
    g->grade[0] = exposure; g->grade[1] = saturation; g->grade[2] = vignette;
    return 0;
}

int sq_gpu_set_rects(SQGpu *g, const SQRect *rects, int count) {
    if (count > (int)kMaxRects) count = kMaxRects;
    if (count > 0) memcpy(g->rectMap, rects, (size_t)count * sizeof(SQRect));
    g->rectCount = count;
    return 0;
}

const char *sq_gpu_adapter_name(const SQGpu *g) { return g->adapter; }

int sq_gpu_resize(SQGpu *g, int width, int height) {
    if (width <= 0 || height <= 0) return 0;
    waitIdle(g);
    for (UINT i = 0; i < kBuffers; i++) g->back[i].Reset();
    if (FAILED(g->swap->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return -1;
    g->width = width; g->height = height;
    makeTargets(g);
    return 0;
}

int sq_gpu_set_frame_rgba(SQGpu *g, const uint8_t *rgba, int w, int h) {
    waitIdle(g);
    g->tex.Reset();
    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; td.Width = w; td.Height = h;
    td.DepthOrArraySize = 1; td.MipLevels = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES hp = heap(D3D12_HEAP_TYPE_DEFAULT);
    if (FAILED(g->dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&g->tex)))) return -1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT rows; UINT64 rowBytes, total;
    g->dev->GetCopyableFootprints(&td, 0, 1, 0, &fp, &rows, &rowBytes, &total);
    ComPtr<ID3D12Resource> up;
    D3D12_HEAP_PROPERTIES uh = heap(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC bd = bufferDesc(total);
    if (FAILED(g->dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&up)))) return -2;
    uint8_t *m = nullptr;
    up->Map(0, nullptr, (void **)&m);
    for (int y = 0; y < h; y++) memcpy(m + fp.Offset + (size_t)y * fp.Footprint.RowPitch, rgba + (size_t)y * w * 4, (size_t)w * 4);
    up->Unmap(0, nullptr);
    g->alloc->Reset();
    g->list->Reset(g->alloc.Get(), nullptr);
    D3D12_TEXTURE_COPY_LOCATION dst = {}, src = {};
    dst.pResource = g->tex.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; dst.SubresourceIndex = 0;
    src.pResource = up.Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = fp;
    g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    D3D12_RESOURCE_BARRIER b = barrier(g->tex.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    g->list->ResourceBarrier(1, &b);
    g->list->Close();
    ID3D12CommandList *ls[] = {g->list.Get()};
    g->queue->ExecuteCommandLists(1, ls);
    waitIdle(g);
    D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
    sv.Format = td.Format; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture2D.MipLevels = 1;
    g->dev->CreateShaderResourceView(g->tex.Get(), &sv, g->srvHeap->GetCPUDescriptorHandleForHeapStart());
    g->texW = w; g->texH = h;
    return 0;
}

int sq_gpu_render(SQGpu *g, float r, float gr, float b, const char *pngPath) {
    UINT i = g->swap->GetCurrentBackBufferIndex();
    ID3D12Resource *bb = g->back[i].Get();
    g->alloc->Reset();
    g->list->Reset(g->alloc.Get(), nullptr);
    D3D12_RESOURCE_BARRIER b1 = barrier(bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    g->list->ResourceBarrier(1, &b1);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = g->rtvHeap->GetCPUDescriptorHandleForHeapStart();
    rtv.ptr += (SIZE_T)i * g->rtvSize;
    float col[4] = {r, gr, b, 1};
    g->list->ClearRenderTargetView(rtv, col, 0, nullptr);
    if (g->tex) {
        // Letterbox: keep the video aspect.
        float sx = (float)g->width / g->texW, sy = (float)g->height / g->texH, s = sx < sy ? sx : sy;
        float vw = g->texW * s, vh = g->texH * s;
        D3D12_VIEWPORT vp = {(g->width - vw) / 2, (g->height - vh) / 2, vw, vh, 0, 1};
        D3D12_RECT sc = {(LONG)vp.TopLeftX, (LONG)vp.TopLeftY, (LONG)(vp.TopLeftX + vw), (LONG)(vp.TopLeftY + vh)};
        g->list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        g->list->SetGraphicsRootSignature(g->root.Get());
        g->list->SetPipelineState(g->gradePso ? g->gradePso.Get() : g->pso.Get());
        if (g->gradePso) {
            float cb[12] = {g->grade[0], g->grade[1], g->grade[2], 0, vw, vh, vp.TopLeftX, vp.TopLeftY, g->texW / vw, g->texH / vh, 0, 0};
            g->list->SetGraphicsRoot32BitConstants(1, 12, cb, 0);
        }
        ID3D12DescriptorHeap *hs[] = {g->srvHeap.Get()};
        g->list->SetDescriptorHeaps(1, hs);
        g->list->SetGraphicsRootDescriptorTable(0, g->srvHeap->GetGPUDescriptorHandleForHeapStart());
        g->list->RSSetViewports(1, &vp);
        g->list->RSSetScissorRects(1, &sc);
        g->list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        g->list->DrawInstanced(3, 1, 0, 0);
    }
    if (g->rectCount > 0) {
        D3D12_VIEWPORT vp = {0, 0, (float)g->width, (float)g->height, 0, 1};
        D3D12_RECT sc = {0, 0, g->width, g->height};
        float screen[2] = {(float)g->width, (float)g->height};
        g->list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        g->list->SetGraphicsRootSignature(g->rectRoot.Get());
        g->list->SetPipelineState(g->rectPso.Get());
        g->list->SetGraphicsRoot32BitConstants(0, 2, screen, 0);
        g->list->SetGraphicsRootShaderResourceView(1, g->rectBuf->GetGPUVirtualAddress());
        g->list->RSSetViewports(1, &vp);
        g->list->RSSetScissorRects(1, &sc);
        g->list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        g->list->DrawInstanced(6, g->rectCount, 0, 0);
    }
    ComPtr<ID3D12Resource> rb;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp = {};
    UINT64 total = 0;
    if (pngPath) {
        D3D12_RESOURCE_DESC bd = g->back[i]->GetDesc();
        g->dev->GetCopyableFootprints(&bd, 0, 1, 0, &fp, nullptr, nullptr, &total);
        D3D12_HEAP_PROPERTIES rh = heap(D3D12_HEAP_TYPE_READBACK);
        D3D12_RESOURCE_DESC rd = bufferDesc(total);
        g->dev->CreateCommittedResource(&rh, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&rb));
        D3D12_RESOURCE_BARRIER t = barrier(bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        g->list->ResourceBarrier(1, &t);
        D3D12_TEXTURE_COPY_LOCATION dst = {}, src = {};
        dst.pResource = rb.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = fp;
        src.pResource = bb; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0;
        g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        D3D12_RESOURCE_BARRIER t2 = barrier(bb, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
        g->list->ResourceBarrier(1, &t2);
    } else {
        D3D12_RESOURCE_BARRIER t = barrier(bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        g->list->ResourceBarrier(1, &t);
    }
    g->list->Close();
    ID3D12CommandList *ls[] = {g->list.Get()};
    g->queue->ExecuteCommandLists(1, ls);
    HRESULT pr = g->swap->Present(1, 0);
    waitIdle(g);
    if (pngPath && rb) {
        uint8_t *m = nullptr;
        rb->Map(0, nullptr, (void **)&m);
        int w = g->width, h = g->height;
        uint8_t *rgb = (uint8_t *)malloc((size_t)w * h * 3);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                const uint8_t *p = m + (size_t)y * fp.Footprint.RowPitch + (size_t)x * 4;
                uint8_t *o = rgb + ((size_t)y * w + x) * 3;
                o[0] = p[2]; o[1] = p[1]; o[2] = p[0];
            }
        rb->Unmap(0, nullptr);
        sqWritePNG(pngPath, rgb, w, h);
        free(rgb);
    }
    return FAILED(pr) ? -1 : 0;
}

void sq_gpu_destroy(SQGpu *g) {
    if (!g) return;
    if (g->queue && g->fence) waitIdle(g);
    if (g->event) CloseHandle(g->event);
    delete g;
}
