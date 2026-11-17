# sq-edit-api porting notes

Ported: TimeLimits, HTTP, ProjectState, EditDiff, EditOperation, EditTransaction, EditAPIRouter, the server (one `std::net`
server in `edit_apiserver_network` replaces both the Network.framework and the Winsock Swift servers; `edit_apiserver_winsock`
is a doc-only module). No dependency was added.

Deviations from the Swift code
- No async: Swift's `async` host and `Task.isCancelled` become a blocking `EditAPIHost` and an `&AtomicBool` cancel flag
  (`HostCommit::admit`, `EditAPIRouter::handle`). The connection thread sets the flag when the 15 s deadline passes.
- `EditAPIHost::run` returns `TransactionError` only; Swift's catch-all `422 String(describing:)` for other errors is gone.
- `EditTransaction::apply` takes an `IdSource` (razor, move, extract, lift and markers create ids). `applyOffActor` is
  `apply_off_actor`: it runs `apply` on a copy on a scoped worker thread and checks the cancel flag afterwards.
- `EditAPIConfig::make_token` takes the random byte source; the app passes the OS CSPRNG (none exists in the workspace yet).
- Error text: a decode error carries serde's wording (and a line/column), not Foundation's coding-path wording. Edit errors keep
  Swift's case-name text (`clipNotFound`).
- `EditOperation` JSON is read through a `serde_json::Map` so the per-op key check (unknown key = error) matches Swift.
- Status codes are `u16`, counts in the diff `i64`, `operationIndex` `usize`.
- Discovery (`EditAPIDiscovery.swift`, file write with 0600) is Apple/Foundation code outside this group and not ported;
  `ConnectionLimiter` lived in that file and is ported next to the server.

Waiting on
- ProjectFile round trip test (`idsSurviveProjectFileRoundTrip`) needs the project file crate; the performance tests of
  `ReadOnlyCostTests` and `TimingSupport` are timing checks and not ported (the main-actor ticker test has no Rust meaning).
- Discovery file writer and an OS random source from a platform crate.
