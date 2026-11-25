// Video decode: hardware (D3D11VA on Windows, VA-API on Linux) or software, one AVCodecContext per decoder.
#include "common.h"
#include <string.h>
#include <thread>
#include <cstdlib>
#include <vector>
#include <chrono>
#if defined(__linux__)
#include <unistd.h>
#endif

// The platform's FFmpeg hardware decoder. D3D11VA frames stay D3D11 textures until downloaded (`kHwTexture`); a VA-API surface
// has no other consumer here, so `sq_dec_receive` copies it to memory at once and the surface goes back to the pool: the
// decoder never holds GPU memory a caller could exhaust (4K 10-bit surfaces on the GPU are scarce).
#if defined(_WIN32)
static const AVHWDeviceType kHwType = AV_HWDEVICE_TYPE_D3D11VA;
static const AVPixelFormat kHwFormat = AV_PIX_FMT_D3D11;
static const bool kHwTexture = true;
static const char *kHwName = "d3d11va";
#elif defined(__linux__)
static const AVHWDeviceType kHwType = AV_HWDEVICE_TYPE_VAAPI;
static const AVPixelFormat kHwFormat = AV_PIX_FMT_VAAPI;
static const bool kHwTexture = false;
static const char *kHwName = "vaapi";
#else
static const AVHWDeviceType kHwType = AV_HWDEVICE_TYPE_NONE;
static const AVPixelFormat kHwFormat = AV_PIX_FMT_NONE;
static const bool kHwTexture = false;
static const char *kHwName = "none";
#endif

// Per-phase time of a decoder (`SQ_DEC_TRACE=1`: printed when it closes): where a picture's time goes.
struct DecTrace {
    double sendMs = 0, receiveMs = 0, transferMs = 0;
    long frames = 0;
};
static double nowMs() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct SQFFDecoder {
    DecTrace trace;
    AVCodecContext *ctx = nullptr;
    AVBufferRef *device = nullptr;
    AVPacket *pkt = nullptr;
    bool hardware = false;
    char name[96];
};

struct SQFFFrame {
    AVFrame *frame;
};

static AVPixelFormat pickHardware(AVCodecContext *, const AVPixelFormat *f) {
    for (; *f != AV_PIX_FMT_NONE; f++)
        if (*f == kHwFormat) return *f;
    return AV_PIX_FMT_NONE;   // no hardware path for this stream: decoding fails, the caller falls back to software
}

/// The hardware device: Windows takes the default adapter. Linux tries `SQ_VAAPI_DEVICE`, then the DRM render nodes in
/// order (the first GPU with a VA-API driver wins; an NVIDIA-only box has none and the caller falls back to software).
static int openHardwareDevice(AVBufferRef **device) {
#if defined(__linux__)
    if (const char *named = getenv("SQ_VAAPI_DEVICE"))
        return av_hwdevice_ctx_create(device, kHwType, named, nullptr, 0);
    int e = AVERROR(ENODEV);
    for (int node = 128; node < 144; node++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/dri/renderD%d", node);
        if (access(path, R_OK | W_OK) != 0) continue;
        if ((e = av_hwdevice_ctx_create(device, kHwType, path, nullptr, 0)) >= 0) return e;
    }
    return e;
#else
    return av_hwdevice_ctx_create(device, kHwType, nullptr, nullptr, 0);
#endif
}

