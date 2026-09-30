# Decisions

- 2026-09-30: Name "Sequence Studio". macOS 26+, Apple Silicon only. License GPL-3.0. English everywhere.
- 2026-09-30: Own data model + own Metal renderer; engine route decided after Phase 0 spike.
- 2026-09-30: Panels: fixed splits in Phase 2, Premiere-style tab groups + drag-to-dock + workspaces in Phase 9. Layout stored as a tree from day one.
- 2026-09-30: No magnetic timeline. Easing is a core feature (bezier handles, value + speed graph, presets). Fewer clicks than Premiere, esp. captions.
- 2026-09-30: UX plan (docs/UX.md) before Figma and before Phase 2.
- 2026-09-30: UX plan approved (docs/UX.md). Default workspace from Paul's Premiere "Editing – PC"; Phase 2 ships two built-in workspaces (PC, MacBook) with a menu switch, custom docking stays Phase 9. No modes/pages, Export button in title bar.
- 2026-09-30: Effect Controls: summary keyframes on collapsed rows, right-click easing templates (own saved curves), relative multi-keyframe editing per property, stopwatch keyframing. All keyframes/volume edited in Effect Controls/Properties, none in the timeline.
- 2026-09-30: Transcript editing is text-only (never cuts media); re-transcribe overwrites. Caption/text styling lives in Properties.
- 2026-09-30: V1 adds Library (disk folders + own presets incl. animated text templates, own format, no .mogrt) late with text templates, and multi-sequence export. No Pen/Rectangle, no voice-over recording.
- 2026-09-30: UI visual language from the design canvas (docs/UX.md §7): Final Cut/AppKit look, Premiere behaviour but never Premiere glyphs; scrubbable values instead of sliders; animate diamond + eye toggles; keyframe shape = interpolation; compact tracks; one colour per clip type, first frame only.
- 2026-09-30: **Changes UX plan "no modes/pages":** two pages, Edit and Color (Final Cut-style colour wheels), switched in the title bar. A page is a built-in workspace on the same sequence, not a separate mode. (Paul)
- 2026-09-30: V1 scope additions: scopes (waveform, vectorscope), export details (Show Details) incl. loudness normalisation and sidecar .srt, background export queue with progress. Text-based cutting in the transcript stays out. (Paul)
- 2026-09-30: Color processing order, deliberately unlike Lumetri: the Color inspector is processed top to bottom as shown: Correction (WB, exposure… on the full log signal) → Conversion LUT (optional camera LUT; otherwise automatic color-managed conversion) → Creative LUT + intensity → curves, wheels, HSL, vignette → Rec.709 output. (Paul)
- 2026-09-30: Engine route B: own VideoToolbox decode path (AVFoundation demux, own clock, frame cache), not AVComposition + custom compositor. Spike showed a tie on scrub; B wins on backward step/reverse and fits eased speed ramps, nesting and live edits. No second spike; its checks became Phase 2 acceptance criteria in PLAN.md. (Paul)

## 2026-09-30 Ripple is timeline-wide (Premiere behaviour)
- Ripple edits shift all tracks with sync lock on; locked tracks stay, edits on them throw. Type is `Timeline` (not `Sequence`, avoids `Swift.Sequence`).
- Ripple that would collide on another track is limited, not cut through: ripple delete / shorten closes the gap only as far as every shifting track allows (returns the applied amount). Clips straddling the edit point on other tracks are never split or trimmed; extending just pushes whole clips at/after the old end. Cutting through other tracks = a separate extract op, not built yet.
- Ripple head trim keeps the clip's start, later content shifts (Premiere).
- `Clip.mediaDuration` (optional) bounds tail extension; head extension is bounded by source start 0.

