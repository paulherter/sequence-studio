// D3D12 quad renderer for the SQDrawKit draw list. One pipeline, one instanced draw per frame.
// Two frames in flight: each frame slot has its own command allocator, quad buffer region and texture upload buffers;
// the CPU only waits when it comes back to a slot whose previous frame the GPU has not finished (no wait after Present).
// Uploads are recorded in the frame's command list.
#include "csqwinapp.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include <mutex>

using Microsoft::WRL::ComPtr;

// The quad shader is Packages/SQGPU/Shaders/DrawQuads.slang; the Swift side passes its generated HLSL entries
// (SQGPUKernels `GeneratedShaders.drawQuads`: quadVertex, quadFragment) to `sq_ui_create`.

static const UINT kBuffers = 2;
static const UINT kFrames = 2;
static const int kImages = 6;
static const UINT kMaxQuads = 65536;
static const UINT kQuadBytes = 80;
static const DXGI_FORMAT kBackFormat = DXGI_FORMAT_B8G8R8A8_UNORM;

struct Tex {
    ComPtr<ID3D12Resource> res, upload[kFrames];
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp = {};
    uint8_t *map[kFrames] = {};
    int w = 0, h = 0, bpp = 1;
    bool dirty = false;
    UINT dirtySlot = 0;
    DXGI_FORMAT format = DXGI_FORMAT_R8_UNORM;
};

struct SQUi {
    HWND hwnd = nullptr;
    int width = 0, height = 0;
    char adapter[128] = {};
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<IDXGISwapChain3> swap;
    ComPtr<ID3D12Resource> back[kBuffers];
    ComPtr<ID3D12Resource> offscreen;
    ComPtr<ID3D12DescriptorHeap> rtvHeap, srvHeap;
    UINT rtvSize = 0, srvSize = 0;
    ComPtr<ID3D12CommandAllocator> alloc[kFrames];
    UINT64 frameFence[kFrames] = {};
    UINT frame = 0;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    UINT64 fenceValue = 0;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pso;
    ComPtr<ID3D12Resource> quadBuf;
    uint8_t *quadMap = nullptr;
    int quadCount = 0;
    Tex atlas, luma, chroma, images[kImages];
    bool hasVideo = false;
    float fullRange = 0;
    float viewExponent = 1;
    float viewScale = 1;     // target pixels per frame pixel (DrawQuads.slang)
    ComPtr<ID3D12Resource> external;     // the Program picture as another renderer's texture on this device (SRV slot 1)
    ComPtr<ID3D12Resource> readback;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT readFp = {};
};

static void waitIdle(SQUi *g) {
    g->queue->Signal(g->fence.Get(), ++g->fenceValue);
    if (g->fence->GetCompletedValue() < g->fenceValue) {
        g->fence->SetEventOnCompletion(g->fenceValue, g->event);
        WaitForSingleObject(g->event, INFINITE);
    }
}

