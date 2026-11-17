#include "csqonnx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif
#include "ort/onnxruntime_c_api.h"

#ifdef _WIN32
typedef OrtStatus *(ORT_API_CALL *AppendDML)(OrtSessionOptions *, int);
typedef HMODULE sqort_module;
#else
typedef void *sqort_module;
#endif

struct sqort_session {
    OrtSession *session;
    OrtSessionOptions *options;
    OrtMemoryInfo *memory;
    OrtAllocator *allocator;
    int nin, nout;
    char **in_names, **out_names;
    const char *provider;   // the provider that runs: "cpu", "directml" or "coreml"
    char fallback[512];     // why the asked provider was not used (empty when it was)
};

static const OrtApi *api = NULL;
static OrtEnv *env = NULL;
static sqort_module module = NULL;

/* Releases a status nobody can act on (cleanup paths). */
static void drop(OrtStatus *status) { if (status) api->ReleaseStatus(status); }

static void fail(char *err, int cap, const char *what, OrtStatus *status) {
    if (!err || cap <= 0) { if (status) api->ReleaseStatus(status); return; }
    if (status) {
        snprintf(err, (size_t)cap, "%s: %s", what, api->GetErrorMessage(status));
        api->ReleaseStatus(status);
    } else {
        snprintf(err, (size_t)cap, "%s", what);
    }
}

#ifdef _WIN32
/* Windows 11 ships an older onnxruntime.dll in System32 (WinML): the bare name would find that one first. Look next to
   the exe, then through PATH, and only then fall back to the bare name. */
static HMODULE load_beside_or_on_path(void) {
    wchar_t exe[1024], candidate[1536];
    DWORD n = GetModuleFileNameW(NULL, exe, 1024);
    if (n > 0 && n < 1024) {
        wchar_t *slash = wcsrchr(exe, L'\\');
        if (slash) {
            *slash = 0;
            swprintf(candidate, 1536, L"%ls\\onnxruntime.dll", exe);
            if (GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES) {
                HMODULE m = LoadLibraryW(candidate);
                if (m) return m;
            }
        }
    }
    DWORD need = GetEnvironmentVariableW(L"PATH", NULL, 0);
    if (need == 0) return NULL;
    wchar_t *path = (wchar_t *)malloc(need * sizeof(wchar_t));
    if (!path) return NULL;
    GetEnvironmentVariableW(L"PATH", path, need);
    HMODULE found = NULL;
    wchar_t *ctx = NULL;
    for (wchar_t *dir = wcstok(path, L";", &ctx); dir && !found; dir = wcstok(NULL, L";", &ctx)) {
        swprintf(candidate, 1536, L"%ls\\onnxruntime.dll", dir);
        if (GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES) found = LoadLibraryW(candidate);
    }
    free(path);
    return found;
}
#else
/* macOS / Linux: next to the exe, in the bundle's Frameworks folder (../Frameworks), in SQ_ONNXRUNTIME, then the bare name. */
#ifdef __APPLE__
#define SQORT_LIB "libonnxruntime.dylib"
#else
#define SQORT_LIB "libonnxruntime.so"
#endif
static void *try_open(const char *dir, const char *rel) {
    char candidate[2048];
    snprintf(candidate, sizeof candidate, "%s%s%s", dir, rel, SQORT_LIB);
    return access(candidate, R_OK) == 0 ? dlopen(candidate, RTLD_NOW | RTLD_LOCAL) : NULL;
}
static void *load_beside_or_named(void) {
    char exe[1024] = {0};
#ifdef __APPLE__
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) exe[0] = 0;
#else
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n < 0) exe[0] = 0;
#endif
    void *m = NULL;
    char *slash = strrchr(exe, '/');
    if (slash) {
        *slash = 0;
        if (!m) m = try_open(exe, "/../Frameworks/");
        if (!m) m = try_open(exe, "/");
    }
    const char *env = getenv("SQ_ONNXRUNTIME");
    if (!m && env && env[0]) m = try_open(env, "/");
    if (!m) m = dlopen(SQORT_LIB, RTLD_NOW | RTLD_LOCAL);
    return m;
}
#endif

int sqort_load(const char *dll, char *err, int cap) {
    if (api) return 0;
#ifdef _WIN32
    wchar_t wide[1024];
    const char *path = (dll && dll[0]) ? dll : "onnxruntime.dll";
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 1024) == 0) { fail(err, cap, "bad path", NULL); return 1; }
    if (!(dll && dll[0])) module = load_beside_or_on_path();
    if (!module) module = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    if (!module) module = LoadLibraryW(wide);
    if (!module) { snprintf(err, (size_t)cap, "cannot load %s (error %lu)", path, GetLastError()); return 1; }
    typedef const OrtApiBase *(ORT_API_CALL *GetBase)(void);
    GetBase base = (GetBase)GetProcAddress(module, "OrtGetApiBase");
