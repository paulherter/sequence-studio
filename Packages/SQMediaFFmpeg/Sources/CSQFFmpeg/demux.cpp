// Video demux: one pass over the file at open records every packet of the best video stream (timing, flags, file
// position); samples are later read straight from the file by position.
// shortcut: the open pass reads the whole file (slow for hour-long media); upgrade to the container's own sample table
// (mov/mp4 index entries plus ctts) when long files open too slowly.
#include "common.h"
#include <mutex>
#include <string.h>
#include <vector>

struct SQFFDemux {
    std::vector<SQFFPacket> packets;
    std::vector<uint8_t> extradata;
    SQFFVideoInfo info;
    AVIOContext *io = nullptr;
    std::mutex lock;
};

static int rotationOf(AVStream *st) {
    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * 4) return 0;
    double r = -av_display_rotation_get((const int32_t *)sd->data);   // counterclockwise -> clockwise
    int deg = ((int)lround(r / 90.0) * 90) % 360;
    return deg < 0 ? deg + 360 : deg;
}

int sq_demux_open(const char *path, SQFFDemux **out, char *err, int errLen) {
    *out = nullptr;
    AVFormatContext *fmt = nullptr;
    AVPacket *pkt = av_packet_alloc();
    SQFFDemux *d = new SQFFDemux();
    memset(&d->info, 0, sizeof d->info);
    int e, vs;
    if ((e = avformat_open_input(&fmt, path, nullptr, nullptr)) < 0) { sqSetError(err, errLen, "open", e); goto fail; }
    if ((e = avformat_find_stream_info(fmt, nullptr)) < 0) { sqSetError(err, errLen, "stream info", e); goto fail; }
    vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vs < 0) { sqSetError(err, errLen, "no video stream", vs); e = vs; goto fail; }
    {
        AVStream *st = fmt->streams[vs];
        AVCodecParameters *p = st->codecpar;
        for (unsigned i = 0; i < fmt->nb_streams; i++) if ((int)i != vs) fmt->streams[i]->discard = AVDISCARD_ALL;
        SQFFVideoInfo &in = d->info;
        in.width = p->width; in.height = p->height;
        in.tbNum = st->time_base.num; in.tbDen = st->time_base.den;
        in.frNum = st->avg_frame_rate.num; in.frDen = st->avg_frame_rate.den;
        in.rotation = rotationOf(st);
        const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get((AVPixelFormat)p->format);
        in.bitDepth = pd ? pd->comp[0].depth : 8;
        snprintf(in.codec, sizeof in.codec, "%s", avcodec_get_name(p->codec_id));
        snprintf(in.pixFmt, sizeof in.pixFmt, "%s", pd ? pd->name : "unknown");
        in.colorPrimaries = p->color_primaries; in.colorTransfer = p->color_trc; in.colorMatrix = p->color_space;
        in.colorRange = p->color_range;
        if (p->extradata_size > 0) d->extradata.assign(p->extradata, p->extradata + p->extradata_size);
        while ((e = av_read_frame(fmt, pkt)) >= 0) {
            if (pkt->stream_index == vs) {
                SQFFPacket x;
                x.pts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
                x.dts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
                x.duration = pkt->duration;
                x.pos = pkt->pos;
                x.size = pkt->size;
                x.key = (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
                d->packets.push_back(x);
            }
            av_packet_unref(pkt);
        }
        if (e != AVERROR_EOF) { sqSetError(err, errLen, "read", e); goto fail; }
        // Missing durations (some muxers): the distance to the next pts in presentation order, else one frame.
        int64_t frameTicks = 0;
        if (in.frNum > 0 && in.frDen > 0)
            frameTicks = av_rescale_q(1, AVRational{in.frDen, in.frNum}, st->time_base);
        std::vector<int64_t> sorted;
        for (auto &x : d->packets) sorted.push_back(x.pts);
        std::sort(sorted.begin(), sorted.end());
        for (auto &x : d->packets) {
            if (x.duration > 0) continue;
            auto it = std::upper_bound(sorted.begin(), sorted.end(), x.pts);
            x.duration = it != sorted.end() ? *it - x.pts : (frameTicks > 0 ? frameTicks : 1);
        }
        // A still picture opened by the image2 demuxer (a lone JPEG or PNG) reports no file position: its one packet is
        // the whole file.
        const bool lonePicture = fmt->iformat && strcmp(fmt->iformat->name, "image2") == 0 && d->packets.size() == 1;
        for (auto &x : d->packets) {
            if (x.pos < 0 && lonePicture) x.pos = 0;
            if (x.pos < 0) { snprintf(err, errLen, "packet without file position"); e = AVERROR_INVALIDDATA; goto fail; }
        }
    }
    if ((e = avio_open(&d->io, path, AVIO_FLAG_READ)) < 0) { sqSetError(err, errLen, "reopen", e); goto fail; }
    avformat_close_input(&fmt);
    av_packet_free(&pkt);
    *out = d;
    return 0;
fail:
    avformat_close_input(&fmt);
    av_packet_free(&pkt);
    delete d;
    return e < 0 ? e : -1;
}

void sq_demux_close(SQFFDemux *d) {
    if (!d) return;
    avio_closep(&d->io);
    delete d;
}

void sq_demux_info(const SQFFDemux *d, SQFFVideoInfo *info) { *info = d->info; }
int sq_demux_packet_count(const SQFFDemux *d) { return (int)d->packets.size(); }
const SQFFPacket *sq_demux_packets(const SQFFDemux *d) { return d->packets.data(); }
const uint8_t *sq_demux_extradata(const SQFFDemux *d, int *size) {
    *size = (int)d->extradata.size();
    return d->extradata.empty() ? nullptr : d->extradata.data();
}

int sq_demux_read(SQFFDemux *d, int ordinal, uint8_t *buf, int cap) {
    if (ordinal < 0 || ordinal >= (int)d->packets.size()) return AVERROR(EINVAL);
    const SQFFPacket &p = d->packets[ordinal];
    if (cap < p.size) return AVERROR(ENOSPC);
    std::lock_guard<std::mutex> g(d->lock);
    int64_t at = avio_seek(d->io, p.pos, SEEK_SET);
    if (at < 0) return (int)at;
    int n = avio_read(d->io, buf, p.size);
    return n == p.size ? 0 : AVERROR(EIO);
}
