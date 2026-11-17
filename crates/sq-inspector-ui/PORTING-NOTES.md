# sq-inspector-ui porting notes

Areas ported here (Swift `SQInspectorUI`): `ec/` = Effect Controls model, `keyframes/` = keyframe geometry and inputs.
`text/`, `captions/`, `graphics/` = the text inspector, the captions panel and the Graphics editor (models, and the draw files listed below). Other workers add `color/`, `audio_masks/`; `lib.rs` keeps one `pub mod` line per area.

## Mapping decisions
- `EffectControlsModel` is a plain struct (`ec/effect_controls_model/`, one file per Swift section; the Swift
  `extension EffectControlsModel` files are `ec/*.rs`). `@Observable` becomes `version: u64` bumped by setters; `clip_revision`
  counts changes of the clip. Swift `didSet` observers are the setters `set_playhead`, `set_selection`, `set_expanded`,
  `set_collapsed_sections` and the private `store_clip`.
- Hooks: every `onX` is a variant of `EffectControlsEvent` pushed to the model's queue (`take_events`), in Swift's call order.
  The host (App) applies `Edit` events back through `set_clip` (the tests do the same with `Rig::pump`). `onScrub` always
  emits `Scrub`; a host without a scrub handler treats it as `Seek`. Hooks that return a value are fields:
  `can_paste_built_in`, `on_paste_built_in`, `timeline`, `StabilizeHooks`.
- The weak `speedSession` is `has_session` plus `display_picture`, both set by `sync(&EditorSession, Change)`. Speed edits take
  `&mut EditorSession` (`set_speed_percent`, `toggle_speed_animation`, ...). `ResetSpeed` is an event (`reset_speed_with` does it).
  `ease_sources.rs`: the Swift classes that held the session borrow it (`SpeedRampEaseSource<'a>`).
- Key ids: Swift `Keyframe(time:value:)` makes a UUID; here the model owns a `Box<dyn IdSource>` and the `with_*` property
  accessors pass `&mut dyn IdSource` to their closures. `ReservedIds` serves `AnimationSet::edit_position`, which hands its closure
  no source.
- `EffectSection` is declared in `sq-editor-session` without `Ord`: sets of sections are `HashSet`. `EffectProperty` has a
  hand-written `Ord` by raw value so `BTreeSet<EffectProperty>` works.
- Static Swift caches/singletons: the text-animation rows memo (`rowsMemo`) is dropped (`TextGenerator::decode` memoizes the
  payload); `MagicTrackedFrames.shared` is the model field `magic_frames`, loading synchronously.
- `ControlsNumberText.format` always uses the en_US pattern (no locale).

## EC draw (`ec_draw/`)
- Ownership: `EffectControlsDrawView` owns the `EffectControlsModel`; the rows column, lanes, ruler, Graph Editor, inline
  speed graphs and value graphs take `&mut EffectControlsModel` per call (Swift: each held the model). Hooks are events:
  `PanelEvent` (rows column), `ViewEvent` (view), `KeyframeGraphEvent` (value graph), `EasingPopoverEvent`.
- Menus: Swift `SQMenuItem` actions captured the model. A `ModelMenu` holds `SQMenuItem`s plus the action per row
  (`MenuEntry`); the host shows `items()` and reports the chosen index path to `run` (the view's `run_menu`). Dialogs a
  menu action asks for come back as `MenuOutput::Prompt(PromptRequest)`; a value graph's own items as `MenuOutput::Graph`;
  `MenuOutput::ResetToAutomatic` is the property menu's session action.
- Widgets of translated rows are rebuilt on every call (as in Swift); their closures are `Rc<dyn Fn(&mut PanelCx)>` run at
  release. `FieldSpec.value` is read when the widget is built.
- The Speed rows need the session: the panel emits `PanelEvent::Speed(SpeedAction)`; the host runs `SpeedAction::run`
  (`ToggleAnimation(false)` returns `NeedsConfirmation` when keys would go). `automatic_resettable` and `has_key_sampler`
  are session facts the host sets (Swift read `speedSession` and `ScreenColorSampler.begin`).
- Other hooks: `onPickColor` -> `PanelEvent::PickColor` + `color_picked`; `onEaseCurve` -> `PanelEvent::EaseCurve` (the host
  builds the `EaseCurveSource`, the popover takes `&mut dyn EaseCurveSource` per call); `confirmRemoveKeyframes` ->
  `ConfirmRemoveKeyframes` + `confirm_remove_keyframes` (`asks_before_removing = false` removes at once, the Swift
  default); the track hooks -> `TrackMask` / `TrackMagic`; `MaskTrackActivity` -> the `mask_track` field the host fills.
- `EffectControlsModel` implements `EaseCurveSource` (Swift extension in `EasingPopoverDraw.swift`); `apply_spring`
  (Swift `applySpring`, missing in `ec/`) lives next to it.
- Button widths: the panel measures the titles it was asked for while drawing (`widths`), a hit test before the first draw
  uses 6 pt per character (Swift kept a `measure` closure over the atlas).
- `MaskMode.title/allCases` and `MatteChannel.title/allCases` are small helpers in `ec_draw/mod.rs` (the core crate has none).
- New dependency line `sq-audiofx` in this crate's `Cargo.toml` (`ParametricEQResponse` for the EQ curve surface).

## Swift quirks kept
- `GraphEditorGeometry.handleTruePoint` equals `handlePoint` (kept as two functions).

## Not ported (left open)
- `trackMask` (async object tracker in `EffectControlsModel+Masks.swift`): needs the tracker backend trait of the app shell.
- `EffectControlsMultibandModel.swift` and `CompressorBandsGeometry.swift`: they use `CrossoverRules`, declared in
  `TrackAudioInspectorModel.swift` (area audio+masks). Port them with that file.
- `MagicTrackControl.swift`, `MaskTrackActivity.swift` (Magic/mask tracking UI state).
- `Exports.swift`, `AnimationKeystoneSource.save` (async, Library).
- `MultibandEditorDraw` (`ec_draw/` is missing it): it reads `MultibandEditor`, `CompressorBandsGeometry`,
  `MultibandMeterDisplay`/`MultibandMeterTap`, `SpectrumDisplay`/`AudioSpectrumTap` and the model's `multibandSnapshot`,
  `setCrossover`, `setMultibandBandValue`, `toggleMultibandSolo` ..., which belong to the audio+masks area. Port it with
  `EffectControlsMultibandModel.swift` and `CompressorBandsGeometry.swift`; its tests (`MultibandEditorDrawTests`) go with it.
- The hosting of the clip's content section in the rows column (`ClipSectionsDraw`, `TextBlockDraw` slots, the caption
  header of the view, `ClipSectionMode`) belongs to the clip sections task: `EffectControlsDrawPanel::place_section`, the
  section routing of the pointer and the text slots are not ported. The view's header names the clip kind through a small
  local copy of `ClipSectionMode.resolve(..).kindName` (`EffectControlsDrawView::kind_name`).
