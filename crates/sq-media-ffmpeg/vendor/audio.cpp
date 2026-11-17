// Audio decode: the best audio stream of a file, resampled once to interleaved float.
#include "common.h"
#include <stdlib.h>
#include <string.h>
#include <vector>

// Audio stream `ordinal` (0-based among the audio streams) or, for a negative ordinal, the best one.
static int audioStreamIndex(AVFormatContext *fmt, int ordinal) {
    if (ordinal < 0) return av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    int n = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && n++ == ordinal) return (int)i;
    return AVERROR_STREAM_NOT_FOUND;
}

// The stream probe of a camera file decodes a picture of its 4K video (150 ms to over a second on a cold disk) just to
// report the audio, and the audio opens on the first Play: only the audio streams are probed here.
static int findAudioStreamInfo(AVFormatContext *fmt) {
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) fmt->streams[i]->discard = AVDISCARD_ALL;
    const int e = avformat_find_stream_info(fmt, nullptr);
    for (unsigned i = 0; i < fmt->nb_streams; i++) fmt->streams[i]->discard = AVDISCARD_DEFAULT;
    return e;
}

int sq_audio_track_channels(const char *path, int *counts, int cap) {
    AVFormatContext *fmt = nullptr;
    // A failure returns FFmpeg's own negative code, so the caller can say why (missing file, not a media file...).
    int e = avformat_open_input(&fmt, path, nullptr, nullptr);
    if (e < 0) return e;
    if ((e = findAudioStreamInfo(fmt)) < 0) { avformat_close_input(&fmt); return e; }
    int n = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        if (n < cap) counts[n] = fmt->streams[i]->codecpar->ch_layout.nb_channels;
        n++;
    }
    avformat_close_input(&fmt);
    return n;
}

int sq_audio_track_rates(const char *path, int *rates, int cap) {
    AVFormatContext *fmt = nullptr;
    int e = avformat_open_input(&fmt, path, nullptr, nullptr);
    if (e < 0) return e;
    if ((e = findAudioStreamInfo(fmt)) < 0) { avformat_close_input(&fmt); return e; }
    int n = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        if (n < cap) rates[n] = fmt->streams[i]->codecpar->sample_rate;
        n++;
    }
    avformat_close_input(&fmt);
    return n;
}

int sq_audio_decode(const char *path, int sampleRate, int channels, SQFFAudio *out, char *err, int errLen) {
    return sq_audio_decode_track(path, sampleRate, channels, -1, out, err, errLen);
}

