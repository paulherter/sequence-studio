# Session and UI design (Waves 4-5)

What the Swift tree does today: each frame `AppController.frame` rebuilds the whole DrawList; input goes through a hand-ordered chain in `AppController.handle`; every panel has `layout`, `draw(&Canvas)`, `handle(InputEvent) -> Bool`. UI package counts: 16 `@Observable` classes, 321 `on*` hooks, 588 `[weak self]`, 698 `await`s, 238 `ask(`. The Mac `SharedUIController` and the Windows `AppController` are near copies; we port the Windows one (portable path = oracle).

## 1. Crates
```
sq-runtime (std only)          sq-gpu  sq-text  sq-uikit  core*
                                    \     |     /
                                     sq-draw  (DrawKit + SQDrawEditor, both renderers, accesskit types)
sq-editor-session (core*, media, playback, export, library, proxy, transcribe, analysis, audiofx, runtime; no sq-draw)
sq-timeline-ui (session)
sq-draw-timeline (draw, timeline-ui)       sq-draw-monitor (draw, session, playback)
sq-inspector-ui (draw, session, timeline-ui)  sq-draw-shell (draw, session, export, library, premiere-import)
sq-draw-library (draw, inspector-ui, library)
sq-app-shell (everything above: App root, hosts, the portable Win* glue, headless harness; no winit)
sq-platform-mac / -win (unsafe allow-list: muda menu, swipe/momentum, drop position, file clipboard, chrome subclass, card watcher)
sequence-studio (binary: winit handler, surfaces, event translation, rfd/arboard, accesskit_winit, crash handler, test modes)
```
Only the binary and the two platform crates touch winit or the OS.

