# Premiere Pro behaviour reference (for Sequence Studio)

Purpose: "user does X -> exactly Y happens", so an engineer can implement the interaction model without opening Premiere.
Own wording throughout; no Adobe text is copied.

## Source quality and conventions (read first)

- Adobe's help site (helpx.adobe.com) answered HTTP 403 to every automated fetch during this research (WebFetch and curl with a
  browser user agent). Adobe pages could therefore NOT be read directly. Search-result snippets, ProVideo Coalition,
  Larry Jordan, Evergreen State helpwiki, Frame.io blog and Adobe community threads were used instead, and the rest is
  written from working knowledge of Premiere Pro 2023-2025 on macOS.
- Tags: **[S]** = confirmed by a cited secondary source or an Adobe snippet returned by search. **(unverified)** = from memory or
  could not be confirmed from any source; check against the real app before relying on it.
- "Cmd" = Command, "Opt" = Option. Shortcuts are macOS defaults. Premiere's own docs call the key "Alt/Option" and
  "Ctrl/Command" in cross-platform text.
- Adobe pages that should be consulted by a human with a browser (all returned 403 to tools):
  - https://helpx.adobe.com/premiere-pro/using/default-keyboard-shortcuts.html
  - https://helpx.adobe.com/premiere-pro/using/trimming-clips.html
  - https://helpx.adobe.com/premiere-pro/using/controlling-effect-changes-using-keyframe.html
  - https://helpx.adobe.com/premiere-pro/using/lumetri-color-panel.html
  - https://helpx.adobe.com/premiere-pro/using/editing-tracks-timeline.html (title approximate)

Sources actually read or returned by search (cited per section as S1..):

- S1 https://www.provideocoalition.com/premiere-pro-hot-topics-understanding-source-patching-and-track-targeting/
- S2 https://larryjordan.com/articles/five-hidden-keyboard-shortcuts-to-faster-trimming-in-adobe-premiere-pro
- S3 https://www.skillademia.com/shortcuts/premiere-pro-shortcuts/
- S4 https://helpwiki.evergreen.edu/wiki/index.php/Keyframe_Editing_-_PP
- S5 https://helpx.adobe.com/premiere-pro/using/controlling-effect-changes-using-keyframe.html (search snippet text only)
- S6 https://blog.frame.io/2018/05/21/premiere-lumetri-guide/ (search snippet only; page fetch 404)
- S7 https://community.adobe.com/questions-729/direct-manipulation-has-lock-axis-with-shift-changed-1625643
- S8 https://www.provideocoalition.com/tool-tip-tuesday-for-adobe-premiere-pro-direct-manipulation-of-clips/
- S9 https://helpx.adobe.com/premiere-pro/how-to/essential-graphics-panel.html and
  https://helpwiki.evergreen.edu/wiki/index.php/Titles_-_Essential_Graphics
- S10 https://www.provideocoalition.com/tool-tip-tuesday-for-adobe-premiere-pro-maximize-monitor-shortcut/
- S11 https://blog.adobe.com/en/publish/2011/02/20/red-yellow-and-green-render-bars
- S12 https://www.tourboxtech.com/en/news/adjust-premiere-pro-track-height.html and
  https://helpx.adobe.com/premiere-pro/how-to/timeline-track-controls-premiere-cc.html (snippets)
- S13 https://www.premiumbeat.com/blog/premiere-pro-timeline-source-patching and https://www.adobe.com/learn/premiere-pro/web/premiere-pro-source-patch-cc

Sequence Studio today (from docs/STATUS.md and docs/FEEDBACK-4.md): SSCore has sequence-wide ripple, trim/roll/slip/move, snapping,
link-aware edits, track lock and sync lock flags; shell has timeline, Program monitor, Effect Controls with keyframe graph, colour
sections, text/captions, export queue, meter panel; tool column is Selection/Razor/Slip/[Pen]/[Shape]/[Mask]/Hand/Type.

---

## 1. Timeline basics

Sources: S1, S12, S13, Adobe timeline docs (not readable), working knowledge.

### 1.1 Track header controls

Each track header (left of the clips) has, from left to right on a video track:

| Control | Meaning |
|---|---|
| Source patch button (V1, A1 ... squares at the far left) | Where the SOURCE monitor's video/audio will land on Insert/Overwrite. One patch per source channel group (one video, up to N audio). |
| Track target button (the track name, e.g. V1/A1, becomes a lit block) | Which tracks are "targeted": receive pastes, are cut by Cmd+K, supply Lift/Extract range, drive sync-locked ripple. |
| Sync lock (arrows icon) | Track follows ripple edits made on other tracks. |
| Track lock (padlock) | Track cannot be edited at all. |
| Eye (video) / M S (audio) | Visibility; mute and solo. |
| Record/voice-over (audio) | Narration record arm. |

### 1.2 Source patching vs track targeting

| Action / Modifier | Result |
|---|---|
| Click an empty source-patch square on a track | Patch the source channel to that track; the old patch on that channel is released. [S1] |
| Drag a patch up/down | Reroutes the source channel to another track. |
| Click a lit patch | Patch toggles off ("edits ignored" for that channel). Disabled patch = that channel is not sent in an Insert/Overwrite. [S13] |
| Source-patch state "black/silent" (third state described by tutorials) | Gaps are placed on the track instead of media. (unverified in current versions) |
| Press `,` or `.` with Source monitor loaded | Edit uses source patches (not targets) to choose destination tracks. [S1] |
| Drag a clip from Project/Source into the timeline | Ignores patches AND targets; clip lands on the track under the pointer. [S1] |
| Cmd+V (paste) | Pastes at the playhead onto the highest-priority targeted track; video targets outrank audio. Several targets active -> still goes to the highest one, so turn unwanted targets off. [S1] |
| Press X (mark clip) / Opt+click on clip | X marks the clip that is on the highest-priority targeted track under the playhead; if video tracks are targeted, audio is only marked after video targets are off. [S1] |
| Click a track target block | Toggles that track targeted. Shift-click: toggles more tracks without clearing (unverified). Opt-click: target only this track (unverified). |
| Cmd+Opt+1..9 / Cmd+Shift... track-target shortcuts | Toggle target of video track N / audio track N (unverified which modifier). |

Edge cases:
- Targets and patches are independent: you may patch V1 but target V3. Keyboard Insert/Overwrite follow the PATCH; Cmd+K, Lift/Extract, paste and Ripple-delete-in-range follow the TARGET.
- A track that is locked cannot be a target for a paste or edit; the patch can still point to it but the edit is refused (beep).
- If no video track is targeted or patched, the video part of a source is dropped; the edit still works for audio.

### 1.3 Sync lock and track lock

| Action | Result |
|---|---|
| Sync Lock ON for a track, then Insert / Ripple Delete / Extract / ripple trim on ANOTHER track | The sync-locked track moves in lockstep: an insert opens a gap (clips split at the insert point) in it; a ripple delete closes the same time range. [S1 gist; Adobe docs] |
| Sync Lock OFF | The track is not moved; stays where it is. Only targeted tracks ripple. [S1] |
| Edit made ON a sync-locked, untargeted track | Does not itself ripple others, but that track is protected from being cut by Add Edit unless targeted. (unverified) |
| Track Lock ON | You cannot select, move, trim, delete, or razor anything on that track. Clips show hatch pattern. Sync-lock does NOT override: a locked track is unchanged by other tracks' ripples (it stays out of sync - lock beats sync). (unverified in detail) |
| Locked track in a Ripple Delete of a time range spanning it | Premiere refuses the whole ripple if a locked clip would be cut; "gap" with locked content remains. (unverified) |

Implementation note: three booleans per track (target, sync, lock) + per source channel patch; ripple code needs `affectedTracks = targeted ∪ syncLocked − locked`.

### 1.4 Linked selection

