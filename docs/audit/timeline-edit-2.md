# Audit: timeline-edit, round 2 (stream 1, project file v18)

Sources: code read in this worktree, `docs/spec/timeline.md` backlog numbers in brackets, and the local Adobe mirror
(`docs/reference/adobe/*.txt`, read-only, grep). Nothing copied from Adobe. "verified" = found in the Adobe text,
"corrected" = the Adobe text differs from the plan, "unverified" = not in the text (web source or memory only).

## Verify against Adobe text

| Row | Result | Note |
|---|---|---|
| Q / W = ripple trim previous / next edit to playhead | verified | `keyboard-shortcuts.txt`, same keys on Mac |
| Opt+Q / Opt+W = Trim Previous / Next Edit to Playhead (not ripple, gap stays) | verified | same table, Mac column `Opt + Q` / `Opt + W` |
| Shift+Q / Shift+W = rolling variant | unverified | not in the shortcut table; only the earlier web note (ProVideo Coalition). Built as planned, bound in the timeline scope only |
| Ctrl+T cycles the trim type | verified (key) | `Toggle Trim Type` is Ctrl+T on Mac. `trimming-clips1.ug.txt`: "changed from the current type to the next type in the order". The order itself is not given, ours: regular, ripple, rolling, regular |
| Duplicate = Shift+Cmd+/ | verified | Mac column |
| Enable = Shift+Cmd+E (plan said Shift+E) | corrected | Mac column is `Shift + Cmd + E`. Windows is Shift+E. Export Frame stays Shift+E; our extra Cmd+Shift+E Export Frame binding was removed to free the key |
| Opt+Up / Opt+Down moves selected clips one lane | unverified | no such row in the table. Built as planned; audio-only selections move visually (up = toward video), mixed selections mirror like dragging |
| Shift-constrained clip drag | unverified | the text only has Option for axis lock in transition curves and Shift for shape aspect. Built as planned (axis chosen by the first 4 pt of travel, while Shift is held) |
| Zoom tool: click zooms in one increment, Alt/Opt-click out | verified | `panels.txt` (Zoom Tool). The marquee is not in that text; built as planned |
| Zoom keys `=` and `-` | verified | table rows Zoom In / Zoom Out. The per-press factor is not stated anywhere in the text |
| `\` fits the sequence and toggles back | unverified | no `\` row in the table; already built and kept |
| Cmd+Opt-drag | corrected | `rearranging-clips-sequence.txt` calls Cmd+Opt-drag of a timeline clip a "rearrange" (a move that closes the old gap and inserts). Our plain Cmd-drag already does that. The plan asks for Cmd+Opt = insert a copy, built as planned (Option = copy, Command = insert). Flagged for Paul |
| Target buttons: Shift / Option click | unverified | `source-patching-track-targeting.txt` has no modifier text. Built: Shift = all tracks of that kind switch to the state this one is switching to, Option = only this track of its kind |

## Inventory and result

| # | Item | Existed before | Now | Tests |
|---|---|---|---|---|
| 1 | Q/W Shift/Opt variants | Q/W ripple only | `Timeline.trimToPlayhead(_:at:tracks:mode:)` (`.ripple/.roll/.plain`), commands `rollTrimPrevious/Next`, `trimPrevious/Next`, Sequence menu entries, one undo step each | A=[0,10) B=[10,20) at 7: roll gives [0,7),[7,20), plain leaves gap [7,10), ripple pulls B back 3; linked partners, locked track, no neighbour refused |
| 2 | Cmd+Opt drag = insert copy | Option-drag copy and Cmd-drag insert-move existed | `Timeline.insertCopy`, `TimelineEdit.insertCopy`, gesture "Insert Copy"; copies become the selection | copy at drop, later clips ripple, original stays, links, locked refused; gesture test |
| 3 | Zoom tool | Z key did nothing ("not available") | `TimelineTool.zoom`, click = one `keyStep` in, Option-click out, drag a box = zoom to it; pure `TimelineZoom.zoomClick` / `zoomMarquee`; menu item now shown | anchor time fixed, clamping, marquee fits, dragged either way |
| 4 | Zoom feel | `\` toggle with memory, zoom bar, Opt/Cmd+wheel, pinch, key step 2.5 all existed | per-press factor is the single constant `TimelineZoom.keyStep` (used by `=` `-` and the Zoom tool). **Kept at 2.5**: neither the Adobe text nor the research gives Premiere's factor, and "fit to about 1 s in at most 2 presses" needs a factor near 8 for a one minute sequence, too coarse to judge blind. From a one minute fit to a 1 s view is 5 presses today | constant pinned, steps count |
| 5 | Enable / Disable clip | no | `Clip.isEnabled` (default true, decodes true from old files, round-trips), `Timeline.toggleEnabled` (group as one, locked refused), skipped in `videoLayers` and `audioSegments` (one filter each), dimmed in the timeline, Shift+Cmd+E, Clip menu, context menu entry | decode/round-trip, render and mix skip, edits still work on disabled clips, v18 migration is identity, project file round trip |
| 6 | Duplicate | no | `Timeline.duplicate`: copies after the selection end on the same tracks, links kept between copies only, selection moves to the copies; Shift+Cmd+/, Edit menu. Cmd+D is not touched (transitions) | placement, links, overwrite, errors, session step |
| 7 | Ctrl+T trim type | no | `EdgeEdits.cycled` and `TimelineView.cycleTrimType` | cycle, edit without neighbour |
| 8 | Snap targets | clip edges, playhead, markers, 0 | `snapPoints` now includes In/Out marks (`SnapKind.inOut`) and, in gestures, keyframe times (`SnapKind.keyframe`) | In/Out within threshold, keys only when asked, own keys never attract |
| 9 | Hold-S snap flip, edge autoscroll | no | S pressed during a drag flips snapping until released (`handleSnapHold`, `TimelineInteraction.snapInverted`); autoscroll timer on clip, edge, marker, marquee and playhead drags (`TimelineAutoscroll.autoscrollSpeed(distanceFromEdge:)`) | monotonic, zero inside, capped; flip gesture test. The timer itself is not unit-testable |
| 10 | Opt+Up/Down | no | `Timeline.moveToLane`, `EditorSession.moveSelectionLane`, status message when blocked | up/down, outermost blocks, locked source/destination, mirrored V+A, overwrite |
| 11 | Target modifiers, Shift axis lock | one plain toggle; no lock | `Timeline.toggleTarget(shift:option:)` wired to the header chip; `AxisLock` in the move gesture | target cases, lock horizontal / vertical |
| 12 | Marker drag in the ruler | double-click dialog, M, next/previous existed; no drag | drag a flag: clamped at 0, snaps to clip edges / playhead / In-Out / other markers, one undo step; a plain click still seeks | `MarkerDrag.target`, session undo |

Already there and re-checked in code (no new work): edge and gap selection with Cmd = ripple, Option-drag copy, the markers dialog
(M twice, double-click), fast zoom `\`, zoom bar, Shift+M / Shift+Cmd+M.

## Project file
v18 owns `Clip.isEnabled`. Added only `migrateV17toV18` (identity) and its dictionary entry `17:`. `currentVersion` is **not** changed here
(protocol: set to the highest number on merge; v17 is transitions), so files written by this branch still say 16 and carry the extra key,
which older readers ignore.

## Not done / open
- Cursor does not follow Option for the zoom tool (zoom-in glyph only); modifier-following cursors need `flagsChanged` tracking.
- Keyframe snap targets have no preference toggle (always on in gestures).
- Trim large step preference, double-click header edge, Opt+scroll on headers: not in this stream's list.
