#ifndef CSQWIN_H
#define CSQWIN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct SQGpu SQGpu;

// D3D12 device + swap chain on an existing window. Returns NULL and fills err on failure.
SQGpu *sq_gpu_create(void *hwnd, int width, int height, char *err, int errLen);
const char *sq_gpu_adapter_name(const SQGpu *g);
int sq_gpu_resize(SQGpu *g, int width, int height);
// Uploads an RGBA8 frame to a texture; drawn letterboxed on the next render.
int sq_gpu_set_frame_rgba(SQGpu *g, const uint8_t *rgba, int width, int height);
// Clears to (r,g,b), draws the frame if any, presents. pngPath (may be NULL) gets a copy of the back buffer.
int sq_gpu_render(SQGpu *g, float r, float gr, float b, const char *pngPath);
// Replaces the video pixel shader with the Slang-generated HLSL (Shaders/Grade.vs.hlsl / Grade.ps.hlsl).
int sq_gpu_set_grade(SQGpu *g, const char *vsPath, const char *psPath, float exposure, float saturation, float vignette, char *err, int errLen);

// Shared draw list, already flattened to rectangles (pixels, y down, colors 0...1). Drawn over the frame each render.
typedef struct { float x, y, w, h, r, g, b, a; } SQRect;
int sq_gpu_set_rects(SQGpu *g, const SQRect *rects, int count);
void sq_gpu_destroy(SQGpu *g);

typedef struct {
    uint8_t *rgba;
    int width, height;
    double openMs, firstFrameMs, convertMs;
    char decoder[96];
} SQDecoded;

// Decodes the first video frame. hardware != 0 tries d3d11va first and falls back to software.
int sq_decode_first_frame(const char *path, int hardware, SQDecoded *out, char *err, int errLen);
void sq_decoded_free(SQDecoded *d);

#ifdef __cplusplus
}
#endif
#endif
