# Audit: captions and text, round 2 (stream captions-text, project file v21)

Step 1 was a code-reading inventory of docs/audit/text-audio.md against the code. "Existing" items got regression tests
only. Adobe wording was checked with grep in `docs/reference/adobe/*.txt` (nothing copied).

## Inventory and result

| # | Item | Premiere | Before this stream | Done now |
|---|---|---|---|---|
| 1 | Hard minimum caption duration | Min duration in Create Captions | `CaptionSegmenter.applyTiming` extended short captions into the silence after them; no property test | Test for the 0.3 s then 2 s pause case, property test (500 random sets: no overlap, order, starts kept, minimum reached when room); `Timeline.trimCaption` fixed so it can never overlap a neighbour (review finding 9, see below) |
| 2 | Create Captions options | Preset, style, length, duration, gap, lines | Dialog with all fields, `CaptionPreset.gap`, Short Video preset (one line) | `CaptionPreset.minGap` (alias of `gap`), tests for it and for one line yielding `lines.count == 1` |
| 3 | Split and merge caption | Yes | Existing, tested (word boundary, edges refused, same range) | Word timings now follow a split and a merge (karaoke) |
| 4 | Add caption at playhead, delete, selection shown in the Captions tab | Yes | Existing (context menu, Captions tab, `Timeline.addCaption`) | Finding 9 fixed (`Captions.swift`); new captions take the track style |
| 5 | Caption-track style, per-item overrides | Style per track | One popup rewrote every caption | `CaptionTrack.styleRef/animationRef`, `CaptionItem.styleOverridden`; track style leaves overridden captions alone; row context menu Style > ... and Use Track Style |
| 6 | Karaoke word highlight | Not in Premiere (TikTok look) | none | `CaptionWord` timings from the transcript, `KaraokeStyle` on the track, per-word colour keys (`CaptionItem.karaokeKeys`), highlight raster in `TextRenderer`, same `CaptionKaraoke.highlight` function for the monitor (`CaptionPreview`) and the burn-in (`CaptionBurnIn`); deterministic render test and monitor/export pixel parity test; Captions tab: Word Highlight, colour, Keep spoken |
| 7 | Type tool click on existing text | Edits it | Existing (private hit test in `EditorPanels`) | Hit test moved to `TextHitTest.topmostTextClip` (SQEditorUI, pure), tested: topmost clip, nothing hit outside or off the playhead, undo depth unchanged |
| 8 | Tracking, italic, all caps | Yes | Tracking, italic existing | All Caps (`TextStyle.allCaps`: glyphs change, stored text does not); test that width grows linearly with tracking |
| 9 | Stroke position, shadow angle/distance | Inner/outer stroke; shadow angle, distance | Outside stroke only; shadow angle/distance existing | `TextStroke.position` outside/centre (bounds grow by w outside, w/2 centred), popup in the Text section; shadow regression tests existed already |
| 10 | Six align-to-frame buttons | Align and Transform | none | `TextAlignToFrame` (pure, tested incl. scale and lopsided ink), six SF Symbol buttons in the Text section of Effect Controls, one undo step, keyed Position gets a key at the playhead |
| 11 | Transcript search next/previous | Search field, up/down arrows | Captions tab: Return jumped to the next match only | Transcript tab: Find field, matches marked, up/down buttons, Return / Shift+Return; Captions tab: up/down buttons and Shift+Return (`TranscriptSearch`, `Timeline.captionMatch`, tested) |
| 12 | Default text duration | Title default 5 s | Hard coded 5 s | Settings > General > New text length (1 to 30 s), `AppSettings.defaultTextSeconds` |
| + | Show/hide captions in the Program monitor | Closed Captions Display toggle | Always on | View > Show Captions in Program Monitor (checkmark, remembered), `PlaybackEngine.showsCaptions`; export burn-in is not affected |
| + | Edit a caption in the Program monitor | Edit in the monitor | Only in the Text panel | Double-click a caption's text in the monitor opens the in-place editor over it (`CaptionMonitorHit`), typing is one undo step; works while a clip is selected |

Review finding 9 (SQCore review, sub-frame neighbour overlap in `Captions.swift`): `CaptionTrack.trim` could move the
head before the previous caption's end or the tail past the next caption's start when the item was shorter than the
minimum (squeezed by neighbours). Fixed with neighbours-win clamping plus a property test. If the cloud session brings
its own fix, keep that one and drop this one (same file, same function).

## Verify against Adobe text (grep in docs/reference/adobe/*.txt)

| Row | Result |
|---|---|
| Create Captions dialog fields | Verified (`working-with-captions.txt`, "Create captions from transcript"): caption preset, format, stream, style, length / duration / gap between captions, lines (single or two). We have preset (our styles), length, minimum duration, gap, lines. Format and stream are broadcast formats: not applicable (burn-in and SRT only). |
| Create Captions dialog defaults | Not verifiable: the text names no default values. Ours: 42 characters, two lines, 1 s, gap 0 (Standard) and 18, one line, 0.5 s (Short Video). Marked (unverified). |
| Type tool click and area text | Partly verified (`create-titles.txt`): Type tool, type text, a title appears above the clip; drag to extend or shorten it, default duration 5 seconds (verified, matches our 5 s); edit via double-click on the clip or Edit Properties. The pages found do not describe click on existing text or drag-to-box wrapping. Marked (unverified). |
| Stroke | Verified only for the legacy Titler (`fills-strokes-shadows-titles.txt`): inner and outer strokes, size, angle. The current Essential Graphics wording (inside/centre/outside) was not found: our outside and centre are marked (unverified), no inside. |
| Search in the transcript | Verified (`speech-to-text.txt`): type the term, all instances are highlighted, Up and Down arrows navigate the instances, Replace for the selected instance, Replace All. |
| Captions display toggle | Verified (`old-captions-workflow.txt`): wrench menu, Closed Captions Display > Enable, "toggle captions display on and off". Ours is a View menu item (no monitor wrench menu in this app). |

## Not done
- Stroke Inside (the legacy Titler had it).
- The transcript search has no replace for one instance (Captions tab Replace All exists).
- Karaoke does not animate (no scale pop of the lit word); colour only.
- A caption cut by a reversed clip spreads its words evenly (no word timings).
- `ProjectFile.currentVersion` stays at 16 in this branch: the v21 step is registered (`20: migrateV20toV21`, identity) and
  the version is set on merge to the highest number, per the bump protocol.

## Review fixes (second pass)
- Word times inside a caption are relative to its start: move, ripple, tail trim and snapping need no change, head trim and
  split rebase them, reads clamp into the caption. Split cuts where the speech is (words ending before the cut stay left).
- Karaoke draws the plain caption once per caption and the lit words as a second, small layer (monitor and burn-in the same
  way); a cold lit layer is skipped for a frame, the caption never waits. The next word's layer is prepared ahead.
- Burn-in cache evicts only what lies behind the current caption.
- Word spans are computed once in `TextLayout` on the original text (`TextWords`, `Character.isWhitespace`), shared by the
  renderer; capitals are made per character, so "Strasse" with a sharp s keeps its spans (test), and a wrapped long word stays one word.
- In-place editor with All Caps: the field is drawn visibly (dark backing, stored text) instead of an invisible caret layer.
- Not covered by a test: the burn-in texture eviction (needs a Metal device); `ExportQueueTests.cancelRunningJobContinuesWithNext`
  and `textLayerAppearsOnlyWhileTheClipIsActive` failed once under load 60 and pass alone.