int sq_dec_open(const char *codecName, const uint8_t *extradata, int extradataSize, int width, int height, int bitsPerCodedSample, uint32_t codecTag, int tbNum,
                int tbDen, int hardware, int extraHWFrames, int swThreads, SQFFDecoder **out, char *err, int errLen) {
    *out = nullptr;
    const AVCodecDescriptor *desc = avcodec_descriptor_get_by_name(codecName);
    const AVCodec *codec = desc ? avcodec_find_decoder(desc->id) : nullptr;
    // libdav1d is FFmpeg's first AV1 decoder and takes no hwaccel: the hardware path needs the native one.
    if (hardware && desc && desc->id == AV_CODEC_ID_AV1)
        if (const AVCodec *native = avcodec_find_decoder_by_name("av1")) codec = native;
    if (!codec) { sqSetError(err, errLen, "no decoder", AVERROR_DECODER_NOT_FOUND); return AVERROR_DECODER_NOT_FOUND; }
    SQFFDecoder *dec = new SQFFDecoder();
    int e;
    dec->ctx = avcodec_alloc_context3(codec);
    dec->pkt = av_packet_alloc();
    dec->ctx->width = width; dec->ctx->height = height;
    dec->ctx->bits_per_coded_sample = bitsPerCodedSample;
    dec->ctx->codec_tag = codecTag;   // ProRes reads its profile (422 vs 4444, 10 vs 12 bit) from the FourCC
    dec->ctx->pkt_timebase = AVRational{tbNum, tbDen};
    if (extradataSize > 0) {
        dec->ctx->extradata = (uint8_t *)av_mallocz(extradataSize + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(dec->ctx->extradata, extradata, extradataSize);
        dec->ctx->extradata_size = extradataSize;
    }
    if (hardware) {
        if (kHwType == AV_HWDEVICE_TYPE_NONE) { sqSetError(err, errLen, "no hardware decoder on this system", AVERROR(ENOSYS)); sq_dec_close(dec); return AVERROR(ENOSYS); }
        if ((e = openHardwareDevice(&dec->device)) < 0) {
            char what[32]; snprintf(what, sizeof what, "%s device", kHwName);
            sqSetError(err, errLen, what, e); sq_dec_close(dec); return e;
        }
        dec->ctx->hw_device_ctx = av_buffer_ref(dec->device);
        dec->ctx->get_format = pickHardware;
        // Decoded frames handed out keep their pool texture until released: room for the frames playback holds.
        dec->ctx->extra_hw_frames = extraHWFrames;
        dec->hardware = true;
    } else {
        // Measured on the PC (16 threads, 4K H.264 and 1080p ProRes in the project): automatic frame threading took 481 % of
        // a core in playback, two slice threads 339 % with no dropped frame. SQ_DEC_THREADS / SQ_DEC_THREAD_TYPE
        // (1 frame, 2 slice, 3 both) override it for experiments.
        const char *tc = getenv("SQ_DEC_THREADS"), *tt = getenv("SQ_DEC_THREAD_TYPE");
        // A picture of 4K and up (the camera files the hardware cannot take, 4:2:2 10-bit) is where a jump or an edit
        // stalls: the decode of the GOP up to the target frame ran 1-2 s on two slice threads and 0.3 s on four frame+slice
        // threads (notes/LEARNINGS.md, edit bench). Smaller pictures keep the cheaper two slice threads.
        // Pixel count, not width: a portrait 2160x3840 file is as heavy. Threads follow the cores (a layered project opens
        // several such decoders at once): a quarter of the logical cores, 2 to 4.
        const bool big = (long)width * height >= 3500000L;
        const unsigned cores = std::thread::hardware_concurrency();
        const int bigThreads = cores >= 16 ? 4 : (cores >= 8 ? 3 : 2);
        dec->ctx->thread_count = tc ? atoi(tc) : (swThreads > 0 ? swThreads : (big ? bigThreads : 2));
        dec->ctx->thread_type = tt ? atoi(tt) : (big ? (FF_THREAD_FRAME | FF_THREAD_SLICE) : FF_THREAD_SLICE);
    }
    if ((e = avcodec_open2(dec->ctx, codec, nullptr)) < 0) { sqSetError(err, errLen, "codec open", e); sq_dec_close(dec); return e; }
    snprintf(dec->name, sizeof dec->name, "%s (%s)", codec->name, hardware ? kHwName : "software");
    *out = dec;
    return 0;
}

void sq_dec_close(SQFFDecoder *dec) {
    if (!dec) return;
    if (dec->trace.frames > 0 && getenv("SQ_DEC_TRACE"))
        fprintf(stderr, "sq-dec-trace %s: %ld frames, per frame: send %.2f ms, receive %.2f ms, transfer %.2f ms\n", dec->name,
                dec->trace.frames, dec->trace.sendMs / dec->trace.frames, dec->trace.receiveMs / dec->trace.frames,
                dec->trace.transferMs / dec->trace.frames);
    avcodec_free_context(&dec->ctx);
    av_packet_free(&dec->pkt);
    av_buffer_unref(&dec->device);
    delete dec;
}

const char *sq_dec_name(const SQFFDecoder *dec) { return dec->name; }

int sq_dec_send(SQFFDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts, int64_t duration, int key) {
    int e;
    if (!data) {
        e = avcodec_send_packet(dec->ctx, nullptr);
        return e == AVERROR_EOF ? 0 : e;
    }
    av_packet_unref(dec->pkt);
    if ((e = av_new_packet(dec->pkt, size)) < 0) return e;
    memcpy(dec->pkt->data, data, size);
    dec->pkt->pts = pts; dec->pkt->dts = dts; dec->pkt->duration = duration;
    if (key) dec->pkt->flags |= AV_PKT_FLAG_KEY;
    double t0 = nowMs();
    e = avcodec_send_packet(dec->ctx, dec->pkt);
    dec->trace.sendMs += nowMs() - t0;
    if (e == AVERROR(EAGAIN)) return 1;
    return e;
}

int sq_dec_receive(SQFFDecoder *dec, SQFFFrame **out) {
    *out = nullptr;
    AVFrame *f = av_frame_alloc();
    double t0 = nowMs();
    int e = avcodec_receive_frame(dec->ctx, f);
    dec->trace.receiveMs += nowMs() - t0;
    if (e == AVERROR(EAGAIN)) { av_frame_free(&f); return 1; }
    if (e == AVERROR_EOF) { av_frame_free(&f); return 2; }
    if (e < 0) { av_frame_free(&f); return e; }
    if (dec->hardware && f->format != kHwFormat) { av_frame_free(&f); return AVERROR(ENOSYS); }
    if (f->best_effort_timestamp != AV_NOPTS_VALUE) f->pts = f->best_effort_timestamp;
    dec->trace.frames++;
    if (dec->hardware && !kHwTexture) {
        double t1 = nowMs();
        AVFrame *sw = av_frame_alloc();
        e = av_hwframe_transfer_data(sw, f, 0);
        dec->trace.transferMs += nowMs() - t1;
        if (e >= 0) e = av_frame_copy_props(sw, f);
        av_frame_free(&f);
        if (e < 0) { av_frame_free(&sw); return e; }
        f = sw;
    }
    *out = new SQFFFrame{f};
    return 0;
}

void sq_dec_flush(SQFFDecoder *dec) { avcodec_flush_buffers(dec->ctx); }

// Preview decode (scrubbing a heavy software-decoded clip): no in-loop deblocking and FFmpeg's non-spec speedups. The pictures
// drift from the exact ones, so the caller flushes and drops them when it turns this off.
void sq_dec_set_fast(SQFFDecoder *dec, int on) {
    if (dec->hardware) return;
    dec->ctx->skip_loop_filter = on ? AVDISCARD_ALL : AVDISCARD_DEFAULT;
    if (on) dec->ctx->flags2 |= AV_CODEC_FLAG2_FAST; else dec->ctx->flags2 &= ~AV_CODEC_FLAG2_FAST;
}

static AVPixelFormat pixelsOf(const AVFrame *f) {
    if (f->format == kHwFormat && f->hw_frames_ctx)
        return ((AVHWFramesContext *)f->hw_frames_ctx->data)->sw_format;
    return (AVPixelFormat)f->format;
}

void sq_frame_info(const SQFFFrame *f, SQFFFrameInfo *info) {
    memset(info, 0, sizeof *info);
    info->width = f->frame->width; info->height = f->frame->height;
    info->hardware = kHwTexture && f->frame->format == kHwFormat;
    if (info->hardware) {
        info->texture = f->frame->data[0];
        info->textureIndex = (int)(intptr_t)f->frame->data[1];
    }
    info->swFormat = pixelsOf(f->frame);
    info->pts = f->frame->pts;
}

/// NV12 for 8-bit sources, P010 for deeper ones: the layouts `SQFramePixelFormat.nv12` / `.p010` describe.
static AVPixelFormat downloadFormat(const AVFrame *f) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(pixelsOf(f));
    return d && d->comp[0].depth > 8 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
}

