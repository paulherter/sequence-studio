# audio_masks porting notes

Swift: `TrackAudioInspectorModel`, `CompressorBandsGeometry`, `EffectControlsMultibandModel`, `MaskTrackActivity`,
`MagicTrackControl`, `SubjectMaskQualityMenu`, `TransitionControlsModel`, and `Draw/TrackAudioDraw`,
`Draw/MultibandEditorDraw`, `Draw/TransitionControlsDraw`. `TransitionEaseSource` was already in `ec/ease_sources.rs`.

## Mapping decisions
- Hooks: `TrackAudioInspectorModel` queues `TrackAudioEvent`s (`take_events`), in Swift's call order. The draw blocks
  keep `menus: Vec<MenuRequest>` (Swift `onMenu`) and `requests` (`onClose`, `onPickColor`, `onEaseCurve`, `onSavePreset`).
- Menu rows hold no model or session: they push a command into a `MenuSink` (`color::color_graph_menus`) and the host
  calls `run_menu_commands` when the menu closes (`TrackAudioDraw`, `TransitionControlsDraw`, `MultibandEditorDraw`).
  The color picker answers through `TransitionControlsDraw::color_picked`.
- The Swift draw classes held the model or session. `TrackAudioDraw` owns its model. `MultibandEditorDraw` and
  `TransitionControlsDraw` take `&mut EffectControlsModel` / `&mut EditorSession` (and `&mut UiCx`) per call. The host applies the
  model's `Edit` events (`set_clip`) after a call and then calls `MultibandEditorDraw::sync`.
- `EditorSession` has no public getter for the selected transition (`selected_transition` is `pub(crate)`):
  `TransitionControlsActions.selected_transition` is a field the host keeps in step with `select_transition`.
- `TransitionControlsActions.reset` / `TransitionControlsDraw.defaults` take the preferences' `TransitionDefaults` (Swift read them
  from the app settings inside `resetTransition`).
- `MaskTrackActivity`: `Task` is a cancel closure (`attach(cancel, token)`), `ObjectIdentifier` owner is `Option<usize>`,
  `WriteSwitch` (`Mutex<Bool>`) is an `AtomicBool`, the `shared` singleton is dropped (the app owns the instance).
  `NSLog("[Magic] ...")` lines are dropped.
- `SubjectMaskQualityMenu.item` shares the defaults with the menu actions as `Rc<RefCell<dyn StringDefaults>>` (the actions
  outlive the call and write to them).
- `MultibandEditorDraw.spectrum_at_input` replaces the `UserDefaults` read (`sq.multiband.spectrumAtInput`); a change is the
  request `SpectrumAtInput(bool)`.
- `MultibandEditor.presets` / `all_keys` are `OnceLock` statics. `MultibandMeterDisplay` keeps `Equatable` as `PartialEq`.
- Time stays rational; `CompressorBandsGeometry` is in points (`f64`).

## Swift quirks kept
- `saveAsUserPreset` / `currentValues` build the preset without `deEss`, so it is dropped (false).
- `MaskTrackActivity.stopAutomatic` and `stopIfKeyChanged` leave the slot as `stop` does; `finish` clears it without saving.

## Not ported
- `Draw/*` hover tips through `HostHover`: `TransitionControlsDraw::handle` offers the tip to `cx.hover`.
- `EffectControlsModel+MaskTool/Masks/MaskPathKeys/PictureMask/TrackMask/ColorRangeMask` belong to the EC area (`ec/`).
- `MagicTrackedFrames` is in `ec/magic_tracked_frames.rs`.
- The Swift `TransitionControlsDraw` tests used a `StubProgramEngine` session; the Rust ones use `SessionDeps::headless`.
