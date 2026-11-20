---
title: Audio
chapter: audio
order: 1
code: crates/sq-core-audio, crates/sq-audiofx, crates/sq-audio-out, crates/sq-playback/src/audio, crates/sq-export/src/core/loudness.rs
---

## For users

Fix, clean and balance sound: effects, noise reduction, silence removal, ducking and loudness.

### Clip audio basics

- **Audio Gain**: choose Clip > Audio Options > Audio Gain… (G). The keys [ and ] lower and raise the gain of the selected clip. Gain Steps in the same menu move it by 1 dB or 6 dB.
- **De-Click**: Settings > Audio > De-Click puts a 3 ms fade at the start and end of every audio clip, so edits do not pop.
- **Roles**: Clip > Audio Options > Tag Role marks a clip as Dialogue, Music or SFX. Ducking and loudness use these roles.

### Audio effects

Audio effects work on a clip or on a whole track. The list includes: Noise Reduction, EQ (3 band), Graphic EQ, Parametric EQ, Compressor, Multiband Compressor, De-Esser, De-Reverb, Gain, Limiter, Noise Gate, Delay, Reverb, De-Hum, Low Cut, High Cut, Dialogue Leveler, Stereo Width, Chorus and Notch.

Presets include "Voice" and "Rode NTG Indoor".

