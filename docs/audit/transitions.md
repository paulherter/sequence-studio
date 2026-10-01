# Audit: transitions (stream `transitions`)

Before tonight: no transition type, no overlap evaluation at cuts, no two-layer blend, no audio crossfade.
Premiere behaviour verified against `docs/reference/adobe/{transition-overview-applying-transitions,modifying-customizing-transitions,audio-transitions}.txt`
and the Claremont help book (shortcuts). "(unverified)" = from memory.

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Where | Cut between two adjacent clips, or only the start / end of a clip (single-sided) | `Transition` on a `Track`, anchored to clip IDs: cut (outgoing + incoming touching), head (fade in), tail (fade out) | none | yes |
| Video kinds | Cross Dissolve (default), Dip to Black, Dip to White, many wipes | Cross Dissolve, Dip to Black, Dip to White | wipes, slides, other kinds | partly |
| Audio kinds | Constant Gain, Constant Power (default), Exponential Fade | Constant Gain, Constant Power | Exponential Fade | partly |
| Default duration | 1 second initially, Preferences (video frames / audio seconds) | 1 s in whole frames of the sequence; Settings > General fields (video frames, 0 = 1 s; audio seconds) | none | yes |
| Alignment | Center at Cut, Start at Cut, End at Cut, Custom Start (after dragging) | same four; `customBefore` frames before the cut | none | yes |
| Handles | Needs media beyond the cut; short handles: warning, repeated frames | Duration clamped to the handles (through speed and reverse); nothing fits = "Not enough media" and no change. No repeated frames (by decision) | repeat frames | no (clamp) |
| Edit operations | Transition follows its cut | Stored as intent, resolved lazily: cut gone = nothing plays and `Project.edit` prunes it; slip / trim re-clamp (slip back restores the length); roll and ripple move it with the cut; split of the outgoing clip drops it, of the incoming clip keeps it | copy / paste of two clips does not copy their transition | no |
| Linked A/V | independent | independent (per track) | none | yes |
| One transition per edge | yes | a new one replaces what sits on the same edge(s) | none | yes |
| Cmd+D / Shift+Cmd+D / Shift+D | Apply Video / Audio Transition, Apply Default Transitions to Selection | same keys and Sequence menu items; target = selected edit(s), else edges of selected clips, else nearest edit on targeted tracks | "Set Selected as Default Transition" | partly |
| Drag from Effects panel | onto a cut or clip end; side of the cut picks alignment | Effects panel lists Video / Audio Transitions; drop picks track, nearest edit within 36 pt, left = End at Cut, middle = Center, right = Start at Cut; clip ends take a one-sided one; double-click applies at the selection | none | yes |
| Timeline box | Box over the cut with the name | Translucent box with a dissolve diagonal and the name when 74 pt wide; accent outline when selected; red tick when shortened | none | yes |
| Click / Delete | selects; Delete removes | same (Delete also works from the menu) | none | yes |
| Edge drag | symmetrical when centred, Shift one side | same; clamped to the handles by the model | none | yes |
| Body drag | moves alignment over the cut | same, snaps to Start / Center / End, else Custom Start | none | yes |
| Double-click | "Set Transition Duration" dialog | same sheet (timecode or digits) | none | yes |
| Effect Controls | Duration, Alignment, preview | Duration (timecode field) and Alignment while a transition is selected | preview, Start/End sliders, Border, Reverse | partly |
| Context menu | on a cut: Apply Default Transitions; on a transition: Set Transition Duration, Clear | same | none | yes |
| Rendering space | Cross dissolve in the sequence colour space | Linear-light working space of the compositor (Rec.709 primaries): `(1-w)A + wB` as A at full opacity plus B at opacity w. Exact for opaque pictures; a transparent overlay (V2+) fades in but its out-going side does not fade out where the incoming picture is transparent | alpha-correct two-layer dissolve | no |
| Dip colour | | solid layer under the faded clips; covers the lower tracks while it dips | | no |
| Audio | Constant Power cos/sin, Constant Gain linear | per-sample gain curves in `AudioFeeder` (shared by playback and export), 256-frame linear interpolation of the curve; both clips play into their handles | retimed (speed != 100 %, pitch kept) incoming clips are silent in the head extension: the stretcher's grain grid starts at the clip start | partly |
| Project file | | v17: `Track.transitions`, identity migration; older builds drop them on save | none | yes |

## Weights

Video: incoming weight of frame i of N = (i+1)/(N+1) (strictly inside 0...1; a 1-frame transition is the 50 % mix). Dips: outgoing fades to the dip colour over the first half, incoming from it over the second, full dip colour at w = 0.5.
Audio: progress p = (t - span.start) / duration per sample time; Constant Power out = cos(p pi/2), in = sin(p pi/2); Constant Gain out = 1-p, in = p.

## Numbers

- Export: two sine tones (440 Hz / 1 kHz) through a 1 s Constant Power crossfade: worst 50 ms window deviates 0.00006 dB from the single-tone level (limit 1 dB). Constant Gain dips 3 dB in the middle as expected.
- Export frames at 25 / 50 / 75 % of a 20-frame dissolve of pure red into pure green match the linear-light blend within 3/255 (an encoded-space blend would be 128 at the middle, linear light gives 180).
- Playback, 1080p30 H.264 pair (both clips decoded inside the span), HostClock ticks every 8 ms, 5 s through a 1 s dissolve: 150 presented, 0 dropped; tick mean 1.44 ms (max 9.1 ms) against 1.07 ms (max 5.0 ms) for the same plain cut; decode calls 20 vs 17. Opt-in test `SQ_PERF=1` (`TransitionPlaybackTests.dissolveFiveSecondPlayAt1080p`; writing the clip takes ~110 s).
- Not click-tested; the timeline box and Effect Controls panel were rendered offscreen once (2x) and look right.
