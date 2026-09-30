# Next session plan (2026-10-01) — four parallel streams, one agent each (worktrees)

Sources: docs/FEEDBACK-4.md (items 1–17), decisions in DECISIONS.md "plan decisions after fourth test", Premiere screenshots in docs/reference/premiere/ (local).

## A. Keyframes & Effect Controls (FEEDBACK-4 1–8, 14, 17-keyframes)
Premiere-like keyframe area: ruler + clip bar + draggable playhead at the TOP; keys once per row; expanded row = speed graph only; bigger eased glyphs (hourglass); zoom (pinch, +/-, zoom scrollbar with round handles at the bottom); timecode bottom-left; ◀ ◆ ▶ next to values; axis-locked handle drags (horizontal stays horizontal); moved key gets deselected; value edits never feel like a mode change; reset = value at playhead (+ separate reset all); Shift-snap of the playhead to keyframes; decluttered graph labels; scrubbing its playhead stops playback (like the timeline, item 18); draggable left/right divider with min/max, hidden when nothing is selected (item 19); Motion/Opacity sections above Text (26).

## B. Colour panel (FEEDBACK-4 13)
Rebuild the UI as fixed Lumetri sections (see DECISIONS), exact sub-layout per screenshots 14–16 (coloured Temperature/Tint tracks, blue right-aligned editable values, Creative look popup with thumbnail + prev/next, Adjustments, tint wheels). Processing: Basic Correction sliders before the Input LUT. Migrate existing v11 blocks into the fixed sections. Keep maths from the current SSRender blocks.

## C1. Timeline & shell (FEEDBACK-4 9, 10, 16, 17, 20, 21, 24, 25, 27)
Page-wise follow during playback (manual scroll wins); no black frame on far seeks (hold last frame); clip-name overdraw bug under the playhead; Shift-snap of the playhead to edit points; Q/W playhead follows the edit; white selection outline; audio meter panel right of the timeline; compact header like Premiere; tool column order per item 27 (Pen/Shape/Mask later, keep slots).

## C2. Program monitor, text, transcribe (FEEDBACK-4 11, 12, 15, 22, 23, 26)
Hand tool + trackpad pan/zoom in the monitor; Type tool (T) per DECISIONS; text clips render in playback/export; TransformOverlayView wired (move/scale/rotate with live values), visible draggable anchor point, smart-guide snapping; Transcribe works end to end.

Process: implementer per stream (Sonnet), reviewer before merge for B (colour) and anything touching the project file/undo; Paul tests after each merge; no screenshot testing by Claude.
