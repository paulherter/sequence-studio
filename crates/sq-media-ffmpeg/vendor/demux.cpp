#include <chrono>
#include <cstdlib>
// Video demux: one pass over the file at open records every packet of the best video stream (timing, flags, file
// position); samples are later read straight from the file by position.
// shortcut: only mov/mp4 skip the payload reads of the open pass (see FakeIO); other containers (MKV, MXF, TS) still read
// the whole file at open, upgrade them when long files of those open too slowly.
#include "common.h"
#include <algorithm>
#include <mutex>
#include <string.h>
#include <utility>
#include <vector>

struct SQFFDemux {
    int fastPaths = 0;   // SQ_FAST_INDEX_ONLY / SQ_FAST_SPS_FACTS
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

// Reads an EBML variable-length integer; `keepMarker` keeps the length bit (element IDs). False on a bad first byte.
static bool ebmlVint(AVIOContext *io, bool keepMarker, uint64_t *v, int *len) {
    int b = avio_r8(io);
    if (io->eof_reached || b == 0) return false;
    int n = 1;
    while (!(b & (0x80 >> (n - 1)))) n++;
    uint64_t r = keepMarker ? (uint64_t)b : (uint64_t)(b & (0xFF >> n));
    for (int i = 1; i < n; i++) r = (r << 8) | (uint64_t)avio_r8(io);
    *v = r; *len = n;
    return !io->eof_reached;
}

// Matroska/WebM report no usable file position (`pos` is not the payload and not even in file order), so the samples
// are located by walking the EBML tree once: the payload offset and size of every block, in file order, which is the
// order FFmpeg returns the packets in. The video track is the one whose block sizes equal the packet sizes. Unlaced blocks only, as video has.
struct MkvBlock { int track; int64_t pos, size; };
static bool matroskaBlocks(AVIOContext *io, std::vector<MkvBlock> &out) {
    if (avio_seek(io, 0, SEEK_SET) < 0) return false;
    for (;;) {
        uint64_t id, size; int n, m;
        if (!ebmlVint(io, true, &id, &n)) return true;   // end of file
        if (!ebmlVint(io, false, &size, &m)) return false;
        if (id == 0x18538067 || id == 0x1F43B675 || id == 0xA0) continue;   // Segment, Cluster, BlockGroup: descend
        int64_t start = avio_tell(io);
        if (id == 0xA3 || id == 0xA1) {
            uint64_t t; int k;
            if (!ebmlVint(io, false, &t, &k)) return false;
            avio_rb16(io);
            int flags = avio_r8(io);
            if (io->eof_reached || (flags & 0x06)) return false;
            out.push_back({(int)t, avio_tell(io), (int64_t)size - (avio_tell(io) - start)});
        }
        if (avio_seek(io, start + (int64_t)size, SEEK_SET) < 0) return false;
    }
}


// mov/mp4 keep their whole packet index (timing, key flags, positions) in the moov box, so the open pass needs no payload.
// FakeIO hands the demuxer zeros for every read once the header is parsed: av_read_frame then walks the index without
// touching the (multi-GB) mdat. Only for files without fragments (a moof is parsed from the file after the header).
struct FakeIO {
    AVIOContext *in = nullptr, *pb = nullptr;
    bool fake = false;
    int64_t pos = 0, size = 0;
};
static int fakeRead(void *o, uint8_t *buf, int n) {
    FakeIO *f = (FakeIO *)o;
    if (f->fake) {
        int64_t left = f->size - f->pos;
        if (left <= 0) return AVERROR_EOF;
        if (n > left) n = (int)left;
        // No memset: the demuxer never looks at the payload here, and zeroing a multi-GB mdat took over a second at open
        // (fresh large allocations are zero pages anyway).
        if (n <= 4096) memset(buf, 0, (size_t)n);
        f->pos += n;
        return n;
    }
    if (avio_seek(f->in, f->pos, SEEK_SET) < 0) return AVERROR(EIO);
    int r = avio_read(f->in, buf, n);
    if (r > 0) f->pos += r;
    return r > 0 ? r : AVERROR_EOF;
}
static int64_t fakeSeek(void *o, int64_t off, int whence) {
    FakeIO *f = (FakeIO *)o;
    if (whence & AVSEEK_SIZE) return f->size;
    whence &= ~AVSEEK_FORCE;
    int64_t p = whence == SEEK_SET ? off : whence == SEEK_CUR ? f->pos + off : f->size + off;
    if (p < 0) return AVERROR(EINVAL);
    f->pos = p;
    return p;
}
// True for an ISO-BMFF file with a moov and no moof/mvex-style fragment at the top level (boxes walked by seeking). The box
// types are read big endian, so they are compared as MKBETAG (MKTAG is little endian and never matched: the payload-free
// index below never ran and every mov/mp4 open read the whole file).
static bool isPlainMov(const char *path) {
    AVIOContext *io = nullptr;
    if (avio_open(&io, path, AVIO_FLAG_READ) < 0) return false;
    int64_t size = avio_size(io), pos = 0;
    bool moov = false, first = true, ok = true;
    while (pos + 8 <= size) {
        if (avio_seek(io, pos, SEEK_SET) < 0) { ok = false; break; }
        uint64_t len = avio_rb32(io);
        uint32_t type = avio_rb32(io);
        if (first && type != MKBETAG('f', 't', 'y', 'p') && type != MKBETAG('m', 'o', 'o', 'v') && type != MKBETAG('w', 'i', 'd', 'e')
            && type != MKBETAG('f', 'r', 'e', 'e') && type != MKBETAG('m', 'd', 'a', 't')) { ok = false; break; }
        first = false;
        if (type == MKBETAG('m', 'o', 'o', 'f') || type == MKBETAG('s', 'i', 'd', 'x')) { ok = false; break; }
        if (type == MKBETAG('m', 'o', 'o', 'v')) moov = true;
        if (len == 1) len = avio_rb64(io);
        else if (len == 0) break;   // box runs to the end
        if (len < 8) { ok = false; break; }
        pos += (int64_t)len;
    }
    avio_closep(&io);
    return ok && moov;
}
static void closeFmt(AVFormatContext **fmt, FakeIO *fio) {
    avformat_close_input(fmt);   // custom IO: the context's pb is ours to free
    if (!fio) return;
    if (fio->pb) { av_freep(&fio->pb->buffer); avio_context_free(&fio->pb); }
    avio_closep(&fio->in);
    delete fio;
}

static double sqNowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
#define SQ_STAGE(name) do { if (getenv("SQ_DEMUX_TIMING")) fprintf(stderr, "demux %s %s: %.0f ms\n", strrchr(path, 47) ? strrchr(path, 47) + 1 : path, name, sqNowMs() - t0); } while (0)
int sq_demux_open(const char *path, SQFFDemux **out, char *err, int errLen) { return sq_demux_open_with(path, 0, out, err, errLen); }
int sq_demux_open_with(const char *path, int fullProbe, SQFFDemux **out, char *err, int errLen) {
    const double t0 = sqNowMs();
    *out = nullptr;
    AVFormatContext *fmt = nullptr;
    FakeIO *fio = nullptr;
    AVPacket *pkt = av_packet_alloc();
    SQFFDemux *d = new SQFFDemux();
    memset(&d->info, 0, sizeof d->info);
    int e, vs;
    if (isPlainMov(path)) {
        fio = new FakeIO();
        if (avio_open(&fio->in, path, AVIO_FLAG_READ) < 0) { delete fio; fio = nullptr; }
        else {
            fio->size = avio_size(fio->in);
            const int bufSize = 1 << 15;
            fmt = avformat_alloc_context();
            fio->pb = avio_alloc_context((uint8_t *)av_malloc(bufSize), bufSize, 0, fio, fakeRead, nullptr, fakeSeek);
            fmt->pb = fio->pb;
            fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
        }
    }
    SQ_STAGE(fio ? "plain-mov check (plain mov/mp4)" : "plain-mov check (not a plain mov/mp4)");
    if ((e = avformat_open_input(&fmt, path, nullptr, nullptr)) < 0) { sqSetError(err, errLen, "open", e); goto fail; }
    SQ_STAGE("open_input");
    // An H.264 camera clip in a plain mov/mp4: the SPS gives what the probe would decode a picture for, so the probe is skipped.
    if (fio && !fullProbe) {
        const int v = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (v >= 0 && sqH264FactsFromSps(fmt->streams[v]->codecpar)) d->fastPaths |= SQ_FAST_SPS_FACTS;
    }
    if (!(d->fastPaths & SQ_FAST_SPS_FACTS) && (e = avformat_find_stream_info(fmt, nullptr)) < 0) { sqSetError(err, errLen, "stream info", e); goto fail; }
    SQ_STAGE("find_stream_info");
    if (fio) {
        // Header parsed: from here on payload reads return zeros (the index needs none).
        fio->fake = true;
        // The parsers would read the zeroed payload; the container's own flags and times are the index.
        fmt->flags |= AVFMT_FLAG_NOPARSE;
        d->fastPaths |= SQ_FAST_INDEX_ONLY;
    }
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
        in.bitsPerCodedSample = p->bits_per_coded_sample;
        in.codecTag = p->codec_tag;
        in.sarNum = p->sample_aspect_ratio.num; in.sarDen = p->sample_aspect_ratio.den;
        in.fieldOrder = (int)p->field_order;
        for (int i = 0; i < p->nb_coded_side_data; i++) {
            const AVPacketSideData &sd = p->coded_side_data[i];
            if (sd.type != AV_PKT_DATA_DOVI_CONF || sd.size < (int)sizeof(AVDOVIDecoderConfigurationRecord)) continue;
            const auto *r = (const AVDOVIDecoderConfigurationRecord *)sd.data;
            int bits = (r->dv_profile << 9) | (r->dv_level << 3) | (r->rpu_present_flag << 2) | (r->el_present_flag << 1) | r->bl_present_flag;
            in.hasDolbyVision = 1;
            in.dolbyVision[0] = r->dv_version_major; in.dolbyVision[1] = r->dv_version_minor;
            in.dolbyVision[2] = (uint8_t)(bits >> 8); in.dolbyVision[3] = (uint8_t)bits;
            in.dolbyVision[4] = (uint8_t)(r->dv_bl_signal_compatibility_id << 4);
            break;
        }
        if (p->extradata_size > 0) d->extradata.assign(p->extradata, p->extradata + p->extradata_size);
        if (getenv("SQ_DEMUX_TIMING")) fprintf(stderr, "info %s %dx%d fmt=%s prim=%d trc=%d mat=%d range=%d fr=%d/%d tb=%d/%d bits=%d field=%d extra=%d\n", strrchr(path, 47) + 1, p->width, p->height, in.pixFmt, p->color_primaries, p->color_trc, p->color_space, p->color_range, st->avg_frame_rate.num, st->avg_frame_rate.den, st->time_base.num, st->time_base.den, in.bitDepth, (int)p->field_order, p->extradata_size);
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
        SQ_STAGE("packet index");
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
    if (fmt->iformat && strstr(fmt->iformat->name, "matroska")) {
        std::vector<MkvBlock> blocks;
        bool ok = matroskaBlocks(d->io, blocks);
        std::vector<int> tracks;
        for (auto &b : blocks) if (std::find(tracks.begin(), tracks.end(), b.track) == tracks.end()) tracks.push_back(b.track);
        ok = false;
        for (int t : tracks) {
            std::vector<MkvBlock> mine;
            for (auto &b : blocks) if (b.track == t) mine.push_back(b);
            bool same = mine.size() == d->packets.size();
            for (size_t i = 0; same && i < mine.size(); i++) same = mine[i].size == d->packets[i].size;
            if (!same) continue;
            for (size_t i = 0; i < mine.size(); i++) d->packets[i].pos = mine[i].pos;
            ok = true;
            break;
        }
        if (!ok) { snprintf(err, errLen, "unreadable matroska blocks"); e = AVERROR_INVALIDDATA; goto fail; }
    }
    closeFmt(&fmt, fio);
    av_packet_free(&pkt);
    *out = d;
    return 0;
fail:
    closeFmt(&fmt, fio);
    av_packet_free(&pkt);
    delete d;
    return e < 0 ? e : -1;
}

// Seek facts for the proxy policy: the codec name and the key flags of the first video packets in decode order. No picture
// is decoded and the file is not indexed: a plain mov/mp4 walks its moov index through FakeIO (no payload read), every other
// container reads packets until `maxPackets` video packets or about `maxBytes` of payload (never fewer than 16 packets).
int sq_seek_probe(const char *path, int maxPackets, int64_t maxBytes, char *codec, int codecLen, uint8_t *keys, int *count,
                  char *err, int errLen) {
    *count = 0;
    if (codecLen > 0) codec[0] = 0;
    AVFormatContext *fmt = nullptr;
    FakeIO *fio = nullptr;
    AVDictionary *opts = nullptr;
    AVPacket *pkt = av_packet_alloc();
    int e = 0, vs;
    int64_t bytes = 0, reads = 0;
    if (isPlainMov(path)) {
        fio = new FakeIO();
        if (avio_open(&fio->in, path, AVIO_FLAG_READ) < 0) { delete fio; fio = nullptr; }
        else {
            fio->size = avio_size(fio->in);
            const int bufSize = 1 << 15;
            fmt = avformat_alloc_context();
            fio->pb = avio_alloc_context((uint8_t *)av_malloc(bufSize), bufSize, 0, fio, fakeRead, nullptr, fakeSeek);
            fmt->pb = fio->pb;
            fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
        }
    }
    // A small probe window for the containers that need one (the codec id of most is in the header already).
    av_dict_set(&opts, "probesize", "1048576", 0);
    av_dict_set(&opts, "analyzeduration", "500000", 0);
    e = avformat_open_input(&fmt, path, nullptr, &opts);
    av_dict_free(&opts);
    if (e < 0) { sqSetError(err, errLen, "open", e); goto fail; }
    if (fio) {
        // The moov told everything: payload reads return zeros from here on, the container's own key flags are the index.
        fio->fake = true;
        fmt->flags |= AVFMT_FLAG_NOPARSE;
    } else if ((e = avformat_find_stream_info(fmt, nullptr)) < 0) { sqSetError(err, errLen, "stream info", e); goto fail; }
    vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vs < 0) { sqSetError(err, errLen, "no video stream", vs); e = vs; goto fail; }
    snprintf(codec, codecLen, "%s", avcodec_get_name(fmt->streams[vs]->codecpar->codec_id));
    for (unsigned i = 0; i < fmt->nb_streams; i++) if ((int)i != vs) fmt->streams[i]->discard = AVDISCARD_ALL;
    while (*count < maxPackets && reads < (int64_t)maxPackets * 4 && (e = av_read_frame(fmt, pkt)) >= 0) {
        reads++;
        bytes += pkt->size;
        if (pkt->stream_index == vs) keys[(*count)++] = (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
        av_packet_unref(pkt);
        if (!fio && bytes >= maxBytes && *count >= 16) break;
    }
    if (*count == 0) { if (e >= 0 || e == AVERROR_EOF) e = AVERROR_INVALIDDATA; sqSetError(err, errLen, "read", e); goto fail; }
    closeFmt(&fmt, fio);
    av_packet_free(&pkt);
    return 0;
fail:
    closeFmt(&fmt, fio);
    av_packet_free(&pkt);
    return e < 0 ? e : -1;
}

void sq_demux_close(SQFFDemux *d) {
    if (!d) return;
    avio_closep(&d->io);
    delete d;
}

void sq_demux_info(const SQFFDemux *d, SQFFVideoInfo *info) { *info = d->info; }
int sq_demux_fast_paths(const SQFFDemux *d) { return d->fastPaths; }
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
