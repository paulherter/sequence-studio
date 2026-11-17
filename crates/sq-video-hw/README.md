# sq-video-hw

Direct VideoToolbox decode on the Mac (H.264, HEVC 8/10-bit, ProRes 4:2:2) behind sq-media's `VideoDecoding`. FFmpeg only demuxes
(its `Demuxing` impl); compressed samples go into an asynchronous `VTDecompressionSession` (8 frames in flight), each output
CVPixelBuffer is imported without a copy as one Metal texture per plane into wgpu and returned as an `sq_gpu::GpuFrame`
(`keep` holds the CVPixelBuffer and CVMetalTextures until the GPU is done). Design: docs/rust/render-playback-export-design.md
section 3, gate report spikes/g1-video/REPORT.md.

- Modules: `codec` and `plan` (portable, unit tested everywhere), `ffi` (macOS, the only `unsafe`), `decoder` (macOS), `stub` (other systems:
  `VtVideoDecoder::new` fails with `UnsupportedCodec`, so the workspace builds on Windows).
- Frames are matched to presentation indexes by decode ordinal (the VT source-frame refcon), so no pts reordering is needed.
- Seeks start at the sync sample (`SampleIndex::fresh_decode_start`); when frames are still missing after the input ends (B-frame HEVC landing after the
  target) the decode retries once one GOP earlier.
- Tests (macOS only, skipped elsewhere and when `ffmpeg` or a GPU is missing): decoded planes equal ffmpeg's `framecrc` hashes for H.264/HEVC,
  ProRes PSNR >= 50 dB. Build with `DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer`. Speed: `SQ_VIDEO_HW_BENCH=1 cargo test -p sq-video-hw bench -- --nocapture`.

Test: `cargo xtask check sq-video-hw`.
