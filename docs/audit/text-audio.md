# Audit: text, captions, audio (stream text-audio, 2026-10-01 night)

Sources: `docs/PREMIERE-BEHAVIOR.md` sections 8 and 9, the code, general Premiere knowledge. The Adobe mirror
(`docs/reference/adobe`) had almost nothing on these topics yet; everything marked (unverified) is from memory.
Time stays rational; all new edit logic has tests in SSCore, SSText, SSTranscribe or SSEditorUI.

## Type tool and text style

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Click with Type tool | Point text at the click, caret in it | Same (5 s clip, top free video track) | none | already there, default style is now bold white (title) |
| Drag with Type tool | Area text box, wraps | Dashed rubber band, area text clip (`TextTemplate.box`), wraps, caret in the box | was missing | yes |
| Click on existing text with Type tool | Edits it | Hit test on text clips at the playhead, edits in place | was missing (made a second text) | yes |
| Double-click with Selection tool | Edits in place | Same (overlay double-click) | none | already there |
| End editing | Esc, click outside | Esc, Cmd+Return, click outside, tool change | Cmd+Return missing | yes |
| Keys while editing | Cmd+A, arrows, Opt+arrows, Cmd+B/I | Standard text keys via NSTextView; Cmd+B toggles Bold/Regular, Cmd+I italic | Cmd+B/I missing | yes |
| Empty box | Discarded | Discarded, no undo trace | none | already there |
| Font, style, size | Yes | Family, weight (8 steps), size, Italic checkbox (real italic face, else 12 degree oblique) | italic | yes |
| Alignment | Left/centre/right, top/middle/bottom for area text | Left/centre/right, Top/Middle/Bottom (area text) | vertical | yes |
| Tracking, leading | Yes | Tracking (kern) and Leading fields | tracking | yes |
| Fill, stroke (colour, width) | Yes | Yes (outer stroke) | stroke inside/centre not offered | no |
| Background (colour, opacity, padding, radius) | Yes | Yes, plus an Opacity field | opacity field | yes |
| Shadow (colour, opacity, angle, distance, blur) | Yes | Yes, angle/distance/opacity fields (stored as offset + alpha) | angle, distance, opacity | yes |
| Renders in playback and export | Yes | One path (`TextGenerator`) for the monitor, `TimelineFrameSource`, caption burn-in; pixel tests for tracking, italic, vertical alignment, shadow alpha | none | yes (StyleRenderingTests) |
| TikTok/YouTube defaults | n/a | Styles `title` (bold white + soft shadow), `tiktok` (heavy, black stroke), `youtube` (bold on dark box) in the Library text templates; Type tool uses `title` | | yes |

## Captions

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Transcribe sequence | Dialog, whole sequence, speakers | Transcribe the selected clip's media; Create Captions maps the transcript onto every clip of that media on the sequence (cut interviews, linked A/V counted once) | multi-media sequences need one transcript per media; no speaker labels | partly |
| Create Captions options | Max characters, single/double line, min duration, gap (frames) | Dialog with the same four options plus style preset; presets Standard and Short Video (18 chars, one line, tiktok) | none | yes |
| Caption track on timeline | Trim, move, split, merge | Trim and move (existing), Split at Playhead, Merge Captions, Delete, Add Caption (context menu, Text panel) | | yes |
| Edit text | Text panel, monitor | Text panel list (double-click or Return in a row), double-click on the timeline caption jumps there. Not in the monitor | edit in the monitor | no |
| Search/replace | Find and replace in transcript | Find, Replace with, Match Case, Replace All over all captions; Return jumps to next match | | yes |
| Caption style | Style for the track | One popup applies style to all captions (one undo step) | per-caption style, saved user styles for captions | partly |
| Caption display in Program monitor | Yes (toggle) | Yes, same look and place as the burn-in (always on) | no toggle | yes |
| Burn-in on export | Yes | Wired now: Export "Burn in captions" was not connected to the caption track before | | yes |
| SRT export | Yes | Export SRT… button in the Captions tab (sidecar SRT in the export dialog existed) | | yes |
| Timing on the frame grid | Frame based | Captions from a transcript snap to frames, never overlap; default new caption and text clip lengths end on a frame (5 s at 29.97 = 150 frames) | | yes |
| Word highlight styles | Not in Premiere's basic flow | out of scope | | no |

## Audio

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Clip volume in Effect Controls | dB, keyframes | dB scrub field, keyframable (already) | | already there |
| Volume rubber band | Line on the clip, drag, Cmd-click key, drag keys | Drawn on audio rows 40 pt and taller; drag the line (whole clip, or the segment between keys), Cmd-click adds a key, drag keys (time and level), right-click key: Delete Keyframe; one undo step per drag | pen tool, key selection/multi-select | yes |
| Audio Gain (G) | Set gain to, Adjust gain by, Normalize max peak, Normalize all peaks | Dialog with the four modes; separate `Clip.audioGainDB` on top of volume, linked audio of a selected video clip is included, peak from the waveform data | normalise needs the waveform to be analysed | yes |
| Waveform reflects gain | Yes | Waveform draws volume line times gain (before it ignored both) | | yes |
| Mute / solo per track | M, S | Already there | | already there |
| Audio scrubbing | Preference | View menu toggle, remembered; off = drag and step are silent | | yes |
| Default fades / crossfades | Constant Power on transitions only | No audio transitions in the engine; seeks and edits use 5 ms anti-click fades. Not added | audio transitions | no |
| Mono / stereo | Mono is centred on both | Mono files fill both sides equally (test with a generated mono WAV) | no channel mapping or panner | partly |
| Linked A/V out of sync | Red badge with frames | Badge `+n` / `-n` on both clips when linked clips of the same media differ by 1 frame or more (slip, independent move) | | yes |
| Audio/video sync, off-by-one | | Tests at 29.97: razor, move, trim, ripple delete keep linked clips in sync; caption boundaries half-open | | yes |

## Found and fixed while testing
- Burn-in captions were never passed to the export frame source.
- Captions were invisible in the Program monitor.
- The waveform in the timeline ignored volume.
- Double-click on a caption did nothing (handler not wired).
- Text clips and captions were created with lengths between frames at 29.97 fps.
