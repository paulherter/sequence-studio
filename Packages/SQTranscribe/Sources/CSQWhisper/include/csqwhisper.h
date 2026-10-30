#ifndef CSQWHISPER_H
#define CSQWHISPER_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A thin C face over whisper.cpp (MIT, ggml-org), loaded at run time from whisper.dll: nothing links against it, so the app
// starts without the DLL and says "speech engine not available" when it is missing. The structs are copied from the pinned
// whisper.h (docs/THIRD_PARTY.md), so the DLL must come from that release (scripts/win-whisper-setup.sh). Off Windows every
// call fails ("not available").

typedef struct sqwh_context sqwh_context;

// Loads whisper.dll: `dir` (a folder, NULL = the folder of the exe, then SQ_WHISPER_DIR, then PATH). 0 on success, else a
// short message in `err`.
int sqwh_load(const char *dir, char *err, int cap);
int sqwh_available(void);

// Opens a ggml model file (CPU). NULL on failure with a message.
sqwh_context *sqwh_open(const char *model, int threads, char *err, int cap);
void sqwh_close(sqwh_context *c);

// Runs recognition over 16 kHz mono floats with word-level tokens (one token per segment text piece, timestamps on).
// `language` is a Whisper code. `progress` gets 0...100, `cancelled` is polled; both may be NULL. 0 on success, 2 when canceled.
typedef void (*sqwh_progress_fn)(int percent, void *user);
typedef int (*sqwh_cancel_fn)(void *user);
int sqwh_run(sqwh_context *c, const float *samples, int count, const char *language, int threads,
             sqwh_progress_fn progress, sqwh_cancel_fn cancelled, void *user, char *err, int cap);

// The tokens of the last run, flattened over all segments.
int sqwh_token_count(sqwh_context *c);
// Raw UTF-8 bytes of token `i` (NUL terminated, valid until the next run or close); `special` = 1 for control tokens.
const char *sqwh_token_text(sqwh_context *c, int i, int *special);
// Start and end in centiseconds, and the probability.
void sqwh_token_info(sqwh_context *c, int i, int64_t *t0, int64_t *t1, float *p);

#ifdef __cplusplus
}
#endif
#endif
