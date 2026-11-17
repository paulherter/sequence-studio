# sq-core-file notes

Port of `ProjectFile.swift`, `ProjectFile+V19 ... V94`, `ProjectFile+Salvage.swift`. Gate of the split plan: decoded model equal,
re-decode equal, same `formatVersion` chosen. Bytes are not compared (Swift escapes `/` as `\/`, writes `"key" : value`; this
crate writes plain JSON with sorted keys, whole `Double`s as integers like Foundation).

## Done
- `ProjectFile::{encode, decode, read, write, autosave, latest_autosave, read_salvaging, back_up_damaged}`, `written_version`
  (all 50 gates of v37 ... v94 in `gates.rs`, same order as Swift), the v77/v84/v85 flags from `EncodeContext::seen()`.
- Migration chain `migrations()` / `real_migrations()` (v1->2, v33->34 own code; v9->10, v23->24, v25->26, v26->27 re-encode
  through `ProjectFixups`), custom tables like Swift's `migrations:` argument, direct decode from v34 on.
- Safe write (temp file, fsync, rename, directory sync), `.bak` copies of older/newer files (keeps 3), autosave names
  `yyyyMMdd-HHmmss-SSS` (UTC, milliseconds as `i64`), `converted_path`, extension helpers.
- `ProjectFixups` (no-op default `NoFixups`): `prune_unused_groups`, `prune_variant_overrides`, `migrate_scale_to_source_pixels`,
  `migrate_legacy_shadow_color`.
- Tests: Swift ProjectFileTests, MigrationTable, DirectDecode, ProjectSalvageTests, backups of ProjectFileSafeWriteTests, a gate
  table, the Swift fixture `project-v71.json` (decoded, re-encoded, same content), write-then-read, hostile input sweeps.

## Deviations from Swift (decide with the oracle)
- `ProjectFileError` has two more cases, `Encode(String)` and `Io(String)`, for what Swift reports as Foundation errors.
- The v24 shadow step (`migrateLegacyShadowColor`, `ClipEffect.upgradingLegacyShadowColor`) is a fixup, not ported here: it
  mints keyframe ids. Swift keeps it in `ProjectFile+V24.swift`; `sq-core-project` or the effects crate should implement
  `migrate_legacy_shadow_color` with an `IdSource`.
- `real_migrations()` holds only the steps that change data (1, 9, 23, 25, 26, 33). Swift also lists named identity steps
  there; `migrations()` is identical.
- Autosave takes a `Timestamp`, truncates to milliseconds (Swift formats the `Date`, same truncation) and compares in whole
  milliseconds when a clock was set back.
- Temp file name is `.<pid>-<counter>.tmp` instead of a UUID (no random source in this crate).
- `formatVersion` must be an integer JSON number (Swift `as? Int` also accepts a float such as `94.0`).
- `FileReplace.replace` is `std::fs::rename` (atomic replace on Unix, MoveFileEx replace on Windows).
- `encode` clones the project to run `prune_unused_groups` (Swift copies too, copy-on-write). shortcut: one clone per save;
  upgrade when `NoFixups` makes it avoidable.

## Waiting on
- NaN and infinities: Swift writes `"NaN"`, `"Infinity"`, `"-Infinity"` strings (`nonConformingFloatEncodingStrategy`) and
  reads them back. `serde_json` writes `null` for a non-finite `f64` and the model's `f64` fields reject a string. A fix needs a
  serde helper for every `f64` field in sq-core-model (or an `F64` wrapper in sq-core-time). Until then a project holding a
  non-finite number round-trips as an error, not as Swift would. Hostile files with those strings decode to errors, never panics.
- `Clip::adopt_legacy_grade` (v26 -> v27 fold of `color` into Color effects; see `notes/m1.md`): files older than v27 lose that grade.
- `Project::normalize_bins` is only partly there (see `project.rs`), `Project::migrate_scale_to_source_pixels`,
  `prune_unused_groups`, `prune_variant_overrides` belong to `sq-core-project` (fixups).
- Gates read the model's fields directly because these helpers do not exist in sq-core-model: `Project::all_clips`,
  `Clip::holds_mask_inputs`, `Clip::transition_layer`, `GyroflowOptions::changes_lens_or_sync`, `ClipEffect::is_audio`,
  `ClipEffect::stabilize_method`, `ColorGraph` step v79/v80 field checks. When they land, call them and delete the local copies.
- `PictureMask.removeTrack` and `disguiseVoice` (named in the brief) are not called by any ProjectFile file in this tree.
- Not translated: the per-version Swift tests that build projects with edit verbs (`ProjectFileV56 ... V93Tests`, V77 legacy
  two-key fold, V85 follow padding, `HostileInputTests` edit-verb parts); they need Clip/Timeline verbs from the model and edit
  crates. The gate table in `tests.rs` covers 22 of the 50 gates directly, the rest only by `written_version` code reading.
