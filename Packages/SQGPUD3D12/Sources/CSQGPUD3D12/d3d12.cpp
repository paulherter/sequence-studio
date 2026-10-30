// D3D12 compute and draw backend for SQGPU (Windows only; empty translation unit elsewhere).
// Frames in flight: `kSlots` command slots, each with its own allocator, descriptor range, constant range, staging
// buffers and retained textures. `sqd3d_commit` submits without waiting; the next `sqd3d_begin` on a slot waits only
// for that slot's previous list. `sqd3d_commit_wait`, download and the readback ticket wait for their own list (the
// queue runs lists in order, so everything before it is done too).
#ifdef _WIN32
#include "csqgpud3d12.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include <string>
#include <mutex>
#include <unordered_map>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

using Microsoft::WRL::ComPtr;

static const int kInputs = 25;                // t0...t23 2D, t24 the 3D table slot
static const int kUAVs = 5;                   // u0 output, u1 unused, u2...u4 data buffers
static const UINT kTable = kInputs + kUAVs;   // descriptors per dispatch
static const int kSlots = 3;                  // command lists in flight
static const UINT kDescriptors = 65536;       // per slot: kTable per dispatch, reset when the slot is reused
static const UINT64 kRingBytes = 8u << 20;    // per slot: constant blocks, 256-byte aligned, reset when the slot is reused
static const UINT kGroup = 16;
static const UINT kRTVs = 4096;             // render target views, one per render pass, reset at every commit

struct SQD3DTex {
    ComPtr<ID3D12Resource> res;
    int width = 0, height = 0, format = 0;
    int depth = 1;
    int kind = 0;                             // 0 2D texture, 1 3D table, 2 data buffer (length bytes, 4-byte elements)
    UINT64 length = 0;
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
    long refs = 1;
};

struct SQD3D {
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    UINT64 fenceValue = 0;
    ComPtr<ID3D12RootSignature> root;
    std::vector<ComPtr<ID3D12PipelineState>> pipelines;
    std::vector<char> drawPipeline;           // per pipeline: 1 = vertex + pixel shader
    ComPtr<ID3D12DescriptorHeap> heap;
    ComPtr<ID3D12DescriptorHeap> nulls;       // CPU-only: one null descriptor per table slot, copied before each dispatch
    UINT descSize = 0;
    ComPtr<ID3D12DescriptorHeap> rtvs;        // CPU-only render target views
    UINT rtvSize = 0;
    ComPtr<ID3D12Resource> ring;
    uint8_t *ringMap = nullptr;
    bool open = false;
    struct Staged { ComPtr<ID3D12Resource> buf; UINT64 size; bool upload; };
    /// One list in flight: what it holds until the GPU passed `fence`.
    struct Slot {
        ComPtr<ID3D12CommandAllocator> alloc;
        UINT64 fence = 0;
        std::vector<Staged> staging;          // uploads recorded into its list, back to the pool once it finished
        std::vector<SQD3DTex *> retained;     // textures its list reads or writes
    };
    Slot slots[kSlots];
    int slot = 0;                             // the open (or last) slot
    struct SQD3DList *current = nullptr;      // the open command buffer (uploads into it retain their texture)
    std::vector<Staged> pendingStaging;       // uploads recorded into the open list, moved to its slot at submit
    UINT64 inFlightMax = 0;                   // statistics: most lists submitted and not finished at once
    std::vector<Staged> stagingPool;          // idle staging buffers (the GPU is done with them), oldest first
    UINT64 stagingPoolBytes = 0;
    char name[128] = {};
};

struct SQD3DList {
    SQD3D *g = nullptr;
    UINT desc = 0, descEnd = 0;
    UINT64 ring = 0, ringEnd = 0;
    int pipeline = -1;
    SQD3DTex *in[kInputs] = {};
    SQD3DTex *out = nullptr;
    SQD3DTex *buf[3] = {};                    // u2...u4
    D3D12_GPU_VIRTUAL_ADDRESS cb[2] = {};
    SQD3DTex *target = nullptr;               // render target of the open render pass
    UINT rtv = 0;
    std::vector<SQD3DTex *> retained;
    bool failed = false;
};

static DXGI_FORMAT dxgi(int f) {
    switch (f) {
    case 1: return DXGI_FORMAT_R32G32B32A32_FLOAT;
    case 2: return DXGI_FORMAT_R8G8B8A8_UNORM;
    case 3: return DXGI_FORMAT_R32_FLOAT;
    case 4: return DXGI_FORMAT_R32G32_FLOAT;
    case 5: return DXGI_FORMAT_R8_UNORM;
    case 6: return DXGI_FORMAT_R8G8_UNORM;
    case 7: return DXGI_FORMAT_R16_UNORM;
    case 8: return DXGI_FORMAT_R16G16_UNORM;
    default: return DXGI_FORMAT_R16G16B16A16_FLOAT;
    }
}

static int bytesPerPixel(int f) {
    switch (f) { case 1: return 16; case 5: return 1; case 6: case 7: return 2; case 2: case 3: case 8: return 4; default: return 8; }
}

