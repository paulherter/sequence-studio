# Core features 3: groups, source patching, four-point edits (SQCore)

Job G on `Packages/SQCore`. **Not compiled or run**: the cloud session had no Swift toolchain (download.swift.org is
blocked by the egress policy), so the code and tests below were written by reading only. First step on the Mac:
`scripts/test.sh SQCore`, fix whatever the compiler finds, then wire the UI.

## What the core now does

### Groups (`Timeline+Group.swift`, `Clip.group`)
- `Timeline.group(_ ids:) -> UUID` (Cmd+G): two or more clips, existing groups of the clips merge (no nesting). Locked track refuses.
- `Timeline.ungroup(_ ids:)` (Shift+Cmd+G): ungroups the whole group of every selected clip, returns the freed IDs. A/V links untouched.
- `linkedGroup(_:individual:)` is now the closure over links **and** groups, so move, nudge, lift, ripple delete, speed, enable,
  duplicate, nest and the three-point helpers already treat a group as one unit.
- Trims (`trim`, `rippleTrim`) act on the group's outer edges only: members whose edge is not on the group boundary are left
  alone, and a trim started on an inner edge returns `.zero`. Ungrouped link partners follow as before.
- `individual: Bool` (Option-click) on `trim`, `rippleTrim`, `move`, `lift`, `nudge`, `rippleDelete` ignores link and group.
- Split / add edit / insert / clear: right halves of one group share a new group ID (same rule as links). Paste keeps a group
  only between copies; a single copied member is ungrouped. Option-drag copies get `CopySpec.group`. Freeze frame inserts are ungrouped.
- `expandedSelection(_:individual:)` gives the clips a click selects; `groupMembers(_:)`, `dropOrphanGroups()` for tidying.

### Source patching (`Timeline+SourcePatch.swift`, `Track.isSourcePatched`)
- Separate per-track state. `sourceEditTargets` (Insert/Overwrite from the Source monitor) now uses the first patched video
  and first patched audio track. Track targets still decide paste, add edit, navigation and match frame.
- `togglePatch(_:shift:option:)` mirrors `toggleTarget`; `patchedTracks(_:)`; `resetPatchesToTargets()`.
- File version 24 (`t[23] = migrateV23toV24` in `ProjectFile+V24.swift`): older tracks get `isSourcePatched = isTargeted`.
  `Track` decoding applies the same default, `Track.init` defaults the patch to `isTargeted`.
- Drag and drop onto the timeline still uses the pointer track, then targets (`dropTargets` unchanged).

### Four-point edits (`FourPointEdit.swift`)
`Timeline.resolveFourPoint(source:sequence:choice:total:frameDuration:) -> FourPointPlacement?` is pure.
Choices: `fitClip` (changes speed), `ignoreSourceIn`, `ignoreSourceOut`, `ignoreSequenceIn`, `ignoreSequenceOut`.
The result has `source`, `at`, `speed`, `duration`; a source shorter than needed gives a shorter clip, never a range outside the media.
It does not place anything: the caller places `source` at `at` with `threePointEdit`, then sets `Clip.speed` when `speed` is not normal
(set it before placing if you want one undo step).

## What the Mac UI layer must add

| Area | Needed |
|---|---|
| Edit menu / commands | **Group** (Cmd+G) and **Ungroup** (Shift+Cmd+G) on the clip selection, one undo step each; disabled with fewer than two clips / no grouped clip. |
| Selection | Click, marquee and select-all go through `expandedSelection`. Option-click selects one member (`individual: true`). Draw group members with a shared outline or the Group label in the Info panel. |
| Edit calls | Pass `individual: true` from Option-drag, Option-trim and Option-Delete. Run `dropOrphanGroups()` after a delete that used `individual`. |
| Trim cursor | Show the trim cursor only on a group's outer edges (`outerEdgeMembers` rule); inner edges show none. |
| Track headers | Second button per track: **source patch** (Source V1 / A1 style), beside the target button. Click flips, Shift-click all of the kind, Option-click only this one (`togglePatch`). Patch and target look different (patch = filled source label, target = outlined). Accessibility: "Source patch V1". |
| Source monitor edits | Insert / Overwrite / drag-to-timeline icons call `sourceEditTargets` (now patches). Nothing else changes in the call chain. |
| Four-point edit | When the Source monitor has In/Out and the sequence has In/Out and their lengths differ, show the Edit Range Mismatch sheet with the five `FourPointChoice` options (Fit Clip is the default), call `resolveFourPoint`, place with `threePointEdit(source:at:)` and apply `speed`. Equal lengths: no sheet. |
| Sequence settings | "Reset patches to targets" is optional (`resetPatchesToTargets`). |
| Project open | v24 files carry the patch; nothing to do for older files. |
| Not covered | Nested groups (groups merge), group keyframe/effect copy, multi-channel audio patching (one audio track per source). |