| Action | Result |
|---|---|
| Linked Selection ON (toggle in timeline header, default ON) | Click a clip: its linked partners (video+audio, grouped by Cmd+L) are selected too and edit together. |
| Linked Selection OFF | Clicks select single clips; edits do not propagate. Linked clips still show the link badge; the link itself stays. |
| Opt+click a clip | Selects only that clip of a linked pair (temporary bypass); Opt+click with Linked Selection OFF selects with link (inverse) (unverified). |
| Cmd+L on selected clips | Link if not linked / unlink if linked. |
| Move a linked pair | Both move; if one side is dragged to another track, the other keeps its track. Loss of sync shows red out-of-sync badge with the frame offset (e.g. -3); right-click the badge: Move into Sync / Slip into Sync. |
| Trim a linked clip with Selection tool | Both sides trim by the same amount (unless Linked Selection is off, or Opt-trim to trim one side only - Opt-drag edge while holding Opt. (unverified)) |
| Delete a linked pair | Both go; Ripple-delete closes both. |

### 1.5 Snapping

Toggle: `S` (also the magnet button). Applies while dragging, trimming, scrubbing with Shift.

| What snaps | To what |
|---|---|
| Clip being moved (its head and tail edges) | Other clip edges on any track (cut points), sequence start, playhead, markers (sequence and clip markers shown in ruler/clip), In/Out marks, keyframe positions on clips (when clip keyframes shown) (unverified for keyframes) |
| Trim edge being dragged | Same targets; the snap guide is a thin vertical line across tracks. |
| Playhead scrubbing in ruler | Does NOT snap by default; hold Shift to engage snapping (reverse of drag behaviour: Shift toggles snapping while scrubbing). [S4 "Shift-drag the playhead snaps to keyframe" for Effect Controls; timeline analog from Adobe docs - confirm] |
| Playhead dragged in Effect Controls keyframe area with Shift | Snaps to keyframes. [S4] |
| Snap distance | A few pixels (screen-space threshold), NOT a time threshold, so zooming out makes snapping reach farther in time. |

Edge cases:
- Dragging with snapping off and Cmd held (insert) still draws the insert arrow.
- Snapping is global (one flag), saved in the app, not per sequence. (unverified)

### 1.6 Playhead behaviour

| Action | Result |
|---|---|
| Click ruler | Playhead jumps there; click-hold-drag scrubs; picture and audio-scrub follow. Playback stops if it was running. |
| Click in the empty area of a track | Deselects clips; does NOT move playhead. |
| Left / Right | Previous/next frame. Shift+Left/Right: 5 frames (value in Preferences > Timeline). [S3] |
| Up / Down | Go to previous / next edit point on targeted tracks (or all tracks if none targeted; with Shift: only selected track). (unverified details) |
| Home / End | Sequence start / end. [S3] |
| Shift+I / Shift+O | Go to In / Out. |
| Auto-scroll when playing (Preferences > Timeline > Auto Scrolling) | "Page scroll": when the playhead reaches the right edge the view jumps one page so the playhead lands at the left. "Smooth scroll": playhead stays fixed near the centre/leading area and the content scrolls under it. "No scroll": view never moves. |
| Manual scroll during playback | View stays where you put it until playhead leaves it again (matches FEEDBACK-4 item 9). Auto-follow does not "fight" a manual scroll in Premiere's Page mode: it only pages when the playhead goes off-screen. |
| Playback at sequence end | Stops at the end of the last clip (or Out point if "Loop" is off); with loop on, returns to In/start. |
| Click Play with In/Out set | Plays from playhead; Shift+Space or Opt+K variants play In to Out ("Play In to Out" = Opt+K). (unverified) |

### 1.7 Scroll and zoom

| Action | Result |
|---|---|
| `=` / `-` | Zoom in / out around the playhead (or around the cursor if hovering over the ruler? Premiere uses the playhead). Zoom steps are fixed factors. |
| `\` | Zoom to fit whole sequence; press again to return to previous zoom (toggle). [S3 "fit view"] |
| Opt+scroll wheel / two-finger trackpad scroll with Opt | Zoom horizontally centred at the pointer (Premiere 2020+: around the playhead if Preferences "Zoom to playhead" - unverified). |
| Plain scroll (vertical) | Scrolls the track stack. |
| Shift+scroll or horizontal two-finger | Scrolls time horizontally. |
| Pinch on trackpad | Zoom (newer versions) (unverified). |
| Drag the ends of the navigator scrollbar (zoom bar under the ruler) | Resize the visible range: handles zoom, drag the middle to pan. Double-click the bar: zoom to fit. |
| Cmd+scroll | Scrolls tracks vertically when tracks are minimised? (unverified) |

### 1.8 Track height

| Action | Result |
|---|---|
| Drag a track header's bottom edge | Resize that track only; min is one line (icon-only), max a few hundred pixels. |
| Shift+drag the edge | Resize ALL tracks of that type (all video or all audio). [S12] |
| Double-click a track header's empty area / edge | Toggle between two standard heights; with Shift, applies to all tracks of the type. [S12] |
| Opt+scroll over the track header column | Change the height of that track; with Shift all tracks of that kind. [S12] |
| `Cmd+=` / `Cmd+-` (video), `Opt+=` / `Opt+-` (audio) | Make video / audio tracks taller or shorter. [S12; exact modifier mapping per snippet, "Control/Command"] |
| `Shift+-` / `Shift+=` | Minimise all tracks / expand all tracks. [S12] |
| Drag the horizontal divider between the last V track and first A track | Moves the visible split: gives more space to video or audio when the stack does not fit; each region scrolls independently (Premiere keeps separate scroll for V and A halves). |
| Header "Collapse/Expand track" toggle (right-click header: Minimize / Expand) | Per track. |
| Custom height presets | None; height is a continuous value saved per sequence. (unverified) |

Edge: minimised video tracks show no thumbnails; audio minimised hides waveform. Clip names are drawn only if height permits.

---

## 2. Edit operations

Sources: S1, S2, S3; Adobe editing docs (unreadable); working knowledge.

### 2.1 Insert, overwrite, lift, extract

| Action | Result |
|---|---|
| `,` (Insert) from Source monitor | Source In->Out (or whole clip if none) is placed at the playhead on the patched tracks. Everything to the right on targeted AND sync-locked tracks moves later by the clip length; a clip under the playhead is split. |
| `.` (Overwrite) | Same placement but replaces whatever is underneath; nothing moves. |
| Insert/Overwrite when Source has In only / Out only | Uses the defined end and the other end falls to clip start/end. Three-point rule below. |
| Drag from Project/Source into timeline (no modifier) | Overwrite at the drop position. |
| Same drag with Cmd held | Insert: arrow indicator shows downward-arrow marks; all tracks ripple (respecting sync locks). Cmd must be held when the drag begins or while over a track? Holding it while releasing works. (unverified) |
| Move an existing clip by dragging | Overwrites by default (leaves a gap where it was). |
| Drag an existing clip with Cmd | Insert-move: a gap closes behind it (ripple) and opens at drop. Linked partners ride along. (unverified exact side effects) |
| Cmd+Opt drag | Insert a copy/moved clip at a new position on the same track without overwriting. [S2 bonus tip] |
| Drag with Opt held | Copy (cursor shows a plus); drop overwrites. Original stays. |
| `;` Lift | Remove In->Out (or the selected clips if Selection tool has clips selected: yes - lift takes clips if selected, else In/Out range on targeted tracks), leaving a gap of the same length. Not sync-lock aware. |
| `'` Extract | Same range removed AND the gap closes: ripples targeted and sync-locked tracks. |
| `Delete` on selected clips | Removes clips, leaves gap. |
| `Shift+Delete` Ripple Delete | Removes clips and closes the gap on all tracks that are not locked, subject to sync-lock rules: other clips overlapping the removed time range on unlocked tracks and not selected block the ripple only if they occupy that space on a track that is NOT sync-locked and is not part of the delete (Premiere then ripples only as far as the free gap allows: it closes the smallest common gap across tracks). |
| Ripple delete of a gap | Select the empty gap (click it) and Delete: closes it; blocked at the minimum overlap across unlocked tracks (aborts with a message if another track has a clip in the way). |
| `Cmd+K` Add Edit | Splits clips under the playhead on TARGETED tracks; if clips are selected, only those. [S3] |
| `Shift+Cmd+K` Add Edit to All Tracks | Splits every track at the playhead regardless of targets and locks (locked tracks excluded). (unverified for locked) |
| Razor tool click | See Tools. |
| `Q` / `W` | Ripple trim previous / next edit to the playhead: moves the nearest edit (on targeted tracks at the playhead) to the playhead and closes the gap (ripple). [S2 describes Q/W as In/Out trim to playhead: see 3.4] |
| `E` | Extend selected edit to playhead: moves the selected edit point to the playhead (trim/roll depending on which type is selected). |

