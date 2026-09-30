# Paul's feedback, third app test (2026-10-01 night)

Works: timeline now behaves properly; embedded camera LUT is applied automatically (OK for Paul); Tint works.

## Bugs
- Space still doesn't play (routing logs show `.playPause` dispatched) — fix slice running.
- App closed during colour grading. Older crash log: EXC_BAD_ACCESS in AppController.handle (key monitor) while the quit alert's modal loop runs (AppController.swift:319 via applicationShouldTerminate NSAlert).
- Drop from Finder onto the timeline: video lands, audio has no waveform preview and overlaps another clip's audio. Drop from Project panel onto upper tracks: audio stays on A1 (must mirror: V2 → A2) → overlaps.
- Sequence set to vertical in Sequence Settings, then all clips deleted and a new clip dropped → sequence format switches again. Only an auto-created, never-configured sequence may adopt the first clip's format.
- Portrait clips still landscape (media slice running). Switching Edit ↔ Color shifts/stretches the Program picture until something else redraws.

## Scale semantics
- A 4K clip in a 1080×1920 sequence shows at 100 %; rotated 90° it needs 180 % to fill — confusing. Use Premiere semantics: 100 % = source pixels at sequence scale; "Set to Frame Size" / "Scale to Frame Size" in the clip context menu; rotation-aware.

## Colour (make it like Premiere's Lumetri)
- Correction results feel unlike Premiere or Final Cut ("weird results"); is the gamma/display path correct?
- Premiere-like controls: Basic Correction (Input LUT; White Balance: Temperature, Tint; Tone: Exposure, Contrast, Highlights, Shadows, Whites, Blacks; Saturation, Vibrance), Creative (Look LUT + intensity), Curves, Colour Wheels (Shadows/Midtones/Highlights), Vignette. Wheels must work.
- Sections collapsible (disclosure arrow), each with enable toggle and reset; "+" to add sections (another LUT, another correction, wheels…) and order them freely.
- Double-click a slider knob resets it to default.
