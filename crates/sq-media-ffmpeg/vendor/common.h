// Shared includes and helpers of the CSQFFmpeg sources.
#ifndef CSQFFMPEG_COMMON_H
#define CSQFFMPEG_COMMON_H
#include "csqffmpeg.h"
#include <algorithm>
#include <math.h>
#include <stdio.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

// Pixel format, range, colour tags and field order of an H.264 stream from its SPS (sps.cpp); false when the SPS says too little.
bool sqH264FactsFromSps(AVCodecParameters *par);

static inline void sqSetError(char *err, int errLen, const char *what, int code) {
    if (!err || errLen <= 0) return;
    char eb[128];
    av_strerror(code, eb, sizeof eb);
    snprintf(err, errLen, "%s: %s", what, eb);
}
#endif
