# sq-app-hosts: porting notes

> Status 2026-11-09: this file was written step by step while the hosts were built; sections below that say "pending", "deferred" or "not available" are partly stale. Since then the root answers Library requests (add folder, preset and pack flows, reveal, whoosh: `rs/w9-*`), Library drags and the text template catalog, Timeline dialogs, track mix, sequence volume, markers, caption editing, the curve popover Save (files an `.easing` preset), the Export sheet, Welcome Tour, Edit API and stored defaults. Entries marked [stale] were checked against the git log, not re-read in code; the open list is in the Roadmap.

## Mapping decisions
- Swift `LibraryHost.run(_:)` -> `route_library` (pure, tested) plus `LibraryHost::take_deferred`.
- The remembered preset apply mode (`PresetApplyModeSetting`) arrives as a closure, the panel keeps its store private.

## Pending (needs a root that owns executor tasks, menus and the timeline host) [stale 2026-11-09: Library requests, menu, drag and the title block / text template placement are answered; see 33d11d45c, 7e49cb440, 0b1e22dbd]
- `LibraryRequest` AddFolder, Reveal, ExportPreset, ImportPresets, DeletePreset, ExportPack, ImportPack and Whoosh:
  dialogs and file choosers (`shell.spawn` + `ModalAsk`). They come back from `take_deferred` as `LibraryDeferred::Request`.
- `LibraryPanelEvent::Menu` and `Drag` (menu controller, `LibraryDropRoute` onto the timeline panel).
- `LibraryModelEvent::InsertTitleBlock` (`TextTemplatePlacement` is not ported), `FoldersChanged`, `ImportWorkspaces`.
- Non-CTA, non-graphic text templates (`session.addTextClip(template:)` needs the template catalog).
- `model.preview.onWillPlay` stopping the sequence: the portable preview player is silent, wire it with the player.

## Monitor and timeline hosts
- No new `AppEvent` variants: both hosts need only `Status`; everything else waits in their queues for the app root.
- Monitor pending: tabs, source drag, Type/Create tools, text double click, graphic text pick (`pickGraphicText`), engine
  and format choices, full screen, quality (all need the shell, inspector or engine hosts).
- [stale: the root answers the Open queue] Timeline: the host accepts every editor request, so no "not available" status shows until the root answers the
  `TimelineHostEvent::Open` queue; the prompt hook is unset (missing-prompt status). Slip two-up and item-selection hooks
  are for the monitor and inspector hosts to connect.

## Root (dock, menu, dialog)
- `AppRoot` places the hosts with `ShellDock` (default `WorkspaceStore`, no saving yet); panels without a host draw `draw_placeholder`.
- Monitor and Library menu events and a tab's right-click menu open in the root's `MenuController` at the next layout.
- `AppHost::handle` carries no text measure, so key-driven menu/dialog sub-layout measures without an atlas until `HostCx` offers one.
- Dialogs: `AppRoot::show_dialog(ShellDialog)`, modal; the dock's focus, save and floating events are dropped for now.
## InspectorHost (clip sections)
- Owns `ClipSectionsDraw`; `route_sections` runs SetShapeKind, SetColorMatte, AudioRole and UpdateText (single or multi text selection). Pickers,
  AudioPreset (engine), AlignToFrame, StylesChanged, Template and EditGraphics come back from `take_deferred`.
- The audio block factory is a constructor argument (it needs the preset library and an id source).
- Pending: the text block/model (`load_text`/`pump_text`), Captions, Graphics and Effect Controls panels and `MultibandHost` are not hosted yet
  (their draw panels are still being wired in sq-inspector-ui; they need `Rc<RefCell>` models shared with the monitor and timeline hosts).
- The section column does not scroll yet (the Swift host puts it in the Controls scroll view).

## ShellHost (menu bar, dialogs, Preferences, start window)
- `route_shell`: `ShellEvent::Status` -> `AppEvent::Status`; every other event and every `ShellFlow` waits in `take_deferred`
  (quit, settings, folders, export queue, flows need the window, the executor and the platform).
