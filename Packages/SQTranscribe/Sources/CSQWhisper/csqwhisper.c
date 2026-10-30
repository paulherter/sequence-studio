#include "csqwhisper.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* The parts of whisper.h (MIT, ggml-org/whisper.cpp, tag b5454 = d1be6fde) this file touches. Both params structs are
   copied whole: whisper_init_from_file_with_params and whisper_full take them by value, so the size must be the DLL's. */
struct whisper_context;
struct whisper_state;
typedef int32_t whisper_token;
typedef bool (*ggml_abort_callback)(void *data);
typedef void (*whisper_new_segment_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef void (*whisper_progress_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef bool (*whisper_encoder_begin_callback)(struct whisper_context *, struct whisper_state *, void *);
typedef void (*whisper_logits_filter_callback)(struct whisper_context *, struct whisper_state *, const void *, int, float *, void *);

typedef struct { int n_text_layer; int n_head; } whisper_ahead;
typedef struct { size_t n_heads; const whisper_ahead *heads; } whisper_aheads;
struct whisper_context_params {
    bool use_gpu;
    bool flash_attn;
    int gpu_device;
    bool dtw_token_timestamps;
    int dtw_aheads_preset;     /* enum whisper_alignment_heads_preset */
    int dtw_n_top;
    whisper_aheads dtw_aheads;
    size_t dtw_mem_size;
};

struct whisper_full_params {
    int strategy;
    int n_threads;
    int n_max_text_ctx;
    int offset_ms;
    int duration_ms;
    bool translate;
    bool no_context;
    bool no_timestamps;
    bool single_segment;
    bool print_special;
    bool print_progress;
    bool print_realtime;
    bool print_timestamps;
    bool token_timestamps;
    float thold_pt;
    float thold_ptsum;
    int max_len;
    bool split_on_word;
    int max_tokens;
    bool debug_mode;
    int audio_ctx;
    bool tdrz_enable;
    const char *suppress_regex;
    const char *initial_prompt;
    bool carry_initial_prompt;
    const whisper_token *prompt_tokens;
    int prompt_n_tokens;
    const char *language;
    bool detect_language;
    bool suppress_blank;
    bool suppress_nst;
    float temperature;
    float max_initial_ts;
    float length_penalty;
    float temperature_inc;
    float entropy_thold;
    float logprob_thold;
    float no_speech_thold;
    struct { int best_of; } greedy;
    struct { int beam_size; float patience; } beam_search;
    whisper_new_segment_callback new_segment_callback;
    void *new_segment_callback_user_data;
    whisper_progress_callback progress_callback;
    void *progress_callback_user_data;
    whisper_encoder_begin_callback encoder_begin_callback;
    void *encoder_begin_callback_user_data;
    ggml_abort_callback abort_callback;
    void *abort_callback_user_data;
    whisper_logits_filter_callback logits_filter_callback;
    void *logits_filter_callback_user_data;
    const void **grammar_rules;
    size_t n_grammar_rules;
    size_t i_start_rule;
    float grammar_penalty;
    bool vad;
    const char *vad_model_path;
    struct { float threshold; int min_speech_duration_ms; int min_silence_duration_ms; float max_speech_duration_s;
             int speech_pad_ms; float samples_overlap; } vad_params;
};

typedef struct whisper_context *(*FnInit)(const char *, struct whisper_context_params);
typedef struct whisper_context_params *(*FnCtxParams)(void);
typedef struct whisper_full_params *(*FnFullParams)(int);
typedef void (*FnFree)(struct whisper_context *);
typedef void (*FnFreeParams)(void *);
typedef int (*FnFull)(struct whisper_context *, struct whisper_full_params, const float *, int);
typedef int (*FnCount)(struct whisper_context *);
typedef int (*FnCount2)(struct whisper_context *, int);
typedef const char *(*FnText)(struct whisper_context *, int, int);
typedef int64_t (*FnT)(struct whisper_context *, int, int);
typedef float (*FnP)(struct whisper_context *, int, int);
typedef whisper_token (*FnTokenId)(struct whisper_context *, int, int);
typedef whisper_token (*FnEot)(struct whisper_context *);

static HMODULE module = NULL;
static FnInit f_init; static FnCtxParams f_ctx_params; static FnFullParams f_full_params; static FnFree f_free;
static FnFreeParams f_free_params, f_free_ctx_params; static FnFull f_full; static FnCount f_nseg; static FnCount2 f_ntok;
static FnText f_text; static FnT f_t0, f_t1; static FnP f_p; static FnTokenId f_id; static FnEot f_eot;

struct sqwh_context {
    struct whisper_context *ctx;
    int count;
    int *seg, *tok;
    whisper_token eot;
    sqwh_progress_fn progress; sqwh_cancel_fn cancelled; void *user;
    int canceled;
};

static void say(char *err, int cap, const char *text, const char *detail) {
    if (err && cap > 0) snprintf(err, (size_t)cap, "%s%s", text, detail ? detail : "");
}

static char module_dir[1024];

static HMODULE try_dir(const wchar_t *dir) {
    wchar_t candidate[1536];
    swprintf(candidate, 1536, L"%ls\\whisper.dll", dir);
    if (GetFileAttributesW(candidate) == INVALID_FILE_ATTRIBUTES) return NULL;
    /* the ggml DLLs sit beside whisper.dll: search that folder for dependents */
    HMODULE m = LoadLibraryExW(candidate, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (m) WideCharToMultiByte(CP_UTF8, 0, dir, -1, module_dir, (int)sizeof module_dir, NULL, NULL);
    return m;
}

static HMODULE find_module(const char *dir) {
    wchar_t wide[1024];
    if (dir && dir[0] && MultiByteToWideChar(CP_UTF8, 0, dir, -1, wide, 1024) > 0) return try_dir(wide);
    wchar_t exe[1024];
    DWORD n = GetModuleFileNameW(NULL, exe, 1024);
    if (n > 0 && n < 1024) {
        wchar_t *slash = wcsrchr(exe, L'\\');
        if (slash) { *slash = 0; HMODULE m = try_dir(exe); if (m) return m; }
    }
    wchar_t env[1024];
    DWORD e = GetEnvironmentVariableW(L"SQ_WHISPER_DIR", env, 1024);
    if (e > 0 && e < 1024) { HMODULE m = try_dir(env); if (m) return m; }
    DWORD need = GetEnvironmentVariableW(L"PATH", NULL, 0);
    if (need == 0) return NULL;
    wchar_t *path = (wchar_t *)malloc(need * sizeof(wchar_t));
    if (!path) return NULL;
    GetEnvironmentVariableW(L"PATH", path, need);
    HMODULE found = NULL;
    wchar_t *ctx = NULL;
    for (wchar_t *d = wcstok(path, L";", &ctx); d && !found; d = wcstok(NULL, L";", &ctx)) found = try_dir(d);
    free(path);
    return found;
}

#define BIND(var, type, name) do { var = (type)GetProcAddress(module, name); if (!var) { say(err, cap, "whisper.dll has no ", name); module = NULL; return 1; } } while (0)

int sqwh_load(const char *dir, char *err, int cap) {
    if (module && f_full) return 0;
    module = find_module(dir);
    if (!module) { say(err, cap, "whisper.dll not found", NULL); return 1; }
    BIND(f_init, FnInit, "whisper_init_from_file_with_params");
    BIND(f_ctx_params, FnCtxParams, "whisper_context_default_params_by_ref");
    BIND(f_full_params, FnFullParams, "whisper_full_default_params_by_ref");
    BIND(f_free, FnFree, "whisper_free");
    BIND(f_free_params, FnFreeParams, "whisper_free_params");
    BIND(f_free_ctx_params, FnFreeParams, "whisper_free_context_params");
    BIND(f_full, FnFull, "whisper_full");
    BIND(f_nseg, FnCount, "whisper_full_n_segments");
    BIND(f_ntok, FnCount2, "whisper_full_n_tokens");
    BIND(f_text, FnText, "whisper_full_get_token_text");
    BIND(f_t0, FnT, "whisper_full_get_token_t0");
    BIND(f_t1, FnT, "whisper_full_get_token_t1");
    BIND(f_p, FnP, "whisper_full_get_token_p");
    BIND(f_id, FnTokenId, "whisper_full_get_token_id");
    BIND(f_eot, FnEot, "whisper_token_eot");
    /* This build keeps the CPU backends in their own DLLs (ggml-cpu-*.dll, picked by the processor): they must be loaded
       from the folder before the first model opens, else ggml finds no device and aborts. */
    HMODULE ggml = GetModuleHandleW(L"ggml.dll");
    typedef void (*FnLoadAll)(const char *);
    FnLoadAll load_all = ggml ? (FnLoadAll)GetProcAddress(ggml, "ggml_backend_load_all_from_path") : NULL;
    if (!load_all) { say(err, cap, "ggml.dll has no ", "ggml_backend_load_all_from_path"); module = NULL; return 1; }
    load_all(module_dir);
    return 0;
}

int sqwh_available(void) { return module && f_full ? 1 : 0; }

sqwh_context *sqwh_open(const char *model, int threads, char *err, int cap) {
    (void)threads;
    if (!sqwh_available()) { say(err, cap, "whisper.dll is not loaded", NULL); return NULL; }
    wchar_t wide[1024];
    if (MultiByteToWideChar(CP_UTF8, 0, model, -1, wide, 1024) == 0) { say(err, cap, "bad model path", NULL); return NULL; }
    /* whisper.cpp opens the path with fopen: hand it the short (8.3) form when the long one has characters the ANSI page lacks */
    char ansi[1024];
    BOOL lost = FALSE;
    WideCharToMultiByte(CP_ACP, 0, wide, -1, ansi, 1024, NULL, &lost);
    if (lost) {
        wchar_t shortw[1024];
        DWORD n = GetShortPathNameW(wide, shortw, 1024);
        if (n > 0 && n < 1024) WideCharToMultiByte(CP_ACP, 0, shortw, -1, ansi, 1024, NULL, NULL);
    }
    struct whisper_context_params *p = f_ctx_params();
    if (!p) { say(err, cap, "no memory", NULL); return NULL; }
    p->use_gpu = false;
    struct whisper_context *ctx = f_init(ansi, *p);
    f_free_ctx_params(p);
    if (!ctx) { say(err, cap, "cannot load the model ", model); return NULL; }
    sqwh_context *c = (sqwh_context *)calloc(1, sizeof(sqwh_context));
    if (!c) return NULL;
    c->ctx = ctx;
    c->eot = f_eot(ctx);
    return c;
}

void sqwh_close(sqwh_context *c) {
    if (!c) return;
    if (c->ctx && f_free) f_free(c->ctx);
    free(c->seg); free(c->tok); free(c);
}

static bool on_begin(struct whisper_context *ctx, struct whisper_state *st, void *user) {
    (void)ctx; (void)st;
    sqwh_context *c = (sqwh_context *)user;
    if (c->cancelled && c->cancelled(c->user)) { c->canceled = 1; return false; }
    return true;
}
static bool on_abort(void *user) {
    sqwh_context *c = (sqwh_context *)user;
    if (c->cancelled && c->cancelled(c->user)) { c->canceled = 1; return true; }
    return false;
}
static void on_progress(struct whisper_context *ctx, struct whisper_state *st, int percent, void *user) {
    (void)ctx; (void)st;
    sqwh_context *c = (sqwh_context *)user;
    if (c->progress) c->progress(percent, c->user);
}

int sqwh_run(sqwh_context *c, const float *samples, int count, const char *language, int threads,
             sqwh_progress_fn progress, sqwh_cancel_fn cancelled, void *user, char *err, int cap) {
    if (!c || !c->ctx) return 1;
    free(c->seg); free(c->tok); c->seg = NULL; c->tok = NULL; c->count = 0; c->canceled = 0;
    c->progress = progress; c->cancelled = cancelled; c->user = user;
    struct whisper_full_params *p = f_full_params(0 /* greedy */);
    if (!p) { say(err, cap, "no memory", NULL); return 1; }
    p->n_threads = threads > 0 ? threads : 4;
    p->language = language;
    p->translate = false;
    p->print_progress = false; p->print_realtime = false; p->print_special = false; p->print_timestamps = false;
    p->token_timestamps = true;
    p->suppress_nst = true;
    p->progress_callback = on_progress; p->progress_callback_user_data = c;
    p->encoder_begin_callback = on_begin; p->encoder_begin_callback_user_data = c;
    p->abort_callback = on_abort; p->abort_callback_user_data = c;
    int r = f_full(c->ctx, *p, samples, count);
    f_free_params(p);
    if (c->canceled) return 2;
    if (r != 0) { char code[32]; snprintf(code, sizeof code, "%d", r); say(err, cap, "recognition failed, code ", code); return 1; }
    int segs = f_nseg(c->ctx), total = 0;
    for (int s = 0; s < segs; s++) total += f_ntok(c->ctx, s);
    c->seg = (int *)malloc(sizeof(int) * (size_t)(total > 0 ? total : 1));
    c->tok = (int *)malloc(sizeof(int) * (size_t)(total > 0 ? total : 1));
    if (!c->seg || !c->tok) return 1;
    int i = 0;
    for (int s = 0; s < segs; s++) {
        int n = f_ntok(c->ctx, s);
        for (int t = 0; t < n; t++, i++) { c->seg[i] = s; c->tok[i] = t; }
    }
    c->count = total;
    return 0;
}

int sqwh_token_count(sqwh_context *c) { return c ? c->count : 0; }

const char *sqwh_token_text(sqwh_context *c, int i, int *special) {
    if (!c || i < 0 || i >= c->count) { if (special) *special = 1; return ""; }
    if (special) *special = f_id(c->ctx, c->seg[i], c->tok[i]) >= c->eot ? 1 : 0;
    const char *t = f_text(c->ctx, c->seg[i], c->tok[i]);
    return t ? t : "";
}

void sqwh_token_info(sqwh_context *c, int i, int64_t *t0, int64_t *t1, float *p) {
    if (!c || i < 0 || i >= c->count) { *t0 = 0; *t1 = 0; *p = 0; return; }
    *t0 = f_t0(c->ctx, c->seg[i], c->tok[i]);
    *t1 = f_t1(c->ctx, c->seg[i], c->tok[i]);
    *p = f_p(c->ctx, c->seg[i], c->tok[i]);
}

#else /* not Windows: no engine */

int sqwh_load(const char *dir, char *err, int cap) {
    (void)dir;
    if (err && cap > 0) snprintf(err, (size_t)cap, "whisper.dll exists on Windows only");
    return 1;
}
int sqwh_available(void) { return 0; }
sqwh_context *sqwh_open(const char *model, int threads, char *err, int cap) {
    (void)model; (void)threads;
    if (err && cap > 0) snprintf(err, (size_t)cap, "not available");
    return NULL;
}
void sqwh_close(sqwh_context *c) { (void)c; }
int sqwh_run(sqwh_context *c, const float *samples, int count, const char *language, int threads,
             sqwh_progress_fn progress, sqwh_cancel_fn cancelled, void *user, char *err, int cap) {
    (void)c; (void)samples; (void)count; (void)language; (void)threads; (void)progress; (void)cancelled; (void)user;
    if (err && cap > 0) snprintf(err, (size_t)cap, "not available");
    return 1;
}
int sqwh_token_count(sqwh_context *c) { (void)c; return 0; }
const char *sqwh_token_text(sqwh_context *c, int i, int *special) { (void)c; (void)i; if (special) *special = 1; return ""; }
void sqwh_token_info(sqwh_context *c, int i, int64_t *t0, int64_t *t1, float *p) { (void)c; (void)i; *t0 = 0; *t1 = 0; *p = 0; }

#endif
