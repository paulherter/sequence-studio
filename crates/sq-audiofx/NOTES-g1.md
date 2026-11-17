# sq-audiofx notes, group g1 (afx1)

Modules: gain, silence_detector, channel_monitor, surround_fold_down, loudness, parametric_eq (+ MultibandStage),
parametric_eqresponse, creator_stages, creator_fx, de_click, de_reverb (+ FFT), audio_spectrum, rnnoise_denoiser (+ FFI),
offline_audio_fx, realtime_audio_fx, clip_audio_fxchain.

## RNNoise
C sources are copied to `vendor/rnnoise` (BSD-3-Clause, `COPYING` kept) and built by `build.rs` with the `cc` crate
(`[workspace.dependencies] cc = "1"` added). The crate sets `unsafe_code = "deny"`; the only `unsafe` is the `ffi` module
in `rnnoise_denoiser.rs` (`DenoiseState`, safe wrapper with `Drop`, `// SAFETY:` comments). README documents the lint.

One local patch to the C sources: the four variable-length arrays in `pitch.c`/`celt_lpc.c` use `SQ_STACK_ARRAY` (arch.h), which is
`_alloca` under MSVC (no VLAs there) and a plain VLA elsewhere; identical numerics. Verified: tests pass on the Mac and on the Windows test PC.

## Mapping decisions
- Buffers: pointer style (`UnsafeMutablePointer<UnsafeMutablePointer<Float>>`, frames) becomes `&mut [&mut [f32]]` plus an explicit
  frame count `n`; `[[Float]]` becomes `&mut [Vec<f32>]`.
- UserDefaults (`AudioDeClick`) becomes the `BoolDefaults` trait; the global `isEnabled` getter/setter on `.standard` and the
  NotificationCenter hook are the shell's job, `AudioDeClickObserver::refresh()` is what the shell calls on a change.
- `RealtimeAudioFX`: the render thread owns the struct (`process(&mut self)`), other threads use `RealtimeControls`
  (`controls()`: setters + reset, mailbox behind a `Mutex` the render side only `try_lock`s). Real-time/threads rule of
  AGENT-RULES applies: please have this reviewed before it drives a real audio callback.
- `AudioSpectrumTap`/`MultibandMeterTap`: chains take `Option<Arc<AudioSpectrumTap>>` (None = shared); the meter tap stays `'static`.
- Stages that Swift calls with pointer offsets (`buf[c] + s`) get a `Vec` of channel views once per block while a value is
  ramped (`MultibandStage`, de-esser stage); not ramped = no allocation. Marked `shortcut:` in code.
- Sound-relevant NaN edge: Swift `min(1, max(0, x))` returns 0 for NaN, Rust `clamp` returns NaN (pan value, De-Reverb amount/tone
  weight, De-Esser sensitivity, multiband limiter fields). Inputs are sanitized upstream, so left as `clamp`.
- `MultibandStage.settings(_:)` (unused in Swift app code) and `AudioDeClick.isEnabled` (global) are not ported.

## Not ported (Apple only or no reference)
- `DenoiseStage.swift` (AVAudioConverter for non-48 kHz): the Windows build throws `unsupportedSampleRate`, so
  `OfflineAudioFX::new` returns `UnsupportedSampleRate` for a denoising preset at any other rate. Swift tests `ResampleTests`
  are therefore not ported.
- `GoldenOutputTests` (FNV hashes of Swift/libm output): needs the Swift oracle dumper; Rust libm bits differ.
- `noHeapAllocation*` tests (malloc_logger hook), `layoutAndStepsAlignForEveryAudioKind` (needs Clip/EffectCatalog).

## Waiting on / open
- afx2's `role_chain::tests::other_sample_rates_and_silence` renders a denoising preset at 44.1/96 kHz; it fails with the
  Windows-reference behavior above. Either that test restricts itself to 48 kHz or a portable resampler (not in Swift) is added.
- Swift tests of the chain that belong to afx2 modules and still need porting on top of `ClipAudioFXChain`:
  `EnhanceSpeechTests`, `BroadcastPresetSafetyTests`, `RoleChainTests`-via-chain parts, `GateDelayReverbTests`,
  `GraphicEQAndGateHoldTests`, `PitchShiftTests`, `NotchStageTests`, `RepairStagesTests` (use `run_with` style helpers in
  `clip_audio_fxchain.rs` tests; `gain::sig` holds the shared signal generators).
- RNNoise numerics are the same C code; no Swift-dumped golden was recorded (the Swift tests only check loosely).
