// Still image decode for numbered image sequences: whatever FFmpeg reads (PNG, TIFF, EXR, DPX, TGA ...) as 8-bit RGBA.
#include "common.h"

static int imageOpen(const char *path, AVFormatContext **fmt, AVCodecContext **ctx, int *stream) {
    int e = avformat_open_input(fmt, path, nullptr, nullptr);
    if (e < 0) return e;
    if ((e = avformat_find_stream_info(*fmt, nullptr)) < 0) return e;
    *stream = av_find_best_stream(*fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (*stream < 0) return *stream;
    return 0;
}

int sq_image_size(const char *path, int *width, int *height) {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *ctx = nullptr;
    int s = -1;
    int e = imageOpen(path, &fmt, &ctx, &s);
    if (e == 0) { *width = fmt->streams[s]->codecpar->width; *height = fmt->streams[s]->codecpar->height; }
    avformat_close_input(&fmt);
    return e;
}

int sq_image_decode_rgba(const char *path, uint8_t *buf, int cap) {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *ctx = nullptr;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    SwsContext *sws = nullptr;
    int s = -1;
    int e = imageOpen(path, &fmt, &ctx, &s);
    if (e < 0) goto done;
    {
        AVCodecParameters *p = fmt->streams[s]->codecpar;
        const AVCodec *codec = avcodec_find_decoder(p->codec_id);
        if (!codec) { e = AVERROR_DECODER_NOT_FOUND; goto done; }
        ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(ctx, p);
        if ((e = avcodec_open2(ctx, codec, nullptr)) < 0) goto done;
        bool got = false;
        while (!got && (e = av_read_frame(fmt, pkt)) >= 0) {
            if (pkt->stream_index == s && avcodec_send_packet(ctx, pkt) >= 0 && avcodec_receive_frame(ctx, fr) >= 0) got = true;
            av_packet_unref(pkt);
        }
        if (!got) {
            avcodec_send_packet(ctx, nullptr);
            got = avcodec_receive_frame(ctx, fr) >= 0;
        }
        if (!got) { e = AVERROR_INVALIDDATA; goto done; }
        int w = fr->width, h = fr->height;
        if ((int64_t)w * h * 4 > cap) { e = AVERROR(ENOSPC); goto done; }
        sws = sws_getContext(w, h, (AVPixelFormat)fr->format, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!sws) { e = AVERROR(EINVAL); goto done; }
        uint8_t *dst[4] = {buf, nullptr, nullptr, nullptr};
        int dstStride[4] = {w * 4, 0, 0, 0};
        sws_scale(sws, fr->data, fr->linesize, 0, h, dst, dstStride);
        e = 0;
    }
done:
    sws_freeContext(sws);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    av_packet_free(&pkt);
    av_frame_free(&fr);
    return e < 0 ? e : 0;
}
