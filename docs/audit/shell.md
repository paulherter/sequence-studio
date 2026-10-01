# Audit: shell (menus, shortcuts, panels, sequence, export, project, preferences)

Verified against Adobe's shortcut reference (docs/reference/adobe/keyboard-shortcuts.txt) where marked (v). "(u)" = could not verify.
Menu dump for checking: `SQ_DUMPMENU=1 SQ_NO_RECOVERY=1 <app binary>` (logs every item, key, enabled state, and shortcuts whose command is not wired).

| Feature | Premiere | Sequence Studio now | Gap | Done tonight? |
|---|---|---|---|---|
| Menu bar | File, Edit, Clip, Sequence, Markers, Graphics and Titles, View, Window, Help | File, Edit, Clip, Sequence, Markers, View, Window, Help (empty: macOS search field) | Graphics and Titles: nothing to list (text is the Type tool / Text panel) | Yes |
| Unwired items | n/a | Hidden, never shown dead (Cut/Copy/Paste/Undo/Redo/Delete stay for text fields) | Link, Group, Match Frame, keyframe items appear once their owner stream wires them | Yes |
| File | New (Project, Sequence), Open, Open Recent, Save, Save As, Revert, Import, Export | New Project (Opt+Cmd+N), New Sequence (Cmd+N), Open Project, Open Recent, Save, Save As, Revert, Import Media, Export | Close/Save a Copy (u: no demand) | Yes |
| Edit | Undo/Redo, clipboard, Paste Insert, Clear, Ripple Delete, Select All, Find | Undo/Redo with action names ("Undo Ripple Delete"), Cut/Copy/Paste/Paste Attributes (hidden-until-wired except text fields), Delete, Ripple Delete | Clipboard and Select All do nothing in the timeline yet (timeline stream) | Partly |
| Clip | Insert/Overwrite, Link, Group, Video Options > Set to Frame Size | Insert, Overwrite, Link, Group, Set to Frame Size (enabled with a selection), keyframe easing | Scale to Frame Size is identical to Set to Frame Size here (no resampling), so only one item | Yes |
| Sequence | Sequence Settings, Lift/Extract, Add Edit, Snap, Match Frame, Zoom | Sequence Settings, Lift, Extract, Add Edit(+all), trims, Snap, Match Frame, edit-point navigation | Render in to out, add/delete tracks (not in scope) | Yes |
| Markers | Mark In/Out/Clip, Go to In/Out, Clear, Add Marker, next/previous marker | Mark In/Out/Clip, Go to In/Out, Clear In and Out, Add Marker | Next/Previous Marker, Clear Marker: timeline/marker stream. Shift+M (v) | No |
| View | monitor zoom, playback resolution, guides | Playback submenu (transport), Zoom, Track Height, Tools submenus | Premiere has no transport/tools in menus: kept as discoverable submenus (u) | Yes |
| Window | Workspaces, one item per panel with check, Reset to Saved Layout Opt+Shift+0 (v) | Workspaces submenu, all 11 panels with checks and Shift+1..7, Maximize items, Minimize/Zoom/Bring All to Front | Shift+6 is Library (Premiere: Audio Track Mixer), Shift+8 Media Browser, Shift+9 Audio Clip Mixer have no panel | Yes |
| Keyboard Shortcuts | Premiere Pro menu, Cmd+Opt+K (v) | App menu, Cmd+Opt+K, searchable read-only window (command, key, scope; "shift cmd z" or the symbols both match) | Editing shortcuts | Read-only |
| Panel focus | click focuses, blue outline | click focuses; 2 pt accent outline on the focused panel | none | Yes |
| ` key | maximise frame under cursor (v), Shift+` active frame (v) | both | none | Yes |
| Panel tab menu | Close Panel, Undock, Maximize | right-click: Close Panel, Maximize / Restore Panel Size | no floating panels, so no Undock | Yes |
| Workspaces | Reset to Saved Layout, Save as New Workspace | present; flows covered by WorkspaceMenuFlowTests | Select Next/Previous Panel Ctrl+Shift+. , (v) not implemented | Tested |
| New Sequence presets | YouTube/vertical via settings | Preset popup: YouTube 1080p and 4K at 24/25/30/50/60, vertical 1080x1920 at 30/60; shows "Custom" when edited | Premiere asks for audio rate etc. (we have sample rate) | Yes |
| Sequence Settings | frame size, rate, audio rate; clips keep scale (100% = source pixels) | same sheet, same preset popup | none | Yes |
| First clip mismatch | prompt: change sequence settings / keep existing | alert with both buttons, only for an empty never-configured sequence (EditorSession.formatMismatch) | none | Yes |
| Export presets | Match Source, YouTube 1080p/4K, social, ProRes | Match Source (High, H.264), YouTube 1080p, YouTube 4K, TikTok/Reels/Shorts 1080x1920 H.264 and HEVC, ProRes 422 HQ; Match Source/ProRes follow sequence size and rate, YouTube follows rate; summary line (size, fps, codec, bitrate) and size estimate | none | Yes |
| Export correctness | n/a | PresetFileTests writes every preset and reads back size, fps, duration, audio track. Found and fixed: AAC 384 kbit/s fails ("Cannot Encode Media"), now 320 | none | Yes |
| Export flow | sheet with file name/location, queue, reveal | sheet (sequence list, preset, range, details), folder chooser on Export, queue popover with progress, cancel and Show in Finder; toolbar Export button | file name field in the sheet (folder only), auto-reveal when done | Partly |
| Project | New/Open/Save/Save As/Revert, recents, autosave + recovery, dirty dot, save on close | all present (recents via Open Recent; dirty dot = window edited flag; "Save changes?" on quit/new/open; autosave and recovery existed) | none | Yes |
| Import / drag | Cmd+I, drag from Finder to Project and timeline | Cmd+I; Project outline and timeline both accept file URLs | none | Existing |
| Offline media | relink dialog on open | after Open: "N media files are offline", Locate... searches a folder (subfolders, by file name, prefers same size), Relink Media is one undo step | per-file Locate | Yes |
| Preferences | Settings Cmd+, | General (autosave interval, recovery), Playback (default quality), Media (cache folder shown, size, Clear Cache) | Removed dead rows: audio output (never used), cache folder chooser and size cap (never read). Default still duration, default transition, snap playhead, scroll mode: no plumbing yet (timeline/media streams) | Cleaned |
| Undo/Redo titles | "Undo Ripple Delete" | existed; names come from the edit | History panel not done | Existing |

