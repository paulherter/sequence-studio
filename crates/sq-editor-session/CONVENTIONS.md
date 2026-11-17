# sq-editor-session: type mapping conventions

Binding for every ES worker, so ten groups produce the same signatures. PORTING.md applies first; this file fixes
what it leaves open for the session. Design: docs/rust/session-ui-design.md section 2. Examples: the members already
ported in each `esNN_*.rs`.

## Files and tracking
- Your group owns `src/esNN_<name>.rs`. Large groups split it into `src/esNN_<name>/<swift_file>.rs` submodules,
  declared (`mod x; pub use x::*;`) in your own `esNN_*.rs`. Never edit `lib.rs`.
- K2 files (`session.rs`, `change.rs`, `events.rs`, `services.rs`, `root.rs`, `pending.rs`) are shared: edit only a
  `// shortcut:` spot that names your group (for example ES4/ES5 in `perform_steps`, ES1 in `project_did_change`).
  Anything else there (a new `SessionEvent` variant, a new trait method) goes to the maintainer.
- Every ported item carries `// Swift: <file>:<line>` with the line exactly as `docs/rust/session-members.tsv` (and
  `--list`) gives it: it can be one above the Swift declaration (a blank line before it). `scripts/session-tasks.py`
  counts these; items the tsv does not list (types, internal members) may carry the plain file line. Step 1: `scripts/session-tasks.py --list ESn`,
  write every signature with `pending!("ESn")` as body, `cargo check` green, commit. Step 2: implement and test file by
  file, removing the markers. Rerun `scripts/session-tasks.py` and commit TASKS.md with your work.
- Types the session's stored fields need are already declared in their owner's module (`SequenceTabs` ES1,
  `LineKeyRef` ES2, `ColorMattePreview` ES4, `GraphicLayerSelection` ES5, `MediaDiskTracker` ES8...): fill them, keep
  the names. A type of another group you need before it exists: ask, do not declare a second one.
- Calling another group's member is fine while it is `pending!`: it compiles and panics only when run.

## Members
| Swift | Rust |
|---|---|
| `func f(_ a: A, label b: B)` | `pub fn f(&mut self, a: A, b: B)`; `&self` when it does not mutate |
| overloads differing by label | suffix with the label: `open_sequence_tab` / `open_sequence_tab_variant` |
| computed `var x: T` | `pub fn x(&self) -> T`; `is_`/`can_` names stay as Swift spells them (`can_paste_attributes`) |
| stored `public private(set) var x` | `pub(crate)` field + getter `pub fn x(&self)` (Copy: by value; else `&T`, `Option<&T>`, `&[T]`) |
| stored `public var x` | field + getter + `pub fn set_x(&mut self, v)`; a `didSet` becomes the setter's body |
| `static let x = <const>` | `pub const X: T` (assoc const) when const-constructible, else `pub fn x() -> T` |
| `static func` | associated fn; caseless `enum X` namespace -> `pub enum X {}` with associated fns |
| `@discardableResult -> Bool` | `-> bool` (no `#[must_use]`) |
| `init(...)` | `pub fn new(...)`; Swift default arguments -> a `*Deps`/options struct or a second constructor |
| `deinit` | `Drop` only if it releases something outside Rust ownership; cancel stored tasks there |

Parameters: non-Copy inputs that are only read are borrowed (`&T`, `&[T]`, `&str`, `&BTreeSet<Id>`, `&Path`); taken by
value when the body stores or moves them. Results are owned unless they return existing session state (`Option<&Clip>`).

