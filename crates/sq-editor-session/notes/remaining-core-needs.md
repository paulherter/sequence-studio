# Core functions the session still waits for

Every item below has a `pending!("ESn")` body (or a `// shortcut:` stand-in) in `sq-editor-session`. The signatures are the
Rust shape the session expects (receiver `&mut Timeline` / `&mut Project` as in Swift, `ids: &mut dyn IdSource` where the
edit creates objects). A core worker adds them to the named crate; then the session body is wired (one call each).

## sq-core-edit / sq-core-model (Timeline)
- `Timeline::bleep(&mut self, range: TimeRange, tracks: &[Id], tone: ToneSpec, ids) -> Result<Id, EditError>` (ToneGenerator.swift:144) -> ES1 `bleep_range`.
- `Timeline::remove_track(&mut self, id: Id) -> Result<(), EditError>`, `remove_empty_tracks(&mut self) -> Vec<Id>` (PictureMask.swift:70, :82) -> ES2 `delete_track`, `remove_empty_tracks`.
- `Timeline::delete_targeted_tracks(&mut self) -> Result<Vec<Id>, EditError>` (ProjectFile+V91.swift:31) -> ES2 `delete_targeted_tracks`.
- `Timeline::sync_audio(&mut self, id: Id, to: Id, fit: AudioDriftFit, retime: bool) -> Result<(), EditError>` (AudioDriftFit.swift:117; the fit type is there) -> ES2 `sync_audio`.
- `Timeline::disguise_voice(&mut self, range: TimeRange, clips: &BTreeSet<Id>, voice: i64, ids) -> Result<Vec<Id>, EditError>` (AudioEffectsPitch.swift:96) -> ES6 `disguise_voice`.
- `Timeline::resize_transition_layer(&mut self, id: Id, edge: ClipEdge, by: Time, symmetric: bool) -> Result<Time, EditError>` (TransitionLayer.swift:215) -> ES4 `resize_transition_layer`.
- `Clip::is_color_match_picture(&self) -> bool` and `Timeline::color_match_pair(&self, target: Id, playhead: Time) -> Option<ColorMatchPair>` (ColorMatchToClip.swift:24, :36); `ColorMatchPair { target, target_time, reference, reference_time }` replaces `es04_effects/stand_in.rs` -> ES4 `has_color_match_target`, `color_match_to_clip_plan`, `apply_color_match_to_clip`, ES6 `request_color_match_to_clip`.
- Bake (UserPresetBake.swift): `Clip::baked_effects(&self) -> Vec<BakedEffect>`; `Timeline::can_convert_to_keyframes(&self, effect: Id, clip: Id) -> bool`, `convert_to_keyframes(&mut self, effect: Id, clip: Id) -> Result<(), EditError>`, `can_reopen_as_effect(&self, record: Id, clip: Id) -> bool`, `reopen_as_effect(&mut self, record: Id, clip: Id) -> Result<(), EditError>` -> ES4 `presets.rs` (4 methods).
- Angles (Angles.swift, Angles+Flatten.swift): `angle_candidates(&self, of: &[Id]) -> Result<Vec<Vec<Clip>>, EditError>`, `make_angles_sequence(...)`, `make_angles_clip(&mut self, from: &[Id], in_timeline: Id, name: Option<&str>, ...)`, `switch_angle(&mut self, index: i64, at: Time, clip: Id, silent: &BTreeSet<i64>) -> Result<Option<Id>, EditError>`, `set_angle(&mut self, index: i64, on: Id, silent: &BTreeSet<i64>) -> Result<bool, EditError>`, `set_audio_follows_video(&mut self, on: bool, clip: Id) -> Result<bool, EditError>`, `flatten_angles(&mut self, clip: Id, in_timeline: Id) -> Result<Vec<Id>, EditError>`, plus `AnglesOffsets`, `angle_names`, `silent_angles` -> ES2 `angles.rs` (9 members).
- DONE: `Timeline::delete_caption`, `move_caption`, `trim_caption`, `normalize_audio_key_marks` (sq-core-audio, sq-core-edit), wired.

## sq-core-project / sq-core-model (Project)
- Grouping.swift: `Project::group(&mut self, clips: &[Id], in_timeline: Id, ids) -> Result<Id, EditError>`, `ungroup(&mut self, clip: Id, in_timeline: Id) -> Result<Vec<Id>, EditError>`, `unnest(&mut self, clip: Id, in_timeline: Id) -> Result<Vec<Id>, EditError>` -> ES1 `group_selection`, `ungroup_selection`, `unnest_selection`.
- `Timeline::is_group(&self) -> bool` is used by ES9 `sequence_items` (every timeline counts as pickable until then).
- ColorGradeTargets.swift: `Project::prepare_source_grade_edit(&mut self, id: Id) -> bool`, `set_grade_linked_to_source(&mut self, id: Id, on: bool) -> bool`, `ensure_sequence_grade(&mut self, timeline: Id, ids) -> Result<Id, EditError>`; replaces the `ProjectGradeTargets` stand-in in `es04_effects/stand_in.rs` (color edits already call it in Swift's order).
- DONE: MediaPolicy (`ProjectFolderSyncExt`, `new_bin_ids`, `FolderSyncAdd`, `MediaPolicyDefaults`), `Project::merge`, smart bin verbs and
  `used_fraction` (sq-core-model), `SmartBinMatchExt`, `RelinkPlanner`, `RelinkScanner::scan_media` / `reconnect_roots`,
  `NearProjectRelinkPlanExt::plan` (sq-core-project), `RenderCacheMedia` (sq-core-model). `project_ops.rs` deleted.
- Left: `Timeline::with_render_cache` (needs `RenderCacheSegment` from sq-core-project, so it cannot sit in sq-core-model).

## sq-core-model: TitleTemplate (TitleTemplate.swift)
The session has a stand-in `TitleTemplate { name, duration, slots }` in `es05_captions_titles/templates.rs`. The core type needs
`content: Timeline` (its `tracks` feed `TemplateTextStyle::from_tracks`), `TitleTemplate::capture(clips: &[Id], in_timeline: Id, project: &Project, name: &str, ...)`,
`Project::apply_title_template(&mut self, template: &TitleTemplate, in_timeline: Id, track: Id, at: Time, ...)`,
`Project::set_template_slot(&mut self, slot: Id, value: SlotValue, clip: Id) -> Result<(), EditError>`,
`TitleTemplate::detect_zones(content: &Timeline, extra_key_times: &[Time]) -> AnimationZones`,
`Project::auto_detect_animation_zones(&mut self, clip: Id) -> Result<(), EditError>`
-> ES5 `title_template_from_selection`, `insert_title_template`, `set_template_slot`, `set_zones_enabled(true)`, `apply_template_style`.

## Not core, left pending
- ES4 `LookStore::import_caption_presets`: done (sync). `flatten_angles`: done as a private helper in `angles.rs`; move it next to `unnest` in sq-core-edit `grouping.rs`.
- ES6 `FrameSampler::sample_color` (Mac Metal readback, no portable path); ES3 `caption_box` (caption text layout, `CaptionMonitorHit.textRect`).
- Platform glue the app owns: `preview_look` (needs a `ProgramEngine` look preview), Color solo file view and render cache spans in `push_timeline`.
