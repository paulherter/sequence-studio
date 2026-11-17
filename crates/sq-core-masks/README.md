# sq-core-masks

Logic of the masks group of Swift `SQCore` (masks, Magic masks, Subject and Picture masks, Anonymize, the Stabilizer,
rolling shutter, perspective tilt) over the project model of `sq-core-model`. The saved types (`ClipMask`, `MaskPath`,
`MagicSelection`, `MaskSource`, ...) live in the model; a Swift `extension` on them is an extension trait here
(`ClipMasksExt`, `MaskPathExt`, `MagicSelectionExt`, ...). Every module names its Swift file in its header comment.

- Masks: `masks`, `mask_inputs`, `mask_path_editing`, `mask_motion`, `picture_mask`, `subject_mask_editing`.
- Magic and Subject: `magic_mask`, `magic_follow`, `magic_correction`, `magic_matte_needs`, `magic_track_health`,
  `subject_mask`, `subject_track_rules`, `subject_crop_pass`, `matte_refine` (only the two filters the smoother needs).
- Anonymize: `anonymize`, `anonymize_order`.
- Stabilizer: `stabilizer` (+ `_solve`, `_quadratic`, `_l1`, `_perspective`), `stabilization_cuts`, `rolling_shutter`,
  `stabilize_effect`, `stage_transform`.
- `perspective_tilt`: the real `PerspectiveTilt` (the model keeps a private copy of the clamp for `Clip::transform`).

Logic that creates ids takes `&mut dyn IdSource` (Swift `UUID()`); nothing reads a clock. See `NOTES.md` for what waits on
other crates.

Tests: `cargo xtask check sq-core-masks`.