#else
    module = (dll && dll[0]) ? dlopen(dll, RTLD_NOW | RTLD_LOCAL) : load_beside_or_named();
    if (!module) { const char *why = dlerror(); snprintf(err, (size_t)cap, "cannot load the ONNX Runtime library (%s)", why ? why : "not found"); return 1; }
    typedef const OrtApiBase *(ORT_API_CALL *GetBase)(void);
    GetBase base = (GetBase)dlsym(module, "OrtGetApiBase");
#endif
    if (!base) { fail(err, cap, "no OrtGetApiBase", NULL); return 1; }
    api = base()->GetApi(ORT_API_VERSION);
    if (!api) { fail(err, cap, "the runtime is older than the header", NULL); return 1; }
    OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "sq", &env);
    if (st) { fail(err, cap, "CreateEnv", st); api = NULL; return 1; }
    return 0;
}

int sqort_available(void) { return api != NULL; }

/* Builds the options and the session for one provider; 0 on success, the session in `s`. */
static int create_session(sqort_session *s, const char *model, int provider, int device, int threads, char *err, int cap) {
    OrtStatus *st = api->CreateSessionOptions(&s->options);
    if (st) { fail(err, cap, "CreateSessionOptions", st); return 1; }
    st = api->SetSessionGraphOptimizationLevel(s->options, ORT_ENABLE_ALL);
    if (st) { fail(err, cap, "graph optimization", st); return 1; }
    if (threads > 0 && (st = api->SetIntraOpNumThreads(s->options, threads))) { fail(err, cap, "threads", st); return 1; }
#ifdef _WIN32
    if (provider == SQORT_DIRECTML) {
        // DirectML wants sequential execution and no memory pattern.
        if ((st = api->DisableMemPattern(s->options))) { fail(err, cap, "memory pattern", st); return 1; }
        if ((st = api->SetSessionExecutionMode(s->options, ORT_SEQUENTIAL))) { fail(err, cap, "execution mode", st); return 1; }
        AppendDML append = (AppendDML)GetProcAddress(module, "OrtSessionOptionsAppendExecutionProvider_DML");
        if (!append) { fail(err, cap, "this onnxruntime has no DirectML provider", NULL); return 1; }
        st = append(s->options, device < 0 ? 0 : device);
        if (st) { fail(err, cap, "DirectML provider", st); return 1; }
    }
    wchar_t wide[2048];
    if (MultiByteToWideChar(CP_UTF8, 0, model, -1, wide, 2048) == 0) { fail(err, cap, "bad model path", NULL); return 1; }
    st = api->CreateSession(env, wide, s->options, &s->session);
#else
    (void)device;
    if (provider == SQORT_COREML) {
        // The generic provider call: the macOS build has CoreML compiled in; a build without it fails here and falls back.
        st = api->SessionOptionsAppendExecutionProvider(s->options, "CoreML", NULL, NULL, 0);
        if (st) { fail(err, cap, "CoreML provider", st); return 1; }
    }
    st = api->CreateSession(env, model, s->options, &s->session);
#endif
    if (st) { fail(err, cap, "CreateSession", st); return 1; }
    return 0;
}

static void release_partial(sqort_session *s) {
    if (s->session) { api->ReleaseSession(s->session); s->session = NULL; }
    if (s->options) { api->ReleaseSessionOptions(s->options); s->options = NULL; }
}

