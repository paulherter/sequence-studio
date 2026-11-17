# PORTING.md: Swift to Rust mapping rules

Every porter reads this first. Agent rules: `docs/rust/AGENT-RULES.md`.
Oracle layout: `docs/rust/ORACLE.md`. Crate order: `docs/rust/crate-order.tsv`. Pilot lessons: `crates/sq-prproj-reader/PILOT-NOTES.md`.
Rule 0: port, do not redesign. Same behavior, same names, same operation order. Idiomatic cleanup comes after parity, as separate commits.

## 1. Naming and layout
- Swift package `SQFoo` -> crate `sq-foo` (`SQMediaFFmpeg` -> `sq-media-ffmpeg`); lib name `sq_foo`. Splits are listed in `crate-order.tsv`.
- Swift file `Sources/SQFoo/BarBaz.swift` -> module `src/bar_baz.rs` (snake_case file, same order of items as the Swift file). Folders map to folders.
- Types, enum cases and protocols keep their Swift names in UpperCamelCase (`ClipSpeed`, `.fadeIn` -> `FadeIn`). Functions and fields -> snake_case
  (`startTime` -> `start_time`). Argument labels vanish; if two overloads differ only by label, suffix the Rust name (`insert_at`, `insert_after`).
- Each Rust item gets a one-line `// Swift: BarBaz.swift` comment on the module (not on every item). Doc comments are copied from the Swift ones.
- `public` -> `pub`, `internal` -> `pub(crate)`, `private`/`fileprivate` -> private. Re-export the public API in `lib.rs` exactly as Swift exposes it.
- Dependencies in `Cargo.toml`: `workspace = true` only. A new external dependency needs an entry in the root `[workspace.dependencies]` and a license check
  (GPL-3.0-or-later compatible; `deny.toml`). Never add a dependency to avoid porting 100 lines of our own code.

## 2. Mechanical first
- Translate line by line. Keep local variable names, helper functions, early returns, loop shapes and comments. Do not merge, split or "improve" functions.
- Do not fix Swift bugs while porting. Record them in the crate's `PORTING-NOTES.md` ("Swift quirks") and keep the behavior; the oracle decides if it is a bug.
- Do not drop Swift code because it looks dead. Mac-only code (imports AVFoundation, Metal, AppKit, Vision) is not ported; say so in the notes.
- Port the Swift tests of pure logic together with the code (plan 6b). Test names stay the same (snake_case of the Swift test name).
- When a construct has no direct mapping, stop at section 14 ("when to escalate"), do not invent an architecture.

## 3. Errors
- Swift `throws` -> `Result<T, CrateError>`. One `enum CrateError` per crate in `src/error.rs`, `#[derive(Debug, Clone, PartialEq)]`, implementing `Display` and
  `std::error::Error` by hand (no `thiserror` unless the root `[workspace.dependencies]` has it). One variant per Swift error case, same names and payloads.
- `try?` -> `.ok()`; `try!` and `fatalError` -> a `Result` error unless the Swift one is a genuine invariant check: then `debug_assert!` plus an error return.
- `precondition`/`assert` -> `debug_assert!` and, where Swift traps in release, an explicit `Err` or `panic!` with the same message (panics are allowed only there).
- No `unwrap()`, `expect()`, `todo!()`, `unimplemented!()`, `dbg!` in non-test code (workspace lints deny them). Array indexing is allowed where Swift also
  traps on a bad index and the index is proven in range by a nearby check; otherwise use `.get(i)` and return the error.
- `Optional` chaining `a?.b?.c` -> `a.as_ref().and_then(|a| a.b.as_ref()).and_then(...)` or a helper; `if let`/`guard let` -> `let Some(x) = .. else { .. }`.
- Cancellation (`CancellationError`, `Task.isCancelled`) -> an explicit `Cancelled` variant and a `CancelToken` argument, see section 9.

## 4. Numerics (the main source of drift)
- Rational time stays integer: `Time { value: i64, timescale: i64 }` with `i128` intermediates (Swift uses Int64/Int64 and Int128 for products, clamping and a convergent approximation; `-min` maps to `max`). NEVER `f64` for time. Port `init(reducing:)` verbatim and do not use panicking `checked_*` inside Time. The older line about `timescale: i32` was wrong.
  operation by operation (gcd reduction at the same points; same rounding of `.rounded()` variants, see below).
