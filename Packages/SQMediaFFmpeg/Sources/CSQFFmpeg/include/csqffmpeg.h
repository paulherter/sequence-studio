// FFmpeg (LGPL shared build) and WASAPI behind a small C interface for SQMediaFFmpeg (Windows only).
// Every function returns 0 on success, a negative FFmpeg/HRESULT-style code on failure, and fills `err` when given.
#ifndef CSQFFMPEG_H
#define CSQFFMPEG_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// MARK: Probe (import: streams and duration of one file, nothing indexed or decoded)

typedef struct {
    int64_t durationUs;           // container duration in microseconds, -1 unknown
    char format[64];              // demuxer name ("mov,mp4,m4a,3gp,3g2,mj2", "png_pipe", "image2", ...)
    int hasVideo, width, height;
    int64_t videoFrames;          // stream frame count, -1 unknown
    char videoCodec[32];
    int hasAudio, audioRate, audioChannels;
    char audioCodec[32];
} SQFFProbe;
int sq_probe(const char *path, SQFFProbe *out, char *err, int errLen);

// MARK: Demux (video stream of one file)

typedef struct SQFFDemux SQFFDemux;
typedef struct {
    int64_t pts, dts, duration;   // stream time base ticks; pts/dts AV_NOPTS_VALUE filled from dts/pts
    int64_t pos;                  // byte offset in the file
    int32_t size;
    int32_t key;
} SQFFPacket;
typedef struct {
    int width, height;
    int tbNum, tbDen;             // stream time base
    int frNum, frDen;             // average frame rate (0/0 unknown)
    int rotation;                 // clockwise degrees
    int bitDepth;
    char codec[32];               // FFmpeg codec name ("h264", "hevc", ...)
    char pixFmt[32];
    int colorPrimaries, colorTransfer, colorMatrix, colorRange;   // AVColor* values
} SQFFVideoInfo;

// Opens `path` and indexes every packet of the best video stream.
int sq_demux_open(const char *path, SQFFDemux **out, char *err, int errLen);
void sq_demux_close(SQFFDemux *d);
void sq_demux_info(const SQFFDemux *d, SQFFVideoInfo *info);
int sq_demux_packet_count(const SQFFDemux *d);
const SQFFPacket *sq_demux_packets(const SQFFDemux *d);   // decode order
const uint8_t *sq_demux_extradata(const SQFFDemux *d, int *size);
// Copies the bytes of packet `ordinal` (decode order) into `buf` (at least the packet size). Thread-safe.
int sq_demux_read(SQFFDemux *d, int ordinal, uint8_t *buf, int cap);

// MARK: Video decode

typedef struct SQFFDecoder SQFFDecoder;
typedef struct SQFFFrame SQFFFrame;   // a reference to one decoded AVFrame
typedef struct {
    int width, height;
    int hardware;                 // 1 = D3D11 texture
    void *texture;                // ID3D11Texture2D* when hardware
    int textureIndex;             // array slice of `texture`
    int swFormat;                 // AVPixelFormat of the pixels (NV12, P010, ...)
    int64_t pts;                  // stream ticks (best effort)
} SQFFFrameInfo;

// `hardware` != 0 decodes with D3D11VA (fails when the GPU cannot decode the stream: the caller falls back).
int sq_dec_open(const char *codec, const uint8_t *extradata, int extradataSize, int width, int height,
                int tbNum, int tbDen, int hardware, int extraHWFrames, SQFFDecoder **out, char *err, int errLen);
void sq_dec_close(SQFFDecoder *dec);
const char *sq_dec_name(const SQFFDecoder *dec);
// Sends one packet (data NULL = end of stream). Returns 1 when the decoder is full (receive first, then send again).
int sq_dec_send(SQFFDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts, int64_t duration, int key);
// 0 = a frame in `out`, 1 = needs input, 2 = end of stream, < 0 = error.
int sq_dec_receive(SQFFDecoder *dec, SQFFFrame **out);
// Drops buffered pictures (before a seek).
void sq_dec_flush(SQFFDecoder *dec);

void sq_frame_info(const SQFFFrame *f, SQFFFrameInfo *info);
// Bytes `sq_frame_download` writes: planes packed, NV12 (8 bit) or P010 (16 bit) layout.
int sq_frame_download_size(const SQFFFrame *f);
int sq_frame_download(const SQFFFrame *f, uint8_t *buf, int cap);
// The same layout box-reduced by `divisor` (1, 2, 4) in one pass, on `threads` threads: 4:2:0 / 4:2:2 / 4:4:4 at 8 or
// 10 bits, planar or NV12 / P010 (hardware frames after transfer). Size 0 / result 1: not this frame (use the plain one).
int sq_frame_download_reduced_size(const SQFFFrame *f, int divisor, int *outWidth, int *outHeight);
int sq_frame_download_reduced(const SQFFFrame *f, int divisor, int threads, uint8_t *buf, int cap);
void sq_frame_free(SQFFFrame *f);

