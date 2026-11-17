# sq-draw-timeline

The drawn timeline (Swift `SQDrawTimeline`) as an `AppHost` of `sq-app-shell`. Design: `docs/rust/session-ui-design.md`
sections 3-4 (tasks DT1-DT4). Logic lives in `sq-timeline-ui`; this crate draws it through `sq_draw::Canvas`, routes
`InputEvent`s and applies the actions to the `EditorSession`.

## Public API
- `TimelineAppHost`: `AppHost` around one `TimelinePanel` and a `TimelineHost` (hooks for editors and dialogs).
  `sync` pulls the sequence from the session, `layout` converts the frame to device pixels, `draw`, `handle` applies the
  returned `TimelineAction`s through `session_bridge::apply`; `needs_frames()` tells the app to keep drawing (zoom ease,
  spring back, autoscroll).
- `TimelinePanel`: state, `sync(SessionView)`, `layout_px`, `handle(&InputEvent, &mut UiCx) -> Vec<TimelineAction>`, `key`,
  `key_up`, `tick`, `follow_playback`, `reveal`, zoom (`set_zoom`, `zoom_in/out`, `zoom_to_fit`), drop (`drop_hover`,
  `drop_commit`, `drop_exit`, `effect_drop_hover`), `cursor_at`.
- `TimelineAction`, `TimelineEditorRequest`, `TimelinePrompt`, `TimelineHost`: what the panel asks of its host.
- `TimelineMediaSource` / `TimelinePicture` / `ThumbnailAtlas`: waveforms, thumbnails and offline state of the media.
- `TimelineDropSource`, `drop_items`, `drop_replace`: what a drag onto the timeline carries.

Modules `lanes`, `captions`, `bands`, `menus`, `header`, `tool_strip`, `trim_bar` belong to the second DT worker.
Notes and open pieces: `PORTING-NOTES.md`. Check: `cargo xtask check sq-draw-timeline`.