static D3D12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE t) {
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

static void retain(SQD3DList *l, SQD3DTex *t) {
    t->refs++;
    l->retained.push_back(t);
}

/// Moves `t` into state `s`, appending the transition (no-op when it is already there).
static void want(std::vector<D3D12_RESOURCE_BARRIER> &b, SQD3DTex *t, D3D12_RESOURCE_STATES s) {
    if (t->state == s) return;
    D3D12_RESOURCE_BARRIER x = {};
    x.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    x.Transition.pResource = t->res.Get();
    x.Transition.StateBefore = t->state;
    x.Transition.StateAfter = s;
    x.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.push_back(x);
    t->state = s;
}

static void waitIdle(SQD3D *g) {
    g->queue->Signal(g->fence.Get(), ++g->fenceValue);
    if (g->fence->GetCompletedValue() < g->fenceValue) {
        g->fence->SetEventOnCompletion(g->fenceValue, g->event);
        WaitForSingleObject(g->event, INFINITE);
    }
}

static void poolStaging(SQD3D *g, SQD3D::Staged s);

static void waitFence(SQD3D *g, UINT64 v) {
    if (v && g->fence->GetCompletedValue() < v) {
        g->fence->SetEventOnCompletion(v, g->event);
        WaitForSingleObject(g->event, INFINITE);
    }
}

/// Gives back what a finished slot held: its staging buffers to the pool, its textures to their owners.
static void retire(SQD3D *g, SQD3D::Slot &s) {
    for (auto &st : s.staging) poolStaging(g, std::move(st));
    s.staging.clear();
    for (SQD3DTex *t : s.retained) sqd3d_texture_release(t);
    s.retained.clear();
}

/// Retires every slot whose list the GPU finished (cheap: one fence read).
static void retireFinished(SQD3D *g) {
    UINT64 done = g->fence->GetCompletedValue();
    for (auto &s : g->slots) if (s.fence && s.fence <= done) { retire(g, s); s.fence = 0; }
}

/// Opens the next slot's list: waits only when the GPU still runs that slot's previous list.
static bool reset(SQD3D *g) {
    if (g->open) return false;
    retireFinished(g);
    g->slot = (g->slot + 1) % kSlots;
    SQD3D::Slot &s = g->slots[g->slot];
    waitFence(g, s.fence);
    retire(g, s);
    s.fence = 0;
    if (FAILED(s.alloc->Reset()) || FAILED(g->list->Reset(s.alloc.Get(), nullptr))) return false;
    g->open = true;
    return true;
}

/// Staging buffers are reused: a playback frame uploads two planes and reads one picture back, and a committed buffer
/// per transfer cost more than the copies (measured in `frameTransfersRoundTripAndAreTimed`).
static const UINT64 kStagingPoolBytes = 512ull << 20;

static void poolStaging(SQD3D *g, SQD3D::Staged s) {
    g->stagingPool.push_back(std::move(s));
    g->stagingPoolBytes += g->stagingPool.back().size;
    while (g->stagingPoolBytes > kStagingPoolBytes && !g->stagingPool.empty()) {
        g->stagingPoolBytes -= g->stagingPool.front().size;
        g->stagingPool.erase(g->stagingPool.begin());
    }
}

/// Closes and runs the open list; with `wait` blocks until the GPU finished it (and so everything before it).
static bool submit(SQD3D *g, bool wait = true) {
    SQD3D::Slot &s = g->slots[g->slot];
    bool ok = SUCCEEDED(g->list->Close());
    for (auto &st : g->pendingStaging) s.staging.push_back(std::move(st));
    g->pendingStaging.clear();
    if (ok) {
        ID3D12CommandList *lists[] = {g->list.Get()};
        g->queue->ExecuteCommandLists(1, lists);
        g->queue->Signal(g->fence.Get(), ++g->fenceValue);
        s.fence = g->fenceValue;
        UINT64 done = g->fence->GetCompletedValue(), n = 0;
        for (auto &x : g->slots) if (x.fence > done) n++;
        if (n > g->inFlightMax) g->inFlightMax = n;
    }
    g->open = false;
    g->current = nullptr;
    if (!ok || wait) {
        // A list that never ran holds nothing the GPU uses.
        if (ok) waitFence(g, s.fence);
        retire(g, s);
        s.fence = 0;
    }
    return ok;
}

#define FAIL(msg, hr) do { snprintf(err, errLen, "%s (0x%08lx)", msg, (unsigned long)(hr)); sqd3d_destroy(g); return nullptr; } while (0)
#define CHECK(expr, msg) do { HRESULT hr_ = (expr); if (FAILED(hr_)) FAIL(msg, hr_); } while (0)

SQD3D *sqd3d_create(char *err, int errLen) {
    SQD3D *g = new SQD3D();
    char debug[8] = {};
    if (GetEnvironmentVariableA("SQ_D3D12_DEBUG", debug, sizeof debug) && debug[0] == '1') {
        ComPtr<ID3D12Debug> d;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&d)))) d->EnableDebugLayer();
    }
    ComPtr<IDXGIFactory6> factory;
    CHECK(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter)) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 d;
        adapter->GetDesc1(&d);
        if (!(d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
            SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&g->dev)))) {
            WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, g->name, sizeof g->name, nullptr, nullptr);
            break;
        }
    }
    if (!g->dev) FAIL("no D3D12 hardware adapter", 0);

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    CHECK(g->dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&g->queue)), "queue");
    for (auto &s : g->slots)
        CHECK(g->dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&s.alloc)), "allocator");
    CHECK(g->dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g->slots[0].alloc.Get(), nullptr, IID_PPV_ARGS(&g->list)), "list");
    g->list->Close();
    CHECK(g->dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&g->fence)), "fence");
    g->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    // Root signature (compute and draws): b0, b1 as root CBVs; one table t0...t24 + u0...u4; static samplers s0 (linear,
    // zero border), s1 (linear, clamp), s2 (nearest, clamp).
    D3D12_DESCRIPTOR_RANGE ranges[2] = {};
    ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[0].NumDescriptors = kInputs;
    ranges[0].OffsetInDescriptorsFromTableStart = 0;
    ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
    ranges[1].NumDescriptors = kUAVs;
    ranges[1].OffsetInDescriptorsFromTableStart = kInputs;
    D3D12_ROOT_PARAMETER params[3] = {};
    for (int i = 0; i < 2; i++) {
        params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        params[i].Descriptor.ShaderRegister = i;
        params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[2].DescriptorTable.NumDescriptorRanges = 2;
    params[2].DescriptorTable.pDescriptorRanges = ranges;
    params[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_STATIC_SAMPLER_DESC samplers[3] = {};
    for (int i = 0; i < 3; i++) {
        D3D12_TEXTURE_ADDRESS_MODE m = i == 0 ? D3D12_TEXTURE_ADDRESS_MODE_BORDER : D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[i].Filter = i == 2 ? D3D12_FILTER_MIN_MAG_MIP_POINT : D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        samplers[i].AddressU = m; samplers[i].AddressV = m; samplers[i].AddressW = m;
        samplers[i].BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK;
        samplers[i].MaxLOD = D3D12_FLOAT32_MAX;
        samplers[i].ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER;
        samplers[i].ShaderRegister = i;
        samplers[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    rd.NumParameters = 3; rd.pParameters = params;
    rd.NumStaticSamplers = 3; rd.pStaticSamplers = samplers;
    ComPtr<ID3DBlob> blob, rerr;
    CHECK(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &rerr), "root signature");
    CHECK(g->dev->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&g->root)), "root signature");

    D3D12_DESCRIPTOR_HEAP_DESC hd = {};
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = kDescriptors * kSlots;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    CHECK(g->dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&g->heap)), "descriptor heap");
    g->descSize = g->dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_DESCRIPTOR_HEAP_DESC nd = {};
    nd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    nd.NumDescriptors = kTable;
    CHECK(g->dev->CreateDescriptorHeap(&nd, IID_PPV_ARGS(&g->nulls)), "null descriptors");
    {
        D3D12_CPU_DESCRIPTOR_HANDLE h = g->nulls->GetCPUDescriptorHandleForHeapStart();
        for (int i = 0; i < kInputs; i++) {
            D3D12_SHADER_RESOURCE_VIEW_DESC sd = {};
            sd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
            sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            if (i == kInputs - 1) { sd.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; sd.Texture3D.MipLevels = 1; }
            else { sd.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; sd.Texture2D.MipLevels = 1; }
            g->dev->CreateShaderResourceView(nullptr, &sd, {h.ptr + (SIZE_T)i * g->descSize});
        }
        for (int i = 0; i < kUAVs; i++) {
            D3D12_UNORDERED_ACCESS_VIEW_DESC ud = {};
            if (i < 2) { ud.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; ud.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D; }
            else { ud.Format = DXGI_FORMAT_UNKNOWN; ud.ViewDimension = D3D12_UAV_DIMENSION_BUFFER; ud.Buffer.StructureByteStride = 4; }
            g->dev->CreateUnorderedAccessView(nullptr, nullptr, &ud, {h.ptr + (SIZE_T)(kInputs + i) * g->descSize});
        }
    }

    D3D12_DESCRIPTOR_HEAP_DESC rh = {};
    rh.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rh.NumDescriptors = kRTVs;
    CHECK(g->dev->CreateDescriptorHeap(&rh, IID_PPV_ARGS(&g->rtvs)), "render target views");
    g->rtvSize = g->dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

    D3D12_HEAP_PROPERTIES up = heapProps(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC rb = bufferDesc(256 + kRingBytes * kSlots);
    CHECK(g->dev->CreateCommittedResource(&up, D3D12_HEAP_FLAG_NONE, &rb, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                                          IID_PPV_ARGS(&g->ring)), "constant ring");
    D3D12_RANGE none = {0, 0};
    CHECK(g->ring->Map(0, &none, (void **)&g->ringMap), "constant ring map");
    memset(g->ringMap, 0, 256);  // offset 0 stays zero: the address of a constant slot nobody set
    return g;
}

