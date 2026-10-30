// Export encode: H.264/HEVC video (hardware first: AMF, NVENC, Quick Sync, Media Foundation; then software) or ProRes
// (prores_ks, 10-bit 4:2:2 / 4:4:4:4), and AAC or integer PCM audio, muxed into MP4/MOV by the file extension; audio-only
// M4A / WAV / FLAC files; animated GIF (one palette per frame).
#include "common.h"
#include <cmath>
#include <string.h>
#include <vector>
extern "C" {
#include <libavutil/audio_fifo.h>
}

struct SQFFEncoder {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *video = nullptr, *audio = nullptr;
    AVStream *vst = nullptr, *ast = nullptr;
    AVFrame *vframe = nullptr, *aframe = nullptr;
    AVPacket *pkt = nullptr;
    AVAudioFifo *fifo = nullptr;
    SwsContext *sws = nullptr;
    AVPixelFormat swsFrom = AV_PIX_FMT_NONE;
    int64_t audioPts = 0;
    bool headerWritten = false;
    char videoName[64] = {0};
};

static int writePackets(SQFFEncoder *e, AVCodecContext *c, AVStream *st) {
    while (true) {
        int r = avcodec_receive_packet(c, e->pkt);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) return r;
        av_packet_rescale_ts(e->pkt, c->time_base, st->time_base);
        e->pkt->stream_index = st->index;
        if ((r = av_interleaved_write_frame(e->fmt, e->pkt)) < 0) return r;
    }
}

static AVCodecContext *openVideo(const SQFFEncodeConfig *cfg, const char *name, bool globalHeader, int bFrames) {
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec) return nullptr;
    AVCodecContext *c = avcodec_alloc_context3(codec);
    c->width = cfg->width; c->height = cfg->height;
    c->time_base = AVRational{cfg->fpsDen, cfg->fpsNum};
    c->framerate = AVRational{cfg->fpsNum, cfg->fpsDen};
    if (cfg->gif) {
        // Centisecond timestamps: the muxer writes each frame's delay as the gap to the next one.
        c->pix_fmt = AV_PIX_FMT_PAL8;
        c->time_base = AVRational{1, 100};
        av_opt_set_int(c->priv_data, "global_palette", 0, 0);   // a local color table per frame (the Mac: no global map)
    } else if (cfg->prores > 0) {
        // Intra-only: bitrate, GOP and B-frames do not apply; the profile sets the data rate (as AVFoundation).
        c->pix_fmt = cfg->prores == 5 ? AV_PIX_FMT_YUVA444P10LE : AV_PIX_FMT_YUV422P10LE;
        av_opt_set_int(c->priv_data, "profile", cfg->prores - 1, 0);
        av_opt_set(c->priv_data, "vendor", "apl0", 0);
    } else {
        c->pix_fmt = cfg->tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        if (strstr(name, "openh264")) c->pix_fmt = AV_PIX_FMT_YUV420P;
        c->bit_rate = cfg->bitrate;
        c->rc_max_rate = cfg->bitrate * 3 / 2;
        c->rc_buffer_size = (int)std::min<int64_t>(INT32_MAX, cfg->bitrate * 2);
        c->gop_size = cfg->gop;
        c->max_b_frames = bFrames;
    }
    if (!cfg->gif) {
        c->color_primaries = AVCOL_PRI_BT709; c->color_trc = AVCOL_TRC_BT709; c->colorspace = AVCOL_SPC_BT709;
        c->color_range = AVCOL_RANGE_MPEG;
    }
    if (globalHeader) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (cfg->tenBit && cfg->hevc) av_opt_set(c->priv_data, "profile", "main10", 0);
    if (avcodec_open2(c, codec, nullptr) < 0) { avcodec_free_context(&c); return nullptr; }
    return c;
}

