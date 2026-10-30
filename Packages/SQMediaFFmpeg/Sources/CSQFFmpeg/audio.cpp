// Audio decode: the best audio stream of a file, resampled once to interleaved float.
#include "common.h"
#include <stdlib.h>
#include <string.h>
#include <vector>

int sq_audio_decode(const char *path, int sampleRate, int channels, SQFFAudio *out, char *err, int errLen) {
    memset(out, 0, sizeof *out);
    AVFormatContext *fmt = nullptr;
    AVCodecContext *ctx = nullptr;
    SwrContext *swr = nullptr;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    std::vector<float> pcm;
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, channels);
    int e, as;
    auto drain = [&](bool flush) -> int {
        while (true) {
            int r = avcodec_receive_frame(ctx, fr);
            if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
            if (r < 0) return r;
            int cap = (int)av_rescale_rnd(swr_get_delay(swr, ctx->sample_rate) + fr->nb_samples, sampleRate,
                                          ctx->sample_rate, AV_ROUND_UP);
            size_t at = pcm.size();
            pcm.resize(at + (size_t)cap * channels);
            uint8_t *dst = (uint8_t *)(pcm.data() + at);
            int n = swr_convert(swr, &dst, cap, (const uint8_t **)fr->extended_data, fr->nb_samples);
            if (n < 0) return n;
            pcm.resize(at + (size_t)n * channels);
            av_frame_unref(fr);
        }
        (void)flush;
    };
    if ((e = avformat_open_input(&fmt, path, nullptr, nullptr)) < 0) { sqSetError(err, errLen, "open", e); goto done; }
    if ((e = avformat_find_stream_info(fmt, nullptr)) < 0) { sqSetError(err, errLen, "stream info", e); goto done; }
    as = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (as < 0) { e = as; sqSetError(err, errLen, "no audio stream", e); goto done; }
    {
        AVCodecParameters *p = fmt->streams[as]->codecpar;
        const AVCodec *codec = avcodec_find_decoder(p->codec_id);
        if (!codec) { e = AVERROR_DECODER_NOT_FOUND; sqSetError(err, errLen, "no decoder", e); goto done; }
        ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(ctx, p);
        if ((e = avcodec_open2(ctx, codec, nullptr)) < 0) { sqSetError(err, errLen, "codec open", e); goto done; }
        if (ctx->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_default(&ctx->ch_layout, ctx->ch_layout.nb_channels);
        if ((e = swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, sampleRate, &ctx->ch_layout, ctx->sample_fmt,
                                     ctx->sample_rate, 0, nullptr)) < 0 || (e = swr_init(swr)) < 0) {
            sqSetError(err, errLen, "resampler", e); goto done;
        }
        for (unsigned i = 0; i < fmt->nb_streams; i++) if ((int)i != as) fmt->streams[i]->discard = AVDISCARD_ALL;
        while ((e = av_read_frame(fmt, pkt)) >= 0) {
            if (pkt->stream_index == as) {
                if ((e = avcodec_send_packet(ctx, pkt)) < 0 && e != AVERROR(EAGAIN)) { sqSetError(err, errLen, "decode", e); goto done; }
                if ((e = drain(false)) < 0) { sqSetError(err, errLen, "decode", e); goto done; }
            }
            av_packet_unref(pkt);
        }
        avcodec_send_packet(ctx, nullptr);
        if ((e = drain(true)) < 0) { sqSetError(err, errLen, "decode", e); goto done; }
        // Resampler tail.
        int tail = (int)av_rescale_rnd(swr_get_delay(swr, ctx->sample_rate), sampleRate, ctx->sample_rate, AV_ROUND_UP);
        if (tail > 0) {
            size_t at = pcm.size();
            pcm.resize(at + (size_t)tail * channels);
            uint8_t *dst = (uint8_t *)(pcm.data() + at);
            int n = swr_convert(swr, &dst, tail, nullptr, 0);
            pcm.resize(at + (size_t)std::max(0, n) * channels);
        }
        out->frames = (int64_t)(pcm.size() / channels);
        out->channels = channels;
        out->sampleRate = sampleRate;
        out->sourceChannels = ctx->ch_layout.nb_channels;
        out->samples = (float *)malloc(std::max<size_t>(1, pcm.size()) * sizeof(float));
        memcpy(out->samples, pcm.data(), pcm.size() * sizeof(float));
        e = 0;
    }
done:
    av_channel_layout_uninit(&outLayout);
    swr_free(&swr);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    av_packet_free(&pkt);
    av_frame_free(&fr);
    return e < 0 ? e : 0;
}

void sq_audio_free(SQFFAudio *a) {
    free(a->samples);
    a->samples = nullptr;
}