void sqd3d_destroy(SQD3D *g) {
    if (!g) return;
    if (g->queue && g->fence) waitIdle(g);
    if (g->fence) for (auto &s : g->slots) retire(g, s);
    if (g->event) CloseHandle(g->event);
    delete g;
}

const char *sqd3d_name(const SQD3D *g) { return g->name; }

// Shader cache: fxc at /O3 takes seconds per pipeline (a cold graph run took 5-7 minutes), so compiled bytecode is kept
// in memory for the process and on disk across runs, keyed by a hash of source, entry, profile, flags and compiler.
// Folder: %SQ_D3D12_SHADER_CACHE% or %LOCALAPPDATA%\SequenceStudio\ShaderCache; "off" disables the disk part.
static const UINT kCompileFlags = D3DCOMPILE_IEEE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
static std::mutex gShaderLock;
static std::unordered_map<unsigned long long, std::vector<char>> gShaders;

static unsigned long long fnv(unsigned long long h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}

static std::string shaderCacheDir() {
    char buf[1024];
    DWORD n = GetEnvironmentVariableA("SQ_D3D12_SHADER_CACHE", buf, sizeof buf);
    if (n > 0 && n < sizeof buf) return strcmp(buf, "off") == 0 ? std::string() : std::string(buf);
    n = GetEnvironmentVariableA("LOCALAPPDATA", buf, sizeof buf);
    if (n == 0 || n >= sizeof buf) return std::string();
    std::string dir = std::string(buf) + "\\SequenceStudio";
    CreateDirectoryA(dir.c_str(), nullptr);
    dir += "\\ShaderCache";
    CreateDirectoryA(dir.c_str(), nullptr);
    return dir;
}