## 2. Session state model
- Root: `UiRoot<App>` = `Rc<RefCell<App>>`. `App` (port of `AppController`) owns `EditorSession`, `ShellHost`, all hosts and panels, `UiCx`. The root is borrowed exactly once per input event, frame, inbox drain and task poll step; `poll_frame` runs outside that borrow (debug assert).
- No stored session references: `self.session` becomes a `&mut EditorSession` parameter.
- Hooks become events: `var onX: ((A)->Void)?` becomes variant `X(A)` of the owner's `*Event` enum pushed to `out: &mut Vec<_>`; the assigning code becomes a match arm in `App::dispatch` (runs after the handler returns, in Swift's chaining order). Hooks returning a value become fields App fills in before the call, or an async `ask`.
- Views pull: `App::frame` syncs panels from `&session` every frame. Changes: Swift `Change` OptionSet as bitflags + `versions: [u64; 9]` bumped in `notify`; `App::dispatch` drains pending bits (replaces `onChange`). The 16 `@Observable` models get a `version: u64` bumped by setters; caches key on versions (LaneCache, thumbnails, `LibraryDrawPanel`'s observation tracking).
- Redraw only on input, version change, inbox message, due timer, while playing, or `ui.request_animation()`; otherwise `WaitUntil(next_deadline)`.
- Undo: existing `sq_core_edit::History<Project>`: `perform(name, key, |p| ..)` commits, then `project_did_change` calls `engine.set_timeline` and `notify(PROJECT)`. Side steps are `Box<dyn FnMut()>` closures capturing `Arc` stores.
- Async methods: `async fn f(h: UiRef<dyn ShellRoot>, ..)`; each synchronous stretch runs in `h.with(|r| ..)` (closure-only access, no borrow across `.await`; `None` if the root is gone = nil weak self). Each crate declares a small root trait (e.g. `ShellRoot::parts() -> ShellParts` of disjoint borrows) that App implements.
- `ask()`: inside `with`, `shell.present(d)` returns a `ModalAsk<Response>`; the task awaits it outside the borrow; a click on a dialog button calls `answer`.
- Background services post typed messages through `sq_runtime::channel` into `App.inbox` (kinds: Proxy, Transcribe, Analysis, Library, ExportQueue, MediaPrepared, DiskChanged), drained at frame start; Swift `for await` streams stay as `rx.next().await` in tasks; playback position is read once per frame from the playback mailbox.
- Edit API: `ApiBridge: EditAPIHost` sends `ApiCall{req, reply}` to the inbox and wakes the loop via `EventLoopProxy`; the server thread waits for the reply (checking cancel). App runs it through `session.perform` = one undo step; while a dialog is open it answers "busy" (as `WinSessionAPIHost`).

## 3. Draw and widget boundary (`sq-draw`)
- Exports: `DrawQuad` (`repr(C)`, 80 bytes, six kinds), `DrawList` (clip stack, canvas extent, image/video slots), `Canvas` (concrete builder, not a trait), `DrawTheme`, `GlyphAtlas`, `TextMeasure` (moved here from SQDrawShell), `InputEvent`/`InputKey`/`InputModifiers` 1:1, `UiCx` (replaces singletons HostHover, HostRequests, HostTypedText, HostKeyRepeat, HostScroll, HostDragPreview, TextClipboard), the widgets, `trait Panel { layout; draw(&mut self, &mut Canvas, &DrawTheme); handle(&mut self, &InputEvent, &mut UiCx) -> bool; a11y(&self, &mut A11y) {} }`, `WgpuRenderer` (G3 spike, DrawQuads Slang pipeline), `SoftwareRenderer` (oracle).
- Text: sq-text rasterizes glyphs into the R8 atlas on the UI thread; dirty rects uploaded per frame; one atlas per display scale (floating windows on monitors with different DPI). Icons: `SQIcon` path data through the `IconOutline` sink, fills/strokes cached per icon and size, drawn as triangle and segment quads.
- Hit-testing: each panel tests its own geometry; routing order is a 1:1 port of `AppController.handle`; `is_dragging` keeps the pointer captured. Focus: `ShellHost.focus` + `owns_keyboard`; no generic focus tree.
- IME: winit `Preedit` -> `requests.composition`; `Commit` -> `keyDown(.character)` with `typed_text`; after each frame `requests.caret` drives `set_ime_allowed` / `set_ime_cursor_area`. `MacKeys`/`ShellTextInput` key tables ported 1:1.
- Accessibility (new; the Swift draw UI has no tree today): panels push `accesskit::Node`s only while assistive tech is active; node ids = `hash(PanelId, role, key)`; actions route back by id; labels from `SQAccessibilityText`.

## 4. Skeleton, then parallel tasks
Skeleton (Opus, serial, ~5k lines):
- K0: sq-runtime from the G5 spike + `UiRoot`, `UiRef`, inbox.
- K1: DrawKit foundation full ports: DrawList, Canvas (+Dash, +Icon), Input, DrawTheme, GlyphAtlas, Host* objects, both renderers.
- K2: the `EditorSession` struct: all fields `pub(crate)`; `Change` and versions; `perform`, `end_gesture`, `register_side_step`, `notify`; traits `ProgramEngine`, `SessionMediaResolving`, `SessionProxyServing`, `AnalysisBackend`, `ProgramFrameSampling`, `SessionEvent` enum; all ~1,800 public session members generated from a Haiku card with a documented pending-marker macro (`pending!("ES<n>")`, the only place where the lint exception lives); `cargo check` passes and the gate counts the remaining markers per owner.
- K3: the `App` struct, platform traits (from `AppPlatform.swift`, plus `ShellFilePicker`), headless `App::{new, frame, handle, drain}`.
- Before ES starts: `CowVec<T>` (Arc<Vec<T>>, make_mut on write, ptr-eq fast equality, serde as a plain list) in sq-core-model for `Project.timelines`, `Project.media`, `Timeline.tracks`, `Track.clips`.

Tasks (workers own whole files):
| Task | Swift group | Lines | After |
|---|---|---|---|
| ES1 | session core rest: Shell, CommandEnablement, Recovery, CommandRouting, KeyRouter, ToolState, FollowSelection | 1.6k | K2 |
| ES2 | TimelineOps, EdgeEdits, Source/Split/MultiEdit, Replace*, Angles, TrimModeModel, SnapGuides | 2.7k | K2 |
| ES3 | FastCut, Speed*, JumpCut, CutCheck, MusicFit, BeatGrid | 1.7k | K2 |
| ES4 | Effects, Color*, Looks, LookStore, Transitions, Presets, Variants | 2.9k | K2 |
| ES5 | Captions, Titles, Text, Graphics, StyleKit, Generators | 2.4k | K2 |
| ES6 | Audio, Voice, AnalysisFlows, Stabilize, Reframe, MagicMaskSession (ONNX path) | 3.1k | K2 |
| ES7 | ProjectPanelModel (+Columns, +Menus), ProxyIntake, Recents | 1.9k | K2 |
| ES8 | resolver moved to `MediaOpener`, Thumbnails, AutoProxy, MediaDisk via `notify`, Relink | 1.6k | K2 |
| ES9 | Export/* | 1.3k | K2 |
| ES10 | Workspace*, AppSettings, Preferences | 2.5k | K2 |
| TU1-2 | SQTimelineUI: Interaction/Geometry/Zoom, then the rest | 5.5k | K2 |
| DK2-3 | DrawKit Inspector controls + Scroll*, then Monitor/* | 4.4k | K1 |
| DT1-4 | SQDrawTimeline: core+draw, input+drop+media, lanes+captions+bands, menus+header+toolstrip+trim | 7.4k | TU |
| DM1-3 | SQDrawMonitor: panel+model, source+slip+scopes+meters, overlays | 5.6k | DK3 |
| IN1-16 | SQInspectorUI by area: EC model 5.0k, EC draw 4.4k, keyframes 3.1k, color model 4.1k, color draw 3.3k, text 3.4k, captions 2.6k, graphics 3.4k, audio+masks 2.1k; model before draw per area | 31.5k | DK2 |
| SH1 | ShellHost, Dialog, Menu*, Keys | 3.1k | K1, K2 |
| SH2-8 | Form, Dock/Floating, Start/About/Mascot, Export, Prefs/Shortcuts, ProjectList, two flow groups | 14.8k | SH1 |
| DL1-2 | Library, Effects | 3.9k | IN |
| AS1-5 | SQAppShell hosts + App root (Windows AppController + Win* glue) | 9.8k | all |
| P1-5 | new: binary 2.5k, platform-mac 0.9k, platform-win 0.8k, accesskit 1k, test modes 1.5k | 6.7k | K3 |
After K0-K3, ES*, TU* and DK* (16 tasks) are independent of each other.

Replaced, not ported: Mac shell `App/Sources/SharedUI` (41 AppKit files, 6.7k) and Windows shell WinSDK files in SQWinApp (16 files, 3.7k) -> P1-P3 (~4.2k new); AppKit menu bar `ShellMenuBar.swift` (363) -> muda; Metal/CoreGraphics/D3D12 UI renderers (525) -> `WgpuRenderer`; Apple-only session files (2.4k) -> portable versions inside ES6/ES8 (~1.2k).

## 5. Oracles
| Layer | Oracle | Pass bar |
|---|---|---|
| renderer | SoftwareRenderer vs WgpuRenderer (G3) | mean < 0.5, FLIP < 0.01 |
| panels, dialogs | binary DrawList dumps per SharedUIShot / WinShellTest state recorded on the Windows test PC; glyph quads keyed by (glyph, face, px), not atlas uv | count/order exact, ±1e-3 px, ±1/255 |
| menus | `shared-menu-*.txt` MenuOutline dumps | byte-equal |
| final image | `--ui-shot` PNG | FLIP < 0.01 |
| session | critical subset of portable Swift tests + model dump per step | exact |
| interaction | JSONL scripts (InputEvents, commands, fake clock) headless in Rust and through a ~200-line `--scenario` mode added to the frozen Swift Windows app; compare `/v1/state`, undo stack, DrawList | exact |
| Edit API | same HTTP calls to both apps | responses equal |
| shell | WinShellTest / WinKeysTest ported as `--shell-test` / `--keys-test` | same ok lines, no frame gap > 100 ms |
| async | G5 fake-clock flow tests | same event order |

## 6. Five riskiest points and decisions
1. Re-entrant borrows (588 weak self, 698 awaits): single root, closure-only access, hooks as events (section 2). A fuzz test of 10k random InputEvents through the headless App must not panic.
2. Undo snapshot cost (Swift copy-on-write vs Rust Vec clone): `CowVec<T>` in sq-core-model before ES starts. Gate: a commit on the largest corpus project takes at most Swift + 20 %; 200 undo steps use at most 1.5x Swift's memory.
3. Full DrawList rebuild per frame: keep it for parity. Gate: one frame of the corpus edit view builds in <= 4 ms on the Mac (baseline from SharedUIShot timings).
4. Glyph and DPI fidelity: one atlas per display scale; compare glyph quads by glyph key; the sq-text gate passes first.
5. Input fidelity: port `MacKeys`/`ShellTextInput` 1:1; add a golden table per OS mapping (physical key, logical key, text, modifiers) to InputEvent; finish the G4 human checklist before Wave 5.

Minimum vertical slice (~6k lines, 1 Opus + 2 Sonnet workers): open a `.sqproj` from the command line; a winit window on Mac and PC showing EditorScreen, TimelineView and MonitorFooter with the Program picture from sq-playback; Space/J/K/L playback with audio; select a clip, ripple Delete, Cmd+Z; Cmd+S and the Save Changes `ask()` on close; Edit API `/v1/state`. It proves the root and task model, modal ask, History + `CowVec`, the engine mailbox, `WgpuRenderer` + atlas, the IME caret path, DrawList and `/v1/state` parity, and the Windows exit rule (drop surfaces before `exit()`).
