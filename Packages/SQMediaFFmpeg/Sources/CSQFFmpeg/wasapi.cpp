// WASAPI shared-mode output: event-driven render thread pulling 48 kHz stereo float from a callback. The audio engine
// converts to the device's mix format (AUTOCONVERTPCM), so the timeline mix stays at 48 kHz like on the Mac.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <propsys.h>
#include <atomic>
#include <stdio.h>
#include <string.h>
#include <thread>
#include "csqffmpeg.h"

static const PROPERTYKEY kFriendlyName = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

struct SQWasapi {
    IMMDevice *device = nullptr;
    IAudioClient *client = nullptr;
    IAudioRenderClient *render = nullptr;
    HANDLE event = nullptr;
    UINT32 bufferFrames = 0;
    int64_t latency = 0;
    std::atomic<bool> running{false};
    std::atomic<int64_t> rendered{0};
    std::thread thread;
    SQWasapiRender cb = nullptr;
    void *ctx = nullptr;
    char name[128] = {0};
};

static int64_t qpcNanos() {
    static LARGE_INTEGER f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x; }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (int64_t)((__int128)c.QuadPart * 1000000000 / f.QuadPart);
}

static int fail(char *err, int errLen, const char *what, HRESULT hr) {
    if (err) snprintf(err, errLen, "%s: HRESULT 0x%08lx", what, (unsigned long)hr);
    return hr < 0 ? (int)hr : -1;
}

// UTF-8 friendly name of `device` into `out` (empty when unknown).
static void friendlyName(IMMDevice *device, char *out, int len) {
    out[0] = 0;
    IPropertyStore *props = nullptr;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
        PROPVARIANT v;
        PropVariantInit(&v);
        if (SUCCEEDED(props->GetValue(kFriendlyName, &v)) && v.vt == VT_LPWSTR)
            WideCharToMultiByte(CP_UTF8, 0, v.pwszVal, -1, out, len - 1, nullptr, nullptr);
        PropVariantClear(&v);
        props->Release();
    }
}

int sq_wasapi_list_outputs(char *buf, int len) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (buf && len > 0) buf[0] = 0;
    IMMDeviceEnumerator *en = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en))) return 0;
    IMMDeviceCollection *list = nullptr;
    int used = 0;
    if (SUCCEEDED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &list))) {
        UINT count = 0;
        list->GetCount(&count);
        for (UINT i = 0; i < count; i++) {
            IMMDevice *d = nullptr;
            if (FAILED(list->Item(i, &d))) continue;
            LPWSTR id = nullptr;
            char idUTF8[512] = {0}, name[256] = {0};
            if (SUCCEEDED(d->GetId(&id))) {
                WideCharToMultiByte(CP_UTF8, 0, id, -1, idUTF8, sizeof idUTF8 - 1, nullptr, nullptr);
                CoTaskMemFree(id);
            }
            friendlyName(d, name, sizeof name);
            d->Release();
            if (!idUTF8[0]) continue;
            int n = snprintf(nullptr, 0, "%s\t%s\n", idUTF8, name);
            if (buf && used + n < len) snprintf(buf + used, len - used, "%s\t%s\n", idUTF8, name);
            used += n;
        }
        list->Release();
    }
    en->Release();
    return used + 1;
}

int sq_wasapi_open(SQWasapiRender render, void *ctx, SQWasapi **out, char *err, int errLen) {
    return sq_wasapi_open_device(nullptr, render, ctx, out, err, errLen);
}