static bool makeBlob(const std::vector<char> &bytes, ComPtr<ID3DBlob> &out) {
    if (FAILED(D3DCreateBlob(bytes.size(), &out))) return false;
    memcpy(out->GetBufferPointer(), bytes.data(), bytes.size());
    return true;
}

static bool compile(const char *hlsl, const char *entry, const char *profile, ComPtr<ID3DBlob> &out, char *err, int errLen) {
    // Key version 1: bump when the flags or the compiler change in a way the inputs do not show.
    unsigned long long h = 14695981039346656037ull;
    const UINT version = 1, flags = kCompileFlags;
    h = fnv(h, &version, sizeof version); h = fnv(h, &flags, sizeof flags);
    h = fnv(h, profile, strlen(profile) + 1); h = fnv(h, entry, strlen(entry) + 1); h = fnv(h, hlsl, strlen(hlsl));
    std::string path;
    {
        std::lock_guard<std::mutex> lock(gShaderLock);
        auto hit = gShaders.find(h);
        if (hit != gShaders.end()) return makeBlob(hit->second, out);
    }
    std::string dir = shaderCacheDir();
    if (!dir.empty()) {
        char name[40];
        snprintf(name, sizeof name, "\\%016llx.dxbc", h);
        path = dir + name;
        if (FILE *f = fopen(path.c_str(), "rb")) {
            std::vector<char> bytes;
            char chunk[65536];
            size_t got;
            while ((got = fread(chunk, 1, sizeof chunk, f)) > 0) bytes.insert(bytes.end(), chunk, chunk + got);
            fclose(f);
            // A DXBC container starts with "DXBC"; anything else (a torn write) is compiled again.
            if (bytes.size() > 4 && memcmp(bytes.data(), "DXBC", 4) == 0 && makeBlob(bytes, out)) {
                std::lock_guard<std::mutex> lock(gShaderLock);
                gShaders[h] = std::move(bytes);
                return true;
            }
        }
    }
    ComPtr<ID3DBlob> cerr;
    // IEEE strictness: no fast-math reassociation, like the .safe math mode of the Metal side.
    if (FAILED(D3DCompile(hlsl, strlen(hlsl), entry, nullptr, nullptr, entry, profile, flags, 0, &out, &cerr))) {
        snprintf(err, errLen, "%s: %s", entry, cerr ? (const char *)cerr->GetBufferPointer() : "compile failed");
        return false;
    }
    std::vector<char> bytes((const char *)out->GetBufferPointer(), (const char *)out->GetBufferPointer() + out->GetBufferSize());
    if (!path.empty()) {
        // Written under a temporary name and moved into place, so a reader never sees half a file.
        std::string tmp = path + "." + std::to_string(GetCurrentProcessId()) + ".tmp";
        if (FILE *f = fopen(tmp.c_str(), "wb")) {
            bool ok = fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
            ok = fclose(f) == 0 && ok;
            if (!ok || !MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) DeleteFileA(tmp.c_str());
        }
    }
    std::lock_guard<std::mutex> lock(gShaderLock);
    gShaders[h] = std::move(bytes);
    return true;
}

int sqd3d_pipeline(SQD3D *g, const char *hlsl, const char *entry, char *err, int errLen) {
    ComPtr<ID3DBlob> cs;
    if (!compile(hlsl, entry, "cs_5_0", cs, err, errLen)) return -1;
    D3D12_COMPUTE_PIPELINE_STATE_DESC pd = {};
    pd.pRootSignature = g->root.Get();
    pd.CS = {cs->GetBufferPointer(), cs->GetBufferSize()};
    ComPtr<ID3D12PipelineState> pso;
    HRESULT hr = g->dev->CreateComputePipelineState(&pd, IID_PPV_ARGS(&pso));
    if (FAILED(hr)) {
        snprintf(err, errLen, "%s: pipeline (0x%08lx)", entry, (unsigned long)hr);
        return -1;
    }
    g->pipelines.push_back(pso);
    g->drawPipeline.push_back(0);
    return (int)g->pipelines.size() - 1;
}

int sqd3d_render_pipeline(SQD3D *g, const char *vsHlsl, const char *vsEntry, const char *psHlsl, const char *psEntry,
                          int format, int blend, char *err, int errLen) {
    ComPtr<ID3DBlob> vs, ps;
    if (!compile(vsHlsl, vsEntry, "vs_5_0", vs, err, errLen) || !compile(psHlsl, psEntry, "ps_5_0", ps, err, errLen)) return -1;
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
    pd.pRootSignature = g->root.Get();
    pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
    pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
    D3D12_RENDER_TARGET_BLEND_DESC &b = pd.BlendState.RenderTarget[0];
    b.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    b.LogicOp = D3D12_LOGIC_OP_NOOP;
    if (blend != 0) {
        // Premultiplied over (1) or additive (2): src * 1 + dst * (1 - src.a) or dst * 1.
        D3D12_BLEND dst = blend == 2 ? D3D12_BLEND_ONE : D3D12_BLEND_INV_SRC_ALPHA;
        b.BlendEnable = TRUE;
        b.SrcBlend = D3D12_BLEND_ONE; b.DestBlend = dst; b.BlendOp = D3D12_BLEND_OP_ADD;
        b.SrcBlendAlpha = D3D12_BLEND_ONE; b.DestBlendAlpha = dst; b.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    } else {
        b.SrcBlend = D3D12_BLEND_ONE; b.DestBlend = D3D12_BLEND_ZERO; b.BlendOp = D3D12_BLEND_OP_ADD;
        b.SrcBlendAlpha = D3D12_BLEND_ONE; b.DestBlendAlpha = D3D12_BLEND_ZERO; b.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    }
    pd.SampleMask = UINT_MAX;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = dxgi(format);
    pd.SampleDesc.Count = 1;
    ComPtr<ID3D12PipelineState> pso;
    HRESULT hr = g->dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));
    if (FAILED(hr)) {
        snprintf(err, errLen, "%s: draw pipeline (0x%08lx)", psEntry, (unsigned long)hr);
        return -1;
    }
    g->pipelines.push_back(pso);
    g->drawPipeline.push_back(1);
    return (int)g->pipelines.size() - 1;
}

