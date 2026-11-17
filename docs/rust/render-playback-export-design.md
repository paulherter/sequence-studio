# Render, playback and export design (Wave 2-3)

Rule: the portable path is the behavior reference: `WinProgramEngine`, `WinCompositor`, `WinTimelineFrameSource`, `FFmpegExportEncoder` and the portable SQRender/SQPlayback/SQExport files (those the `Package.swift` `appleOnly` lists do not exclude). Mac-only speed paths come back only behind a measured gate (plan §8).

## 1. Crates and traits
```
sq-frame - sq-media(traits) - sq-media-ffmpeg (C++ shim via cc; FFI-only unsafe)
   |           '- sq-video-hw (macOS VT decode + IOSurface->wgpu import; unsafe allow-list; absorbs sq-gpu-interop)
sq-gpu (wgpu, committed shader outputs) - sq-render - sq-playback (+ sq-audio-out, sq-audiofx)
                                              '---- sq-export (+ sq-media-ffmpeg encoder API)
```
- sq-gpu: `cargo xtask shaders` (built from `spikes/g2-slang/build.rs`) writes MSL/DXIL/SPIR-V + reflection into `crates/sq-gpu/shaders/`; xtask checks the reflection against the fixed layout. `Gpu` creates the 3 samplers first and never drops them; one 35-entry layout with 1x1 dummies; a uniform arena per command buffer (b0/b1, dynamic offsets, no immediates); the 62 lazy pipelines, `GpuFrame`, texture pool, `Readback`. No `GPUDevice` trait: wgpu is the abstraction. `GPUCompositor<D>` becomes `GpuCompositor` with the same encoder method names (`set_input(slot)`, `set_output`, `set_constants`, `dispatch`).
- sq-render: the portable SQRender files plus `WinCompositor` (LayerRequest -> RenderLayer -> `RenderNode` tree -> passes). Test oracle = the existing Swift CPU reference functions (ColorPipeline, StyleFilters, ImageFilters, BlendModes, UltraKey, CropMask, ScopesReference). No new full CPU compositor.
- sq-media-ffmpeg: keep `CSQFFmpeg/*.cpp`, drop `wasapi.cpp`; `ffmpeg-sys-next` only for linking. Demuxer, decoder, audio source, still reader, plus a safe `Encoder` API.
- sq-platform-mac/win: window, menus and the G4 patches only; no media code.
- Traits (only these): `sq_media::{Demuxing, VideoDecoding, AudioSource}` (Swift shapes), new `sq_media::MediaOpener` (~30 lines, the role of `WinMediaSource`/`MediaResolver`; on the Mac it tries VT first, then FFmpeg), `sq_audio_out::Renderer` (G6), `sq_export::{FrameSource, AudioSource, ExportEncoding}`.
- `VideoDecoding::decode(&mut self, range, needed_from, &CancelToken, deliver: &mut dyn FnMut(DecodedFrame))` is blocking; `&mut` encodes "never called concurrently".

