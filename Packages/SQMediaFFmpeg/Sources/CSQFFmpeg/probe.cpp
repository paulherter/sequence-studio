// Import probe: the container's streams and duration without indexing or decoding (the Windows side of
// MediaImporter.probe). Video detail that needs the packet table (frame rate mode, exact duration) comes from the demuxer.
#include "common.h"
#include <string.h>

int sq_probe(const char *path, SQFFProbe *out, char *err, int errLen) {
    memset(out, 0, sizeof *out);
    out->durationUs = -1;
    out->videoFrames = -1;
    AVFormatContext *fmt = nullptr;
    int e;
    if ((e = avformat_open_input(&fmt, path, nullptr, nullptr)) < 0) { sqSetError(err, errLen, "open", e); return e; }
    if ((e = avformat_find_stream_info(fmt, nullptr)) < 0) {
        sqSetError(err, errLen, "stream info", e);
        avformat_close_input(&fmt);
        return e;
    }
    snprintf(out->format, sizeof out->format, "%s", fmt->iformat ? fmt->iformat->name : "");
    if (fmt->duration != AV_NOPTS_VALUE) out->durationUs = fmt->duration;
    int vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vs >= 0 && !(fmt->streams[vs]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
        AVStream *st = fmt->streams[vs];
        out->hasVideo = 1;
        out->width = st->codecpar->width;
        out->height = st->codecpar->height;
        out->videoFrames = st->nb_frames > 0 ? st->nb_frames : -1;
        snprintf(out->videoCodec, sizeof out->videoCodec, "%s", avcodec_get_name(st->codecpar->codec_id));
    }
    int as = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (as >= 0) {
        AVCodecParameters *p = fmt->streams[as]->codecpar;
        out->hasAudio = 1;
        out->audioRate = p->sample_rate;
        out->audioChannels = p->ch_layout.nb_channels;
        snprintf(out->audioCodec, sizeof out->audioCodec, "%s", avcodec_get_name(p->codec_id));
    }
    avformat_close_input(&fmt);
    if (!out->hasVideo && !out->hasAudio) {
        if (err && errLen > 0) snprintf(err, errLen, "no video or audio stream");
        return AVERROR_STREAM_NOT_FOUND;
    }
    return 0;
}
