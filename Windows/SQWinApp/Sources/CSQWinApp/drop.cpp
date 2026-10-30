// Explorer drags over the window: an OLE IDropTarget, so the timeline can show its drop ghost while files hover
// (WM_DROPFILES alone reports only the release). The hover is polled (`sq_drop_hover`, `sq_drop_paths`); the release
// is handed on as the WM_DROPFILES the window already handles, with the drop point in client pixels.
#include "csqwinapp.h"
#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>   // DROPFILES
#include <string.h>
#include <string>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")

namespace {

HWND gHwnd = nullptr;
bool gHovering = false;
float gX = 0, gY = 0;
/// The hovering drag's paths, each NUL-terminated.
std::wstring gPaths;

void clientPoint(POINTL pt, float &x, float &y) {
    POINT p{pt.x, pt.y};
    ScreenToClient(gHwnd, &p);
    x = (float)p.x;
    y = (float)p.y;
}

/// The CF_HDROP paths of `d`; `copy` (when given) gets a copy of the HDROP the window procedure can own.
bool readPaths(IDataObject *d, std::wstring &out, HGLOBAL *copy) {
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM med{};
    if (!d || FAILED(d->GetData(&fmt, &med))) return false;
    HDROP drop = (HDROP)med.hGlobal;
    UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    out.clear();
    for (UINT i = 0; i < n; i++) {
        UINT len = DragQueryFileW(drop, i, nullptr, 0);
        std::wstring s(len + 1, L'\0');
        DragQueryFileW(drop, i, &s[0], len + 1);
        s.resize(len);
        out += s;
        out.push_back(L'\0');
    }
    if (copy) {
        *copy = nullptr;
        SIZE_T size = GlobalSize(med.hGlobal);
        void *src = GlobalLock(med.hGlobal);
        HGLOBAL h = src ? GlobalAlloc(GHND, size) : nullptr;
        if (h) {
            void *dst = GlobalLock(h);
            memcpy(dst, src, size);
            GlobalUnlock(h);
            *copy = h;
        }
        if (src) GlobalUnlock(med.hGlobal);
    }
    ReleaseStgMedium(&med);
    return n > 0;
}

class Target final : public IDropTarget {
    LONG refs = 1;
    bool files = false;

public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (riid == IID_IUnknown || riid == IID_IDropTarget) {
            *ppv = static_cast<IDropTarget *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG r = InterlockedDecrement(&refs);
        if (r == 0) delete this;
        return (ULONG)r;
    }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject *d, DWORD, POINTL pt, DWORD *effect) override {
        files = readPaths(d, gPaths, nullptr);
        gHovering = files;
        clientPoint(pt, gX, gY);
        *effect = files ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL pt, DWORD *effect) override {
        if (files) clientPoint(pt, gX, gY);
        *effect = files ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override {
        files = false;
        gHovering = false;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject *d, DWORD, POINTL pt, DWORD *effect) override {
        files = false;
        gHovering = false;
        std::wstring paths;
        HGLOBAL copy = nullptr;
        *effect = DROPEFFECT_NONE;
        if (readPaths(d, paths, &copy) && copy) {
            auto *df = (DROPFILES *)GlobalLock(copy);
            POINT p{pt.x, pt.y};
            ScreenToClient(gHwnd, &p);
            df->pt = p;
            df->fNC = FALSE;
            GlobalUnlock(copy);
            // The window procedure reads it like any WM_DROPFILES and frees it (DragFinish).
            if (PostMessageW(gHwnd, WM_DROPFILES, (WPARAM)copy, 0)) *effect = DROPEFFECT_COPY;
            else GlobalFree(copy);
        } else if (copy) {
            GlobalFree(copy);
        }
        return S_OK;
    }
};

} // namespace

extern "C" int sq_drop_register(void *hwnd) {
    gHwnd = (HWND)hwnd;
    HRESULT hr = OleInitialize(nullptr);
    if (FAILED(hr)) return (int)hr;   // WM_DROPFILES (DragAcceptFiles) still takes the drops, without a hover
    auto *t = new Target();
    hr = RegisterDragDrop(gHwnd, t);
    t->Release();
    return SUCCEEDED(hr) ? 0 : (int)hr;
}

extern "C" int sq_drop_hover(float *x, float *y) {
    if (!gHovering) return 0;
    *x = gX;
    *y = gY;
    return 1;
}

extern "C" int sq_drop_paths(uint16_t *buf, int capacity) {
    int n = (int)gPaths.size();
    if (buf && capacity >= n) memcpy(buf, gPaths.data(), (size_t)n * sizeof(uint16_t));
    return n;
}

// The exe is a console program (the test scripts read its output); started from Explorer it would show an empty black
// window. GetConsoleProcessList counts every process on the console: 1 = only us, so nobody reads it.
extern "C" int sq_detach_own_console(void) {
    DWORD ids[2];
    if (GetConsoleProcessList(ids, 2) != 1) return 0;
    return FreeConsole() ? 1 : 0;
}
