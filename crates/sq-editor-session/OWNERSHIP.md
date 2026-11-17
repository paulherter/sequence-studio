# sq-editor-session: ownership

The session is owned by the app root (`UiRoot<App>`) and used on the UI thread only; no field holds a reference to the
app or to another panel.

| field | owner | lifetime | shared-by |
|---|---|---|---|
| `EditorSession.history` (Project snapshots) | `EditorSession` | project open | undo snapshots share `CowVec` buffers (Arc, copy on write) |
| `EditorSession.media: Arc<dyn SessionMediaResolving>` | `EditorSession` | session | engine and worker threads read it (`&self`, lock inside the resolver) |
| `EditorSession.engine: Box<dyn ProgramEngine>` | `EditorSession` | session | the adapter talks to the playback thread through `sq_playback::ProgramHandle` (mailbox) |
| `EditorSession.auxiliary_engines` | `EditorSession` | until `is_alive()` is false | engine handles; the Trim monitor owns its own handle to the same engine |
| `EditorSession.side_steps` closures | `EditorSession` | until the history step leaves the stack | capture `Arc` stores (matte store), never the session |
| `EditorSession.media_info_probe`, `color_detector` | `EditorSession` | session | cloned (`Arc`) into worker jobs |
| `EditorSession.*_task: Option<JoinHandle<()>>` | `EditorSession` | until done or canceled | the UI executor polls the task |
| `RefOnlyMediaResolver.state` | `RefOnlyMediaResolver` | session | `Mutex`: UI thread writes, engine threads read |