### 2.2 Nudging

| Action | Result |
|---|---|
| Opt+Left / Opt+Right with a clip selected | Nudge clip by one frame. [S2 for trim context] |
| Shift+Opt+Left/Right | Five frames (Preferences > Trim > Large Trim Offset). [S2] |
| Opt+Up / Opt+Down with clips selected | Move clip up or down a track (overwrites at destination). [S2] |
| `Opt+,` / `Opt+.` | Nudge clip left/right by one frame (older mapping). (unverified) |
| Selected edit point + Opt+Left/Right | Trims the edit one frame per press in the current trim mode (see §3). [S2] |

### 2.3 Three-point and four-point editing

| Case | Marks | Result |
|---|---|---|
| Three-point | Any three of: source In, source Out, sequence In, sequence Out | The fourth is computed from the other side's duration: given source In/Out and sequence In, sequence Out = In + duration. Given source In and sequence In/Out, source Out = In + sequence duration. |
| Four-point | All four set | Source and sequence durations may differ. Dialog "Fit Clip": Change Clip Speed (Fit to Fill) / Ignore Source In / Ignore Source Out / Ignore Sequence In / Ignore Sequence Out. Fit to Fill retimes the clip. |
| One mark only | Source In only, nothing in sequence | Sequence In defaults to the playhead; source duration = from In to clip end. |
| No marks | - | Whole source at the playhead. |

Marks live on the Program monitor for sequence In/Out, on Source monitor for source In/Out. If no sequence In/Out exists, Insert/Overwrite uses the playhead as the sequence In.

### 2.4 Replace edit and match frame

| Action | Result |
|---|---|
| Opt+drag a Project/Source clip onto a timeline clip | Replace: the new clip substitutes the old clip, keeping the old clip's length and position. Default alignment: source's In is at the old clip's head (clip start). (unverified) |
| Opt+Shift variant | Replace with Match Frame alignment: aligns the source's frame at the Source playhead with the timeline playhead, used for changing the shot while keeping the frame sync. (unverified) |
| Source monitor menu "Replace Edit" shortcuts (Opt+Cmd+...) | Replace from Source Monitor, Match Frame / Replace from source / Replace from bin. (unverified) |
| Replace on a clip with effects | Effects/keyframes of the replaced clip are kept (retains attributes). (unverified) |
| `F` Match Frame | Loads the clip under the playhead (on the targeted track; selected clip if any) into the Source monitor, parked on the same frame, with the playhead's source position and the clip's In/Out marks shown. |
| `Shift+R` Reverse Match Frame | Moves the sequence playhead to the frame matching the Source monitor's current frame within the clip used in the timeline. |

---

## 3. Trimming

Sources: S2 (confirmed: Opt+arrows, Shift+Opt+arrows, Ctrl+T toggles trim type, Q/W top&tail); working knowledge of Adobe docs otherwise.

### 3.1 Selection tool at an edge

| Action | Result |
|---|---|
| Hover near a clip's left/right edge | Cursor becomes a red bracket (trim head / trim tail). The bracket faces the clip being trimmed. |
| Drag the edge | Regular (non-ripple) trim: In/Out of that clip changes, duration changes, gap or overwritten neighbour; clips beyond the edit do not move. Dragging into a neighbour overwrite-trims it? NO: you cannot trim over a neighbour; drag stops at the adjacent clip's edge. Extension beyond source media is blocked at the source end. |
| Cmd held while dragging (or Cmd held on hover) | Ripple trim; the bracket turns yellow. All later clips on affected tracks shift by the delta; sync-locked tracks follow. |
| Hover at the cut between two adjacent clips | A double bracket appears; dragging performs a rolling edit (the cut moves, total length is unchanged). Which one appears depends on the cursor's horizontal position relative to the cut: left half trims the left clip, right half the right clip, dead centre rolls. (unverified exact zones) |
| Click an edge (trim selection) | The edge is highlighted (red); Shift+click to add another edge (multi-select edit points across tracks); then Opt+arrows or the Trim mode panel apply the change to all. |
| Opt+drag edge on a linked clip | Trim only that clip, not its partner (temporary unlink). (unverified) |
| Drag edge with linked selection on | Partner edge trims in sync. |
| Drag a tail past the end of the source | Stops at source end; red "end of media" cue. Drag a head past start: same. |
| Trim to create gap | Shortening a clip leaves a gap behind (no auto ripple) unless Cmd. |

### 3.2 Dedicated trim tools

| Tool (key) | Gesture | Result | Gap / linked / sync behaviour |
|---|---|---|---|
| Ripple Edit (B) | Drag the edge of a clip | Trims that edge and ripples everything after it. The neighbour on the other side is unaffected. Shows yellow bracket; Program monitor shows two-up (outgoing/incoming) view during drag. | No gap remains. Linked partner trims too. Sync-locked tracks shift by the delta; locked tracks do not (may go out of sync). A track with a clip in the way blocks the ripple at the available amount. |
| Rolling Edit (N) | Drag a cut between two clips | Moves the cut: left clip Out and right clip In change by opposite deltas; sequence length is constant. Limited by the available handles on both clips. Two-up display. | Linked partners edited with it. Does not ripple. |
| Rate Stretch (R) | Drag the edge | Clip duration changes WITHOUT changing source range: speed changes (shorter = faster). Cursor shows clock icon. Limits ~ 5%-20000% (unverified). Neighbours do not move; blocked by neighbours. | Audio stretches with the video if linked; pitch follows unless "Maintain Audio Pitch" is set in Speed dialog. |
| Slip (Y) | Drag inside a clip | Changes In and Out together (same duration); position unchanged. Program monitor shows a 4-up (left neighbour out, new in, new out, right neighbour in). Limited by handles. | Linked pair slips together. No effect on neighbours or other tracks. |
| Slide (U) | Drag inside a clip | Moves the clip in time; the neighbours' Out (left) and In (right) trim opposite so total length is constant; clip's own In/Out unchanged. 4-up display. | Needs handles on neighbours. Linked partner moves; sync-locked tracks do not change length (no ripple). |
| Slip/Slide with arrows | `Opt+Left/Right` after selecting the clip (1 frame), with Shift (5 frames) | Same as drag. (unverified) | - |

Shortcuts: Slip Y, Slide U, Rate Stretch R, Ripple B, Rolling N [S3].

### 3.3 Trim mode (Trim Monitor)

| Action | Result |
|---|---|
| Double-click an edit point (cut) with Selection tool | Selects the edit and opens Trim mode: the Program monitor becomes two-up (outgoing left, incoming right) with -5, -1, +1, +5 buttons below and a jog area. Default is Ripple on the side nearest; a roll if both sides selected. |
| `Shift+T` | Toggle Trim mode for the selected edit (the T key itself is the Type tool; do not use T for trim mode) [(unverified key; S3 confirms T = Type tool)] |
| `Ctrl+T` | Cycle the trim type of the selected edit: ripple in -> ripple out -> roll -> back. Notice: S2 says it toggles through the options with each press. [S2] |
| In Trim mode, JKL | J / K / L play the incoming/outgoing side for a "loop" playback: K+L plays small loops around the edit; the edit then trims live as you press J/L? (unverified) |
| In Trim mode, `Left`/`Right` | Trim by 1 frame in the active type; `Shift` 5 frames (large trim offset). |
| Edit point selection with Shift+click on both sides | Roll. |
| Preference: "Select nearest edit point automatically" (Settings > Trim) | Selecting an edit by clicking near it picks roll or ripple per cursor position. [S2 "Auto-select"] |
| Escape / click empty | Exit Trim mode. |

### 3.4 Keyboard trims

