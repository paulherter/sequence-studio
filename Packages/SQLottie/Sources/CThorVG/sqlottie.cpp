// C shim over the ThorVG C++ API for SQLottie (Sequence Studio, GPL-3.0-or-later). Single-threaded, deterministic.
#include <mutex>
#include <vector>
#include <cstring>
#include "thorvg.h"
#include "sqlottie.h"

struct SQLottie {
    tvg::Animation *animation = nullptr;
    tvg::SwCanvas *canvas = nullptr;
    std::vector<uint32_t> buffer;
    uint32_t width = 0, height = 0;
    float picW = 0, picH = 0;
};

static void initEngine() {
    static std::once_flag once;
    std::call_once(once, [] { tvg::Initializer::init(0); });   // 0 threads: every render runs on the caller's thread
}

SQLottie *sqlottie_open(const char *data, uint32_t size) {
    if (!data || size == 0) return nullptr;
    initEngine();
    auto h = new SQLottie();
    h->animation = tvg::Animation::gen();
    if (!h->animation || h->animation->picture()->load(data, size, "lottie", nullptr, true) != tvg::Result::Success) {
        delete h->animation;
        delete h;
        return nullptr;
    }
    h->animation->picture()->size(&h->picW, &h->picH);
    if (h->picW <= 0 || h->picH <= 0) { delete h->animation; delete h; return nullptr; }
    return h;
}

void sqlottie_close(SQLottie *h) {
    if (!h) return;
    delete h->canvas;        // the canvas first: it holds the animation's picture
    delete h->animation;
    delete h;
}

void sqlottie_info(const SQLottie *h, float *w, float *hgt, float *frames, float *seconds) {
    if (w) *w = h->picW;
    if (hgt) *hgt = h->picH;
    if (frames) *frames = h->animation->totalFrame();
    if (seconds) *seconds = h->animation->duration();
}

int sqlottie_render(SQLottie *h, float frame, uint32_t w, uint32_t hgt, uint8_t *rgba) {
    if (!h || !rgba || w == 0 || hgt == 0) return 1;
    if (!h->canvas || h->width != w || h->height != hgt) {
        delete h->canvas;
        h->canvas = nullptr;
        h->buffer.assign((size_t)w * hgt, 0);
        h->width = w; h->height = hgt;
        h->canvas = tvg::SwCanvas::gen();
        if (!h->canvas) return 2;
        if (h->canvas->target(h->buffer.data(), w, w, hgt, tvg::ColorSpace::ABGR8888S) != tvg::Result::Success) return 3;
        h->animation->picture()->size((float)w, (float)hgt);
        if (h->canvas->add(h->animation->picture()) != tvg::Result::Success) return 4;
    }
    float total = h->animation->totalFrame();
    if (frame < 0) frame = 0;
    if (frame > total - 0.001f) frame = total > 0.001f ? total - 0.001f : 0;
    h->animation->frame(frame);
    h->canvas->update();
    if (h->canvas->draw(true) != tvg::Result::Success) return 5;
    h->canvas->sync();
    std::memcpy(rgba, h->buffer.data(), (size_t)w * hgt * 4);
    return 0;
}
