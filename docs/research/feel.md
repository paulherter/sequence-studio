# Research F / feel: timeline zoom, scroll, scrub, snapping, trim feedback

Scope: Premiere vs DaVinci Resolve vs Final Cut, what makes each feel fast, and what Sequence Studio (SQ) should adopt.

## Honesty about sources

This run had limited web access: `helpx.adobe.com`, `community.adobe.com` and `support.apple.com` were blocked by the
egress proxy, so only search snippets were readable. Items are tagged:

- **[sourced]** stated in a search result (linked).
- **[recall]** from general knowledge of the apps, not verified in this run. Paul should confirm on the Mac before we
  build on it. No concrete pixel numbers for Premiere/Resolve/FCP snapping were findable; none are invented here.

## 1. What the others do

### Premiere
| Area | Behaviour | Tag |
|---|---|---|
| Zoom | `+` / `-` zoom; zoom scrollbar at bottom, drag handle ends | [sourced: Adobe navigate page via search](https://helpx.adobe.com/tw/premiere/desktop/edit-projects/change-clip-sequence/navigate-sequences-in-the-timeline.html) |
| Scrub | Drag playhead in ruler; arrows = 1 frame, Shift+arrows = 5 frames | [sourced, same] |
| Snapping | Shift-drag playhead snaps to edges and markers; `S` toggles snapping, and holding `S` flips it temporarily during a drag; pref "Snap playhead in timeline" makes it permanent | [sourced, same](https://community.adobe.com/t5/premiere-pro-discussions/why-doesn-t-the-playhead-snap-to-an-edit-point-in-the-timeline/td-p/4819759) |
| Snap distance | Not user-adjustable; community talk says it is zoom-relative, i.e. a fixed pixel radius | [sourced, weak](https://thomaswictor.com/turn-off-snapping-in-premiere-pro-why-your-timeline-feels-sticky-and-how-to-fix-it-zom) |
| Wheel mapping | Scroll wheel/modifier combos for scrub and zoom changed between versions and annoy users | [sourced](https://community.adobe.com/questions-729/keyboard-middle-mouse-scroll-wheel-combinations-shortcuts-to-scrub-and-zoom-timeline-are-different-how-to-change-them-back-1334681) |
| Perf | Users report timeline dropping to ~5 fps after a few cuts on heavy projects | [sourced](https://community.adobe.com/questions-729/premiere-pro-2024-timeline-lag-1414589) |
| Alt/Option+wheel zooms around the pointer; `\` fits sequence; Esc/Cmd-drag trims show both-sides live in Program Monitor (trim monitor) | [recall] |

### DaVinci Resolve
| Area | Behaviour | Tag |
|---|---|---|
| Snapping | `N` toggles; commonly fought during slip/sync | [sourced](https://chrisdobey.com/resolve/2018/2/12/davinci-resolve-shortcuts-snapping) |
| Scrub/playback | Reported smooth scrubbing where Premiere lags on the same media; credited to GPU/multi-core pipeline | [sourced, anecdotal](https://blog.motionarray.com/learn/davinci-resolve/davinci-resolve-vs-premiere-pro/) |
| Cache | Smart Cache / render cache with a ruler strip: red = to be cached, blue = cached; optimized media speeds up all pages | [sourced](https://www.4kshooters.net/2020/07/15/smart-playback-caching-in-resolve-16) |
| Storage | Scrub lag often disk-bound; dedicated NVMe for cache | [sourced](https://evezone.evetech.co.za/build-lab/how-to-set-up-an-nvme-scratch-and-cache-disk-for-editing) |
| Dynamic trim mode (`W`), JKL while trimming, edit/trim on one live view; Alt+scroll zoom, Cmd+scroll horizontal scroll; Shift+Z fit | [recall] |

### Final Cut Pro
| Area | Behaviour | Tag |
|---|---|---|
| Snapping | `N`; affects Select, Trim, Position, Range and Blade tools | [sourced](https://support.apple.com/is-is/guide/final-cut-pro/aside/verb97d145e/12.0/mac/15.6) |
| Magnetic timeline | Surrounding clips auto-move/snap to avoid gaps and collisions; keyboard-oriented trimming; jog wheel for frame trim | [sourced](https://blog.frame.io/2017/10/16/fcpx-magnetic-timeline/) |
| Skimming | Hover scrubs with no click; `S` toggles skimming, audio skimming separate | [recall] |
| Zoom | Cmd +/- , Shift+Z fit, animated zoom, appearance slider for clip height | [recall] |

## 2. Why each feels fast (synthesis)

1. **Latency is decode latency, not UI latency.** The Resolve-vs-Premiere gap in every source is playback/scrub pipeline
   (GPU decode, cache, optimized media), not timeline drawing.
2. **Visible cache state** (Resolve's red/blue strip) lets the user trust and predict scrubbing.
3. **Frame-level hover feedback** (FCP skimming) removes the click from navigation.
4. **Zoom anchors on the pointer/playhead**, never on the left edge. Snapping is a fixed pixel radius, so it feels
   consistent at every zoom.
5. **Snap toggle is one key, and momentary during drag** (Premiere `S` hold).

## 3. SQ today (read from code)

- Zoom: step 2.5x per `=`/`-`, Option/Cmd+wheel exp(delta*gain), pinch gain 4.5, anchored at pointer, `\` fit toggle with
  memory, limits down to fit*0.5 and up to 4 frames across or 400 pt/frame
  (`Packages/SSEditorUI/Sources/SSEditorUI/TimelineZoom.swift:5-26`, `TimelineView.swift:333-355`).
- Snap radius: 8 pt for clip drags (`TimelineGeometry.swift:~60`, `defaultSnapThresholdPoints`), 10 pt for playhead
  (`PlayheadLogic.swift:28`). Both fixed pixel radius. Same model as Premiere [sourced weak].
- Playhead follow during play: page-wise, manual scroll wins (`PlayheadLogic.swift:1-25`).
- Scrub: `PlaybackEngine.beginScrub/scrub/endScrub`, with audio grains and 5 ms fade (`SSPlayback/PlaybackEngine.swift:130-147`).
- Frame cache: byte-budgeted, evicts farthest from playhead, behind-direction counts double (`SSPlayback/FrameCache.swift`).
- Not found in code: hover skimming, cache-state strip on the ruler, a momentary snap-hold key, edge autoscroll while dragging
  a clip/playhead (grep for autoscroll found nothing).

## 4. What to adopt

| # | Item | Package | Effort | Notes |
|---|---|---|---|---|
| 1 | Cache-state strip on ruler (cached/uncached ranges from `FrameCache` index) | SSPlayback API + SSEditorUI draw | M | Resolve model. Needs a cheap "cached ranges" query on the cache. |
| 2 | Hold-`S` momentary snap invert during drags | SSEditorUI (KeyRouter, TimelineInteraction) | S | Premiere behaviour [sourced]. |
| 3 | Edge autoscroll while dragging clip or playhead near viewport edge | SSEditorUI | S-M | Not present. Test the pure speed-vs-distance function in a unit test. |
| 4 | Optional hover skimming in timeline/Project panel with toggle | SSEditorUI + SSPlayback scrub path | M | FCP. Reuse `scrub(to:)` without audio grains. Rate-limit to latest request. |
| 5 | Frame-accurate scrub latency measurements (Stats) shown in a debug HUD | SSPlayback `Stats.swift` | S | Paul judges feel; we report ms from pointer event to presented frame. |
| 6 | Optimized/proxy media for scrub-heavy clips | SSProxy | L | Already a package; ensure scrub prefers proxy decode scale. |
| 7 | Trim feedback: two-up live view while edge trimming | SSEditorUI + SSRender | M-L | Premiere/Resolve [recall]; verify first. |
| 8 | Snap-point indicator line while snapped | SSEditorUI | S | Confirm whether `SnapGuides` already covers timeline (it covers the transform overlay). |

## 5. Code worth borrowing

None identified this run: no repository was read (browsing was limited to search snippets). Candidates to check next
run, all GPL-3.0-compatible: Kdenlive timeline (GPL-2+/3: verify "or later"), Olive (GPL-3.0), Shotcut (GPL-3.0),
OpenShot (GPL-3.0). Licence per file must be checked at read time. Nothing recorded in THIRD_PARTY.

## 6. Open questions for Paul

- Confirm on the Mac the [recall] rows (Premiere trim feedback, FCP skimming zoom keys). No concrete numbers (ms, px)
  for competitor snapping or zoom were findable, so we should tune SQ by feel, not by copying numbers.
- Run Job F `engine` next with full web access, and re-run `feel` if Adobe/Apple domains are allowed on the proxy.
