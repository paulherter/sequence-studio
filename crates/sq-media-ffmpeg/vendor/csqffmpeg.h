// FFmpeg (LGPL shared build) behind a small C interface for sq-media-ffmpeg (copied from CSQFFmpeg; WASAPI dropped).
// Every function returns 0 on success, a negative FFmpeg/HRESULT-style code on failure, and fills `err` when given.
#ifndef CSQFFMPEG_H
#define CSQFFMPEG_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// MARK: Version check

// 0 when the loaded libraries have the major versions the headers of this build describe; else -1 and `err` says which differs.
int sq_version_mismatch(char *err, int errLen);

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
    int32_t discard;              // AV_PKT_FLAG_DISCARD: the container's edit list does not present this sample (kept for decoding)
    int32_t reserved;
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
    int fieldOrder;               // AVFieldOrder of the codec parameters (0 unknown, 1 progressive, 2 TT, 3 BB, 4 TB, 5 BT)
    int bitsPerCodedSample;       // QuickTime Animation (qtrle) and other RLE codecs need it to pick their pixel format
    int sarNum, sarDen;           // sample aspect ratio the file tags (0/0 or 0/1 = untagged)
    int hasDolbyVision;           // 1 = the stream carries a Dolby Vision configuration record (dvcC / dvvC / dvwC atom)
    uint8_t dolbyVision[5];       // that record in the atom's byte layout: version major/minor, profile/level/flags (16 bit BE), compatibility id << 4
    uint32_t codecTag;            // the container's codec FourCC (ProRes apcn / ap4h ...): the decoder takes its profile from it
} SQFFVideoInfo;

// Opens `path` and indexes every packet of the best video stream.
int sq_demux_open(const char *path, SQFFDemux **out, char *err, int errLen);
// `fullProbe` 1: always FFmpeg's complete stream probe (decodes a picture); the reference the SPS shortcut is tested against.
int sq_demux_open_with(const char *path, int fullProbe, SQFFDemux **out, char *err, int errLen);
// The codec name and the key flags (1 = sync sample) of the first video packets in decode order, read without indexing or
// decoding the file. `keys` has room for `maxPackets`; `*count` is how many were read. Stops at `maxBytes` of payload
// (but not before 16 packets) in containers that must be read, so a 4K file answers quickly.
int sq_seek_probe(const char *path, int maxPackets, int64_t maxBytes, char *codec, int codecLen, uint8_t *keys, int *count,
                  char *err, int errLen);
// Which quick paths the open took (bit flags): the packet index came from the container's index without reading the
// payload, and the stream facts (pixel format, range, colour tags) came from the H.264 SPS without decoding a picture.
#define SQ_FAST_INDEX_ONLY 1
#define SQ_FAST_SPS_FACTS 2
int sq_demux_fast_paths(const SQFFDemux *d);
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

// `swThreads` > 0 is the thread count of a software decoder (the caller shares the cores between its open decoders); 0 = built-in default.
// `hardware` != 0 decodes with the platform's hardware decoder: D3D11VA (Windows, frames stay D3D11 textures) or VA-API (Linux,
// frames are copied to memory as they come out). Fails when the GPU cannot decode the stream: the caller falls back.
int sq_dec_open(const char *codec, const uint8_t *extradata, int extradataSize, int width, int height, int bitsPerCodedSample,
                uint32_t codecTag, int tbNum, int tbDen, int hardware, int extraHWFrames, int swThreads, SQFFDecoder **out, char *err, int errLen);
void sq_dec_close(SQFFDecoder *dec);
const char *sq_dec_name(const SQFFDecoder *dec);
// Sends one packet (data NULL = end of stream). Returns 1 when the decoder is full (receive first, then send again).
int sq_dec_send(SQFFDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts, int64_t duration, int key);
// 0 = a frame in `out`, 1 = needs input, 2 = end of stream, < 0 = error.
int sq_dec_receive(SQFFDecoder *dec, SQFFFrame **out);
// Drops buffered pictures (before a seek).
void sq_dec_flush(SQFFDecoder *dec);
// Preview decode for software decoders: skips the loop filter (faster, pictures drift from exact). Flush after turning it off.
void sq_dec_set_fast(SQFFDecoder *dec, int on);

void sq_frame_info(const SQFFFrame *f, SQFFFrameInfo *info);
// Bytes `sq_frame_download` writes: planes packed, NV12 (8 bit) or P010 (16 bit) layout.
int sq_frame_download_size(const SQFFFrame *f);
int sq_frame_download(const SQFFFrame *f, uint8_t *buf, int cap);
// Pictures with an alpha channel (QuickTime Animation, ProRes 4444, WebM VP9 alpha ...): 1 when the decoded pixel format has alpha.
int sq_frame_has_alpha(const SQFFFrame *f);
// Those pictures as 8-bit RGBA with straight alpha (width * height * 4 bytes; YUV sources through BT.709).
int sq_frame_download_rgba(const SQFFFrame *f, uint8_t *buf, int cap);
// The same layout box-reduced by `divisor` (1, 2, 4) in one pass, on `threads` threads: 4:2:0 / 4:2:2 / 4:4:4 at 8 or
// 10 bits, planar or NV12 / P010 (hardware frames after transfer). Size 0 / result 1: not this frame (use the plain one).
int sq_frame_download_reduced_size(const SQFFFrame *f, int divisor, int *outWidth, int *outHeight);
/// 1 when the reduced download keeps 4:2:2 chroma (P210 / NV16 layout: interleaved CbCr, full height).
int sq_frame_reduced_422(const SQFFFrame *f);
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
// The same for audio stream `ordinal` (0-based among the audio streams; negative = the best one).
int sq_audio_decode_track(const char *path, int sampleRate, int channels, int ordinal, SQFFAudio *out, char *err, int errLen);
// Channels of every audio stream in file order (up to `cap` written); returns the number of audio streams, -1 on error.
int sq_audio_track_channels(const char *path, int *counts, int cap);
// Sample rate of every audio stream in file order (same order and limit as `sq_audio_track_channels`).
int sq_audio_track_rates(const char *path, int *rates, int cap);
void sq_audio_free(SQFFAudio *a);