## 2. Threads
| thread | owns | Swift origin |
|---|---|---|
| UI (winit) | `UiExecutor`, session, UI draw and present, `ProgramHandle` | @MainActor |
| render (1) | `ProgramEngine` (1:1 port of WinProgramEngine: cache, wanted/shown, clock hold, warm), compositor, plane uploads | WinProgramEngine; Mac RenderLoop thread |
| decode lanes (<=4) | decoders by `&mut`, FIFO jobs | `Task.detached` decode, DecodeScheduler |
| audio mixer + cpal RT callback | AudioFeeder -> SPSC ring -> AudioRenderCore, seqlock clock | WASAPIAudioEngine |
| export (1 per job, serial lane) | own compositor, decoders, opener; shares the device | WinRenderActor, ExportQueue actor |
| WorkerPool (G5) | probes, thumbnails, waveforms, proxies | detached tasks |
- Crossing threads: engine methods become commands over `mpsc`; decoded frames go to the render thread over a channel; the render thread puts the latest `Shown{generation, position, Arc<GpuFrame>}` in a mailbox for the UI; position events go through `ui_queue.post`.
- Backpressure: decoding is pull-only; the engine requests ranges and an in-flight set removes duplicates; the cache byte budget counts GPU bytes too; VT pool capped at 8 in flight; export keeps 3 frames between GPU and encoder.
- Cancellation: `WinWantGate` becomes `Arc<Mutex>`; a job checks staleness before each GOP; seek/scrub cancel `CancelToken`s; export checks per frame; encoder abort deletes the partial file.
- Master clock: the audio clock (AudioClock + G6's DLL smoothing); host clock as fallback without a device.

## 3. Frame lifetime
- `GpuFrame { planes: <=3 wgpu::Texture, layout: Nv12|P010|Rgba8Straight|Rgba16f, size, color, pts, keep: Option<Box<dyn Any+Send+Sync>> }`, passed as `Arc`, implements `SQFrameStorage`.
- One function does the interop: `sq_render::planes::to_gpu(&Gpu, &SQFrame, &mut PlaneCache)`. It downcasts the storage: a `GpuFrame` passes through (Mac VT, zero-copy; `keep` holds CVPixelBuffer and CVMetalTexture); `CpuPlanes` (Windows FFmpeg download) are written into pooled textures keyed by (media, index, proxy, divisor), as `WinCompositor` does today.
- Each submit records the frames it read in `InFlight{submission, Vec<Arc<GpuFrame>>}`, released only after `device.poll` reports the submission done (open item from G1).

## 4. Port order (task, Swift files with lines, parallel with, oracle)
- R0 (Opus): GPU.swift API, g2 spike (~1.2k new) | with R2, R3, M1, X2 | 65 entry-point goldens, Metal vs D3D12 <= 1/255.
- R1: Passes, ScopeBinning, ReferenceGraph, ReferenceFamilies (0.9k) | after R0 | ReferenceGraph PNG; exact bin counters.
- R2: Color/* except MSL strings and Metal files (2.9k) | | Swift color tests; float dumps 1e-6.
- R3: effect plans and CPU refs, FrameBlend, MotionBlurNode, VisibleSourceRegion, ViewGamma, PortableSIMD (2.2k) | | CPU-reference dumps.
- R4a: RenderLayer, Compositor+Uniforms, GPUCompositor(+Resample), GPUColorChain, ColorPipelineGPU+Plan, LayerColorResolver (1.8k) | after R0-R3 | GPUCompositorReference PNG <= 1/255, 0 % over 1 (f16 rounded toward zero).
- R4b: GPUCompositor+Effects/+Flow, EffectPasses, TemporalPasses, OpticalFlowPasses, Scope* (1.6k) | with R4a | per-pass CPU-vs-GPU tolerance from the Swift tests.
- R5: WinCompositor (0.4k -> 1k) | after R4, M1 | corpus frame goldens recorded on the Windows test PC.
- M1 (Opus): FFmpeg*.swift + shim, decode side (0.8k) | | NV12/P010 FNV hash per frame; 10 random seeks exact.
- M2 (Opus): sq-video-hw from G1 (1.2k new) + SQFrame+CoreVideo | after R0, M1 | H.264/HEVC planes = FFmpeg hashes; ProRes PSNR >= 50 dB; time <= Swift + 10 %.
- A1: sq-audio-out (G6), AudioRenderCore, RingBuffer, Clock, AudioClock (0.8k) | Wave 3 start | G6 soak; AudioClockTests.
- A2: AudioFeeder(+TrackMix, +Preferences), AudioRetimer, AudioTimeMap, ShuttleStretch, ScrubAudio, gain/meter stages, WaveformSilences, AudioPlaying (2.6k) | after A1 | null test rms < -140 dBFS / peak < -120 dBFS (<= 24 tracks, fixed sum order).
- P1: WinProgramEngine, WinMediaSource, WinPlayStats, MemoryBudget, PreviewRate, PowerPolicy, CaptionLayerPlan (1.6k) + thread shell | after R5, M1, A1 | wanted-keys dump per position; paused frames = export goldens; EngineBench timing.
- X1: portable SQExport (settings, presets, queue, loudness, stems, TimelineAudioSource, GIFPalette ...) (2.9k) | with A1 | portable Swift tests.
- X2: EDL, FCPXML, XMEML, OTIO, SRT, VTT, ITT, MarkerCSV, YouTubeChapters (1.3k) | from Wave 1 on | byte-exact text.
- X3: FFmpegExportEncoder, WinTimelineFrameSource, WinRenderActor, WinExport resolver (0.7k + encode.cpp) | after R5, X1 | box/timestamp dump exact; software codecs: decoded-frame hashes; hardware codecs: PSNR >= 45 dB, FLIP < 0.01.

## 5. The five riskiest points and the decision for each
1. Playback engine: port WinProgramEngine's logic, run it on its own render thread with the audio clock as master. The Mac RenderLoop helpers (DecodeScheduler, Prefetch, FrameCache, DisplayLead, FramePacing, ~1.7k lines, unused on Windows) are parked; if the Mac bench is worse than Swift, port DisplayLead first, then the DecodeScheduler lanes.
2. FFmpeg binding: keep the C++ shim built with `cc` (proven behavior, small unsafe surface), no `ffmpeg-next` API, LGPL shared build; the Mac adds `h264_videotoolbox`/`hevc_videotoolbox` to the encoder list.
3. GPU layer: concrete code, no traits; one wgpu device and queue for UI, program and export; patch the `.slang` sources to ByteAddressBuffer directly (12 modules + DrawQuads) since the Swift D3D12 path is deleted anyway.
4. Frame lifetime: `Arc<GpuFrame>` plus `InFlight` release; Windows keeps the CPU copy (r8/rg8 or r16/rg16) until after cutover.
5. Mac export and grade speed: the readback + FFmpeg path is the reference; measure against AVFoundation (incl. prores_ks vs hardware ProRes) and the generic Slang color chain against the Mac's fused MSL grade kernels; if a check fails, add a GPU RGB->NV12/P010 pass plus a VT encoder (from IOSurface) behind `ExportEncoding`.

## 6. Apple-only code that is replaced, not ported (new code ~4.3k lines in total)
- SQGPU: MetalGPU (262) and SQGPUD3D12 (1.2k), plus ShaderSources (42k generated) -> sq-gpu (~0.8k) + xtask shaders (~0.4k).
- SQRender: the Metal files (3.6k: Compositor 1281, ColorPipelineGPU, Presenter, DisplayView, CompositorEffects/Masks, ShapeRenderer ...) and the MSL strings (1.25k) -> R4/R5 ports + present glue (~0.3k).
- SQPlayback: RenderLoop 3363, PlaybackEngine 697, AudioEngine 385, PlayProbe, AudioOutputDevices, LookPreview, ProxyPicture, VoiceRecorder (5.05k) -> engine shell (~0.4k), sq-audio-out (~0.7k), cpal input for the voice recorder (~0.2k).
- SQExport: ExportWriter, TimelineFrameSource, DecoderFrameProvider, EncoderSpeedSession, CaptionBurnIn, SmartRender, RenderCacheSegment and others (4.46k) -> export pipeline (~0.3k). **Smart render and segment caching are dropped; the maintainer has to sign this off (plan §8).**
- SQMedia: VideoDecoder, Demuxer, AudioSource, SQFrameCoreVideo -> sq-video-hw (~1.2k).
- Windows audio: WASAPIAudioEngine and `wasapi.cpp` -> cpal.
