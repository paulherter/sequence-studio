# sq-core-model

The project model of Sequence Studio (port of the saved types of Swift `SQCore`): every type stored in a `.sqproj`,
with its serde coding, and the logic Swift keeps next to those types. Depends only on `sq-core-time` and `serde`.

## Public API
- `Project` > `Timeline` > `Track` > `Clip`, plus `MediaRef`, `Bin`, markers, captions, transitions, graphics, masks
  and color types. All plain values (`Clone`, `PartialEq`); ids are `sq_core_time::Id`.
- JSON names, optional keys and defaults follow the Swift `Codable` code (`serde(rename_all = "camelCase")` plus
  explicit renames where Swift differs, `skip_serializing_if` where Swift omits nil).
- Shared accessors: `Clip::duration`/`timeline`, `Track::clips`/`end`, `Timeline::frame_duration`/`track`,
  `ClipSpeed::scale`/`unscale`, `AnimatedProperty::remapped`/`shifted`, `ClipEffect::remapped`/`shifted`.
- `EditError`: why an edit was refused. `prelude`: model types plus the time types they use.

## Status
Skeleton: some saved types are still empty placeholders and some custom coding is missing; each one says which task
fills it. Plan: `docs/rust/sq-core-model-tasks.md`. Ownership: `OWNERSHIP.md`.

## Tests
`cargo xtask check sq-core-model`. Parity: corpus dump of derived values (docs/rust/sq-core-split.md section 5).