Track controls (in the Controls panel for a track) include a role and preset choice (a new Role gives an untouched chain that Role's own settings; a chain you edited or picked stays as it is, and picking the same Role again brings the Role's own settings back), Denoise, a compressor with an On switch and a crossover strip, a Noise Gate with attack, hold and release, and Warmth with a mix amount. The Effects tab adds the EQ (four bands: a low shelf, two bells and a high shelf, each with Frequency, Gain and Width (Q); a bell's Frequency is its middle, a shelf's Frequency is its corner, so a typed frequency gives a bell its full Gain there, and changing a bell's Width keeps its middle where it is), the Noise Gate, Noise Reduction, Warmth and the Multiband Compressor. These settings belong to the whole track, so every clip on that track follows them; clips on other tracks are not touched. The Frequency slider runs on a log scale from 20 Hz to 20 kHz, so the low frequencies get as much room on the track as the high ones. You can type a value into any EQ field, also while the Multiband Compressor is off. Everything you change there is saved with the project and applies in playback and in export alike. Selecting a linked video and audio pair shows the audio clip's track controls below the video controls, so you do not need to unlink the pair to reach them. Editing a value keeps the panel where it is scrolled.

Clip > Audio Options > Voice also holds Voice Chain, Disguise Voice, Voiceover from Text… and Record Voice-Over.

### Noise suppression

Add the **Noise Reduction** effect to a clip. Its Amount slider (in percent) sets how much noise is removed. For a steady hum, there is also De-Hum.

### Remove silences

1. Select an audio clip.
2. Choose Clip > Audio Options > Clean Up > Remove Silences….
3. Set Level (dB), Min. Length (ms) and Keep Each Side (ms). The ranges that will be cut show in red on the timeline.
4. Click Remove, or Mark for Review to look first.

Silences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync. Messages you may see: "Select an audio clip first.", "The audio is not analyzed yet. Try again in a moment.", "No silences found."

With Mark for Review, use Review, Accept and Reject Proposed Cuts in the same menu. Remove Filler Words is there too.

### Ducking (music under speech)

There are two ways.

**Live Ducking** lowers Music tracks while Dialogue tracks speak, during playback and export. It does not change your clips. Turn it on in Settings > Audio, or use Clip > Audio Options > Live Ducking for This Project…. Settings let you choose Duck amount, Duck Preset (Soft, Hard, Custom) and timing (Lookahead, Attack, Recovery, Hold, Minimum pause). It is off by default.

**Bake Live Duck to Keys** (Control-Option-D on the Mac) writes the ducking as volume keys on the music clip, so you can fine tune it by hand.

1. Tag the music clip as Music and the speech clips as Dialogue.
2. Choose Clip > Audio Options > Bake Live Duck to Keys.

Pauses in dialogue of 0.6 seconds or longer let the music come back. If a clip already has duck keys, you are asked whether to replace them. If Live Ducking is also on, the music ducks twice, and a dialog offers to remove the keys.

### Loudness

- **Match Loudness** (Control-Option-L on the Mac) matches the loudness of selected clips.
- At export, turn on **Normalize** in the Audio section. Options are Loudness Range (needs a program of 60 seconds or more) and True Peak Max (-9 to 0 dBTP).
- **Audio Check** reports loudness, true peak, clipping, gaps, dual mono and sync.
- A sequence's delivery target sets the loudness: TikTok, Reels, Shorts, feed posts and YouTube all aim at -14 LUFS with a true peak ceiling of -1 dBTP.

Other Audio settings: Crossfade kind and length, J / L Offset per role, Meter Response (Smooth or Fast) and Fade Shape.

### Windows and Linux

Audio effects on Windows and Linux are still being checked. See below.

### Not sure yet

- Which audio effects work on Windows and Linux in the current alpha.
- The exact Effects panel folder that holds Noise Reduction.

Related: [Editing](timeline-and-editing.md), [Export](export.md), [Shortcuts](shortcuts.md), [Settings and Updates](settings-and-updates.md)

## For developers

Audio is split in three crates plus the places that use them.

| Crate | Role |
|---|---|
| `sq-core-audio` | Edit logic on the project model, no DSP and no device: Audio Gain and its dialog plan, audio roles, channel maps, audio effect catalog entries, Auto Duck (baked volume keys), live ducking, silence and filler-word cuts, voiceover helpers, the tone generator. It also holds the caption editing logic (see [Titles and Captions](text-and-subtitles.md)). |
| `sq-audiofx` | Own DSP: realtime and offline effect chains, loudness meter, limiter, multiband compressor, noise gate, de-esser, graphic and parametric EQ, de-click, de-reverb, pitch shift, silence detector, RNNoise denoiser. |
| `sq-audio-out` | The sound card side: the cpal output stream, the ring buffer and the audio clock (`output`, `ring`, `clock`). |

Data flow:

1. Saved types (`AudioTag`, `DuckTiming`, `ProjectLiveDucking`, `AudioChannelMap`) live in `sq-core-model`; `sq-core-audio` adds logic as extension traits such as `VolumeLineExt` and `TimelineRoleExt`. Ids come in as `&mut dyn IdSource`, user defaults through the small `DefaultsStore` trait.
2. Playback: `sq-playback` (`src/audio/`) owns the block mixer `AudioFeeder`, retiming, scrub grains, shuttle stretch, monitoring stages and the dialogue-pause detector for live ducking. It runs the realtime chain of `sq-audiofx` (`RealtimeAudioFX`, created in `feeder/config.rs`).
3. The audio clock derives the playback position from the frames the output actually consumed (`sq-audio-out/src/clock/audio_clock.rs`), so video follows audio and never runs ahead.
4. Export: loudness normalization, delivery checks and stems are in `sq-export/src/core/` (`loudness.rs`, `audio_delivery.rs`, `stems.rs`); they use the `sq-audiofx` loudness meter and limiter.
5. Live ducking is evaluated by the one mix path, for playback and export (as stated in `live_ducking.rs`). It needs no stored field; the amount comes from the user setting `sq.audio.liveDuckingDB` (0 = off). Clips with role Music are ducked, audible clips with role Dialogue duck them. `Ducking` (baked volume keys) is the separate, optional bake.
6. Silence removal (`silence_removal.rs`) turns detected pauses into frame-aligned ripple cuts with a fixed pad on each side. The media is never changed.

Tests: `cargo xtask check sq-core-audio`, `cargo xtask check sq-audiofx`, `cargo xtask check sq-audio-out`. `sq-audiofx` has a golden test (`tests/g2_golden.rs`), `sq-audio-out` a soak test (`tests/soak.rs`). Reference data comes from the oracle, see [Developing](developers.md).

Extension points: a new effect is a new module in `sq-audiofx` (one module per effect family) plus its catalog entry in `sq-core-audio/src/audio_effects.rs`. Track presets are in `sq-audiofx/src/presets.rs`.

`sq-audiofx` uses `unsafe_code = "deny"` instead of the workspace `forbid`; the only `unsafe` is the `ffi` module in `src/rnnoise_denoiser.rs`, which calls the vendored RNNoise (`vendor/rnnoise`, built by `build.rs`).

## For AI agents

- **Inputs and outputs**: `sq-core-audio` maps project model values to edited project model values (no I/O). `sq-audiofx` maps sample buffers to sample buffers (`RealtimeAudioFX` for playback, `OfflineAudioFX` for offline rendering). `sq-audio-out` maps a ring of samples to the output device and exposes the audio clock.
- **Invariants**: time is rational (`sq_core_time::Time`), never `f64`; media files are never changed by silence removal or ducking; live ducking is evaluated in the one mix path (`live_ducking.rs`); the clock holds at its anchor until the first audible sample left the output.
- **Paths**: `crates/sq-core-audio/src/` (`ducking.rs`, `live_ducking.rs`, `silence_removal.rs`, `filler_words.rs`, `audio_gain.rs`, `audio_role.rs`), `crates/sq-audiofx/src/` (`realtime_audio_fx.rs`, `offline_audio_fx.rs`, `loudness.rs`, `role_chain.rs`, `presets.rs`), `crates/sq-audio-out/src/` (`output/`, `ring/`, `clock/`), `crates/sq-playback/src/audio/`, `crates/sq-export/src/core/loudness.rs`.
- **Commands**: `cargo xtask check sq-core-audio`, `cargo xtask check sq-audiofx`, `cargo xtask check sq-audio-out`; before a merge also the crates that depend on them (`sq-playback`, `sq-export`, `sq-editor-session`).
- **Open items**: `crates/sq-core-audio/NOTES.md` lists what is not ported yet.
