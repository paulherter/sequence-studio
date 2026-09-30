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
