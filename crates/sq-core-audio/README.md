# sq-core-audio

Audio, ducking and caption logic on top of `sq-core-model` (port of the audio part of Swift `SQCore`): Audio Gain and
its dialog plan, the volume line, audio roles, channel maps, audio effect catalog entries and their DSP values, Auto Duck,
live ducking (curve, bake, index), silence and filler-word cuts, voiceover helpers, the tone generator and caption
editing, tidying, translation and handover.

Swift extensions on model types are extension traits (`VolumeLineExt`, `TimelineRoleExt`, ...). Ids come in as
`&mut dyn IdSource`, user defaults as the small `DefaultsStore` trait. What cannot be ported yet is listed in `NOTES.md`.

## Tests
`cargo xtask check sq-core-audio`.