// MARK: Audio decode (whole stream to interleaved float at a fixed rate)

typedef struct {
    float *samples;               // interleaved, `channels` per frame
    int64_t frames;
    int channels, sampleRate;
    int sourceChannels;
} SQFFAudio;
// Decodes the best audio stream of `path`, resampled to `sampleRate` and `channels` (1 or 2).
int sq_audio_decode(const char *path, int sampleRate, int channels, SQFFAudio *out, char *err, int errLen);
void sq_audio_free(SQFFAudio *a);

// MARK: Encode (H.264/HEVC or ProRes video + AAC or PCM audio into MP4/MOV; audio-only M4A/WAV/FLAC; GIF; stills)

typedef struct SQFFEncoder SQFFEncoder;
typedef struct {
    const char *path;
    int hevc;                     // 0 = H.264, 1 = HEVC
    int hardware;                 // 1 = try AMF, NVENC, QSV, Media Foundation before software
    int width, height;
    int fpsNum, fpsDen;           // frame rate (inverse of the frame duration)
    int64_t bitrate;
    int gop;
    int bFrames;                  // 0 = none
    int tenBit;                   // HEVC Main 10 (P010 input)
    int prores;                   // 0 = H.264/HEVC; else 1 + prores_ks profile (1 Proxy, 2 LT, 3 422, 4 HQ, 5 4444)
    int pcmBits;                  // 0 = AAC; 16, 24 or 32 = little-endian integer PCM
    int audioRate, audioChannels; // audioChannels 0 = no audio
    int64_t audioBitrate;
    int noVideo;                  // 1 = audio-only file (M4A, WAV or FLAC by the extension)
    int flac;                     // 1 = FLAC audio, `pcmBits` 16 or 24 its depth
    int gif;                      // 1 = animated GIF: "pal8" frames (indices, then 256 BGRA palette entries), each with
                                  // its own palette; the frame index of `sq_enc_video` is its start in centiseconds
    int gifFinalDelay;            // centiseconds the last GIF frame shows
} SQFFEncodeConfig;
int sq_enc_open(const SQFFEncodeConfig *cfg, SQFFEncoder **out, char *err, int errLen);
const char *sq_enc_video_name(const SQFFEncoder *e);
// One frame, `format` an AVPixelFormat name ("bgra", "rgba", "nv12", "p010le"); planes packed, `stride` of plane 0.
int sq_enc_video(SQFFEncoder *e, const uint8_t *pixels, const char *format, int stride, int64_t frameIndex);
// Interleaved float frames at the audio rate.
int sq_enc_audio(SQFFEncoder *e, const float *interleaved, int frames);
// Flushes, writes the trailer and closes the file (`e` is freed, also on failure).
int sq_enc_finish(SQFFEncoder *e, char *err, int errLen);
void sq_enc_abort(SQFFEncoder *e);
// One still image file. `codec` "png", "mjpeg", "tiff" or "exr"; `format` the AVPixelFormat name of `pixels` (planes
// packed, `stride` the bytes of a plane-0 row); `alpha` keeps the alpha channel (PNG, TIFF); `quality` 0...1 (JPEG).
int sq_still_write(const char *path, const char *codec, const uint8_t *pixels, const char *format, int stride,
                   int width, int height, int alpha, double quality, char *err, int errLen);

// MARK: WASAPI shared-mode output (48 kHz stereo float, the system converts to the mix format)

typedef struct SQWasapi SQWasapi;
// Called on the audio thread: fill `frames` interleaved stereo frames. `hostNanos` = QPC time of the call.
typedef void (*SQWasapiRender)(void *ctx, float *interleaved, int frames, int64_t hostNanos);
int sq_wasapi_open(SQWasapiRender render, void *ctx, SQWasapi **out, char *err, int errLen);
// `deviceID` (an IMMDevice id, UTF-8) or NULL = the system default; an id that is not connected falls back to the default.
int sq_wasapi_open_device(const char *deviceID, SQWasapiRender render, void *ctx, SQWasapi **out, char *err, int errLen);
// Active output devices as "id\tname\n" lines (UTF-8) into `buf`; returns the bytes needed (with the NUL).
int sq_wasapi_list_outputs(char *buf, int len);
int sq_wasapi_start(SQWasapi *w);
void sq_wasapi_stop(SQWasapi *w);
void sq_wasapi_close(SQWasapi *w);
// Device + stream latency in 48 kHz frames.
int64_t sq_wasapi_latency_frames(const SQWasapi *w);
int64_t sq_wasapi_rendered_frames(const SQWasapi *w);
const char *sq_wasapi_device_name(const SQWasapi *w);

#ifdef __cplusplus
}
#endif
#endif
