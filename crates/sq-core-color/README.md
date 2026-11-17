# sq-core-color

Color logic of the Sequence Studio project model (port of the color files of Swift `SQCore`). The saved color types
(`ClipColor`, `ColorEffect`, `ColorGradeData`, `ColorGraph`, `ZoneBoard`, ...) live in `sq-core-model`; this crate adds
the maths and the edits on them. Swift `extension`s on model types are extension traits (`ClipColorExt`,
`ClipEffectColorExt`, `ClipGradeExt`, `ColorGraphExt`, ...) re-exported flat from the crate root; import the trait you call.

## Public API
- Tone: `basic_tone_curves` (Lumetri-matched Contrast/Highlights/Shadows/Whites/Blacks/Exposure), `auto_tone_solver`
  (Auto Tone, neutral sample), `ZoneSettingExt` / `ZoneBoardExt` (Zone Board maths), `key_color_pick`.
- Color effect: `ColorGradeFields` (the tables of numbers, wheels and switches; `spec()` is the catalog entry),
  `ClipEffectColorExt` (`color_effect`, `set_color_effect`, `apply_color_edit`, range strength), `ColorEffectScaleExt`.
- Clip view: `ClipGradeExt` (`color`, `set_color`, `set_color_edited_from`, `render_color`, keyframing, range grades,
  Pro grade accessors, `adopt_legacy_grade`, `apply_color_match`).
- Pro grade: `ColorGraphExt` (Steps, columns, stacks, list rows, "Send to Pro"), `ColorGraphWiringExt` (wires, refusals,
  compile back to Step kinds), `StepPrimariesExt`, `ColorStepExt`.
- Match: `ColorMatchStatsExt`, `color_wheels_model`, `color_match_solver` (`solve`, `solve_clip`), `Oklab`.
- Others: `FilmLook` / `GateWeave`, `ColorBypass`, Color Matte, `ColorRangeKeyExt`, camera input color spaces
  (`ColorSpaceIdExt`, `InputColorProfile`, `InputPickerState`).

Ids for new effects, keyframes and Steps come from an `IdSource` argument (Swift draws random UUIDs). Status, open items
and decisions: `NOTES.md`.

## Tests
`cargo xtask check sq-core-color`. The Swift tests of these files were translated with the same inputs and tolerances.
