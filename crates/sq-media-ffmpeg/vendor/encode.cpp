// Export encode: H.264/HEVC video (hardware first: VideoToolbox on the Mac; NVENC, AMF, Quick Sync, Media Foundation on
// Windows; VA-API on Linux; then software: x264 / x265 where the build has them, else OpenH264 / Kvazaar) or ProRes
// (prores_videotoolbox on the Mac, else prores_ks, 10-bit 4:2:2 / 4:4:4:4), and AAC or integer PCM audio, muxed into MP4/MOV by the file extension; audio-only
// M4A / WAV / FLAC files; animated GIF (one palette per frame).
#include <chrono>
#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <map>
#include <mutex>
#include <set>
#include "common.h"
#include <cmath>
#include <string.h>
#include <string>
#include <utility>
#include <vector>
extern "C" {
#include <libavutil/audio_fifo.h>
#include <libavutil/mastering_display_metadata.h>
}

// One audio track being written: encoder, stream, a frame and the FIFO that regroups samples into encoder frames.
struct AudioOut {
    AVCodecContext *ctx = nullptr;
    AVStream *st = nullptr;
    AVFrame *frame = nullptr;
    AVAudioFifo *fifo = nullptr;
    int64_t pts = 0;
};

// A packet that came out before the container header could be written (see `SQFFEncoder::deferHeader`).
struct HeldPacket {
    AVPacket *pkt;
    AVRational timeBase;   // the encoder's time base; the stream's is known only once the header is written
};

struct SQFFEncoder {
    AVFormatContext *fmt = nullptr;
    AVCodecContext *video = nullptr;
    AVStream *vst = nullptr;
    AVFrame *vframe = nullptr;
    AVPacket *pkt = nullptr;
    AudioOut a0;                  // the first audio track
    std::vector<AudioOut> extra;  // further audio tracks (conform writes every source track)
    SwsContext *sws = nullptr;
    AVPixelFormat swsFrom = AV_PIX_FMT_NONE;
    AVPixelFormat swFormat = AV_PIX_FMT_NONE;   // the layout of `vframe`: the encoder's own, or the sw_format behind a hardware surface
    int64_t lastPts = INT64_MIN;
    bool reordered = false;                     // a video packet came out with an earlier time than its predecessor (B-frames)
    bool headerWritten = false;
    // VA-API: the parameter sets in the stream are the driver's own and differ from the ones FFmpeg puts in the
    // extradata (on Mesa's AMD encoder: other QP-delta depth), and the MP4 muxer keeps only the extradata copy for the
    // hvc1 / avc1 tags, which then mismatches every slice. So the header waits for the first video packet and takes the
    // parameter sets from it; audio packets that arrive meanwhile are held.
    bool deferHeader = false;
    AVDictionary *headerOptions = nullptr;
    std::vector<HeldPacket> held;
    char videoName[64] = {0};
};

// Private options of one candidate encoder, from Rust (`options.rs`): key / value pairs applied to the codec context.
typedef std::vector<std::pair<std::string, std::string>> EncOptions;

// What one opening attempt asks for. The attempts get less ambitious until one works (see `openVideoAny`).
struct VideoTry {
    bool tenBit;
    int bFrames;
    bool planar420;   // planar 4:2:0 instead of NV12 / P010 (encoders that do not take the semi-planar layouts)
    bool useOptions;  // the Rust-chosen private options; off as the last resort so an encoder that refuses one still runs
};

// The parameter sets (HEVC VPS / SPS / PPS, H.264 SPS / PPS) of an Annex B packet, each behind a 4-byte start code.
static std::vector<uint8_t> parameterSetsOf(const AVPacket *p, bool hevc) {
    std::vector<uint8_t> out;
    const uint8_t *d = p->data;
    int n = p->size;
    std::vector<int> starts;
    for (int i = 0; i + 3 <= n; i++) if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { starts.push_back(i + 3); i += 2; }
    for (size_t k = 0; k < starts.size(); k++) {
        int begin = starts[k], end = k + 1 < starts.size() ? starts[k + 1] - 3 : n;
        while (end > begin && d[end - 1] == 0) end--;   // trailing zero bytes belong to the next start code
        if (end <= begin) continue;
        int type = hevc ? (d[begin] >> 1) & 0x3F : d[begin] & 0x1F;
        bool wanted = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
        if (!wanted) continue;
        const uint8_t code[4] = {0, 0, 0, 1};
        out.insert(out.end(), code, code + 4);
        out.insert(out.end(), d + begin, d + end);
    }
    return out;
}

// Writes the container header (taking the parameter sets from `first` when the header was deferred) and the packets held
// back until now.
static int openContainer(SQFFEncoder *e, const AVPacket *first) {
    if (first && e->deferHeader) {
        AVCodecParameters *par = e->vst->codecpar;
        std::vector<uint8_t> ps = parameterSetsOf(first, par->codec_id == AV_CODEC_ID_HEVC);
        if (!ps.empty()) {
            av_freep(&par->extradata);
            par->extradata = (uint8_t *)av_mallocz(ps.size() + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!par->extradata) return AVERROR(ENOMEM);
            memcpy(par->extradata, ps.data(), ps.size());
            par->extradata_size = (int)ps.size();
        }
    }
    int r = avformat_write_header(e->fmt, &e->headerOptions);
    av_dict_free(&e->headerOptions);
    if (r < 0) return r;
    e->headerWritten = true;
    for (HeldPacket &h : e->held) {
        AVStream *st = e->fmt->streams[h.pkt->stream_index];
        av_packet_rescale_ts(h.pkt, h.timeBase, st->time_base);
        r = av_interleaved_write_frame(e->fmt, h.pkt);
        av_packet_free(&h.pkt);
        if (r < 0) return r;
    }
    e->held.clear();
    return 0;
}