/// The video-range twin of a JPEG-range planar format. swscale converts the range of a yuvj* source into a video-range
/// target, but the codes of a stream flagged full range must reach the picture unscaled (its pixel format says full):
/// reading the planes as the twin copies them. The reduced download (`planesOf`) copies the codes the same way.
static AVPixelFormat unscaledFormat(AVPixelFormat f) {
    switch (f) {
    case AV_PIX_FMT_YUVJ420P: return AV_PIX_FMT_YUV420P;
    case AV_PIX_FMT_YUVJ422P: return AV_PIX_FMT_YUV422P;
    case AV_PIX_FMT_YUVJ444P: return AV_PIX_FMT_YUV444P;
    case AV_PIX_FMT_YUVJ440P: return AV_PIX_FMT_YUV440P;
    case AV_PIX_FMT_YUVJ411P: return AV_PIX_FMT_YUV411P;
    default: return f;
    }
}

int sq_frame_download_size(const SQFFFrame *f) {
    return av_image_get_buffer_size(downloadFormat(f->frame), f->frame->width, f->frame->height, 1);
}

int sq_frame_download(const SQFFFrame *f, uint8_t *buf, int cap) {
    const AVFrame *src = f->frame;
    AVFrame *sw = nullptr;
    int e = 0;
    if (src->format == kHwFormat) {
        sw = av_frame_alloc();
        if ((e = av_hwframe_transfer_data(sw, src, 0)) < 0) { av_frame_free(&sw); return e; }
        src = sw;
    }
    AVPixelFormat target = downloadFormat(f->frame);
    int w = src->width, h = src->height;
    int need = av_image_get_buffer_size(target, w, h, 1);
    if (cap < need) { av_frame_free(&sw); return AVERROR(ENOSPC); }
    uint8_t *dst[4]; int ds[4];
    av_image_fill_arrays(dst, ds, buf, target, w, h, 1);
    if ((AVPixelFormat)src->format == target) {
        av_image_copy2(dst, ds, src->data, src->linesize, target, w, h);
    } else {
        SwsContext *sws = sws_getContext(w, h, unscaledFormat((AVPixelFormat)src->format), w, h, target, SWS_POINT, nullptr, nullptr, nullptr);
        if (!sws) { av_frame_free(&sw); return AVERROR(EINVAL); }
        sws_scale(sws, src->data, src->linesize, 0, h, dst, ds);
        sws_freeContext(sws);
    }
    av_frame_free(&sw);
    return 0;
}

