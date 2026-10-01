# Job C: command, shortcut and menu parity audit

Read-only audit by reading code (no Mac, nothing run). Files read: `CommandMap`, `MenuSpec`, `EditorCommand`, `KeyRouter`,
`TimelineContextMenu` (SQEditorUI); `MenuBuilder`, `KeyMapping`, `KeyboardShortcutsWindow`, `AppController`,
`AppController+Commands/+Shell/+TimelineOps/+EffectControls`, `EditorPanels` (+Markers, +TrackMenu), `SourceMonitor` (App/Sources);
context menus in the Project panel. Compared with `docs/spec/*.md`, `docs/audit/shell.md`, `docs/PREMIERE-BEHAVIOR.md`.
Line numbers are for the tree this branch was cut from. Everything here is "by reading": items marked *verify* need a Mac.

Ranked most valuable first. S/M/L = fix size.

## A. Bugs (shortcut or menu does the wrong thing)

### A1. Scoped shortcuts are global as soon as they have a menu item (M)
`CommandMap` scopes (`timeline`, `program`, ...) only apply to key events that reach `KeyRouter`. But
`AppController.handle` (`AppController.swift:~511`) returns every key with Command to the menus
("Command shortcuts belong to the menus"), and `MenuBuilder.menuItem` installs the binding as a plain key equivalent
with no scope. So every Command-modified timeline binding fires from any panel and from text fields:

| Key | Command | Effect when focus is elsewhere |
|---|---|---|
| Cmd+A / Shift+Cmd+A | Select All / Deselect All | In a text field (rename, marker dialog, search, timecode box) it selects/deselects **timeline clips** instead of the text. `validateMenuItem` (`AppController.swift:477`) whitelists only cut/copy/paste/delete for text fields, and `forwardToText` (`AppController+Commands.swift:~212`) has no `selectAll`. In the Project panel it selects timeline clips, not project items. |
| Cmd+K / Shift+Cmd+K | Add Edit (all tracks) | Cuts the timeline while the Source monitor or Project panel has focus. |
| Cmd+L | Link | Links timeline clips while another panel has focus. |
| Cmd+R | Speed/Duration | Same. |
| Cmd+= / Cmd+- | Video track height | Same (harmless, but not scoped). |

Fix: in `validateMenuItem`, disable scoped commands when the focused panel's scope is not the command's scope (add
`CommandMap.scope(of:)`), and add `.selectAll`/`.deselectAll` to `forwardToText` (`tv.selectAll(nil)`) and to the text-field
whitelist. AC (unit-testable): a pure `func isEnabled(_ c: EditorCommand, focus: PanelID?, typing: Bool) -> Bool` in
SQEditorUI; selectAll with `typing == true` is routed to text, with focus `.project` it is not a timeline command.

### A2. Nudge shortcuts are dead (S)
`Cmd+Left/Right` (nudge 1 frame) and `Shift+Cmd+Left/Right` (nudge 5) are bound (`CommandMap.swift:~105`) and implemented
(`AppController+TimelineOps.swift:44-47`), but no menu has `.nudgeLeft/.nudgeRight/...` (`MenuSpec.swift`). Keys with Command never reach
the router (`AppController.swift:~518`) and no menu item owns them, so nothing fires (macOS plays the error beep).
Fix options: let the router take Command+arrow keys that have no menu item, or add an Edit/Clip > "Nudge" submenu.
Same class: any binding with Command and no menu item. Today that is exactly the four nudges, `.group` (Cmd+G), and the
second Export Frame binding (A3). AC: test that every binding containing `.command` is the first binding of a command that is in `EditorMenus.all`.

### A3. Shift+Cmd+E (Export Frame, second binding) is dead (S)
`CommandMap.swift:~58` binds Export Frame twice: Shift+E and Shift+Cmd+E. The menu shows `binding(for:)` = first entry
(Shift+E); Shift+Cmd+E has Command, so the router never sees it, and no menu item carries it. Shift+Cmd+E is also Premiere's
Enable Clip (`docs/spec/timeline.md` section 9). Remove the second binding. AC: `map.duplicates` and a new test "no command is bound twice".