static int writePackets(SQFFEncoder *e, AVCodecContext *c, AVStream *st) {
    while (true) {
        int r = avcodec_receive_packet(c, e->pkt);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) return r;
        if (st == e->vst && e->pkt->pts != AV_NOPTS_VALUE) {
            // B-frames come out of the encoder in decode order: a time that goes back proves the reordering.
            if (e->pkt->pts < e->lastPts) e->reordered = true;
            e->lastPts = e->pkt->pts;
        }
        e->pkt->stream_index = st->index;
        if (!e->headerWritten) {
            if (c == e->video && (r = openContainer(e, e->pkt)) < 0) return r;
            if (!e->headerWritten) {
                AVPacket *copy = av_packet_clone(e->pkt);
                if (!copy) return AVERROR(ENOMEM);
                e->held.push_back({copy, c->time_base});
                av_packet_unref(e->pkt);
                continue;
            }
        }
        av_packet_rescale_ts(e->pkt, c->time_base, st->time_base);
        if ((r = av_interleaved_write_frame(e->fmt, e->pkt)) < 0) return r;
    }
}

// The layout of the pictures `sq_enc_video` fills: the encoder's own, or the software format behind a hardware surface.
static AVPixelFormat swFormatOf(const AVCodecContext *c) {
    if (c->hw_frames_ctx) return ((AVHWFramesContext *)c->hw_frames_ctx->data)->sw_format;
    return c->pix_fmt;
}

// VA-API (Linux) takes hardware surfaces only: a device on the first render node that opens, and a pool of surfaces in
// the picture layout. The codec context owns the frames reference; the device reference is dropped here.
static bool attachVaapiFrames(AVCodecContext *c, AVPixelFormat swFmt) {
    const char *forced = getenv("SQ_VAAPI_DEVICE");
    AVBufferRef *dev = nullptr;
    for (int node = 128; node < 136 && !dev; node++) {
        char path[32];
        if (forced) snprintf(path, sizeof path, "%s", forced); else snprintf(path, sizeof path, "/dev/dri/renderD%d", node);
        if (av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VAAPI, path, nullptr, 0) < 0) dev = nullptr;
        if (forced) break;
    }
    if (!dev) return false;
    AVBufferRef *frames = av_hwframe_ctx_alloc(dev);
    av_buffer_unref(&dev);
    if (!frames) return false;
    AVHWFramesContext *fc = (AVHWFramesContext *)frames->data;
    fc->format = AV_PIX_FMT_VAAPI;
    fc->sw_format = swFmt;
    fc->width = c->width; fc->height = c->height;
    fc->initial_pool_size = 24;   // the encoder keeps a few pictures in flight (async depth, B-frame reordering)
    if (av_hwframe_ctx_init(frames) < 0) { av_buffer_unref(&frames); return false; }
    c->hw_frames_ctx = frames;
    c->pix_fmt = AV_PIX_FMT_VAAPI;
    return true;
}