- Escalation: `AppHost::layout` and `draw` get no session and no `UiCx`. The host builds the menus in `sync` and installs them in `layout`, and
  draws with its own `UiCx` (no shell tooltips). `HostCx` has no glyph atlas, so `handle` measures at zero width; add the atlas to `HostCx`.
- `ShellHooks` is a constructor argument; the app root implements it once all panel hosts exist.

## Menu flows, start window, stored state
- `App::launch` shows the start window for an untitled empty session; `ShellDeferred::Flow` becomes `AppEvent::Flow`, the loop spawns it
  (`Headless::turn`) with `App` as `ShellRoot`; Quit becomes `AppEvent::Quit`. `App::settle` (after each task poll) lets hosts route what
  the tasks left in the shell.
- The dock layout (`workspaces.json`) and the recents (`recents.json`) are saved in the support folder (`AppRoot::with_storage`).
- Not stored yet: the start screen settings (`ShellEvent::Setting` is dropped), floating panel state; other shell events still show the status line.

## Edit menu, transport and shortcuts
- The shell already runs Edit and transport commands on the session (`ShellCommands::run`); the root now gives it what it lacked: the dock's
  focus (`DockEvent::Focus` and a press inside a panel set `ShellHost::focus`, the scope of timeline-bound shortcuts such as Add Edit)
  and the timeline's menu/header commands (`ShellHost::run_command`). Key presses reach Library, Monitor and Inspector only while they have the focus.
- Tests drive the root with real key events: split + undo/redo, delete/ripple delete, cut/paste/select all, play/pause, step, go to start/end.

## ProjectHost (Project panel)
- Owns `ProjectListView` and a view copy of `ProjectPanelModel` (headless import deps; imports still run through the app's own
  panel and arrive as a project change, `sync` and `on_change` reload the copy). Docked as `PanelID::Project`; keys reach it only with the focus.
- `route_project`: OpenSequence/OpenVariant, Flash/Message, Import (`ShellFlow::ImportAnything`), Insert/Overwrite run here; menus, drags and
  the rest wait in `take_deferred`. The root places media dropped on the timeline panel at the playhead (Overwrite); menu rows run in `pump`.
- `AppHost::layout`/`draw`/`handle` all get the `HostCx` (session, `UiCx`, glyph atlas, scale; `cx.measure()`), so no host keeps a throwaway session or measures at zero width, and menus open in `handle`.
- Posters: `ProjectThumbnails` queues, a worker pool decodes through `FfmpegPosters` (`sq-media-ffmpeg`), an `Inbox` brings the pictures back in `sync`;
  new pictures wait in `take_uploads` for the renderer (it must fill the slot named in `ProjectListView::posters`).
- Find, Replace Media and Locate run the shell's `ShellTool` flows; Reveal goes through the `Platform` trait (`open -R`, `explorer /select,`);
  Rename edits in a field bar over the list (the list keeps row geometry private; a cell-level editor needs a public row rect in sq-draw-shell).
- Not done: OpenMedia (needs the source monitor), bins dragged as clips, settings persistence (`SettingsChanged`), a11y nodes, poster visibility hints (`set_visible`).

## SourceMonitorHost (Source monitor)
- Owns `SourceMonitorCore` and a Source-mode `MonitorPanel`; the core's model sits in the panel only during a panel call (`with_panel` swaps them).
  The root opens it on `ProjectListEvent::OpenMedia` (double click) and shows the dock tab; Insert/Overwrite run in the core at the playhead.
