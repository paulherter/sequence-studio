# sq-inspector-ui / color: porting notes (IN7 color model, IN8 color draw)

Module dir `src/color/` only; `lib.rs` holds one line (`pub mod color;`) and `Cargo.toml` is minimal so it merges with the
`ec/` and `keyframes/` worker that creates the same crate (expect a trivial conflict in `lib.rs` and in the dependency list).

## Mapping decisions
- `ColorInspectorModel` (an `@Observable` class with hooks): a struct with `version` bumped by setters and `events: Vec<ColorInspectorEvent>`
  (`onChange`, `onGestureBegan/Ended`, `onGraphChange`, `onSharpenSet`, `onKeyframe`, ... as variants). The host drains them; the
  controller does it with `pump`. `onResetAll` (a value-returning hook) is the field `reset_all_hooked`.
- `ColorGradeController` takes `&mut EditorSession` (and `&mut ColorClipboard`, the app's one instance) per call. Its hooks and platform
  seams are `ColorGradeEvent`s (`Beep`, `PickScreenColor`, `SampleProgramFrame`, `SetColorBypass`, ...); `finish_white_balance` and
  `finish_auto_tone` take the host's answer. `session.engine.setColorBypass` has no outside access in `EditorSession`: it is the event
  `SetColorBypass` (the host calls `ProgramEngine::set_color_bypass`).
- Menus: `SQMenuItem.action` is `Rc<dyn Fn()>`. Rows push a command into a `MenuSink<C>` (`Rc<RefCell<Vec<C>>>`, single thread, shared by the
  rows of one open menu and the host that drains it when the menu closes) and the host runs the command with the model/session in hand
  (`ColorGraphMenus::apply`, `ColorGradeController::run_menu_command`, `ColorGradeDraw::run_menu_command`). This is the one `Rc<RefCell>` of the
  crate; ownership table row: field `MenuSink.0`, owner: the menu builder, lifetime: while a menu is open, shared-by: its rows and the host.
- The draw classes (`ColorGradeDraw`, `ColorStepsDraw`, `ColorSourcesDraw`, `ColorViewerHeaderDraw`, `ColorStripToolsDraw`, `LookGalleryDraw`) hold no
  controller. Reads take `&ColorGradeController`, writes take `ColorGradeHost { controller, session, clipboard }`; `onMenu` is the `menus` queue,
  `chooseLUTFiles` and friends are `file_requests` / `requests`. Hooks of the host (`clock`) are `UiCx.now`.
- `LUTLibraryStore` / `RecentLUTs` (UserDefaults): the model keeps `lut_entries` and `recents` snapshots; toggling a favorite, importing files
  and picking a LUT are events (`ToggleFavouriteLut`, `ImportLuts`, `RecentLut`) the host handles with its `LUTLibrary` and `UiDefaults`.
- New ids (`ColorGraph()`, `addStep`): the model owns a `Box<dyn IdSource>` (`ColorInspectorModel::new(ids)`); the controller gets a factory.
- Text widths for the layout: Swift kept the last canvas. `ColorGradeDraw::text_width` returns an estimate on a miss and remembers the ask; the next
  draw measures it (`learn_widths`). The Mac tab widths table is a function (`mac_tab_width`).
- `ScrubFieldControl` is not `Clone` (Swift copied the struct): `fields` is a `RefCell<HashMap>`, `field()` takes the field out and `put_field` returns it.
- `CGRect.union/intersects/offsetBy` are `geom.rs`. `intersects` is strict (touching edges do not intersect), as `CGRectIntersectsRect` behaves.

## Not ported / open
- `ColorDecisionImport` (ASC CDL / CMX EDL parser) is not in `sq-core-color` yet (its NOTES say not started). `importColorDecision(data, ext, into)`
  is `apply_color_decision(id, primaries)` and `ColorGraphMenus.importDecision` / `makeDecisionImport` are the `ImportDecision` host request only.
- `ColorBlockText.localized` (root-level file of SQInspectorUI, EC area) is not applied: `auto_tone_block` returns the English reason from `sq-core-color`.
- `onGestureCancelled` of the model: the controller's `cancel_gesture(session)` is called by the draw classes where Swift called the hook.
- Swift integration tests that need a session rig and DrawList comparisons (`ColorGradeDrawTests` rig tests, `ColorRound3/4/5/6/8DrawTests`) are not
  translated: they belong to the interaction scenarios and DrawList goldens (plan 6b). The pure-logic tests are ported with the same names
  (`ColorWheelMathTests`, `ColorPrimaryWheelsTests`, `ColorWheelSmoothTests`, `StepsCanvasTests`, `HueCurveExplanationTests`, `ZoneBoardPanelTests`,
  `rangeBarMathMapsEdgesAndMoves`, `fillSourceCutsTheLongerSide`); the rest got new unit tests next to the code.
- `LookGalleryDraw` draws with the UI face when the look's font is not bundled (the Swift `shortcut`, kept).
- `ColorGradeDraw::wrap_lines` estimates by character count until the canvas can wrap (`shortcut` in the code).

## Swift quirks kept
- `ColorGradeDraw` Group rows draw their label at `r.y + 0.5` when there is no rule (kept), and `draw_control` ignores `Section` taps outside the header.
- `selectedSteps.first` (a `Set` in Swift) is the smallest id here (`BTreeSet`).