int sq_frame_has_alpha(const SQFFFrame *f) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(pixelsOf(f->frame));
    return d && (d->flags & AV_PIX_FMT_FLAG_ALPHA) ? 1 : 0;
}

int sq_frame_download_rgba(const SQFFFrame *f, uint8_t *buf, int cap) {
    const AVFrame *src = f->frame;
    AVFrame *sw = nullptr;
    int e = 0;
    if (src->format == kHwFormat) {
        sw = av_frame_alloc();
        if ((e = av_hwframe_transfer_data(sw, src, 0)) < 0) { av_frame_free(&sw); return e; }
        src = sw;
    }
    int w = src->width, h = src->height;
    if (cap < w * h * 4) { av_frame_free(&sw); return AVERROR(ENOSPC); }
    uint8_t *dst[4] = { buf, nullptr, nullptr, nullptr }; int ds[4] = { w * 4, 0, 0, 0 };
    SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)src->format, w, h, AV_PIX_FMT_RGBA, SWS_POINT, nullptr, nullptr, nullptr);
    if (!sws) { av_frame_free(&sw); return AVERROR(EINVAL); }
    const AVPixFmtDescriptor *sd = av_pix_fmt_desc_get((AVPixelFormat)src->format);
    if (sd && !(sd->flags & AV_PIX_FMT_FLAG_RGB)) {   // YUV (ProRes 4444 ...): BT.709, as the video path
        const int *c709 = sws_getCoefficients(SWS_CS_ITU709);
        sws_setColorspaceDetails(sws, c709, src->color_range == AVCOL_RANGE_JPEG ? 1 : 0, c709, 1, 0, 1 << 16, 1 << 16);
    }
    sws_scale(sws, src->data, src->linesize, 0, h, dst, ds);
    sws_freeContext(sws);
    av_frame_free(&sw);
    return 0;
}

// MARK: Reduced download