- Swift `Int` is 64-bit: use `i64`/`isize` as the Swift type is used for (`Int` -> `i64`, array counts and indices -> `usize` with an `as i64` at the boundary).
  `UInt8/16/32/64`, `Int8/16/32/64` -> same Rust widths. Never use `as` to narrow silently; use `try_from` and handle the error, or a documented `as` after a clamp.
- Overflow: Swift traps on `+ - *` overflow in release and debug; Rust release wraps. Where the Swift code can overflow and trap, use `checked_*` and
  return the error or panic with the same message. Where Swift uses `&+ &- &*` use `wrapping_*`. Where Swift clamps (`min`/`max`), use `clamp` or `saturating_*`.
  Division and `%` by zero trap in both; keep the guard.
- Float: keep the exact operation order and types (`Float` -> `f32`, `Double`/`CGFloat` -> `f64`). Do not use `mul_add`, do not reorder sums, do not turn
  `x / y` into `x * (1/y)`. Rust never fuses multiply-add by itself; check `-C target-cpu` is not set to something that does.
- Rounding: `.rounded()` (half away from zero) -> `f64::round`; `.rounded(.toNearestOrEven)` -> `round_ties_even`; `.rounded(.down)` -> `floor`; `Int(x)`
  truncates toward zero and traps on NaN/inf/out of range -> `x as i64` saturates silently, so check `x.is_finite()` and the range first.
- `Double.truncatingRemainder` -> `%`; `fmod`/`pow`/`sin`/`exp` -> the `f64` methods (libm differences are expected: the oracle compares floats with the
  tolerance stated in the task card, never bitwise unless the card says so).
- Integer division of negatives: Swift `/` truncates like Rust. Swift `%` has the sign of the dividend like Rust `%`; `rem_euclid` only if Swift code does the same dance.
- Hashing for tests/goldens is FNV-1a 64 over bytes (pilot convention), not `std::hash`.

## 5. Determinism
- Swift `sort`/`sorted` is NOT guaranteed stable by the language but is in practice (introsort replaced by timsort); treat it as stable. Use `sort_by`/`sort_by_key`
  (stable) and never `sort_unstable*` unless the Swift comment says order of equal elements is irrelevant. Comparators must be total (`f64::total_cmp`) or you
  must reproduce Swift's behavior with NaN explicitly.
- `Dictionary` and `Set` iteration order in Swift is random per process: Swift code that depends on it is already nondeterministic. Use `BTreeMap`/`BTreeSet`
  wherever the Swift code sorts keys before iterating or the output order matters; `HashMap` otherwise (with `std` hasher). Never iterate a `HashMap` into output.
