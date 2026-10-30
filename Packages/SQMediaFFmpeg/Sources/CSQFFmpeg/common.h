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
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

static inline void sqSetError(char *err, int errLen, const char *what, int code) {
    if (!err || errLen <= 0) return;
    char eb[128];
    av_strerror(code, eb, sizeof eb);
    snprintf(err, errLen, "%s: %s", what, eb);
}
#endif
