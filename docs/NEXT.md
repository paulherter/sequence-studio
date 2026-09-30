# Next session plan (2026-10-01) — three parallel streams, one agent each (worktrees)

Sources: docs/FEEDBACK-4.md (items 1–17), decisions in DECISIONS.md "plan decisions after fourth test", Premiere screenshots in docs/reference/premiere/ (local).

## A. Keyframes & Effect Controls (FEEDBACK-4 1–8, 14, 17-keyframes)
Premiere-like keyframe area: ruler + clip bar + draggable playhead at the TOP; keys once per row; expanded row = speed graph only; bigger eased glyphs (hourglass); zoom (pinch, +/-, zoom scrollbar with round handles at the bottom); timecode bottom-left; ◀ ◆ ▶ next to values; axis-locked handle drags (horizontal stays horizontal); moved key gets deselected; value edits never feel like a mode change; reset = value at playhead (+ separate reset all); Shift-snap of the playhead to keyframes; decluttered graph labels; scrubbing its playhead stops playback (like the timeline, item 18); draggable left/right divider with min/max, hidden when nothing is selected (item 19); Motion/Opacity sections above Text (26).

## B. Colour panel (FEEDBACK-4 13)
Rebuild the UI as fixed Lumetri sections (see DECISIONS), exact sub-layout per screenshots 14–16 (coloured Temperature/Tint tracks, blue right-aligned editable values, Creative look popup with thumbnail + prev/next, Adjustments, tint wheels). Processing: Basic Correction sliders before the Input LUT. Migrate existing v11 blocks into the fixed sections. Keep maths from the current SSRender blocks.

## C. Timeline & Program monitor (FEEDBACK-4 9–12, 15–17)
Page-wise follow during playback, manual scroll wins; no black frame on far seeks (hold last frame); clip-name overdraw bug under the playhead; Shift-snap of the playhead to edit points in the timeline; Hand tool + trackpad pan/zoom in the Program monitor; Type tool (T) per DECISIONS; wire TransformOverlayView so Motion can be dragged/scaled/rotated in the monitor with live values, incl. visible draggable anchor point and smart-guide snapping (23); Q/W playhead follows the edit (20); white selection outline (21); audio meter panel right of the timeline (24); compact header like Premiere (25); text clips render in playback/export (26); tool column order per item 27 (Pen/Shape/Mask = later scope, keep slots); Transcribe wiring (22).

Process: implementer per stream (Sonnet), reviewer before merge for B (colour) and anything touching the project file/undo; Paul tests after each merge; no screenshot testing by Claude.
