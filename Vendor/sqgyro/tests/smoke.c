// Smoke test for libsqgyro: open a clip, recompute, warp a checkerboard luma + flat chroma plane, print timings.
// Built and run by scripts/build-gyro.sh --check <clip>.
#include "sqgyro.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: smoke <clip>\n"); return 2; }
    SQGyroInfo info; char err[256] = {0};
    double t0 = now();
    SQGyroHandle *h = sqgyro_open(argv[1], &info, err, sizeof err);
    if (!h) { printf("open failed: %s\n", err); return 1; }
    printf("open %.2f s: %ux%u fps %.3f duration %.0f ms frames %llu readout %.2f ms motion %d accurateTS %d camera '%s' lens '%s'\n",
           now() - t0, info.width, info.height, info.fps, info.duration_ms, (unsigned long long)info.frame_count,
           info.readout_ms, info.has_motion, info.has_accurate_timestamps, info.camera, info.lens);
    sqgyro_set_params(h, 50, 130, 1, 0);
    t0 = now();
    int ok = sqgyro_recompute(h);
    printf("recompute %d %.2f s\n", ok, now() - t0);
    uint32_t w = info.width, ht = info.height;
    uint8_t *in = malloc((size_t)w * ht), *out = malloc((size_t)w * ht);
    for (uint32_t y = 0; y < ht; y++) for (uint32_t x = 0; x < w; x++) in[(size_t)y * w + x] = ((x / 64 + y / 64) & 1) ? 220 : 30;
    for (int i = 0; i < 5; i++) {
        t0 = now();
        ok = sqgyro_process_plane(h, (int64_t)(i * 1e6 / info.fps), SQGYRO_LUMA8, w, ht, in, w, out, w, 0);
        printf("luma frame %d ok %d %.1f ms\n", i, ok, (now() - t0) * 1e3);
    }
    long diff = 0;
    for (size_t i = 0; i < (size_t)w * ht; i++) diff += in[i] != out[i];
    printf("changed pixels %.1f%%\n", 100.0 * diff / ((double)w * ht));
    uint8_t *uin = malloc((size_t)w * ht / 2), *uout = malloc((size_t)w * ht / 2);
    memset(uin, 128, (size_t)w * ht / 2);
    for (int i = 0; i < 3; i++) {
        t0 = now();
        ok = sqgyro_process_plane(h, (int64_t)(i * 1e6 / info.fps), SQGYRO_UV8, w / 2, ht / 2, uin, w, uout, w, 0);
        printf("uv frame %d ok %d %.1f ms\n", i, ok, (now() - t0) * 1e3);
    }
    // Residual motion: mean / max frame-to-frame camera rotation over the whole clip, raw vs stabilised.
    int64_t dt = (int64_t)(1e6 / info.fps);
    double sumR = 0, sumS = 0, maxR = 0, maxS = 0; int n = 0;
    for (int64_t ts = 0; ts + dt < (int64_t)(info.duration_ms * 1000); ts += dt) {
        double r = 0, s = 0;
        if (!sqgyro_motion_step(h, ts, dt, &r, &s)) continue;
        sumR += r; sumS += s; n++;
        if (r > maxR) maxR = r;
        if (s > maxS) maxS = s;
    }
    if (n) printf("motion per frame over %d frames: raw mean %.4f max %.4f deg, stabilised mean %.4f max %.4f deg (%.1fx less)\n",
                  n, sumR / n, maxR, sumS / n, maxS, sumS > 0 ? sumR / sumS : 0);
    sqgyro_free(h);
    free(in); free(out); free(uin); free(uout);
    return ok ? 0 : 1;
}
