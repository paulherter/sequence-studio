#ifndef CSQGPUD3D12_H
#define CSQGPUD3D12_H
// C face of the D3D12 compute and draw backend (implementation: d3d12.cpp, Windows only). Binding layout = GPUBinding in SQGPU:
// inputs t0...t23, 3D table t24, output u0, data buffers u2...u4, constant blocks b0 and b1, static samplers s0 (linear, transparent-black border), s1
// (linear, clamp to edge) and s2 (nearest, clamp to edge). Dispatches are 16 x 16 thread groups, like the [numthreads] of every Slang kernel.
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct SQD3D SQD3D;
typedef struct SQD3DTex SQD3DTex;
typedef struct SQD3DList SQD3DList;
typedef struct SQD3DReadback SQD3DReadback;

/// Hardware adapter (high-performance first). NULL and err filled on failure. SQ_D3D12_DEBUG=1 enables the debug layer.
SQD3D *sqd3d_create(char *err, int errLen);
void sqd3d_destroy(SQD3D *g);
const char *sqd3d_name(const SQD3D *g);

/// Compiles one compute entry of Slang-generated HLSL (cs_5_0). Returns the pipeline index, -1 with err on failure.
int sqd3d_pipeline(SQD3D *g, const char *hlsl, const char *entry, char *err, int errLen);

/// A draw pipeline: vertex and pixel entry (vs_5_0, ps_5_0) writing `format` targets; blend 0 replace, 1 premultiplied
/// over, 2 additive. Returns the pipeline index (set with sqd3d_set_pipeline), -1 with err on failure.
int sqd3d_render_pipeline(SQD3D *g, const char *vsHlsl, const char *vsEntry, const char *psHlsl, const char *psEntry,
                          int format, int blend, char *err, int errLen);

/// format: 0 rgba16Float, 1 rgba32Float, 2 rgba8Unorm, 3 r32Float, 4 rg32Float. Reference counted: the creator owns one reference.
SQD3DTex *sqd3d_texture(SQD3D *g, int width, int height, int format);
void sqd3d_texture_release(SQD3DTex *t);
/// Read-only 3D table (filled with sqd3d_upload: rows of bytesPerRow, slices one after another); bind at input slot 24.
SQD3DTex *sqd3d_texture3d(SQD3D *g, int width, int height, int depth, int format);
/// Read-write data buffer of 4-byte elements (released with sqd3d_texture_release; upload/download move all bytes).
SQD3DTex *sqd3d_buffer(SQD3D *g, int length);

/// One command list in flight per device (NULL while another is open). Bindings stay until changed.
SQD3DList *sqd3d_begin(SQD3D *g);
void sqd3d_set_pipeline(SQD3DList *l, int pipeline);
void sqd3d_set_input(SQD3DList *l, int slot, SQD3DTex *t);
void sqd3d_set_output(SQD3DList *l, SQD3DTex *t);
/// slot 2...4.
void sqd3d_set_buffer(SQD3DList *l, int slot, SQD3DTex *t);
void sqd3d_set_constants(SQD3DList *l, int slot, const void *bytes, int length);
void sqd3d_dispatch(SQD3DList *l, int width, int height);
int sqd3d_copy(SQD3DList *l, SQD3DTex *src, SQD3DTex *dst);
/// Following draws write `target` (a 2D texture); clear != 0 clears it to rgba first. Viewport and scissor = the whole target.
void sqd3d_begin_render(SQD3DList *l, SQD3DTex *target, int clear, const float *rgba);
void sqd3d_set_viewport(SQD3DList *l, float x, float y, float width, float height);
void sqd3d_set_scissor(SQD3DList *l, int x, int y, int width, int height);
/// Inputs, buffers and constants as for a dispatch; strip != 0: triangle strip, else a triangle list.
void sqd3d_draw(SQD3DList *l, int vertexCount, int strip);
/// Executes, waits for the GPU and frees the list. 0 when every recorded command fit (descriptor and constant budget).
int sqd3d_commit_wait(SQD3DList *l);
/// Executes without waiting (up to three lists in flight; the next sqd3d_begin waits only for the list that last used
/// its slot) and frees the list. Textures it uses stay alive until the GPU finished it. Same result as commit_wait.
int sqd3d_commit(SQD3DList *l);
/// The most lists that were submitted and not finished at one time (statistics).
int sqd3d_in_flight_max(const SQD3D *g);
/// Records a readback of a 2D texture into the open list; finish maps it once that list ran (waits only for it) and
/// frees the ticket. NULL when no list is open. A ticket must be finished (its staging buffer goes back to the pool).
SQD3DReadback *sqd3d_readback(SQD3DList *l, SQD3DTex *t);
int sqd3d_readback_finish(SQD3DReadback *r, void *out, int bytesPerRow);

/// Whole-texture transfers, rows of bytesPerRow on the CPU side. Upload runs at once, or joins the open list (it then
/// lands when that list runs); download needs no open list.
int sqd3d_upload(SQD3D *g, SQD3DTex *t, const void *bytes, int bytesPerRow);
int sqd3d_download(SQD3D *g, SQD3DTex *t, void *out, int bytesPerRow);

/// The device's ID3D12Device and its direct ID3D12CommandQueue, for a renderer that shares them (the app window's swap
/// chain): work it submits on that queue runs in order with this device's command lists.
void *sqd3d_native_device(SQD3D *g);
void *sqd3d_native_queue(SQD3D *g);
/// The texture's ID3D12Resource, moved into the shader resource state (pixel and non-pixel) so another renderer on the same
/// queue can sample it without barriers. Joins the open list (lands when it runs), else runs at once. The next command
/// list that writes the texture moves it out again (the state stays tracked here).
void *sqd3d_texture_for_sampling(SQD3D *g, SQD3DTex *t);

#ifdef __cplusplus
}
#endif
#endif
