#ifndef SQLOTTIE_H
#define SQLOTTIE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A loaded Lottie animation (ThorVG software renderer). One handle must not be used from two threads at once.
typedef struct SQLottie SQLottie;

/// Loads Lottie JSON (the bytes are copied). NULL when ThorVG cannot read it.
SQLottie *sqlottie_open(const char *data, uint32_t size);
void sqlottie_close(SQLottie *handle);

/// The animation's own size in px, frame count and duration (out-parameters may be NULL).
void sqlottie_info(const SQLottie *handle, float *width, float *height, float *total_frames, float *duration_seconds);

/// Draws animation frame `frame` (0 ... total frames) scaled to `width` x `height` px into `rgba`, which holds
/// width * height * 4 bytes: R, G, B, A per pixel, straight (not premultiplied), transparent where nothing is drawn.
/// Returns 0 on success.
int sqlottie_render(SQLottie *handle, float frame, uint32_t width, uint32_t height, uint8_t *rgba);

#ifdef __cplusplus
}
#endif

#endif
