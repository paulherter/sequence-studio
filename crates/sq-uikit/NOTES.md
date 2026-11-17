# sq-uikit notes, group g2 (worker ui2)

Modules: `editor_command`, `sqmenu_model`, `sqicon_path_data`, `sqmascot_model`, `sqmascot_player`, `keyframe_graph_editing`,
`keyframe_viewport`, `controls_grid`, `sqdialog_model`, `focus_routing`, `sqaccessibility_text`, `command_catalog`,
`timecode_start_entry`, `save_changes_prompt`, `key_binding`, `app_version`, `tooltip`, `sqbyte_size`.

## What other groups must provide (the names this group codes against)
- g1 (ui1): `localization::SQL10n::{string(&str), format(&str, &[&str])}`, `sqicon::SQIcon` (Copy, PartialEq),
  `command_map::CommandMap::{entries() -> &[Entry{command}], binding_for(EditorCommand) -> Option<KeyBinding>}`,
  `menu_spec::EditorMenus::all() -> &[MenuSpec]` and `MenuSpec::commands() -> Vec<EditorCommand>`.
- g3 (ui3): `panel_id::PanelID` (`ALL`), `appearance_palette::PaletteColor`, `keyboard_listing::KeyboardListing::text_for(&KeyBinding)`,
  `timecode::Timecode::{new(frame_duration, drop_frame), frames_only (pub field), format(Time), parse(&str)}`,
  `keyframe_graph_geometry::{Point, Size, Rect, GraphMath, GraphMode, GraphHandleSide, GraphHit, GraphFit, GraphDataPoint, KeyframeGraphGeometry}`,
  `localization_counts::SQL10n::plural(n, one, other, language: Option<&str>)`.
- Other crates: `sq_core_edit::timeline_replace_modes::ReplaceMode`, `sq_core_effects::speed_ramp_preset::SpeedRampPreset`,
  `sq_core_graphics::split_layout::SplitLayoutPreset` (three `Cargo.toml` dependency lines were added for them).
- ui1/ui3 ship `command_map`, `menu_spec`, `keyboard_listing` against slightly different signatures (by-reference vs by-value
  `EditorCommand`, `entries` field vs method); the merge must align them. `EditorCommand` is `Copy`, so by-value is the cheap fit.

## Deviations from the Swift code (decisions)
- Geometry: `CGPoint`, `CGSize`, `CGRect` are aliases of `keyframe_graph_geometry::{Point, Size, Rect}` (one definition; `CGRect.contains(rect)` is `Rect::contains_rect`).
- `SQMenuLayout.measureLines/lineHeight` (mutable globals in Swift) are the explicit `SQMenuTextMetrics` argument of
  `heights`, `content_height`, `help_lines`, `caption_height`; `Default` gives the Swift defaults.
- `SQMenuItem` keeps `action` as `Rc<dyn Fn()>` (main thread only); `SQMenuImageBox` holds `Rc<dyn Any>` and compares by pointer.
  Init with defaults is `SQMenuItem::new(title)` plus public fields and `with_help`/`with_leading`.
- `AppVersion` has no bundle: number is the fallback `0.2.0`, build is empty (same as the Swift fallback on Windows and in tests).
  The Swift tests that read `App/Info.plist`, `project.yml` or scan sources for version strings are repo checks, not ported.
- `EffectControlsSplit.load/save` use `UserDefaults`; only the pure rule is ported (`width_from_stored`).
- `KeyClaiming` (AppKit-only protocol) and `SQIcon.svgSource` (bundle read, belongs to `sqicon_resources`) are not ported.
- `TimecodeStartEntry`: the fifth Swift test (`parsePosition` with an origin) is in `timecode.rs`.
- Swift `Dictionary` iteration of `SQMascotLook.x/y` is order independent (distinct channels), so `HashMap` is fine.
- JSON numbers read with `as_f64` (Swift `NSNumber.doubleValue` would also accept booleans; the data has none).
- `CommandCatalog.plain` lists Place on Top twice, as Swift does; `audited` dedupes.
- `GraphGestureState` fields are private with getters; the Swift `private(set)` properties stay readable (`moved`, `axis`, `handle_axis`, `kind`).

## Oracle
`oracle/sq-uikit/run.sh` builds a plain-swiftc dumper over the frozen `SQMascotModel.swift` (minus the bundle-reading `shared`)
and `SQMascotPlayer.swift` and writes `golden/mascot.tsv` (RNG bits, easings, 7 trace samples for each of the 14 animations).
`tests/mascot_oracle.rs` checks the RNG bit-exactly and the rest within 1e-9. The Swift tests carry no numbers for these.

## Not covered
- The graph gesture tests come from `SQInspectorUI/Tests/.../KeyframeGraphTests.swift` (editing, gesture, axis lock, deselect suites).