// `t.planar420` picks the planar 4:2:0 layout (yuv420p / yuv420p10le) for encoders that do not take NV12 / P010.
static AVCodecContext *openVideo(const SQFFEncodeConfig *cfg, const char *name, bool globalHeader, const VideoTry &t, const EncOptions &options) {
    const int bFrames = t.bFrames;
    const bool planar420 = t.planar420, tenBit = t.tenBit;
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec) return nullptr;
    AVCodecContext *c = avcodec_alloc_context3(codec);
    c->log_level_offset = 8;   // the encoders' progress statistics (info) stay quiet; warnings and errors still show
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
        // prores_videotoolbox takes the same profile numbers (0 Proxy ... 4 4444, 5 XQ) but other layouts: P210 for 4:2:2,
        // AYUV64 (alpha included) for 4:4:4:4; the swscale step converts from the editor's frames.
        bool vtPro = strstr(name, "videotoolbox") != nullptr;
        if (vtPro) c->pix_fmt = cfg->prores == 5 ? AV_PIX_FMT_AYUV64LE : AV_PIX_FMT_P210LE;
        else c->pix_fmt = cfg->prores == 5 ? AV_PIX_FMT_YUVA444P10LE : AV_PIX_FMT_YUV422P10LE;
        av_opt_set_int(c->priv_data, "profile", cfg->prores - 1, 0);
        if (!vtPro) av_opt_set(c->priv_data, "vendor", "apl0", 0);
    } else {
        c->pix_fmt = tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        if (strstr(name, "openh264") || !strcmp(name, "mpeg4") || planar420) c->pix_fmt = tenBit ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P;
        // 8-bit 4:2:0 only (OpenH264, Kvazaar): they refuse a 10-bit request (below).
        if (!strcmp(name, "mpeg4") || strstr(name, "openh264") || strstr(name, "kvazaar")) {
            if (tenBit) { avcodec_free_context(&c); return nullptr; }   // 8-bit encoders never stand in for Main 10
            c->pix_fmt = AV_PIX_FMT_YUV420P;
        }
        // "profile" exists on the context itself (numeric, no H.264 words) and on most encoders' private class (named): the private one is meant.
        if (options.size() && t.useOptions) for (auto &kv : options) av_opt_set(kv.first == "profile" && c->priv_data ? (void *)c->priv_data : (void *)c, kv.first.c_str(), kv.second.c_str(), AV_OPT_SEARCH_CHILDREN);
        if (strstr(name, "_vaapi") && !attachVaapiFrames(c, c->pix_fmt)) { avcodec_free_context(&c); return nullptr; }
        bool vt = strstr(name, "videotoolbox") != nullptr;
        if (cfg->quality > 0) {
            // Constant quality: the size follows the picture. libx264 / libx265 take a CRF (q 1 = 14, q 0.05 = 42);
            // VideoToolbox takes its 0...1 quality as global_quality in QSCALE mode (FFmpeg maps it to 0...100).
            double q = std::min(1.0, std::max(0.05, cfg->quality));
            if (vt) { c->flags |= AV_CODEC_FLAG_QSCALE; c->global_quality = (int)(q * 100 * FF_QP2LAMBDA); }
            else if (!strcmp(name, "mpeg4")) { int qp = (int)(2 + (1 - q) * 29 + 0.5); c->qmin = qp; c->qmax = qp; c->flags |= AV_CODEC_FLAG_QSCALE; c->global_quality = qp * FF_QP2LAMBDA; }   // qscale 2...31
            else if (strstr(name, "libx26")) av_opt_set_int(c->priv_data, "crf", (int64_t)(14 + (1 - q) * 30 + 0.5), 0);
            else if (strstr(name, "_amf")) {
                // AMD AMF: constant QP (rc=cqp) with the same QP as the CRF above; B frames a little coarser.
                int qp = (int)(14 + (1 - q) * 30 + 0.5);
                av_opt_set(c->priv_data, "rc", "cqp", 0);
                av_opt_set_int(c->priv_data, "qp_i", qp, 0);
                av_opt_set_int(c->priv_data, "qp_p", qp + 1, 0);
                av_opt_set_int(c->priv_data, "qp_b", qp + 2, 0);
            } else if (strstr(name, "openh264")) {
                // libopenh264: quality rate control mode, the QP range pinned to one value.
                int qp = (int)(14 + (1 - q) * 30 + 0.5);
                av_opt_set(c->priv_data, "rc_mode", "quality", 0);
                c->qmin = qp; c->qmax = qp;
            } else if (!strstr(name, "_vaapi") && !strstr(name, "_nvenc") && !strstr(name, "_qsv") && !strstr(name, "_mf") && !strstr(name, "kvazaar")) {
                c->bit_rate = cfg->bitrate;
            }   // those take their quality from the private options Rust chose (`options.rs`), no bitrate target
        } else {
            c->bit_rate = cfg->bitrate;
            // libopenh264 defaults to its quality mode and would ignore the bitrate; ask for the bitrate mode (the VBV max below becomes its cap).
            if (strstr(name, "openh264")) av_opt_set(c->priv_data, "rc_mode", "bitrate", 0);
            if (!strcmp(name, "mpeg4")) {}   // MPEG-4 Part 2 (the LGPL fallback) refuses the VBV limits of a 20 Mbit/s H.264 export
            else if (cfg->cbr) { c->rc_max_rate = cfg->bitrate; c->rc_min_rate = cfg->bitrate; c->rc_buffer_size = (int)std::min<int64_t>(INT32_MAX, cfg->bitrate); }
            else {
                c->rc_max_rate = cfg->maxBitrate > 0 ? cfg->maxBitrate : cfg->bitrate * 3 / 2;
                c->rc_buffer_size = (int)std::min<int64_t>(INT32_MAX, c->rc_max_rate * 4 / 3);
            }
        }
        if (cfg->speed > 0) {
            if (vt) { av_opt_set_int(c->priv_data, "realtime", 0, 0); av_opt_set_int(c->priv_data, "prio_speed", 1, 0); }
            else if (strstr(name, "libx26")) av_opt_set(c->priv_data, "preset", cfg->speed == 2 ? "veryfast" : "faster", 0);
        }
        c->gop_size = cfg->gop;
        c->max_b_frames = bFrames;
    }
    if (!cfg->gif) {
        auto tag = [](int v, int fallback) { return v > 0 && v != 2 ? v : fallback; };   // 0 reserved, 2 unspecified
        c->color_primaries = (AVColorPrimaries)tag(cfg->colorPrimaries, AVCOL_PRI_BT709);
        c->color_trc = (AVColorTransferCharacteristic)tag(cfg->colorTrc, AVCOL_TRC_BT709);
        c->colorspace = (AVColorSpace)tag(cfg->colorSpace, AVCOL_SPC_BT709);
        c->color_range = AVCOL_RANGE_MPEG;
        // HDR delivery: the mastering display and content light level travel as stream side data (the MOV/MP4 muxer writes mdcv / clli).
        auto be16 = [](const uint8_t *p) { return (int)((p[0] << 8) | p[1]); };
        auto be32 = [](const uint8_t *p) { return (int64_t)(((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]); };
        if (cfg->mdcv && cfg->hevc) {
            AVPacketSideData *sd = av_packet_side_data_new(&c->coded_side_data, &c->nb_coded_side_data,
                                                           AV_PKT_DATA_MASTERING_DISPLAY_METADATA, sizeof(AVMasteringDisplayMetadata), 0);
            if (sd) {
                auto *m = (AVMasteringDisplayMetadata *)sd->data;
                memset(m, 0, sizeof *m);
                const uint8_t *b = cfg->mdcv;   // order G, B, R, white; ffmpeg wants R, G, B
                const int src[3] = {2, 0, 1};
                for (int i = 0; i < 3; i++) {
                    m->display_primaries[i][0] = av_make_q(be16(b + src[i] * 4), 50000);
                    m->display_primaries[i][1] = av_make_q(be16(b + src[i] * 4 + 2), 50000);
                }
                m->white_point[0] = av_make_q(be16(b + 12), 50000);
                m->white_point[1] = av_make_q(be16(b + 14), 50000);
                m->max_luminance = av_make_q((int)be32(b + 16), 10000);
                m->min_luminance = av_make_q((int)be32(b + 20), 10000);
                m->has_primaries = m->has_luminance = 1;
            }
        }
        if (cfg->cll && cfg->hevc) {
            size_t size = 0;
            AVContentLightMetadata *l = av_content_light_metadata_alloc(&size);
            if (l) {
                l->MaxCLL = be16(cfg->cll); l->MaxFALL = be16(cfg->cll + 2);
                AVPacketSideData *sd = av_packet_side_data_add(&c->coded_side_data, &c->nb_coded_side_data,
                                                               AV_PKT_DATA_CONTENT_LIGHT_LEVEL, l, size, 0);
                if (!sd) av_free(l);
            }
        }
    }
    if (globalHeader) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (!cfg->hevc && !cfg->gif && cfg->prores == 0 && cfg->h264Profile >= 1 && cfg->h264Profile <= 3 && strcmp(name, "mpeg4") != 0) {
        // The H.264 profile of the sheet at codec level: Media Foundation reads only this one, VA-API, AMF and QSV read it
        // beside their own option (`options.rs`), the other encoders ignore it. The hardware writes the constrained Baseline.
        static const int levels[] = {AV_PROFILE_UNKNOWN, AV_PROFILE_H264_BASELINE, AV_PROFILE_H264_MAIN, AV_PROFILE_H264_HIGH};
        bool constrained = strstr(name, "_vaapi") || strstr(name, "_amf");
        c->profile = cfg->h264Profile == 1 && constrained ? AV_PROFILE_H264_CONSTRAINED_BASELINE : levels[cfg->h264Profile];
    }
    if (tenBit && cfg->hevc) {
        av_opt_set(c->priv_data, "profile", "main10", 0);
        c->profile = AV_PROFILE_HEVC_MAIN_10;   // VA-API reads the codec-level profile
    }
    if (!strcmp(name, "libx265")) av_opt_set(c->priv_data, "x265-params", "log-level=error", 0);
    if (avcodec_open2(c, codec, nullptr) < 0) { avcodec_free_context(&c); return nullptr; }
    return c;
}