namespace {
/// One source picture's planes for the box reduction: planar (Cb in `c0`, Cr in `c1`) or interleaved CbCr (`c1` null).
struct Planes {
    const uint8_t *y, *c0, *c1;
    int ys, cs0, cs1;          // line sizes in bytes
    int shift;                 // right shift of a stored sample to its `bits` value (P010: 6)
    int sx, sy;                // chroma subsampling (1 or 2)
};

template <int B> inline int rd(const uint8_t *row, int x) {
    if constexpr (B == 1) return row[x]; else return ((const uint16_t *)row)[x];
}

/// Output rows [y0, y1) (even) of the reduced picture: luma W x H, then interleaved chroma after it: (W/2) x (H/2) rows, or
/// (W/2) x H when `v422` (a 4:2:2 source keeps its full chroma height: P210 layout, no vertical merge). `Deep` writes 16-bit
/// samples MSB-aligned (P010 / P210), else 8 bits. `D` is the reduction when known at compile time (0: `dr`), so the box
/// sums and their division fold into shifts the compiler vectorizes.
template <int B, bool Deep, int D>
void reduceRows(const Planes &p, uint8_t *out, int W, int H, int dr, int y0, int y1, int bits, bool v422) {
    const int d = D ? D : dr;
    const int area = d * d, half = area / 2, up = 16 - bits;
    for (int y = y0; y < y1; y++) {
        for (int x = 0; x < W; x++) {
            int sum = 0;
            for (int dy = 0; dy < d; dy++) {
                const uint8_t *row = p.y + (size_t)(y * d + dy) * p.ys;
                for (int dx = 0; dx < d; dx++) sum += rd<B>(row, x * d + dx) >> p.shift;
            }
            int v = (sum + half) / area;
            if constexpr (Deep) ((uint16_t *)out)[(size_t)y * W + x] = (uint16_t)(v << up);
            else out[(size_t)y * W + x] = (uint8_t)v;
        }
    }
    // Chroma pair (cx, cy) covers luma [2d cx, 2d cx + 2d) x [vo d cy, ...): in source chroma samples bw x bh from (bx, by).
    const int vo = v422 ? 1 : 2;
    const int bw = 2 * d / p.sx, bh = vo * d / p.sy, carea = bw * bh, chalf = carea / 2;
    const int CW = W / 2;
    uint8_t *cbase = out + (size_t)W * H * (Deep ? 2 : 1);
    for (int cy = y0 / vo; cy < y1 / vo; cy++) {
        for (int cx = 0; cx < CW; cx++) {
            int cb = 0, cr = 0;
            for (int dy = 0; dy < bh; dy++) {
                int sy = cy * bh + dy;
                const uint8_t *r0 = p.c0 + (size_t)sy * p.cs0;
                if (p.c1) {
                    const uint8_t *r1 = p.c1 + (size_t)sy * p.cs1;
                    for (int dx = 0; dx < bw; dx++) { cb += rd<B>(r0, cx * bw + dx) >> p.shift; cr += rd<B>(r1, cx * bw + dx) >> p.shift; }
                } else {
                    for (int dx = 0; dx < bw; dx++) {
                        cb += rd<B>(r0, 2 * (cx * bw + dx)) >> p.shift; cr += rd<B>(r0, 2 * (cx * bw + dx) + 1) >> p.shift;
                    }
                }
            }
            size_t o = ((size_t)cy * CW + cx) * 2;
            int vb = (cb + chalf) / carea, vr = (cr + chalf) / carea;
            if constexpr (Deep) { ((uint16_t *)cbase)[o] = (uint16_t)(vb << up); ((uint16_t *)cbase)[o + 1] = (uint16_t)(vr << up); }
            else { cbase[o] = (uint8_t)vb; cbase[o + 1] = (uint8_t)vr; }
        }
    }
}

template <int B, bool Deep>
void reduceBand(const Planes &p, uint8_t *out, int W, int H, int d, int y0, int y1, int bits, bool v422) {
    switch (d) {
    case 1: reduceRows<B, Deep, 1>(p, out, W, H, d, y0, y1, bits, v422); break;
    case 2: reduceRows<B, Deep, 2>(p, out, W, H, d, y0, y1, bits, v422); break;
    case 4: reduceRows<B, Deep, 4>(p, out, W, H, d, y0, y1, bits, v422); break;
    default: reduceRows<B, Deep, 0>(p, out, W, H, d, y0, y1, bits, v422); break;
    }
}

/// The planes of `f` (a software frame, or a hardware frame after transfer) in a layout the reduction reads; false for
/// other formats (RGB, 4:1:1, 12-bit...).
bool planesOf(const AVFrame *f, Planes &p, int &bits) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get((AVPixelFormat)f->format);
    if (!d || (d->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL | AV_PIX_FMT_FLAG_BE | AV_PIX_FMT_FLAG_HWACCEL))) return false;
    int depth = d->comp[0].depth;
    if (depth != 8 && depth != 10) return false;
    p.sx = 1 << d->log2_chroma_w; p.sy = 1 << d->log2_chroma_h;
    if (p.sx > 2 || p.sy > 2 || d->nb_components < 3) return false;
    p.y = f->data[0]; p.ys = f->linesize[0];
    bool interleaved = d->comp[1].plane == d->comp[2].plane;
    if (interleaved) {
        if (d->comp[1].offset > d->comp[2].offset) return false;   // NV21
        p.c0 = f->data[1]; p.cs0 = f->linesize[1]; p.c1 = nullptr; p.cs1 = 0;
    } else {
        p.c0 = f->data[d->comp[1].plane]; p.cs0 = f->linesize[d->comp[1].plane];
        p.c1 = f->data[d->comp[2].plane]; p.cs1 = f->linesize[d->comp[2].plane];
    }
    p.shift = d->comp[0].shift;
    bits = depth;
    return true;
}
}

