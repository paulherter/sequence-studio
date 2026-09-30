# Phase 5 — Audio FX (Packages/SSAudioFX)

Standalone package. Depends on SSCore (KeyframeTrack/Time only, read-only). AudioToolbox allowed, no AppKit, no AVFoundation. Plain `[[Float]]` (one array per channel) as buffer type, so everything is testable offline.

## Slices (tests first, each)
1. **Gain math + volume automation**: dB<->linear (-inf <-> 0), `VolumeAutomation` = static dB or `KeyframeTrack<Double>` (dB), optional pan (constant power, unity at centre). Gain evaluated on an absolute-sample control grid (64 samples) and interpolated linearly per sample: sample-accurate, no zipper noise, identical result for any chunking.
2. **Track preset model**: `MultibandCompressorSettings` (4 bands, 3 crossovers, per-band threshold/ratio/attack/release/gain, makeup), `TrackAudioPreset` (+ noise-reduction amount 0...1), built-ins Off/Voice/Music, `PresetLibrary` for user presets. `auParameters()` -> `[(id, value)]` for AUMultibandCompressor (pure data).
3. **RNNoise**: vendored RNNoise 0.1.1 (C target `CRNNoise`, built-in weights in `rnn_data.c`). `RNNoiseDenoiser`: 48 kHz, 480-sample frames, FIFO, fixed latency of 480 samples (output[n] = processed[n-480]) so every call returns exactly as many samples as it got and chunking never changes the result. `mix` = wet/dry.
4. **Metering** (BS.1770-4 / EBU R128): K-weighting, momentary 400 ms, short-term 3 s, integrated with -70 LUFS absolute and -10 LU relative gate, sample peak, true peak (4x polyphase oversampling).
5. **Offline pipeline**: gain -> denoise -> compressor (placeholder, see below), `render(...)` compensates the denoiser latency.

## Decisions taken here
- Volume below -120 dB is exact silence (keeps dB interpolation finite; UI can show -inf).
- K-weighting coefficients are computed from the BS.1770 filter parameters (f0/Q/G) for any sample rate; at 48 kHz they reproduce the standard table.
- Channel weights default: mono/stereo 1.0; 6 channels = L R C LFE Ls Rs with LFE 0 and surrounds 1.41; other counts 1.0.
- RNNoise input is scaled to int16 range internally (x32768); callers pass normal +-1.0 floats.

## Open questions
1. **AU mapping is approximate.** AUMultiBandCompressor has a global attack/release (we average the four bands) and a per-band "headroom" instead of a ratio (we use `24 dB * (1 - 1/ratio)`, clamped 0.1...40). Needs a listening/measurement pass; alternative is our own 4-band compressor in SSAudioFX.
2. **Offline compressor is a placeholder**: wideband, feed-forward, settings averaged over the bands. Not meant for final output.
3. **Non-48 kHz input**: RNNoise only runs at 48 kHz. The pipeline skips denoise otherwise (`Result.denoiseApplied == false`). The playback/export side should convert to 48 kHz (AVAudioConverter) before the chain, or we add a resampler here.
4. **Latency**: denoise adds 480 samples (10 ms). Live playback must delay the other paths or shift the clip; offline `render` compensates.
5. LRA and loudness range are not implemented (not requested); max-momentary is cheap to add.
6. Gain before denoise (as specified) means a boosted clip is denoised after boosting; RNNoise is level-sensitive, so gain-after-denoise may sound better. Easy to swap.
7. **RNNoise and flat white noise**: measured, RNNoise leaves stationary flat-spectrum white noise almost untouched (-1 to -4 dB) but removes low-passed room/fan-like noise by 40+ dB. Tests use coloured noise. Real-world footage is the judge; Paul should listen on a typical recording.
