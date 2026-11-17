# sq-editor-session

Port of the Swift package `SQEditorSession` (frozen reference: `Packages/SQEditorSession/Sources/SQEditorSession`): the
editing session with undo history, active sequence, playhead, selection, file state and the services around them
(Program engine, media resolver, proxies, render cache, analysis), plus the models the panels read (markers, export
dialog, project panel, workspaces, settings).

- `EditorSession` (`src/session.rs`): every stored property of the Swift class as a `pub(crate)` field; `perform`,
  `try_perform`, `end_gesture`, `register_side_step`, `undo`, `redo` over `sq_core_edit::history::History<Project>`.
- Changes: `notify(Change::X)` bumps one of nine version counters and keeps the flags until `take_changes()`; Swift's
  `on*` hooks are `SessionEvent`s drained with `take_events()`.
- Services (`src/services.rs`): `ProgramEngine`, `SessionMediaResolving`, `SessionRenderCaching`,
  `SessionProxyServing`, `AnalysisBackend`, `ProgramFrameSampling`, with `StubProgramEngine` and
  `RefOnlyMediaResolver` for headless runs.
- Async flows take `UiRef<R>` with `R: SessionRoot` (`src/root.rs`).
- The ten `esNN_*` modules belong to the ES workers; `TASKS.md` lists their Swift files and what is left,
  `CONVENTIONS.md` how Swift types map, `pending!("ESn")` marks unported bodies.

Not ported: Mac-only code (`#if os(macOS)`: VoiceRecorder, MediaDiskWatcher, shoot metadata probe, viewer zoom,
Metal textures, Look preview); the portable branch is the oracle.

Regenerate the task list: `scripts/session-tasks.py` (`--stats`, `--list ESn [file]`). Check: `cargo xtask check sq-editor-session`.