/// Waits until the GPU finished the frame that last used the current frame slot (its allocator, quad region and
/// upload buffers); returns at once when it already has.
static void waitFrame(SQUi *g) {
    UINT64 v = g->frameFence[g->frame];
    if (v && g->fence->GetCompletedValue() < v) {
        g->fence->SetEventOnCompletion(v, g->event);
        WaitForSingleObject(g->event, INFINITE);
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

static D3D12_RESOURCE_DESC texDesc(int w, int h, DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; d.Width = w; d.Height = h;
    d.DepthOrArraySize = 1; d.MipLevels = 1; d.Format = f; d.SampleDesc.Count = 1; d.Flags = flags;
    return d;
}

/// (Re)creates a texture plus its persistent upload buffer and SRV slot `slot` when the size changed.
static bool ensureTex(SQUi *g, Tex &t, int w, int h, DXGI_FORMAT f, int bpp, int slot) {
    if (t.res && t.w == w && t.h == h && t.format == f) return true;
    waitIdle(g);
    t.res.Reset();
    for (UINT k = 0; k < kFrames; k++) { t.upload[k].Reset(); t.map[k] = nullptr; }
    D3D12_RESOURCE_DESC td = texDesc(w, h, f);
    D3D12_HEAP_PROPERTIES hp = heap(D3D12_HEAP_TYPE_DEFAULT);
    if (FAILED(g->dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                                               nullptr, IID_PPV_ARGS(&t.res)))) return false;
    UINT64 total = 0;
    g->dev->GetCopyableFootprints(&td, 0, 1, 0, &t.fp, nullptr, nullptr, &total);
    D3D12_HEAP_PROPERTIES uh = heap(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC bd = bufferDesc(total);
    for (UINT k = 0; k < kFrames; k++) {
        if (FAILED(g->dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                                                   IID_PPV_ARGS(&t.upload[k])))) return false;
        t.upload[k]->Map(0, nullptr, (void **)&t.map[k]);
    }
    t.w = w; t.h = h; t.bpp = bpp; t.format = f;
    D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
    sv.Format = f; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture2D.MipLevels = 1;
    D3D12_CPU_DESCRIPTOR_HANDLE h0 = g->srvHeap->GetCPUDescriptorHandleForHeapStart();
    h0.ptr += (SIZE_T)slot * g->srvSize;
    g->dev->CreateShaderResourceView(t.res.Get(), &sv, h0);
    return true;
}

/// Writes into the current frame slot's upload buffer (the caller waited for the slot with `waitFrame`).
static void fillTex(SQUi *g, Tex &t, const uint8_t *src, int srcStride) {
    waitFrame(g);
    t.dirtySlot = g->frame;
    for (int y = 0; y < t.h; y++)
        memcpy(t.map[g->frame] + t.fp.Offset + (size_t)y * t.fp.Footprint.RowPitch, src + (size_t)y * srcStride, (size_t)t.w * t.bpp);
    t.dirty = true;
}

static void recordUpload(SQUi *g, Tex &t) {
    if (!t.dirty || !t.res) return;
    D3D12_RESOURCE_BARRIER b = barrier(t.res.Get(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
    g->list->ResourceBarrier(1, &b);
    D3D12_TEXTURE_COPY_LOCATION dst = {}, src = {};
    dst.pResource = t.res.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.pResource = t.upload[t.dirtySlot].Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = t.fp;
    g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    D3D12_RESOURCE_BARRIER b2 = barrier(t.res.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    g->list->ResourceBarrier(1, &b2);
    t.dirty = false;
}

static bool makeTargets(SQUi *g) {
    D3D12_CPU_DESCRIPTOR_HANDLE h = g->rtvHeap->GetCPUDescriptorHandleForHeapStart();
    if (g->swap) {
        for (UINT i = 0; i < kBuffers; i++) {
            if (FAILED(g->swap->GetBuffer(i, IID_PPV_ARGS(&g->back[i])))) return false;
            g->dev->CreateRenderTargetView(g->back[i].Get(), nullptr, h);
            h.ptr += g->rtvSize;
        }
    } else {
        D3D12_RESOURCE_DESC td = texDesc(g->width, g->height, kBackFormat, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        D3D12_HEAP_PROPERTIES hp = heap(D3D12_HEAP_TYPE_DEFAULT);
        if (FAILED(g->dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COMMON, nullptr,
                                                   IID_PPV_ARGS(&g->offscreen)))) return false;
        g->dev->CreateRenderTargetView(g->offscreen.Get(), nullptr, h);
    }
    g->readback.Reset();
    return true;
}

#define CHECK(expr, msg) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { snprintf(err, errLen, "%s (0x%08lx)", msg, (unsigned long)hr_); sq_ui_destroy(g); return nullptr; } } while (0)

static SQUi *create(void *hwnd, int width, int height, ID3D12Device *sharedDev, ID3D12CommandQueue *sharedQueue,
                    const char *sharedName, const char *vsHlsl, const char *psHlsl, char *err, int errLen);

SQUi *sq_ui_create(void *hwnd, int width, int height, const char *vsHlsl, const char *psHlsl, char *err, int errLen) {
    return create(hwnd, width, height, nullptr, nullptr, nullptr, vsHlsl, psHlsl, err, errLen);
}

SQUi *sq_ui_create_shared(void *device, void *queue, const char *adapterName, void *hwnd, int width, int height,
                          const char *vsHlsl, const char *psHlsl, char *err, int errLen) {
    return create(hwnd, width, height, (ID3D12Device *)device, (ID3D12CommandQueue *)queue, adapterName, vsHlsl, psHlsl,
                  err, errLen);
}

static SQUi *create(void *hwnd, int width, int height, ID3D12Device *sharedDev, ID3D12CommandQueue *sharedQueue,
                    const char *sharedName, const char *vsHlsl, const char *psHlsl, char *err, int errLen) {
    SQUi *g = new SQUi();
    g->hwnd = (HWND)hwnd; g->width = width; g->height = height;
    ComPtr<IDXGIFactory6> factory;
    CHECK(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
    ComPtr<IDXGIAdapter1> adapter;
    if (sharedDev) {
        g->dev = sharedDev;
        g->queue = sharedQueue;
        snprintf(g->adapter, sizeof g->adapter, "%s", sharedName ? sharedName : "");
    }
    for (UINT i = 0; !g->dev && factory->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter)) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 d; adapter->GetDesc1(&d);
        if (!(d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
            SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&g->dev)))) {
            WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, g->adapter, sizeof g->adapter, nullptr, nullptr);
            break;
        }
        adapter.Reset();
    }
    if (!g->dev) { snprintf(err, errLen, "no D3D12 adapter"); sq_ui_destroy(g); return nullptr; }

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (!g->queue) CHECK(g->dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&g->queue)), "queue");
    if (g->hwnd) {
        DXGI_SWAP_CHAIN_DESC1 sd = {};
        sd.Width = width; sd.Height = height; sd.Format = kBackFormat;
        sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = kBuffers; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        ComPtr<IDXGISwapChain1> sc1;
        CHECK(factory->CreateSwapChainForHwnd(g->queue.Get(), g->hwnd, &sd, nullptr, nullptr, &sc1), "swap chain");
        factory->MakeWindowAssociation(g->hwnd, DXGI_MWA_NO_ALT_ENTER);
        CHECK(sc1.As(&g->swap), "swap chain 3");
    }
    D3D12_DESCRIPTOR_HEAP_DESC hd = {};
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = kBuffers;
    CHECK(g->dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&g->rtvHeap)), "rtv heap");
    g->rtvSize = g->dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.NumDescriptors = 3 + kImages;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    CHECK(g->dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&g->srvHeap)), "srv heap");
    g->srvSize = g->dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    if (!makeTargets(g)) { snprintf(err, errLen, "render targets"); sq_ui_destroy(g); return nullptr; }

    for (UINT f = 0; f < kFrames; f++)
        CHECK(g->dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g->alloc[f])), "allocator");
    CHECK(g->dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g->alloc[0].Get(), nullptr, IID_PPV_ARGS(&g->list)), "list");
    g->list->Close();
    CHECK(g->dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g->fence)), "fence");
    g->event = CreateEvent(nullptr, FALSE, FALSE, nullptr);

    // Root: constants (b0), SRV table t0-t2 (atlas, luma, chroma) + t4-t9 (images), root SRV t3 (quads); static linear
    // clamp sampler.
    D3D12_DESCRIPTOR_RANGE ranges[2] = {};
    ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; ranges[0].NumDescriptors = 3;
    ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; ranges[1].NumDescriptors = kImages;
    ranges[1].BaseShaderRegister = 4; ranges[1].OffsetInDescriptorsFromTableStart = 3;
    D3D12_ROOT_PARAMETER rp[3] = {};
    rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    rp[0].Constants.Num32BitValues = 8; rp[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    rp[1].DescriptorTable.NumDescriptorRanges = 2; rp[1].DescriptorTable.pDescriptorRanges = ranges;
    rp[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    rp[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
    rp[2].Descriptor.ShaderRegister = 3; rp[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_STATIC_SAMPLER_DESC ss = {};
    ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    ss.MaxLOD = D3D12_FLOAT32_MAX; ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rsd = {};
    rsd.NumParameters = 3; rsd.pParameters = rp; rsd.NumStaticSamplers = 1; rsd.pStaticSamplers = &ss;
    // Floating windows open on the main thread: the root signature, the compiled shaders and the pipeline state of a
    // device are made once and reused (a second window cost ~60 ms of D3DCompile and pipeline creation).
    struct PsoCache { ComPtr<ID3D12Device> dev; std::string vs, ps; ComPtr<ID3D12RootSignature> root; ComPtr<ID3D12PipelineState> pso; };
    static std::vector<PsoCache> psoCache;
    static std::mutex psoLock;
    std::lock_guard<std::mutex> lock(psoLock);
    bool cached = false;
    if (sharedDev && vsHlsl && psHlsl) {
        for (auto &c : psoCache)
            if (c.dev.Get() == g->dev.Get() && c.vs == vsHlsl && c.ps == psHlsl) { g->root = c.root; g->pso = c.pso; cached = true; break; }
    }
    if (!cached) {
        ComPtr<ID3DBlob> sig, serr;
        CHECK(D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &serr), "root signature");
        CHECK(g->dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&g->root)), "root signature create");

        ComPtr<ID3DBlob> vs, ps, cerr;
        if (!vsHlsl || !psHlsl ||
            FAILED(D3DCompile(vsHlsl, strlen(vsHlsl), "ui", nullptr, nullptr, "quadVertex", "vs_5_0", 0, 0, &vs, &cerr)) ||
            FAILED(D3DCompile(psHlsl, strlen(psHlsl), "ui", nullptr, nullptr, "quadFragment", "ps_5_0", 0, 0, &ps, &cerr))) {
            snprintf(err, errLen, "HLSL: %s", cerr ? (const char *)cerr->GetBufferPointer() : "?");
            sq_ui_destroy(g); return nullptr;
        }
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = g->root.Get();
        pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
        pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
        pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pd.RasterizerState.DepthClipEnable = TRUE;
        D3D12_RENDER_TARGET_BLEND_DESC &bl = pd.BlendState.RenderTarget[0];
        bl.BlendEnable = TRUE; bl.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        bl.SrcBlend = D3D12_BLEND_SRC_ALPHA; bl.DestBlend = D3D12_BLEND_INV_SRC_ALPHA; bl.BlendOp = D3D12_BLEND_OP_ADD;
        bl.SrcBlendAlpha = D3D12_BLEND_ZERO; bl.DestBlendAlpha = D3D12_BLEND_ONE; bl.BlendOpAlpha = D3D12_BLEND_OP_ADD;
        pd.SampleMask = UINT_MAX; pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets = 1; pd.RTVFormats[0] = kBackFormat; pd.SampleDesc.Count = 1;
        CHECK(g->dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&g->pso)), "pipeline state");

        if (sharedDev && vsHlsl && psHlsl) psoCache.push_back({g->dev, vsHlsl, psHlsl, g->root, g->pso});
    }

    D3D12_HEAP_PROPERTIES uh = heap(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC bd = bufferDesc((UINT64)kFrames * kMaxQuads * kQuadBytes);
    CHECK(g->dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&g->quadBuf)), "quad buffer");
    g->quadBuf->Map(0, nullptr, (void **)&g->quadMap);
    // Placeholder textures so every descriptor is valid before the first atlas / picture.
    uint8_t zero[8] = {};
    if (!ensureTex(g, g->atlas, 2, 2, DXGI_FORMAT_R8_UNORM, 1, 0) || !ensureTex(g, g->luma, 2, 2, DXGI_FORMAT_R8_UNORM, 1, 1) ||
        !ensureTex(g, g->chroma, 1, 1, DXGI_FORMAT_R8G8_UNORM, 2, 2)) {
        snprintf(err, errLen, "textures"); sq_ui_destroy(g); return nullptr;
    }
    fillTex(g, g->atlas, zero, 2); fillTex(g, g->luma, zero, 2); fillTex(g, g->chroma, zero, 2);
    for (int i = 0; i < kImages; i++) {
        if (!ensureTex(g, g->images[i], 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, 4, 3 + i)) {
            snprintf(err, errLen, "image textures"); sq_ui_destroy(g); return nullptr;
        }
        fillTex(g, g->images[i], zero, 4);
    }
    return g;
}

