// Image-sequence stills (PNG, JPEG, TIFF, EXR): one frame through FFmpeg's image encoder, its packet is the file.
#include "common.h"
#include <string.h>

int sq_still_write(const char *path, const char *codecName, const uint8_t *pixels, const char *format, int stride,
                   int width, int height, int alpha, double quality, char *err, int errLen) {
    AVPixelFormat from = av_get_pix_fmt(format);
    const AVCodec *codec = avcodec_find_encoder_by_name(codecName);
    if (from == AV_PIX_FMT_NONE || !codec) { snprintf(err, errLen, "no %s image encoder", codecName); return AVERROR_ENCODER_NOT_FOUND; }
    bool jpeg = !strcmp(codecName, "mjpeg"), exr = !strcmp(codecName, "exr"), tiff = !strcmp(codecName, "tiff");
    bool deep = from == AV_PIX_FMT_RGBA64LE || from == AV_PIX_FMT_RGB48LE;
    AVPixelFormat to = jpeg ? AV_PIX_FMT_YUVJ444P
                     : exr ? AV_PIX_FMT_GBRAPF32LE
                     : tiff ? (alpha ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_RGB48LE)
                     : deep ? (alpha ? AV_PIX_FMT_RGBA64BE : AV_PIX_FMT_RGB48BE)
                     : (alpha ? AV_PIX_FMT_RGBA : AV_PIX_FMT_RGB24);
    AVCodecContext *c = avcodec_alloc_context3(codec);
    AVFrame *f = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    SwsContext *sws = nullptr;
    AVIOContext *io = nullptr;
    int r = 0;
    auto done = [&](int code, const char *what) {
        if (code < 0 && what) sqSetError(err, errLen, what, code);
        if (io) avio_closep(&io);
        sws_freeContext(sws);
        av_packet_free(&pkt);
        av_frame_free(&f);
        avcodec_free_context(&c);
        return code;
    };
    c->width = width; c->height = height;
    c->pix_fmt = to;
    c->time_base = AVRational{1, 25};
    c->color_primaries = AVCOL_PRI_BT709; c->color_trc = exr ? AVCOL_TRC_LINEAR : AVCOL_TRC_BT709;
    c->colorspace = jpeg ? AVCOL_SPC_BT470BG : AVCOL_SPC_RGB;
    c->color_range = AVCOL_RANGE_JPEG;
    if (jpeg) {
        // ImageIO's 0.95: qscale 2 (1 best .. 31).
        int q = std::max(1, std::min(31, (int)lround(1 + (1 - quality) * 30)));
        c->flags |= AV_CODEC_FLAG_QSCALE;
        c->global_quality = FF_QP2LAMBDA * q;
    }
    if (exr) {
        av_opt_set(c->priv_data, "format", "half", 0);
        av_opt_set(c->priv_data, "compression", "zip16", 0);
    }
    if ((r = avcodec_open2(c, codec, nullptr)) < 0) return done(r, "image encoder");
    f->format = to; f->width = width; f->height = height;
    f->color_primaries = c->color_primaries; f->color_trc = c->color_trc; f->colorspace = c->colorspace;
    f->color_range = c->color_range;
    if ((r = av_frame_get_buffer(f, 0)) < 0) return done(r, "frame");
    const uint8_t *src[4]; int ss[4];
    av_image_fill_arrays((uint8_t **)src, ss, pixels, from, width, height, 1);
    ss[0] = stride;
    if (from == to) {
        av_image_copy2(f->data, f->linesize, (uint8_t *const *)src, ss, from, width, height);
    } else {
        sws = sws_getContext(width, height, from, width, height, to, SWS_POINT | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT,
                             nullptr, nullptr, nullptr);
        if (!sws) return done(AVERROR(EINVAL), "convert");
        // JPEG: full-range BT.601 (JFIF) from full-range RGB.
        const int *coeffs = sws_getCoefficients(SWS_CS_ITU601);
        sws_setColorspaceDetails(sws, coeffs, 1, coeffs, 1, 0, 1 << 16, 1 << 16);
        sws_scale(sws, src, ss, 0, height, f->data, f->linesize);
    }
    if (jpeg) f->quality = c->global_quality;
    f->pts = 0;
    if ((r = avcodec_send_frame(c, f)) < 0 || (r = avcodec_send_frame(c, nullptr)) < 0) return done(r, "encode");
    if ((r = avio_open(&io, path, AVIO_FLAG_WRITE)) < 0) return done(r, "create file");
    while ((r = avcodec_receive_packet(c, pkt)) >= 0) {
        avio_write(io, pkt->data, pkt->size);
        av_packet_unref(pkt);
    }
    if (r != AVERROR_EOF && r != AVERROR(EAGAIN)) return done(r, "encode");
    return done(0, nullptr);
}