static SQD3DTex *makeResource(SQD3D *g, const D3D12_RESOURCE_DESC &d) {
    D3D12_HEAP_PROPERTIES hp = heapProps(D3D12_HEAP_TYPE_DEFAULT);
    SQD3DTex *t = new SQD3DTex();
    if (FAILED(g->dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d, D3D12_RESOURCE_STATE_COMMON, nullptr,
                                               IID_PPV_ARGS(&t->res)))) {
        delete t;
        return nullptr;
    }
    return t;
}

SQD3DTex *sqd3d_texture(SQD3D *g, int width, int height, int format) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = (UINT64)width; d.Height = (UINT)height; d.DepthOrArraySize = 1; d.MipLevels = 1;
    d.Format = dxgi(format);
    d.SampleDesc.Count = 1;
    d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    SQD3DTex *t = makeResource(g, d);
    if (t) { t->width = width; t->height = height; t->format = format; }
    return t;
}

SQD3DTex *sqd3d_texture3d(SQD3D *g, int width, int height, int depth, int format) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D;
    d.Width = (UINT64)width; d.Height = (UINT)height; d.DepthOrArraySize = (UINT16)depth; d.MipLevels = 1;
    d.Format = dxgi(format);
    d.SampleDesc.Count = 1;
    SQD3DTex *t = makeResource(g, d);
    if (t) { t->width = width; t->height = height; t->depth = depth; t->format = format; t->kind = 1; }
    return t;
}

SQD3DTex *sqd3d_buffer(SQD3D *g, int length) {
    UINT64 n = ((UINT64)(length < 4 ? 4 : length) + 3) & ~(UINT64)3;
    D3D12_RESOURCE_DESC d = bufferDesc(n);
    d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    SQD3DTex *t = makeResource(g, d);
    if (t) { t->kind = 2; t->length = n; }
    return t;
}

void sqd3d_texture_release(SQD3DTex *t) {
    if (t && --t->refs == 0) delete t;
}

SQD3DList *sqd3d_begin(SQD3D *g) {
    if (!reset(g)) return nullptr;
    SQD3DList *l = new SQD3DList();
    l->g = g;
    g->current = l;
    // The slot's own descriptor and constant ranges (the first 256 ring bytes stay zero, see sqd3d_create).
    l->desc = (UINT)g->slot * kDescriptors;
    l->descEnd = l->desc + kDescriptors;
    l->ring = 256 + (UINT64)g->slot * kRingBytes;
    l->ringEnd = l->ring + kRingBytes;
    ID3D12DescriptorHeap *heaps[] = {g->heap.Get()};
    g->list->SetDescriptorHeaps(1, heaps);
    g->list->SetComputeRootSignature(g->root.Get());
    g->list->SetGraphicsRootSignature(g->root.Get());
    return l;
}

void sqd3d_set_pipeline(SQD3DList *l, int pipeline) { l->pipeline = pipeline; }

void sqd3d_set_input(SQD3DList *l, int slot, SQD3DTex *t) {
    if (slot < 0 || slot >= kInputs) return;
    if (t) retain(l, t);
    l->in[slot] = t;
}

void sqd3d_set_buffer(SQD3DList *l, int slot, SQD3DTex *t) {
    if (slot < 2 || slot > 4 || (t && t->kind != 2)) return;
    if (t) retain(l, t);
    l->buf[slot - 2] = t;
}

void sqd3d_set_output(SQD3DList *l, SQD3DTex *t) {
    if (t) retain(l, t);
    l->out = t;
}

void sqd3d_set_constants(SQD3DList *l, int slot, const void *bytes, int length) {
    if (slot < 0 || slot > 1) return;
    UINT64 size = ((UINT64)length + 255) & ~(UINT64)255;
    if (l->ring + size > l->ringEnd) { l->failed = true; return; }
    memcpy(l->g->ringMap + l->ring, bytes, (size_t)length);
    l->cb[slot] = l->g->ring->GetGPUVirtualAddress() + l->ring;
    l->ring += size;
}

static D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc(const SQD3DTex *t) {
    D3D12_SHADER_RESOURCE_VIEW_DESC d = {};
    d.Format = dxgi(t->format);
    d.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    if (t->kind == 1) { d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; d.Texture3D.MipLevels = 1; }
    else { d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; d.Texture2D.MipLevels = 1; }
    return d;
}