// Hardware encoders can open and still fail on the first picture (a Media Foundation HEVC encoder without a codec pack,
// AMF below its minimum size): encode one black picture on a throwaway context. The caller reopens a fresh one.
// A picture for a hardware encoder: the software picture copied into a surface of the frames pool.
static AVFrame *uploadPicture(AVCodecContext *c, const AVFrame *sw) {
    AVFrame *hw = av_frame_alloc();
    if (!hw) return nullptr;
    if (av_hwframe_get_buffer(c->hw_frames_ctx, hw, 0) < 0 || av_hwframe_transfer_data(hw, sw, 0) < 0) { av_frame_free(&hw); return nullptr; }
    hw->pts = sw->pts;
    return hw;
}

static bool probeEncoder(AVCodecContext *c) {
    AVFrame *f = av_frame_alloc();
    AVPacket *p = av_packet_alloc();
    bool ok = false;
    AVPixelFormat swFmt = swFormatOf(c);
    f->format = swFmt; f->width = c->width; f->height = c->height;
    ptrdiff_t ls[4] = {0, 0, 0, 0};
    if (av_frame_get_buffer(f, 0) >= 0) for (int k = 0; k < 4; k++) ls[k] = f->linesize[k];
    if (f->buf[0] && av_image_fill_black(f->data, ls, swFmt, AVCOL_RANGE_MPEG, c->width, c->height) >= 0) {
        f->pts = 0;
        AVFrame *hw = c->hw_frames_ctx ? uploadPicture(c, f) : nullptr;
        int r = c->hw_frames_ctx && !hw ? AVERROR(EINVAL) : avcodec_send_frame(c, hw ? hw : f);
        av_frame_free(&hw);
        if (r >= 0) r = avcodec_send_frame(c, nullptr);
        while (r >= 0) { r = avcodec_receive_packet(c, p); if (r >= 0) av_packet_unref(p); }
        ok = r == AVERROR_EOF;
    }
    av_packet_free(&p);
    av_frame_free(&f);
    return ok;
}

