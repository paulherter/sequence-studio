# Audit: monitors, Source edit path, Project panel (stream `monitors`)

Sources: Adobe user-guide mirror in `docs/reference/adobe` (keyboard-shortcuts, playing-assets: marked [A]), `docs/PREMIERE-BEHAVIOR.md`.
Shortcuts are the Mac mapping of Adobe's Windows list (Ctrl+Shift -> Option for Clear In/Out). (unverified) = not found in a source.

## Source monitor and source edits

| Feature | Premiere | Sequence Studio before | Gap | Done tonight |
|---|---|---|---|---|
| Source monitor panel | Plays one clip, own transport | Placeholder panel ("Not connected yet") | Everything | Yes: own engine (one-clip sequence in the clip's format), own audio output, pauses the Program monitor and vice versa |
| Open a clip | Double-click in Project; Open in Source Monitor | none | | Yes (double-click, context menu, Match Frame) |
| Mark In / Out (I, O) | Source marks when Source has focus [A] | only sequence marks | | Yes, stored in `Project.sourceMarks`, not an undo step |
| Go to In / Out (Shift+I / Shift+O) [A] | yes | sequence only | | Yes, per focused monitor |
| Clear In / Out / both | Mac Option+I / Option+O / Option+X [A: Win Ctrl+Shift+I/O/X] | only both (Option+X) | Clear In, Clear Out | Yes, source and sequence; menu entries |
| Insert `,` / Overwrite `.` [A] | Source In..Out at sequence In, else playhead; targeted tracks | Inserted the Project selection at the playhead | no Source monitor, no targets | Yes: `EditorSession.sourceEdit` (SSCore `Timeline.sourceEditRange/Position/Targets`), tests |
| Playhead after edit | Moves to end of new clip | stayed | | Yes |
| Three-point rule | In + Out in source, In or playhead in sequence; fourth point computed | | Our sequence In/Out always carry both ends, so a sequence Out cannot shorten the source | Partly: sequence In (else playhead) is the position, source range from marks. No four-point "Fit Clip" dialog, no sequence-Out-defined edit |
| Source patching | Patch buttons per source channel, separate from targeting | Only `Track.isTargeted` exists | No separate patch state | Used `isTargeted` as patch + target. An untargeted kind is dropped (as Premiere). No target at all: V1 + mirrored audio. Needs the timeline stream if it adds real patches |
| Drag video-only / audio-only icons | yes | none | | Yes: film / waveform handles under the Source picture; dragging the picture drops both. Drop honours `SourceStreams` (ghost too) |
| Insert/Overwrite buttons | yes | n/a | | Yes, Source button bar |
| Match Frame F / Reverse Match Frame Shift+R [A] | Opens clip under playhead in Source / moves playhead to matching frame | Commands existed, not supported | | Yes (SSCore `matchFrame`, `reverseMatchFrame`, tests): selected clip, then targeted track, then topmost video; menu + Program context menu |
| Source markers (M in Source) | clip markers | none | Not available | No (status message) |
| Multiple clips in Source (dropdown history) | yes | none | | No |
| Audio-only sources (waveform view) | waveform display | black picture | | No |

## Transport (both monitors)

| Feature | Premiere | Now | Gap | Done |
|---|---|---|---|---|
| Space, J/K/L, K+J/K+L slow and frame step | [A] J, JJ, K+J slow, K+tap J = 1 frame | existing state machine (1,2,4,8; K+J/L slow 1/4; tap = frame) | speed step table of Premiere not published in [A] | kept; Source monitor has its own Shuttle state |
| Shift+J / Shift+L "slightly faster/slower", up to five times [A] | yes | none | | Yes: +-1/4 steps (`PlaybackRate.nudged`, tests) |
| Left/Right, Shift+Left/Right (5 frames), Home/End | yes | Program only | Source | Yes (Source handles them when focused) |
| Play In to Out | Ctrl+Shift+Space; Shift+Space = with preroll/postroll [A] | none | | Yes: Shift+Space + wrench menu, stops at Out (preroll variant not built); `PlaybackBounds` |
| Loop | Loop icon / transport | none | | Yes: wrench menu, Ctrl+L (key unverified), both monitors |
| Button bar | Marker, In, Out, Go to In, Step back, Play, Step fwd, Go to Out, (Insert, Overwrite) / (Lift, Extract), Export Frame | different order, no Lift/Extract/Export | | Yes, same order; tooltips with shortcut |
| Scrub strip under the picture | yes | none | | Yes: whole length, In/Out range, playhead, drag to scrub |
| Timecode: click to type, drag to scrub, duration | yes | click to type, duration | drag | Yes |
| Button editor | + customises buttons | none | | No |

## Program monitor

| Feature | Premiere | Now | Done |
|---|---|---|---|
| Lift `;` / Extract `'` | buttons + keys | keys + menu only | buttons added |
| Export Frame | Shift+E [A] (brief: Cmd+Shift+E) | none | Yes, both keys, button, menu, context menu; PNG/JPEG via save panel (BT.709 curve like the viewer) |
| Zoom popup Fit, 25..400 % | yes | existed | kept |
| Safe margins | toggle, 90 % / 80 % (unverified percentages) | none | Yes: wrench menu + context menu, draws on the picture rect |
| Context menu (right-click) | Mark/clear, markers, Lift/Extract, Match Frame, zoom, safe margins ... | none | Yes (only entries we can run) |
| Playback resolution | yes | existed | kept |
| Transform overlay / Type tool / pan-zoom | another stream | | untouched |

## Project panel

| Feature | Premiere | Now | Done |
|---|---|---|---|
| List view columns | Name, Frame Rate, Media Duration, Video info ... | Name + Frame Rate | default now Name, Frame Rate, Duration, Format (users keep their saved layout) |
| Icon view, thumbnail size slider | yes | none | Yes: icon view (toggle next to the search field), size slider, bin navigation with up button |
| Hover scrub | yes | none | Yes: pointer position over the icon picks the frame, playhead line |
| Rename | Return | existed (click edit conflicted with double-click) | Return / menu; double-click now opens |
| Double-click | media -> Source, sequence -> Timeline, bin -> opens | none | Yes (bin: expand in list, enter in icons) |
| New Bin Cmd+B | yes | context menu only | Yes: File menu + key, name edit in place |
| Drag into bin | yes | list only | list and icon view |
| Search | yes | existed | kept |
| Labels | yes | existed | kept (both views) |
| New Sequence From Clip | context menu / drag onto New Item | none | Yes: context menu (clip's own size and rate, whole clip). Drag onto New Item not built (no such button) |
| Sequence presets | | size and rate separate | Yes: preset popup (YouTube 1080p / 4K at 24, 25, 30, 50, 60; TikTok/Shorts/Reels 1080x1920 at 24, 25, 30, 60) |
| Reveal in Finder | yes | existed | kept |
| Replace Footage / Link Media | yes | none | Yes: keeps clips, marks, label (`Project.replaceMedia`, tests); no automatic search for neighbours |
| Offline in red | yes (red/media offline) | existed in list | icon view too |
| Context menus | item / bin / empty | one mixed menu | Yes, three variants; dead entries left out |
| Insert / Overwrite from Project menu | yes | | Yes |

## Still missing

Source markers, Source clip history dropdown, four-point edit (Fit Clip), real source patch buttons (needs timeline stream), Play In to Out with preroll,
button editor, delete of sequences from the Project panel, automatic relink search from the menu, Premiere's shuttle speed table (not in the guide).
