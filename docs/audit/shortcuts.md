# Shortcut audit (macOS defaults)

Source of the Adobe column: `docs/reference/adobe/keyboard-shortcuts.txt`, `project-shortcuts.txt` (key names only). Our keys come from
`CommandMap.premiereDefault`. `CommandParityTests.defaultsMatchAdobe` pins every "Match" row; `documentedDeviationsAreReal` pins the deviations.
Run `SQ_DUMPMENU=1` on the app for the live menu plus the per-command table (title | menu | keys | wired), or walk `CommandAudit.rows`.

Scopes: Everywhere = global, TL = Timeline panel, PM = Program monitor, SM = Source monitor, Proj = Project panel. Needs fn = F-key on a laptop.

## Table

| Command | Our key | Adobe key | Status |
|---|---|---|---|
| New Project | Opt+Cmd+N | Opt+Cmd+N | Match |
| New Sequence | Cmd+N | Cmd+N | Match |
| New Bin | Cmd+/ (Everywhere), Cmd+B (Proj) | Cmd+/ (File), Cmd+B (Project panel) | Match (fixed: was Cmd+B everywhere, File menu now shows Cmd+/) |
| Open Project | Cmd+O | Cmd+O | Match |
| Save / Save As | Cmd+S / Shift+Cmd+S | Cmd+S / Shift+Cmd+S | Match |
| Import | Cmd+I | Cmd+I | Match |
| Export Media | Cmd+M | Cmd+M | Match |
| Undo / Redo | Cmd+Z / Shift+Cmd+Z | Cmd+Z / Shift+Cmd+Z | Match |
| Cut / Copy / Paste | Cmd+X / C / V | Cmd+X / C / V | Match |
| Paste Insert | Shift+Cmd+V | Shift+Cmd+V | Match |
| Paste Attributes | Opt+Cmd+V | Opt+Cmd+V | Match |
| Clear / Delete | Delete (TL) | Delete | Match (title says Delete, Premiere says Clear) |
| Ripple Delete | Shift+Delete, Opt+Delete (TL) | Shift+Fwd Delete (Edit), Opt+Delete (Timeline) | Match (Opt+Delete added) |
| Duplicate | Shift+Cmd+/ | Shift+Cmd+/ | Match |
| Select All / Deselect All | Cmd+A / Shift+Cmd+A | Cmd+A / Shift+Cmd+A | Match |
| Find | Cmd+F | Cmd+F | Match |
| Keyboard Shortcuts | Opt+Cmd+K | Cmd+Opt+K | Match |
| Settings | Cmd+, | none (macOS convention) | Addition |
| Audio Gain | G | G | Match |
| Audio Gain -1 dB / +1 dB | [ / ] (TL) | none found in the Adobe mirror | Addition (not pinned by the Adobe test; unverified) |
| Audio Gain -6 dB / +6 dB | Shift+[ / Shift+] (TL) | none found in the Adobe mirror | Addition (unverified) |
| Speed/Duration | Cmd+R | Cmd+R | Match |
| Insert / Overwrite | , / . | , / . | Match |
| Enable | Shift+Cmd+E | Shift+Cmd+E | Match |
| Link | Cmd+L | Cmd+L | Match |
| Match Frame / Reverse Match Frame | F / Shift+R | F / Shift+R | Match |
| Add Edit / Add Edit to All Tracks | Cmd+K / Shift+Cmd+K | Cmd+K / Shift+Cmd+K | Match |
| Extend Selected Edit | E | E | Match |
| Apply Video / Audio Transition | Cmd+D / Shift+Cmd+D | Cmd+D / Shift+Cmd+D | Match |
| Apply Default Transitions | Shift+D | Shift+D | Match |
| Lift / Extract | ; / ' | ; / ' | Match |
| Zoom In / Zoom Out | = / - | = / - | Match (menu entries moved from View to Sequence, as in Premiere) |
| Zoom to Fit | \ | none in the extract | Addition |
| Snap | S | S | Match |
| Mark In / Mark Out / Mark Clip | I / O / X | I / O / X | Match |
| Mark Selection | / | / | Match |
| Go to In / Go to Out | Shift+I / Shift+O | Shift+I / Shift+O | Match |
| Clear In / Clear Out / Clear In and Out | Opt+I / Opt+O / Opt+X | Opt+I / Opt+O / Opt+X | Match |
| Add Marker | M | M | Match |
| Next / Previous Marker | Shift+M / Shift+Cmd+M | Shift+M / Shift+Cmd+M | Match |
| Reset to Saved Layout | Opt+Shift+0 | Opt+Shift+0 | Match |
| Project / Source / Timeline / Program / Effect Controls / Effects | Shift+1 / 2 / 3 / 4 / 5 / 7 | same | Match |
| Library panel | Shift+6 | Shift+6 = Audio Track Mixer | Deviation: no mixer panel; Shift+6 opens our Library |
| Maximize Panel Under Pointer / Active Panel | ` / Shift+` | ` / Shift+` | Match |
| Play / Stop | Space | Space | Match |
| Shuttle Reverse / Stop / Forward | J / K / L | J / K / L | Match |
| Shuttle Slow Reverse / Forward | Shift+J / Shift+L | Shift+J / Shift+L | Match |
| Step Back / Forward | Left / Right | Left / Right | Match |
| Step 5 Frames | Shift+Left / Right | Shift+Left / Right | Match |
| Go to Start / End | Home / End | Home / End | Match |
| Go to Previous / Next Edit Point | Up / Down (TL, PM) | Up / Down | Match |
| ... on Any Track | Shift+Up / Shift+Down (TL) | Shift+Up / Shift+Down | Match |
| Select Clip at Playhead | D (TL) | D | Match |
| Play In to Out | Opt+K (PM, SM, Proj) | Opt+K | Deviation by scope: in the Timeline Opt+K is free; the monitors and the Project panel carry it so it never clashes with a timeline binding |
| Play In to Out with Preroll/Postroll | Shift+Space | Shift+Space | Match |
| Play Around | Shift+K | Shift+K | Match |
| Loop Playback | Ctrl+L | Cmd+L (only inside mixer and metadata panels) | Deviation: Adobe's Cmd+L is Link in the Timeline; Ctrl+L is Premiere's monitor loop key |
| Ripple Trim Previous / Next Edit to Playhead | Q / W (TL) | Q / W | Match |
| Trim Previous / Next Edit to Playhead | Opt+Q / Opt+W (TL) | Opt+Q / Opt+W | Match |
| Roll Previous / Next Edit to Playhead | Shift+Q / Shift+W (TL) | none in the extract | Addition |
| Trim Backward / Forward | Opt+Left / Opt+Right (TL) | Opt+Left / Opt+Right | Match (new command; before, these keys were bound to unwired "Previous/Next Keyframe" and trimmed as a side effect) |
| Trim Backward / Forward 5 Frames | Opt+Shift+Left / Right (TL) | Opt+Shift+Left / Right | Match |
| Toggle Trim Type | Ctrl+T (TL) | Ctrl+T | Match |
| Nudge Clip Selection Left / Right 1 Frame | Cmd+Left / Cmd+Right (TL) | Cmd+Left / Cmd+Right | Match (fixed: dead before, Command keys never reached the router) |
| Nudge Clip Selection Left / Right 5 Frames | Shift+Cmd+Left / Right (TL) | Shift+Cmd+Left / Right | Match (fixed, same reason) |
| Move Selection Up / Down | Opt+Up / Opt+Down (TL) | none in the extract | Addition |
| Increase / Decrease Video Track Height | Cmd+= / Cmd+- | Cmd+= / Cmd+- | Match |
| Increase / Decrease Audio Track Height | Opt+= / Opt+- | Opt+= / Opt+- | Match |
| Expand / Minimize All Tracks | Shift+= / Shift+- | Shift+- minimize listed; expand not in the extract | Match / Addition |
| Audio Scrubbing | Shift+S | Shift+S | Match (new key; was menu only) |
| Set Poster Frame / Clear Poster Frame | Cmd+P / Opt+P (Proj) | Cmd+P / none | Match / Addition |
| Hover Scrub | Shift+H (Proj) | Shift+H | Match |
| Export Frame | Shift+E | none in the extract | Addition (second binding Shift+Cmd+E removed earlier: it was Enable Clip's key) |
| Tools: V A Shift+A B N Y U C H Z T R | same | tool keys are not in the extract | Addition (Premiere's classic tool keys) |
| Easy Ease / Ease In / Ease Out | F9 / Shift+F9 / Shift+Cmd+F9 (Everywhere, needs fn) | none | Addition: After Effects keys, now wired to the keyframes selected in Effect Controls |
| Toggle Hold Interpolation | none (Clip menu only) | none | Match (Cmd+Opt+H was bound before and collides with Hide Others) |
| Show Time Remapping, Remove Time Remapping, Fade In/Out, Frame Hold, Set to Frame Size, Linked Selection, Captions in Program Monitor, Revert, Sequence Settings | menu only | none | Match |

## Removed (bound to nothing that works)

| Was | Why |
|---|---|
| Group (Cmd+G) | No group model; Adobe has it, listed as missing below |
| Previous / Next Keyframe (Opt+Left / Right) | Unwired; the keys now trim by one frame like Premiere |
| Add Keyframe (Opt+K, TL) | Unwired |
| Toggle Value/Speed Graph (Shift+F3) | Unwired |
| Cmd+Opt+H Toggle Hold Interpolation | Collides with Hide Others |

## Adobe defaults for things we do not have (not bound, listed for later)

Group / Ungroup (Cmd+G, Shift+Cmd+G), Make Subclip (Cmd+U), Edit Original (Cmd+E), Trim Edit (Cmd+T), Clear Selected Marker (Opt+M), Clear All Markers
(Opt+Cmd+M), Select Next / Previous Clip (Cmd+Down / Up), Go to Selected Clip Start / End (Shift+Home / End), Slip / Slide clip selection
(Opt+Cmd+arrows, Opt+, and Opt+.), Increase / Decrease Clip Volume (], audio stream), Play from Playhead to Out (Ctrl+Space), Render Effects in Work Area (Enter),
Save a Copy (Opt+Cmd+S), Close (Cmd+W), project panel list/icon view (Cmd+Page Up/Down), thumbnail size (Shift+[ / ]), Toggle All Audio/Video Targets (Cmd+9 / Cmd+0).

## Behaviour changes that go with the key work

- Command keys that have no menu item (nudge, Cmd+B in the Project panel) now go through the key router. Before, every key with Command was left to the menus, so those did nothing and beeped. `MenuKeys.owned` is the set that stays with the menus.
- While a text field is edited, Select All selects the text; panel-only Command shortcuts (Add Edit, Link, Speed/Duration, Deselect All) are disabled instead of acting on timeline clips.
- Menu items now disable when they cannot act: Paste/Paste Insert without a clipboard, Extend Edit / Toggle Trim Type / Trim Backward/Forward without a selected edit, Link without two clips or a linked clip, Set to Frame Size without a picture clip, Speed/Duration without a clip, Audio Gain without audio, easing without selected keyframes. Clip > Link reads "Unlink" for a linked group.
- Delete in the Project panel (icon view too) runs a real command instead of flashing "not available yet".

## Context menus

| Menu | Entries | Change |
|---|---|---|
| Timeline clip | Cut, Copy, Paste, Paste Insert, Paste Attributes, Clear, Ripple Delete, Link/Unlink, Enable/Disable, Nest, Speed/Duration, Show Time Remapping, Set to Frame Size, Audio Gain (audio clips), Label, Rename | Added Paste Attributes and Audio Gain; removed "Scale to Frame Size" (identical to Set to Frame Size) |
| Gap, empty track space | Ripple Delete / Paste / Paste Insert | none |
| Track header | Add Video Track, Add Audio Track, Delete Track, Rename | none (all exist) |
| Ruler | Add or Edit/Delete Marker, Clear In and Out | none |
| Transition | Set Transition Duration, Clear | none |
| Keyframe | interpolations, saved curves, Copy, Paste, Delete | none |
| Effect header | Enable/Disable, Cut, Copy, Paste, Clear, Reset, Duplicate | none (Cut and Clear were already there) |
| Project item / bin / empty | Open in Source Monitor, Insert, Overwrite, New Sequence From Clip, New Bin, Rename, Delete, Clear Poster Frame, Label, Reveal in Finder, Replace Footage / Link Media; empty: New Bin, New Sequence, Import, Find | none; Set Poster Frame stays Cmd+P (needs a hovered or Source frame) |
| Program monitor | Mark In/Out, Go to, Clear In and Out, Add Marker, Lift, Extract, Match Frame, Reverse Match Frame, Export Frame, Safe Margins, Loop, Zoom | Titles come from the commands and show their keys |
| Source monitor | Mark Clip/In/Out, Go to, Clear, Add Marker, Clear Marker(s), Insert, Overwrite, Export Frame, Loop, Zoom, Reveal in Project | Added Zoom; keys shown |
| Caption | Edit Caption Text, Split Caption at Playhead, Merge Captions, Delete | none |

Not in our menus because there is no command: Reveal in Project (timeline clip), Group, Make Subclip, Duplicate (project), Auto/Continuous Bezier.

## Tooltips

Toolbar, monitor transport buttons and the timeline Snap button build their text from the key map (`KeyboardListing.tip`), so a changed key cannot leave a stale hint
(Export Frame said Cmd+Shift+E, the real key is Shift+E; Play/Pause lost its key after the first state change). Track header buttons have no Premiere default keys.
Tests: `monitorButtonTipsShowTheirKeys`, `toolColumnKeysMatchTheMap`.

## Menu placement

Zoom In / Out / Fit moved from View to Sequence (Premiere puts them there). The rest of the menus already follow Premiere: File (New, Open, Save, Import, Export), Edit
(Undo, clipboard, Duplicate, Select, Find), Clip (Insert, Overwrite, Enable, Link, Speed, Audio Gain, Video Options), Sequence (Match Frame, edits, trims, transitions,
Lift/Extract, Snap), Markers, View, Window. Keyboard Shortcuts and Settings sit in the app menu (macOS).