int sq_enc_open(const SQFFEncodeConfig *cfg, SQFFEncoder **out, char *err, int errLen) {
    *out = nullptr;
    SQFFEncoder *e = new SQFFEncoder();
    int r;
    if ((r = avformat_alloc_output_context2(&e->fmt, nullptr, nullptr, cfg->path)) < 0) {
        sqSetError(err, errLen, "container", r); delete e; return r;
    }
    bool globalHeader = e->fmt->oformat->flags & AVFMT_GLOBALHEADER;
    static const char *h264HW[] = {"h264_amf", "h264_nvenc", "h264_qsv", "h264_mf", nullptr};
    static const char *hevcHW[] = {"hevc_amf", "hevc_nvenc", "hevc_qsv", "hevc_mf", nullptr};
    static const char *h264SW[] = {"libopenh264", nullptr};
    static const char *hevcSW[] = {nullptr};
    static const char *proresSW[] = {"prores_ks", nullptr};
    static const char *gifSW[] = {"gif", nullptr};
    const char **lists[2] = {cfg->hardware && cfg->prores == 0 && !cfg->gif ? (cfg->hevc ? hevcHW : h264HW) : nullptr,
                             cfg->gif ? gifSW : cfg->prores > 0 ? proresSW : cfg->hevc ? hevcSW : h264SW};
    for (int l = 0; l < 2 && !e->video && !cfg->noVideo; l++) {
        if (!lists[l]) continue;
        for (const char **n = lists[l]; *n && !e->video; n++) {
            e->video = openVideo(cfg, *n, globalHeader, cfg->bFrames);
            if (!e->video && cfg->bFrames > 0 && cfg->prores == 0 && !cfg->gif) e->video = openVideo(cfg, *n, globalHeader, 0);
            if (e->video) snprintf(e->videoName, sizeof e->videoName, "%s", *n);
        }
    }
    if (!e->video && !cfg->noVideo) { snprintf(err, errLen, "no %s encoder could be opened", cfg->gif ? "GIF" : cfg->prores > 0 ? "ProRes" : cfg->hevc ? "HEVC" : "H.264"); sq_enc_abort(e); return AVERROR_ENCODER_NOT_FOUND; }
    if (e->video) {
        e->vst = avformat_new_stream(e->fmt, nullptr);
        avcodec_parameters_from_context(e->vst->codecpar, e->video);
        e->vst->time_base = e->video->time_base;
        e->vst->avg_frame_rate = e->video->framerate;
        if (cfg->hevc && cfg->prores == 0) e->vst->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');   // QuickTime and browsers want hvc1
    }
    if (cfg->audioChannels > 0) {
        // PCM: 24-bit takes 32-bit samples (the top 24 bits are written); FLAC the same (16 or 24 bits).
        AVCodecID id = cfg->flac ? AV_CODEC_ID_FLAC : cfg->pcmBits == 16 ? AV_CODEC_ID_PCM_S16LE
                     : cfg->pcmBits == 24 ? AV_CODEC_ID_PCM_S24LE : cfg->pcmBits == 32 ? AV_CODEC_ID_PCM_S32LE : AV_CODEC_ID_AAC;
        const AVCodec *aac = avcodec_find_encoder(id);
        e->audio = aac ? avcodec_alloc_context3(aac) : nullptr;
        const char *aname = cfg->flac ? "FLAC" : cfg->pcmBits ? "PCM" : "AAC";
        if (!e->audio) { snprintf(err, errLen, "no %s encoder", aname); sq_enc_abort(e); return AVERROR_ENCODER_NOT_FOUND; }
        e->audio->sample_rate = cfg->audioRate;
        e->audio->sample_fmt = id == AV_CODEC_ID_AAC ? AV_SAMPLE_FMT_FLTP
                             : id == AV_CODEC_ID_PCM_S16LE || (cfg->flac && cfg->pcmBits <= 16) ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S32;
        if (cfg->flac) e->audio->bits_per_raw_sample = cfg->pcmBits <= 16 ? 16 : 24;
        av_channel_layout_default(&e->audio->ch_layout, cfg->audioChannels);
        e->audio->bit_rate = cfg->audioBitrate;
        e->audio->time_base = AVRational{1, cfg->audioRate};
        if (globalHeader) e->audio->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if ((r = avcodec_open2(e->audio, aac, nullptr)) < 0) { sqSetError(err, errLen, aname, r); sq_enc_abort(e); return r; }
        e->ast = avformat_new_stream(e->fmt, nullptr);
        avcodec_parameters_from_context(e->ast->codecpar, e->audio);
        e->ast->time_base = e->audio->time_base;
        // PCM encoders take any frame size (frame_size 0): the FIFO starts at 4 x 1024 frames and grows.
        e->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, cfg->audioChannels, std::max(e->audio->frame_size, 1024) * 4);
        if (!e->fifo) { snprintf(err, errLen, "audio buffer"); sq_enc_abort(e); return AVERROR(ENOMEM); }
        e->aframe = av_frame_alloc();
    }
    e->pkt = av_packet_alloc();
    if (e->video) {
        e->vframe = av_frame_alloc();
        e->vframe->format = e->video->pix_fmt;
        e->vframe->width = cfg->width; e->vframe->height = cfg->height;
        if ((r = av_frame_get_buffer(e->vframe, 0)) < 0) { sqSetError(err, errLen, "frame", r); sq_enc_abort(e); return r; }
    }
    if ((r = avio_open(&e->fmt->pb, cfg->path, AVIO_FLAG_WRITE)) < 0) { sqSetError(err, errLen, "create file", r); sq_enc_abort(e); return r; }
    AVDictionary *opts = nullptr;
    if (cfg->gif) {
        av_dict_set(&opts, "loop", "0", 0);   // loops forever
        av_dict_set_int(&opts, "final_delay", std::max(1, cfg->gifFinalDelay), 0);
    } else if (!strcmp(e->fmt->oformat->name, "mp4") || !strcmp(e->fmt->oformat->name, "mov") || !strcmp(e->fmt->oformat->name, "ipod")) {
        av_dict_set(&opts, "movflags", "+faststart", 0);
    }
    r = avformat_write_header(e->fmt, &opts);
    av_dict_free(&opts);
    if (r < 0) { sqSetError(err, errLen, "header", r); sq_enc_abort(e); return r; }
    e->headerWritten = true;
    *out = e;
    return 0;
}

