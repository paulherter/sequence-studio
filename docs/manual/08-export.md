# Export

Render your sequence to a file: presets, the export queue, smart rendering, captions and delivery targets.

## Export a video

1. Choose File > Export… (Command-M on the Mac, Ctrl+M on Windows and Linux).
2. Pick a preset at the top.
3. Set the File Name and the Folder.
4. Click Export. The job goes into the export queue.

The sheet opens at the size and shape of your sequence. If the preset it starts with (your last one, or the one that belongs to the sequence's delivery target) is made for another shape, such as YouTube 1080p on a vertical sequence or TikTok on a horizontal one, the size stays the sequence's own and the picture is not letterboxed. When you pick a preset yourself in the sheet, you get that preset's own size.

For a fast export with no dialog, use Quick Export (Option-Command-M, Windows and Linux Ctrl+Alt+M). It uses the sequence's platform preset and the last export folder (or the Movies folder on the Mac, the Videos folder on Windows and Linux, if there is none).

## Presets

| Group | Presets |
|---|---|
| Match Source | Match Source – High bitrate (H.264), Match Source – HEVC 10-bit, Best quality at size – H.264 (multi-pass) |
| YouTube | YouTube 1080p Full HD, YouTube 1440p QHD, YouTube 4K Ultra HD |
| Other sites | X (Twitter) 1080p (H.264), Facebook 1080p (H.264) |
| Short video | TikTok 1080×1920, Instagram Reels 1080×1920, YouTube Shorts 1080×1920 (H.264 or HEVC) |
| Instagram | Instagram Feed 4:5 1080×1350, Instagram Feed 1:1 1080×1080, Instagram Stories 1080×1920 |
| Master | ProRes 422 HQ, ProRes 422, ProRes 4444 |
| Audio only | M4A (AAC), WAV (24-bit PCM), FLAC (lossless) |
| Other | Animated GIF, Image sequence (PNG) |

The top card holds what almost every export needs: Size (type a width and height, swap them with the arrows, or pick 9:16, 16:9, 1:1 or 4:5), Quality (Smaller, Standard or Best, with the bitrate beside it; a step keeps the preset you picked and is remembered with it, while typing a bitrate, codec, size or frame rate yourself turns the preset into Custom), Format, Frame Rate, Audio, Captions, Range and Save to. The Result block on the left shows the estimated file size, the length and the target file. Everything technical is folded under More settings: Video details (profile, rate control, bitrate, hardware encoding, encoder speed, color space), Audio details and Advanced. Range exports the Entire sequence, In to Out, a Custom range, or the Selected clips, with an option for one file per clip. When the sequence has In/Out marks, an In / Out line shows the range the picked mode exports (Entire reads from the start to the end of the sequence).

HEVC, H.264 and ProRes are offered on all three systems. H.264 and HEVC use a hardware encoder when your computer has one and software otherwise. ProRes uses the Mac's hardware encoder when it is available; on Windows and Linux it is made in software.

## Delivery targets

A sequence can have a delivery target: TikTok, Reels, Shorts, a social feed post or YouTube. The target picks the matching export preset and the loudness (-14 LUFS, -1 dBTP true peak). With no target, the default is Match Source. For YouTube the preset follows the frame width: 1080p, 1440p or 4K. The target never changes the size of the sheet: a vertical sequence with a YouTube target still opens vertical.

## The export queue

Every export goes into the queue, so you can keep editing. Open the Export Queue to see each job as Waiting, Exporting, Done, Failed or Canceled. You can cancel a waiting or running job (stopping a running export asks first, and the unfinished file is deleted), reveal a finished file (Reveal in Finder on the Mac, Show in Explorer on Windows, Show in File Manager on Linux), and use Clear Finished. In a small window a long queue scrolls instead of running out of the window, so its header and its footer (Stop All, Clear Finished) stay in view.

## Smart rendering

When part of your sequence is a single untouched clip that already matches the export format, Sequence Studio can avoid re-encoding it. This keeps quality and saves time. It only counts when the clip has no effect, no change of size or speed, no title on top, and its codec, size, frame rate, bit depth and color tags already match what the export would write. If there is any doubt, it re-encodes.

## Captions with your video

In the Captions section choose None, Burn in, SRT file, VTT file or iTT file. SRT, VTT and iTT save a sidecar file next to the video, with the same name. Burn in draws the captions into the picture.

## Audio, cover and chapters

- Audio: Include Audio, Sample Rate (44.1, 48 or 96 kHz), Bit Depth, Channels, Normalize, Loudness Range, True Peak Max.
- Also save cover image: saves a PNG, with a Cover Frame you choose.
- Copy Chapters puts chapter text on the clipboard, to paste into a video description.
- Export Cut-downs and Export Stems are in the same sheet for extra files.

## Advanced

Keyframe Every, B-Frames, Alpha (Keep transparency, ProRes 4444), Damaged Frames (continue on damaged frames), HDR to SDR, HDR Gamut, Color Space and Peak Brightness. H.264 is tagged Rec. 709. "Also export every format variant" makes all variants in one go.

Settings > Media has "Use proxies when exporting". It is off by default and is meant for drafts only.

## Other formats

File also offers Export EDL…, FCPXML…, OpenTimelineIO… and Markers as CSV….

## Export a single frame
**File > Export Frame** (Shift+E) saves the picture the Program monitor (or the Source monitor) shows as a still, at the full size of the sequence whatever the monitor quality is. The save panel's format list offers PNG, JPEG, TIFF (16-bit) and EXR (half float, linear); the file name suggested is the sequence name. PNG and JPEG are 8-bit, TIFF is 16-bit, all with the Rec.709 curve like the monitor; EXR keeps the linear light values. PNG and TIFF keep an alpha channel when the picture has transparent areas (turn on the transparency grid to see them); JPEG is always opaque, EXR always has alpha. JPEG uses quality 95. The PNG file is tagged Rec.709 (cICP chunk); TIFF, JPEG and EXR carry no color tag.

## Windows and Linux

HDR export (HEVC, PQ) works on Windows; it was checked on one PC. On Windows the hardware encoders tried are NVIDIA NVENC, AMD AMF, Intel Quick Sync and Windows Media Foundation, in that order; on Linux it is VA-API. They honor the bitrate (average or constant), 10-bit HEVC, Keyframe Every, the H.264 profile (Baseline, Main or High; a Baseline file has no B-frames) and, where the encoder has them, B-Frames. Without a hardware encoder H.264 is written by OpenH264 and HEVC by Kvazaar, both 8-bit; OpenH264 writes no B-frames, and neither does multi-pass. The sheet names the encoder that will run and marks what it cannot do as not available on this computer (for example the B-Frames box and the H.264 profile), instead of writing a file that ignores it. Your choice of format is never swapped for another: if no 10-bit HEVC encoder is available (Main 10, HDR), Main 10 is greyed out with "not available on this computer" and the export stops with a message that says what to choose instead (turn on hardware encoding, HEVC Main, H.264 or ProRes). The same holds for a computer with no H.264 or HEVC encoder at all; no MPEG-4 file is written in their place.

## Not sure yet

- Where the Export Queue button sits in the window.
- Exact hardware encoder support on Windows and Linux, and whether HDR export works on Linux.
- Whether ProRes files made on Windows and Linux open in every other editor.
- Which HEVC color space choices appear for each preset.

Related: [Titles and Captions](06-titles-and-captions.md), [Audio](07-audio.md), [Settings and Updates](10-settings-and-updates.md), [Troubleshooting](12-troubleshooting.md)
