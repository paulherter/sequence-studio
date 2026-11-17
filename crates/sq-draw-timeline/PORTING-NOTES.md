# sq-draw-timeline porting notes

Port of `Packages/SQDrawTimeline`, DT1 + DT2: TimelinePanel (+Draw, +Input, +Wheel, +Cursor, +Ruler, +ZoomBar, +Follow,
+Skimmer, +Overlays, +HostDefaults, +Drop, +Media, +LaneCache), TimelineHost, TimelineAction, TimelineSessionBridge,
TimelineSkin, ThumbnailAtlas, TimelineDrop. Swift file -> module: `TimelinePanel+X.swift` -> `x.rs`; `+Drop` and
`TimelineDrop` are `drop.rs`; `TimelinePanel.swift` is `panel.rs`. Rust-only: `app_host.rs` (the `AppHost` wiring), `geom.rs`
(`CGRect` helpers), `tests.rs`.

## The panel extension files (DT3/DT4 wiring)
Every `TimelinePanel+X.swift` is ported: `item_lanes` (+ItemLanes), `caption_words` (+CaptionWords), `caption_lanes`
(+Captions), `caption_search_panel` (+CaptionSearch), `band_gestures` (+Bands), `speed_band`, `speed_commands`,
`fast_cut`, `keystones`, `source_patch`, `view_commands`, `track_headers` (+Header draw and hit, +MixRow),
`transition_layer`, `key_lanes`, `timeline_menus` (TimelineMenus, `contextSelect`), `TimelineHeaderState::make` in
`header.rs`, the duck curve (`duck_context`, `draw_duck_curve`) in `overlays.rs`. The panel-free controls (`header`,
`bands`, `lanes`, `captions`, `menus`, `tool_strip`, `trim_bar`) are called from them. The Swift order of hit checks and
draw calls is kept (`input::pressed`, `draw::draw_timeline`, `draw::draw_lanes`, `cursor`).

## Not ported / deferred (needs a type another crate does not have)
- Perf and frame-bench suites (`TimelineFrameBenchTests`, `TimelinePerfTests`, `TimelineCullingTests` timing parts).
- Mac-only: the AppKit branches are not in this package (it is the shared draw UI).

## Deviations from the Swift API (decisions)
- Events are pixels, the panel keeps points: `TimelinePanel::point` converts with the frame set by `layout_px`; the
  `AppHost::layout` call passes points and `HostCx::scale`.
- `TimelinePanel.sync` takes a `SessionView`; `selectedTransition` and the picked line keys have no `EditorSession`
  accessor yet (`pub(crate)` fields), so `TimelineAppHost::sync` keeps the panel's own values. The session owner adds
  `selected_transition()` and `selected_line_keys()`.
- `TimelineHost.prompt` is callback style (`FnOnce(String)`) instead of `async -> String?`; the `panel:` hook is gone (the
  bridge's caller owns the panel).
- `.dropMedia` calls `place_media` (sync) instead of `placeMediaAsking`: the format question needs a `UiRef` task.
- `TimelineWheelState`, `ZoomBarSnapshot`, `Gesture` are `pub(crate)`; `Gesture::Header` carries no payload (the Swift `.header(id, toggle)` payload is never read).
- Swift `sync` order kept; `interaction_seed` replaces `UUID()` ids inside the reducer (see `sq-timeline-ui` notes).
- `TimelineAppHost::sync` also runs `tick` and parks its actions until the next input event (`AppHost::sync` has no
  mutable session).

## Escalations (resolved)
- `ClipAudioCurves::volume_db` / `source_map` return `Box<dyn Fn>` without `Send + Sync`, but `WaveformInput` needs
  `Arc<dyn Fn + Send + Sync>`: waveforms draw without the clip's volume and speed curves until `sq-timeline-ui` returns
  `Arc<dyn Fn + Send + Sync>` (`media::draw_waveform`).

- Done in sq-timeline-ui: `DuckCurveSource` (the draw of the duck curve itself, `drawDuckCurve`, is still open), `ToneWaveform`, `WaveformClipping` (both used by `media::draw_waveform`), `RazorGuide`; `ClipAudioCurves` returns `Arc<dyn Fn + Send + Sync>` and the waveform applies volume and speed curves now.

## Decisions of the panel extension port
- Menu rows cannot borrow the session (Swift captured `[weak s]`): each row of `TimelineMenus::items` pushes a `MenuEffect`
  into a `MenuOutbox` (`Rc<RefCell<Vec<MenuEffect>>>`, UI thread only, shared by the rows and the host that opened the menu)
  and the host runs them with `TimelineMenus::run_all(out, session, host, panel)` right after the row was chosen. Prompt
  answers (Rename, Combine, transition duration) come back through the same outbox.
- `session_bridge::apply` takes the panel as `Option<&mut TimelinePanel>` (the Swift `host.editPanel`): the keystone bar and
  the item selection follow `DropKeystone`, `RestretchKeystone` and `MoveItemsOut`. `ReorderItems` now runs
  (`GraphicsDocument::move_to_index` is ported).
- `TimelinePanel::fresh_ids` hands out deterministic ids (`PanelIds`) for what the panel's own edits create (band keys,
  duplicated layers, split captions), like `interaction_seed` does for the reducer.
- `beginWordEditing(at:caption:)` is `begin_word_editing_at`; `reveal(_ time)` is `reveal_time` (`follow.rs` has `reveal(range)`).
- `TimelineSideMenus.trackHeader` is `sq_timeline_ui::TimelineSideMenus::track_header(&Track, TrackHeaderMenu)`.
- `LayerListLogic.symbol` is a private `layer_symbol` in `item_lanes.rs` (the rest of the list logic is not ported).
- `UserDefaults` arguments (`runViewCommand`, `loadHeightPrefs`) are `&mut dyn SettingsStore`; `ThumbnailPrefs.didChange`
  (NotificationCenter) is not posted, the caller redraws. `runViewCommand` takes `Option<&mut TimelineHost>` and
  `owns_delete` like Swift; `runSpeedCommand` and `viewChecks` take the session by reference.
- `TextFieldControl::draw` needs a `UiCx` but `AppHost::draw` gives none: the word field draws with a fresh `UiCx` (the
  caret does not blink; marked `shortcut:`).
- `VolumeLineGesture` and `OpacityLineGesture` derive `Clone` (sq-timeline-ui) so `Gesture` stays `Clone`.

## Open
- The session's `linked_selection` mirror flag is `pub(crate)` with no setter: `sync_toggles` and `ToggleLinkedSelection`
  rely on `set_linked_selection` to set it when the sequence setting changes (`shortcut:` in `view_commands.rs`). The session
  owner adds a setter if the two can differ.
- `LineKeyClick { extend }` still replaces the picked set (the session has no accessor for it).
- `TimelineMenus` entries that the Mac builds from `TimelineMenuAction.label` use `s.set_label` (clip labels of the
  selection); media-bin labels stay in the Project panel.