## Shortcut table (CommandMap.premiereDefault; scope Everywhere unless noted)

Cmd+N New Sequence, Opt+Cmd+N New Project, Cmd+O Open Project, Cmd+S Save, Shift+Cmd+S Save As, Cmd+I Import, Cmd+M Export, Cmd+, Settings, Opt+Cmd+K Keyboard Shortcuts,
Cmd+Z / Shift+Cmd+Z Undo/Redo, Cmd+X/C/V Cut/Copy/Paste, Opt+Cmd+V Paste Attributes,
Space Play/Pause, J K L shuttle, Left/Right step 1, Shift+Left/Right step 5, Home/End sequence start/end,
I O Mark In/Out, Shift+I / Shift+O Go to In/Out, X Mark Clip, Opt+X Clear In and Out, ; Lift, ' Extract, , Insert, . Overwrite, M Add Marker,
V A Shift+A B N Y U C H Z T tools (Z does nothing yet), Shift+1 Project, Shift+2 Source, Shift+3 Timeline, Shift+4 Program, Shift+5 Effect Controls, Shift+6 Library, Shift+7 Effects,
` maximise panel under pointer, Shift+` maximise active panel, Opt+Shift+0 Reset to Saved Layout.
Timeline: Up/Down previous/next edit point, Cmd+K / Shift+Cmd+K Add Edit (all tracks), Q W ripple trim previous/next, E extend edit, Delete / Shift+Delete delete / ripple delete,
S snap, Cmd+L link, Cmd+G group, F match frame, Shift+R reverse match frame, = - zoom in/out, \ zoom to fit,
Cmd+= / Cmd+- video track height, Opt+= / Opt+- audio track height, Shift+= expand all, Shift+- minimise all,
F9 / Shift+F9 / Shift+Cmd+F9 easing, Opt+Cmd+H hold, Opt+Left/Right previous/next keyframe, Shift+F3 speed graph, Opt+K add keyframe.
Program monitor: Up/Down edit points, F, Shift+R. Project panel: Delete.

Checks (ShortcutTableTests): no duplicate binding in a scope; no panel-scope binding shadows a different global command; no shifted characters as keys (the old "+" zoom binding could never fire and was removed); every menu command has a key or is menu-only; each command appears in one menu; file/app shortcuts and Shift+1..5 mapping match Premiere (v).

Shortcuts bound to commands that are not wired (do nothing, listed for their owners): Z Zoom tool, Cmd+C/X/V, Opt+Cmd+V, E, Cmd+L, Cmd+G, F, Shift+R (timeline and program), F9 family, Opt+Cmd+H, Opt+Left/Right, Shift+F3, Opt+K, Delete in the Project panel.
