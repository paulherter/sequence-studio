// Video decode: D3D11VA (frames stay D3D11 textures) or software, one AVCodecContext per decoder.
#include "common.h"
#include <string.h>
#include <thread>
#include <vector>

struct SQFFDecoder {
    AVCodecContext *ctx = nullptr;
    AVBufferRef *device = nullptr;
    AVPacket *pkt = nullptr;
    bool hardware = false;
    char name[96];
};

struct SQFFFrame {
    AVFrame *frame;
};

static AVPixelFormat pickD3D11(AVCodecContext *, const AVPixelFormat *f) {
    for (; *f != AV_PIX_FMT_NONE; f++)
        if (*f == AV_PIX_FMT_D3D11) return *f;
    return AV_PIX_FMT_NONE;   // no hardware path for this stream: decoding fails, the caller falls back to software
}

int sq_dec_open(const char *codecName, const uint8_t *extradata, int extradataSize, int width, int height, int tbNum,
                int tbDen, int hardware, int extraHWFrames, SQFFDecoder **out, char *err, int errLen) {
    *out = nullptr;
    const AVCodecDescriptor *desc = avcodec_descriptor_get_by_name(codecName);
    const AVCodec *codec = desc ? avcodec_find_decoder(desc->id) : nullptr;
    if (!codec) { sqSetError(err, errLen, "no decoder", AVERROR_DECODER_NOT_FOUND); return AVERROR_DECODER_NOT_FOUND; }
    SQFFDecoder *dec = new SQFFDecoder();
    int e;
    dec->ctx = avcodec_alloc_context3(codec);
    dec->pkt = av_packet_alloc();
    dec->ctx->width = width; dec->ctx->height = height;
    dec->ctx->pkt_timebase = AVRational{tbNum, tbDen};
    if (extradataSize > 0) {
        dec->ctx->extradata = (uint8_t *)av_mallocz(extradataSize + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(dec->ctx->extradata, extradata, extradataSize);
        dec->ctx->extradata_size = extradataSize;
    }
    if (hardware) {
        if ((e = av_hwdevice_ctx_create(&dec->device, AV_HWDEVICE_TYPE_D3D11VA, nullptr, nullptr, 0)) < 0) {
            sqSetError(err, errLen, "d3d11va device", e); sq_dec_close(dec); return e;
        }
        dec->ctx->hw_device_ctx = av_buffer_ref(dec->device);
        dec->ctx->get_format = pickD3D11;
        // Decoded frames handed out keep their pool texture until released: room for the frames playback holds.
        dec->ctx->extra_hw_frames = extraHWFrames;
        dec->hardware = true;
    } else {
        dec->ctx->thread_count = 0;   // automatic
    }
    if ((e = avcodec_open2(dec->ctx, codec, nullptr)) < 0) { sqSetError(err, errLen, "codec open", e); sq_dec_close(dec); return e; }
    snprintf(dec->name, sizeof dec->name, "%s (%s)", codec->name, hardware ? "d3d11va" : "software");
    *out = dec;
    return 0;
}

void sq_dec_close(SQFFDecoder *dec) {
    if (!dec) return;
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
    e = avcodec_send_packet(dec->ctx, dec->pkt);
    if (e == AVERROR(EAGAIN)) return 1;
    return e;
}

int sq_dec_receive(SQFFDecoder *dec, SQFFFrame **out) {
    *out = nullptr;
    AVFrame *f = av_frame_alloc();
    int e = avcodec_receive_frame(dec->ctx, f);
    if (e == AVERROR(EAGAIN)) { av_frame_free(&f); return 1; }
    if (e == AVERROR_EOF) { av_frame_free(&f); return 2; }
    if (e < 0) { av_frame_free(&f); return e; }
    if (dec->hardware && f->format != AV_PIX_FMT_D3D11) { av_frame_free(&f); return AVERROR(ENOSYS); }
    if (f->best_effort_timestamp != AV_NOPTS_VALUE) f->pts = f->best_effort_timestamp;
    *out = new SQFFFrame{f};
    return 0;
}

void sq_dec_flush(SQFFDecoder *dec) { avcodec_flush_buffers(dec->ctx); }

static AVPixelFormat pixelsOf(const AVFrame *f) {
    if (f->format == AV_PIX_FMT_D3D11 && f->hw_frames_ctx)
        return ((AVHWFramesContext *)f->hw_frames_ctx->data)->sw_format;
    return (AVPixelFormat)f->format;
}

void sq_frame_info(const SQFFFrame *f, SQFFFrameInfo *info) {
    memset(info, 0, sizeof *info);
    info->width = f->frame->width; info->height = f->frame->height;
    info->hardware = f->frame->format == AV_PIX_FMT_D3D11;
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

int sq_frame_download_size(const SQFFFrame *f) {
    return av_image_get_buffer_size(downloadFormat(f->frame), f->frame->width, f->frame->height, 1);
}

int sq_frame_download(const SQFFFrame *f, uint8_t *buf, int cap) {
    const AVFrame *src = f->frame;
    AVFrame *sw = nullptr;
    int e = 0;
    if (src->format == AV_PIX_FMT_D3D11) {
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
        SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)src->format, w, h, target, SWS_POINT, nullptr, nullptr, nullptr);
        if (!sws) { av_frame_free(&sw); return AVERROR(EINVAL); }
        sws_scale(sws, src->data, src->linesize, 0, h, dst, ds);
        sws_freeContext(sws);
    }
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

/// Output rows [y0, y1) (even) of the reduced picture: luma W x H, interleaved chroma (W/2) x (H/2) after it. `Deep`
/// writes 16-bit samples MSB-aligned (P010), else 8 bits.
template <int B, bool Deep>
void reduceRows(const Planes &p, uint8_t *out, int W, int H, int d, int y0, int y1, int bits) {
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
    // Chroma pair (cx, cy) covers luma [2d cx, 2d cx + 2d) x [2d cy, ...): in source chroma samples bw x bh from (bx, by).
    const int bw = 2 * d / p.sx, bh = 2 * d / p.sy, carea = bw * bh, chalf = carea / 2;
    const int CW = W / 2;
    uint8_t *cbase = out + (size_t)W * H * (Deep ? 2 : 1);
    for (int cy = y0 / 2; cy < y1 / 2; cy++) {
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
    return av_image_get_buffer_size(downloadFormat(f->frame), w / d, h / d, 1);
}

int sq_frame_download_reduced(const SQFFFrame *f, int divisor, int threads, uint8_t *buf, int cap) {
    const AVFrame *src = f->frame;
    int w = src->width, h = src->height, d = divisor < 1 ? 1 : divisor;
    if (w % (2 * d) || h % (2 * d)) return 1;
    bool deep = downloadFormat(src) == AV_PIX_FMT_P010LE;
    int W = w / d, H = h / d;
    if (cap < av_image_get_buffer_size(deep ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12, W, H, 1)) return AVERROR(ENOSPC);
    AVFrame *sw = nullptr;
    int e = 0;
    if (src->format == AV_PIX_FMT_D3D11) {
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
            reduceRows<2, true>(p, buf, W, H, d, y0, y1, bits);
        } else {
            reduceRows<1, false>(p, buf, W, H, d, y0, y1, bits);
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