// MARK: Audio reader (streaming: decodes on demand, keeps no more than the caller's window)
typedef struct SQFFAudioReader SQFFAudioReader;
// Opens audio stream `ordinal` (negative = best) for reads at `sampleRate` Hz, `channels` 1 or 2.
// `estimatedFrames` is the length from the container (-1 = unknown), `sourceChannels` the file's own channel count.
SQFFAudioReader *sq_audio_reader_open(const char *path, int sampleRate, int channels, int ordinal,
                                      int64_t *estimatedFrames, int *sourceChannels, char *err, int errLen);
// Interleaved frames [start, start + frames) into `out`; seeks when `start` is not where the decoder is. Returns the
// frames written (fewer or 0 at the end of the stream), or a negative FFmpeg error.
int sq_audio_reader_read(SQFFAudioReader *r, int64_t start, float *out, int frames);
// Length in frames once the end of the stream was reached, else -1.
int64_t sq_audio_reader_end(const SQFFAudioReader *r);
void sq_audio_reader_close(SQFFAudioReader *r);

// MARK: Still image decode (any format FFmpeg reads: PNG, TIFF, EXR, DPX, TGA ...)
// Reads the picture size without decoding.
int sq_image_size(const char *path, int *width, int *height);
// Decodes the first picture as straight 8-bit RGBA, `width * height * 4` bytes (`cap` is the buffer size).
int sq_image_decode_rgba(const char *path, uint8_t *buf, int cap);

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
    double quality;               // 0 = a target bitrate; else constant quality 0.05...1 (no bitrate, no cap)
    int64_t maxBitrate;           // 0 = the default cap (1.5 x bitrate); else the VBR maximum
    int cbr;                      // 1 = constant bitrate (maximum and minimum = the bitrate)
    int speed;                    // 0 = Quality, 1 = Balanced, 2 = Fast (encoder preset / speed hint)
    int colorPrimaries, colorTrc, colorSpace;   // AVColor* values written to the video stream; 0 or 2 (unspecified) = Rec. 709
    int rotation;                 // clockwise degrees stored as the stream's display matrix (0 = none)
    const char *title, *comment, *creationTime;   // container tags (null or empty = none); creationTime ISO 8601
    const uint8_t *mdcv;          // 24 bytes MasteringDisplayColorVolume (G, B, R, white x/y UInt16 0.00002; max/min UInt32 0.0001 nit), big endian; null = none
    const uint8_t *cll;           // 4 bytes ContentLightLevelInfo (MaxCLL, MaxFALL UInt16 nits), big endian; null = none
    const char *encoders;         // comma-separated video encoder names in try order (Rust `candidates`)
    const char *encoderOptions;   // "name<TAB>key<TAB>value" lines: private options per candidate (Rust `private_options`)
    int hardwareEncoders;         // how many of them, from the front, are hardware (probed with a test frame first)
    int extraAudioCount;          // further audio tracks after the first (0...7), same codec and depth
    int extraAudioRate[7];
    int extraAudioChannels[7];
    int h264Profile;              // H.264 only: 0 = the encoder decides, 1 Baseline, 2 Main, 3 High (Baseline also drops B-frames)
} SQFFEncodeConfig;
int sq_enc_open(const SQFFEncodeConfig *cfg, SQFFEncoder **out, char *err, int errLen);
const char *sq_enc_video_name(const SQFFEncoder *e);
// What the opened video encoder really does: the bit depth of its pictures and whether packets came out with a time
// that goes back (B-frames); the second is only meaningful after a few pictures were written.
void sq_enc_video_facts(const SQFFEncoder *e, int *bitDepth, int *reordered);
// Ends the video stream and writes the packets the encoder still holds; no picture may follow (probes only).
int sq_enc_drain_video(SQFFEncoder *e);
// One frame, `format` an AVPixelFormat name ("bgra", "rgba", "nv12", "p010le"); planes packed, `stride` of plane 0.
int sq_enc_video(SQFFEncoder *e, const uint8_t *pixels, const char *format, int stride, int64_t frameIndex);
// Interleaved float frames at the audio rate.
int sq_enc_audio(SQFFEncoder *e, const float *interleaved, int frames);
// The same for audio track `track` (0 = the first, 1... = the extra ones).
int sq_enc_audio_track(SQFFEncoder *e, int track, const float *interleaved, int frames);
// Flushes, writes the trailer and closes the file (`e` is freed, also on failure).
int sq_enc_finish(SQFFEncoder *e, char *err, int errLen);
void sq_enc_abort(SQFFEncoder *e);
// One still image file. `codec` "png", "mjpeg", "tiff" or "exr"; `format` the AVPixelFormat name of `pixels` (planes
// packed, `stride` the bytes of a plane-0 row); `alpha` keeps the alpha channel (PNG, TIFF); `quality` 0...1 (JPEG).
int sq_still_write(const char *path, const char *codec, const uint8_t *pixels, const char *format, int stride,
                   int width, int height, int alpha, double quality, char *err, int errLen);

#ifdef __cplusplus
}
#endif
#endif
