// FFmpeg (LGPL shared build): decode the first video frame, d3d11va when possible, as RGBA.
#include "csqwin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
}

static AVPixelFormat pickD3D11(AVCodecContext *, const AVPixelFormat *f) {
    for (; *f != AV_PIX_FMT_NONE; f++)
        if (*f == AV_PIX_FMT_D3D11) return *f;
    return AV_PIX_FMT_NONE;
}

static int tryDecode(const char *path, int hw, SQDecoded *out, char *err, int errLen) {
    AVFormatContext *fmt = NULL;
    AVCodecContext *ctx = NULL;
    AVBufferRef *hwdev = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc(), *sw = av_frame_alloc();
    int rc = -1, vs = -1;
    char eb[128];
    #define FAIL(msg, code) do { av_strerror(code, eb, sizeof eb); snprintf(err, errLen, "%s: %s", msg, eb); goto done; } while (0)
    int e;
    int64_t t1 = 0;
    bool got = false;
    int64_t t0 = av_gettime_relative();
    if ((e = avformat_open_input(&fmt, path, NULL, NULL)) < 0) FAIL("open", e);
    if ((e = avformat_find_stream_info(fmt, NULL)) < 0) FAIL("stream info", e);
    vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vs < 0) FAIL("no video stream", vs);
    {
        const AVCodec *codec = avcodec_find_decoder(fmt->streams[vs]->codecpar->codec_id);
        if (!codec) FAIL("no decoder", AVERROR_DECODER_NOT_FOUND);
        ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(ctx, fmt->streams[vs]->codecpar);
        if (hw) {
            if ((e = av_hwdevice_ctx_create(&hwdev, AV_HWDEVICE_TYPE_D3D11VA, NULL, NULL, 0)) < 0) FAIL("d3d11va device", e);
            ctx->hw_device_ctx = av_buffer_ref(hwdev);
            ctx->get_format = pickD3D11;
        }
        if ((e = avcodec_open2(ctx, codec, NULL)) < 0) FAIL("codec open", e);
        snprintf(out->decoder, sizeof out->decoder, "%s (%s)", codec->name, hw ? "d3d11va hardware" : "software");
    }
    t1 = av_gettime_relative();
    out->openMs = (t1 - t0) / 1000.0;
    while (!got && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vs && avcodec_send_packet(ctx, pkt) >= 0) {
            int r = avcodec_receive_frame(ctx, fr);
            if (r == 0) got = true;
            else if (r != AVERROR(EAGAIN)) FAIL("receive", r);
        }
        av_packet_unref(pkt);
    }
    if (!got) { avcodec_send_packet(ctx, NULL); if (avcodec_receive_frame(ctx, fr) == 0) got = true; }
    if (!got) { snprintf(err, errLen, "no frame decoded"); goto done; }
    {
        AVFrame *src = fr;
        if (fr->format == AV_PIX_FMT_D3D11) {
            if ((e = av_hwframe_transfer_data(sw, fr, 0)) < 0) FAIL("hw download", e);
            src = sw;
        } else if (hw) {
            snprintf(err, errLen, "hardware requested, got pixel format %d", fr->format);
            goto done;
        }
        int64_t t2 = av_gettime_relative();
        out->firstFrameMs = (t2 - t1) / 1000.0;
        int w = fr->width, h = fr->height;
        SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)src->format, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
        if (!sws) { snprintf(err, errLen, "swscale context"); goto done; }
        out->rgba = (uint8_t *)malloc((size_t)w * h * 4);
        uint8_t *dst[4] = {out->rgba, NULL, NULL, NULL};
        int ds[4] = {w * 4, 0, 0, 0};
        sws_scale(sws, src->data, src->linesize, 0, h, dst, ds);
        sws_freeContext(sws);
        out->width = w; out->height = h;
        out->convertMs = (av_gettime_relative() - t2) / 1000.0;
        rc = 0;
    }
done:
    av_frame_free(&fr); av_frame_free(&sw); av_packet_free(&pkt);
    avcodec_free_context(&ctx); avformat_close_input(&fmt); av_buffer_unref(&hwdev);
    return rc;
}

int sq_decode_first_frame(const char *path, int hardware, SQDecoded *out, char *err, int errLen) {
    memset(out, 0, sizeof *out);
    err[0] = 0;
    if (hardware) {
        if (tryDecode(path, 1, out, err, errLen) == 0) return 0;
        fprintf(stderr, "hardware decode failed (%s), using software\n", err);
        free(out->rgba);
        memset(out, 0, sizeof *out);
    }
    return tryDecode(path, 0, out, err, errLen);
}

void sq_decoded_free(SQDecoded *d) { free(d->rgba); d->rgba = NULL; }