// Whether the driver library behind a hardware encoder family is on this machine. Without it every try of the encoder logs an
// error ("Cannot load nvcuda.dll") and cannot work, so such an encoder is never a candidate. Checked once per process and family.
static bool driverPresent(const char *name) {
    const char *lib = nullptr;
#ifdef _WIN32
    if (strstr(name, "_nvenc")) lib = "nvcuda.dll";
    else if (strstr(name, "_amf")) lib = "amfrt64.dll";
#else
    if (strstr(name, "_nvenc")) lib = "libcuda.so.1";
    else if (strstr(name, "_amf")) lib = "libamfrt64.so.1";
#endif
    if (!lib) return true;
    static std::mutex lock;
    static std::map<std::string, bool> known;
    std::lock_guard<std::mutex> g(lock);
    auto it = known.find(lib);
    if (it != known.end()) return it->second;
#ifdef _WIN32
    HMODULE h = LoadLibraryA(lib);
    bool ok = h != nullptr;
    if (h) FreeLibrary(h);
#else
    void *h = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
    bool ok = h != nullptr;
    if (h) dlclose(h);
#endif
    if (!ok) av_log(nullptr, AV_LOG_INFO, "encoder %s skipped: %s is not installed\n", name, lib);
    known[lib] = ok;
    return ok;
}

// The encoder `name` with the layouts, bit depths, B-frame counts and options worth trying, most ambitious first:
// NV12 / P010 before planar; the wanted depth before 8-bit; the wanted B-frames before none; the Rust-chosen private
// options before the encoder's defaults (an encoder that refuses one option still runs, with its own rate control).
static AVCodecContext *openVideoAny(const SQFFEncodeConfig *cfg, const char *name, bool globalHeader, bool probe, const EncOptions &options) {
    if (probe && !driverPresent(name)) return nullptr;
    // An encoder that failed every try for this kind of video (a driver such as nvcuda.dll missing) is not tried again in this process:
    // each try logs an error and an export asks several times. The key holds what can change the answer.
    static std::mutex failedLock;
    // The entry expires after 60 s: a transient failure (session limit, device busy) must not exclude the encoder for a later export.
    static std::map<std::string, std::chrono::steady_clock::time_point> failed;
    std::string failKey = std::string(name) + "|" + (cfg->tenBit ? "10" : "8") + "|" + std::to_string(cfg->width) + "x" + std::to_string(cfg->height)
        + "|" + (cfg->hevc ? "hevc" : "h264") + "|p" + std::to_string(cfg->h264Profile);
    {
        std::lock_guard<std::mutex> g(failedLock);
        auto it = failed.find(failKey);
        if (it != failed.end()) {
            if (std::chrono::steady_clock::now() - it->second < std::chrono::seconds(60)) return nullptr;
            failed.erase(it);
        }
    }
    bool plain = cfg->prores == 0 && !cfg->gif;
    // shortcut: VideoToolbox gets no B-frames; its B-frame timestamps broke the MP4 muxer (pts < dts) in a 128x72 test.
    // Upgrade with a measurement against AVFoundation's file size.
    // Baseline has no B-frames by the standard: an encoder that was asked for B-frames would write a Main stream.
    int bFrames = strstr(name, "videotoolbox") || (!cfg->hevc && cfg->h264Profile == 1) ? 0 : cfg->bFrames;
    bool vaapi = strstr(name, "_vaapi") != nullptr;   // surfaces only: no planar layout to fall back to
    // libx265 takes planar 4:2:0 only: start there instead of logging an error for NV12 first.
    // A 10-bit request opens 10-bit or fails: no silent 8-bit retry (the sheet shows Main 10 as not available instead).
    for (int planar = !strcmp(name, "libx265") ? 1 : 0; planar < (plain && !vaapi ? 2 : 1); planar++) {
        for (int opts = 0; opts < (options.empty() || !plain ? 1 : 2); opts++) {
            for (int bf = 0; bf < (bFrames > 0 && plain ? 2 : 1); bf++) {
                VideoTry t{cfg->tenBit != 0, bf == 0 ? bFrames : 0, planar != 0, opts == 0};
                AVCodecContext *c = openVideo(cfg, name, globalHeader, t, options);
                if (c && probe) {
                    bool works = probeEncoder(c);
                    avcodec_free_context(&c);
                    if (!works) continue;
                    c = openVideo(cfg, name, globalHeader, t, options);
                }
                if (c) return c;
            }
        }
    }
    // Only hardware candidates (`probe`) are remembered: a software encoder's refusal belongs to its options, not to the machine.
    if (probe) {
        std::lock_guard<std::mutex> g(failedLock);
        failed[failKey] = std::chrono::steady_clock::now();
    }
    return nullptr;
}

// "name<TAB>key<TAB>value" lines from Rust: the options of the candidate `name`.
static EncOptions optionsOf(const char *lines, const std::string &name) {
    EncOptions out;
    std::string text = lines ? lines : "";
    for (size_t pos = 0; pos < text.size();) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        pos = end + 1;
        size_t a = line.find('\t');
        size_t b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b == std::string::npos || line.compare(0, a, name) != 0) continue;
        out.emplace_back(line.substr(a + 1, b - a - 1), line.substr(b + 1));
    }
    return out;
}

