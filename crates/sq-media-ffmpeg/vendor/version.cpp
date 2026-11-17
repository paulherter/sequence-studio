// Whether the FFmpeg libraries loaded at run time are the ones the headers of this build describe. The loader checks
// the library file names; this checks the numbers inside them (a library of the same name from another FFmpeg build).
#include "common.h"
#include <libavutil/avutil.h>
#include <string.h>

// Major versions only: a minor bump keeps the ABI.
static int checkOne(const char *name, unsigned built, unsigned loaded, char *err, int errLen) {
    if ((built >> 16) == (loaded >> 16)) return 0;
    snprintf(err, errLen, "%s %u built against, %u loaded", name, built >> 16, loaded >> 16);
    return -1;
}

int sq_version_mismatch(char *err, int errLen) {
    if (!err || errLen <= 0) return -1;
    err[0] = 0;
    if (checkOne("avutil", LIBAVUTIL_VERSION_INT, avutil_version(), err, errLen)) return -1;
    if (checkOne("avcodec", LIBAVCODEC_VERSION_INT, avcodec_version(), err, errLen)) return -1;
    if (checkOne("avformat", LIBAVFORMAT_VERSION_INT, avformat_version(), err, errLen)) return -1;
    if (checkOne("swscale", LIBSWSCALE_VERSION_INT, swscale_version(), err, errLen)) return -1;
    if (checkOne("swresample", LIBSWRESAMPLE_VERSION_INT, swresample_version(), err, errLen)) return -1;
    return 0;
}
