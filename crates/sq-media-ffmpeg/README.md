# sq-media-ffmpeg

FFmpeg demux, decode and encode behind sq-media's traits (C++ shim built with cc). Design: docs/rust/render-playback-export-design.md. Modules: shim, decode, encode.

Test: `cargo xtask check sq-media-ffmpeg`.

Encode: `encode::Encoder` (safe wrapper of `vendor/encode.cpp`) and `encode::write_still` (`vendor/still.cpp`). Hardware first:
VideoToolbox on the Mac (no B-frames, see the shortcut in `encode.cpp`), AMF / NVENC / Quick Sync / Media Foundation on
Windows; software x264 / x265 where the FFmpeg build has them, else OpenH264. Dropping an unfinished `Encoder` aborts and
deletes the partial file. The pipeline that drives it is `sq-export::encode`.
