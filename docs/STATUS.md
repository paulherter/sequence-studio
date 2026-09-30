# Status

## Current: Phase 1 started (SSCore, tests first)
Done in Phase 1: `Time`/`TimeRange`, `Clip`, `Track` (overwrite / insert / split / remove / ripple delete), `Timeline` with **sequence-wide ripple** (31 tests green): `rippleDelete`, `rippleTrim` (head/tail), `insert`; plain `trim`, `roll`, `slip`, `move` (overwrite) in Timeline+Edits.swift, all link-aware (54 tests green). Tracks have `isLocked` and `syncLock`; ripple shifts every unlocked sync-locked track, locked tracks never move and an edit on a locked track throws. Linked A/V partners are deleted/trimmed together.
Next in Phase 1: snapping logic; undo (snapshot history); project file (Codable + versioning). One slice per session.

## Phase 0 (done) — engine route B decided
Done: XcodeGen project (`project.yml`, empty SwiftUI app), six packages in `Packages/` (SSCore, SSMedia, SSRender, SSPlayback, SSExport, SSTranscribe, each with one placeholder test), `scripts/build.sh`, `scripts/test.sh [Package]` (errors only), decode/scrub spike in `Tools/DecodeSpike`.
Engine: Route B (own VideoToolbox path), see DECISIONS.md; Phase 2 acceptance criteria + risk items in PLAN.md.

## UI design (2026-09-30, done: Paul approved)
Canvas artifact "Sequence Studio UI": https://claude.ai/artifact/6mArdzhxkp4P9abYXJHP63 (private).
Tokens + screens: 1 workspace 9:16, 2 Effect Controls speed graph + easing menu, 3a/3b captions, 4a export, 4b export details,
4c export queue, 5 quick color + Scopes tab, 6 Color page (Edit | Color switch). UX.md, PLAN.md and DECISIONS.md updated to match.
Direction: Final Cut / Compositor look with AppKit controls, Premiere handling but never Premiere's glyphs; scrubbable values (no sliders); compact tracks; one color per clip type; one radius/spacing scale (tokens.css in the canvas).
Done. Handoff: docs/DESIGN.md. The artifact is the copy of record (canvas sources were only in the session scratchpad).

## Environment gotcha
`swift` on PATH is the swiftly shim (6.3.3) and links against the CLT SDK (MacOSX27.0.sdk) → "tapi error: malformed file". Use `/usr/bin/swift` (Xcode toolchain). The scripts already do. Package tools-version is 6.2 (needed for `.macOS(.v26)`).

## Spike results (M1 Max, release build, `Tools/DecodeSpike`; rerun: `cd Tools/DecodeSpike && /usr/bin/swift build -c release && .build/release/DecodeSpike [Sony|iPhone|<path>]`)
Route A = AVFoundation (AVAssetReader / AVComposition + custom `AVVideoCompositing` / AVPlayer seek). Route B = own `VTDecompressionSession` fed by `AVSampleCursor` + `AVSampleBufferGenerator` (no cache, no renderer). First 240 frames of each clip. Compositor is a no-op (no Metal), so these are decode + hand-off costs only.

| Clip | Format | Route B: VT hardware | Route B: VT software | A: reader decode | A: reader + composition + compositor |
|---|---|---|---|---|---|
| Sony C2160.MP4 | H.264 High 4:2:2 10-bit, 3840×2160, 29.97, 140 Mbit/s, GOP≈27, no color tags | **266 fps** (HW) | **fails** (-8969, 0/241 frames) | 166 fps | 212 fps |
| iPhone IMG_1281.MOV | HEVC Main 8-bit, 1920×1080, 59.96, 12 Mbit/s, GOP≈47, BT.709 | 2800 fps (HW) | 1290 fps | 364 fps | 483 fps |
| extra: iPhone 18 Pro/P1000065.MP4 | HEVC Main10 4:2:0 10-bit, 3840×2560, 29.97, 48 Mbit/s, GOP≈14, BT.709 | 619 fps (HW) | 183 fps | 183 fps | 195 fps |

Scrub latency (20 random targets, then 30 adjacent single-frame steps; time from seek call until the frame reaches the compositor / is decoded):

| Clip | B: VT random access (decode from previous sync frame) | A: AVPlayer+compositor random seek | A: AVPlayer+compositor 1-frame step |
|---|---|---|---|
| Sony C2160 | med 95 / p95 136 ms (up to 30 frames deep) | med 94 / p95 133 ms | med 11 / p95 32 ms |
| iPhone IMG_1281 | med 12 / p95 21 ms (up to 55 deep) | med 7 / p95 20 ms | med 1 / p95 3 ms |
| P1000065 (4K HEVC 10-bit) | med 19 / p95 29 ms (up to 15 deep) | med 18 / p95 36 ms | med 11 / p95 21 ms |

Native decoded formats: Sony `x422` (10-bit 4:2:2, VT hands out the Apple-compressed `&xf2` variant), P1000065 `x420`, iPhone IMG_1281 `420v` (compressed `&8v0` from VT).

### What the numbers say
- Hardware decode works on this M1 Max for all three, **including H.264 4:2:2 10-bit** (Sony). That clip has no software fallback through VideoToolbox: hardware only, ~9× realtime for one stream.
- Both routes land within noise of each other on random-access scrub (Sony ~95 ms both; cost is GOP depth × per-frame decode). Route A's 1-frame step is fast because AVPlayer keeps decoding forward; B would need the same (keep the session, decode next sample) plus a frame cache to match.
- Route A reader tops out below raw VT on the Sony clip (166–212 vs 266 fps) — irrelevant for one stream at 30 fps, may matter for stacked 4K layers.
- Not measured: multi-stream (stacked 4K layers), reverse playback / backward step, real Metal compositor cost, memory, audio sync. iPhone 1080p HW number (2800 fps) is pipelined throughput and likely optimistic; treat 1080p as "not a bottleneck".

### Caveats
- **No HLG/HDR iPhone clip exists in ~/Documents/Videos** (scanned all 210 files: iPhone clips are BT.709, 8-bit or 10-bit). HLG decode, color tags and tone mapping are untested. Sony clips carry no color tags at all (`? / ? / ?`) → S-Log3 must be assigned by us (detect by camera metadata or user choice).
- Sony clip is landscape 3840×2160, not vertical as previously noted.
- Timings vary run to run by ~10% (random targets); the spike is Swift 5 mode, throwaway code.

## Known facts
- Sony: long-GOP (GOP≈27) H.264 High 4:2:2 10-bit L5.1, 140 Mbit/s, LPCM audio.
- 124 of the 210 clips in ~/Documents/Videos are ProRes (`apcs`, 1080×1920) — likely exports.

## Open decisions
- None.