### A4. Cmd+Opt+H will collide with Hide Others (S)
`toggleHoldInterpolation` is bound to Cmd+Opt+H (`CommandMap.swift:~117`) and sits in the Clip menu (`MenuSpec.swift:49`); the app menu
has Hide Others on exactly Cmd+Opt+H (`MenuBuilder.swift:~96`). Hidden today because the command is unwired, but the day it is wired
both menus show the same key and the first one in menu order wins (the app menu: macOS hides the app). Pick another key (Premiere has none for it).
AC: a test that collects key equivalents of `EditorMenus.all` plus the app-menu items and asserts uniqueness.

### A5. Clip > Link never says "Unlink" (S)
The context menu switches between "Link" and "Unlink" (`TimelineContextMenu.swift:~46`); the Clip menu item is `.link` with the fixed title "Link"
(`EditorCommand.swift` title) and `validateMenuItem` only retitles Undo/Redo. Selecting a linked pair and opening Clip shows "Link". Both run
`toggleLinkSelection`, so it works, the label lies. Fix: retitle in `validateTimelineOpItem`. Also Link has no enabled rule: `commandEnabled` returns true even with nothing selected.

### A6. Up/Down in Effect Controls and keyframe commands: timeline-only scope (M, *verify*)
`CommandScope.scope(for:)` maps only timeline/program/source/project/library; with Effect Controls focused only `global` bindings resolve.
All of these are timeline scope: Delete, Cmd+A, `=`/`-`/`\` zoom, F9 family, Opt+Left/Right keyframe navigation, Shift+F3, Opt+K.
`execute` contains Effect Controls branches for `.delete`, `.zoomIn/.zoomOut/.zoomFit` (`AppController+Commands.swift:~100-110`) that the router
can only reach via menu clicks, never via the key. (Delete works because `EffectControlsView.keyDown` handles key 51/117 itself, `EffectControlsView.swift:105`; zoom and keyframe keys have no such path.)
Fix: add a `CommandScope.effectControls` that inherits the timeline keyframe bindings, or bind keyframe commands in `global`. AC: `map.command(for: Opt+Right, focus: .effectControls) == .nextKeyframe`.

### A7. "Previous/Next Keyframe" keys trim edits (S)
Opt+Left/Right is bound to `.previousKeyframe/.nextKeyframe` but `executeTimelineOp` uses it as Premiere's Trim Backward/Forward 1 frame when an edit is
selected (`AppController+TimelineOps.swift:51-56`); with no edit selected it falls through to "Previous Keyframe is not available yet."
Nobody can discover 1-frame trim (the Keyboard Shortcuts window lists only "Previous Keyframe"). Add real `.trimBackward/.trimForward` (1 frame) commands bound to
Opt+Left/Right in a scope that is active when an edge is selected, and give keyframe navigation its own keys (Premiere has none by default).

## B. Bound to something that does nothing ("X is not available yet")
`AppController.isSupported` is the list; anything else flashes `"<title> is not available yet."` (`AppController+Commands.swift:38`). Keys are swallowed.

| Command | Key | Where else it appears | Notes |
|---|---|---|---|
| Group | Cmd+G (timeline) | Clip menu hidden | `docs/spec/timeline.md` backlog item 23 (L). Cmd+G swallowed; also not a macOS conflict. |
| Paste Attributes | Cmd+Opt+V | Edit menu hidden | Confirmed unimplemented (`docs/spec/timeline.md` says "verify"). Not in `isTimelineOp`, so it flashes. M. |
| Zoom tool | Z | View > Tools hides it (`MenuBuilder.isVisible`) | Z selects nothing and flashes. The toolbar button? none. S (spec backlog 3). |
| Easy Ease / Ease In / Ease Out | F9 / Shift+F9 / Shift+Cmd+F9 | Clip menu hidden | The same easing is **implemented** in the keyframe context menu (`EffectKeyframeLanesView.swift:255`) and `KeyframeGraphView`; only the command wiring is missing. S. Shift+Cmd+F9 also hits A1 (Command key, but it has a menu item once visible). F-keys need fn on most Macs: Premiere/our spec call this deliberate (`docs/spec/effects.md:62`). |
| Toggle Hold Interpolation | Cmd+Opt+H | hidden | A4. |
| Add Keyframe | Opt+K | hidden | Needs focused property. |
| Toggle Value/Speed Graph | Shift+F3 | hidden | |
| Delete (project items) | Delete in Project/Library | no menu | `.deleteProjectItems` is not in `isSupported`, not handled by `execute`. `handle()` lets NSTableView/NSOutlineView keep Delete (`AppController.swift:~524`), so it probably works through the panel's own keyDown (*verify*); the command binding itself is dead and shows as a second "Delete" row in the Shortcuts window. Remove the binding or wire it to `ProjectPanelView.menuDelete`. |
| Add Marker in Source monitor | M | – | Status text says so ("Markers on source clips are not available yet.") – honest. |

`docs/audit/shell.md:50` lists stale entries: Cmd+C/X/V, Cmd+L, E (Extend Edit), F (Match Frame) and Shift+R (Reverse Match Frame) are wired now; update that list.

## C. Menu items and their effect

| Item | Finding |
|---|---|
| File > Revert, Sequence Settings, Set to Frame Size | Menu-only, fine. Set to Frame Size is enabled for an audio-only selection and then flashes "Select clips to scale to the frame size." (`AppController+Shell.swift:~25`): wrong message; `commandEnabled` should check for a video clip. |
| Edit > Delete / Ripple Delete | Enabled with selection or caption selection; `Ripple Delete` on captions: `deleteSelection(ripple:)` behaviour for captions not checked (*verify*). |
| Edit > Cut/Copy/Paste/Paste Insert | Paste is always enabled (`commandEnabled` default) even with an empty clipboard; the context menu disables it. Flash "Nothing to paste. Copy clips first." is okay, but a disabled item is closer to Premiere and to our own context menu. S. |
| Edit > Select All | A1. |
| Sequence > Go to Previous/Next Edit Point | Bound in timeline and program scope, **not** in Source monitor/Project: Up/Down do nothing there and fall through to the system (beep). Minor. |
| Sequence > Extend Selected Edit | Works only with an edge selected; always enabled; flashes "Select an edit first (click a clip edge)." Should be disabled when `interaction.edgeSelection == nil`. S. |
| Markers > Mark Clip, Mark Selection | Both exist. "Mark Selection" is Premiere's name but unclear for users ("Mark In/Out around the selected clips" would say it). Title only. |
| View > Playback | Missing "Shuttle Slow Left/Right"; present in the Shortcuts window only. Fine. |
| Window | Panel items for `.text`, `.colorInspector`, `.scopes`, `.audioMeter` have no key (Shift+1..7 map to 7 panels). Fine. Shift+6 opens Library; Premiere's Shift+6 is Audio Clip Mixer (documented in `CommandMap.swift:~62`). |
| Help menu | Empty by design (macOS search field). No "Keyboard Shortcuts" entry there, it is in the app menu. Fine. |
| Commands with no menu item at all | Nudge x4, Trim 5 frames x2, Select Clip at Playhead (D), Go to Next/Previous Edit Point on Any Track, Delete in Project, Maximize Panel Under Pointer (Window: present). Only the Shortcuts window lists them. Add an Edit/Sequence "Nudge" and "Trim" submenu, or accept. |

## D. Context menus vs `docs/spec`

| Menu | Spec (Premiere) | Today | Gap |
|---|---|---|---|
| Timeline clip (`TimelineContextMenu.items`) | Cut, Copy, Paste, Paste Insert, Clear, Ripple Delete, Link/Unlink, Nest, Speed/Duration, Audio Gain, Label, Rename; plus Enable, Reveal in Project, Paste Attributes, Group | Same minus those after the semicolon | **Audio Gain…** exists as a command with menu item and key G (`.audioGain`), but the clip menu has no entry. S: add `TimelineMenuAction.audioGain` for audio clips. Reveal in Project and Enable are known-missing (spec section 9). |
| Same menu, Scale / Set to Frame Size | One entry would do | **Both** "Set to Frame Size" and "Scale to Frame Size" are listed and both call `onFrameSize()` (`EditorPanels.swift:253`) | Duplicate entries with identical effect; `docs/audit/shell.md:12` says only one item. Remove "Scale to Frame Size" (S) unless resampling is built. |
| Same menu, Delete | Premiere "Clear" | "Clear" here, "Delete" in Edit menu and caption menu, same command | Pick one word. Premiere calls the Edit item "Clear" too. S. |
| Gap menu | Ripple Delete, Paste | ok | none |
| Empty track space | Paste, Paste Insert | ok | Spec lists nothing else. |
| Track header | Add/Delete track, Rename (spec: same) | Add Video/Audio Track, Delete Track, Rename… | Spec is satisfied. Premiere also has "Add Tracks…", "Delete Tracks…", Track Height; not in spec. |
| Ruler | Add Marker, Edit/Delete Marker, Clear In/Out | same | "Add Marker" jumps the playhead to the click time as a side effect (`EditorPanels+Markers.swift:~66`): deliberate? Premiere adds at the playhead. *verify intent*. |
| Marker on a clip, caption menu | n/a | caption menu: Edit Caption Text, Split at Playhead, Merge, Delete | ok. |
| Program monitor | Mark In/Out, Go to, Clear, Add Marker, Lift/Extract, Match Frame, zoom, safe margins | all present (`EditorPanels.swift:~395-430`) | none. Items bypass `CommandMap`, so their enabled state is hand-written: Match Frame/Export Frame enabled without a clip. Minor. |
| Source monitor | spec monitors.md:112 | Mark In/Out, Go to, Clear In/Out/both, Insert, Overwrite, Export Frame, Loop, Reveal in Project | **Missing: Add Marker, Match Frame / Go to**, zoom and safe margins that the Program menu has (spec says same set as Program). S each. |
| Project panel | Make Subclip, Duplicate, Proxy (spec: "intended") | Open in Source, Insert, Overwrite, New Sequence From Clip, Rename, Delete, Label, Reveal in Finder, Replace Footage / Link Media | Nothing missing that we can run. Empty-area menu: New Bin, New Sequence, Import. No "Import…" ellipsis consistency: the menu says "Import…", File says "Import Media…". |
| Effect Controls effect header | Cut, Copy, Paste, Clear (`docs/spec/effects.md:32`) | Copy, Paste | Missing Cut and Clear. S. (Cut works through Cmd+X, `executeInEffectControls`.) |
| Keyframe | Linear, Bezier, Auto Bezier, Continuous Bezier, Ease In/Out, Hold | no Auto/Continuous Bezier | known (spec). M. |
| Panel tab | Close, Maximize (our own), Undock etc. | Close Panel, Maximize Panel | `maximizePanelFromTab` item shows key "`" with empty modifier mask but the real shortcut is global `\`` under the pointer: consistent. |