int sq_frame_download_reduced_size(const SQFFFrame *f, int divisor, int *outWidth, int *outHeight) {
    int w = f->frame->width, h = f->frame->height, d = divisor < 1 ? 1 : divisor;
    if (w % (2 * d) || h % (2 * d)) return 0;
    *outWidth = w / d; *outHeight = h / d;
    if (sq_frame_reduced_422(f)) return (w / d) * (h / d) * 2 * (downloadFormat(f->frame) == AV_PIX_FMT_P010LE ? 2 : 1);
    return av_image_get_buffer_size(downloadFormat(f->frame), w / d, h / d, 1);
}

int sq_frame_reduced_422(const SQFFFrame *f) {
    const AVFrame *s = f->frame;
    if (s->format == kHwFormat) return 0;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get((AVPixelFormat)s->format);
    return d && d->comp[0].depth > 8 && d->log2_chroma_w == 1 && d->log2_chroma_h == 0 && d->nb_components >= 3
        && !(d->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL | AV_PIX_FMT_FLAG_BE)) ? 1 : 0;
}

int sq_frame_download_reduced(const SQFFFrame *f, int divisor, int threads, uint8_t *buf, int cap) {
    const AVFrame *src = f->frame;
    int w = src->width, h = src->height, d = divisor < 1 ? 1 : divisor;
    if (w % (2 * d) || h % (2 * d)) return 1;
    bool deep = downloadFormat(src) == AV_PIX_FMT_P010LE;
    int W = w / d, H = h / d;
    bool v422 = sq_frame_reduced_422(f) != 0;
    int need = v422 ? W * H * 2 * (deep ? 2 : 1) : av_image_get_buffer_size(deep ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12, W, H, 1);
    if (cap < need) return AVERROR(ENOSPC);
    AVFrame *sw = nullptr;
    int e = 0;
    if (src->format == kHwFormat) {
        sw = av_frame_alloc();
        if ((e = av_hwframe_transfer_data(sw, src, 0)) < 0) { av_frame_free(&sw); return e; }
        src = sw;
    }
    Planes p; int bits = 8;
    if (!planesOf(src, p, bits) || (bits > 8) != deep) { av_frame_free(&sw); return 1; }   // not this format
    int n = threads < 1 ? 1 : threads > 16 ? 16 : threads;
    if ((long long)W * H < 512 * 512) n = 1;
    // Bands of whole chroma rows (even luma rows).
    int rows = ((H / 2 + n - 1) / n) * 2;
    auto band = [&](int i) {
        int y0 = i * rows, y1 = y0 + rows < H ? y0 + rows : H;
        if (y0 >= y1) return;
        if (bits > 8) {
            reduceBand<2, true>(p, buf, W, H, d, y0, y1, bits, v422);
        } else {
            reduceBand<1, false>(p, buf, W, H, d, y0, y1, bits, v422);
        }
    };
    std::vector<std::thread> pool;
    for (int i = 1; i < n; i++) pool.emplace_back(band, i);
    band(0);
    for (auto &t : pool) t.join();
    av_frame_free(&sw);
    return 0;
}

void sq_frame_free(SQFFFrame *f) {
    if (!f) return;
    av_frame_free(&f->frame);
    delete f;
}