- Strings: Swift `String` is a sequence of grapheme clusters, `==` and hashing use Unicode canonical equivalence (the pilot's e + U+0301 == U+00E9 finding),
  `count` counts graphemes. Rust `String` is UTF-8 bytes with byte equality. Rules: (a) default to byte equality and list the difference in the crate notes;
  (b) where the Swift code compares user-visible names (clip names, file names, tags), compare after NFC normalization using a small table-free helper in
  `sq_core_time::text` once that exists; (c) `count` -> `chars().count()` only when the Swift code counts Characters of ASCII-only data, otherwise grapheme-aware
  helper in the same module; (d) `utf8.count` -> `len()`; `unicodeScalars` -> `chars()`.
- Locale: all case conversion and number formatting must be locale independent (`to_ascii_lowercase`, `to_lowercase` is Unicode but not locale-aware, which equals
  Swift's `lowercased()` without locale). `String(format:)` -> `format!` with explicit precision (`{:.3}`), `%g` has no equivalent: write the helper and test it.
  `localizedCompare`, `localizedStandardCompare` (Finder-style sort): port as a named helper, document the ICU difference.
- `trimmingCharacters(in: .whitespacesAndNewlines)`: Foundation's set is not `char::is_whitespace` (it trims U+200B, not U+FEFF/U+180E). Use the table in
  `sq-prproj-reader::fastxml::is_ws` as the reference and move it to `sq_core_time::text` when a second crate needs it.
- Time and randomness: no `SystemTime::now()` or random in logic paths; take a clock/RNG argument as the Swift code does. UUID: `uuid` crate, lowercase hyphenated
  where Swift's `uuidString` is uppercase: keep Swift's uppercase (`to_string().to_uppercase()`).
- File paths: `URL`/`NSString` path APIs -> `std::path::Path` with `/` normalization in stored data (project files always store `/`).

## 6. Swift types and constructs
| Swift | Rust |
|---|---|
| `struct` (value type) | `struct` with `#[derive(Debug, Clone, PartialEq)]`; add `Copy` only if all fields are `Copy` and Swift copies it freely; `Eq`/`Hash`/`Default` only when Swift conforms |
| `enum` without payload | `enum` + `Clone, Copy, Debug, PartialEq, Eq, Hash`; raw values -> `fn raw_value(self)` and `fn from_raw(..) -> Option<Self>` |
| `enum` with associated values | `enum` with the same cases (UpperCamel) and tuple/struct variants; indirect cases -> `Box` |
| `class` (reference type, no shared mutation) | `struct` owned by one place; pass `&`/`&mut`. See section 10 |
| `class` shared by several owners | `Rc<RefCell<T>>` single thread, `Arc<Mutex<T>>` across threads, only if the ownership table (section 11) says so; otherwise indices into an arena |
| `protocol` used as constraint | `trait`; associated types -> associated types; `Self` requirements -> trait with `Self: Sized` |
| `protocol` used as type (`any P`) | `Box<dyn P>` / `&dyn P`; if the set of conformers is closed, an `enum` is preferred and recorded in the notes |
| `extension Foo` | `impl Foo` in the same module as the Swift file; protocol extensions with default methods -> trait default methods; constrained extensions -> `impl<T: Bound> Trait for T` or a free fn |
| generics `<T: P>` | `<T: P>`; `where` clauses stay as `where`; `some P` -> `impl P`; opaque `any` -> `Box<dyn>` |
| `Optional<T>` | `Option<T>`; `x!` -> a `?`/`ok_or` (Swift traps: see section 3); `??` -> `unwrap_or`/`unwrap_or_else` |
| `Array<T>` | `Vec<T>`; slices `ArraySlice` -> `&[T]` (indices rebase to 0: re-check every index); `array[a..<b]` -> `&v[a..b]` |
| tuple `(a: Int, b: Int)` | a small named `struct` if it crosses a function boundary; plain tuple for locals |
| `typealias` | `type` alias |
| `lazy var`, computed property | method `fn name(&self)`; `lazy` -> `OnceCell` or an `Option` filled by `&mut self` method |
| `didSet`/`willSet` | explicit setter method that does the work; list them in the notes |
| `inout` | `&mut T` |
| `defer` | `Drop` guard or an explicit block at each exit; keep the order (LIFO) |
| `switch` with `where`/ranges | `match` with guards / range patterns; `fallthrough` -> duplicate arm body via helper fn |
| `Result<T, E>` | `Result<T, E>` |
| `Codable` | `serde::{Serialize, Deserialize}`: see section 8 |
| `@propertyWrapper` | plain field plus the setter/getter logic written out; or a small generic struct with methods if used in 3+ places |
| `@resultBuilder` | builder `Vec` pushes at the call site; DSL macros only if the builder is used in 10+ places (decide in the design note) |
| `KeyPath` | closure `fn(&T) -> &U`, or an enum of fields when keypaths are stored/compared |
| `CustomStringConvertible` | `impl Display` |
| `Equatable/Hashable/Comparable` by hand | `impl PartialEq/Hash/PartialOrd` by hand with the same fields in the same order |
| `Data` | `Vec<u8>` / `&[u8]`; `[UInt8]` same |
| `Date` | `i64` seconds or a `Timestamp` newtype; never `SystemTime` in model data |
| `CGFloat/CGPoint/CGSize/CGRect` | `f64` and our own `Point/Size/Rect` in `sq-time`/`sq-core` geometry module with the same field names |
| `UserDefaults`, `NotificationCenter`, `NSLock`, `DispatchQueue` | injected trait objects (settings store, event sink), `std::sync::Mutex`, channels; one trait per use, decided in the design note |

## 7. Closures and callbacks
- Non-escaping closure parameter -> `impl FnMut(..)`/`impl Fn(..)` generic. Escaping closure stored in a struct -> `Box<dyn FnMut(..) + 'a>`; add `+ Send` only if the value crosses threads.
- `[weak self]` capture -> do not capture self: pass an id/handle and look the object up when the callback fires; a destroyed target is a no-op (same as weak nil).
- `[unowned self]` -> same, but a lookup miss is a bug: `debug_assert!`.
- Closure-returning-closure and curried helpers: write the named fn. Trailing-closure DSL calls become normal calls.

## 8. Codable -> serde
- Field names in JSON are exactly the Swift property names (Swift does not rename). Use `#[serde(rename_all = "camelCase")]` on the struct and an explicit
  `#[serde(rename = ..)]` on every field it would get wrong (acronyms: `audioGainDB`, `duckKeyIDs`, `volumeDB`) and on every custom `CodingKeys` raw string
  (`*Store` fields: `variantStore` -> `"variantOverrides"`). Enums with String raw values: `rename_all = "camelCase"` on the cases.
- Swift `UUID` -> `sq_core_time::Id` (uppercase text), `Data` -> `Vec<u8>` with `#[serde(with = "sq_core_time::base64")]`, `Date` -> `sq_core_time::Timestamp`
  (`with = "sq_core_time::timestamp::iso8601"` where the encoder sets `.iso8601`). Swift `try?` on a single key (lenient decode) has no plain serde form: see the
  model task plan.
- Order of keys: Swift `JSONEncoder` order is not specified, our writers set `.sortedKeys` where files are hashed or diffed: then write keys sorted. Otherwise declaration
  order. `serde_json` with `preserve_order` is NOT enabled: use structs (declaration order) or `BTreeMap`.
- Optionals: Swift omits `nil` keys (`encodeIfPresent`) -> `#[serde(skip_serializing_if = "Option::is_none", default)]`. Decoding a missing key into a non-optional with a default in
  `init(from:)` -> `#[serde(default = "fn")]` using the same default value.
- Enums with associated values: Swift's synthesized form is `{"caseName":{"_0":..}}` or `{"caseName":{"label":..}}`; replicate with `#[serde(rename = "caseName")]` externally tagged variants and `_0`
  fields via a small wrapper struct. Check against a golden before generalizing. Enums with raw values -> string/int via `rename` per variant.
- Numbers: the text form of a `Double` differs between Foundation's `JSONEncoder` and `serde_json` (e.g. `1` vs `1.0`, exponent forms). Do not assume: check a golden, then write one float
  formatting helper in `sq-project-file` that all writers use. NaN/inf are encode errors in Swift too.
- Dates, `Data` (base64), `URL` (string) use the strategies the Swift encoder sets; read them from the Swift file, do not assume the defaults.
- Compatibility gate is content equality of the parsed model (plan 6b); bytes only where hashed or signed. Unknown keys are ignored on read, like Swift.
- Project file version: a Rust change never bumps `ProjectFile.version`; flag it to the human.

## 9. Concurrency and async
- No tokio. UI-side `async`/`await` runs on a small single-threaded executor polled once per frame (plan 2); `async fn` in Rust with futures that only the executor drives.
  Until `sq-executor` exists (gate G5) port async code as `async fn` and do not call `.await` in unit tests; use the test driver `block_on_local` once it lands.
- `Task { }` / `Task.detached` -> `executor.spawn(fut)` returning a `JoinHandle` that cancels on drop only if Swift's `Task` was stored and cancelled; `Task.sleep` -> `executor.sleep(duration)`.
- `TaskGroup` -> `join_all`-style helper on the executor; results in input order unless Swift collects in completion order.
- `@MainActor` -> the code runs on the UI thread: plain `&mut` access, no locks. Calls from other threads go through a message to the UI thread queue.
- `actor` -> owned struct with a command channel (`std::sync::mpsc`/crossbeam-free: std only unless the root deps list one); the actor's methods become messages; reentrancy points (`await` inside an actor method) are listed in the design note.
- `Sendable` is implicit: just keep types `Send` where they cross threads; no `unsafe impl Send`.
- `@Observable`/`ObservableObject`/`@Published` -> the model struct has a `version: u64` bumped by setters plus an explicit change event list; views poll `version`. No reactive framework.
- `Combine`/`AsyncStream` -> channel + `Iterator`/poll loop. `DispatchQueue.main.async` -> `ui_queue.post(fn)`. `DispatchSemaphore`/`NSLock` -> `Mutex` + `Condvar`.
- Real-time threads (audio, decode, playback) are dedicated `std::thread`s, no allocation or locks in the audio callback (bounded SPSC ring buffer written by hand).
- Modal `ask(...)` flows: `async fn` that completes when the dialog's state changes, driven by the frame loop; tests drain it step by step.

## 10. Ownership and lifetimes
- Default: data is owned (`String`, `Vec`, `Box`), functions take `&T` or `T` by value for Copy types, results are owned. No lifetime parameters on public types unless the Swift code
  is a view over a buffer (a parser over bytes): then one lifetime, named `'a`.
- Parent/child graphs (timeline -> track -> clip, view trees): ids + arena (`Vec<T>` indexed by `Id(u32)`), never `Rc<RefCell>` cycles, never `Weak` as a parent pointer.
- Undo = snapshots in Swift (value-type copies). Rust: `Clone` of the model; where cloning the whole model per edit is too slow, the crate design note picks persistent
  structures (`im`) or command deltas. Do not decide this while porting an edit function.
- `Rc<RefCell<..>>`/`Arc<Mutex<..>>` need a row in the ownership table (section 11) with the reason; clippy `clone_on_ref_ptr` is denied: write `Rc::clone(&x)`.
- Borrow-checker fight that needs more than two attempts: restructure with indices or split the struct; do not add `unsafe`, `RefCell` or `clone()` to silence it. If it still fights, escalate (section 14).

## 11. Ownership table (one per crate, in `crates/<crate>/OWNERSHIP.md`, written before the first batch for crates with shared state)
| field | owner | lifetime | shared-by |
|---|---|---|---|
| `Timeline.tracks` | `Timeline` | project open | read by render thread via snapshot clone |
| `Player.audio_clock` | `Player` | session | audio thread (atomic u64) |
Columns: field (type and name), owner (single owning struct), lifetime (until when it lives and who frees it), shared-by (readers/writers and the mechanism: `&`, snapshot, channel, atomic, mutex).
Empty "shared-by" means single user. A row without a mechanism is a design bug: escalate.

## 12. Unsafe policy
- `unsafe_code = "forbid"` in every crate except the allow-list: `sq-gpu-interop`, `sq-video-hw`, `sq-platform-*` (`cargo xtask gate` counts). Those crates set `[lints.rust] unsafe_code = "allow"`
  themselves and justify it in their `OWNERSHIP.md`.
- Each `unsafe` block: one-line `// SAFETY:` comment naming the invariant and who upholds it; smallest possible block; wrapped in a safe function; unit test that exercises the wrapper.
- Never `unsafe` for speed in portable crates. `transmute`, `static mut`, `unsafe impl Send/Sync` need an Opus design note.
- C libraries (ThorVG, RNNoise, LZFSE, FFmpeg wrapper) are built with `cc` in the crate that owns them; the FFI declarations are the only unsafe in that crate.

## 13. Tests, commits
- Test policy is plan 6b: port pure-logic tests of L1-L3; for session/UI/shell use goldens and scenario scripts. Do not translate tests of Mac-only backends.
- Tests live next to the code (`#[cfg(test)] mod tests`) for unit tests, `tests/` for integration/oracle tests. Test helpers that read goldens use paths relative to `CARGO_MANIFEST_DIR`.
- Property tests only where the plan says (undo/redo identity, round trips). Fuzz targets only for parsers.
- Done = `cargo xtask check <crate>` green (fmt, clippy -D warnings, tests), crate notes written, then `cargo xtask gate <crate>` on the PC.
- Commits: small (one module or one batch of 1-3k lines), English, plain imperative ("Port ClipSpeed and Rational math"), no tool or AI mentions. `git add <explicit paths>`, only paths under your crate and
  `docs/rust/cards/`. Never `git add -A`, `git stash`, `git reset`, `rebase`, force-push, `rm -rf`. Never touch the status files, root `Cargo.toml`, another crate.
- Comments: explain why, not what; no internal notes, no task ids in code. A deliberate shortcut gets `// shortcut: <limit>, <when to upgrade>`.

## 14. When to stop and escalate to Opus
Stop, commit what is green, write the question in `crates/<crate>/PORTING-NOTES.md` under "Escalations", and end the session when:
- a borrow-checker problem survives two restructurings, or a design needs `Rc<RefCell>`, `Arc<Mutex>`, `unsafe` or a lifetime on a public type that the ownership table does not list;
- a Swift construct has no row in section 6 (actors with reentrancy, `@dynamicMemberLookup`, runtime reflection `Mirror`, `NSObject` KVO, `ObjectIdentifier` tricks, `unowned` cycles);
- the oracle shows a diff you cannot explain after one fix attempt (float drift beyond tolerance, ordering, string equality), or the Swift code behaves differently on Mac and Windows;
- you need to change the public API of a crate another crate already uses, or add a dependency;
- the task touches threads, GPU/video interop, audio real-time paths, or FFI;
- the same compile error or the same test failure came back three times (the driver also stops at three attempts).
Escalation is cheap; guessing an architecture that 20 other crates then copy is not.

## 15. SQCore-specific rules (from the core split design, docs/rust/sq-core-split.md)
- JSON and encoder side channels: Swift's `userInfo` flags and compact keyframes decide the file version. Use `EncodeContext` (a scope guard) exactly where Swift reads userInfo:
  the writer holds `EncodeContext::project_file()` and reads `.seen()` after encoding; a type's `Serialize` calls `EncodeContext::compact_keyframes()` / `EncodeContext::mark(Seen::..)`;
  a payload encoded inside a project file encode opens `EncodeContext::plain()`. The gate is decoded-content equality; compare `GeneratorRef.payload` by decoded content. `RenderCachePlan` hashes Clip JSON: change the render-cache salt (`sq-render-cache-1`) to a new value.
- IDs and clocks: logic takes `&mut dyn IdSource` and `now: Timestamp`; it never calls `Uuid::new_v4()` or the system clock itself. Dumps renumber new ids by first appearance; fixed `%012d`-style ids are rebuilt string-exact.
- Ordering: model dictionaries are `BTreeMap`; `Set` + `.sorted()` becomes `BTreeSet`; every sort is stable; every order-dependent loop over a Swift dictionary is listed in the crate notes and the golden decides.
- Strings: use `sq_core_time::text::{standard_compare, ci_contains, graphemes}` (all 640 rows of `oracle/sq-core-time/golden/text-tables.tsv` match; limits in the crate README) for `localizedStandardCompare`, `localizedCaseInsensitiveContains` and grapheme counts. `%.1f` with a Unicode minus is a known trap. `Float` stays `f32`; check `Int(x)` conversions for finite and in range.
- Swift `internal` read by other crates: `#[doc(hidden)] pub` (fields and helpers such as `KeyframeTrack::index_of`, `Interpolation::mirrored`). `public private(set)`: private field
  plus a getter (`Track::clips()`, `ClipSpeed::num()`), or a setter method where Swift has `didSet` (`EasingCurve::set_interpolation`).
- Swift keyword clashes get a suffix: `move` -> `move_key`; generic `KeyframeValue` operators are `lerp`/`plus`/`minus` on references (`f64`, `Vec2`, `EffectColor`, `MaskPath`).
- Types go down, logic goes up: types saved in `Project` live in `sq-core-model` with their serde code; Swift `extension Timeline` in file X becomes `pub trait <X>Ext` in its crate (re-exported in `prelude`); Swift `internal` fields used across crates become `#[doc(hidden)] pub`.
