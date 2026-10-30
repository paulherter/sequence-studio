#ifndef CSQONNX_H
#define CSQONNX_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A thin C face over ONNX Runtime (MIT, Microsoft), loaded at run time from onnxruntime.dll: nothing links against it,
// so the app starts without the DLL and reports "unavailable" when it is missing (the Windows port plan, Magic Mask).
// Every call that can fail returns 0 on success and writes a short message into `err` (capacity `cap`).

typedef struct sqort_session sqort_session;

// Loads onnxruntime.dll from `dll` (a full path; NULL or "" = the name, found next to the exe or on PATH).
int sqort_load(const char *dll, char *err, int cap);
// 1 when a loaded runtime exists.
int sqort_available(void);

// Opens a model file. `dml` != 0 asks for the DirectML provider on adapter `device` (-1 = the default adapter);
// the CPU provider serves everything DirectML does not take. `threads` 0 = ORT's default.
sqort_session *sqort_open(const char *model, int dml, int device, int threads, char *err, int cap);
void sqort_close(sqort_session *s);

// Names and counts of the model's inputs and outputs (valid until `sqort_close`).
int sqort_input_count(sqort_session *s);
int sqort_output_count(sqort_session *s);
const char *sqort_input_name(sqort_session *s, int i);
const char *sqort_output_name(sqort_session *s, int i);

// One inference with float32 tensors. `in_data[i]` points at the input `i` (in the model's input order), shaped
// `in_shapes[i]` (rank `in_ranks[i]`). `out_data[i]` receives a malloc'd float32 copy of output `i` (free with
// `sqort_free`), `out_counts[i]` its element count, `out_ranks[i]` its rank (at most 8) and `out_dims[i * 8 ...]` its shape.
int sqort_run(sqort_session *s, const float *const *in_data, const int64_t *const *in_shapes, const int *in_ranks,
              float **out_data, int64_t *out_counts, int *out_ranks, int64_t *out_dims, char *err, int cap);
void sqort_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