- Own engine and picture: `standard_root_with_source`. The picture draws as renderer image slot `SOURCE_PICTURE_SLOT` (`MonitorPanel::picture_slot`), the Program card keeps the one video quad.
- Only one monitor plays: `StartedPlaying` stops the session, a playing session pauses the source in `layout`. The core ticks in `layout` (one call per frame).
- Not done: keyboard shortcuts while the Source tab has focus (the shell's key map runs the Program transport; `SourceMonitorCore::handle` is not wired), the picture is not cleared when the clip closes,
  context menu rows other than the core's own, full screen, tabs of several opened clips (model events the core does not own are dropped).

## Export (File > Export)
- `ShellHost::enable_export(ExportSetup)` turns it on: the draw shell's Export command starts `ShellFlow::ShowExport`, the sheet
  (`sq-draw-shell/shell_export_sheet.rs`: sequence, preset, file name, folder) submits through `export_after_sheet`, and
  `ShellEvent::RunExportQueue` runs `ExportQueue::run_all` on a detached thread (`export_host::run_queue`). Progress is the status
  line plus the status ring; Cancel is the queue popover (`StopExport`).
- The jobs read an `ExportSnapshot` (sequences and media) that `ShellHost::sync` refreshes; the app supplies the renderer
  (`sequence-studio/src/export.rs`: a paused `ProgramHandle` seeking frame by frame, FFmpeg encoder).
- Audio: `sequence-studio/src/export_audio.rs` runs the playback feeder offline (`FeederMix` as `MixFeed` in a `TimelineAudioSource`), muxed as AAC/PCM by the encoder. The folder row has a Choose button (`ShellFilePicker::choose_folder`).
- Not done: the full ShellExportSheet (preview, per-format rows, range, loudness),
  Quick Export, stems, cut-downs, a worker-pool lane instead of the detached thread.

## Effect Controls (in InspectorHost)
- The host owns an `EffectControlsDrawView` below the clip sections (sections height is the offset). `sync` follows the session
  (selection, project, playhead versions) through `EffectControlsModel::sync`; `route_controls` is Swift `EffectControlsBinding.connect`:
  Edit/EditMany/AudioEdit, gestures, seek/scrub, clipboards, notices, ResetSpeed and the Speed rows run on the session.
- Also routed now: AlignToFrame (`align_text`) and GraphicItem (graphic layer selection) from the sections.
- Waiting in `take_view_deferred` (root reports "not available"): menus, key tool prompts, color pickers, curve popovers, Multiband editor,
  mask tracking, ResetToAutomatic, the Speed remove-keys question. Still in `take_deferred`: pickers, AudioPreset (engine), Template, StylesChanged, EditGraphics.
- Answered in the root now: Effect Controls and Layer menus (`take_menus`; rows queue index paths, `pump` runs them on the view and the
  session with undo), color picker popover (`color_popover.rs`: matte, template slot, EC color and mask range; no recents), Remove Keyframes
  and field-less key tool dialogs (`take_dialogs`), Template events (`route_sections`).
- Answered in the inspector now: key tool prompts with text fields and SaveCurve (`inspector_host/forms.rs`, a form dialog; texts are read as the
  form reports them), ResetToAutomatic (`session.reset_variant_override`; `automatic_resettable` is filled on sync), the curve popover
  (`inspector_host/ease.rs`: motion effect Custom curve and the speed transition at the playhead), the Multiband editor (`MultibandHost` as a
  floating panel; "Spectrum at Input" starts off and is not stored), EditGraphics (brings the Graphics panel forward).
- [partly stale: eyedropper, mask tracking and the curve Save are done, 2fd73c0cb, 9ee436c42] Gaps still waiting: the Key Hue/text eyedropper reads only the Program picture (no screen read-back), mask tracking, the track audio presets
  (kept in `AppRoot::audio_preset`, in memory like Swift's; playback and export do not read them yet), a curve saved from the
  popover (the preset store is the Library's, the Save event is dropped).
- Graphics panel: `GraphicsHost` (`graphics_host.rs`) hosts `GraphicsPanelDraw` in the dock. The panel holds a stand-in session and every call runs
  inside `with_session(cx.session, ..)`, which swaps the host's session in and out (the hosts only get `&mut EditorSession`). EditGraphics brings it forward.
  The color picker (`ColorPopover<ColorTarget>`, drawn over the dock and given events first) and the text eyedropper (the Program-picture
  `Eyedropper` shared with the monitor) are answered by `GraphicsHost::pump`; menus and template requests reach the root through `take_requests`.
  Text styles (`StylesChanged`) save into `looks.json` under the support folder (`LookStore`, `AppRoot::with_prefs`).
- Not done: Stabilizer re-plan after an edit, color match sampling, divider width storage, the section column and EC rows share one frame (no outer scroll).
- Effects are added from the Library panel (`ApplyPreset` -> `session.apply_preset`) to the selection; dragging onto the timeline/inspector is the Library drag route (deferred above).

## EffectsHost (Effects panel)
- `AppRoot::with_effects`: a drag shows a ghost at the cursor at once; a release over the timeline applies the target `effect_drop_hover` lit (clip effect/preset, transition at a cut, transition layer on an empty spot), over Effect Controls it applies to the selection; a double click applies to the selection. All are single undo steps.
- Shortcuts: apply mode and transition lengths are the factory ones (no Settings in the hosts yet), the saved presets are not re-listed in the panel after the Library changes, folders and view mode are not stored.
- Library files, titles and text templates dragged out of the Library panel are still deferred (only files onto the timeline work).

## Timeline commands and menus
- `TimelineHooks` (shell hooks) queue the commands the panel owns (`is_view_command`: snapping, linked selection, Fast Cut, tools,
  zoom, track heights, Fit Tracks, edge selection/trims, speed band, templates, marker editors); `AppRoot::answer_timeline` runs them
  with `run_view_command`/`run_speed_command` and publishes the View check marks. Session commands (add/delete track, lock, group,
  markers, trims) already ran through the shell. Build the root with `with_timeline_link` (`standard_root` does).
- Right-click on the timeline: `TimelinePanelHost::handle` builds the menu (`TimelineMenus::items`: clip, gap, track header, ruler,
  transitions, keys), the root opens it, `pump` runs the chosen rows.
- Editor requests: `Source` opens the Source monitor. Answered in the root now: the transition duration (the open hook declines it, so the
  timeline's text prompt runs; `timeline_dialogs.rs` shows every prompt, Rename Track/Clip and Combine too), track mix, sequence volume,
  marker and clip marker sheets (the shell's form, now `pub`), the caption line editor (lines joined by " / ", as the Swift fallback) and
  Reveal in Project (`ProjectHost::reveal`, brings the panel forward). A dialog only reports into a map; the answer waits in `Answers`
  and `TimelinePanelHost::pump` applies it to the session.
  Still "not available": trim mode (`ShellHost::enter_trim_mode` needs a `ShellCx`, which the hosts cannot build), the speed curve
  (`EasePopover::open` only starts from the Controls model, not from a clip and segment), save presets/title blocks/templates, text/tone/graphic
  editors, color matte, angles clip, caption word editing and find/replace, key lane picks.
- The view settings (track height mode, Fit Tracks, toggles) sit in `MemorySettings` in the root; connect them to the stored defaults.
  `load_height_prefs` is not called yet. Disabled commands (Mute/Solo/Link without a track or clip selection) still show the shell's
  generic "not available" line.

## Preferences, stored state, autosave and recovery (`persist.rs`)
- `AppRoot::with_prefs(support)`: the shell's defaults store becomes `FileDefaults` (`prefs.json`, rewritten whenever a value changed, so Preferences,
  the start window tab/sort and every other `UserDefaults` write persist). Cmd/Ctrl+, and the menu run the draw shell's Preferences (`ShowPreferences`).
- Applied after each change and at launch: palette and interface size (`AppEvent::Appearance`, `App::set_theme` keeps the display scale apart from it)
  and the autosave interval. Playback options, pre/post-roll etc. are read from the store by the commands, so they follow at once.
- Floating panel frames: `floating-panels.json`, written once the window was quiet for 0.5 s, loaded in `with_prefs`.
- Autosave: `tick_autosave` on every pump (the policy decides). The session writes the crash marker itself; Quit calls `session.close()`.
  At launch the newest unsaved autosave of a dead run is offered with the shell's recovery dialog (off with `offer_recovery`); Discard dismisses the marker.
- Not present in the prefs model, so not done: a recent projects limit (`RecentProjects` has a fixed cap). Pending: the Swift `writeCrashReports`;
  the process check spawns `kill -0` / `tasklist` (no FFI here); a recovered project does not close the start window by itself.

## Export sheet
- The sheet has sequence, preset (every preset the encoder writes, incl. audio only, GIF and image sequences), range (whole, In to Out,
  selected clips), the loudness switch, file name and folder. Quick Export (`ShellFlow::QuickExport`, Option+Cmd+M) runs the last preset and
  settings into `Exports/` without a sheet.
- The sheet also has the stem roles with Export Stems (`ExportSetup::make_stem_audio`: the offline mixer, one `FeederMix` per stem timeline;
  `stem_encoder`) and the cut-down ranges with Export Cut-downs (jobs through the queue). Both buttons run inside the open sheet.
- The preview renders on a worker thread (`shell_export_preview.rs`, newest request wins) and follows the range, the custom In/Out, the
  sequence and the playhead (100 ms poll). It sits in image slot 1 (the Slip two-up slot, free under a modal sheet); a seventh slot needs
  a change of `DrawQuads.slang` and `cargo xtask shaders` (slangc), not done. A preset change does not re-render it.
- Gaps: preview scrubber, stem presets (Swift `StemPresetStore` rows), the codec/profile/HDR rows, "Other Formats".

## Color page (`color_page_host.rs`) and the Edit | Color switch (`chrome/title_row.rs`)
- The switch sits in the middle of the title row (as `SharedUIController` centers it) and is dropped when the name or the Workspace popup would
  collide; a press runs `ShellDock::set_page`. The Color page shows the Color settings (`ColorInspector`), Steps, Sources and Scopes on the
  dock's cards, the viewer header above the Program monitor card, and hides Steps while the Pro grade is not shown. Edits go through
  `ColorGradeController` into the session (one undo step each); menus open through the root's menu controller.
- Done: the strip tools of the Color, Steps and Sources tabs (`ColorStripToolsDraw`; the host sets `ShellDock::strip_tools` from the
  controller and draws/clicks them over the strips), Before | After (`SetColorBypass` -> `EditorSession::set_color_bypass`), LUT choosers
  (`PanelFileChooser::choose_luts`), the Step decision chooser (`ShellFilePicker::choose_file`, polled in `pump`), Scopes counts from the
  Program `MonitorPicture` (`AppRoot::with_scope_picture`, `MonitorPicture::generation`), the grade text in the status bar (`ChromeInputs::grade`).
- Gaps: a picked color decision file is only reported (the ASC CDL / CMX EDL reader is not ported); the Timeline strip's tools (Copy/Paste,
  detail) are not drawn; the white-balance eyedropper, Auto measuring and the loupe (`PickScreenColor`, `SampleProgramFrame` need the platform
  read-back); the Step window handles on the monitor (`refreshStepWindow`) and the Split divider; the timeline's grade outline; the Scopes'
  pictures (`ScopesPanel::images`) are made but the window must upload them to the image slots; Sources tiles have no thumbnails (no decoder or
  atlas upload seam); copy/paste via the Edit menu while a Color panel has focus (only Cmd+C/V in the panel); the Color page's own pointer
  cursors; Copy Grade beep shows a status line.
- A `Window` menu change that goes through `ShellHost.dock` (not the root's dock) does not move the page; the root's dock is the one the switch uses.

## Angles sync (Create Angles Clip)
- Done: the sheet offers `AngleSyncMode::choices` whole; the answer queues `ShellFlow::CreateAngles` (the editor dialogs' outbox, `TimelineHost::take_flows`),
  the root emits it and `ShellHost::create_angles` reads the timecodes or sounds (`angles_origins`), makes the clip and says the outcome.
