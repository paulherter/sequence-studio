# sq-audiofx: group g2 notes (worker afx2)

Modules: pitch_shift, multiband, role_chain, repair_stages, presets, space_and_gate_stages, lookahead_limiter, limiter,
enhance_speech, graphic_eqstage, multiband_meters, monitor_gain, notch_stage, gate_core, spectrum_display.

## Conventions the chain (group g1) must call
- Pointer-style `process(buf, channels, frames)` became `process(buf: &mut [&mut [f32]], n: usize, ...)`: one slice per channel
  (`buf.len()` is the channel count, `min(chs, channels)` is taken inside), `n` frames like `ClipAudioFXChain::ramp`.
- Swift `wasOff` is a `pub was_off` field (Low/High Cut: `set_was_off`).
- Ramped pairs `from`/`to` are `(f64, f64)` tuples (NoiseGateStage: threshold, range; DelayStage: time, feedback, mix;
  ReverbStage: mix); NoiseGateStage `times` = (attack ms, release ms, hold ms); Notch `NotchParams`; De-Hum `DeHumParams`.
  (Reason: clippy's 7-argument limit; the alternative was an `#[allow]`.)
- `GateCore::step` takes a `GateStep` struct (same eight values).
- Stages and helpers are `pub` (not `pub(crate)`) so the crate has no dead-code warnings before the chain uses them.
- `MultibandCompressor::process(buf, n)` and `process_planar(&mut [Vec<f32>])` (the Swift `[[Float]]` overload);
  `MultibandConfig::from_settings` / `from_values` are the two Swift `Config` initializers.
- `MultibandMeterTap::shared()` is a `static`; ids are `sq_core_time::Id`; `split` reads the two halves little-endian.
- `EnhanceSpeechStage::new` returns `Option` (the RNNoise state can fail to allocate); Swift `free()` is `Drop`.
- `PresetLibrary::save_user` takes `&mut dyn IdSource` (Swift `UUID()`); `TrackAudioPreset` statics are functions
  (`voice()`, `built_ins()` ...); `NoiseGateSettings::OFF` comes from `creator_fx`.

## Deviations from Swift (behavior kept)
- FFT: `PitchVocoder` always uses the portable `FFTRadix2` (the Windows path of the Swift package), never vDSP.
- `MonitorGain` reads and writes through the `MonitorDefaults` trait (number + flag) instead of `UserDefaults`;
  `apply_launch_rules_once` keys on `MonitorDefaults::store_id` (Swift `ObjectIdentifier`).
- `MonitorGain.Ramp.next()` is `MonitorRamp::advance()` (clippy `should_implement_trait`); its `target` `didSet` is `set_target`.
- SIMD4 sums keep Swift's left-to-right lane order (checked with a Swift snippet: `[1e16, 1, -1e16, 1].sum() == 1`).
- `RoleChain::measure` returns `(lufs, true_peak_db)`.
- `.max(a).min(b)` with constant bounds is `clamp` (same result incl. NaN pass-through; Swift `min(max(x, a), b)`).

- `RoleChainTests.otherSampleRatesAndSilence`: the portable denoiser is 48 kHz only (see NOTES-g1), so Dialogue at 44.1/96 kHz
  returns `UnsupportedSampleRate`; the Rust test asserts that and checks Music (no denoiser) at those rates.
- One call site of group g1 was adapted to the `NoiseGateStage::process` tuple signature (`clip_audio_fxchain.rs`).
- Oracle: `oracle/sq-audiofx/golden/g2.tsv` (Swift output, FNV hash + samples); `tests/g2_golden.rs`: 15 of 16 rows bit-exact,
  Disguise Voice within 0 relative difference on the sampled values.

## Waiting on (needs group g1 or the chain)
- Chain-driven tests: disabled stages pass through (De-Hum, Low Cut, Notch, Gate, Graphic EQ), slot latency
  (`chain.latencySamples`), swept Notch parameters through `process(steps:endSteps:)` (ported at stage level instead),
  `BroadcastPresetSafetyTests` (all go through the Multiband slot with the limiter), `GateCoreEquivalenceTests.trackGateMatchesLegacy`
  (needs `creator_fx::NoiseGate`).
- Not ported: `PitchShiftTests.realtimeCost` / `noHeapAllocationInProcess` (timing and `malloc_logger`, Darwin only).
