# Audio

Fix, clean and balance sound: effects, noise reduction, silence removal, ducking and loudness.

## Clip audio basics

- **Audio Gain**: choose Clip > Audio Options > Audio Gain… (G). The keys [ and ] lower and raise the gain of the selected clip. Gain Steps in the same menu move it by 1 dB or 6 dB.
- **De-Click**: Settings > Audio > De-Click puts a 3 ms fade at the start and end of every audio clip, so edits do not pop.
- **Roles**: Clip > Audio Options > Tag Role marks a clip as Dialogue, Music or SFX. Ducking and loudness use these roles.

## Audio effects

Audio effects work on a clip or on a whole track. The list includes: Noise Reduction, EQ (3 band), Graphic EQ, Parametric EQ, Compressor, Multiband Compressor, De-Esser, De-Reverb, Gain, Limiter, Noise Gate, Delay, Reverb, De-Hum, Low Cut, High Cut, Dialogue Leveler, Stereo Width, Chorus and Notch.

Presets include "Voice" and "Rode NTG Indoor".

Track controls (in the Controls panel for a track) include a role and preset choice (a new Role gives an untouched chain that Role's own settings; a chain you edited or picked stays as it is, and picking the same Role again brings the Role's own settings back), Denoise, a compressor with an On switch and a crossover strip, a Noise Gate with attack, hold and release, and Warmth with a mix amount. The Effects tab adds the EQ (four bands: a low shelf, two bells and a high shelf, each with Frequency, Gain and Width (Q); a bell's Frequency is its middle, a shelf's Frequency is its corner, so a typed frequency gives a bell its full Gain there, and changing a bell's Width keeps its middle where it is), the Noise Gate, Noise Reduction, Warmth and the Multiband Compressor. These settings belong to the whole track, so every clip on that track follows them; clips on other tracks are not touched. The Frequency slider runs on a log scale from 20 Hz to 20 kHz, so the low frequencies get as much room on the track as the high ones. You can type a value into any EQ field, also while the Multiband Compressor is off. Everything you change there is saved with the project and applies in playback and in export alike. Selecting a linked video and audio pair shows the audio clip's track controls below the video controls, so you do not need to unlink the pair to reach them. Editing a value keeps the panel where it is scrolled.

Clip > Audio Options > Voice also holds Voice Chain, Disguise Voice, Voiceover from Text… and Record Voice-Over.

## Noise suppression

Add the **Noise Reduction** effect to a clip. Its Amount slider (in percent) sets how much noise is removed. For a steady hum, there is also De-Hum.

## Remove silences

1. Select an audio clip.
2. Choose Clip > Audio Options > Clean Up > Remove Silences….
3. Set Level (dB), Min. Length (ms) and Keep Each Side (ms). The ranges that will be cut show in red on the timeline.
4. Click Remove, or Mark for Review to look first.

Silences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync. Messages you may see: "Select an audio clip first.", "The audio is not analyzed yet. Try again in a moment.", "No silences found."

With Mark for Review, use Review, Accept and Reject Proposed Cuts in the same menu. Remove Filler Words is there too.

## Ducking (music under speech)

There are two ways.

**Live Ducking** lowers Music tracks while Dialogue tracks speak, during playback and export. It does not change your clips. Turn it on in Settings > Audio, or use Clip > Audio Options > Live Ducking for This Project…. Settings let you choose Duck amount, Duck Preset (Soft, Hard, Custom) and timing (Lookahead, Attack, Recovery, Hold, Minimum pause). It is off by default.

**Bake Live Duck to Keys** (Control-Option-D on the Mac) writes the ducking as volume keys on the music clip, so you can fine tune it by hand.

1. Tag the music clip as Music and the speech clips as Dialogue.
2. Choose Clip > Audio Options > Bake Live Duck to Keys.

Pauses in dialogue of 0.6 seconds or longer let the music come back. If a clip already has duck keys, you are asked whether to replace them. If Live Ducking is also on, the music ducks twice, and a dialog offers to remove the keys.

## Loudness

- **Match Loudness** (Control-Option-L on the Mac) matches the loudness of selected clips.
- At export, turn on **Normalize** in the Audio section. Options are Loudness Range (needs a program of 60 seconds or more) and True Peak Max (-9 to 0 dBTP).
- **Audio Check** reports loudness, true peak, clipping, gaps, dual mono and sync.
- A sequence's delivery target sets the loudness: TikTok, Reels, Shorts, feed posts and YouTube all aim at -14 LUFS with a true peak ceiling of -1 dBTP.

Other Audio settings: Crossfade kind and length, J / L Offset per role, Meter Response (Smooth or Fast) and Fade Shape.

## Windows and Linux

Audio effects on Windows and Linux are still being checked. See below.

## Not sure yet

- Which audio effects work on Windows and Linux in the current alpha.
- The exact Effects panel folder that holds Noise Reduction.

Related: [Editing](02-editing.md), [Export](08-export.md), [Shortcuts](11-shortcuts.md), [Settings and Updates](10-settings-and-updates.md)