## Types
| Swift | Rust |
|---|---|
| `Int` / counts, indices, undo depth | `i64` / `usize` (undo depth, slots into Vecs) |
| `Double`, `CGFloat`, `TimeInterval` | `f64` (TimeInterval in seconds) |
| `Float`, `SIMD3<Float>` | `f32`, `[f32; 3]` |
| `CGPoint`, `CGSize`, `CGRect` | `sq_uikit::keyframe_graph_geometry::{Point, Size, Rect}` (same field names) |
| `Date` | `sq_core_time::Timestamp`; now = the session's `clock` (`(self.clock)()`), never the system clock |
| Swift `Duration`, `ContinuousClock.Instant` | `std::time::Duration` (instant = `sq_runtime::Clock::now()`) |
| `URL` | `PathBuf` stored, `&Path` parameter; string paths stay `String` as in Swift |
| `UUID`, `Clip.ID`, `Timeline.ID`, `MediaRef.ID`... | `sq_core_time::Id` |
| `Set<T>`, `[K: V]` | `BTreeSet<T>`, `BTreeMap<K, V>` (`HashMap` only if never iterated) |
| tuple crossing a function boundary | named struct next to its first user (`CutPoint`, `PlayheadStep`, `DetectedColor`) |
| `any Error` that only reaches the status line | `String` message |
| own `enum XError: Error` | enum with the same cases, `Display` with the English text (the UI localizes), `std::error::Error` |
| `throws` | `Result<T, E>`; `rethrows` edit closures -> `try_perform` |
| `UserDefaults` | `&dyn sq_library::library_folder_store::SettingsStore` (read) / `&mut dyn` (write); keys unchanged |
| `NotificationCenter` observer | an inbox message (`sq_runtime::channel`) the app routes to the session |
| `.shared` singletons (LookStore, CaptionLookLibrary, EffectDefaultsLibrary) | owned by the app; passed as a parameter, never stored in the session |
| `#if os(macOS)` code | not ported (the portable `#else` path is the oracle); Mac-only stored fields are left out |

## State, hooks, async
- `@Observable` models (`MarkersPanelModel`, `ExportDialogModel`, `ProjectPanelModel`...): struct with
  `pub(crate) version: u64`, bumped by every mutating method that changes what views read; `pub fn version()`.
  The session itself uses `notify(Change::X)` (bumps `versions`), never its own counters.
- `var onX: ((A) -> Void)?` -> variant `X(A)` of the owner's event enum (`SessionEvent`, `MarkersPanelEvent`,
  `AnalysisFlowsEvent`), pushed in Swift's call order, drained by the app with `take_events()`. Several arguments ->
  struct variant with the Swift labels. `onChange` of a model -> its `version`.
- A hook that returns a value: synchronous pure policy -> `Option<Box<dyn FnMut(..) -> T>>` field
  (`confirm_format_change`); a dialog -> a method of the group's asks trait returning `sq_runtime::ModalAsk<T>`
  (`FormatAsks::ask_format_change`).
- Classes that hold the session (`AnalysisFlows`, `ProjectPanelModel`, `ExportDialogModel+Session`): no stored
  reference; methods take `session: &mut EditorSession` (or `&EditorSession`) as the first parameter after `self`.
- `async func`: `pub async fn f<R: SessionRoot + XAsks + ?Sized>(h: UiRef<R>, ..)` as an associated fn; every
  synchronous stretch inside `h.with(|r| ..)`, nothing borrowed across `.await`, `None` = root gone = return.
- `@Sendable` async closures doing I/O (probes, detectors, prepare) -> `Arc<dyn Fn(..) -> T + Send + Sync>`, run
  blocking on `sq_runtime::WorkerPool`; the result comes back as an inbox message or through the task.
- Stored `Task` -> `Option<sq_runtime::JoinHandle<()>>` (drop or `cancel()` = Swift `cancel()`); `Task.sleep` ->
  `sq_runtime::sleep`.
- Weak references to engines -> `ProgramEngine::is_alive`. Weak references to anything else -> an id looked up when used.
- Engine callbacks: `onPositionChange` is `ProgramEngine::take_position_change`; other service hooks become inbox messages.
- Undo: every project change goes through `perform` / `try_perform` (one step); changes outside the project register a
  `register_side_step` whose closures capture `Arc` stores only. Ids for new objects come from `self.ids`
  (`IdSource`), never `Uuid::new_v4()`.
