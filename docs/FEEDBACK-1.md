# Paul's feedback, first app test (2026-09-30 night)

Vision: a clean Premiere — feels the same, runs faster, more modern, flawless on any Mac. No clutter.

## Works / praised
- Scrubbing is very fast (better than Premiere). Playback works. Nest works. Rounded Corners effect works.

## Bugs
- B1 Space (play) plays a macOS error beep every time (key not consumed).
- B2 Clicking elsewhere while playing: playback must STOP and stay stopped until Play/Space; transport icon gets out of sync (shows playing when paused).
- B3 Dragging a Project item out of the panel and back in moves/duplicates it to the bottom as if re-imported.
- B4 Moving clips to other tracks is flaky (needed several tries); linked audio doesn't follow: moving video up one track must move the linked audio down one track (Premiere mirrors the track offset).
- B5 S-Log3 shows only yellow (decode side, Phase 2 session fixing).
- B6 Effect Controls show nothing useful yet; Sequence Settings missing (can't switch to 9:16).

## Timeline
- T1 Trim cursors: Premiere-style trim-in/trim-out (and ripple) cursors on clip edges so you see you can lengthen/shorten.
- T2 Tools: tool column with Selection (default) and Razor (C); Razor click cuts the clip, Shift+click cuts all tracks. Others later.
- T3 No big empty grey area below the tracks: track area fits the panel (extra space goes to track heights / tracks anchored so no dead space).

## Project panel
- P1 Label colours (Premiere): colour swatch at the left of each item; the same colour is the clip colour in the timeline. Defaults per type (video, audio, sequence, nested sequence, colour matte, text…), user-changeable.
- P2 Type icons: video, audio, video+audio (combined icon), sequence, nested sequence, colour matte, text, image…
- P3 Default columns: Name, Frame Rate. Other metadata columns user-selectable (column chooser), saved.

## Effects
- E1 Drag effect onto clip (in progress).
- E2 Later: Option+Space effect search palette; Enter applies to the selected clip. Presets are part of the Effects panel (a "Presets" folder, user folders, save own presets).

## Other
- Source monitor: low priority for Paul (others may use it).
- Sequence Settings dialog (resolution/aspect incl. 1080×1920, fps, audio rate) + New Sequence with presets.