/// Moves the bound resources into their states and fills a fresh descriptor table (null views for unbound slots).
/// `written` = the dispatch's output or the draw's target (an input slot holding it is dropped). false: out of budget.
static bool bindTable(SQD3DList *l, SQD3DTex *written, bool draw, D3D12_GPU_DESCRIPTOR_HANDLE &table) {
    SQD3D *g = l->g;
    if (l->pipeline < 0 || l->pipeline >= (int)g->pipelines.size() || g->drawPipeline[l->pipeline] != (draw ? 1 : 0)) return false;
    if (l->desc + kTable > l->descEnd) return false;
    // An input slot left over from an earlier pass that holds this pass's output is dropped (Metal ignores stale slots
    // the shader does not read; here it would ask for two states of one resource).
    for (SQD3DTex *&t : l->in) if (t == written) t = nullptr;
    std::vector<D3D12_RESOURCE_BARRIER> b;
    for (SQD3DTex *t : l->in) if (t && t->kind != 2) want(b, t, D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE);
    if (written) want(b, written, draw ? D3D12_RESOURCE_STATE_RENDER_TARGET : D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    for (SQD3DTex *t : l->buf) if (t) want(b, t, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    if (!b.empty()) g->list->ResourceBarrier((UINT)b.size(), b.data());

    D3D12_CPU_DESCRIPTOR_HANDLE cpu = g->heap->GetCPUDescriptorHandleForHeapStart();
    D3D12_GPU_DESCRIPTOR_HANDLE gpu = g->heap->GetGPUDescriptorHandleForHeapStart();
    cpu.ptr += (SIZE_T)l->desc * g->descSize;
    gpu.ptr += (UINT64)l->desc * g->descSize;
    // Null views everywhere, then real ones for the bound slots.
    g->dev->CopyDescriptorsSimple(kTable, cpu, g->nulls->GetCPUDescriptorHandleForHeapStart(), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for (int i = 0; i < kInputs; i++) {
        SQD3DTex *t = l->in[i];
        // A 3D table only fits t24, a 2D texture every other slot (a mismatch keeps the null view).
        if (!t || t->kind == 2 || (t->kind == 1) != (i == kInputs - 1)) continue;
        D3D12_SHADER_RESOURCE_VIEW_DESC sd = srvDesc(t);
        g->dev->CreateShaderResourceView(t->res.Get(), &sd, {cpu.ptr + (SIZE_T)i * g->descSize});
    }
    if (l->out && !draw) {
        D3D12_UNORDERED_ACCESS_VIEW_DESC ud = {};
        ud.Format = dxgi(l->out->format);
        ud.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        g->dev->CreateUnorderedAccessView(l->out->res.Get(), nullptr, &ud, {cpu.ptr + (SIZE_T)kInputs * g->descSize});
    }
    for (int i = 0; i < 3; i++) {
        SQD3DTex *t = l->buf[i];
        if (!t) continue;
        D3D12_UNORDERED_ACCESS_VIEW_DESC ud = {};
        ud.Format = DXGI_FORMAT_UNKNOWN;
        ud.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
        ud.Buffer.NumElements = (UINT)(t->length / 4);
        ud.Buffer.StructureByteStride = 4;
        g->dev->CreateUnorderedAccessView(t->res.Get(), nullptr, &ud, {cpu.ptr + (SIZE_T)(kInputs + 2 + i) * g->descSize});
    }
    l->desc += kTable;
    table = gpu;
    return true;
}

void sqd3d_dispatch(SQD3DList *l, int width, int height) {
    SQD3D *g = l->g;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu;
    if (!bindTable(l, l->out, false, gpu)) { l->failed = true; return; }
    D3D12_GPU_VIRTUAL_ADDRESS zero = g->ring->GetGPUVirtualAddress();
    g->list->SetPipelineState(g->pipelines[l->pipeline].Get());
    g->list->SetComputeRootConstantBufferView(0, l->cb[0] ? l->cb[0] : zero);
    g->list->SetComputeRootConstantBufferView(1, l->cb[1] ? l->cb[1] : zero);
    g->list->SetComputeRootDescriptorTable(2, gpu);
    g->list->Dispatch((UINT)(width + kGroup - 1) / kGroup, (UINT)(height + kGroup - 1) / kGroup, 1);

    // The next dispatch may read what this one wrote.
    D3D12_RESOURCE_BARRIER uav = {};
    uav.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    uav.UAV.pResource = nullptr;
    g->list->ResourceBarrier(1, &uav);
}

void sqd3d_begin_render(SQD3DList *l, SQD3DTex *target, int clear, const float *rgba) {
    SQD3D *g = l->g;
    if (!target || target->kind != 0 || l->rtv >= kRTVs) { l->failed = true; l->target = nullptr; return; }
    retain(l, target);
    l->target = target;
    std::vector<D3D12_RESOURCE_BARRIER> b;
    want(b, target, D3D12_RESOURCE_STATE_RENDER_TARGET);
    if (!b.empty()) g->list->ResourceBarrier((UINT)b.size(), b.data());
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = g->rtvs->GetCPUDescriptorHandleForHeapStart();
    rtv.ptr += (SIZE_T)l->rtv++ * g->rtvSize;
    g->dev->CreateRenderTargetView(target->res.Get(), nullptr, rtv);
    g->list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    if (clear) g->list->ClearRenderTargetView(rtv, rgba, 0, nullptr);
    sqd3d_set_viewport(l, 0, 0, (float)target->width, (float)target->height);
    sqd3d_set_scissor(l, 0, 0, target->width, target->height);
}

void sqd3d_set_viewport(SQD3DList *l, float x, float y, float width, float height) {
    D3D12_VIEWPORT v = {x, y, width, height, 0.0f, 1.0f};
    l->g->list->RSSetViewports(1, &v);
}

void sqd3d_set_scissor(SQD3DList *l, int x, int y, int width, int height) {
    D3D12_RECT r = {x, y, x + width, y + height};
    l->g->list->RSSetScissorRects(1, &r);
}

void sqd3d_draw(SQD3DList *l, int vertexCount, int strip) {
    SQD3D *g = l->g;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu;
    if (!l->target || !bindTable(l, l->target, true, gpu)) { l->failed = true; return; }
    D3D12_GPU_VIRTUAL_ADDRESS zero = g->ring->GetGPUVirtualAddress();
    g->list->SetPipelineState(g->pipelines[l->pipeline].Get());
    g->list->SetGraphicsRootConstantBufferView(0, l->cb[0] ? l->cb[0] : zero);
    g->list->SetGraphicsRootConstantBufferView(1, l->cb[1] ? l->cb[1] : zero);
    g->list->SetGraphicsRootDescriptorTable(2, gpu);
    g->list->IASetPrimitiveTopology(strip ? D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP : D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    g->list->DrawInstanced((UINT)vertexCount, 1, 0, 0);
    // A data buffer the pixel shader wrote may be read next.
    D3D12_RESOURCE_BARRIER uav = {};
    uav.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    uav.UAV.pResource = nullptr;
    g->list->ResourceBarrier(1, &uav);
}

int sqd3d_copy(SQD3DList *l, SQD3DTex *src, SQD3DTex *dst) {
    if (!src || !dst || src->kind != 0 || dst->kind != 0 || src->width != dst->width || src->height != dst->height ||
        src->format != dst->format) return 0;
    retain(l, src);
    retain(l, dst);
    std::vector<D3D12_RESOURCE_BARRIER> b;
    want(b, src, D3D12_RESOURCE_STATE_COPY_SOURCE);
    want(b, dst, D3D12_RESOURCE_STATE_COPY_DEST);
    if (!b.empty()) l->g->list->ResourceBarrier((UINT)b.size(), b.data());
    l->g->list->CopyResource(dst->res.Get(), src->res.Get());
    return 1;
}

/// Hands the list's retained textures to its slot (released once the GPU finished it).
static int finishList(SQD3DList *l, bool wait) {
    SQD3D *g = l->g;
    SQD3D::Slot &s = g->slots[g->slot];
    for (SQD3DTex *t : l->retained) s.retained.push_back(t);
    l->retained.clear();
    bool ok = submit(g, wait) && !l->failed;
    delete l;
    return ok ? 0 : -1;
}

int sqd3d_commit_wait(SQD3DList *l) { return finishList(l, true); }

int sqd3d_commit(SQD3DList *l) { return finishList(l, false); }

int sqd3d_in_flight_max(const SQD3D *g) { return (int)g->inFlightMax; }

/// Staging buffer + footprint of a whole texture (one subresource; a 3D table has `depth` slices of `rows` rows).
/// A pooled buffer of `type` that holds `total` bytes (at most half again as large), else a new one.
static bool staging(SQD3D *g, SQD3DTex *t, D3D12_HEAP_TYPE type, SQD3D::Staged &out,
                    D3D12_PLACED_SUBRESOURCE_FOOTPRINT &fp, UINT &rows) {
    D3D12_HEAP_PROPERTIES hp = heapProps(type);
    D3D12_RESOURCE_STATES s = type == D3D12_HEAP_TYPE_UPLOAD ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COPY_DEST;
    UINT64 total = t->length;
    if (t->kind != 2) {
        D3D12_RESOURCE_DESC d = t->res->GetDesc();
        UINT64 rowSize = 0;
        g->dev->GetCopyableFootprints(&d, 0, 1, 0, &fp, &rows, &rowSize, &total);
    }
    bool upload = type == D3D12_HEAP_TYPE_UPLOAD;
    for (size_t i = g->stagingPool.size(); i-- > 0;) {
        auto &p = g->stagingPool[i];
        if (p.upload == upload && p.size >= total && p.size <= total + total / 2) {
            out = std::move(p);
            g->stagingPoolBytes -= out.size;
            g->stagingPool.erase(g->stagingPool.begin() + i);
            return true;
        }
    }
    D3D12_RESOURCE_DESC bd = bufferDesc(total);
    out = SQD3D::Staged{nullptr, total, upload};
    return SUCCEEDED(g->dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, s, nullptr, IID_PPV_ARGS(&out.buf)));
}

/// Records the copy between `t` and its staging buffer (direction by `toTexture`).
static void stagingCopy(SQD3D *g, SQD3DTex *t, ID3D12Resource *buf, const D3D12_PLACED_SUBRESOURCE_FOOTPRINT &fp, bool toTexture) {
    std::vector<D3D12_RESOURCE_BARRIER> b;
    want(b, t, toTexture ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COPY_SOURCE);
    if (!b.empty()) g->list->ResourceBarrier((UINT)b.size(), b.data());
    if (t->kind == 2) {
        if (toTexture) g->list->CopyBufferRegion(t->res.Get(), 0, buf, 0, t->length);
        else g->list->CopyBufferRegion(buf, 0, t->res.Get(), 0, t->length);
        return;
    }
    D3D12_TEXTURE_COPY_LOCATION tex = {}, stage = {};
    tex.pResource = t->res.Get(); tex.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; tex.SubresourceIndex = 0;
    stage.pResource = buf; stage.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; stage.PlacedFootprint = fp;
    if (toTexture) g->list->CopyTextureRegion(&tex, 0, 0, 0, &stage, nullptr);
    else g->list->CopyTextureRegion(&stage, 0, 0, 0, &tex, nullptr);
}

int sqd3d_upload(SQD3D *g, SQD3DTex *t, const void *bytes, int bytesPerRow) {
    SQD3D::Staged st;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp = {};
    UINT rows = 0;
    if (!staging(g, t, D3D12_HEAP_TYPE_UPLOAD, st, fp, rows)) return -1;
    ID3D12Resource *buf = st.buf.Get();
    uint8_t *map = nullptr;
    D3D12_RANGE none = {0, 0};
    if (FAILED(buf->Map(0, &none, (void **)&map))) return -1;
    if (t->kind == 2) memcpy(map, bytes, (size_t)t->length);
    else {
        size_t row = (size_t)t->width * bytesPerPixel(t->format);
        if ((size_t)bytesPerRow < row) row = (size_t)bytesPerRow;
        for (UINT z = 0; z < (UINT)t->depth; z++)
            for (UINT y = 0; y < rows; y++)
                memcpy(map + fp.Offset + ((size_t)z * rows + y) * fp.Footprint.RowPitch,
                       (const uint8_t *)bytes + ((size_t)z * t->height + y) * bytesPerRow, row);
    }
    buf->Unmap(0, nullptr);
    if (g->open) {
        // A command buffer is recording: the copy joins it, so later passes in it see the data (Metal uploads at once,
        // before the buffer runs; a texture uploaded twice in one buffer would differ, the engines never do that).
        stagingCopy(g, t, buf, fp, true);
        g->pendingStaging.push_back(std::move(st));
        if (g->current) retain(g->current, t);   // the copy runs later: keep the texture alive until then
        return 0;
    }
    if (!reset(g)) { poolStaging(g, std::move(st)); return -1; }
    stagingCopy(g, t, buf, fp, true);
    g->pendingStaging.push_back(std::move(st));
    return submit(g) ? 0 : -1;
}

int sqd3d_download(SQD3D *g, SQD3DTex *t, void *out, int bytesPerRow) {
    SQD3D::Staged st;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp = {};
    UINT rows = 0;
    if (!staging(g, t, D3D12_HEAP_TYPE_READBACK, st, fp, rows)) return -1;
    ComPtr<ID3D12Resource> buf = st.buf;
    if (!reset(g)) { poolStaging(g, std::move(st)); return -1; }
    stagingCopy(g, t, buf.Get(), fp, false);
    // Pooled only after the bytes are copied out below (submit returns it to the pool before the Map otherwise).
    if (!submit(g)) { poolStaging(g, std::move(st)); return -1; }
    uint8_t *map = nullptr;
    if (FAILED(buf->Map(0, nullptr, (void **)&map))) { poolStaging(g, std::move(st)); return -1; }
    if (t->kind == 2) memcpy(out, map, (size_t)t->length);
    else {
        size_t row = (size_t)t->width * bytesPerPixel(t->format);
        if ((size_t)bytesPerRow < row) row = (size_t)bytesPerRow;
        for (UINT z = 0; z < (UINT)t->depth; z++)
            for (UINT y = 0; y < rows; y++)
                memcpy((uint8_t *)out + ((size_t)z * t->height + y) * bytesPerRow,
                       map + fp.Offset + ((size_t)z * rows + y) * fp.Footprint.RowPitch, row);
    }
    D3D12_RANGE none = {0, 0};
    buf->Unmap(0, &none);
    poolStaging(g, std::move(st));
    return 0;
}

/// A readback recorded into an open list: the bytes are mapped once its list finished (`sqd3d_readback_finish`).
struct SQD3DReadback {
    SQD3D *g = nullptr;
    SQD3D::Staged st;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp = {};
    UINT rows = 0;
    UINT64 fence = 0;
    int width = 0, height = 0, format = 0;
};

SQD3DReadback *sqd3d_readback(SQD3DList *l, SQD3DTex *t) {
    SQD3D *g = l->g;
    if (!g->open || !t || t->kind != 0) return nullptr;
    SQD3DReadback *r = new SQD3DReadback();
    r->g = g;
    if (!staging(g, t, D3D12_HEAP_TYPE_READBACK, r->st, r->fp, r->rows)) { delete r; return nullptr; }
    retain(l, t);
    stagingCopy(g, t, r->st.buf.Get(), r->fp, false);
    r->fence = g->fenceValue + 1;   // the open list's signal (nothing else submits while a list is open)
    r->width = t->width; r->height = t->height; r->format = t->format;
    return r;
}

int sqd3d_readback_finish(SQD3DReadback *r, void *out, int bytesPerRow) {
    if (!r) return -1;
    SQD3D *g = r->g;
    int result = -1;
    if (g->fenceValue >= r->fence) {   // its list was submitted
        waitFence(g, r->fence);
        uint8_t *map = nullptr;
        if (SUCCEEDED(r->st.buf->Map(0, nullptr, (void **)&map))) {
            size_t row = (size_t)r->width * bytesPerPixel(r->format);
            if ((size_t)bytesPerRow < row) row = (size_t)bytesPerRow;
            for (UINT y = 0; y < r->rows; y++)
                memcpy((uint8_t *)out + (size_t)y * bytesPerRow, map + r->fp.Offset + (size_t)y * r->fp.Footprint.RowPitch, row);
            D3D12_RANGE none = {0, 0};
            r->st.buf->Unmap(0, &none);
            result = 0;
        }
        poolStaging(g, std::move(r->st));
    }
    delete r;
    return result;
}

void *sqd3d_native_device(SQD3D *g) { return g->dev.Get(); }
void *sqd3d_native_queue(SQD3D *g) { return g->queue.Get(); }

void *sqd3d_texture_for_sampling(SQD3D *g, SQD3DTex *t) {
    const D3D12_RESOURCE_STATES s = D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE;
    if (t->state != s) {
        bool own = !g->open;
        if (own && !reset(g)) return nullptr;
        std::vector<D3D12_RESOURCE_BARRIER> b;
        want(b, t, s);
        g->list->ResourceBarrier((UINT)b.size(), b.data());
        if (own && !submit(g)) return nullptr;
    }
    return t->res.Get();
}
#endif
