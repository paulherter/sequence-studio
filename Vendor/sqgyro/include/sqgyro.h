// sqgyro: Sequence Studio's C API around gyroflow_core (GPL-3.0-or-later). Implementation: ../src/lib.rs.
// The app loads libsqgyro.dylib at runtime (dlopen) and binds these symbols (SQGyro package); this header documents
// the ABI and is used by the smoke test (scripts/build-gyro.sh --check).
#ifndef SQGYRO_H
#define SQGYRO_H
#include <stdint.h>
#include <stddef.h>

typedef struct SQGyroInfo {
    uint32_t width, height;
    double fps;
    double duration_ms;
    uint64_t frame_count;
    double readout_ms;            // rolling-shutter readout from lens profile / file (0 = unknown)
    uint8_t has_motion;
    uint8_t has_accurate_timestamps;
    char camera[128];
    char lens[128];
} SQGyroInfo;

enum { SQGYRO_LUMA8 = 0, SQGYRO_UV8 = 1, SQGYRO_LUMA16 = 2, SQGYRO_UV16 = 3, SQGYRO_BGRA8 = 4 };

typedef struct SQGyroHandle SQGyroHandle;

/// Opens a clip and reads its gyro data + lens profile (blocking). NULL on failure, reason in err.
SQGyroHandle *sqgyro_open(const char *path, SQGyroInfo *info, char *err, size_t err_len);
/// smoothness % (1...100), zoom_limit %, rolling_shutter 0/1, horizon_lock %. Applied by the next sqgyro_recompute.
void sqgyro_set_params(SQGyroHandle *h, double smoothness, double zoom_limit, uint8_t rolling_shutter, double horizon_lock);
/// fov: output field of view (1 = as framed, 0.1...3); lens_correction 0...1; sync_offset_ms added to the file's gyro
/// sync offsets (Gyroflow's sign: positive = an EARLIER gyro sample is used). Applied by the next sqgyro_recompute.
void sqgyro_set_lens_params(SQGyroHandle *h, double fov, double lens_correction, double sync_offset_ms);
/// Overrides the file's rotation tag (clockwise degrees); only the horizon lock uses it. Applied by the next recompute.
void sqgyro_set_rotation(SQGyroHandle *h, double degrees);
/// Copy of an opened handle (same file data and settings, no file read). NULL on failure.
SQGyroHandle *sqgyro_fork(SQGyroHandle *h);
/// Measuring aid: total angle of the smoothing/horizon correction at ts_us, degrees. 1 = ok.
int32_t sqgyro_correction_angle(SQGyroHandle *h, int64_t ts_us, double *deg);
/// Smoothing + adaptive zoom over the whole clip (blocking, CPU). 1 = ok.
int32_t sqgyro_recompute(SQGyroHandle *h);
/// Warps one plane (CPU memory). ts_us = frame start in the file. 1 = ok, 0 = not ready / failed.
int32_t sqgyro_process_plane(SQGyroHandle *h, int64_t ts_us, uint32_t kind, uint32_t width, uint32_t height,
                             uint8_t *input, size_t in_stride, uint8_t *output, size_t out_stride, uint8_t full_range);
/// Measuring aid: camera rotation between ts_us and ts_us + dt_us in degrees, raw and after smoothing (the residual).
int32_t sqgyro_motion_step(SQGyroHandle *h, int64_t ts_us, int64_t dt_us, double *raw_deg, double *smooth_deg);
void sqgyro_free(SQGyroHandle *h);
#endif