const char *sq_ui_adapter(const SQUi *g) { return g->adapter; }

int sq_ui_resize(SQUi *g, int width, int height) {
    if (width <= 0 || height <= 0 || (width == g->width && height == g->height)) return 0;
    waitIdle(g);
    for (UINT i = 0; i < kBuffers; i++) g->back[i].Reset();
    g->offscreen.Reset();
    if (g->swap && FAILED(g->swap->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return -1;
    g->width = width; g->height = height;
    return makeTargets(g) ? 0 : -2;
}

int sq_ui_set_atlas(SQUi *g, const uint8_t *r8, int size) {
    if (!ensureTex(g, g->atlas, size, size, DXGI_FORMAT_R8_UNORM, 1, 0)) return -1;
    fillTex(g, g->atlas, r8, size);
    return 0;
}

int sq_ui_set_view_gamma(SQUi *g, float exponent) {
    g->viewExponent = exponent > 0 ? exponent : 1.f;
    return 0;
}

int sq_ui_set_view_scale(SQUi *g, float scale) {
    g->viewScale = scale > 0 ? scale : 1.f;
    return 0;
}

int sq_ui_set_video_nv12(SQUi *g, const uint8_t *bytes, int w, int h, int fullRange) {
    if (!bytes) { g->hasVideo = false; return 0; }
    if (!ensureTex(g, g->luma, w, h, DXGI_FORMAT_R8_UNORM, 1, 1) ||
        !ensureTex(g, g->chroma, w / 2, h / 2, DXGI_FORMAT_R8G8_UNORM, 2, 2)) return -1;
    g->external.Reset();   // after ensureTex: it waited for the GPU and wrote slot 1 again
    fillTex(g, g->luma, bytes, w);
    fillTex(g, g->chroma, bytes + (size_t)w * h, w);
    g->hasVideo = true;
    g->fullRange = fullRange ? 1.f : 0.f;
    return 0;
}

int sq_ui_set_video_rgba(SQUi *g, const uint8_t *rgba, int w, int h) {
    if (!rgba) { g->hasVideo = false; return 0; }
    if (!ensureTex(g, g->luma, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 4, 1)) return -1;
    g->external.Reset();
    fillTex(g, g->luma, rgba, w * 4);
    g->hasVideo = true;
    g->fullRange = 2.f;
    return 0;
}

int sq_ui_set_video_texture(SQUi *g, void *resource) {
    if (!resource) { g->hasVideo = false; return 0; }
    ID3D12Resource *r = (ID3D12Resource *)resource;
    if (g->external.Get() != r) {
        waitIdle(g);   // frames in flight read descriptor slot 1
        g->luma.res.Reset();
        for (UINT k = 0; k < kFrames; k++) { g->luma.upload[k].Reset(); g->luma.map[k] = nullptr; }
        g->luma.w = g->luma.h = 0;
        g->luma.dirty = false;
        g->external = r;
        D3D12_RESOURCE_DESC d = r->GetDesc();
        D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
        sv.Format = d.Format; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture2D.MipLevels = 1;
        D3D12_CPU_DESCRIPTOR_HANDLE h0 = g->srvHeap->GetCPUDescriptorHandleForHeapStart();
        h0.ptr += (SIZE_T)1 * g->srvSize;
        g->dev->CreateShaderResourceView(r, &sv, h0);
    }
    g->hasVideo = true;
    g->fullRange = 2.f;
    return 0;
}

int sq_ui_set_image(SQUi *g, int slot, const uint8_t *rgba, int w, int h) {
    if (slot < 0 || slot >= kImages || !rgba || w <= 0 || h <= 0) return -1;
    if (!ensureTex(g, g->images[slot], w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 4, 3 + slot)) return -1;
    fillTex(g, g->images[slot], rgba, w * 4);
    return 0;
}

int sq_ui_set_quads(SQUi *g, const float *quads, int count) {
    if (count > (int)kMaxQuads) count = kMaxQuads;
    waitFrame(g);
    if (count > 0) memcpy(g->quadMap + (size_t)g->frame * kMaxQuads * kQuadBytes, quads, (size_t)count * kQuadBytes);
    g->quadCount = count;
    return 0;
}

int sq_ui_render(SQUi *g, float r, float gr, float b, uint8_t *rgbaOut, int vsync) {
    UINT i = g->swap ? g->swap->GetCurrentBackBufferIndex() : 0;
    ID3D12Resource *bb = g->swap ? g->back[i].Get() : g->offscreen.Get();
    waitFrame(g);
    g->alloc[g->frame]->Reset();
    g->list->Reset(g->alloc[g->frame].Get(), nullptr);
    recordUpload(g, g->atlas); recordUpload(g, g->luma); recordUpload(g, g->chroma);
    for (int k = 0; k < kImages; k++) recordUpload(g, g->images[k]);
    D3D12_RESOURCE_BARRIER b1 = barrier(bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    g->list->ResourceBarrier(1, &b1);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = g->rtvHeap->GetCPUDescriptorHandleForHeapStart();
    rtv.ptr += (SIZE_T)i * g->rtvSize;
    float col[4] = {r, gr, b, 1};
    g->list->ClearRenderTargetView(rtv, col, 0, nullptr);
    if (g->quadCount > 0) {
        D3D12_VIEWPORT vp = {0, 0, (float)g->width, (float)g->height, 0, 1};
        D3D12_RECT sc = {0, 0, g->width, g->height};
        float cb[8] = {(float)g->width, (float)g->height, g->fullRange, g->hasVideo ? 1.f : 0.f, g->viewExponent, g->viewScale, 0, 0};
        g->list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        g->list->SetGraphicsRootSignature(g->root.Get());
        g->list->SetPipelineState(g->pso.Get());
        ID3D12DescriptorHeap *hs[] = {g->srvHeap.Get()};
        g->list->SetDescriptorHeaps(1, hs);
        g->list->SetGraphicsRoot32BitConstants(0, 8, cb, 0);
        g->list->SetGraphicsRootDescriptorTable(1, g->srvHeap->GetGPUDescriptorHandleForHeapStart());
        g->list->SetGraphicsRootShaderResourceView(2, g->quadBuf->GetGPUVirtualAddress() + (UINT64)g->frame * kMaxQuads * kQuadBytes);
        g->list->RSSetViewports(1, &vp);
        g->list->RSSetScissorRects(1, &sc);
        g->list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        g->list->DrawInstanced(6, g->quadCount, 0, 0);
    }
    if (rgbaOut) {
        if (!g->readback) {
            D3D12_RESOURCE_DESC bd = bb->GetDesc();
            UINT64 total = 0;
            g->dev->GetCopyableFootprints(&bd, 0, 1, 0, &g->readFp, nullptr, nullptr, &total);
            D3D12_HEAP_PROPERTIES rh = heap(D3D12_HEAP_TYPE_READBACK);
            D3D12_RESOURCE_DESC rd = bufferDesc(total);
            g->dev->CreateCommittedResource(&rh, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&g->readback));
        }
        D3D12_RESOURCE_BARRIER t = barrier(bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        g->list->ResourceBarrier(1, &t);
        D3D12_TEXTURE_COPY_LOCATION dst = {}, src = {};
        dst.pResource = g->readback.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = g->readFp;
        src.pResource = bb; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
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
    HRESULT pr = g->swap ? g->swap->Present(vsync ? 1 : 0, 0) : S_OK;
    g->queue->Signal(g->fence.Get(), ++g->fenceValue);
    g->frameFence[g->frame] = g->fenceValue;
    g->frame = (g->frame + 1) % kFrames;
    if (rgbaOut) waitIdle(g);   // the readback needs the finished frame
    if (rgbaOut && g->readback) {
        uint8_t *m = nullptr;
        g->readback->Map(0, nullptr, (void **)&m);
        for (int y = 0; y < g->height; y++)
            for (int x = 0; x < g->width; x++) {
                const uint8_t *p = m + g->readFp.Offset + (size_t)y * g->readFp.Footprint.RowPitch + (size_t)x * 4;
                uint8_t *o = rgbaOut + ((size_t)y * g->width + x) * 4;
                o[0] = p[2]; o[1] = p[1]; o[2] = p[0]; o[3] = 255;
            }
        g->readback->Unmap(0, nullptr);
    }
    return FAILED(pr) ? -1 : 0;
}

void sq_ui_destroy(SQUi *g) {
    if (!g) return;
    if (g->queue && g->fence) waitIdle(g);
    if (g->event) CloseHandle(g->event);
    delete g;
}