const char *sq_enc_video_name(const SQFFEncoder *e) { return e->videoName; }

int sq_enc_video(SQFFEncoder *e, const uint8_t *pixels, const char *format, int stride, int64_t frameIndex) {
    if (!e->video) return AVERROR(EINVAL);
    AVPixelFormat from = av_get_pix_fmt(format);
    if (from == AV_PIX_FMT_NONE) return AVERROR(EINVAL);
    int w = e->video->width, h = e->video->height, r;
    if ((r = av_frame_make_writable(e->vframe)) < 0) return r;
    const uint8_t *src[4]; int ss[4];
    av_image_fill_arrays((uint8_t **)src, ss, pixels, from, w, h, 1);
    ss[0] = stride;
    if (from == e->video->pix_fmt) {
        av_image_copy2(e->vframe->data, e->vframe->linesize, (uint8_t *const *)src, ss, from, w, h);
    } else {
        if (!e->sws || e->swsFrom != from) {
            sws_freeContext(e->sws);
            e->sws = sws_getContext(w, h, from, w, h, e->video->pix_fmt, SWS_BICUBIC, nullptr, nullptr, nullptr);
            e->swsFrom = from;
            if (!e->sws) return AVERROR(EINVAL);
            // RGB input is full range Rec.709 light; the file is limited range Rec.709.
            const int *coeffs = sws_getCoefficients(SWS_CS_ITU709);
            sws_setColorspaceDetails(e->sws, coeffs, 1, coeffs, 0, 0, 1 << 16, 1 << 16);
        }
        sws_scale(e->sws, src, ss, 0, h, e->vframe->data, e->vframe->linesize);
    }
    e->vframe->pts = frameIndex;
    if ((r = avcodec_send_frame(e->video, e->vframe)) < 0) return r;
    return writePackets(e, e->video, e->vst);
}