int sq_enc_open(const SQFFEncodeConfig *cfg, SQFFEncoder **out, char *err, int errLen) {
    *out = nullptr;
    SQFFEncoder *e = new SQFFEncoder();
    int r;
    if ((r = avformat_alloc_output_context2(&e->fmt, nullptr, nullptr, cfg->path)) < 0) {
        sqSetError(err, errLen, "container", r); delete e; return r;
    }
    bool globalHeader = e->fmt->oformat->flags & AVFMT_GLOBALHEADER;
    // The candidate list comes from Rust (`candidates`): hardware names first (probed with a test frame), then software.
    std::string list = cfg->encoders ? cfg->encoders : "";
    int index = 0;
    for (size_t pos = 0; pos < list.size() && !e->video && !cfg->noVideo;) {
        size_t end = list.find(',', pos);
        if (end == std::string::npos) end = list.size();
        std::string name = list.substr(pos, end - pos);
        pos = end + 1;
        e->video = openVideoAny(cfg, name.c_str(), globalHeader, index++ < cfg->hardwareEncoders, optionsOf(cfg->encoderOptions, name));
        if (e->video) snprintf(e->videoName, sizeof e->videoName, "%s", name.c_str());
    }
    if (!e->video && !cfg->noVideo) { snprintf(err, errLen, "no %s encoder could be opened", cfg->gif ? "GIF" : cfg->prores > 0 ? "ProRes" : cfg->hevc ? (cfg->tenBit ? "HEVC 10-bit" : "HEVC") : "H.264"); sq_enc_abort(e); return AVERROR_ENCODER_NOT_FOUND; }
    if (e->video) {
        e->vst = avformat_new_stream(e->fmt, nullptr);
        avcodec_parameters_from_context(e->vst->codecpar, e->video);
        if (cfg->rotation % 360 != 0) {
            AVPacketSideData *sd = av_packet_side_data_new(&e->vst->codecpar->coded_side_data, &e->vst->codecpar->nb_coded_side_data,
                                                           AV_PKT_DATA_DISPLAYMATRIX, sizeof(int32_t) * 9, 0);
            if (sd) av_display_rotation_set((int32_t *)sd->data, (double)(cfg->rotation % 360));
        }
        e->swFormat = swFormatOf(e->video);
        e->vst->codecpar->format = e->swFormat;
        e->vst->time_base = e->video->time_base;
        e->vst->avg_frame_rate = e->video->framerate;
        if (cfg->hevc && cfg->prores == 0 && strcmp(e->videoName, "mpeg4")) e->vst->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');   // QuickTime and browsers want hvc1
    }
    if (cfg->audioChannels > 0) {
        // PCM: 24-bit takes 32-bit samples (the top 24 bits are written); FLAC the same (16 or 24 bits).
        AVCodecID id = cfg->flac ? AV_CODEC_ID_FLAC : cfg->pcmBits == 16 ? AV_CODEC_ID_PCM_S16LE
                     : cfg->pcmBits == 24 ? AV_CODEC_ID_PCM_S24LE : cfg->pcmBits == 32 ? AV_CODEC_ID_PCM_S32LE : AV_CODEC_ID_AAC;
        const AVCodec *aac = avcodec_find_encoder(id);
        const char *aname = cfg->flac ? "FLAC" : cfg->pcmBits ? "PCM" : "AAC";
        int extras = std::max(0, std::min(cfg->extraAudioCount, 7));
        e->extra.resize(extras);
        for (int t = 0; t <= extras; t++) {
            AudioOut &a = t == 0 ? e->a0 : e->extra[t - 1];
            int rate = t == 0 ? cfg->audioRate : cfg->extraAudioRate[t - 1];
            int channels = t == 0 ? cfg->audioChannels : cfg->extraAudioChannels[t - 1];
            a.ctx = aac ? avcodec_alloc_context3(aac) : nullptr;
            if (!a.ctx) { snprintf(err, errLen, "no %s encoder", aname); sq_enc_abort(e); return AVERROR_ENCODER_NOT_FOUND; }
            a.ctx->sample_rate = rate;
            a.ctx->sample_fmt = id == AV_CODEC_ID_AAC ? AV_SAMPLE_FMT_FLTP
                              : id == AV_CODEC_ID_PCM_S16LE || (cfg->flac && cfg->pcmBits <= 16) ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S32;
            if (cfg->flac) a.ctx->bits_per_raw_sample = cfg->pcmBits <= 16 ? 16 : 24;
            av_channel_layout_default(&a.ctx->ch_layout, channels);
            a.ctx->log_level_offset = 8;
            a.ctx->bit_rate = cfg->audioBitrate;
            a.ctx->time_base = AVRational{1, rate};
            if (globalHeader) a.ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            if ((r = avcodec_open2(a.ctx, aac, nullptr)) < 0) { sqSetError(err, errLen, aname, r); sq_enc_abort(e); return r; }
            a.st = avformat_new_stream(e->fmt, nullptr);
            avcodec_parameters_from_context(a.st->codecpar, a.ctx);
            a.st->time_base = a.ctx->time_base;
            // PCM encoders take any frame size (frame_size 0): the FIFO starts at 4 x 1024 frames and grows.
            a.fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, channels, std::max(a.ctx->frame_size, 1024) * 4);
            if (!a.fifo) { snprintf(err, errLen, "audio buffer"); sq_enc_abort(e); return AVERROR(ENOMEM); }
            a.frame = av_frame_alloc();
        }
    }
    e->pkt = av_packet_alloc();
    if (e->video) {
        e->vframe = av_frame_alloc();
        e->vframe->format = e->swFormat;
        e->vframe->width = cfg->width; e->vframe->height = cfg->height;
        if ((r = av_frame_get_buffer(e->vframe, 0)) < 0) { sqSetError(err, errLen, "frame", r); sq_enc_abort(e); return r; }
    }
    if ((r = avio_open(&e->fmt->pb, cfg->path, AVIO_FLAG_WRITE)) < 0) { sqSetError(err, errLen, "create file", r); sq_enc_abort(e); return r; }
    for (auto kv : {std::pair<const char *, const char *>{"title", cfg->title}, {"comment", cfg->comment}, {"creation_time", cfg->creationTime}})
        if (kv.second && *kv.second) av_dict_set(&e->fmt->metadata, kv.first, kv.second, 0);
    AVDictionary *opts = nullptr;
    if (cfg->gif) {
        av_dict_set(&opts, "loop", "0", 0);   // loops forever
        av_dict_set_int(&opts, "final_delay", std::max(1, cfg->gifFinalDelay), 0);
    } else if (!strcmp(e->fmt->oformat->name, "mp4") || !strcmp(e->fmt->oformat->name, "mov") || !strcmp(e->fmt->oformat->name, "ipod")) {
        av_dict_set(&opts, "movflags", "+faststart", 0);
    }
    e->deferHeader = e->video && strstr(e->videoName, "_vaapi") != nullptr;
    if (e->deferHeader) {
        e->headerOptions = opts;   // written with the first video packet
    } else {
        r = avformat_write_header(e->fmt, &opts);
        av_dict_free(&opts);
        if (r < 0) { sqSetError(err, errLen, "header", r); sq_enc_abort(e); return r; }
        e->headerWritten = true;
    }
    *out = e;
    return 0;
}

