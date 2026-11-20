---
title: Keyboard Shortcuts
chapter: settings-and-shortcuts
order: 2
code: crates/sq-uikit/src/command_map.rs, crates/sq-uikit/src/key_binding_text.rs, crates/sq-uikit/src/keymap_store.rs, crates/sq-uikit/src/keymap_import.rs, crates/sq-uikit/src/layout_keys.rs, crates/sq-uikit/src/manual_shortcuts_tests.rs, crates/sq-draw-shell/src/shell_shortcuts.rs, crates/sq-core-project/src/foreign_keymap.rs
---

## For users

A complete list of the default keys in Sequence Studio, with the Mac keys and the Windows and Linux keys side by side.

### Read this first

- On the Mac the modifier keys are Control (⌃), Option (⌥), Shift (⇧) and Command (⌘). On Windows and Linux, Command and Control both appear as Ctrl, and Option appears as Alt.
- The same key map is used on all three systems, and Windows and Linux share one column. Where a Control key on the Mac would end up on the same key as a Command shortcut there, the Windows and Linux column says "Menu only". Use the menu for those commands. Two of them, Play to Out and Toggle Target Video Track 9, have no menu row: run them from Quick Apply (Window > Quick Apply) instead.
- Some of those clashes only exist while a panel has focus. On Windows and Linux, with the Project panel focused, Ctrl+[ and Ctrl+] make thumbnails smaller and larger and Ctrl+P sets the poster frame; with the Timeline focused, Ctrl+L is Link. In those places use the menu for Go to Previous Keyframe, Go to Next Keyframe, Go to Timecode and Loop Playback, or click another panel first.
- The Mac Delete key (⌫) is Backspace on Windows and Linux. Forward Delete is Del.
- On Windows and Linux the menu bar is in the window. Press and release Alt on its own, or press F10, to put the keyboard on it: Left and Right move between the menus, Down or Enter opens one, a menu's underlined letter opens it, and Esc leaves. Alt with a key or a mouse click is still a shortcut, and Alt + mouse wheel zooms the timeline. On the Mac the menu bar is the system's own.
- Quit is Command-Q on the Mac (the Sequence Studio menu shows Quit Sequence Studio), Alt+F4 on Windows and Ctrl+Q on Linux (File shows Exit). The window's close button, Alt+F4 and the window manager's close ask "Save Changes" first when the project has unsaved changes, like Quit does.
- The system can take a key before the app sees it. On the Mac: Control-Space (Play to Out) when two input sources are installed, Command-M (Export) is the system Minimize key, and Control-1 to Control-9 (Toggle Target Video Track) when you turned on "Switch to Desktop". On Linux some desktops use Ctrl+Alt chords for themselves (Ctrl+Alt+arrows switch workspaces, Ctrl+Alt+Backspace, Ctrl+Alt+L, Ctrl+Alt+D, Ctrl+Alt+T): if such a key does nothing, change it in Window > Keyboard Shortcuts.
- On a Windows layout with an AltGr key (German, French and others), AltGr types its characters (@, €, µ, {, [) and never runs a shortcut. The left Ctrl with the left Alt key runs the Ctrl+Alt shortcuts (Quick Export, Actual Size, the Toggle Target Track keys, Video Fade In and Out).
- On Windows and Linux the keys shown follow your keyboard layout, and you press what is shown. A shortcut whose character your layout types with Shift shows that Shift: on a German keyboard New Folder (Ctrl+/) is Ctrl+Shift+7, and Duplicate (Ctrl+Shift+/) is Ctrl+Shift+- (the key at the US slash position). The key left of 1 shows as "Backtick" on a US keyboard and as ^ on a German one. A shortcut that no key of your layout reaches shows no key; use the menu or change it in Window > Keyboard Shortcuts (German: every shortcut with ] and the plain / of Mark Selection; French: the digit 4 and 6 keys of the angle and track keys, and Shift+. of Place on Top). Windows reads the layout from the system; Linux reads it once at start and knows US, UK, German and French (other layouts show the US names).
- Every key can be changed. Open Window > Keyboard Shortcuts (Mac: Option-Command-K).

### How keys are routed

- A key is looked up in the focused panel first, then in "Everywhere". A panel never reuses a key that "Everywhere" gives to another command.
- With the **Controls** panel focused, Cut, Copy, Paste and Delete (Backspace on Windows and Linux) and the same rows of the Edit menu act on what is selected in Controls: keyframes first, otherwise the selected effect or mask. They never cut, copy, paste or delete clips in the timeline, and with nothing selected in Controls they do nothing. The Delete and Ripple Delete rows below are for the Timeline. See [Effects and Motion](effects-and-motion.md).
- With the **Library** focused, Space plays or pauses the sound or video you selected there. With nothing playable selected, Space plays the sequence.
- The Timeline, Program monitor and Source monitor share the transport and marking keys (Space, J, K, L, arrow keys, I, O, X, comma and period).
- While you type in a text field (names, timecode, text, search), plain keys such as Space, J, K, L, Delete and the arrows stay in the field. Undo, Copy, Cut, Paste and Select All edit the text.
- In lists and number fields the arrow keys belong to the list or field, not to the playhead.
- A menu row shows its key. The menu bar lists the most used commands; every command, with or without a key, is in Quick Apply (Window > Quick Apply).

Windows and Linux: Alt plus a menu's letter opens that menu (Alt+F opens File); a bound Alt chord such as Alt+M, Alt+V or Alt+W runs its command instead. Esc closes every menu, popup, sheet and dialog.

### Hidden gems

- **Quick Apply** (Mac: Option-Space, Windows and Linux: Ctrl+Space): a popup to find and apply an effect, preset or command by name without leaving the keyboard.
- **Quick Export** (Mac: Option-Command-M, Windows and Linux: Ctrl+Alt+M): exports with no dialog, using the sequence's platform preset and the last export folder.
- **Maximize Panel Under Pointer** (`): blows up the panel under the mouse. Press it again to go back. Shift-` does the same for the active panel.
- **Tool keys**: tap a tool key to keep the tool. Hold it for more than a quarter of a second to use the tool only while the key is down. Esc returns to the Select tool.
- **Keyword at Playhead** (Shift+T): turns the transcript word under the playhead into a large text clip.

### Change a shortcut

1. Open Window > Keyboard Shortcuts.
2. Search for the command, or click a key on the keyboard picture.
3. Choose Set Shortcut and press the new keys. Esc cancels.
4. If the key is already used in the same place, you are asked "Replace the existing shortcut?". If it overlaps a panel key, you can choose Assign Anyway.
5. Choose Reset to defaults to go back. It asks first.

Some keys are reserved and cannot be assigned: Command-H, Option-Command-H, Shift-Command-H, Command-Q and Command-W (on Windows and Linux Ctrl+Q is reserved too).

Key sets: the switcher offers Sequence Studio (default), Classic NLE (Premiere-style) and Final Cut style, and your own sets. Import Shortcuts… reads Premiere .kys files, DaVinci Resolve layouts, Final Cut .commandset files and Sequence Studio .sqkeys files. Save Current as My Set… and Export Current Set… keep your changes.

### Everywhere

| Mac | Windows and Linux | Command |
|---|---|---|
| ⌥⌘0 | Ctrl+Alt+0 | Actual Size |
| M | M | Add Marker |
| ⌘T | Ctrl+T | Add Title |
| ⇧⌘D | Ctrl+Shift+D | Apply Audio Transition |
| ⇧D | Shift+D | Apply Default Transitions to Selection |
| ⌘D | Ctrl+D | Apply Video Transition |
| ⌃⇧. | Ctrl+Shift+. | Attach Backtimed |
| ⇧S | Shift+S | Audio Scrubbing |
| C | C | Blade Tool |
| ⌥⌘G | Ctrl+Alt+G | Bundle |
| ⌃⌥M | Menu only | Clear All Markers |
| ; | ; | Clear Range |
| ⌥M | Alt+M | Clear Selected Marker |
| ⇧⌘W | Ctrl+Shift+W | Close Project |
| ⌘C | Ctrl+C | Copy |
| ⌘X | Ctrl+X | Cut |
| ⇧X | Shift+X | Cut Out (Mark Start, then Delete Range) |
| ' | ' | Delete Range |
| ⌥⇧D | Alt+Shift+D | Draw Tool |
| ⇧⌘/ | Ctrl+Shift+/ | Duplicate |
| ⌘E | Ctrl+E | Edit Original |
| ⌥⇧E | Alt+Shift+E | Ellipse Tool |
| ⇧⌘E | Ctrl+Shift+E | Enable |
| ⇧E | Shift+E | Export Frame… |
| ⌘M | Ctrl+M | Export… |
| ⇧I | Shift+I | Go to In |
| ⌃] | Ctrl+] | Go to Next Keyframe |
| ⇧M | Shift+M | Go to Next Marker |
| ⌥⇧M | Alt+Shift+M | Go to Next Weak Tracking |
| ⇧O | Shift+O | Go to Out |
| ⌃[ | Ctrl+[ | Go to Previous Keyframe |
| ⇧⌘M | Ctrl+Shift+M | Go to Previous Marker |
| ↘ | End | Go to Sequence End |
| ↖ | Home | Go to Sequence Start |
| ⌃P | Ctrl+P | Go to Timecode… |
| ⌘G | Ctrl+G | Group |
| H | H | Hand Tool |
| ⌘I | Ctrl+I | Import… |
| , | , | Insert |
| ⌥⌘K | Ctrl+Alt+K | Keyboard Shortcuts… |
| ⇧T | Shift+T | Keyword at Playhead |
| ⌥⌘= | Ctrl+Alt+= | Larger |
| ⌥⇧L | Alt+Shift+L | Line Tool |
| ⌃L | Ctrl+L | Loop Playback |
| ⌘U | Ctrl+U | Make Subclip |
| X | X | Mark Clip |
| I | I | Mark In |
| O | O | Mark Out |
| / | / | Mark Selection |
| P | P | Mask Tool |
| ⇧` | Shift+Backtick | Maximize Active Panel |
| ` | Backtick | Maximize Panel Under Pointer |
| ⌘/ | Ctrl+/ | New Folder |
| ⌥⌘N | Ctrl+Alt+N | New Project |
| ⌘N | Ctrl+N | New Sequence… |
| ⌘O | Ctrl+O | Open Project… |
| . | . | Overwrite |
| ⌘V | Ctrl+V | Paste |
| ⌥V | Alt+V | Paste Attached |
| ⇧⌘V | Ctrl+Shift+V | Paste Insert |
| ⌥⌘V | Ctrl+Alt+V | Paste Settings |
| ⇧. | Shift+. | Place on Top |
| ⇧K | Shift+K | Play Around |
| ⇧Space | Shift+Space | Play In to Out with Preroll/Postroll |
| ⌃⇧Space | Ctrl+Shift+Space | Play from Start |
| ⌃Space | Menu only | Play to Out |
| Space | Space | Play/Pause |
| ⇧V | Shift+V | Position Tool |
| ⇧P | Shift+P | Punch In |
| ⌥Space | Ctrl+Space | Quick Apply… |
| ⌥⌘M | Ctrl+Alt+M | Quick Export |
| ⌥⇧R | Alt+Shift+R | Rectangle Tool |
| ⇧⌘Z | Ctrl+Shift+Z | Redo |
| ⌥I | Alt+I | Remove In |
| ⌥X | Alt+X | Remove In and Out |
| ⌥O | Alt+O | Remove Out |
| ⌥⇧0 | Alt+Shift+0 | Reset to Saved Layout |
| B | B | Ripple Tool |
| N | N | Roll Tool |
| ⌘S | Ctrl+S | Save |
| ⇧⌘S | Ctrl+Shift+S | Save As… |
| ⌥⌘S | Ctrl+Alt+S | Save a Copy… |
| ⌥⌘T | Ctrl+Alt+T | Save as Template |
| ⇧A | Shift+A | Select Backward Tool |
| A | A | Select Forward Tool |
| ⌃⌥. | Ctrl+Alt+. | Select Next Panel |
| ⌃⌥, | Ctrl+Alt+, | Select Previous Panel |
| V | V | Select Tool |
| ⌘, | Ctrl+, | Settings… |
| ⇧6 | Shift+6 | Show Audio Meters |
| ⇧8 | Shift+8 | Show Captions |
| ⇧0 | Shift+0 | Show Color |
| ⇧5 | Shift+5 | Show Controls |
| ⇧7 | Shift+7 | Show Effects |
| ⇧9 | Shift+9 | Show Text & Graphics |
| ⇧, | Shift+, | Nudge Clip Selection Left 10 Frames |
| ⇧4 | Shift+4 | Show Program |
| ⇧1 | Shift+1 | Show Project |
| ⇧2 | Shift+2 | Show Source |
| ⇧3 | Shift+3 | Show Timeline |
| L | L | Shuttle Forward |
| J | J | Shuttle Reverse |
| ⇧L | Shift+L | Shuttle Slow Forward |
| ⇧J | Shift+J | Shuttle Slow Reverse |
| K | K | Shuttle Stop |
| U | U | Slide Tool |
| Y | Y | Slip Tool |
| ⌥⌘- | Ctrl+Alt+- | Smaller |
| F9 | F9 | Ease In & Out |
| ⇧F9 | Shift+F9 | Ease In |
| ⇧⌘F9 | Ctrl+Shift+F9 | Ease Out |
| ← | Left | Step Back 1 Frame |
| ⇧← | Shift+Left | Step Back 10 Frames |
| → | Right | Step Forward 1 Frame |
| ⇧→ | Shift+Right | Step Forward 10 Frames |
| R | R | Stretch Tool |
| T | T | Text Tool |
| ⌥⌘C | Ctrl+Alt+C | Transcribe and Create Captions |
| ⌥⇧⌘G | Ctrl+Alt+Shift+G | Unbundle |
| ⌘Z | Ctrl+Z | Undo |
| ⇧⌘G | Ctrl+Shift+G | Ungroup |
| Z | Z | Zoom Tool |

### Timeline

| Mac | Windows and Linux | Command |
|---|---|---|
| ⌃⌥A | Ctrl+Alt+A | Add Audio Track |
| ⌘K | Ctrl+K | Add Edit |
| ⇧⌘K | Ctrl+Shift+K | Add Edit to All Tracks |
| ⌃⇧H | Ctrl+Shift+H | Add Frame Hold |
| ⌃⌥K | Menu only | Add Keyframe |
| ⌃⌥V | Menu only | Add Video Track |
| ⌃E | Menu only | Append to Main Track |
| G | G | Audio Gain… |
| ⌃⌥D | Ctrl+Alt+D | Bake Live Duck to Keys |
| ⌃⌫ (Delete) | Ctrl+Backspace | Close Gap at Playhead |
| ⌃G | Menu only | Create Storyline |
| [ | [ | Decrease Audio Gain by 1 dB |
| ⇧[ | Shift+[ | Decrease Audio Gain by 6 dB |
| ⌥- | Alt+- | Decrease Audio Track Height |
| ⌘- | Ctrl+- | Decrease Video Track Height |
| ⌫ (Delete) | Backspace | Delete |
| ⌥⌘⌫ (Delete) | Ctrl+Alt+Backspace | Delete Selection Only |
| ⌃⌥⌫ (Delete) | Menu only | Delete Track |
| ⇧⌘A | Ctrl+Shift+A | Deselect All |
| ⌃⇧D | Menu only | Detach Audio |
| ⇧= | Shift+= | Expand All Tracks |
| W | W | Extend Selected Edit to Playhead |
| ⌃⌥[ | Ctrl+Alt+[ | Fade In |
| ⌃⌥] | Ctrl+Alt+] | Fade Out |
| ⇧G | Shift+G | Fast Cut |
| ⌃\ | Ctrl+\ | Fit All Tracks to Height |
| ↓ | Down | Go to Next Edit |
| ⇧↓ | Shift+Down | Go to Next Edit on Any Track |
| ↑ | Up | Go to Previous Edit |
| ⇧↑ | Shift+Up | Go to Previous Edit on Any Track |
| ⇧↘ | Shift+End | Go to Selected Clip End |
| ⇧↖ | Shift+Home | Go to Selected Clip Start |
| ] | ] | Increase Audio Gain by 1 dB |
| ⇧] | Shift+] | Increase Audio Gain by 6 dB |
| ⌥= | Alt+= | Increase Audio Track Height |
| ⌘= | Ctrl+= | Increase Video Track Height |
| ⌃W | Ctrl+W | Insert Spacer |
| ⌥J | Alt+J | J Cut (Audio Leads) |
| ⌃⌥⇧J | Ctrl+Alt+Shift+J | J Cut by Offset |
| ⌃⌥J | Ctrl+Alt+J | Join Cuts |
| ⌃K | Menu only | Jump Cut to Alternate Track |
| ⌥L | Alt+L | L Cut (Audio Trails) |
| ⌃⌥⇧L | Ctrl+Alt+Shift+L | L Cut by Offset |
| ⌥⌘↑ | Ctrl+Alt+Up | Lift off Main Track |
| ⌘L | Ctrl+L | Link |
| ⌃⇧L | Ctrl+Shift+L | Linked Selection |
| ⌃⇧K | Menu only | Lock or Unlock Targeted Tracks |
| ⌃⌥L | Ctrl+Alt+L | Match Loudness |
| ⇧- | Shift+- | Minimize All Tracks |
| ⌃⇧A | Menu only | Move Audio Edit to Playhead |
| ⌃⌘← | Menu only | Move Clip Left |
| ⌃⌘→ | Menu only | Move Clip Right |
| ⌥↓ | Alt+Down | Move Selection Down |
| ⌥↑ | Alt+Up | Move Selection Up |
| ⌃⇧V | Menu only | Move Video Edit to Playhead |
| ⌃⇧M | Menu only | Mute Selected Tracks |
| ⌃⌥← | Menu only | Nudge Audio Edit Left 1 Frame |
| ⌃⌥→ | Menu only | Nudge Audio Edit Right 1 Frame |
| ⌘← | Ctrl+Left | Nudge Clip Selection Left 1 Frame |
| ⇧⌘← | Ctrl+Shift+Left | Nudge Clip Selection Left 10 Frames |
| ⌘→ | Ctrl+Right | Nudge Clip Selection Right 1 Frame |
| ⇧⌘→ | Ctrl+Shift+Right | Nudge Clip Selection Right 10 Frames |
| ⌃⌥⇧← | Menu only | Nudge Video Edit Left 1 Frame |
| ⌃⌥⇧→ | Menu only | Nudge Video Edit Right 1 Frame |
| ⌥⇧⌘V | Ctrl+Alt+Shift+V | Paste to Targeted Track |
| ⌥K | Alt+K | Play In to Out |
| ⌥⌘↓ | Ctrl+Alt+Down | Put on Main Track |
| ⌃⌥⇧P | Ctrl+Alt+Shift+P | Replace Clip from Project |
| ⌃⌥⇧R | Ctrl+Alt+Shift+R | Replace Clip from Source |
| ⌃⌥R | Ctrl+Alt+R | Reverse Clip |
| ⇧⌫ (Delete) | Shift+Backspace | Ripple Delete |
| ⌃⇧⌫ (Delete) | Ctrl+Shift+Backspace | Ripple Delete in Storyline |
| E | E | Ripple Trim Next Edit to Playhead |
| Q | Q | Ripple Trim Previous Edit to Playhead |
| ⇧W | Shift+W | Roll Next Edit to Playhead |
| ⇧Q | Shift+Q | Roll Previous Edit to Playhead |
| ⌘A | Ctrl+A | Select All |
| D | D | Select Clip at Playhead |
| ⌥] | Alt+] | Select Layer Above |
| ⌥[ | Alt+[ | Select Layer Below |
| ⌘↓ | Ctrl+Down | Select Next Clip |
| ⌘↑ | Ctrl+Up | Select Previous Clip |
| F | F | Show in Source |
| ⇧R | Shift+R | Show in Timeline |
| ⌥, | Alt+, | Slide Clip Selection Left 1 Frame |
| ⌥⇧, | Alt+Shift+, | Slide Clip Selection Left 10 Frames |
| ⌥. | Alt+. | Slide Clip Selection Right 1 Frame |
| ⌥⇧. | Alt+Shift+. | Slide Clip Selection Right 10 Frames |
| ⌥⌘← | Ctrl+Alt+Left | Slip Clip Selection Left 1 Frame |
| ⌥⇧⌘← | Ctrl+Alt+Shift+Left | Slip Clip Selection Left 10 Frames |
| ⌥⌘→ | Ctrl+Alt+Right | Slip Clip Selection Right 1 Frame |
| ⌥⇧⌘→ | Ctrl+Alt+Shift+Right | Slip Clip Selection Right 10 Frames |
| S | S | Snap |
| ⌃⌥S | Menu only | Solo Selected Tracks |
| ⌘R | Ctrl+R | Speed… |
| 1 | 1 | Switch to Angle 1 |
| 2 | 2 | Switch to Angle 2 |
| 3 | 3 | Switch to Angle 3 |
| 4 | 4 | Switch to Angle 4 |
| 5 | 5 | Switch to Angle 5 |
| 6 | 6 | Switch to Angle 6 |
| 7 | 7 | Switch to Angle 7 |
| 8 | 8 | Switch to Angle 8 |
| 9 | 9 | Switch to Angle 9 |
| ⌘0 | Ctrl+0 | Toggle Audio Targets |
| ⌃⌥1 | Ctrl+Alt+1 | Toggle Target Audio Track 1 |
| ⌃⌥2 | Ctrl+Alt+2 | Toggle Target Audio Track 2 |
| ⌃⌥3 | Ctrl+Alt+3 | Toggle Target Audio Track 3 |
| ⌃⌥4 | Ctrl+Alt+4 | Toggle Target Audio Track 4 |
| ⌃⌥5 | Ctrl+Alt+5 | Toggle Target Audio Track 5 |
| ⌃⌥6 | Ctrl+Alt+6 | Toggle Target Audio Track 6 |
| ⌃⌥7 | Ctrl+Alt+7 | Toggle Target Audio Track 7 |
| ⌃⌥8 | Ctrl+Alt+8 | Toggle Target Audio Track 8 |
| ⌃⌥9 | Ctrl+Alt+9 | Toggle Target Audio Track 9 |
| ⌃1 | Ctrl+1 | Toggle Target Video Track 1 |
| ⌃2 | Ctrl+2 | Toggle Target Video Track 2 |
| ⌃3 | Ctrl+3 | Toggle Target Video Track 3 |
| ⌃4 | Ctrl+4 | Toggle Target Video Track 4 |
| ⌃5 | Ctrl+5 | Toggle Target Video Track 5 |
| ⌃6 | Ctrl+6 | Toggle Target Video Track 6 |
| ⌃7 | Ctrl+7 | Toggle Target Video Track 7 |
| ⌃8 | Ctrl+8 | Toggle Target Video Track 8 |
| ⌃9 | Menu only | Toggle Target Video Track 9 |
| ⌃T | Menu only | Toggle Trim Type |
| ⌘9 | Ctrl+9 | Toggle Video Targets |
| ⌥← | Alt+Left | Trim Backward |
| ⌥⇧← | Alt+Shift+Left | Trim Backward 10 Frames |
| ⌥→ | Alt+Right | Trim Forward |
| ⌥⇧→ | Alt+Shift+Right | Trim Forward 10 Frames |
| ⌃⇧T | Ctrl+Shift+T | Trim Mode |
| ⌥W | Alt+W | Trim Next Edit to Playhead |
| ⌥Q | Alt+Q | Trim Previous Edit to Playhead |
| = | = | Zoom In |
| ⌃= | Menu only | Zoom In Vertically |
| - | - | Zoom Out |
| ⌃- | Menu only | Zoom Out Vertically |
| \ | \ | Zoom to Fit |

### Program monitor

| Mac | Windows and Linux | Command |
|---|---|---|
| ↓ | Down | Go to Next Edit |
| ↑ | Up | Go to Previous Edit |
| ⌥K | Alt+K | Play In to Out |
| ⌥] | Alt+] | Select Layer Above |
| ⌥[ | Alt+[ | Select Layer Below |
| F | F | Show in Source |
| ⇧R | Shift+R | Show in Timeline |
| 1 | 1 | Switch to Angle 1 |
| 2 | 2 | Switch to Angle 2 |
| 3 | 3 | Switch to Angle 3 |
| 4 | 4 | Switch to Angle 4 |
| 5 | 5 | Switch to Angle 5 |
| 6 | 6 | Switch to Angle 6 |
| 7 | 7 | Switch to Angle 7 |
| 8 | 8 | Switch to Angle 8 |
| 9 | 9 | Switch to Angle 9 |
| ⌃T | Menu only | Toggle Trim Type |
| ⌃⇧T | Ctrl+Shift+T | Trim Mode |

### Source monitor

| Mac | Windows and Linux | Command |
|---|---|---|
| ⌥K | Alt+K | Play In to Out |

### Project panel

| Mac | Windows and Linux | Command |
|---|---|---|
| ⌥P | Alt+P | Delete Poster Frame |
| ⌫ (Delete) | Backspace | Delete Project Items |
| ⌘F | Ctrl+F | Find… |
| ⇧H | Shift+H | Hover Scrub |
| ⌘⇟ | Ctrl+PgDn | Icon View |
| ⌘] | Ctrl+] | Larger Thumbnails |
| ⌘⇞ | Ctrl+PgUp | List View |
| ⌘B | Ctrl+B | New Folder |
| ⌥K | Alt+K | Play In to Out |
| ⌘P | Ctrl+P | Set Poster Frame |
| ⌘[ | Ctrl+[ | Smaller Thumbnails |

### Commands without a key by default

These are in the menus. You can give them a key in Window > Keyboard Shortcuts.

| Command | Menu |
|---|---|
| Accept All Proposed Cuts | Clip > Audio Options > Clean Up > Proposed Cuts |
| Accept Proposed Cut at Playhead | Clip > Audio Options > Clean Up > Proposed Cuts |
| Add Speed Point | Clip > Timing |
| Add Subject Mask | Clip > Video Options |
| Add and Edit Marker… | Markers > Marker |
| Anonymize… | Clip > Video Options |
| Auto | View > Track Height |
| Auto Reframe | Clip > Video Options > Fit Frame |
| Bleep | Sequence > New |
| Broadcast 2.4 | View > View Gamma |
| Card with Blurred Background | Clip > Video Options > Fit Frame |
| Check Cuts… | Sequence > Edit > Cut Tools |
| Continuous | View > Timeline Thumbnails |
| Create Angles Clip… | Clip > Multi-Clip > Angles |
| Crest | Clip > Timing > Speed Ramp Presets |
| Crest on Beat | Clip > Timing > Speed Ramp Presets > On Beat |
| Cut to Beats | Clip > Timing > Beat Edits |
| Dialogue | Clip > Audio Options > Tag Role |
| Disguise Voice | Clip > Audio Options > Voice |
| Dynamic Zoom In | Clip > Video Options > Dynamic Zoom |
| Dynamic Zoom Out | Clip > Video Options > Dynamic Zoom |
| Edit Dynamic Zoom | Clip > Video Options > Dynamic Zoom |
| Edit Marker… | Markers > Marker |
| Export EDL… | File |
| Export FCPXML… | File |
| Export Final Cut Pro XML… | File |
| Export Markers as CSV… | File |
| Export OpenTimelineIO… | File |
| Extend to Sequence End | Clip > Arrange |
| Fill Frame | Clip > Replace and Fit |
| Fill Reel… | Sequence > Edit > Cut Tools |
| Find Scene Changes | Clip > Video Options |
| Fit Music to Length… | Clip > Timing > Beat Edits |
| Fit to Fill | Clip > Replace and Fit |
| Fit to Frame | Clip > Replace and Fit |
| Fit with Blurred Fill | Clip > Video Options > Fit Frame |
| Go to Next Split Point | Sequence > Go To > Edit Points |
| Go to Previous Split Point | Sequence > Go To > Edit Points |
| Head | View > Timeline Thumbnails |
| Head and Tail | View > Timeline Thumbnails |
| Import Lottie Animation… | File |
| Import Motion Graphics Template… | File |
| Import Premiere Presets… | File |
| Import Premiere Project… | File |
| Import Project… | File |
| Import Timeline… | File |
| Insert Frame Hold Segment | Clip > Video Options > Holds and Fades |
| Jump Back 10 Frames | - |
| Jump Forward 10 Frames | - |
| Keep Intro and Outro When Trimmed | Clip > Arrange |
| Large | View > Track Height |
| Linear | Clip > Ease Keyframes |
| Live Ducking for This Project… | Clip > Audio Options > Loudness and Ducking |
| Mac 1.96 | View > View Gamma |
| Mark Overhang | Markers > Marker |
| Markers on Beat | Markers > Marker |
| Markers on Downbeats | Markers > Marker |
| Match Color to Clip | Clip > Video Options |
| Medium | View > Track Height |
| Music | Clip > Audio Options > Tag Role |
| New Tone… | Sequence > New |
| Nudge Clip Selection Left by Many | - |
| Nudge Clip Selection Right by Many | - |
| Picture in Picture | Clip > Multi-Clip > Split Screen |
| Picture in Picture (Circle) | Clip > Multi-Clip > Split Screen |
| Picture in Picture (Circle), Animated | Clip > Multi-Clip > Split Screen > Animated |
| Picture in Picture, Animated | Clip > Multi-Clip > Split Screen > Animated |
| Project Notes… | File > Project |
| Pulse | Clip > Timing > Speed Ramp Presets |
| Pulse on Beat | Clip > Timing > Speed Ramp Presets > On Beat |
| Punch | Clip > Timing > Speed Ramp Presets |
| Punch In Cuts… | Sequence > Edit > Cut Tools |
| Punch on Beat | Clip > Timing > Speed Ramp Presets > On Beat |
| Record Voice-Over | Clip > Audio Options > Voice |
| Reject All Proposed Cuts | Clip > Audio Options > Clean Up > Proposed Cuts |
| Reject Proposed Cut at Playhead | Clip > Audio Options > Clean Up > Proposed Cuts |
| Remove Blurred Fill | Clip > Video Options > Fit Frame |
| Remove Empty Tracks | Sequence > Tracks and Transitions |
| Remove Filler Words | Clip > Audio Options > Clean Up |
| Remove Silences… | Clip > Audio Options > Clean Up |
| Remove Speed Ramp | Clip > Timing |
| Replace at Playhead | Clip > Replace and Fit > Replace Modes |
| Replace from End | Clip > Replace and Fit > Replace Modes |
| Replace from Start | Clip > Replace and Fit > Replace Modes |
| Replace with Retime | Clip > Replace and Fit > Replace Modes |
| Revert | File > Project |
| Review Proposed Cuts… | Clip > Audio Options > Clean Up > Proposed Cuts |
| Rush | Clip > Timing > Speed Ramp Presets |
| Rush on Beat | Clip > Timing > Speed Ramp Presets > On Beat |
| SFX | Clip > Audio Options > Tag Role |
| Safe Margins | View > Show |
| Select Left Edge | Edit > Select |
| Select Right Edge | Edit > Select |
| Selection Follows Playhead | Sequence > Tracks and Transitions > Track Targets |
| Sequence Settings… | Sequence |
| Set Attach Point | Sequence > Storyline |
| Show Captions in Program | View > Show |
| Show Library | Window > Library (checkable item) |
| Show Markers | Window > More Panels > Markers |
| Show Overlays | View > Show |
| Show Scopes | Window > More Panels > Scopes |
| Show Sources | Window > More Panels > Sources |
| Show Speed Ramp | Clip > Timing |
| Show Steps | Window > More Panels > Steps |
| Side by Side 50/50 | Clip > Multi-Clip > Split Screen |
| Side by Side 50/50, Animated | Clip > Multi-Clip > Split Screen > Animated |
| Side by Side 60/40 | Clip > Multi-Clip > Split Screen |
| Side by Side 60/40, Animated | Clip > Multi-Clip > Split Screen > Animated |
| Slip Tool (Keyframes Stay) | View > Tools |
| Small | View > Track Height |
| Snap to Beats | Clip > Timing > Beat Edits |
| Stabilize | Clip > Video Options |
| Surge | Clip > Timing > Speed Ramp Presets |
| Surge on Beat | Clip > Timing > Speed Ramp Presets > On Beat |
| Sync Audio to Reference | Clip > Arrange |
| Three Stacked | Clip > Multi-Clip > Split Screen |
| Three Stacked, Animated | Clip > Multi-Clip > Split Screen > Animated |
| Toggle All Targets | Sequence > Tracks and Transitions > Track Targets |
| Toggle Hold | Clip > Ease Keyframes |
| Tone Settings… | Sequence > New |
| Top and Bottom 50/50 | Clip > Multi-Clip > Split Screen |
| Top and Bottom 50/50, Animated | Clip > Multi-Clip > Split Screen > Animated |
| Trim to In/Out | Clip > Arrange |
| Unlink | Clip > Link and Group |
| Voice Chain | Clip > Audio Options > Voice |
| Voiceover from Text… | Clip > Audio Options > Voice |
| Web 2.2 | View > View Gamma |
| Whoosh at Selected Cuts | Sequence > Edit > Cut Tools |
| SDR 100 nit Rec.709 | View > Display |
| Display P3 | View > Display |
| HDR 1000 nit | View > Display |
| Not Tone-Mapped | View > Display |

### Not sure yet

- Mac shortcuts that use both Control and Command (for example Control-Command-S) are shown as "Menu only" on Windows and Linux. How they are routed on a real PC has not been checked.
- The Windows and Linux column is worked out from the key map. It has not been tested key by key on a Windows or Linux PC.
- The keys shown for German, French and UK layouts are checked with simulated key presses only, not yet on a real PC with that layout.
- Whether a Linux input method (IBus, Fcitx) keeps Ctrl+Space (Quick Apply) for switching input sources. If it does, use the menu or change the key.

Related: [Editing](timeline-and-editing.md), [Settings and Updates](settings-and-updates.md), [Troubleshooting](troubleshooting.md)

## For developers

The key map lives in `crates/sq-uikit`; the Keyboard Shortcuts window is in `crates/sq-draw-shell/src/shell_shortcuts.rs`.

- `editor_command.rs`: `EditorCommand` (every command) and `CommandScope` (`Global`, `Timeline`, `Program`, `Source`, `Project`, `EffectControls`). `command_catalog.rs` lists the commands.
- `key_binding.rs`: `Key`, `KeyModifiers`, `KeyBinding`. `command_map.rs`: `CommandMap` with `entries: Vec<Entry { scope, binding, command }>` and a lookup table. `command_for(binding, focus)` looks in the focused panel's scope first, then in `Global`. A duplicate (scope, binding) pair keeps the first entry.
- Default sets: `CommandMap::sq_default_for(platform)` is the Classic NLE set (`premiere_default_for`) with a few overrides (Q and E ripple trim, W extends an edit, Shift+T is Keyword at Playhead, Trim mode on Ctrl+Shift+T). Only the Quick Apply key differs between the Mac and other systems. `KeymapPreset` (`Sq`, `Premiere`, `FinalCut`) names the three built-in sets.
- `keymap_store.rs`: `KeymapConfig` (preset, `overrides`, `custom_sets`, `active_set_id`) is saved as JSON under the defaults key `sq.keymap` (`KeymapStore::load` and `save`). The user's keys are stored as overrides over the active template, so a new default reaches users who did not change that key. `Keymap::apply`, `diff`, `conflicts` (`SameScope`, `ShadowedInPanel`, `ShadowsGlobal`, `Reserved`), `assign` and `unbind` are the editing rules. `Keymap::reserved()` lists five keys that cannot be assigned. `.sqkeys` files are JSON with a format tag (`KeymapSet::export_data`, `from_exported`).
- Import: `crates/sq-core-project/src/foreign_keymap.rs` and `foreign_keymap_formats.rs` read Premiere `.kys` and DaVinci Resolve layouts into neutral `ForeignChord`s, with command tables in `premiere_command_table.rs` and `fcpcommand_table.rs` (Final Cut `.commandset`). `sq-uikit/src/keymap_import.rs` (`KeymapImport::build`) merges them over the default: an imported command loses its base keys first, the imported binding wins a clash, and two imported claims on one key go to the first in file order.
- Windows and Linux: `key_binding_text.rs` has `KeyBindingText` (Mac glyph text and Windows text, with parsing) and `WindowsKeyRoute` (Ctrl stands for Command first and for Mac Control second; `candidates`, `command`, `shadowed`). `layout_keys.rs` matches a key press to a binding on the active layout (`chords`, `choose`, `cap`), and `key_character_resolver.rs` maps typed characters to physical keys. `menu_keys.rs` decides which Command-key bindings belong to menu items.
- Focus: `focus_routing.rs` maps Cut, Copy, Paste and Delete to the focused panel's target (`FocusedEditTarget`), which is why the Controls panel never edits clips. `panel_cycle.rs` implements Select Next and Previous Panel.

Tests (`cargo test -p sq-uikit`):

- `manual_shortcuts_tests.rs` keeps this page and the map in step. Every table row under the headings Everywhere, Timeline, Program monitor, Source monitor and Project panel must be a binding of the default map (Mac key, Windows and Linux key, command title) and the other way round; Effect Controls entries are skipped because the Timeline table lists the shared Add Keyframe key. A Windows cell "Menu only" means the Mac Control key lands on a key a Command shortcut uses there. The table "Commands without a key by default" (two columns: command, menu path) must list every menu command that has no key; "-" means no menu, "Window ..." rows are panel commands the shell builds.
- `layout_shortcuts_tests.rs` presses every key shown on a PC the way the US, UK, German and French layouts press it.
- `tests/command_tables.rs` covers imported key tables, command ids and the Windows key map.

Extension points: a new command is a variant of `EditorCommand` plus its title and id, an entry in `command_catalog.rs`, a binding in `command_map.rs`, a menu item (`menu_spec.rs`), and a row in this page. Run the manual test afterward: it fails until the page matches.

## For AI agents

- Source of truth: `CommandMap::sq_default_for(Platform::Mac)` and `...(Platform::Windows)` in `crates/sq-uikit/src/command_map.rs`. This page's tables must equal them; edit both in one change.
- Table format parsed by `crates/sq-uikit/src/manual_shortcuts_tests.rs`: a heading line `###` or `##` with one of `Everywhere`, `Timeline`, `Program monitor`, `Source monitor`, `Project panel` sets the scope. Rows are `| Mac key | Windows and Linux key | Command |` (exactly three cells split on ` | `; the header row starts with `Mac`). In the Mac cell " (Delete)" is stripped before comparing. A Windows cell may be `Menu only`. The Command cell is `EditorCommand::title()`.
- Second table under the heading `Commands without a key by default`: `| Command | Menu path |` (two cells). Every menu command with no key in the default map must be listed there, with its menu path (from `EditorMenus::visible()`, else `EditorMenus::all()`), or `-` for no menu.
- Do not rename these headings and do not add other `###` headings with a table of three cells under them: a heading not in the list ends the current scope.
- Scopes and lookup: focused panel scope first, then `Global` (`CommandMap::command_for`). Panel scopes: Timeline, Program, Source, Project, EffectControls.
- Storage: defaults key `sq.keymap`, JSON `KeymapConfig` with `preset` (`sq`, `premiere`, `finalCut`), `overrides`, `customSets`, `activeSetID`. Exchange format `.sqkeys` (JSON with a format tag). Import formats: Premiere `.kys`, DaVinci Resolve layout, Final Cut `.commandset`.
- Reserved keys that cannot be assigned: `Keymap::reserved()` (five bindings) in `crates/sq-uikit/src/keymap_store.rs`.
- Commands: `cargo test -p sq-uikit manual_shortcuts` (page against map), `cargo test -p sq-uikit layout_shortcuts`.
