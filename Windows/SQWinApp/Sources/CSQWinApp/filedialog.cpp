// The Windows file and folder choosers: the Common Item Dialog (IFileOpenDialog / IFileSaveDialog, FOS_PICKFOLDERS for
// folders), the system window the Mac counterpart NSOpenPanel / NSSavePanel also keeps.
#include "csqwinapp.h"
#include <windows.h>
#include <shobjidl.h>
#include <ole2.h>
#include <string.h>
#include <thread>
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "uuid.lib")

namespace {

const wchar_t *w(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }

/// Appends the file system path of `item` and a NUL to `out`; false when it has none.
bool appendPath(IShellItem *item, std::wstring &out) {
    PWSTR path = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) || !path) return false;
    out += path;
    out.push_back(L'\0');
    CoTaskMemFree(path);
    return true;
}

/// The dialog itself, on a thread that is (or becomes) STA.
int runDialog(void *owner, int mode, const uint16_t *title, const uint16_t *filter, const uint16_t *folder,
              const uint16_t *name, const uint16_t *defaultExtension, uint16_t *out, int capacity) {
    if (out && capacity > 0) out[0] = 0;
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    const bool uninit = SUCCEEDED(init);
    const bool save = mode == SQ_FILE_DIALOG_SAVE;
    IFileDialog *dlg = nullptr;
    HRESULT hr = save ? CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(reinterpret_cast<IFileSaveDialog **>(&dlg)))
                      : CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(reinterpret_cast<IFileOpenDialog **>(&dlg)));
    if (FAILED(hr) || !dlg) { if (uninit) CoUninitialize(); return -1; }

    FILEOPENDIALOGOPTIONS opts = 0;
    dlg->GetOptions(&opts);
    opts |= FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST;
    if (save) opts |= FOS_OVERWRITEPROMPT;
    if (mode == SQ_FILE_DIALOG_OPEN || mode == SQ_FILE_DIALOG_OPEN_MULTIPLE) opts |= FOS_FILEMUSTEXIST;
    if (mode == SQ_FILE_DIALOG_OPEN_MULTIPLE) opts |= FOS_ALLOWMULTISELECT;
    if (mode == SQ_FILE_DIALOG_FOLDER) opts |= FOS_PICKFOLDERS;
    dlg->SetOptions(opts);
    if (title && title[0]) dlg->SetTitle(w(title));

    // "label\0pattern\0label\0pattern\0\0"
    std::vector<COMDLG_FILTERSPEC> specs;
    if (filter && mode != SQ_FILE_DIALOG_FOLDER) {
        const wchar_t *p = w(filter);
        while (*p) {
            const wchar_t *label = p;
            p += wcslen(p) + 1;
            if (!*p) break;
            specs.push_back({label, p});
            p += wcslen(p) + 1;
        }
        if (!specs.empty()) dlg->SetFileTypes(static_cast<UINT>(specs.size()), specs.data());
    }
    if (defaultExtension && defaultExtension[0] && save) dlg->SetDefaultExtension(w(defaultExtension));
    if (name && name[0]) dlg->SetFileName(w(name));
    if (folder && folder[0]) {
        IShellItem *start = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(w(folder), nullptr, IID_PPV_ARGS(&start)))) {
            dlg->SetFolder(start);
            start->Release();
        }
    }

    int count = 0;
    std::wstring paths;
    hr = dlg->Show(static_cast<HWND>(owner));
    if (SUCCEEDED(hr)) {
        if (mode == SQ_FILE_DIALOG_OPEN_MULTIPLE) {
            IFileOpenDialog *open = nullptr;
            IShellItemArray *items = nullptr;
            if (SUCCEEDED(dlg->QueryInterface(IID_PPV_ARGS(&open))) && SUCCEEDED(open->GetResults(&items))) {
                DWORD n = 0;
                items->GetCount(&n);
                for (DWORD i = 0; i < n; i++) {
                    IShellItem *item = nullptr;
                    if (SUCCEEDED(items->GetItemAt(i, &item))) {
                        if (appendPath(item, paths)) count++;
                        item->Release();
                    }
                }
                items->Release();
            }
            if (open) open->Release();
        } else {
            IShellItem *item = nullptr;
            if (SUCCEEDED(dlg->GetResult(&item))) {
                if (appendPath(item, paths)) count++;
                item->Release();
            }
        }
    } else if (hr != HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        count = -1;
    }
    dlg->Release();
    if (uninit) CoUninitialize();
    if (count <= 0) return count;
    paths.push_back(L'\0');
    if (!out || static_cast<int>(paths.size()) > capacity) return -2;
    memcpy(out, paths.data(), paths.size() * sizeof(wchar_t));
    return count;
}

bool callerIsMTA() {
    APTTYPE type;
    APTTYPEQUALIFIER qualifier;
    if (FAILED(CoGetApartmentType(&type, &qualifier))) return false;   // CO_E_NOTINITIALIZED: becomes STA in runDialog
    return type == APTTYPE_MTA || (type == APTTYPE_NA && qualifier == APTTYPEQUALIFIER_NA_ON_MTA)
        || qualifier == APTTYPEQUALIFIER_IMPLICIT_MTA;
}

}  // namespace

extern "C" int sq_com_init_ui_thread(void) { return (int)OleInitialize(nullptr); }

extern "C" int sq_com_is_sta(void) {
    APTTYPE type;
    APTTYPEQUALIFIER qualifier;
    if (FAILED(CoGetApartmentType(&type, &qualifier))) return 0;
    return type == APTTYPE_STA || type == APTTYPE_MAINSTA ? 1 : 0;
}

int sq_file_dialog(void *owner, int mode, const uint16_t *title, const uint16_t *filter, const uint16_t *folder,
                   const uint16_t *name, const uint16_t *defaultExtension, uint16_t *out, int capacity) {
    if (!callerIsMTA()) return runDialog(owner, mode, title, filter, folder, name, defaultExtension, out, capacity);
    // An MTA caller would block in a non-pumping COM wait while the shell runs the dialog in an STA of its own: the
    // owner window stops answering ("Not responding", then Windows kills it). Run it on an STA thread instead and keep
    // dispatching this thread's messages until it returns (the dialog disables the owner, so no input slips through).
    int result = -1;
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!done) return -1;
    std::thread worker([&] {
        result = runDialog(owner, mode, title, filter, folder, name, defaultExtension, out, capacity);
        SetEvent(done);
    });
    for (;;) {
        DWORD r = MsgWaitForMultipleObjects(1, &done, FALSE, INFINITE, QS_ALLINPUT);
        if (r == WAIT_OBJECT_0) break;
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { PostQuitMessage((int)msg.wParam); break; }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    worker.join();
    CloseHandle(done);
    return result;
}
