# Audit: audio-shortform (round 2, project file v20)

| Feature | Premiere | Sequence Studio | Done |
|---|---|---|---|
| Gain keys `[` / `]` (1 dB, Shift 6 dB) | not in the Adobe mirror (unverified); Audio Gain (G) confirmed | Clip > Audio Options, one undo step, floor never mutes, video ignored | yes |
| Clip gain vs track level | Audio Gain is independent of the mixer/track level and combined with it for the final mix (verified, adjusting-volume-levels.txt) | clip gain (inside `Clip.volume`) x track fader x pan, applied once in `AudioFeeder`, so playback, scrub and export match; tests through crossfade, speed, time remap, disabled clip | yes |
| Fade handles on audio clip edges | interactive handles drag a fade, vertical drag shapes the slope (verified, what-s-new text); slope not built | head/tail handles via `SQCore/Fades.swift`, sub-frame snaps to 0, follow trim | yes (no slope) |
| Rubber band Cmd-click key | Cmd-click (Mac) creates keyframes, Pen tool too (verified) | Cmd-click adds a key, keys cannot cross neighbours | yes (no Pen tool) |
| Auto duck | Auto Ducking with Fade Position slider (verified) | pure function, dialogue/music tags, re-run replaces generated keys; no fade-position control | partly |
| Normalize / match loudness | Normalize Max Peak / All Peaks to dB, Adjust Gain by, Set Gain To (verified) | Match Loudness to -14 LUFS (tag-dependent), clamped; peak normalize not built | partly |
| Track pan and volume | track level in mixer (verified) | constant-power pan + fader, "Volume and Pan..." in the track menu | yes |
| Peak meter, clip latch | not re-verified | hold 1.5 s, latch until reset (pre-existing, tested) | yes |
| Clip tags Dialogue/Music/SFX | automatic tagging exists in Premiere (verified, what-s-new) | manual tags in Audio Options | yes |
| Pause removal | not an Adobe command (Text-Based Editing has it, unverified) | explicit "Remove Silences..." dialog: threshold, minimum length, padding, count preview; one undo step | yes |

Not verified: exact `[` / `]` step sizes. Not looked at offscreen: RemoveSilencesDialog and TrackMixDialog layout.
