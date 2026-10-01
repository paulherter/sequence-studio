# Audit: timeline and edit operations (stream `timeline`)

Sources: `docs/PREMIERE-BEHAVIOR.md`, the mirrored Adobe keyboard-shortcut table (`docs/reference/adobe/keyboard-shortcuts.txt`, macOS column; used for every key below), working knowledge. "unverified" = behaviour not confirmed from a source.

| Feature | Premiere | Sequence Studio before | Gap | Done tonight? |
|---|---|---|---|---|
| Click / Shift-click / marquee select | Click selects clip (+ linked partner), Shift toggles, drag on empty = marquee | Had it | none | already |
| Linked Selection toggle | Header button, default on; Option-click inverts per gesture | Flag existed, no UI | No button, no menu | Yes: chain button in the ruler corner, Sequence menu "Linked Selection" (checkmark). Option-click inversion existed |
| Option-drag duplicates | Copy lands at drop, originals stay | Missing | Missing | Yes (`Timeline.move(copy:)`, one undo step "Copy Clip(s)", copies become the selection) |
| Delete / Shift+Delete | Clear (lift) / Ripple Delete | Had it | none | already |
| Click on gap, Delete closes it | Gap selectable, Delete = ripple delete | Missing | Missing | Yes (gap highlight, Delete or Shift+Delete, right-click gap menu "Ripple Delete"; extract on that track + sync-locked tracks) |
| Edge select, Cmd = ripple trim | Click edge selects it; Cmd-drag ripples | Edge drag only, no Cmd | Missing | Yes (edge highlight bar; orange = ripple) |
| Rolling via Selection tool | Select both sides (Shift-click) then drag | Missing (only N tool) | Missing | Yes. Note: brief said "Cmd on an edit point = rolling"; Premiere's Cmd is ripple, rolling is both sides selected |
| Ripple (B), Rolling (N), Slip (Y), Slide (U) tools | yes | Had them | none | already |
| Rate Stretch (R) | yes | Missing | Needs speed model | No |
| Trim cursors per kind | trim in/out, ripple in/out, roll, slip, slide | Per tool, not per modifier | Cmd does not swap the cursor to ripple | No (cursor rects cannot follow modifiers; needs flagsChanged tracking) |
| Keyboard trim of selected edit | Opt+Left/Right 1 frame, Opt+Shift+Left/Right 5 frames (verified) | Missing | Missing | Yes. Opt+Left/Right is also bound to keyframe nav (other stream): with an edge selected it trims, otherwise falls through |
| Nudge clip selection | Cmd+Left/Right 1 frame, Shift+Cmd 5 frames (verified) | Missing | Missing | Yes (group moves as one, overwrite semantics, clamps at 0) |
| E Extend selected edit to playhead | E | Command existed, unsupported | Missing | Yes (trim / ripple / roll per edge selection) |
| Q / W ripple trim to playhead | yes | Had it | none | already |
| Razor C, Shift = all tracks | yes | Had it | none | already |
| Cmd+K / Shift+Cmd+K | Add edit on targeted tracks / all | Had it (selected clips' tracks, else targeted, else all) | none | already |
| Track targeting | Toggle per track | Chip on header, one flag | no Shift/Opt variants | No |
| Source patching | Separate from targeting, per source channel | Not modelled (Insert uses targeted/default tracks) | Missing concept | No (needs source monitor model) |
| Track lock / eye / mute / solo | yes | Had it | none | already |
| Sync lock | Per track toggle, ripple affects `targeted ∪ syncLocked − locked` | Model + ripple logic had it, no toggle | No UI | Yes (header button on hover, always shown when off) |
| Snap toggle S | S, magnet button | Key only | No button | Yes (button in the ruler corner, menu checkmark) |
| Playhead: Up/Down edit points | Targeted tracks; Shift+Up/Down any track | All tracks only | Targets ignored | Yes |
| Home/End, Shift+Left/Right 5, I/O, X, Opt+X | yes | Had it | none | already |
| `/` Mark selection | yes | Missing | Missing | Yes |
| D select clip at playhead, Cmd+A, Shift+Cmd+A | yes | Missing | Missing | Yes |
| Track Select Backward (Shift+A) | yes | Mapped to forward | Wrong direction | Yes |
| Context menu: clip | Cut Copy Paste, Paste Insert, Clear, Ripple Delete, Link/Unlink, Nest, Label, Rename, ... | Cut/Copy/Paste/Link/Rename were disabled, dead entries Enable/Speed/Reveal | Clipboard missing | Yes: working Cut, Copy, Paste, Paste Insert, Clear, Ripple Delete, Link/Unlink, Nest, Set/Scale to Frame Size, Label submenu, Rename. Dead entries removed |
| Clipboard | Cmd+C/X/V, Cmd+Shift+V insert paste; paste goes to targeted track at playhead | Missing | Missing | Yes (`TimelineClipboard`, lane-based, links kept between copies) |
| Link / Unlink | Cmd+L | Unsupported | Missing | Yes (toggle) |
| Context menu: gap, empty track | Ripple Delete / Paste | none | Missing | Yes |
| Context menu: track header | Add Track(s), Delete Track(s), Rename | none | Missing | Yes (Add Video/Audio Track, Delete Track, Rename) |
| Context menu: ruler | Add marker etc. | none | Missing | Yes (Add Marker, Edit/Delete Marker, Clear In and Out) |
| Group / Ungroup, Enable (Shift+Cmd+E), Speed/Duration (Cmd+R), Paste Attributes | yes | not modelled | features missing | No; "Group" removed from Clip menu (was a dead entry) |
| Reveal in Project | yes | disabled entry | needs Project panel API | No; entry removed |
| Markers: M, M again = dialog | yes | M always added | Duplicates, no dialog | Yes (name, colour, comment, Delete Marker) |
| Marker model | name, colour, comment, duration | name only | format | Yes (`Marker.color/comment/duration`, old files decode with defaults; Markers panel rows read them) |
| Double-click marker in ruler | opens marker dialog | Missing | Missing | Yes |
| Shift+M / Shift+Cmd+M next / previous marker | verified | Missing | Missing | Yes |
| Marker duration UI, drag marker, clip markers | yes | - | - | No |
| Gap/edge selection and sync-lock detail for locked tracks | refuses edit | SQCore refuses | none | already |

## Left open
- Rate Stretch, source patching, Group, Enable, Speed/Duration, Paste Attributes, Duplicate (Shift+Cmd+/).
- Cmd-hover ripple cursor, Option-hover copy cursor.
- Multi-edge trims across tracks by keyboard use one edit per edge in order, not one atomic multi-track trim.
- Opt+Left/Right edge trim shares keys with the keyframe commands (decision for the keyframe stream).
