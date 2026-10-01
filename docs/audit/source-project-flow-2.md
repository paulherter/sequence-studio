# Audit: source-project-flow (round 2, project file v19)

Basis: `docs/ROUND2.md` stream 2, `docs/spec/monitors.md`, code read first. Adobe text: `docs/reference/adobe/*.txt` (read with grep, nothing copied).
Status: **built** = new tonight, **existed** = already there (regression test added), **partly** / **no** as stated.

## Items

| # | Item | Premiere | Before | Result | Tests |
|---|---|---|---|---|---|
| 1 | J/K/L decelerate | Opposite key slows one step; at 1x it reverses | opposite key restarted at 1x; 3x/5x/7x could double to 10x/14x | **built**: `Shuttle.press` halves (not below 1x), at 1x reverses; doubling clamps to 8x; `Shuttle.adopt` / `KeyRouter.rateChanged` so J/L continue from a Shift+L nudge | PlaybackTests, KeyRouterTests |
| 2 | Source `X` | marks the loaded clip | fell through and marked the sequence | **built**: `Project.markSourceClip`, Source handles `.markClip`, sequence In/Out untouched; also in the Source context menu | SourceMarkClipTests |
| 3 | Out convention and back-timing | In and Out both belong to the range | Program Out stored the playhead (exclusive), no Out at frame 0, Go to Out one frame past | **built**: `Timeline.markIn(at:)` / `markOut(at:)` (Out stored as frame + 1 frame, allowed at 0), `goToOut` lands on the Out frame, range playback parks on the Out frame; `Timeline.sourceEditPlacement` (In, else Out minus duration, else playhead) wired into `EditorSession.sourceEdit`. Out-only is remembered by `Timeline.outOnlyEnd` (not saved; ignored once `inOut` changes) | SequenceMarkConventionTests, SourceFlowSessionTests, EditorSessionTests |
| 4 | Drop on Source, history popup | Drop loads; popup lists earlier clips, Close / Close All | none | **built**: drop target on the Source panel (several items: first shows, rest join the list), title popup (20 unique ids, pruned when media is deleted), Close / Close All; double-click with several selected loads them all | SourceHistoryTests |
| 5 | Hover-scrub `I`/`O`, Shift+H | `I`/`O` mark the hovered clip; Shift+H toggles; Shift scrubs temporarily when off; double-click loads at the hovered frame | hover scrub only | **built**: `ProjectPanelModel.markFromHover` writes `sourceMarks` (not an undo step), toggle persisted in `AppSettings.hoverScrub`, Shift held scrubs while off, double-click opens at the hovered time, context-menu entry "Hover Scrub" | ProjectDeleteFindPosterTests (poster), manual for hover |
| 6 | Source markers (`M`) | clip markers | status "not available" | **built**: `MediaRef.sourceMarkers` (project v19), `Project.addSourceMarker`..., yellow ticks on the strip, M / Shift+M / Cmd+Shift+M in Source, context menu Clear Marker / Clear All; not undoable (clip metadata, like the marks); a second M on a frame says so (no edit dialog yet) | SourceMarkerTests, SourceFlowSessionTests |
| 7 | Drag In/Out grips on the strip | grips of the range drag | strip only scrubbed | **built**: `MonitorScrubMath.hit(x:markIn:markOut:)` (6 pt slop, grips beat the playhead), grips drawn, resize cursor, drag previews in the model, one commit on mouse-up (Source: marks; Program: one undo step). In past Out clears Out, Out before In clears In | ScrubGripHitTests, MarkDragModelTests |
| 8 | Preroll / postroll, Play Around | Shift+K plays around the playhead, Shift+Space plays In to Out with roll; defaults 3 s / 2 s | Shift+Space was plain Play In to Out, no roll | **built**: `PlaybackBounds.extended` / `playAround` (clamped), `returnTo` (Play Around goes back to its start), Settings > Playback preroll / postroll, both monitors, wrench menu has Play In to Out in both | PlaybackRollTests, SourceFlowSessionTests, RollSettingsTests |
| 9 | Relative timecode | type `+10` / `-5` | absolute only | **built**: `Timecode.parseRelative`, field seeks `current + offset` (frames, or a timecode amount), never before 0 | RelativeTimecodeTests |
| 10 | Delete feedback, delete sequences | warn, never lose a used clip | silent beep; sequences could not be deleted | **built**: `ProjectPanelModel.delete` returns `DeleteResult` (blocking sequence names, message in the status bar); `Project.deleteSequence` refuses the last one and one nested elsewhere, fixes `activeTimeline`; one undo step | DeleteSequenceTests, ProjectDeleteFindPosterTests |
| 11 | Poster frame, Find | Cmd+P sets, Option+P clears; Find with criteria | fixed poster at 10 %; filter only | **built**: `MediaRef.posterTime` (v19), Cmd+P (hovered frame, else the Source frame of that clip), Option+P / context menu clear, thumbnails reload; Cmd+F Find sheet (name or label text, offline only) selects all matches | ProjectDeleteFindPosterTests |
| 12 | Monitor feel (uniform scale, anchor at centre, rotate cursor) | | built by the monitors stream | **existed**: regression tests only (`OverlayFeelRegressionTests`, plus the existing TransformOverlayGeometryTests) | yes |
| 13 | Latency HUD, cache strip | | none | **built**: `FrameCache.cachedRanges` (pure), `PlaybackStats.latencySummary`, 2 pt strip on the ruler top edge (RulerView), HUD behind `SQ_HUD=1` (dev aid) | FrameCacheTests, CacheStripTests |

