// H.264 stream facts from the SPS in the avcC record. FFmpeg's stream probe learns the pixel format and the range and
// colour tags by decoding a whole picture (150 ms for a 4K 10-bit 4:2:2 camera frame, over a second on a slow disk);
// the sequence parameter set says the same in microseconds.
#include "common.h"
#include <vector>

namespace {
struct Bits {
    std::vector<uint8_t> d;   // the payload without emulation prevention bytes
    size_t pos = 0;
    bool bad = false;
    uint32_t bit() {
        if (pos >= d.size() * 8) { bad = true; return 0; }
        uint32_t b = (d[pos >> 3] >> (7 - (pos & 7))) & 1;
        pos++;
        return b;
    }
    uint32_t u(int n) { uint32_t v = 0; for (int i = 0; i < n && !bad; i++) v = (v << 1) | bit(); return v; }
    uint32_t ue() {
        int zeros = 0;
        while (!bit()) { if (bad || ++zeros > 31) { bad = true; return 0; } }
        return zeros ? ((1u << zeros) - 1) + u(zeros) : 0;
    }
    int32_t se() { uint32_t k = ue(); return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2); }
};

void skipScalingList(Bits &b, int size) {
    int last = 8, next = 8;
    for (int j = 0; j < size && !b.bad; j++) {
        if (next != 0) next = (last + b.se() + 256) % 256;
        if (next != 0) last = next;
    }
}
}  // namespace

bool sqH264FactsFromSps(AVCodecParameters *par) {
    const uint8_t *x = par->extradata;
    if (par->codec_id != AV_CODEC_ID_H264 || par->extradata_size < 12 || x[0] != 1 || (x[5] & 0x1f) < 1) return false;
    const int len = (x[6] << 8) | x[7];
    if (len < 4 || 8 + len > par->extradata_size || (x[8] & 0x1f) != 7) return false;
    Bits b;
    for (int i = 9, zeros = 0; i < 8 + len; i++) {   // after the NAL header byte
        if (zeros >= 2 && x[i] == 3) { zeros = 0; continue; }
        zeros = x[i] == 0 ? zeros + 1 : 0;
        b.d.push_back(x[i]);
    }
    const int profile = (int)b.u(8);
    b.u(16);   // constraint flags, level
    b.ue();    // sps id
    int chroma = 1, depth = 8;
    switch (profile) {
        case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135: {
            chroma = (int)b.ue();
            if (chroma == 3) b.u(1);
            depth = 8 + (int)b.ue();
            if ((int)b.ue() + 8 != depth) return false;
            b.u(1);
            if (b.u(1)) for (int i = 0; i < (chroma != 3 ? 8 : 12); i++) if (b.u(1)) skipScalingList(b, i < 6 ? 16 : 64);
            break;
        }
        default: break;
    }
    b.ue();   // log2 max frame num
    const uint32_t pocType = b.ue();
    if (pocType == 0) b.ue();
    else if (pocType == 1) {
        b.u(1); b.se(); b.se();
        const uint32_t n = b.ue();
        if (n > 255) return false;
        for (uint32_t i = 0; i < n; i++) b.se();
    }
    b.ue();   // max reference frames
    b.u(1);   // gaps in frame num
    b.ue(); b.ue();   // size in macroblocks
    if (!b.u(1)) return false;   // not frame_mbs_only: the field order needs a decoded picture
    b.u(1);   // direct 8x8
    if (b.u(1)) { b.ue(); b.ue(); b.ue(); b.ue(); }   // cropping
    int range = par->color_range, primaries = par->color_primaries, transfer = par->color_trc, matrix = par->color_space;
    AVRational sar = par->sample_aspect_ratio;
    if (b.u(1)) {   // VUI
        if (b.u(1)) {   // aspect ratio: a table entry, or 255 and the sizes
            static const AVRational table[17] = {{0, 1}, {1, 1}, {12, 11}, {10, 11}, {16, 11}, {40, 33}, {24, 11}, {20, 11}, {32, 11},
                                                 {80, 33}, {18, 11}, {15, 11}, {64, 33}, {160, 99}, {4, 3}, {3, 2}, {2, 1}};
            const uint32_t idc = b.u(8);
            AVRational vui = idc < 17 ? table[idc] : AVRational{0, 1};
            if (idc == 255) { vui.num = (int)b.u(16); vui.den = (int)b.u(16); }
            if (vui.num > 0 && vui.den > 0) sar = vui;   // the decoder takes the SPS's aspect over the container's
        }
        if (b.u(1)) b.u(1);                     // overscan
        if (b.u(1)) {                           // video signal type
            b.u(3);
            range = b.u(1) ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
            if (b.u(1)) { primaries = (int)b.u(8); transfer = (int)b.u(8); matrix = (int)b.u(8); }
        }
    }
    if (b.bad || chroma < 1 || chroma > 3 || (depth != 8 && depth != 10)) return false;
    const bool full = range == AVCOL_RANGE_JPEG;
    static const AVPixelFormat deep[] = {AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P10LE};
    static const AVPixelFormat flat[] = {AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV444P};
    static const AVPixelFormat flatFull[] = {AV_PIX_FMT_NONE, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P};
    par->format = depth == 10 ? deep[chroma] : (full ? flatFull[chroma] : flat[chroma]);
    par->color_range = (AVColorRange)range;
    par->color_primaries = (AVColorPrimaries)primaries;
    par->color_trc = (AVColorTransferCharacteristic)transfer;
    par->color_space = (AVColorSpace)matrix;
    par->sample_aspect_ratio = sar;
    par->field_order = AV_FIELD_PROGRESSIVE;
    return true;
}