sqort_session *sqort_open(const char *model, int provider, int device, int threads, char *err, int cap) {
    if (!api) { fail(err, cap, "onnxruntime is not loaded", NULL); return NULL; }
    sqort_session *s = (sqort_session *)calloc(1, sizeof *s);
    s->provider = "cpu";
    OrtStatus *st = NULL;
    if (create_session(s, model, provider, device, threads, err, cap) != 0) {
        if (provider == SQORT_CPU) { free(s); return NULL; }
        // The accelerated provider did not take the model: the CPU always can. Say so in `fallback`.
        snprintf(s->fallback, sizeof s->fallback, "%s", err && cap > 0 ? err : "");
        release_partial(s);
        if (create_session(s, model, SQORT_CPU, device, threads, err, cap) != 0) { release_partial(s); free(s); return NULL; }
    } else {
        s->provider = provider == SQORT_DIRECTML ? "directml" : provider == SQORT_COREML ? "coreml" : "cpu";
    }
    st = api->GetAllocatorWithDefaultOptions(&s->allocator);
    if (st) { fail(err, cap, "allocator", st); sqort_close(s); return NULL; }
    st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->memory);
    if (st) { fail(err, cap, "memory info", st); sqort_close(s); return NULL; }
    size_t n = 0;
    if ((st = api->SessionGetInputCount(s->session, &n))) { fail(err, cap, "input count", st); sqort_close(s); return NULL; }
    s->nin = (int)n;
    if ((st = api->SessionGetOutputCount(s->session, &n))) { fail(err, cap, "output count", st); sqort_close(s); return NULL; }
    s->nout = (int)n;
    s->in_names = (char **)calloc((size_t)s->nin, sizeof(char *));
    s->out_names = (char **)calloc((size_t)s->nout, sizeof(char *));
    for (int i = 0; i < s->nin; i++) {
        char *name = NULL;
        if ((st = api->SessionGetInputName(s->session, (size_t)i, s->allocator, &name))) { fail(err, cap, "input name", st); sqort_close(s); return NULL; }
        s->in_names[i] = name;
    }
    for (int i = 0; i < s->nout; i++) {
        char *name = NULL;
        if ((st = api->SessionGetOutputName(s->session, (size_t)i, s->allocator, &name))) { fail(err, cap, "output name", st); sqort_close(s); return NULL; }
        s->out_names[i] = name;
    }
    return s;
}

void sqort_close(sqort_session *s) {
    if (!s) return;
    for (int i = 0; i < s->nin; i++) if (s->in_names && s->in_names[i]) drop(api->AllocatorFree(s->allocator, s->in_names[i]));
    for (int i = 0; i < s->nout; i++) if (s->out_names && s->out_names[i]) drop(api->AllocatorFree(s->allocator, s->out_names[i]));
    free(s->in_names); free(s->out_names);
    if (s->memory) api->ReleaseMemoryInfo(s->memory);
    if (s->session) api->ReleaseSession(s->session);
    if (s->options) api->ReleaseSessionOptions(s->options);
    free(s);
}

const char *sqort_provider(sqort_session *s) { return s ? s->provider : ""; }
const char *sqort_fallback_reason(sqort_session *s) { return s ? s->fallback : ""; }
int sqort_input_count(sqort_session *s) { return s ? s->nin : 0; }
int sqort_output_count(sqort_session *s) { return s ? s->nout : 0; }
const char *sqort_input_name(sqort_session *s, int i) { return (s && i >= 0 && i < s->nin) ? s->in_names[i] : NULL; }
const char *sqort_output_name(sqort_session *s, int i) { return (s && i >= 0 && i < s->nout) ? s->out_names[i] : NULL; }

int sqort_run(sqort_session *s, const float *const *in_data, const int64_t *const *in_shapes, const int *in_ranks,
              float **out_data, int64_t *out_counts, int *out_ranks, int64_t *out_dims, char *err, int cap) {
    if (!s) { fail(err, cap, "no session", NULL); return 1; }
    OrtValue **inputs = (OrtValue **)calloc((size_t)s->nin, sizeof(OrtValue *));
    OrtValue **outputs = (OrtValue **)calloc((size_t)s->nout, sizeof(OrtValue *));
    int rc = 0;
    OrtStatus *st = NULL;
    for (int i = 0; i < s->nin && !st; i++) {
        size_t count = 1;
        for (int d = 0; d < in_ranks[i]; d++) count *= (size_t)in_shapes[i][d];
        st = api->CreateTensorWithDataAsOrtValue(s->memory, (void *)in_data[i], count * sizeof(float), in_shapes[i],
                                                 (size_t)in_ranks[i], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[i]);
    }
    if (!st) st = api->Run(s->session, NULL, (const char *const *)s->in_names, (const OrtValue *const *)inputs,
                           (size_t)s->nin, (const char *const *)s->out_names, (size_t)s->nout, outputs);
    if (st) { fail(err, cap, "Run", st); rc = 1; }
    for (int i = 0; i < s->nout; i++) { out_data[i] = NULL; out_counts[i] = 0; }
    for (int i = 0; i < s->nout && rc == 0; i++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        size_t count = 0;
        ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
        float *data = NULL;
        if ((st = api->GetTensorTypeAndShape(outputs[i], &info))) { fail(err, cap, "output shape", st); rc = 1; break; }
        size_t rank = 0;
        st = api->GetTensorElementType(info, &type);
        if (!st) st = api->GetTensorShapeElementCount(info, &count);
        if (!st) st = api->GetDimensionsCount(info, &rank);
        if (rank > 8) rank = 8;
        out_ranks[i] = (int)rank;
        if (!st) st = api->GetDimensions(info, out_dims + i * 8, rank);
        api->ReleaseTensorTypeAndShapeInfo(info);
        if (st) { fail(err, cap, "output shape", st); rc = 1; break; }
        if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { fail(err, cap, "an output is not float32", NULL); rc = 1; break; }
        if ((st = api->GetTensorMutableData(outputs[i], (void **)&data))) { fail(err, cap, "output data", st); rc = 1; break; }
        out_data[i] = (float *)malloc(count * sizeof(float));
        memcpy(out_data[i], data, count * sizeof(float));
        out_counts[i] = (int64_t)count;
    }
    if (rc) for (int i = 0; i < s->nout; i++) { free(out_data[i]); out_data[i] = NULL; }
    for (int i = 0; i < s->nin; i++) if (inputs[i]) api->ReleaseValue(inputs[i]);
    for (int i = 0; i < s->nout; i++) if (outputs[i]) api->ReleaseValue(outputs[i]);
    free(inputs); free(outputs);
    return rc;
}