Already there (not rebuilt): Source monitor, I/O marks, insert/overwrite, match frame, scrub bar, timecode entry, icon view with hover scrub.

## Verify against Adobe text

| Row | Adobe text | Verdict |
|---|---|---|
| Preroll / postroll defaults | playing-assets: 3 s preroll, 2 s postroll, set in Preferences > Playback | **verified** |
| Play Around | playing-assets + keyboard-shortcuts: Shift+K, plays before and after the playhead | **verified** |
| Which key plays In to Out | keyboard-shortcuts: Shift+Space = Play In to Out **with Preroll/Postroll**; plain Play In to Out is Ctrl+Shift+Space on Windows = **Option+K on the Mac** | **corrected**: the plan said Ctrl+Shift+Space; the old code had plain Play In to Out on Shift+Space. Now Shift+Space plays with roll, Option+K plain (see conflict below) |
| Out includes its own frame | timecode: the duration between In and Out includes the frames at both; the same timecode for In and Out is one frame | **verified** (applied to Source and sequence marks) |
| Shift+H Hover Scrub | customizing-project-panel: Project panel menu or Shift+H; with it off, Shift scrubs temporarily; I / O mark while scrubbing; double-click loads at the hover position | **verified**, all three behaviours built |
| Cmd+P poster | organizing-assets-project-panel / keyboard-shortcuts: Cmd+P sets, Option+P clears (Mac) | **verified** |
| Mark Clip | keyboard-shortcuts: X | **verified** (what it marks in the Source is not described; whole clip kept) |
| Relative timecode | timecode: type + or - and a number of frames | **verified** |
| Shift+L first speed | "slightly faster", up to five presses, opposite key (Shift+J) slows one increment; first speed not given | **not verifiable**: kept 1.25x start; the five-press cap is not enforced |
| J decelerates | Adobe only describes Shift+J/Shift+L for fine speed; JJ = faster | **not in Adobe text**; plan (web sources) followed, Adobe does not contradict it |
| Step many | preferences: default 5 frames (a Preference) | noted, still fixed at 5 |
| Play from Playhead to Out Point | keyboard-shortcuts: Ctrl+Space | not built |

## Conflicts and decisions to look at

- **Option+K**: the Timeline scope already binds Option+K to Add Keyframe (UX proposal). To stay clear of the shortcut-collision test, Play In to Out (Option+K) is bound in the Program, Source and Project scopes only. In Timeline focus Option+K still adds a keyframe.
- Existing sequence marks keep their meaning; only new marks use the inclusive Out (a mark made yesterday at the same frame is one frame shorter at the end).
- Project file **v19**: `MediaRef.posterTime`, `MediaRef.sourceMarkers`. Identity migration `migrateV18toV19` (new file `ProjectFile+V19.swift`). In this branch `currentVersion` is 19 and 16 -> 17 and 17 -> 18 are identity placeholders in the migrations table until the other round-2 streams merge; on merge keep their migrations and this one.
- `ProjectFileTests` / `ClipColorTests` no longer hard-code the version list; they use `ProjectFile.migrations`.

## Still missing

Four-point Fit Clip dialog, source patching, audio-only waveform in the Source, source timecode display, button editor, Make Subclip, a dialog for source markers (colour, comment), clip-marker navigation in the Project panel, Step many preference, Play from Playhead to Out.
