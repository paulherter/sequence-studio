# sq-core-edit, integration ED-5

## Helpers with one home now
`floored_to_frame`, `clear_main_track_attachments` (sq-core-model, `pub`), `plays_through_zones`, `trim_spaces` (sq-core-model,
`pub`; used for `trim_whitespaces`), `FadeKeys::snap_down` (model, `pub`), `is_fast_cut` (`MagneticOpsExt`), `add_track`
(`AddTrackExt`, replaces `push_track`), `held_back_partners` (`SoloExt`). The `FlooredToFrameExt` trait of timeline_solo_views is gone.
Still open from g1: sq-core-audio `voiceover.rs` keeps its inline `add_track` copy (sq-core-audio cannot depend on this crate).

## Ported here (were waiting)
- Fast Cut verbs: `timeline_magnetic_verbs` (`MagneticVerbsExt`: delete, spacer, ripple trim, roll, slip, slide, nudge, add edit,
  join, rearrange, move, move attached, lift off / onto / put on main, clipboard, paste, duplicate, extract, clear range;
  `MagneticNestExt` for `Project`), `timeline_magnetic_moves` (`MagneticGesturesExt`: lane gap, copy, rearrange block, drag off
  main (set), trim to playhead, apply speed, rate stretch, speed keys, frame holds, move to lane), `position_move`
  (storylines), `place_block` (title block). All keep g1's shape: `(MagneticScope, ids, |tl, ids| ...)`; every verb that mints ids
  takes `ids: &mut dyn IdSource`.
- Normal-mode verbs they needed: `trim_to_playhead` + `PlayheadTrimMode`, `insert_copy`, `insert_move`, `duplicate`,
  `TimelineClipboard::stripping_attachments`.
- `trim_edit` goes through `magnetic_ripple_trim` / `magnetic_roll` (takes `ids` now); `move_into_sync` has the Fast Cut branch
  (the `offsets` argument stays; the partners recompute `sync_offsets()` inside, as Swift does).
- `detach_audio`, `trim_to_range`, `source_edit_targets`, `replace_on_main_track_mode`, `place_sequences`
  (`SequencePlacement` carries host / time / track / new track / mode), `place_sequence_clips` (+ `sequence_clip_board`),
  `cut_to_beats` / `snap_to_beats` / `beat_times`, `close_gaps_at_playhead`, `jump_cut_alternate` (+ candidates, `is_jump_cut`),
  `accept_proposed_cuts` + `remove_silences` + `soften_joins`, `fill_reel`, `pour_still`, `copy_with_fresh_ids(_mapped)`,
  `punch_in_cuts`, clip marker edits (`timeline_clip_markers`), caption word wrappers (`captions_words`, with
  `CaptionTrack::with_items` added to sq-core-model).
- Swift tests translated: MagneticEditTests (all but the engine-rule cases), JumpCutTests, CutToBeatsTests, the CutKeys / ProposedCut
  accept cases, TrimToPlayheadModeTests, MuteDetach / TrimToRange / TitleBlock / fast-cut position move and move-into-sync (own cases).

## Crate layout
- `project_launch_path`: ported here; `sq-core-file` was already a dependency.
- `new_project_input` moved to `sq-core-project/src/sequence_format_presets.rs` (with the size, frame-rate and sample-rate lists;
  `Named` delivery presets are not ported). `resolve_command_table` moved to `sq-core-project/src/foreign_keymap.rs`
  (`Target`, `resolve_target`); the local `ResolveTarget` mirror is gone.

## Still open
- `Project.unnest` and `Angles+Flatten` (`flatten_angles`): Grouping.swift (group / ungroup / unnest, about 330 lines) has no owner
  in any group and is not in sq-core-model; port it as one module, then `flatten_angles` is 30 lines on top.
- `NearProjectRelink.plan` and `WorkLimits.pools`: need `RelinkPlanner`, `RelinkScanner`, `MediaPathResolver`, `WorkLimits`, which
  are still one-line skeletons in sq-core-project (that crate depends on this one: the two functions belong there).
- `SafeZoneChoice` (SafeZone / NormRect) is in no crate; `platform_uimock` waits for it.
- Swift fuzz suites, FastCutRoutingTests, FastCutBypassVerbsTests, FastCutNoGapTests, MagneticMoveStepTests, MagneticMovesTests
  (copy / drag-off set / trim-to-playhead / speed / frame-hold cases), NestPlaceSequenceTests, ReelFillTests, SourceEditTests target
  cases, PunchInCutsTests, caption word wrapper tests, CutKeys `closeGaps` on locked tracks of Fast Cut are not translated.
- `destinations` in jump_cut.rs lacks Swift's `lo + shift < 0 -> shift = b` guard (the Rust comment says odd blocks never leave
  the list); behavior is the same for every input the Swift tests use.
