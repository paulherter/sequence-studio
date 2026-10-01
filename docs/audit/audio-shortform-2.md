# Audit: audio-shortform (round 2, project file v20)

| Feature | Premiere | Sequence Studio | Done |
|---|---|---|---|
| Gain keys `[` / `]` (1 dB, Shift 6 dB) | not in the Adobe mirror (unverified); Audio Gain (G) confirmed | Clip > Audio Options, one undo step, floor never mutes, video ignored | yes |
| Clip gain vs track level | Audio Gain is independent of the mixer/track level and combined with it for the final mix (verified, adjusting-volume-levels.txt) | clip gain (inside `Clip.volume`) x track fader x pan, applied once in `AudioFeeder`, so playback, scrub and export match; tests through crossfade, speed, time remap, disabled clip | yes |
| Fade vs audio transition | a transition is added to the end of a clip to fade in/out (verified), i.e. it takes the handle's place | an audio transition on an edge removes that edge's fade and hides its handle | yes |
| Fade handles on audio clip edges | interactive handles drag a fade, vertical drag shapes the slope (verified, what-s-new text); slope not built | head/tail handles via `SQCore/Fades.swift`, sub-frame snaps to 0, follow trim | yes (no slope) |
| Rubber band Cmd-click key | Cmd-click (Mac) creates keyframes, Pen tool too (verified) | Cmd-click adds a key, keys cannot cross neighbours | yes (no Pen tool) |
| Auto duck | Auto Ducking with Fade Position slider (verified) | pure function, dialogue/music tags, re-run replaces generated keys; no fade-position control | partly |
| Normalize / match loudness | Normalize Max Peak / All Peaks to dB, Adjust Gain by, Set Gain To (verified) | Match Loudness to -14 LUFS (tag-dependent), clamped; peak normalize not built | partly |
| Track pan and volume | track level in mixer; pan/balance control on the track (verified); the Adobe text names no pan law (unverified); Balance effect is stereo-only (verified) | stereo media: balance (centre unity, only the far side attenuated); mono media: equal power scaled to unity at the centre, capped at unity; never a boost; fader and pan ramp across one block; nested sequences apply inner then outer track mix | yes |
| Peak meter, clip latch | not re-verified | hold 1.5 s, latch until reset (pre-existing, tested) | yes |
| Clip tags Dialogue/Music/SFX | automatic tagging exists in Premiere (verified, what-s-new) | manual tags in Audio Options | yes |
| Pause removal | not an Adobe command (Text-Based Editing has it, unverified) | "Remove Silences..." dialog built and tested, but hidden behind `FeatureFlags.removeSilences = false` until Paul decides | hidden |

Not verified: exact `[` / `]` step sizes. Not looked at offscreen: RemoveSilencesDialog and TrackMixDialog layout.

Fade keys are now marked (`FadeMarks`, in the clip): a fade only touches its own keys; user and Auto Duck keys inside a fade region stay with their own values (the line passes through them).
