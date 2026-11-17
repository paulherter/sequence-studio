# sq-runtime

Async runtime of the UI side (std only, no unsafe, no dependencies). Port of the G5 spike (`spikes/g5-async`) plus the
root/inbox pieces of `docs/rust/session-ui-design.md` section 2.

## Public API
- `UiExecutor`: `!Send`, one per UI thread, `poll_frame()` runs every ready task once per frame; timers read an injectable
  `Clock` (`SystemClock`, `FakeClock`); `spawn_local` (cancel = drop), `spawn_cooperative` (cancel = flag), `sleep`, `TaskGroup`.
- `WorkerPool`: threads (or a manual pool for tests); `run` returns a future that resumes on the UI thread.
- `modal()` gives a `ModalAsk<T>` (future) and a `ModalAnswer<T>` (`answer`), the `ask()` of the shell host.
- `channel`: MPSC into the UI thread, optional wake callback (wakes the event loop); `Inbox<Msg>` drains at frame start.
- `UiRoot<App>` (`Rc<RefCell<App>>`) and `UiRef<dyn Trait>` weak handles: closure-only access `with(|app| ..) -> Option<R>`.
  `poll_frame` must never run while the root is borrowed (debug assert); a re-entrant borrow is caught too.
- `testing::Rt`: fake clock plus manual pool, deterministic.

Tests: unit tests per module, `tests/runtime.rs` (stress), `src/flows` (ShellHost ask, save queue + autosave, auto proxy;
test doubles of the Swift flows, test-only).