- `EasingPresets` (load / save of curve presets in the `PresetStore`, async, SQLibrary): the popover reports
  `EasingPopoverEvent::Save`, the library crate stores it. `saved` is filled by the host.
- `ModelMenu` entries that wrote `ColorRangeKey`/`CurveEditing` use a copy of `Color/CurveEditing.swift`
  (`ec_draw/effect_controls_draw_surfaces.rs`); replace it with `color::curve_editing` once the color area is merged.
- Tests of Swift files that need an `EditorSession` scenario (`EffectUndoTests`, Multi*): the multi-select code is covered only
  by the shared paths in the ported suites.

## text / captions / graphics (models and the first draw files)
Decisions
- `TextInspectorModel`, `CaptionsPanelModel`, `GraphicsEditor`: every Swift `onX` hook is an event the host drains (`take_events` for text and captions, `version()` for the graphics editor). `onChange` carries the forced paths (`pendingForcedPaths`) as its third field.
- `CaptionsPanelModel` has no `TranscriptionService` and no `Task`: `transcribe` queues `CaptionsPanelEvent::Transcribe(request)`, the host runs prepare/transcribe on a thread and reports through `report_preparation`, `preparation_done`, `report_progress`, `finish`; `text_changed` queues `ScheduleFlush` and the host calls `flush_edits`. `transcribe_and_create_captions` sets a flag, `finish` creates the captions (the Swift version awaited).
- `GraphicsEditor` does not hold the session: every method takes `session` (`&EditorSession` to read, `&mut` to edit). Its text measure is the portable layout (needs the bundled Inter files; tests that measure text are left out).
- `TextStyleLibrary::{add, duplicate}` and the editor take an id source (`Box<dyn IdSource>` in the models).
- `TextStyleStore::{load, save}` take the `LookStore`; the Swift default-URL switch is the app's.
- `TextTemplateCatalogEntry` is the part of `TextTemplateCatalog` (ClipSectionLogic.swift, not ported) the tiles read. `LayerDrop` (LayerListLogic.swift, timeline UI) is declared in `graphics/editor.rs` until that file is ported.
- Language list in the captions panel sorts by identifier (Swift: localized display name).

Swift quirks kept
- `GraphicsSnap.targets` returns no targets for a rotated graphic; `TextStyleLibrary` equality ignores `base`.

Not ported (left open)
- `FontFamilyList` (AppKit/CoreText only): `TextBoxDefaults::installed_families` returns the bundled families; its test is Mac-only.
- `TextStyleThumbnails` (CGImage), `CaptionLanguageGuess` (NaturalLanguage; `guessed_retry_language` returns `None` like the Swift non-Apple branch).
- `TextInspectorModel.saveCustomAnimation` (async Library save: `AnimationKeystoneSource` has no `save`), the TextMixed session scenario test (needs `update_text_clips`).
- `TextTemplatePlacement::insert_title` for a saved multi-layer title template: `TitleTemplatePreset` keeps the template as JSON until `TitleTemplate` can be decoded; it reports "could not be placed".
- `GraphicsEditor`: the Property/value/key half (`Property`, `value`, `set_value`, keys, colors, shape kind, shadow, layer effects, `EffectDrop`), `+Follow`, `+EffectPresets`, `text_edit_target`/`text_layer_hit` (need `OverlayTarget`, display timeline), `GraphicsPanelLogic.structure` (needs `GraphicsEmptyState`).
- Draw files not started: `TextBlockDraw`, `TextPanelDraw`, `TextTemplatesTabDraw`, `CaptionStyleTabDraw` (with `CaptionOffsetDisplay`), `CaptionsTabDraw`, `GraphicItemRowsDraw`, `GraphicsFormDraw`, `GraphicsLayerListDraw`, `GraphicsPanelDraw`. Done: `CaptionListDraw` (`captions/list_draw.rs`), `TextTemplateTileAtlas` (`text/template_tile_atlas.rs`).
- Tests not ported: Mac-only `FontFamilyListTests`; the draw tests of the files above.

## Escalations
None.
