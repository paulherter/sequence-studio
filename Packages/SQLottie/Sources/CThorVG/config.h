// Hand-written replacement for ThorVG's meson-generated config.h (ThorVG v1.1.2). CPU (software) engine, Lottie + raw +
// PNG + JPG loaders only; no SVG/WebP/fonts/media, no expressions (jerryscript is not vendored), no SIMD (same output
// everywhere), no file IO (the Lottie bytes come from the project), no logging.
#define THORVG_VERSION_STRING "1.1.2"
#define THORVG_THREAD_SUPPORT 1
#define THORVG_CPU_ENGINE_SUPPORT 1
#define THORVG_LOTTIE_LOADER_SUPPORT 1
#define THORVG_PNG_LOADER_SUPPORT 1
#define THORVG_JPG_LOADER_SUPPORT 1