| Key | Result |
|---|---|
| `Opt+Left` / `Opt+Right` with an edit point selected | Trim the selected edit(s) by one frame earlier/later in the current trim type (ripple or roll). [S2] |
| `Shift+Opt+Left/Right` | Five frames (adjustable). [S2] |
| `Cmd+Left/Right` | (task asked for these; no source found) possibly "trim previous/next edit by 1 frame" in some keymaps. (unverified) |
| `Q` | Ripple Trim Previous Edit to Playhead: the nearest edit LEFT of the playhead on the targeted track(s) moves to the playhead; the content to the right shifts left by the removed amount (head of the clip under the playhead is trimmed). [S2: "trim the In of a clip to the playhead"] |
| `W` | Ripple Trim Next Edit to Playhead: the clip's Out at the right edge moves back to the playhead, gap closes. [S2] |
| `E` | Extend Selected Edit to Playhead (non-ripple unless ripple selected). |
| Shift+Q / Shift+W | Non-ripple variants "Trim to playhead" (unverified mapping; default unassigned in many versions). |
| `Opt+Up/Down` | Move selected clip to another track (not trim). [S2] |
| Playhead after Q (Sequence Studio FEEDBACK-4 #20) | Premiere keeps the picture under the playhead: the playhead ends up at the new edit point. Treat as the rule for ripple-at-playhead edits. |

Edge cases for ripple trims:
- Q/W act on edits within the clips under the playhead on targeted tracks; if none targeted, on all tracks that have a clip there. Sync-locked tracks participate in the ripple.
- When the edit point lies on a track that has a clip with no more handle media, trimming beyond is clamped.

---

## 4. Tools

Source: S3 for keys; Adobe tools docs (unreadable); knowledge.

| Tool (key) | Click | Drag | Modifiers |
|---|---|---|---|
| Selection (V) | Select clip / gap / edge; click empty deselects | Move selected clips (overwrite); trim edges; marquee-select over empty area | Shift: add/remove selection; Cmd: ripple trim / insert move; Opt: copy-drag, or select one of linked pair. |
| Track Select Forward (A) | Selects the clicked clip and ALL clips to its right on that track | Marquee still works | Shift+click: every track from the click onward (all tracks); the other mode (Shift+A = Track Select Backward) selects to the left. [S3] |
| Track Select Backward (Shift+A) | Selects clip and all to the left | - | Shift: all tracks. |
| Ripple Edit (B) | See §3 | - | - |
| Rolling Edit (N) | See §3 | - | - |
| Rate Stretch (R) | See §3 | - | - |
| Razor (C) | Cuts the clip under the cursor at the click point on that track (and its linked partner) | - | Shift+click: cuts ALL tracks at that time (locked tracks excluded). Holding Opt toggles the razor to cut linked partner only? (unverified). Cuts snap to the playhead when snapping is on. |
| Slip (Y), Slide (U) | See §3 | - | - |
| Pen (P) | Click on a rubber band: add a keyframe (on clip opacity/volume or any displayed property) | Drag a keyframe vertically/horizontally; marquee selects keyframes | Cmd-click with Selection tool adds key without Pen. [S3 lists P] |
| Hand (H) | - | Pan the timeline horizontally (and vertically). In Program monitor: pans the zoomed view. | - |
| Zoom (Z) | Zoom in at the click | Drag a marquee to zoom to it | Opt+click zooms out. |
| Type (T) | Click in Program monitor: point text clip at the click, in the Graphics (MOGRT-like) workflow | Drag: area (box) text | See §9. [S9] |
| Rectangle/Ellipse (no default key) | - | Drag a shape in Program monitor | Shift constrains, Opt draws from centre. (unverified) |

Edge cases:
- Switching tools: pressing the key arms the tool; Premiere reverts to Selection after a one-shot "sticky" only if "Selection follows playhead" no. Tools stay armed (not one-shot).
- Pressing V returns to Selection. Spacebar always plays regardless of tool.
- Cursor over a clip with Razor armed cuts only where a clip exists; click in an empty region does nothing.

---

## 5. Source and Program monitors

Sources: S3, S7, S8, S10; Adobe monitors docs (unreadable).

### 5.1 Transport

| Action | Result |
|---|---|
| `Space` | Play/pause toward current direction (forward from stop). [S3] |
| `L` | Play forward at 1x; each additional press: 2x, 4x, 8x (higher in some builds). (unverified step table) |
| `J` | Play reverse at 1x, then 2x, 4x, 8x. [S3 for key; steps unverified] |
| `K` | Stop. [S3] |
| `K+L` / `K+J` held | Frame advance/reverse; keep both down for slow play (about 1/4 speed in older versions). Tap = single frame step. [S3] |
| `Shift+L` / `Shift+J` | Slow play forward/reverse (unverified). |
| `L` while playing in reverse | Decelerates one step (reverses direction at 1x). |
| Trackpad scroll over the monitor | Zooms/pans the picture when Hand tool armed? Plain scroll over a zoomed view pans it. (unverified) |

### 5.2 Marks, markers, buttons

| Action | Result |
|---|---|
| `I` / `O` | Set In / Out at playhead of the active monitor/panel (Source monitor focused: source marks; Program or Timeline focused: sequence marks). [S3] |
| `X` | Mark clip: In/Out = the clip under the playhead on the highest targeted track. |
| `/` | Mark selection (selected clips in the timeline). |
| `Opt+I` / `Opt+O` / `Opt+X` | Clear In / Out / both. (unverified) |
| `Shift+I` / `Shift+O` | Go to In / Out. |
| `M` | Add marker at the playhead; `M` again on the marker opens its dialog (name, comment, colour, duration); marker colours selectable. |
| Next/previous marker | `Shift+M` / `Cmd+Shift+M`. (unverified) |
| Marker on timeline vs clip | With a clip selected, `M` adds a clip marker; otherwise a sequence marker on the ruler. (unverified) |
| Insert / Overwrite buttons under Source monitor | Same as `,` and `.`; Insert uses patch state. |
| Lift / Extract buttons under Program | Same as `;` and `'`. |
| Export Frame button (camera) | Saves the current frame. |
| Button editor (+) | Customises which buttons show. |

### 5.3 View settings

| Item | Behaviour |
|---|---|
| Zoom menu | Fit, 10%, 25%, 50%, 75%, 100%, 150%, 200%, 400%. Fit is default. Scrollbars appear when zoomed beyond window. |
| Playback resolution | Full, 1/2, 1/4, 1/8, 1/16 (reduces decode cost). |
| Safe Margins | Overlay: action-safe 90%, title-safe 80% (configurable in Project Settings > General). Toggle in the wrench menu / button editor. (unverified percentages in 2025 builds) |
| Overlays | Timecode, clip name, etc. (newer). |
| Display timecode formats | Click the timecode to change units. |
| Timecode field | Type digits and Enter to jump (e.g. `123` = 00:00:01:23); `+10` relative. |

### 5.4 Direct manipulation (Motion)

| Action | Result |
|---|---|
| Select a clip and click the "Motion" label in Effect Controls (or double-click the clip image in the Program monitor, or the toggle button at the bottom-left of the Program monitor) | Bounding box with 8 handles appears around the clip; centre crosshair shows the anchor point. [S8] |
| Drag inside the box | Position changes by the pointer delta (value shown live in Effect Controls). Shift pressed BEFORE starting locks to the axis of the initial horizontal/vertical direction; pressed after, it locks at the current position. [S7] |
| Drag a corner handle | Scale (Uniform Scale on = proportional; off = width/height separate). Hold Shift to toggle uniformity (unverified), Opt to scale about the centre? (unverified; Premiere scales about the anchor point by default). |
| Drag an edge handle | Scale in one dimension only when Uniform Scale is off, else uniform. (unverified) |
| Move cursor just outside a corner | Cursor changes to a rotate arc; dragging rotates around the anchor point; Shift snaps to 45 degree steps (unverified). |
| Drag the anchor crosshair | Moves the anchor; to keep the picture still, Position compensates automatically only when Cmd? (unverified: in Premiere dragging the anchor in the monitor moves the anchor value and the image does not shift since position is unchanged, which visually shifts the image; check). |
| Smart guides (Premiere 22+) | Moving a layer shows pink/magenta guides snapping the box edges/centre to canvas centre/edges and to other layers; hold Cmd to temporarily disable. (unverified modifier) |
| Keyframes | If Position is animated (stopwatch on), dragging adds/modifies a keyframe at the playhead; with a motion path the path shows in the monitor with draggable Bezier handles. |
| Click empty canvas | Exits direct manipulation (deselects). |
| Hand tool in Program monitor | Pans the view only when zoomed; does not change clip values. |

Edge cases: when several clips overlap, double-click selects the topmost clip under the cursor; Cmd+click cycles? (unverified).

---

## 6. Effect Controls

Sources: S4, S5; Adobe effect controls docs (unreadable).

### 6.1 Fixed effects

| Effect | Properties |
|---|---|
| Motion | Position (x,y in sequence pixels), Scale (%), Scale Width (enabled when Uniform Scale off), Uniform Scale (check), Rotation (degrees, multi-turn "1x 30.0"), Anchor Point (x,y in clip pixels), Anti-flicker Filter (0-1). |
| Opacity | Opacity (0-100%), Blend Mode (drop-down), plus mask tools (ellipse, 4-point polygon, pen) and Opacity "Time" rendering (video: no keyframes on blend). |
| Time Remapping (video only) | Speed (percent, keyframable). Visible when the clip has speed changes or you open it; shows a stopwatch. |
| Audio clip fixed effects | Volume (Level), Channel Volume, Panner. |

Fixed effects exist on every clip; standard effects are listed under them in application order (top = first). Premiere applies standard effects before the fixed Motion/Opacity ones, regardless of list position, except where the list order shows otherwise (Lumetri on top). (unverified in current versions)

### 6.2 Stopwatch and keyframe navigation

| Action | Result |
|---|---|
| Click an OFF stopwatch | Animation is enabled; a keyframe is created at the playhead with the current value. |
| Click an ON stopwatch | All keyframes of that property are deleted after a confirmation alert ("This action will delete all keyframes..."); the property keeps the value at the current time as static value. [S4: "turns off all keyframes"] |
| Add/Remove Keyframe button (diamond, between the arrows) | Adds a key at the playhead if none; removes it if the playhead sits exactly on one. [S4] |
| ◀ / ▶ buttons | Jump the playhead to the previous / next keyframe of that property. [S4] |
| Edit a value while animated and the playhead is not on a key | A new keyframe is created at the playhead. |
| Edit a value while playhead is on a key | Updates that key. |
| Edit a value when stopwatch is off | Changes the single static value. |
| Click a key in the lane | Selects it (selected = highlighted). Shift-click: extend selection. Marquee in lane. [S4] |
| Drag a key horizontally | Changes time; vertical drag in the lane does nothing (the lane has no value axis; value editing is in the graph). Shift: snaps to the playhead? (unverified) |
| Delete / Backspace with key selected | Removes it. |
| Reset button (curved arrow at the row's right) | Restores the default value of the property; if animated, resets value at the playhead (keeps animation) per recent builds; older builds: resets all keys? (unverified; FEEDBACK-4 #7 asks for both variants) |
| Reset on a section (effect name row's reset) | Resets every property of the effect to defaults and removes its keyframes. |

### 6.3 Value scrubbing

| Action | Result |
|---|---|
| Drag across a blue numeric value (scrubby slider) | Value changes continuously; cursor shows left-right arrows. |
| Shift+drag | Faster: roughly 10x (unverified exact factor). |
| Cmd+drag | Finer/slower: roughly 0.1x (unverified). |
| Click the value | Becomes a text field; type, Enter commits; Tab commits and goes to next field; Esc cancels. |
| Dragging the slider (expanded property) | Same as scrubbing within min/max range. |
| Double-click the property name | Selects the row? no action. (unverified) |

### 6.4 Interpolation types

Set by right-clicking a key (Temporal Interpolation / Spatial Interpolation for Position) [S5].

| Type | Meaning | Handles | Typical icon (unverified; shapes differ by version) |
|---|---|---|---|
| Linear | Constant rate between keys, abrupt start/stop. [S5] | None | Diamond |
| Bezier | Curve with adjustable handles, each side independent. [S5] | Two independent | Round/half-round |
| Auto Bezier | Smooth curve through the key; handles adjust automatically when neighbours/values change. [S5] | Auto, none to drag (dragging converts to Continuous) | Circle |
| Continuous Bezier | Smooth through the key but you can drag handles; the opposite side mirrors direction to stay smooth. [S5] | Linked pair | Circle with tails |
| Hold | Value jumps at the next key; flat line afterwards. [S5] | None | Square-ish step glyph |
| Ease In | Slows approach into the key: sets the incoming side to a bezier ease. | - | Hourglass-left half |
| Ease Out | Accelerates away from key. | - | Hourglass-right half |

Notes: Ease In/Out are presets that produce Bezier handles. A key can have different types per side (e.g. Linear in, Bezier out): the glyph is a combination. When the glyph is half hourglass (ease) it spans both sides in a "bow-tie" shape when both sides eased (Paul's note: hourglass glyph for eased keys).

### 6.5 Value graph and velocity graph

| Aspect | Behaviour |
|---|---|
| Expand a property (twisty arrow to the left of the name) | A graph strip opens under the property row in the keyframe area. It shows the VALUE graph (value vs time) and, for properties with temporal interpolation, a VELOCITY (speed) graph below or beside (two views stacked in older versions). [S4: both graphs are shown] |
| Value graph | Y = property value, X = time; handles on Bezier keys change the shape; dragging a key vertically changes its value. |
| Velocity graph | Y = rate of change (units/s), X = time; each key has a speed handle; the area under the curve = total value change. Dragging the speed handle changes ease; dragging the "influence" handle sets how far the ease reaches. [S5: "velocity graph adjusts rate of change before/after key"] |
| Mapping of mouse to velocity handle | Horizontal drags change influence (0-100%), vertical drags change speed. In Premiere both can happen at once (FEEDBACK-4 #5 asks for axis lock). |
| Graph height | Draggable divider at the bottom of the row, min ~40 px. |

### 6.6 Mini timeline in Effect Controls

| Part | Behaviour |
|---|---|
| Time ruler | At the TOP of the keyframe area, aligned with the timeline's scale for the selected clip's range (shows clip start/end); shows timecode for the clip's sequence time. |
| Clip bar | Thin bar under the ruler showing the clip's extent; trimmed regions greyed. |
| Playhead | Same playhead as the sequence: click/drag in the ruler to move it; shows blue line through keyframe lanes; sequence time shown bottom-left of the panel. |
| Zoom | Navigator scrollbar at the bottom with round handles; drag the handles to zoom, middle to pan; wheel/trackpad zoom as in timeline. [S4 + FEEDBACK-4] |
| Shift+drag playhead | Snaps to keyframes. [S4] |
| Left/right divider | Draggable splitter between property names/values and keyframe lanes; remembered. Hidden when no clip is selected (Sequence Studio rule). |

### 6.7 Copy/paste and order

| Action | Result |
|---|---|
| Select keys, Cmd+C, move playhead, Cmd+V | Pastes at the playhead; first copied key lands at the playhead, relative spacing preserved. Pastes onto the same property type of the selected property/clip (select the target property row or clip). |
| Paste to a different clip | Select target clip, select the property row (or whole effect), Cmd+V: the keys go to the clip's property at the playhead (clip-local time). |
| Copy an effect (click effect name, Cmd+C) and paste on another clip | Copies all property values and keys; pasting onto the destination appends the effect at the end of its list; Paste Attributes (Cmd+Opt+V) dialog: choose Scale attribute times (stretch keyframes to fit duration), Video effects, Audio effects. |
| Drag an effect header up/down | Reorders it among standard effects (not Motion/Opacity? they can be dragged relative to standard effects in newer builds: yes, fixed effects can move below standard ones since 2022 - unverified). |
| Eye/"fx" toggle at the effect row | Bypass the effect. |
| Right-click effect name: Remove Effect / Delete | Removes. |
| Cmd+click or Shift+click effect names | Multi-select to copy together. |

---

## 7. Lumetri Color

Sources: S6 (search snippet), Adobe Lumetri docs (unreadable), community processing-order threads; ranges from knowledge (unverified unless stated).

### 7.1 Section order (top to bottom) and processing order

Panel order: Basic Correction, Creative, Curves, Color Wheels & Match, HSL Secondary, Vignette (newer builds add a Settings tab for UI options and scope settings; older builds had Basic, Creative, Curves, Color Wheels, HSL Secondary, Vignette). [S6]

Processing order: top-to-bottom within a tab and tab-to-tab, with these exceptions. [community.adobe.com "stacking Lumetri" snippet, confirmed:]
- Input LUT (top of Basic) is the very first step, before the Basic sliders.
- In Basic Correction, the White Balance tool is processed last, not first.
- Hue/Sat curves are processed after RGB curves and take the RGB result as input.
Sequence Studio's current order (Basic sliders -> Input LUT -> Creative -> Curves -> Wheels -> Vignette) intentionally differs for Paul (FEEDBACK-4 #13). In Premiere the Input LUT is before the sliders.

### 7.2 Basic Correction

| Control | Range / default (unverified except where noted) |
|---|---|
| Input LUT drop-down | None, built-ins, Browse..., Add LUT; applies a technical (camera log to Rec.709) LUT before adjustments |
| HDR White | (HDR sequences only) |
| White Balance selector (eyedropper) | Click a neutral pixel in the Program monitor; sets Temperature+Tint |
| Temperature | -100 (blue) .. +100 (orange), default 0 |
| Tint | -100 (green) .. +100 (magenta) |
| Exposure | -5.0 .. +5.0 stops |
| Contrast | -100..100 |
| Highlights | -100..100 |
| Shadows | -100..100 |
| Whites | -100..100 |
| Blacks | -100..100 |
| HDR Specular | HDR only |
| Saturation | 0..200, default 100 |
| Auto button | Applies auto levels |
| Reset button | Back to defaults (section) |
| Intensity (Look) | Not here; see Creative. (Paul's FEEDBACK mentions Basic "Intensity"; newer builds may have it) |

### 7.3 Creative

| Control | Range |
|---|---|
| Look drop-down | None, built-in Creative looks (SpeedLooks, etc.), Browse. Thumbnail preview with prev/next arrows. |
| Intensity | 0..100, default 100 |
| Faded Film | 0..100 |
| Sharpen | -100..100 |
| Vibrance | -100..100 |
| Saturation | 0..200 |
| Shadow Tint wheel / Highlight Tint wheel | Hue/amount |
| Tint Balance | -100..100 |

Look (Creative LUT) is applied AFTER Basic correction. Input LUT vs Creative Look: Input LUT = technical conversion before corrections; Look = aesthetic grade after corrections with Intensity blend. Sequence Studio's "Input LUT" should always be before basic.

### 7.4 Curves

- RGB Curves: master curve with channel selectors (white = Master, red, green, blue dots); click on curve adds a point, drag to move, double-click or drag off removes.
- Hue Saturation Curves: Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat; eyedropper sets points to a sampled colour.

### 7.5 Color Wheels & Match

- Shadows, Midtones, Highlights wheels with a luma slider for each (-100..100) and a colour puck; double-click resets.
- Colour Match: Apply Match with Face Detection; Comparison View (side-by-side reference frame).

### 7.6 HSL Secondary

Key: Set colour eyedropper (hue, saturation, luminance range with sliders), Color/Gray view, Invert, Denoise, Blur; Refine; Correction: Temperature, Tint, Contrast, Sharpen, Saturation, plus Colour wheels for the keyed region.

### 7.7 Vignette

Amount -5..5, Midpoint 0..100, Roundness -100..100, Feather 0..100.

### 7.8 Toggle / reset / multiple instances

| Item | Behaviour |
|---|---|
| Each section header has an enable checkbox/toggle | Disables just that section (bypass). [Paul reference screenshots] |
| Reset | Per-section reset arrow (in the Lumetri panel header) and an Effect-level Reset in Effect Controls. (unverified) |
| Multiple Lumetri effects | The panel always edits ONE instance (the first / chosen via the effect picker above the panel); to stack, drag Lumetri Color from the Effects panel onto the clip or onto an adjustment layer; order = Effect Controls order, top to bottom. [community snippets] |
| Order in effect list | Dragging an instance up/down changes processing order. |
| Lumetri Presets / saved looks | Stored as .look / .cube. |
| Scopes | Lumetri Scopes panel: Waveform (RGB, Parade, Luma, YC, YC no chroma), Vectorscope (YUV, HSL), Histogram, RGB Parade, YCbCr Parade; Audio meter not part; settings: Brightness, colour space (Rec.709/2020/HDR), Auto-show scopes. |

---

## 8. Audio

Sources: Adobe audio docs (unreadable); S3 for `[` `]` gain keys (listed); knowledge.

| Action | Result |
|---|---|
| Clip volume | Effect Controls > Audio > Volume > Level (dB, -inf..+15 dB); also rubber band in the clip. Baked into the clip, per clip. |
| Track volume | Audio Track Mixer fader (and "Write/Read" automation modes: Off, Read, Latch, Touch, Write). Per track, applied after clip effects. |
| Master | Master meter/fader in Mixer; final level. |
| Rubber band on audio clip | A horizontal line over the waveform; drag it up/down to change level for the whole clip (no keys) in the Selection tool, drag a segment between two keys changes both. |
| Add key on rubber band | Cmd+click with the Selection tool (Ctrl on Windows) or click with the Pen tool. Drag key up/down for level and left/right for time (cannot cross neighbours). Right-click key: remove/ease options. |
| Show clip vs track keyframes | Header menu / fx badge right-click: Show Clip Keyframes / Show Track Keyframes. |
| Gain dialog `G` | Dialog: Set Gain to (dB), Adjust Gain by (dB), Normalize Max Peak to (dB), Normalize All Peaks to (dB). Applies to selected clips; relative to clip's original level; separate from Volume. (unverified detail; key `G` confirmed from knowledge) |
| `[` / `]` | Reduce / raise audio gain of selected clips by 1 dB; with Shift, 6 dB. [S3: "adjust gain"] |
| Audio meters | Vertical meters at the right of the timeline (dock panel): -infinity to 0 dBFS; clip indicator (red) at top latched until clicked; solo icons below; right-click: Show/hide channels, switch dB/ sample peak vs program loudness. Peak colours: green, yellow above -12, red at 0. |
| Mute / Solo | `M` button on a track header mutes it; `S` button solos (note: keys M and S are marker/snap on the keyboard; buttons only). Soloing mutes all non-solo tracks. |
| Audio scrubbing | Dragging the playhead in the ruler plays audio at the scrub speed; toggle in Preferences > Audio / the Program monitor's Timeline settings: "Audio scrubbing" (Timeline panel wrench menu). |
| Linked A/V | Cmd+L link/unlink. Click either side selects both (when Linked Selection on); Opt+click selects only that side. Moving, trimming, razor, deleting apply to both. |
| Audio vs video edit mismatch | If only one side is moved, an out-of-sync badge shows the frame offset (red). |
| Waveform | Draw shape per channel; mono tracks have separate rows; display as Rectified is a panel option. |

---

## 9. Text and graphics

Sources: S9; Adobe Essential Graphics docs (unreadable).

| Action | Result |
|---|---|
| Click with the Type tool in the Program monitor | Creates Point Text (text-on-a-point; no box; grows with text; a new graphic clip appears on the first video track above existing content at the playhead). [S9] |
| Drag with the Type tool | Creates Area (box) Text; text wraps inside the box; justification options work within the box. [S9] |
| New clip duration | The default duration is the preference for still images (Settings > Timeline > Still Image Default Duration, 5 s by default), the clip is placed at the playhead on the lowest unlocked video track that is free above the clip? (unverified track choice). |
| Edit text | Double-click the text with the Type tool in the Program monitor, edit in place; Esc / click outside commits; text clip's properties live in Essential Graphics > Edit tab (layers panel + font, size, tracking, fill, stroke, shadow, background). [S9] |
| Essential Graphics panel | Browse tab (templates) and Edit tab (layers list, Responsive Design Time and Position, Align and Transform, Text, Appearance). Layer order = z order. Select a layer then drag in Program monitor. |
| Text template drag | Dragging a template onto the timeline creates a graphic clip with the template's default duration. [S9] |
| Captions workflow | Window > Text panel > Transcript tab: Transcribe sequence (pick language, track) -> editable transcript with speakers -> Create captions (dialog: caption stream/format e.g. Open Captions / CEA-608 / Subtitle, max characters per line, minimum duration, gap between captions, lines: single/double) -> a captions track is added above/below the tracks with caption clips editable in Captions tab; export captions as sidecar or burn in. |
| Caption clips | Selecting one shows its text and timing in the Text panel > Captions tab; split/merge buttons; dragging edges changes timing; stylisation via Essential Graphics (Caption style). |

---

## 10. Project panel and bins

Sources: Adobe project panel docs (unreadable); knowledge (all unverified unless stated).

| Action | Result |
|---|---|
| List view | Rows with columns (Name, Frame Rate, Media Start/End, Media Duration, Video In/Out, Label, etc.); column set chosen from the panel menu "Metadata display"; click header sorts. |
| Icon view | Thumbnails with names; slider at bottom changes size. |
| Freeform view | Free arrangement of thumbnails (storyboard); arrange by dragging. |
| Hover scrub | Enable in the panel menu (Hover Scrub): moving the mouse over a thumbnail scrubs it without clicking; Shift+hover (while hovering) toggles hover scrub temporarily; clicking and `I/O` sets in/out directly in the thumbnail (Set In/Out via the thumbnail). |
| Sequence from clip | Drag a clip onto the New Item button (or right-click clip > New Sequence From Clip): creates a sequence with the clip's frame size, rate, audio config. |
| Dropping a clip into an empty timeline | Also creates a matching sequence (prompt if settings mismatch: "Change sequence settings" in older versions). |
| Labels | Right-click item > Label: choose colour; label colours shown on bins/clips and on timeline clips by default. |
| Bins | `Cmd+B` new bin; drag media into it; double-click opens bin in-place or in a new panel per Preferences; Cmd+double-click opens in new window. |
| Search | The filter field narrows the current bin (name/label/metadata) live; `Cmd+F` Find dialog; Find Bin / "Search in all bins (check Search Bins)": When you type in the filter, items from all subbins show; the toggle that restricts to the current bin exists in newer builds. |
| Smart bins | Find dialog "Create new smart bin" with saved criteria. |
| Delete | Removing from the project does not delete files; clips used in sequences prompt. |
| Offline media | Question-mark thumbnail; Link Media... |

---

## 11. Workspaces and panels

Sources: S10 for the grave key; Adobe workspace docs (unreadable); knowledge.

| Action | Result |
|---|---|
| Drag a panel by its tab | Ghost outline and drop zones appear: centre of another panel's area (tab group), edges of a panel or group (split docking: new panel takes that side), outside area (floating window). |
| Drop on the tab strip | Inserts into the tab group at that position. |
| Drag a panel's grabber (the dotted handle at its top-left) | Moves the whole group. |
| Drag Cmd+? on a panel tab | Float without docking (hold Cmd to prevent docking? - Command key disables snapping to drop zones; unverified). |
| Drag the divider between panels | Resizes both neighbours; double-click? None. Min size enforced; Cmd/Opt-drag adjusts all three (cross-divider group) (unverified). |
| `` ` `` (accent grave, left of 1) | Hover any panel and press: maximise that panel to the full window; press again to restore. [S10] |
| Window > Workspaces > Reset to Saved Layout | Restores the active workspace's saved panel layout (undoes docking/resizing changes). |
| Window > Workspaces > Save as New Workspace | Prompts for a name; stores current panel arrangement as a new workspace tab in the workspace bar. |
| Edit Workspaces / Delete | Reorder, rename, delete. |
| Workspace bar | Click a name to switch; the bar shows overflow menu. Right-click for Reset. |
| What switching preserves | Panel arrangement only (docking, sizes, which tabs are open). Does NOT change the open project, sequence, selection, playhead, undo history, Source monitor contents. Panel-internal view settings (zoom levels, column choices) are not part of a workspace. |
| Changes you made to a workspace | Premiere remembers them when you switch away and back (workspace auto-updates) unless you use Reset to Saved Layout; the saved layout is the last "Save Changes to this Workspace" state. (unverified) |
| Import workspace | From project, or `.prlayout` files. |

---

## 12. Export

Sources: Adobe export docs (unreadable; search snippets only: Quick Export vs Export mode exist as separate paths).

| Action | Result |
|---|---|
| Quick Export (button at top-right of the app, or via `Cmd+Opt+M`? unverified) | A small popover: file name, location, preset (the choice is remembered: e.g. "Match Source - H.264"), Export button; exports the active sequence using its In/Out range if set. |
| `Cmd+M` (File > Export > Media) | Opens full Export mode (tab page): left = source preview + range; right = settings. |
| Export mode layout | Left column: file name, location, preset list (Match Source, YouTube, Vimeo, etc.); Video / Audio / Captions / Effects / Metadata / Publish tabs; a preview with Source/Output tabs and Source Range: Entire Sequence, Sequence In/Out, Work Area, Custom. |
| In/out range | Sequence In/Out marks are honoured when "Sequence In/Out" is chosen (default if set). |
| Match Sequence Settings checkbox | Uses the sequence's frame size, rate, aspect; unchecking enables custom values. |
| Presets | Match Source - High bitrate / Adaptive, plus format presets (H.264, HEVC, ProRes, DNxHR). |
| Queue vs Export | "Queue" sends to Adobe Media Encoder; "Export" encodes in Premiere. |
| Use Maximum Render Quality / Previews | Reuse sequence preview files option. |
| Metadata, captions | Choose burn-in vs sidecar (SRT) in the Captions tab. |

---

## 13. Default keyboard shortcuts (macOS)

Confirmed via S2/S3 where marked [S], rest unverified against Adobe's list (which could not be fetched).

### 13.1 Tools

| Key | Tool |
|---|---|
| V | Selection [S] |
| A / Shift+A | Track Select Forward / Backward [S] |
| B | Ripple Edit [S] |
| N | Rolling Edit [S] |
| R | Rate Stretch [S] |
| C | Razor [S] |
| Y | Slip [S] |
| U | Slide [S] |
| P | Pen [S] |
| H | Hand [S] |
| Z | Zoom |
| T | Type [S] |

### 13.2 Playback

| Key | Action |
|---|---|
| Space | Play/stop [S] |
| J, K, L | Reverse, stop, forward [S] |
| K+J / K+L | Single-frame back/forward [S] |
| Left / Right | Frame back/forward [S] |
| Shift+Left/Right | 5 frames [S] |
| Up / Down | Previous / next edit |
| Home / End | Sequence start / end [S] |
| Shift+I / Shift+O | Go to In / Out |
| Cmd+Left / Cmd+Right | Previous / next keyframe?? (unverified; not found) |
| Shift+Space | Play around / loop? (unverified) |
| Ctrl+L | Loop playback toggle |

### 13.3 Timeline and editing

| Key | Action |
|---|---|
| S | Snap toggle [S] |
| = / - | Timeline zoom in / out [S] |
| \ | Fit sequence [S] |
| Cmd+K | Add Edit [S] |
| Shift+Cmd+K | Add Edit to All Tracks |
| , / . | Insert / Overwrite |
| ; / ' | Lift / Extract |
| Delete / Shift+Delete | Delete / Ripple Delete |
| Q / W | Ripple trim previous / next edit to playhead [S] |
| E | Extend selected edit to playhead |
| Ctrl+T | Cycle trim type [S] |
| Shift+T | Trim mode (unverified) |
| Opt+Left/Right | Nudge / trim by 1 frame [S] |
| Shift+Opt+Left/Right | By 5 frames [S] |
| Opt+Up/Down | Move clip to another track [S] |
| Cmd+L | Link / unlink [S] |
| Cmd+G | Group [S] |
| F / Shift+R | Match frame / Reverse match frame |
| X | Mark clip |
| / | Mark selection |
| I / O | Mark In / Out [S] |
| M | Add marker |
| Cmd+R | Speed/Duration |
| Cmd+Z / Cmd+Shift+Z | Undo / redo [S] |
| Cmd+C/X/V | Copy/cut/paste [S] |
| Cmd+Opt+V | Paste attributes |
| Cmd+Shift+V? | Paste insert (unverified: Cmd+Shift+V = Paste Insert) |
| Cmd+B | New bin |
| Cmd+F | Find |
| Cmd+/ | Insert (in older keymaps) (unverified) |
| Cmd+A | Select all |
| Cmd+Shift+A | Deselect all |
| Cmd+D | Apply default transition |
| Shift+Cmd+D | Apply default audio transition |
| Cmd+Shift+/ | Context? (unverified) |
| G | Audio gain dialog |
| [ / ] | Gain -1 / +1 dB [S] |
| Cmd+= / Cmd+- | Video track height (unverified) |
| Opt+= / Opt+- | Audio track height (unverified) |
| Shift+- / Shift+= | Minimise / expand all tracks |
| ` | Maximise panel under cursor [S10] |
| Cmd+S | Save [S] |
| Cmd+M | Export Media [S] |
| Shift+5 | Effect Controls panel [S] |
| Shift+7 | Effects panel [S] |
| Cmd+Shift+T | New title [S] |
| Enter | Render In to Out (render effects) |
| Cmd+Shift+... | Opt+Cmd? None. |

---

## 14. Speed/duration, nesting, adjustment layers, render bars

Sources: S11 (render bars); rest knowledge.

### 14.1 Speed/Duration (Cmd+R)

| Control | Result |
|---|---|
| Speed % | Percent of normal; 100% default; changes duration inversely. Range roughly 1%..10000% (unverified). |
| Duration | Timecode; linking (chain icon) ties it to speed; unlinking changes only one (changes duration by trimming instead, as it uses Fit-to-Fill). |
| Reverse Speed | Plays backward. |
| Maintain Audio Pitch | Keep original pitch while time-stretching audio. |
| Ripple Edit, Shifting Trailing Clips | Later clips shift to absorb the length change (otherwise the clip overwrites or leaves a gap). |
| Time Interpolation | Frame Sampling, Frame Blending, Optical Flow. |
| Applies to | All selected clips; linked audio is affected too. Speed < 100% needs spare tail? When the clip gets longer it extends into the gap/overwrites the next clip unless ripple is checked. |

### 14.2 Time remapping

| Action | Result |
|---|---|
| Right-click the clip's `fx` badge > Time Remapping > Speed | Shows a speed rubber band on the clip (also in Effect Controls). Raise the band to speed up, lower to slow down (e.g. 200%, 50%). |
| Cmd+click the band (or Pen click) | Adds a speed keyframe (a divided marker). |
| Drag a half of a split keyframe horizontally | Makes a speed ramp between the two halves (Opt+drag the keyframe to create the ramp split). |
| Drag the ramp's blue bezier handle | Eases the ramp. |
| Time remap (Time Remapping > Speed in Effect Controls) | Stopwatch controls the same data; speed graph in Effect Controls. |
| Clip length | Changes with speed key edits because source frames are consumed differently; the clip tail extends; neighbours get overwritten unless space. |

### 14.3 Nesting

| Action | Result |
|---|---|
| Right-click selected clips > Nest | Replace them with one nested sequence clip (named `Nested Sequence 01`), using the current sequence as basis; clip keeps position; double-click opens it in its own timeline tab. |
| Edit inside the nest | Changes propagate to every instance in other sequences. |
| Nest on a tracks selection | Audio and video of the same range go into the nest. |
| Nest toggles | "Nested Sequence Selection Follows Playhead" etc. (unverified) |

### 14.4 Adjustment layers

| Action | Result |
|---|---|
| Project panel > New Item > Adjustment Layer | Creates a transparent item with sequence frame size; drag it to a video track above the clips. |
| Effects on an adjustment layer | Apply to all video tracks below it for its duration (clipping at its edges); opacity/blend mode apply to its output. Uses stack order. |
| Move/trim the layer | Changes extent of the effect. |
| Multiple adjustment layers | Evaluated bottom to top. |

### 14.5 Render bar (sequence ruler strip)

| Colour | Meaning | Result |
|---|---|---|
| Red | Needs rendering for smooth real-time playback | Enter / Sequence > Render In to Out creates preview files. [S11] |
| Yellow | May play in real time; render to be sure. [S11] | Rendering turns it green. |
| Green | A preview file exists and plays smoothly. [S11] | Preview files are invalidated when the clip changes (green returns to yellow/red). |
| No bar | Plays in real time without rendering. | - |

---

## Gaps vs Sequence Studio

Judgement based on STATUS.md/FEEDBACK-4.md as read (first ~170 lines of STATUS, all of FEEDBACK-4), not on code. Most valuable first.

1. Source patching vs track targeting as two independent concepts per track (Insert/Overwrite use patches; Cmd+K, paste, lift/extract and ripple use targets; drag-drop ignores both). STATUS only mentions lock/sync lock; confirm the model has patches and targets.
2. Insert/Overwrite/Lift/Extract and three/four-point editing, with Fit-to-Fill dialog and Source monitor In/Out (STATUS lists "Source monitor (M-02)" as Next, so Source monitor-driven edits are missing).
3. Linked Selection toggle plus Opt+click to pick one side, out-of-sync badge with frame offset and Move/Slip into Sync.
4. Program-monitor direct manipulation (Motion handles, rotation outside corners, Shift axis lock before drag, anchor drag, smart guides): FEEDBACK-4 #12, #23.
5. Trim mode panel (two-up monitor, -5/-1/+1/+5, Ctrl+T type cycling, double-click edit) and Opt+arrow keyboard trims; Q/W exist, Opt+arrow/Shift+Opt+arrow unconfirmed.
6. Keyframe editor parity: stopwatch-off confirmation alert, reset-at-playhead vs reset-all, velocity graph handles with axis lock, ease in/out glyphs, ruler at top, zoom scrollbar (FEEDBACK-4 #1-8, #14).
7. Timeline zoom/height shortcuts: `\` fit toggle, Opt+scroll zoom, Shift-drag all heights, Shift+-/Shift+= minimise/expand, Cmd/Opt +/- for video/audio track heights, V/A divider.
8. Playhead snapping with Shift for scrubbing and Effect Controls keyframe snapping (FEEDBACK-4 #17 partly done in C1 for the timeline only).
9. Replace edit, Match Frame (F) and Reverse Match Frame, Extend Edit (E), Add Edit to All Tracks (Shift+Cmd+K), Paste Insert/Paste Attributes.
10. Speed/Duration dialog (Cmd+R) with ripple option, time remapping speed ramps via rubber band, Optical Flow (Frame Blending), render bars (red/yellow/green) and Render In to Out.
11. Hover scrub and Sequence-from-clip in the Project panel; Freeform view; Smart bins.
12. Audio: Gain dialog (G), `[`/`]` gain keys, rubber-band keys with Cmd-click, track mixer automation (Latch/Touch/Write), audio scrubbing toggle.
13. Lumetri parity: Input LUT first in processing order (Paul asked for the opposite - open decision), White Balance applied last, HSL Secondary maths, WB eyedropper, Hue/Sat curves, Sharpen, Tint wheels. Colour effect not yet shown in Effect Controls.
14. Workspaces: Reset to Saved Layout, Save as New Workspace, maximise panel with the grave key (check if built), multi-instance Lumetri via Effects panel.
15. Pen/Shape/Mask tools: scope addition, slots reserved (FEEDBACK-4 #27).
16. Type tool point vs area text and in-place editing in the Program monitor (FEEDBACK-4 #11, #26: text render wiring).
17. Export: Quick Export popover vs full Export mode, source range selector (Entire/In-Out/Work Area/Custom), Match Sequence Settings.
18. Hand tool/trackpad pan-zoom in Program monitor (FEEDBACK-4 #15).
19. Captions: Transcribe wiring (FEEDBACK-4 #22), create-captions dialog with max chars, min duration, gap, lines.
20. Marker dialog and next/previous marker navigation, Mark Clip (X) with targeted-track rule.