int sq_audio_decode_track(const char *path, int sampleRate, int channels, int ordinal, SQFFAudio *out, char *err, int errLen) {
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
    if ((e = findAudioStreamInfo(fmt)) < 0) { sqSetError(err, errLen, "stream info", e); goto done; }
    as = audioStreamIndex(fmt, ordinal);
    if (as < 0) { e = as; sqSetError(err, errLen, "no audio stream", e); goto done; }
    {
        AVCodecParameters *p = fmt->streams[as]->codecpar;
        const AVCodec *codec = avcodec_find_decoder(p->codec_id);
        if (!codec) { e = AVERROR_DECODER_NOT_FOUND; sqSetError(err, errLen, "no decoder", e); goto done; }
        ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(ctx, p);
        // AAC priming makes the decoder warn "Could not update timestamps for discarded samples" on many packets; the audio is fine.
        ctx->log_level_offset = 16;
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

// MARK: Streaming reader

struct SQFFAudioReader {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *ctx = nullptr;
    SwrContext *swr = nullptr;
    AVPacket *pkt = nullptr;
    AVFrame *fr = nullptr;
    AVChannelLayout outLayout{};
    int stream = -1, rate = 0, channels = 0;
    int64_t basePts = AV_NOPTS_VALUE;  // pts of the first decoded frame: output frame 0
    int64_t pendStart = 0;             // output frame index of pending[0] (negative: priming before frame 0)
    bool pendSet = false;              // false = adopt pendStart from the next frame's pts
    std::vector<float> pending;        // decoded, not yet delivered, interleaved
    bool eof = false;
    int64_t endFrames = -1;
    int64_t decoded() const { return pendStart + (int64_t)(pending.size() / channels); }
};

static bool readerInitSwr(SQFFAudioReader *r) {
    swr_free(&r->swr);
    return swr_alloc_set_opts2(&r->swr, &r->outLayout, AV_SAMPLE_FMT_FLT, r->rate, &r->ctx->ch_layout, r->ctx->sample_fmt,
                               r->ctx->sample_rate, 0, nullptr) >= 0 && swr_init(r->swr) >= 0;
}

// Appends what the decoder has ready (after a packet or the flush); true when frames were produced or more may come.
static int readerDrain(SQFFAudioReader *r) {
    while (true) {
        int e = avcodec_receive_frame(r->ctx, r->fr);
        if (e == AVERROR(EAGAIN) || e == AVERROR_EOF) return 0;
        if (e < 0) return e;
        if (r->basePts == AV_NOPTS_VALUE && r->fr->pts != AV_NOPTS_VALUE) r->basePts = r->fr->pts;
        if (!r->pendSet) {
            AVRational tb = r->fmt->streams[r->stream]->time_base;
            int64_t p = r->fr->pts == AV_NOPTS_VALUE || r->basePts == AV_NOPTS_VALUE ? 0 : r->fr->pts - r->basePts;
            r->pendStart = av_rescale_q(p, tb, AVRational{1, r->rate});
            r->pendSet = true;
        }
        int cap = (int)av_rescale_rnd(swr_get_delay(r->swr, r->ctx->sample_rate) + r->fr->nb_samples, r->rate,
                                      r->ctx->sample_rate, AV_ROUND_UP);
        size_t at = r->pending.size();
        r->pending.resize(at + (size_t)cap * r->channels);
        uint8_t *dst = (uint8_t *)(r->pending.data() + at);
        int n = swr_convert(r->swr, &dst, cap, (const uint8_t **)r->fr->extended_data, r->fr->nb_samples);
        av_frame_unref(r->fr);
        if (n < 0) return n;
        r->pending.resize(at + (size_t)n * r->channels);
    }
}

// Reads one more packet worth of audio; sets `eof` after the flush.
static int readerStep(SQFFAudioReader *r) {
    int e = av_read_frame(r->fmt, r->pkt);
    if (e == AVERROR_EOF || (e < 0 && r->fmt->pb && r->fmt->pb->eof_reached)) {
        avcodec_send_packet(r->ctx, nullptr);
        if ((e = readerDrain(r)) < 0) return e;
        int tail = (int)av_rescale_rnd(swr_get_delay(r->swr, r->ctx->sample_rate), r->rate, r->ctx->sample_rate, AV_ROUND_UP);
        if (tail > 0) {
            size_t at = r->pending.size();
            r->pending.resize(at + (size_t)tail * r->channels);
            uint8_t *dst = (uint8_t *)(r->pending.data() + at);
            int n = swr_convert(r->swr, &dst, tail, nullptr, 0);
            r->pending.resize(at + (size_t)std::max(0, n) * r->channels);
        }
        r->eof = true;
        if (r->pendSet) r->endFrames = r->decoded();
        return 0;
    }
    if (e < 0) return e;
    if (r->pkt->stream_index == r->stream) {
        int s = avcodec_send_packet(r->ctx, r->pkt);
        if (s < 0 && s != AVERROR(EAGAIN)) { av_packet_unref(r->pkt); return s; }
        av_packet_unref(r->pkt);
        return readerDrain(r);
    }
    av_packet_unref(r->pkt);
    return 0;
}

void sq_audio_reader_close(SQFFAudioReader *r) {
    if (!r) return;
    av_channel_layout_uninit(&r->outLayout);
    swr_free(&r->swr);
    avcodec_free_context(&r->ctx);
    avformat_close_input(&r->fmt);
    av_packet_free(&r->pkt);
    av_frame_free(&r->fr);
    delete r;
}

SQFFAudioReader *sq_audio_reader_open(const char *path, int sampleRate, int channels, int ordinal,
                                      int64_t *estimatedFrames, int *sourceChannels, char *err, int errLen) {
    SQFFAudioReader *r = new SQFFAudioReader();
    r->rate = sampleRate;
    r->channels = channels;
    r->pkt = av_packet_alloc();
    r->fr = av_frame_alloc();
    av_channel_layout_default(&r->outLayout, channels);
    int e;
    if ((e = avformat_open_input(&r->fmt, path, nullptr, nullptr)) < 0) { sqSetError(err, errLen, "open", e); goto fail; }
    if ((e = findAudioStreamInfo(r->fmt)) < 0) { sqSetError(err, errLen, "stream info", e); goto fail; }
    r->stream = audioStreamIndex(r->fmt, ordinal);
    if (r->stream < 0) { e = r->stream; sqSetError(err, errLen, "no audio stream", e); goto fail; }
    {
        AVStream *st = r->fmt->streams[r->stream];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (!codec) { e = AVERROR_DECODER_NOT_FOUND; sqSetError(err, errLen, "no decoder", e); goto fail; }
        r->ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(r->ctx, st->codecpar);
        r->ctx->log_level_offset = 16;
        if ((e = avcodec_open2(r->ctx, codec, nullptr)) < 0) { sqSetError(err, errLen, "codec open", e); goto fail; }
        if (r->ctx->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)
            av_channel_layout_default(&r->ctx->ch_layout, r->ctx->ch_layout.nb_channels);
        if (!readerInitSwr(r)) { e = AVERROR(EINVAL); sqSetError(err, errLen, "resampler", e); goto fail; }
        for (unsigned i = 0; i < r->fmt->nb_streams; i++) if ((int)i != r->stream) r->fmt->streams[i]->discard = AVDISCARD_ALL;
        *sourceChannels = r->ctx->ch_layout.nb_channels;
        double secs = -1;
        if (st->duration != AV_NOPTS_VALUE) secs = st->duration * av_q2d(st->time_base);
        else if (r->fmt->duration != AV_NOPTS_VALUE) secs = (double)r->fmt->duration / AV_TIME_BASE;
        *estimatedFrames = secs >= 0 ? (int64_t)llround(secs * sampleRate) : -1;
        r->pendSet = false;  // the first frame decides frame 0
        // Decode the first frame now: it fixes where frame 0 is, which later seeks count from.
        while (!r->pendSet && !r->eof) if ((e = readerStep(r)) < 0) { sqSetError(err, errLen, "decode", e); goto fail; }
    }
    return r;
fail:
    sq_audio_reader_close(r);
    return nullptr;
}

int sq_audio_reader_read(SQFFAudioReader *r, int64_t start, float *out, int frames) {
    if (start < 0 || frames <= 0) return 0;
    // Seek when the request is before what is held, or far beyond what is decoded (decoding through is cheaper for short hops).
    bool seek = r->pendSet && (start < r->pendStart || start > r->decoded() + (int64_t)r->rate * 5);
    if (seek) {
        AVStream *st = r->fmt->streams[r->stream];
        int64_t base = r->basePts == AV_NOPTS_VALUE ? 0 : r->basePts;
        // Back off a little so the decoder has its priming frames; frames before `start` are dropped below.
        int64_t from = start - r->rate / 2;  // may be negative: the demuxer then seeks to the first packet, priming included
        int64_t ts = base + av_rescale_q(from, AVRational{1, r->rate}, st->time_base);
        if (av_seek_frame(r->fmt, r->stream, ts, AVSEEK_FLAG_BACKWARD) < 0) return AVERROR(EIO);
        avcodec_flush_buffers(r->ctx);
        if (!readerInitSwr(r)) return AVERROR(EINVAL);
        r->pending.clear();
        r->pendSet = false;
        r->eof = false;
    }
    while (!r->eof && (!r->pendSet || r->decoded() < start + frames)) {
        int e = readerStep(r);
        if (e < 0) return e;
        // Drop what lies before the request so the buffer stays small.
        if (r->pendSet && r->pendStart < start) {
            int64_t drop = std::min<int64_t>(start - r->pendStart, (int64_t)(r->pending.size() / r->channels));
            r->pending.erase(r->pending.begin(), r->pending.begin() + (size_t)(drop * r->channels));
            r->pendStart += drop;
        }
    }
    if (!r->pendSet || start < r->pendStart) return 0;  // the seek landed after `start` (no data there) or nothing decoded
    int64_t have = r->decoded() - start;
    int n = (int)std::max<int64_t>(0, std::min<int64_t>(have, frames));
    memcpy(out, r->pending.data() + (size_t)((start - r->pendStart) * r->channels), (size_t)n * r->channels * sizeof(float));
    return n;
}

int64_t sq_audio_reader_end(const SQFFAudioReader *r) { return r->eof ? r->endFrames : -1; }