## E. Unclear user-visible strings

| Where | String | Problem | Suggestion |
|---|---|---|---|
| Any unwired command | "Group is not available yet." / "Paste Attributes is not available yet." | Says "not available yet", gives no hint it is planned vs impossible; a key press from a user who knows Premiere gets a flash only | Keep; but for easing keys say "Select a keyframe in Effect Controls first" once wired. |
| `EditorCommand.title` | "Shuttle Slow Left/Right" vs "Shuttle Reverse/Forward" | Inconsistent direction words | "Shuttle Slow Reverse/Forward". |
| `.trimBackward5` | "Trim Backward Five Frames" next to "Step Back 5 Frames" | Digit vs word | Use digits: "Trim Backward 5 Frames", "Nudge Clip Selection Left 5 Frames". |
| `.maximizePanel` | "Maximize or Restore Panel Under Pointer" | Long for a menu | "Maximize Panel Under Pointer". |
| `.toggleSnapping` | "Snap" | A verb in a menu with a checkmark | "Snap" is Premiere's word; ok. Keep. |
| `.toggleLinkedSelection` | "Linked Selection" | fine |  |
| `.markSelection` | "Mark Selection" | Not clear what it marks | "Mark In/Out Around Selection". |
| `.delete` vs `.deleteProjectItems` | both "Delete" | Two identical rows in the Shortcuts window (distinguished by scope only) | Title "Delete Project Items". |
| `.exportFrame` | two rows "Export Frame…" | Same (two bindings) | Remove second binding (A3). |
| `.previousKeyframe` | "Previous Keyframe" bound to Opt+Left | A7: also trims an edit | Split commands. |
| Shortcuts window note | "Editing shortcuts is not available yet." | Fine. |
| `needEdit()` flash | "Select an edit first (click a clip edge)." | fine |
| Panel title | "Meter" (`.audioMeter`) | Window > Meter, "Show Meter" in the Shortcuts window | "Audio Meters". |
| Setting | "Settings…" | Premiere says Preferences; macOS 13+ says Settings. Fine. |
| Context menu | "Nest…" | The sheet title is "Nest" and the prompt "Name of the new sequence:" | fine |
| Alert | "This clip does not match the sequence settings." | Premiere's wording; buttons clear. | fine |