const char *sq_enc_video_name(const SQFFEncoder *e) { return e->videoName; }

void sq_enc_video_facts(const SQFFEncoder *e, int *bitDepth, int *reordered) {
    const AVPixFmtDescriptor *d = e->video ? av_pix_fmt_desc_get(e->swFormat) : nullptr;
    *bitDepth = d ? d->comp[0].depth : 0;
    *reordered = e->reordered ? 1 : 0;
}

// Ends the video stream and writes what the encoder still holds (a probe reads `sq_enc_video_facts` after this).
int sq_enc_drain_video(SQFFEncoder *e) {
    if (!e->video) return AVERROR(EINVAL);
    int r = avcodec_send_frame(e->video, nullptr);
    return r < 0 ? r : writePackets(e, e->video, e->vst);
}

int sq_enc_video(SQFFEncoder *e, const uint8_t *pixels, const char *format, int stride, int64_t frameIndex) {
    if (!e->video) return AVERROR(EINVAL);
    AVPixelFormat from = av_get_pix_fmt(format);
    if (from == AV_PIX_FMT_NONE) return AVERROR(EINVAL);
    int w = e->video->width, h = e->video->height, r;
    if ((r = av_frame_make_writable(e->vframe)) < 0) return r;
    const uint8_t *src[4]; int ss[4];
    av_image_fill_arrays((uint8_t **)src, ss, pixels, from, w, h, 1);
    ss[0] = stride;
    if (from == e->swFormat) {
        av_image_copy2(e->vframe->data, e->vframe->linesize, (uint8_t *const *)src, ss, from, w, h);
    } else {
        if (!e->sws || e->swsFrom != from) {
            sws_freeContext(e->sws);
            e->sws = sws_getContext(w, h, from, w, h, e->swFormat, SWS_BICUBIC, nullptr, nullptr, nullptr);
            e->swsFrom = from;
            if (!e->sws) return AVERROR(EINVAL);
            // RGB input is full range Rec.709 light; YCbCr input is already limited range; the file is limited range Rec.709.
            const int *coeffs = sws_getCoefficients(SWS_CS_ITU709);
            const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(from);
            int srcRange = d && (d->flags & AV_PIX_FMT_FLAG_RGB) ? 1 : 0;
            sws_setColorspaceDetails(e->sws, coeffs, srcRange, coeffs, 0, 0, 1 << 16, 1 << 16);
        }
        sws_scale(e->sws, src, ss, 0, h, e->vframe->data, e->vframe->linesize);
    }
    e->vframe->pts = frameIndex;
    if (e->video->hw_frames_ctx) {
        AVFrame *hw = uploadPicture(e->video, e->vframe);
        if (!hw) return AVERROR(ENOMEM);
        r = avcodec_send_frame(e->video, hw);
        av_frame_free(&hw);
        if (r < 0) return r;
    } else if ((r = avcodec_send_frame(e->video, e->vframe)) < 0) {
        return r;
    }
    return writePackets(e, e->video, e->vst);
}

