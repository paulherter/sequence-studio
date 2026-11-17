# sq-draw-shell: porting notes

> Status 2026-11-09: the Export sheet is ported (860x640 two-column body, all Swift rows, Other Formats menu, preview with play and scrub: commits 0f7898dfb, dfbe8b054). The "Escalations" entry below about the unported sheet and "File > Export does nothing yet" is [stale]; what is open about export is Export Frame alpha entries. Other "not available" lines are as old as their section; check the code first.

## Scope of this crate state (SH1)
Ported: ShellHost.swift, ShellDialog.swift, MenuBar, MenuController, MenuListView (with `MenuFont`), ShellMenuBar.swift
(`ShellAction`, `ShellMenuState`, `ShellMenu`, the builder), ShellKeys.swift (with `AltTap`, `ShellWindowTitle`),
ShellKeyRoute.swift, ShellModalKeys.swift, ShellMenuActions.swift, `ShellFilePicker` (from ShellHost.swift),
`ShellPanelFacts` and the shell's own rows of `ShellCommands` (ShellCommands.swift), `current_facts` (ShellFacts.swift, reduced).
Not ported: `ShellMenuBar.swift`'s AppKit import and `TextMeasure` (already in `sq-draw`), the `Canvas.emptyStateArt` init hook.
`SharedCommandCoverage.swift` is ported in SH-E.

## Scope of the SH-B state (start, about, mascot, help)
Ported: ShellStart (+Draw) with ShellStartWindows (`shell_start*.rs`), ShellAbout, ShellHelp (`performHelp`, Reveal Logs, Check for
Updates), ShellMascot, ShellMascotStage, ShellAppIcon + ShellAppIconPixels (the 128 px RGBA is `app_icon_pixels.rgba`, the same
bytes decoded from the Swift base64), ShellRecovery (`restoreAutosave`, `recoveryDialog`).
Not ported (still stubs in `pending_steps.rs` or missing, reason in brackets):
- (ported in SH-C: ShellShortcuts, ShellNewProject, ShellPreferences, `saveCheckpoint`, ShellExport and its queue menu and popover.)
- `offerRecovery`, `writeCrashReports`, `presentCrashReport` [need the platform's process table, log files and home folder; the
  ported `RecoveryScanner`/`CrashReport` are ready, the platform inputs have no home yet].
- (`quickCreate` and template rename/delete are ported in SH-C.)
- Card pictures (`startPoster`, `ProjectPoster`) and the Appearance popover [shortcuts, see `shell_start.rs`].