## F. Duplicates and shadows (as asked)

Checked `CommandMap.premiereDefault` by reading, per scope:
* Same (scope, key) twice: **none** (the existing `ShortcutTableTests.noDuplicateBindingsInAScope` covers this).
* One command, two keys: Export Frame (A3). Everything else is one key per command.
* Panel scope shadowing a global key with a different command: none (the existing test covers it).
* Same key, different modifiers, easily confused: `B` Ripple tool vs Cmd+B New Bin; `E` Extend Edit vs Shift+E Export Frame; `R` Rate Stretch vs Shift+R Reverse Match Frame vs Cmd+R Speed; `K` Stop vs Cmd+K Add Edit vs Opt+K Add Keyframe vs Cmd+Opt+K Shortcuts. All match Premiere.
* Menu key equivalents that collide with the app menu: Cmd+Opt+H (A4). No other collisions (Cmd+M is Export, not Minimize; the Window menu leaves Minimize without a key on purpose; Cmd+H, Cmd+Q untouched).
* macOS reserved: F3, F9 and F-keys in general need fn; Ctrl+L, `\``  fine.

## G. Suggested tests (SQEditorUI, no UI needed)
1. Every binding that contains `.command` belongs to a command in `EditorMenus.all` (A2, A3).
2. Key equivalents of all `EditorMenus` items plus the app-menu items (Hide, Hide Others, Quit, About-less) are unique (A4).
3. `isEnabled(command, focus:, typing:)` pure function: scoped commands disabled outside their scope; selectAll is routed to text when typing (A1).
4. Every `EditorCommand` case is either supported or in an explicit `unwired` set; the set matches section B (stops the audit list from going stale).
5. Every title is unique per (command), and no two rows in `KeyboardListing.windowRows` have the same command title and key (E).

## H. Ranked backlog
1. A1 scoped shortcuts / Select All in text fields (M)
2. A2 nudge shortcuts dead (S)
3. A6 Effect Controls scope for keyframe and zoom keys (M)
4. B easing commands: wire F9 family to the existing keyframe code (S)
5. D clip menu: add Audio Gain, remove duplicate Scale to Frame Size (S)
6. A3, A4 remove second Export Frame binding, move Hold off Cmd+Opt+H (S)
7. A5 Link/Unlink title, Paste/Extend Edit enabled states (S)
8. A7 separate trim-by-1-frame command from keyframe navigation (S)
9. Source monitor context menu: Add Marker, Match Frame, zoom (S)
10. B Paste Attributes (M), Zoom tool (S), Group (L)
11. E string fixes (S)
