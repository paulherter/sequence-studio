// The D3D12 side of SQWinApp: one quad pipeline that draws a SQDrawKit DrawList (shapes, glyphs, triangles and the
// NV12 picture) into a flip-model swap chain or an offscreen target. The per-pixel math mirrors
// SQDrawKit.SoftwareRenderer, so the Mac comparison renders the same list on the CPU.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SQUi SQUi;

/// `hwnd` NULL renders offscreen (headless tests); `render` then only fills `rgbaOut`. `vsHlsl` / `psHlsl`: the
/// generated HLSL of DrawQuads.slang's `quadVertex` and `quadFragment` (SQGPUKernels `GeneratedShaders.drawQuads`).
SQUi *sq_ui_create(void *hwnd, int width, int height, const char *vsHlsl, const char *psHlsl, char *err, int errLen);
/// The same on another renderer's ID3D12Device and direct queue (SQGPUD3D12's device): the Program picture then stays
/// on the GPU (`sq_ui_set_video_texture`) and both renderers' work runs in queue order.
SQUi *sq_ui_create_shared(void *device, void *queue, const char *adapterName, void *hwnd, int width, int height,
                          const char *vsHlsl, const char *psHlsl, char *err, int errLen);
const char *sq_ui_adapter(const SQUi *g);
int sq_ui_resize(SQUi *g, int width, int height);
/// The R8 glyph atlas (size x size); call again when its generation changes.
int sq_ui_set_atlas(SQUi *g, const uint8_t *r8, int size);
/// One NV12 picture: `w * h` luma bytes, then `w * h / 2` interleaved chroma bytes (stride = width). NULL clears it.
int sq_ui_set_video_nv12(SQUi *g, const uint8_t *bytes, int w, int h, int fullRange);
/// The composited Program picture: RGBA8 display code values (rows top down, stride = w * 4). NULL clears it.
int sq_ui_set_video_rgba(SQUi *g, const uint8_t *rgba, int w, int h);
/// The composited Program picture as an ID3D12Resource of the shared device (RGBA display code values), already in a
/// shader resource state; the renderer keeps a reference. NULL clears it. Only with `sq_ui_create_shared`.
int sq_ui_set_video_texture(SQUi *g, void *resource);
/// View Gamma of the picture quads: the sampled code values are raised to `exponent` (gamma / 2.2; 1 = unchanged).
int sq_ui_set_view_gamma(SQUi *g, float exponent);
/// Target pixels per frame pixel (DrawQuads.slang `viewScale`): 1 draws the quads as given, below 1 shows a larger frame
/// reduced and supersampled (a floating window on a display with a smaller scale). The quads' coordinates stay frame pixels.
int sq_ui_set_view_scale(SQUi *g, float scale);
/// RGBA8 (straight alpha, rows top down, stride = w * 4) of image slot 0...5, drawn by image quads (SQDrawKit
/// `DrawList.image`): scopes, thumbnails, meters' bitmaps.
int sq_ui_set_image(SQUi *g, int slot, const uint8_t *rgba, int w, int h);
/// The frame's quads, 20 floats each (SQDrawKit.DrawQuad).
int sq_ui_set_quads(SQUi *g, const float *quads, int count);
/// Clears, draws the quads, presents (when a window is attached). `rgbaOut` (width * height * 4) gets the picture.
int sq_ui_render(SQUi *g, float r, float gr, float b, uint8_t *rgbaOut, int vsync);
void sq_ui_destroy(SQUi *g);

/// File choosers (filedialog.cpp): the Common Item Dialog. `filter` "label\0pattern\0...\0\0" (NULL = none), `folder` the
/// folder it opens in, `name` the suggested file name, `defaultExtension` the save extension (all UTF-16, NULL = none).
/// `out` gets "path\0path\0\0" (UTF-16). Returns the number of paths, 0 when canceled, below 0 on failure.
enum { SQ_FILE_DIALOG_OPEN = 0, SQ_FILE_DIALOG_OPEN_MULTIPLE = 1, SQ_FILE_DIALOG_SAVE = 2, SQ_FILE_DIALOG_FOLDER = 3 };
/// Never blocks the caller's message loop: on an MTA thread (WASAPI's CoInitializeEx) the dialog runs on its own STA
/// thread while the caller keeps pumping messages, so the window never shows "Not responding".
int sq_file_dialog(void *owner, int mode, const uint16_t *title, const uint16_t *filter, const uint16_t *folder,
                   const uint16_t *name, const uint16_t *defaultExtension, uint16_t *out, int capacity);

/// Makes the calling (UI) thread a single-threaded apartment (OleInitialize): call first in main, before any COM user
/// (WASAPI asks for MTA and then gets the STA, which it works in). Returns the HRESULT (S_FALSE = already STA).
int sq_com_init_ui_thread(void);
/// 1 when the calling thread is in a single-threaded apartment (the file dialog test).
int sq_com_is_sta(void);

/// Closes the console window when this process is its only user (started from a shortcut or by double-clicking a
/// .sqproj); a console shared with a shell or a script keeps working. 1 = detached.
int sq_detach_own_console(void);

/// Explorer drags (drop.cpp): an OLE drop target on `hwnd`; 0 = registered. The release still arrives as WM_DROPFILES.
int sq_drop_register(void *hwnd);
/// 1 while files hover over the window, with the pointer in client pixels.
int sq_drop_hover(float *x, float *y);
/// The hovering drag's paths, UTF-16, each NUL-terminated; returns the length in code units (copies only when it fits).
int sq_drop_paths(uint16_t *buf, int capacity);

/// The STORAGE_BUS_TYPE of drive `root` ("E:\\", UTF-16) (drive.cpp): 7 USB, 4 1394, 12 SD, 13 MMC; -1 unknown.
int sq_drive_bus_type(const uint16_t *root);

#ifdef __cplusplus
}
#endif