static int encodeAudioFrames(SQFFEncoder *e, AudioOut &a, bool flush) {
    int fs = a.ctx->frame_size > 0 ? a.ctx->frame_size : 1024, r;
    while (av_audio_fifo_size(a.fifo) >= fs || (flush && av_audio_fifo_size(a.fifo) > 0)) {
        int n = std::min(fs, av_audio_fifo_size(a.fifo));
        av_frame_unref(a.frame);
        a.frame->nb_samples = n;
        a.frame->format = a.ctx->sample_fmt;
        a.frame->sample_rate = a.ctx->sample_rate;
        av_channel_layout_copy(&a.frame->ch_layout, &a.ctx->ch_layout);
        if ((r = av_frame_get_buffer(a.frame, 0)) < 0) return r;
        if (a.ctx->sample_fmt == AV_SAMPLE_FMT_FLTP) {
            av_audio_fifo_read(a.fifo, (void **)a.frame->data, n);
        } else {
            // Integer PCM, interleaved: clamp, scale to full range, round.
            int ch = a.ctx->ch_layout.nb_channels;
            std::vector<float> planar((size_t)n * ch);
            std::vector<void *> planes((size_t)ch);   // any channel count: a fixed array overran past 8
            for (int c = 0; c < ch; c++) planes[c] = planar.data() + (size_t)c * n;
            av_audio_fifo_read(a.fifo, planes.data(), n);
            bool s16 = a.ctx->sample_fmt == AV_SAMPLE_FMT_S16;
            for (int i = 0; i < n; i++) {
                for (int c = 0; c < ch; c++) {
                    double v = std::max(-1.0, std::min(1.0, (double)planar[(size_t)c * n + i]));
                    if (s16) ((int16_t *)a.frame->data[0])[(size_t)i * ch + c] = (int16_t)std::lround(std::min(v * 32768.0, 32767.0));
                    else ((int32_t *)a.frame->data[0])[(size_t)i * ch + c] = (int32_t)std::llround(std::min(v * 2147483648.0, 2147483647.0));
                }
            }
        }
        a.frame->pts = a.pts;
        a.pts += n;
        if ((r = avcodec_send_frame(a.ctx, a.frame)) < 0) return r;
        if ((r = writePackets(e, a.ctx, a.st)) < 0) return r;
    }
    return 0;
}

int sq_enc_audio_track(SQFFEncoder *e, int track, const float *interleaved, int frames) {
    if (track < 0 || track > (int)e->extra.size()) return AVERROR(EINVAL);
    AudioOut &a = track == 0 ? e->a0 : e->extra[track - 1];
    if (!a.ctx || frames <= 0) return 0;
    int ch = a.ctx->ch_layout.nb_channels;
    std::vector<float> planar((size_t)frames * ch);
    std::vector<void *> planes((size_t)ch);
    for (int c = 0; c < ch; c++) {
        float *p = planar.data() + (size_t)c * frames;
        for (int i = 0; i < frames; i++) p[i] = interleaved[(size_t)i * ch + c];
        planes[c] = p;
    }
    int r = av_audio_fifo_write(a.fifo, planes.data(), frames);
    if (r < 0) return r;
    return encodeAudioFrames(e, a, false);
}

int sq_enc_audio(SQFFEncoder *e, const float *interleaved, int frames) {
    return sq_enc_audio_track(e, 0, interleaved, frames);
}

int sq_enc_finish(SQFFEncoder *e, char *err, int errLen) {
    int r = 0;
    for (int t = 0; t <= (int)e->extra.size(); t++) {
        AudioOut &a = t == 0 ? e->a0 : e->extra[t - 1];
        if (a.ctx && (r = encodeAudioFrames(e, a, true)) < 0) { sqSetError(err, errLen, "audio", r); sq_enc_abort(e); return r; }
    }
    if (e->video && ((r = avcodec_send_frame(e->video, nullptr)) < 0 || (r = writePackets(e, e->video, e->vst)) < 0)) {
        sqSetError(err, errLen, "video flush", r); sq_enc_abort(e); return r;
    }
    for (int t = 0; t <= (int)e->extra.size(); t++) {
        AudioOut &a = t == 0 ? e->a0 : e->extra[t - 1];
        if (a.ctx && ((r = avcodec_send_frame(a.ctx, nullptr)) < 0 || (r = writePackets(e, a.ctx, a.st)) < 0)) {
            sqSetError(err, errLen, "audio flush", r); sq_enc_abort(e); return r;
        }
    }
    if (!e->headerWritten && (r = openContainer(e, nullptr)) < 0) { sqSetError(err, errLen, "header", r); sq_enc_abort(e); return r; }   // no video packet ever came
    if ((r = av_write_trailer(e->fmt)) < 0) { sqSetError(err, errLen, "trailer", r); sq_enc_abort(e); return r; }
    e->headerWritten = false;
    sq_enc_abort(e);   // frees everything, the file is complete
    return 0;
}

void sq_enc_abort(SQFFEncoder *e) {
    if (!e) return;
    avcodec_free_context(&e->video);
    av_frame_free(&e->vframe);
    av_packet_free(&e->pkt);
    for (int t = 0; t <= (int)e->extra.size(); t++) {
        AudioOut &a = t == 0 ? e->a0 : e->extra[t - 1];
        avcodec_free_context(&a.ctx);
        av_frame_free(&a.frame);
        if (a.fifo) av_audio_fifo_free(a.fifo);
    }
    sws_freeContext(e->sws);
    for (HeldPacket &h : e->held) av_packet_free(&h.pkt);
    av_dict_free(&e->headerOptions);
    if (e->fmt) {
        if (e->fmt->pb) avio_closep(&e->fmt->pb);
        avformat_free_context(e->fmt);
    }
    delete e;
}