static size_t elem_size(int type) {
    switch (type) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return 4;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return 8;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: return 1;
    default: return 0;
    }
}

int sqort_run_typed(sqort_session *s, const int *in_types, const void *const *in_data, const int64_t *const *in_shapes,
                    const int *in_ranks, int n_want, const int *want, void **out_data, int *out_types, int64_t *out_counts,
                    int *out_ranks, int64_t *out_dims, char *err, int cap) {
    if (!s) { fail(err, cap, "no session", NULL); return 1; }
    static int64_t empty_buffer[2] = {0, 0};
    OrtValue **inputs = (OrtValue **)calloc((size_t)s->nin, sizeof(OrtValue *));
    OrtValue **outputs = (OrtValue **)calloc((size_t)n_want, sizeof(OrtValue *));
    const char **want_names = (const char **)calloc((size_t)(n_want > 0 ? n_want : 1), sizeof(char *));
    int rc = 0;
    OrtStatus *st = NULL;
    for (int i = 0; i < n_want; i++) want_names[i] = s->out_names[want[i]];
    for (int i = 0; i < s->nin && !st; i++) {
        size_t count = 1;
        for (int d = 0; d < in_ranks[i]; d++) count *= (size_t)in_shapes[i][d];
        size_t size = elem_size(in_types[i]);
        if (size == 0) { fail(err, cap, "unsupported input type", NULL); rc = 1; break; }
        void *data = count == 0 ? (void *)empty_buffer : (void *)in_data[i];
        st = api->CreateTensorWithDataAsOrtValue(s->memory, data, count * size, in_shapes[i], (size_t)in_ranks[i],
                                                 (ONNXTensorElementDataType)in_types[i], &inputs[i]);
    }
    if (!st && !rc) st = api->Run(s->session, NULL, (const char *const *)s->in_names, (const OrtValue *const *)inputs,
                                  (size_t)s->nin, want_names, (size_t)n_want, outputs);
    if (st) { fail(err, cap, "Run", st); rc = 1; }
    for (int i = 0; i < n_want; i++) { out_data[i] = NULL; out_counts[i] = 0; out_types[i] = 0; }
    for (int i = 0; i < n_want && rc == 0; i++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        size_t count = 0, rank = 0;
        ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
        void *data = NULL;
        if ((st = api->GetTensorTypeAndShape(outputs[i], &info))) { fail(err, cap, "output shape", st); rc = 1; break; }
        st = api->GetTensorElementType(info, &type);
        if (!st) st = api->GetTensorShapeElementCount(info, &count);
        if (!st) st = api->GetDimensionsCount(info, &rank);
        if (rank > 8) rank = 8;
        out_ranks[i] = (int)rank;
        if (!st) st = api->GetDimensions(info, out_dims + i * 8, rank);
        api->ReleaseTensorTypeAndShapeInfo(info);
        if (st) { fail(err, cap, "output shape", st); rc = 1; break; }
        size_t size = elem_size((int)type);
        if (size == 0) { fail(err, cap, "an output has an unsupported type", NULL); rc = 1; break; }
        if ((st = api->GetTensorMutableData(outputs[i], &data))) { fail(err, cap, "output data", st); rc = 1; break; }
        out_data[i] = malloc(count * size + 1);
        if (count > 0) memcpy(out_data[i], data, count * size);
        out_counts[i] = (int64_t)count;
        out_types[i] = (int)type;
    }
    if (rc) for (int i = 0; i < n_want; i++) { free(out_data[i]); out_data[i] = NULL; }
    for (int i = 0; i < s->nin; i++) if (inputs[i]) api->ReleaseValue(inputs[i]);
    for (int i = 0; i < n_want; i++) if (outputs[i]) api->ReleaseValue(outputs[i]);
    free(inputs); free(outputs); free(want_names);
    return rc;
}

void sqort_free(void *p) { free(p); }
