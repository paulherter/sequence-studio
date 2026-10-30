#include "csqonnx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "ort/onnxruntime_c_api.h"

typedef OrtStatus *(ORT_API_CALL *AppendDML)(OrtSessionOptions *, int);

struct sqort_session {
    OrtSession *session;
    OrtSessionOptions *options;
    OrtMemoryInfo *memory;
    OrtAllocator *allocator;
    int nin, nout;
    char **in_names, **out_names;
};

static const OrtApi *api = NULL;
static OrtEnv *env = NULL;
static HMODULE module = NULL;

static void fail(char *err, int cap, const char *what, OrtStatus *status) {
    if (!err || cap <= 0) { if (status) api->ReleaseStatus(status); return; }
    if (status) {
        snprintf(err, (size_t)cap, "%s: %s", what, api->GetErrorMessage(status));
        api->ReleaseStatus(status);
    } else {
        snprintf(err, (size_t)cap, "%s", what);
    }
}

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

int sqort_load(const char *dll, char *err, int cap) {
    if (api) return 0;
    wchar_t wide[1024];
    const char *path = (dll && dll[0]) ? dll : "onnxruntime.dll";
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 1024) == 0) { fail(err, cap, "bad path", NULL); return 1; }
    if (!(dll && dll[0])) module = load_beside_or_on_path();
    if (!module) module = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    if (!module) module = LoadLibraryW(wide);
    if (!module) { snprintf(err, (size_t)cap, "cannot load %s (error %lu)", path, GetLastError()); return 1; }
    typedef const OrtApiBase *(ORT_API_CALL *GetBase)(void);
    GetBase base = (GetBase)GetProcAddress(module, "OrtGetApiBase");
    if (!base) { fail(err, cap, "no OrtGetApiBase", NULL); return 1; }
    api = base()->GetApi(ORT_API_VERSION);
    if (!api) { fail(err, cap, "the runtime is older than the header", NULL); return 1; }
    OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "sq", &env);
    if (st) { fail(err, cap, "CreateEnv", st); api = NULL; return 1; }
    return 0;
}

int sqort_available(void) { return api != NULL; }

sqort_session *sqort_open(const char *model, int dml, int device, int threads, char *err, int cap) {
    if (!api) { fail(err, cap, "onnxruntime is not loaded", NULL); return NULL; }
    sqort_session *s = (sqort_session *)calloc(1, sizeof *s);
    OrtStatus *st = api->CreateSessionOptions(&s->options);
    if (st) { fail(err, cap, "CreateSessionOptions", st); free(s); return NULL; }
    api->SetSessionGraphOptimizationLevel(s->options, ORT_ENABLE_ALL);
    if (threads > 0) api->SetIntraOpNumThreads(s->options, threads);
    if (dml) {
        // DirectML wants sequential execution and no memory pattern.
        api->DisableMemPattern(s->options);
        api->SetSessionExecutionMode(s->options, ORT_SEQUENTIAL);
        AppendDML append = (AppendDML)GetProcAddress(module, "OrtSessionOptionsAppendExecutionProvider_DML");
        if (!append) { fail(err, cap, "this onnxruntime has no DirectML provider", NULL); sqort_close(s); return NULL; }
        st = append(s->options, device < 0 ? 0 : device);
        if (st) { fail(err, cap, "DirectML provider", st); sqort_close(s); return NULL; }
    }
    wchar_t wide[2048];
    if (MultiByteToWideChar(CP_UTF8, 0, model, -1, wide, 2048) == 0) { fail(err, cap, "bad model path", NULL); sqort_close(s); return NULL; }
    st = api->CreateSession(env, wide, s->options, &s->session);
    if (st) { fail(err, cap, "CreateSession", st); sqort_close(s); return NULL; }
    st = api->GetAllocatorWithDefaultOptions(&s->allocator);
    if (st) { fail(err, cap, "allocator", st); sqort_close(s); return NULL; }
    st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->memory);
    if (st) { fail(err, cap, "memory info", st); sqort_close(s); return NULL; }
    size_t n = 0;
    api->SessionGetInputCount(s->session, &n); s->nin = (int)n;
    api->SessionGetOutputCount(s->session, &n); s->nout = (int)n;
    s->in_names = (char **)calloc((size_t)s->nin, sizeof(char *));
    s->out_names = (char **)calloc((size_t)s->nout, sizeof(char *));
    for (int i = 0; i < s->nin; i++) {
        char *name = NULL;
        api->SessionGetInputName(s->session, (size_t)i, s->allocator, &name);
        s->in_names[i] = name;
    }
    for (int i = 0; i < s->nout; i++) {
        char *name = NULL;
        api->SessionGetOutputName(s->session, (size_t)i, s->allocator, &name);
        s->out_names[i] = name;
    }
    return s;
}

void sqort_close(sqort_session *s) {
    if (!s) return;
    for (int i = 0; i < s->nin; i++) if (s->in_names && s->in_names[i]) api->AllocatorFree(s->allocator, s->in_names[i]);
    for (int i = 0; i < s->nout; i++) if (s->out_names && s->out_names[i]) api->AllocatorFree(s->allocator, s->out_names[i]);
    free(s->in_names); free(s->out_names);
    if (s->memory) api->ReleaseMemoryInfo(s->memory);
    if (s->session) api->ReleaseSession(s->session);
    if (s->options) api->ReleaseSessionOptions(s->options);
    free(s);
}

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
        api->GetTensorElementType(info, &type);
        api->GetTensorShapeElementCount(info, &count);
        size_t rank = 0;
        api->GetDimensionsCount(info, &rank);
        if (rank > 8) rank = 8;
        out_ranks[i] = (int)rank;
        api->GetDimensions(info, out_dims + i * 8, rank);
        api->ReleaseTensorTypeAndShapeInfo(info);
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

void sqort_free(void *p) { free(p); }

#else
// Off Windows there is no ONNX Runtime backend (the Mac uses Core ML): everything reports unavailable.
int sqort_load(const char *dll, char *err, int cap) { (void)dll; if (err && cap > 0) snprintf(err, (size_t)cap, "ONNX Runtime is Windows only"); return 1; }
int sqort_available(void) { return 0; }
sqort_session *sqort_open(const char *m, int d, int dev, int t, char *err, int cap) { (void)m; (void)d; (void)dev; (void)t; if (err && cap > 0) snprintf(err, (size_t)cap, "ONNX Runtime is Windows only"); return NULL; }
void sqort_close(sqort_session *s) { (void)s; }
int sqort_input_count(sqort_session *s) { (void)s; return 0; }
int sqort_output_count(sqort_session *s) { (void)s; return 0; }
const char *sqort_input_name(sqort_session *s, int i) { (void)s; (void)i; return NULL; }
const char *sqort_output_name(sqort_session *s, int i) { (void)s; (void)i; return NULL; }
int sqort_run(sqort_session *s, const float *const *a, const int64_t *const *b, const int *c, float **d, int64_t *e, int *f, int64_t *g, char *err, int cap) {
    (void)s; (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; if (err && cap > 0) snprintf(err, (size_t)cap, "ONNX Runtime is Windows only"); return 1; }
void sqort_free(void *p) { free(p); }
#endif