## Scope of the SH-C state (flow dialogs on ShellForm)
Ported: ShellShortcuts (+Draw), ShellNewProject (with `createProject` and the start screen's `quickCreate`), ShellTemplates
(rename, delete), ShellPreferences, `saveCheckpoint` of ShellRecovery, ShellExport (the statics, `prepare_export_model`,
`export_after_sheet`, preflight, follow, finished dialog), ShellExportQueueMenu, ShellExportQueuePopover,
ShellImportReportContent, ShellTextInput. The stubs of `pending_steps.rs` for these are gone, except `show_export`.
Not ported: ShellExportSheet, ShellExportRows, ShellExportPreview (see Escalations). Tests: the Swift suites of Shortcuts,
Preference stores, the queue menu and popover, text input and the new-project / checkpoint / template parts of the recovery
and dialog suites; the Export suites that drive the sheet are not ported with it.

### Mapping decisions (SH-C)
- Dialogs that react while open (New Project's Choose…, Preferences) are flows over `shell_live`: `ShellHost::present_live`
  shows the dialog, `LiveAsk::next` yields the next form change or the answer. The host wakes the waiting flow from
  `route_form_changes` (`form_waker`). `DialogForm` gained `set_value` / `set_row_detail` so a flow can fill a row while
  the dialog is open; `ShellForm::set_sidebar_focused` keeps the keyboard on the Preferences page list.
- `ShellDialog::footer_summary` cannot read the form it does not own: New Project keeps an `Rc<RefCell<FooterSummary>>` that
  the form's change reaction updates (UI thread only).
- `UserDefaults` is `ShellHost::defaults` (`UiDefaults`, in memory by default: `ShellDefaults`). The library's `SettingsStore`
  and the audio core's `DefaultsStore` are lent the same store through `shell_preferences::Bridge` (numbers kept as text).
- Keyboard Shortcuts is plain state in `ShellHost::shortcuts`; Swift `host.spawn { await ... }` is `ShellFlow::Shortcuts`.
  `onKeymapChanged` is `ShellHost::take_keymap_change`. The editor's frame follows the window in `relayout`.
- Preferences hooks (`audioOutputs`, `effectDefaultsLibrary`, `hasCardImport`, `libraryFolders`, `clearCache`, `editAPI`)
  are the data of `ShellHost::preferences` (`PreferencesHost`); what Swift did with a hook is a `ShellEvent`
  (`SettingsChanged`, `AddLibraryFolder`, `RemoveLibraryFolder`, `ClearCache`, `SetEditApi`, `MoveProxies`,
  `RestoreEffectDefault`). `ShellLibraryFolder` and `EditApiState` live in `shell_preferences.rs`; if the group that ports
  ShellEditAPI.swift defines its own state type, unify the two.
- Export: `ShellHost::export` (`ExportHost`) holds the hooks (`exportSources`, `exportQueue`, `exportCodecs`, ...). The
  queue's `run_all` blocks: the app runs it on a worker on `ShellEvent::RunExportQueue`; the flow only follows statuses.
  The queue popover refreshes from `draw_overlays` every 250 ms and returns its callbacks as `QueuePopoverEvent`s.
- Menu rows that start a flow (the export ring menu) push to `ShellHost::menu_flows`, which `take_flows` hands out.
- Root `Cargo.lock` changed: sq-draw-shell now depends on sq-core-audio, sq-library, sq-export and sq-premiere-import
  (all workspace crates).

### Swift quirks kept (SH-C)
- The import report's row order is `($0.status, $1.count, $0.feature) > ($1.status, $0.count, $1.feature)`: status worst
  first, count ascending, feature descending.
- Deleting a template does not ask; renaming ignores a blank or unchanged name.

### Shortcuts taken (SH-C)
- Final Cut command sets (property lists) cannot be imported: no plist reader exists, `ForeignKeymapFile::read` gets `None`.
- The key layout of an import is the US layout (`KeyCharacterResolver::us()`), not the active keyboard layout.
- UI language and transcription language names come from small tables, not a locale database.
- The cache size line of Preferences is app-managed (`PreferencesHost::cache_used`, `ShellHost::cache_folder_size`); it
  refreshes at the next page change.
- `MediaManagement.sanitized` / `freeFolderName` / `layout` are local copies in `shell_new_project.rs`.

## Escalations [stale 2026-11-09: the Export sheet exists; read the Update paragraph below]
- ShellExportSheet + ShellExportRows + ShellExportPreview (about 1,430 Swift lines) are not ported. Why: the sheet, its
  footer closures (`footerNote`, `buttonEnabled`, `canClose`) and `showExport` all share one `ExportDialogModel` object, and
  every row item of ShellExportRows is a closure that edits it. A Rust port needs (a) the model behind a shared handle
  (`Rc<RefCell<ExportDialogModel>>`) because the dialog owns its content as `Box<dyn ShellDialogContent>` that the flow cannot
  get back, (b) the closures replaced by an `ExportAction` enum applied to the model, and (c) the preview's frame loading
  and playback on a worker with an RGBA conversion hook (threads and video interop). That is a design decision for the
  ownership table, not a mechanical port. Proposed shape: `ShellExportSheet` owns the model; the flow gets it back through
  a `ShellDialogContent::into_any` default method; actions are an enum; the preview loads synchronously behind a shortcut
  until the executor has a worker pool. `ShellHost::prepare_export_model` and `ShellHost::export_after_sheet` are ready for it;
  `pending_steps::show_export` flashes "not available" until then. File > Export therefore does nothing yet.

- Update: the sheet is a `ShellForm` (`shell_export_sheet.rs`, `shell_export_rows.rs`), not the closure-based Swift sheet. It has
  the preview of the frame at the playhead (`Row::Picture`, slot `EXPORT_PREVIEW_SLOT`, `ExportHost::frame_pixels`), custom In/Out
  timecodes, size, frame rate, bitrate and rate mode, audio codec and bitrate, captions and cover frame, stems with presets
  and Save Choice, cut-downs (non-blocking: the tick follows the jobs), the format list (add, duplicate, remove, tick, edit,
  Export all formats), codec, profile, keyframe and HDR rows. A change that alters other rows builds the sheet again over
  the model (`ExportRows::rebuilds`, `rebuild_sheet`). Gaps: constant quality, hardware switch, encoder speed, max bitrate,
  channels, true peak, damaged-frames rows; a preview that follows later edits or scrubs; the "Other Formats" footer menu.

## Mapping decisions (SH-B)
- The start screen does not know the host: it reads a `StartEnv` per call and returns `StartAction`s the host applies
  (`ShellHost::apply_start_actions`); stored settings leave as `ShellEvent::Setting` (UserDefaults replacement), links, reveal and
  clipboard as `ShellEvent::{OpenUrl, RevealFile, CopyText}`. Dialog contents that need those (About) push to the host's shared
  event queue (`ShellHost::event_sink`).
- `ShellStartScreen::reload` reads the recents' files on the calling thread (Swift ran it detached); tests clear `missing`.
- Swift statics (`ShellMascot.markOverride`, `ShellAppIcon.hasImage`) are arguments (`draw_with_marks`, `has_image`).
- `ShellDialogContent` got a defaulted `height_measured(width, &TextMeasure)`: a Rust measure borrows the atlas and cannot be stored
  like Swift's copy. About implements it.
- `ShellFilePicker::fetch(url)` (defaulted) is the HTTPS GET of Check for Updates; `ShellHost::update_feed` is `UpdateCheck::feed_url`.
- The shell tests of this group are in `tests_b.rs` (on the rig of `tests.rs`, whose helpers became `pub(crate)`).
- `GroupingCalendar` for the day labels is `UtcCalendar` (shortcut: Swift used `Calendar.current`).

## Mapping decisions
- No stored session (`session-ui-design.md` section 2): `ShellHost` has no `session` field; calls take `ShellCx`.
- Hooks: `onStatus`, `onProjectChanged`, `onQuit`, `saveRecents` -> `ShellEvent`; value-returning hooks (`onCommand`, `commandHandlers`,
  `onAction`, `fillMenuState`, `menuChecks`, `factProviders`, `isAnonymizing`, `runAutoCaptions`, `runWhooshAtCuts`, `onNewShape`, media
  defaults) -> `ShellHooks` methods. `spawn` -> `ShellFlow` + `ShellHost::run_flow`. `Task`-based shuttle deadline -> `shuttle_wake_at`
  / `tick_shuttle` (the app polls it each frame). `completion`/`withCheckedContinuation` of `ask` -> `ModalAsk`; a finished dialog is
  swept at the next `handle`/`draw_overlays` (`dialog()` already hides it).
- `TextMeasure` borrows the glyph atlas, so `MenuController`/`MenuBar`/`ShellDialog` do not store it; `layout`, `present`, `handle` take
  `&TextMeasure`. The Swift `didSet` relayouts (`menus`, `height`, `origin`, `maxWidth`, `showsTitles`) are setters taking the measure.
- `MenuBar.refresh` closure captured the host: the host lends a `MenuRefresh` per call and takes the bar out of itself meanwhile.
- `MenuController.onDismiss` / `onSideKey` -> `take_dismissed()` / `take_side_key()` polled by the bar after each call; `side_keys` says
  whether a handler is installed (Left at the root closes the menu without one).
- `ShellDialog.form` is a `Box<dyn DialogForm>` and `content` a `Box<dyn ShellDialogContent>`: `ShellForm` (SH form task) implements
  the trait and may widen it; `openPopup` callbacks became `take_popup()`. `buttonFrames` (a Swift dictionary) is a `BTreeMap`.
- `ShellMenuState.now` is set by the host from its wall clock (Swift read `Date()`); `AutosaveVersionRow.path` stays a `String`.
- Swift `Response(Int)` is `sq_uikit::sqdialog_model::SQDialogResponse`.
- Session `open/save/saveAs/saveCopy` are synchronous in Rust, so the file flows only await dialogs and choosers.

## SH2-8 part A: Form, Dock, Floating, Project list, Focused edit, Full screen, Format, Platform text
Ported: ShellForm, ShellDock (+Draw, +Shell), ShellFloating, ProjectListView (+Chrome, +Columns, +Grid, +Health, +HoverScrub,
+Move, +Reveal), ShellFocusedEdit, ShellFullScreen, ShellFormat (change format, templates, pixel aspect), ShellPlatformText.
The stubs of `pending_steps.rs` for these files are gone (`not_available` moved to `ShellPlatformText::not_available`).
Not ported: Help > Welcome Tour (`showWelcome`, `presentWelcomeIfNeeded`): the text is `OnboardingContent` (ES10, not in
`sq-editor-session` yet), the arm falls through to "not available". Swift tests not ported yet: ShellFormExtras / Sidebar /
NumberField suites (the new `shell_form` tests cover the same rows by direct drive), ShellFloatingMonitorZoom, ShellDockPage,
ProjectPanelChrome / HoverScrub / Reveal suites (need a media-bearing project fixture), ShellFormat flow tests (need the root harness).

### Mapping decisions (part A)
- `ShellFloating` has no back reference: it is plain state and geometry inside `ShellDock`; the steps that change both
  (`float`, `dock_back`, `close_floating`, `set_floating_frame`, `toggle_floating_zoom`, `tear_off`, `floating_press`) are
  `ShellDock` methods in `shell_floating.rs`. `screens`, `mainScreenFrame` and the clock are plain fields.
- Dock hooks are `DockEvent`s: `Focus` and `PresentMenu` are applied by `ShellHost::sync_dock` (key-map scope, menu), the rest
  (`SaveWorkspaces`, `Changed`, `FloatPanel`, `Raise`) is for the app (`ShellHost::take_dock_events`). A tab
  menu row queues a `TabAction`, performed by `ShellDock::run_tab_actions`. Mutators relayout from the tab title widths of the
  last `ShellDock::set_measure` (the measure borrows the atlas); `ShellHost::relayout` calls it.
- `DialogForm` grew `UiCx` / `TextMeasure` parameters (key, drag, release, draw, press) because the shared text controls need
  the clipboard and the IME caret request, plus `take_changes` and the readers `text` / `index` / `bool` / `number` / `color`.
  `onChange` is the queue `take_changes()`; `ShellForm::on_change` is the synchronous reaction that edits other rows (Change
  Format's preset popup). A popup choice comes back through a queue applied at the form's next call.
- After the answer the dialog is swept at once, so a flow reads the typed values from `ShellHost::take_answered_form()`.
  Changes made while a dialog is open that nobody handles are in `take_form_changes()`; the History dialog's rows are handled
  by the host (`history_base`, jumps right away).
- `ProjectListView` holds no host, model or session: calls take a `ProjectListCx`; hooks are `ProjectListEvent`s; menu rows
  queue a `ListAction` (`run_queued`); `UserDefaults` is `ProjectListSettings` + `ProjectListEvent::SettingsChanged`; the dock's
  tab strip is `set_strip(StripTools)`. `ShellHost::project_selection` mirrors `projectSelection`, `ShellHooks::has_project_list` /
  `delete_project_selection` replace `projectList`, `ShellHooks::edit_action` replaces `editActions`.
- `ShellHost.template_folder` (Swift `templateFolder`) and `ShellHost.ids` (template ids; the app replaces the sequential
  default with its random source) stand in for the app's template store; the session's `ids` is crate-private.
- Pixel aspect changes always go through `session.perform`; the Swift host preferred `projectModel.setPixelAspect` so the model
  stayed in step, here the app syncs the model from the session each frame (session-ui-design section 2).

## SH-E: commands, timeline ops, dialogs of the edit group
Ported: ShellCommands (`enabled` for every row, `run` with the split-edit and trim rows), ShellTimelineOps, ShellTrim,
ShellPasteMedia, ShellPasteSettings, ShellPunchIn, ShellSequenceMatch, ShellMarkerDialog, ShellSequenceDialogs (New Sequence,
Sequence Settings, Project Notes, Go to Timecode, tones), ShellReconnect, ShellRelink (Reconnect Media), ShellViewCommands,
ShellQuickApply + ShellQuickApplyCommands, SharedCommandCoverage (the table and the "every audited command has a route" test).
The stubs for `paste_media`, `run_trim_command` and `view_checks` in `pending_steps.rs` are gone.
Not ported:
- ShellRelink's Import Checklist half (`ShellImportChecklist`, `showImportChecklist`, `showImportReport`, `saveImportReport`,
  `showAffectedClip`) needs `ShellImportReportContent` (ShellImport.swift) and the `sq-premiere-import` dependency.
- ShellViewCommands `quickExport` and `importProjectAsBin` need the export models (`ExportDialogModel`, ShellExport) and the project model.
  The Project list rows of `performViewCommand` (list/icon view, Hover Scrub, thumbnail size, New Bin's list part) return false:
  the host's list answers them through `ShellHooks::on_command`, which runs first.
- `SharedCommandCoverageTests.ownersExistAndNameTheirCommand` greps the Swift source tree; `notYetSharedListMatchesTheHostSet`
  has nothing to compare (`ShellHost.notYetShared` is empty).
- Toggle Audio Scrubbing and Toggle Captions in Monitor: `EditorSession` has no mutable engine accessor, so both take the
  Swift "engine ignored the switch" path and flash "not available"; `restoreCaptionsInMonitor` is dropped with them.
  Needs `EditorSession::engine_mut()`.
- Delete's menu rule lacks `session.selectedTransition != nil` (no public reader; the field is crate-private).
- Match Loudness inside a Quick Apply macro is started but not awaited (see the shortcut in `shell_quick_apply_commands.rs`).

### Mapping decisions (SH-E)
- Stored defaults: `ShellHost::settings` is a `SharedDefaults` (`Rc<RefCell<dyn UiDefaults>>`, the typed UserDefaults mirror;
  default `MemoryDefaults`). Reads: `setting_string/flag/numbers`; writes: `store_setting`, which also emits
  `ShellEvent::Setting` for the app's own store. A flag is the integer 0/1, a list of numbers comma text, the relink folders
  one path per line. `BytesView` (library/session `SettingsStore`: Jump Cut overlap, Quick Apply recents) and `NumbersView`
  (Live Ducking `DefaultsStore`) are views of it. `ShellHost::audio_role_defaults` stands for `AudioRoleDefaults.current`.
- `ShellCommands::run` takes the settings view and the role defaults (Jump Cut and J/L cuts read UserDefaults in Swift).
- Flows that need only the session and files are `ShellHost::xxx(h: UiRef<R>)` async fns with `ShellFlow` variants
  (`PasteSettings`, `PunchInCuts`, `NewSequence`, `SequenceSettings`, `ProjectNotes`, `GoToTimecode`, `Tone`, `ImportMixed`).
  The starters that need the hooks stay sync with a `ShellCx`: `go_to_timecode_command` (tries `ShellHooks::focus_timecode`
  first), `toggle_quick_apply`, `go_to_next_weak_tracking`, `perform_view_command`. `reconnect_from_found_file` needs
  `R: MediaWorkers` as well, so it is called by the app directly (the Project list's health line), not through `run_flow`;
  `relink_media` is a plain flow for `ShellAction::RelinkMedia`. The dispatch (`performDialogCommand`, ShellAnalysis) belongs to
  the group that ports those files.
- `canClose` cannot read the form the dialog owns: the Sequence Settings form keeps a `usable` flag and Reconnect a tick count
  in its change reaction; the dialog's `can_close` reads that.
- The Sequence Settings `State` class is `Rc<RefCell<SequenceSettingsState>>`, shared by the change reaction and the answer.
- New hooks: `media_clipboard`, `pasted_image_folder`, `focus_timecode`, `quick_apply_items`, `library_presets`,
  `edge_selection`, `save_stack_as_preset`. New fields: `ShellHost::{settings, audio_role_defaults, magic_health}`.
- `QuickApplyPopup` owns its `QuickApplyModel` (recents and the last search persist through the settings view); its `onChoose` /
  `onClose` are `take_events()`, polled by `ShellHost::handle`.
- `format_g` in `shell_sequence_match.rs` copies the crate-private helper of sq-editor-session (`%.5g`); use that one when public.
- Tone slider ranges are literals (20 Hz...20 kHz, -60...0 dB): `ToneSpec`'s range constants are private.
## SH-D: flow and dialog files (analysis, audio, imports, card import, find, locate ...)
Ported: ShellAnalysis, ShellAnglesSync, ShellAnonymize, ShellAudioFlows, ShellAudioTools, ShellBackgroundOffers, ShellCaptions,
ShellCardBrowser, ShellCardImport, ShellCheckCuts, ShellClipDialogs, ShellCollect, ShellEditAPI, ShellFind, ShellImport,
ShellInterchange, ShellLibraryImport, LibraryImports, ShellLocate (modules `shell_*.rs`, `library_imports.rs`). Tests: the
modules' own `tests` and `tests_d.rs` (flows on the rig idea of `tests.rs`).

### Mapping decisions (SH-D)
- Everything the Swift `ShellHost` held besides the session (`projectModel`, `projectList`, `probe`, `waveform`, `clipPeak`,
  `startTimecode`, `voiceover`, `voiceRecorder`, `presetStore`, `analysis`, `runAnonymize`, `edgeSelection`, `files` for
  the app's pool ...) is the trait `ShellServices` (`shell_flow_env.rs`), every method defaulted to "not provided";
  `ShellHost::flow_env` (`FlowEnv`) holds it with the flow state (`relink_offer`, `import_running`, `silence_preview`,
  `edit_api`, `card_import_volumes`) and the flows' own settings store. Work the platform does on a worker answers through a
  `ModalAsk` (probe, import, relink scans), like the file choosers.
- `spawn { await ... }` of a sync command is `ShellFlow::Tool(ShellTool::..)` (one new `ShellFlow` variant), run by
  `ShellHost::run_tool`. `onJob` is `ShellEvent::Job`, `presetsChanged` is `ShellEvent::PresetsChanged`.
- `UserDefaults` of the flows is `FlowEnv::settings` (a `SettingsStore`; strings UTF-8, numbers decimal text, string arrays one
  per line); the dialogs read and write it through `ShellHost::{setting_string, setting_number, setting_list,
  store_setting_*}`. Two other groups added their own store (`ShellHost::settings`, `ShellHost::defaults`): at the merge point
  these four helpers to the one store (nothing else in SH-D reads `flow_env.settings`).
- A form reaction cannot reach the session or the dialog, so what Swift did inside `onChange` is done differently:
  Check Cuts works out the summary of all three platforms when the sheet opens (`CutCheck::analyze` is pure) and swaps the
  chart; the markers of the platform left on the popup are written when the sheet closes. Remove Silences keeps a snapshot
  (`SilenceScan`: audible clips, faders, waveforms) so the live count needs no session; the preview ranges are
  `FlowEnv::silence_preview`, read by the app each frame instead of a `silencePreview` callback. A dialog button that depends
  on a field (Find, Voiceover) reads a flag the form reaction keeps (text fields report on commit, as in Swift).
- `ShellCardBrowser` is a shared handle (`Rc<RefCell<..>>`); the dialog owns one clone as content, the flow another. A
  `ShellDialogContent` gets no clock, so its scroll body counts from the time the board was made. The Rust `ShellDialog::press`
  refuses negative responses, so the card dialog's Cancel is response 3 (Swift: -1).
- `import_mixed` runs the other kinds one after the other (Swift started each as its own task); media go first.
- Auto Reframe, Find Scene Changes and Stabilize call the `AnalysisFlows` object of `ShellServices::analysis`; its UI events
  leave as `ShellEvent::Job` / `Status` through `ShellHost::forward_analysis_events` (the app calls it after routing a worker
  message).
- Record Voice-Over: `ShellServices::toggle_voice_recording` runs `EditorSession::toggle_voice_recording` with the app's recorder
  and importer (the session seam wants both at once). The status line has no countdown number (the recorder seam has states).
- Loudness measuring is `ShellServices::measure_loudness` (the session's `MeasureLoudness` seam); it blocks the UI thread, as the
  session designed it; Swift awaited.

### Not ported / pending (SH-D)
- `MogrtImporter.read` (template capture) is not in `sq-premiere-import` (only `open`): `ShellServices::read_mogrt` stands in,
  the default fails with a message; `library_imports::import_mogrts` takes the read results.
- `AnalysisFlows::request_color_match_to_clip` is `pending!("ES6")` in the session: Match Color to Clip says "not available".
  `goToNextWeakTracking` / `toggleQuickApply` (ShellQuickApplyCommands) and the arms of `performDialogCommand` for
  NewSequence, SequenceSettings, ProjectLiveDucking, ProjectNotes, GoToTimecode, NewTone, ToneSettings, PunchInCuts,
  PasteAttributes, QuickExport, ImportProject and `performViewCommand` belong to the group that ports those files; they add the
  arms to `perform_dialog_command` / `run_analysis_command`.
- `showImportChecklist` / `showImportReport` (ShellImportReportContent, no owner in the task split) and the Reconnect Media offer
  that follows an import: the imports end after `session.new_project`, the status line and `ProjectChanged`.
- `ShellHooks::showCaptionSearch` (the Find command asks the Captions panel first) is not wired; Find always opens the sheet.
- `projectModel.importFiles` progress, `ShellCardImport.poster` as a static: `FlowEnv::card_poster` is taken by the next card
  dialog. The card dialog closes when the import starts (Swift shortcut kept).
- Dates on the card board are UTC (`date_text`); Swift used the user's locale and time zone.
- `ShellFilePicker::chooseFile` / `chooseExportLocation` Swift extensions already exist in `shell_file_picker.rs`.
- `MediaManagement.importedFolder(forProjectAt:)` is a local copy in `shell_collect.rs` (shortcut), `ProjectFile.isProjectURL` one in
  `shell_import.rs`.
- Check Cuts passes no caption box function (`EditorSession::caption_box` is pending in ES3), so captions are not checked.
- A relayout of the open dialog after Check Cuts' chart note changes its line count waits for the next layout pass.

## Swift quirks kept (SH-D)
- `ShellAudioTools.waveforms` polls the cache in 100 ms steps up to a timeout; media that never arrive are left out.
- `ShellCheckCuts` stores the platform choice on every change; here once when the sheet closes with another platform.

## Pending (owner: the group that ports the named Swift file; each stub sits in `src/pending_steps.rs` unless noted)
- ShellFocusedEdit: `run_focused_edit`, `focused_deletes_project`, `run_focused_delete` (+ `editActions`, `projectList`).
- ShellDock(+Shell, +Draw): `dock`, `execute_panel_command`,
  `perform_window`, `fill_window_state`, `dock.handle`/overlay in `handle`/`draw_overlays`, Esc docking a floating panel,
  `canRenameWorkspace`/`canResetWorkspace`; ShellAudioFlows, ShellAnalysis (`analysis`, titles, enabled), ShellLibraryImport,
  ShellClipDialogs `perform_dialog_command`, ShellFormat `pixel_aspect_rows`
  and `set_selection_pixel_aspect`, ShellRecovery (`save_checkpoint`), `startScreen`,
  ShellShortcuts (`show_shortcuts`, `shortcutsEditor`), ShellBackgroundOffers, ShellImport
- ShellAudioFlows, ShellAnalysis (`analysis`, titles, enabled), ShellLibraryImport,
  ShellClipDialogs `perform_dialog_command`, ShellHelp `perform_help`, ShellRecovery (`restore_autosave`, `save_checkpoint`), ShellStart (`show_start`, `startScreen`,
  `syncStart`, `chooserShown`), ShellShortcuts (`show_shortcuts`, `shortcutsEditor`), ShellBackgroundOffers, ShellImport
  (`import_anything`, `import_premiere_project`, `showImportChecklist`), ShellNewProject, ShellPreferences, ShellExport (the
  `.export where exportSources != nil` arm), ShellCollect/Relink/SequenceDialogs/Format flows (`project_flow`), ShellQuickApply and the
  export queue popover (`handle`, `draw_overlays`, `owns_keyboard`).
- ShellHost.swift fields whose types live in those files (`dock`, `startScreen`, `shortcutsEditor`, `quickApply`, `queuePopover`,
  `projectList`, `projectModel`, the export, preferences and library hooks, `fullScreenStarted` ...) are added by their owners.
- `ShellHost.newProject()` (the start window's quick path) is not ported: it needs `EditorSession.makeUntitled` ids, but `EditorSession::ids`
  is crate-private. A public `new_untitled_project()` on the session would close it.
- `NewShape` fallback (a Graphic with the kind's default box) needs the same id source plus the stored default text length: it flashes
  "not available" when no host places the shape (`ShellHooks::on_new_shape`).
- `MediaManagement.outsideMode` / `projectFolder(forProjectAt:)` and `MediaPolicy.isEmpty` are not in `sq-core-project` yet; local copies in
  `shell_menu_actions.rs` (marked shortcut), `MediaPolicy::default()` stands for `isEmpty`.
- `SQLog` lines (project open/save, errors) are dropped until a Rust logger exists.
- The autosave version label shows UTC, ISO order (`absolute_time`, marked shortcut); the Swift Mac path used the locale formatter.
- `CommandMap.finalCutDefault` is not in `sq-uikit`: the shortcut walk test (`ShellMenuShortcutWalkTests`) is not ported yet.

## Swift quirks kept
- `ShellDialog.handle` with a form: Escape and Enter both pass through the `if k == .enter || k == .escape` test, only Enter commits.

## Merge sh-d + sh-e
- Wired: `perform_dialog_command` now has the sh-e arms (NewSequence, SequenceSettings, ProjectNotes, GoToTimecode, NewTone,
  ToneSettings, PunchInCuts, PasteAttributes) and falls back to `perform_view_command`; `run_analysis_command` has QuickApply and
  NextWeakTracking; `ShellFlow::ImportAnything/ImportMixed` call the real `ShellHost` imports. Still open: ProjectLiveDucking,
  QuickExport, ImportProject arms.
- Two settings stores remain: the `setting_*` helpers use the host store; the audio/analysis/anonymize flows still read
  `flow_env.settings` directly (shortcut in `shell_flow_env.rs`).
