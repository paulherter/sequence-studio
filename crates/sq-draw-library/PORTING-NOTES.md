# sq-draw-library: porting notes

## Mapping decisions
- `LibraryPanelModel` is synchronous: the Swift `async` calls to the `LibraryIndex` actor, the preset store and the preview
  coordinator are plain calls on the UI thread (the Rust types are polled). The update stream is `pump()`, once per frame.
  `ids` and `clock` are injected (Swift calls `UUID()` / `Date()`), `support_directory` and `lut_directory` replace the
  `LibraryStores.supportDirectory` / `LUTLibrary.defaultDirectory()` statics.
- `LookStore.shared` is an `Arc<LookStore>` the app sets (`set_look_store`); its `didChange` notification is its `version()`,
  compared in `pump`.
- `UserDefaults` keys keep their names. Numbers are stored as text (`UiDefaults` has no double): the app maps the key.
  `UserEffectFolder` / `EffectFolderStore` are stored as JSON under the same key.
- `EffectsDrawPanel` / `LibraryDrawPanel` mouse methods take the clock (`now`) the Swift closure `now()` supplied; `key`
  takes the `UiCx` (text field editing, clipboard); `draw` takes a `UiCx` for the caret request. The hosts keep their own.
- Swift `CGRect.intersects/offsetBy` live in `geom.rs` (the Rust `CGRect` has neither).
- `SQMenuItem` actions are `Rc<dyn Fn()>`: tests call the action, then `pump()`.
- Swift `EffectsCatalog.catalog` (a static let) is `EffectsCatalog::catalog()`; `QuickApplyCatalog.items(presets:)` needs the
  menu commands in Rust (`QuickApplyCatalogExt::items_for(presets, commands)`).
- `TextTemplateCatalog` and `TextTemplateTile` live in SQInspectorUI's Text panel (not ported): `library/text_templates.rs`
  is a seam (`TextTemplates`), `NoTextTemplates` until the app hands in the real one. `sq-inspector-ui` is therefore not a
  dependency yet.
- `Workspace` pack entries: the Rust validator type returns `PresetFileError`, so a damaged workspace reads as a damaged
  entry (Swift threw `SQPackError.malformed("workspace")`).

## Shortcuts (searchable `shortcut:` comments)
- Previews, pack files and the hover loop of the Effects grid are made on the UI thread (Swift: detached tasks).
- Pack fonts are not registered with a font system (`register_fonts`).
- `medium_date` formats in UTC.
- Swift's `PollingFolderWatcher` is not ported; the app supplies `FolderWatching` (`NotifyFolderWatcher`, OS events like FSEvents).

## Not ported (Mac only or nothing to port)
- `LibraryPanelModel.itemDidDisappear`, `pendingPreviewCount`, `liveLookObservers` (Swift task and observer bookkeeping).
- `MediaPreviewProvider`, `FSEventsFolderWatcher` choice in `platformWatcher/platformProvider` (`#if os(macOS)`): the app wires them.
- Test `anAudioItemGetsAPreviewBarWithPlayPauseAndStopsOnLeaving` (`#if canImport(AVFoundation)`): the portable preview
  player is silent. `EffectsTileAtlasTests.hoveringATilePlaysItsLoopInTheLiveCell` is ported without the thread wait.
- `a11y` nodes: the Swift panels have none; the hosts push nothing.

## Swift quirks kept
- `EffectsDrawPanel.mouseDown` sets `lastClick` after the double-click test even when `press` was cleared.
- `LibraryDrawPanel.refresh` runs inside observation tracking in Swift; here `version()` compares per call.

## Escalations
None.
