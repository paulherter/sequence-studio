# Phase 5 — Audio FX (Packages/SQAudioFX)

Standalone package. Depends on SQCore (KeyframeTrack/Time only, read-only). AVFoundation allowed (AVAudioConverter), no AppKit, no AudioToolbox. Plain `[[Float]]` (one array per channel) as buffer type, so everything is testable offline.

## Slices (tests first, each)
1. **Gain math + volume automation**: dB<->linear (-inf <-> 0), `VolumeAutomation` = static dB or `KeyframeTrack<Double>` (dB), optional pan (constant power, unity at centre). Gain evaluated on an absolute-sample control grid (64 samples) and interpolated linearly per sample: sample-accurate, no zipper noise, identical result for any chunking.
2. **Track preset model**: `MultibandCompressorSettings` (4 bands, 3 crossovers, per-band threshold/ratio/attack/release/gain, pre-gain, makeup), `TrackAudioPreset` (+ `noiseReduction` = denoiser wet/dry mix 0...1, default 0.5, 0 = off), built-ins Off/Voice/Music, `PresetLibrary` for user presets.
3. **RNNoise**: vendored RNNoise 0.1.1 (C target `CRNNoise`, built-in weights in `rnn_data.c`). `RNNoiseDenoiser`: 48 kHz, 480-sample frames, FIFO, fixed latency of 480 samples (output[n] = processed[n-480]) so every call returns exactly as many samples as it got and chunking never changes the result. `mix` = wet/dry; the dry path is delayed by the same 480 samples, so mix 0 is the time-aligned input.
4. **Multiband compressor** (`Multiband.swift`, own DSP, no AU): 3 Linkwitz-Riley 4th-order crossovers, low bands allpass-compensated (recombined sum is flat within 0.1 dB, tone at a crossover frequency included). Per band: linked stereo peak detector (hold 3...20 ms, tied to the band's low edge), hard-knee gain computer `(level - threshold) * (1 - 1/ratio)`, gain reduction smoothed in dB with attack/release time constants (one-pole, exp(-1/(t*fs))), band gain. Pre-gain before the split, makeup after the sum. Per-sample, all state in the value: chunk size never changes the output; same code offline and realtime; zero latency. Bypass is bit-exact.
5. **Metering** (BS.1770-4 / EBU R128): K-weighting, momentary 400 ms, short-term 3 s, integrated with -70 LUFS absolute and -10 LU relative gate, sample peak, true peak (4x polyphase oversampling).
6. **Offline pipeline** (`OfflineAudioFX`): denoise -> multiband compressor -> gain (gain last, incl. pan and keyframed volume). Any sample rate: `DenoiseStage` converts to 48 kHz with AVAudioConverter, denoises, converts back; the stage latency is measured once per rate with an impulse (includes both converters). `process` output is delayed by `latencySamples`, the volume is evaluated at the input-aligned time; `flushTail` returns the rest; `render` compensates and returns the input length. `denoiseMix` is settable on the chain (initial value = `preset.noiseReduction`).
7. **Realtime path** (`RealtimeAudioFX`, for the SQPlayback render callback): same chain on deinterleaved `UnsafeMutablePointer<UnsafeMutablePointer<Float>>` channels, in place, fixed 48 kHz, every buffer preallocated in `init`. `process(_:frameCount:timelineSample:)` does no allocation, no blocking and no ObjC (checked with a `malloc_logger` test, release build: 0 allocations over 1000 blocks incl. a parameter handoff). Setters (`setPreset`, `setDenoiseMix`, `setVolume`, `setBypass`) from any thread build the new parameter set on the caller's thread and hand it over via a Mutex the render thread only try-locks; applied at the start of the next block (one block later if a setter holds the lock at that instant). Compressor state (filters, detectors) is kept across setting changes. `reset()` (any thread) is applied at the start of the next block. Output equals `OfflineAudioFX.process` within 1e-6 for any chunking. Shared code: `MultibandCompressor` and `VolumeAutomation` got pointer-based cores; the array entry points delegate to them (offline results unchanged).

## Decisions taken here
- [auto] Realtime chain runs at a fixed 48 kHz (the playback mixer rate). Non-48 kHz material is resampled by the feeder upstream, not in `RealtimeAudioFX`.
- [auto] Realtime latency is constant 480 samples while a denoiser exists (`denoiser: true`, default), independent of mix or bypass (mix 0 / bypass = delayed dry), so moving the mix never makes audio jump. `denoiser: false` = no denoiser, latency 0, for tracks that never use noise reduction. The engine must delay its other paths / shift clips by `latencySamples`.
- [auto] Bypass = compressor off + denoiser dry; volume/pan still apply (clip properties, not FX).
- [auto] `timelineSample` = timeline position of the first input sample; volume is evaluated at the input time of each output sample (same as offline).
- [auto] Vendored RNNoise got one addition, `rnnoise_reset` (in-place state reset without allocation, for seeks); docs/THIRD_PARTY.md still says "unmodified" and should be updated by the control session.
- Volume below -120 dB is exact silence (keeps dB interpolation finite; UI can show -inf).
- K-weighting coefficients are computed from the BS.1770 filter parameters (f0/Q/G) for any sample rate; at 48 kHz they reproduce the standard table.
- Channel weights default: mono/stereo 1.0; 6 channels = L R C LFE Ls Rs with LFE 0 and surrounds 1.41; other counts 1.0.
- RNNoise input is scaled to int16 range internally (x32768); callers pass normal +-1.0 floats.

- [auto] Integration fixes in SQPlayback (see ARCHITECTURE §7): per-track FX buses in the feeder with unity FX volume, latency alignment to max (`outputLatencySamples`), reverse = FX bypassed (dry, same latency) + reset on every seek, flush epoch + consumer fade (`RingBuffer(fadeFrames:)`), 48 kHz precondition. A denoiser, once created for a track, stays allocated while the track has a preset (mix 0 = dry) so the amount slider never changes the global latency; clip volume applies before the compressor in live playback (offline: after).

## Decisions (Paul)
- Own 4-band compressor replaces the wideband placeholder and the AUMultibandCompressor mapping (`auParameters()` and the AudioToolbox dependency removed).
- Denoiser strength is a wet/dry mix, default 0.5, on preset (`noiseReduction`) and chain (`denoiseMix`).
- Non-48 kHz input is resampled inside the chain (AVAudioConverter); denoise is never skipped (`denoiseApplied` is true whenever noise reduction > 0).
- Chain order denoise -> compressor -> gain.
- No LRA.

## Open questions
1. **Latency**: the denoise path adds 480 samples at 48 kHz, more at other rates (`latencySamples`, measured). Live playback must delay the other paths or shift the clip; offline `render` compensates.
2. **RNNoise and flat white noise**: measured, RNNoise leaves stationary flat-spectrum white noise almost untouched (-1 to -4 dB) but removes low-passed room/fan-like noise by 40+ dB. Tests use coloured noise. Real-world footage is the judge; Paul should listen on a typical recording.
3. **Compressor voicing**: Voice/Music presets are starting values, not tuned by ear. Hard knee, peak detector; a soft knee or RMS detection is easy to add if it sounds harsh.
