# sq-draw-library

The Library and Effects panels on the shared draw UI (Swift `SQDrawLibrary`, tasks DL1-DL2 of
`docs/rust/session-ui-design.md`). Check: `cargo xtask check sq-draw-library`.

## What is here
- `effects/`: `EffectsCatalog` (what the panel lists), `EffectFolderStore` / `EffectFolderOutline` (user folders, rows,
  search, key navigation), `EffectPreviewPlan` + `EffectsGridLayout` (grid), `EffectsTileAtlas` (tile stills and the hover
  loop in one image slot), `EffectsDrawPanel` (the panel) and `EffectsPanelHost` (its `sq_app_shell::AppHost`).
- `library/`: `LibraryPanelModel` (+ packs, SFX bin), `LibraryLabels` / `LibrarySidebarRow` / `LibraryPresetCell` /
  `LibraryTileGeometry`, `LibraryMenus`, `WorkspacePackKind`, `LibraryDrawServices`, `LibraryDrawPanel` (+ preview bar,
  rubber band) and `LibraryPanelHost` (its `AppHost`).

## How the Swift hooks map
- A hook that reported something is an event the owner drains: `EffectsEvent` (`Apply`, `Menu`, `AskName`, `Drag`),
  `LibraryPanelEvent` (`Request`, `Menu`, `Drag`) and `LibraryModelEvent` (`FoldersChanged`, `InsertTitleBlock`,
  `ImportWorkspaces`, `ApplyPreset`). The app turns them into dialogs, file choosers and timeline calls; the answer to
  `AskName` goes to `EffectsDrawPanel::answer_name`.
- Menu rows hold no reference to their panel: they push into a `MenuQueue`, `pump` applies the picks after the menu closed.
- `@Observable` is `LibraryPanelModel::version`; the host calls `sync` once per frame (`model.pump`, `panel.refresh`).
- The host's `picture` / `previewFrame` closures are the `picture` parameter of `draw` and the `preview_frame` field.
- Settings (`UserDefaults`) go through an injected `UiDefaults`; the preset apply mode and the watched folders through
  `sq_library::library_folder_store::SettingsStore`.

Notes and limits: `PORTING-NOTES.md`.