static int encodeAudioFrames(SQFFEncoder *e, bool flush) {
    int fs = e->audio->frame_size > 0 ? e->audio->frame_size : 1024, r;
    while (av_audio_fifo_size(e->fifo) >= fs || (flush && av_audio_fifo_size(e->fifo) > 0)) {
        int n = std::min(fs, av_audio_fifo_size(e->fifo));
        av_frame_unref(e->aframe);
        e->aframe->nb_samples = n;
        e->aframe->format = e->audio->sample_fmt;
        e->aframe->sample_rate = e->audio->sample_rate;
        av_channel_layout_copy(&e->aframe->ch_layout, &e->audio->ch_layout);
        if ((r = av_frame_get_buffer(e->aframe, 0)) < 0) return r;
        if (e->audio->sample_fmt == AV_SAMPLE_FMT_FLTP) {
            av_audio_fifo_read(e->fifo, (void **)e->aframe->data, n);
        } else {
            // Integer PCM, interleaved: clamp, scale to full range, round.
            int ch = e->audio->ch_layout.nb_channels;
            std::vector<float> planar((size_t)n * ch);
            void *planes[8];
            for (int c = 0; c < ch && c < 8; c++) planes[c] = planar.data() + (size_t)c * n;
            av_audio_fifo_read(e->fifo, planes, n);
            bool s16 = e->audio->sample_fmt == AV_SAMPLE_FMT_S16;
            for (int i = 0; i < n; i++) {
                for (int c = 0; c < ch; c++) {
                    double v = std::max(-1.0, std::min(1.0, (double)planar[(size_t)c * n + i]));
                    if (s16) ((int16_t *)e->aframe->data[0])[(size_t)i * ch + c] = (int16_t)std::lround(std::min(v * 32768.0, 32767.0));
                    else ((int32_t *)e->aframe->data[0])[(size_t)i * ch + c] = (int32_t)std::llround(std::min(v * 2147483648.0, 2147483647.0));
                }
            }
        }
        e->aframe->pts = e->audioPts;
        e->audioPts += n;
        if ((r = avcodec_send_frame(e->audio, e->aframe)) < 0) return r;
        if ((r = writePackets(e, e->audio, e->ast)) < 0) return r;
    }
    return 0;
}

int sq_enc_audio(SQFFEncoder *e, const float *interleaved, int frames) {
    if (!e->audio || frames <= 0) return 0;
    int ch = e->audio->ch_layout.nb_channels;
    std::vector<float> planar((size_t)frames * ch);
    void *planes[8];
    for (int c = 0; c < ch && c < 8; c++) {
        float *p = planar.data() + (size_t)c * frames;
        for (int i = 0; i < frames; i++) p[i] = interleaved[(size_t)i * ch + c];
        planes[c] = p;
    }
    int r = av_audio_fifo_write(e->fifo, planes, frames);
    if (r < 0) return r;
    return encodeAudioFrames(e, false);
}

int sq_enc_finish(SQFFEncoder *e, char *err, int errLen) {
    int r = 0;
    if (e->audio && (r = encodeAudioFrames(e, true)) < 0) { sqSetError(err, errLen, "audio", r); sq_enc_abort(e); return r; }
    if (e->video && ((r = avcodec_send_frame(e->video, nullptr)) < 0 || (r = writePackets(e, e->video, e->vst)) < 0)) {
        sqSetError(err, errLen, "video flush", r); sq_enc_abort(e); return r;
    }
    if (e->audio && ((r = avcodec_send_frame(e->audio, nullptr)) < 0 || (r = writePackets(e, e->audio, e->ast)) < 0)) {
        sqSetError(err, errLen, "audio flush", r); sq_enc_abort(e); return r;
    }
    if ((r = av_write_trailer(e->fmt)) < 0) { sqSetError(err, errLen, "trailer", r); sq_enc_abort(e); return r; }
    e->headerWritten = false;
    sq_enc_abort(e);   // frees everything, the file is complete
    return 0;
}

void sq_enc_abort(SQFFEncoder *e) {
    if (!e) return;
    avcodec_free_context(&e->video);
    avcodec_free_context(&e->audio);
    av_frame_free(&e->vframe);
    av_frame_free(&e->aframe);
    av_packet_free(&e->pkt);
    if (e->fifo) av_audio_fifo_free(e->fifo);
    sws_freeContext(e->sws);
    if (e->fmt) {
        if (e->fmt->pb) avio_closep(&e->fmt->pb);
        avformat_free_context(e->fmt);
    }
    delete e;
}