int sq_wasapi_open_device(const char *deviceID, SQWasapiRender render, void *ctx, SQWasapi **out, char *err, int errLen) {
    *out = nullptr;
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    SQWasapi *w = new SQWasapi();
    w->cb = render; w->ctx = ctx;
    IMMDeviceEnumerator *en = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en);
    if (FAILED(hr)) { delete w; return fail(err, errLen, "device enumerator", hr); }
    hr = E_FAIL;
    if (deviceID && deviceID[0]) {
        wchar_t wid[512] = {0};
        if (MultiByteToWideChar(CP_UTF8, 0, deviceID, -1, wid, 511) > 0) hr = en->GetDevice(wid, &w->device);
        DWORD state = 0;
        if (SUCCEEDED(hr) && (FAILED(w->device->GetState(&state)) || state != DEVICE_STATE_ACTIVE)) {
            w->device->Release(); w->device = nullptr; hr = E_FAIL;
        }
    }
    // A device that is not connected (or none asked for) plays on the system default.
    if (FAILED(hr)) hr = en->GetDefaultAudioEndpoint(eRender, eConsole, &w->device);
    en->Release();
    if (FAILED(hr)) { sq_wasapi_close(w); return fail(err, errLen, "no output device", hr); }
    friendlyName(w->device, w->name, sizeof w->name);
    hr = w->device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&w->client);
    if (FAILED(hr)) { sq_wasapi_close(w); return fail(err, errLen, "activate", hr); }
    WAVEFORMATEXTENSIBLE fmt = {};
    fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    fmt.Format.nChannels = 2;
    fmt.Format.nSamplesPerSec = 48000;
    fmt.Format.wBitsPerSample = 32;
    fmt.Format.nBlockAlign = 8;
    fmt.Format.nAvgBytesPerSec = 48000 * 8;
    fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    fmt.Samples.wValidBitsPerSample = 32;
    fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    const REFERENCE_TIME bufferDuration = 200000;   // 20 ms in 100 ns units
    hr = w->client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                               AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                   AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                               bufferDuration, 0, (WAVEFORMATEX *)&fmt, nullptr);
    if (FAILED(hr)) { sq_wasapi_close(w); return fail(err, errLen, "initialize", hr); }
    w->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    w->client->SetEventHandle(w->event);
    w->client->GetBufferSize(&w->bufferFrames);
    REFERENCE_TIME streamLatency = 0;
    w->client->GetStreamLatency(&streamLatency);
    w->latency = (int64_t)streamLatency * 48000 / 10000000 + w->bufferFrames;
    hr = w->client->GetService(__uuidof(IAudioRenderClient), (void **)&w->render);
    if (FAILED(hr)) { sq_wasapi_close(w); return fail(err, errLen, "render client", hr); }
    *out = w;
    return 0;
}

static void renderLoop(SQWasapi *w) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HANDLE task = nullptr;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    while (w->running.load(std::memory_order_acquire)) {
        if (WaitForSingleObject(w->event, 200) != WAIT_OBJECT_0) continue;
        UINT32 padding = 0;
        if (FAILED(w->client->GetCurrentPadding(&padding))) break;
        UINT32 avail = w->bufferFrames - padding;
        if (avail == 0) continue;
        BYTE *data = nullptr;
        if (FAILED(w->render->GetBuffer(avail, &data))) break;
        w->cb(w->ctx, (float *)data, (int)avail, qpcNanos());
        w->render->ReleaseBuffer(avail, 0);
        w->rendered.fetch_add(avail, std::memory_order_relaxed);
    }
    (void)task;
    CoUninitialize();
}

int sq_wasapi_start(SQWasapi *w) {
    if (w->running.exchange(true)) return 0;
    // Prime the buffer with silence so the first period does not underrun.
    BYTE *data = nullptr;
    if (SUCCEEDED(w->render->GetBuffer(w->bufferFrames, &data))) w->render->ReleaseBuffer(w->bufferFrames, AUDCLNT_BUFFERFLAGS_SILENT);
    w->thread = std::thread(renderLoop, w);
    HRESULT hr = w->client->Start();
    if (FAILED(hr)) { sq_wasapi_stop(w); return (int)hr; }
    return 0;
}

void sq_wasapi_stop(SQWasapi *w) {
    if (!w->running.exchange(false)) return;
    SetEvent(w->event);
    if (w->thread.joinable()) w->thread.join();
    w->client->Stop();
    w->client->Reset();
}

void sq_wasapi_close(SQWasapi *w) {
    if (!w) return;
    if (w->client) sq_wasapi_stop(w);
    if (w->render) w->render->Release();
    if (w->client) w->client->Release();
    if (w->device) w->device->Release();
    if (w->event) CloseHandle(w->event);
    delete w;
}

int64_t sq_wasapi_latency_frames(const SQWasapi *w) { return w->latency; }
int64_t sq_wasapi_rendered_frames(const SQWasapi *w) { return w->rendered.load(std::memory_order_relaxed); }
const char *sq_wasapi_device_name(const SQWasapi *w) { return w->name; }
