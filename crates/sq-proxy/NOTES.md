# sq-proxy notes

Ported: all portable Swift files (Model, ProxyCache, ProxyOrdering, ProxyPolicy, ProxyProvider, ProxyQueue, ProxyTranscoding, AutoProxy).
Not ported (Apple-only or platform code): `AVSourceSeekProber`, `ProxyTranscoder` (AVFoundation), `WebMProxyTranscoder` (needs the WebM/FFmpeg crates),
and the Swift tests that run them (Alpha, Deinterlace, PixelAspect, WebM, Integration).

## ProxyQueue (PORTING section 9)
- The actor is a plain struct with explicit state: no threads, no executor. `enqueue`, `set_held(false)`, `start`, `complete` mark jobs
  running and put them in an outbox; the driver calls `take_started()`, runs each `StartedJob::run(transcoder, progress, now)` on a
  worker thread and reports with `set_progress` / `complete`. `run_until_idle` is the single-threaded driver used by the tests.
- `ProxyTranscoding::transcode` is blocking; cancellation is a `CancelToken` (Swift `Task.cancel` + `cancelRequested`) and a
  `Cancelled` error variant. `cancel` on a running job only sets the token; the state changes at `complete`.
- `AsyncStream` listeners are `mpsc` channels (unbounded: Swift buffered the newest 64/256 updates). A dropped receiver is removed on the next send.
- `TaskPriority` mapping of `ProxyJobPriority` is dropped: the driver picks thread priority from `priority`.
- `ProxyAutoGenerator::source_imported` takes the queue as an argument instead of owning a shared actor reference.
- Ids and clocks are passed in (`IdSource`, `now: Timestamp`) everywhere Swift called `UUID()` / `Date()`.

## Deviations and shortcuts
- `FileReplace.replace` (sq-core-project, not ported yet): `std::fs::rename` replaces the target atomically on macOS, Linux and Windows
  (MoveFileEx with REPLACE_EXISTING); there is no retry loop for sharing violations like the Swift Windows branch.
- `ProxyProvider::has_fields` returns false (Swift does the same without AVFoundation).
- `ProxyDiskGuard::volume` and `MachineProfile.current` (process memory, volume sizes) need the platform layer: `volume` reports unknown;
  `MachineProfile::current_with` takes the numbers from the caller.
- Index/settings JSON: keys sorted (via `serde_json::Value`), dates ISO 8601 whole seconds; written to `<name>.tmp` then renamed.
- Swift's tests with 2000-iteration async races are ported with threads and smaller counts.

## Waiting on
- sq-core-project `file_replace` once ported (then `ProxyCache::commit` can call it for the Windows retry).
- An FFmpeg-based `SourceSeekProbing` and `ProxyTranscoding` (sq-media) and a field-order probe for `has_fields`.
