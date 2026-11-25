# Roadmap

Sequence Studio is an open-source video editor for Mac, Windows and Linux, written in Rust. It is in alpha.
This page lists everything that is still planned, small things included, in one table sorted by priority.
It has no dates and no version numbers: we ship when it works, and 1.0 comes only when the app is really finished.

Last reviewed: 2026-11-19

## How to read the table

Items are sorted by priority, then by rank inside a priority. Finished items sit at the end of their priority group.
The priorities are:

1. Smooth playback and reliability, including that everything the app offers really works, local crash reports with a pre-filled GitHub form, and Stable and Nightly channels.
2. Transcription and captions.
3. An AI assistant that works over a local MCP server.
4. Masks, tracking and object removal.
5. Switching from other editors, the preset and pack library, and learnability.
6. Platform work: zero-copy video on Windows and Linux, signed installers, self-update, render cache.
7. Later: plugins, node-based color, motion design.

Status is one of `in progress`, `not started` or `done`. Good machines always play at full preview quality; a reduced
preview is meant only for very weak machines. The app collects no telemetry.

## Give feedback

- Bugs: [open an issue](https://github.com/paulherter/sequence-studio/issues/new/choose).
- Ideas: post them in [Discord](https://discord.gg/q6KPQc8WCA). Tell us the problem you have before the solution you want.
- Anything else: [open an issue](https://github.com/paulherter/sequence-studio/issues/new/choose).
- Questions and chat: [Discord](https://discord.gg/q6KPQc8WCA).
- To build something yourself, open an issue first so nobody works twice on the same thing, then follow
  [CONTRIBUTING.md](CONTRIBUTING.md).

## The list

| ID | Priority | Area | Item | Status |
| --- | --- | --- | --- | --- |
| SQ-001 | 1 | Playback | A benchmark suite measures frame spacing, dropped frames, audio dropouts and start times, and rejects speed changes that slow playback. | in progress |
| SQ-002 | 1 | Playback | A video with a graded 4K clip on top plays smoothly on the Mac, as the earlier Swift version did. | in progress |
| SQ-003 | 1 | Playback | 4K clips shown small are decoded at reduced size on the Mac, so memory use and dropped frames fall. | in progress |
| SQ-004 | 1 | Playback | Color grades run on specialised GPU kernels and layers are composited once per displayed frame, so graded layers cost less. | in progress |
| SQ-005 | 1 | Playback | Playback threads run at higher priority than background work, so exports and proxy jobs never cause stutter. | in progress |
| SQ-006 | 1 | Playback | Loudness matching, import, scopes, animated text and work at clip boundaries no longer block playback on the interface thread. | in progress |
| SQ-007 | 1 | Playback | Good machines always play at full preview quality; a half-resolution preview is used only on very weak machines. | not started |
| SQ-008 | 1 | Playback | When a machine cannot keep up, the monitor offers the fix (lower preview quality, make a proxy) instead of stuttering. | not started |
| SQ-009 | 1 | Playback | Play may start up to half a second late while a short pre-roll fills, so playback starts without a stutter. | not started |
| SQ-010 | 1 | Playback | Each layer gets a ring cache, decoders are released when idle, and fully hidden layers are skipped, so many clips do not exhaust memory. | not started |
| SQ-011 | 1 | Playback | Windows and Linux decode 4K layers with catch-up decoding, which roughly halves CPU use per frame. | not started |
| SQ-012 | 1 | Playback | Four stacked 4K layers play smoothly on every system, eight with reduced preview only where the machine needs it. | not started |
| SQ-013 | 1 | Playback | A broken file, unsupported codec or failed hardware decode shows a message in the monitor, never a silent black frame. | not started |
| SQ-014 | 1 | Playback | On a computer without a usable graphics driver the app starts with a clear 'software graphics, slow' notice. | not started |
| SQ-015 | 1 | Playback | Unplugging or switching the audio device during playback keeps the playhead running and sound returns when possible. | not started |
| SQ-016 | 1 | Playback | Screen recordings and phone clips with variable frame rate play and cut cleanly, with a hint on the clip. | not started |
| SQ-017 | 1 | Playback | The monitor and each clip show the proxy state, such as 'Proxy 2 of 5', and proxy creation pauses while you play or export. | not started |
| SQ-018 | 1 | Playback | Memory stays flat with hundreds of large photos or deeply nested sequences; heavy cases give a clear message, never a black frame. | not started |
| SQ-019 | 1 | Playback | Opening a project and jumping to an exact frame in 4K footage feel instant. | not started |
| SQ-020 | 1 | Export | Export is faster than real time for 4K H.264 on Mac and PC, with scaling on the GPU and B-frames on the Mac. | not started |
| SQ-021 | 1 | Export | The caption files (SRT, VTT, ITT) and cover image that the export dialog offers are actually written. | not started |
| SQ-022 | 1 | Export | Export writes to a temporary file first, so a failed or cancelled export never destroys the old file. | not started |
| SQ-023 | 1 | Export | Exported files look the same in QuickTime, VLC and web browsers, with correct color tags. | not started |
| SQ-024 | 1 | Export | HEVC export warns honestly when no HEVC encoder is available instead of quietly using something worse. | not started |
| SQ-025 | 1 | Export | The export dialog can render from the original or from proxies for fast draft exports. | not started |
| SQ-026 | 1 | Text & Captions | The WebVTT writer keeps '-->' inside caption text, and the reader keeps cues whose identifier is 'STYLE'. | not started |
| SQ-027 | 1 | Editing | Razor cuts made through the edit API round to whole frames or return a clear error. | not started |
| SQ-028 | 1 | Editing | Switches such as snapping, linked selection and track targets no longer count as undo steps. | not started |
| SQ-029 | 1 | Editing | Typing letters into number, timecode and text fields never triggers shortcuts. | not started |
| SQ-030 | 1 | Editing | Keys that do nothing and greyed-out commands say why, for example which locked track blocks a ripple. | not started |
| SQ-031 | 1 | Reliability | Every command that answers 'not available on this computer yet' on Windows and Linux either works or is greyed out with a reason. | not started |
| SQ-032 | 1 | Reliability | Settings and menu items that have no effect are connected or removed, including 'check for updates on start'. | not started |
| SQ-033 | 1 | Reliability | The audio mixer's track inspector controls change the sound, and audio scrubbing is connected with the default off. | not started |
| SQ-034 | 1 | Reliability | The 37 features never checked by hand in a real window (drag-in, trackpad, J/K/L sound, HDR) are checked on all three systems. | not started |
| SQ-035 | 1 | Reliability | A real-file test set (phone HEVC and HDR, Sony S-Log3, DJI, GoPro, ProRes, screen recordings) is opened, played and exported on every release. | not started |
| SQ-036 | 1 | Reliability | Readers for outside files (Premiere projects, SRT and VTT, LUTs, FCPXML, EDL, OTIO) are fuzz-tested so broken files never crash the app. | not started |
| SQ-037 | 1 | Reliability | Crashes, including Rust aborts on Windows, write a local report; at the next start you can review it and choose to send it. | not started |
| SQ-038 | 1 | Reliability | Help > Report a Problem opens a pre-filled GitHub form with version, system, graphics card and recent log lines, shown before anything is sent. | not started |
| SQ-039 | 1 | Reliability | The app collects no telemetry and says so in the README and in the app. | not started |
| SQ-040 | 1 | Reliability | Projects keep opening in every later version, with migration tests for older formats. | not started |
| SQ-041 | 1 | Reliability | A project that uses an effect the app does not know opens and saves without losing it, and shows an 'effect missing' notice. | not started |
| SQ-042 | 1 | Reliability | Opening a damaged or oversized project file gives a clear error instead of crashing, and autosave recovers after errors. | not started |
| SQ-043 | 1 | Reliability | Effects look the same in preview at reduced resolution as in the final export. | not started |
| SQ-044 | 1 | Reliability | A broken LUT file shows an error instead of being ignored. | not started |
| SQ-045 | 1 | Reliability | Before each release a short release-candidate period fixes only things that got worse. | not started |
| SQ-046 | 1 | Platform | Stable and Nightly release channels, switchable in the settings; Nightly warns you to back up your projects. | not started |
| SQ-047 | 1 | Platform | Stabilization (Gyroflow), auto reframe, HDR display and export, and hardware encoding behave on Windows and Linux like on the Mac, and are verified there. | not started |
| SQ-048 | 1 | Platform | Windows and Linux get a complete set of default shortcuts, checked in a real window. | not started |
| SQ-049 | 1 | Platform | Scrolling and zooming with a trackpad feel equally good on Mac, Windows and Linux. | not started |
| SQ-050 | 1 | Community | A Discord channel for pre-release builds carries a pinned list of known problems, and every bug report gets a first answer within seven days. | not started |
| SQ-200 | 1 | Color | The Program and Source viewers set the area around the picture apart from black video (a gray or checkerboard backdrop, switchable), so the frame edge is always visible. | not started |
| SQ-201 | 1 | Platform | On Linux the main window keeps its rounded corners at small window sizes. | not started |
| SQ-202 | 1 | Platform | On Linux (KDE Plasma) the installer and update window shows no gray veil outside its rounded corners. | not started |
| SQ-051 | 1 | Playback | Heavy clips get a proxy automatically. | done |
| SQ-052 | 1 | Export | Hardware encoding works on Mac, Windows and Linux (VideoToolbox, NVENC, AMF, QSV, VAAPI), with an honest warning when 10-bit is missing. | done |
| SQ-053 | 1 | Reliability | The 22 commands that did nothing are now wired up; a Mac export crash, the Linux file dialog and an EQ error are fixed. | done |
| SQ-054 | 1 | Reliability | Crashes write a local report on Mac, Windows and Linux, and a first-run tour explains the basics. | done |
| SQ-055 | 2 | Transcription | The speech model is chosen from measurements on real clips on Mac, Windows and Linux, not from guesses. | not started |
| SQ-056 | 2 | Transcription | Transcription uses the GPU on Mac and PC, and a faster, more accurate model than the small default. | not started |
| SQ-057 | 2 | Transcription | Word times are accurate to about one frame, with voice activity detection. | not started |
| SQ-058 | 2 | Transcription | Words at J-cuts and L-cuts are never missing from the transcript. | not started |
| SQ-059 | 2 | Transcription | The transcript is saved in the project; re-transcribing keeps your corrections and only covers used ranges. | not started |
| SQ-060 | 2 | Transcription | The app asks before replacing corrected captions when you transcribe again. | not started |
| SQ-061 | 2 | Transcription | A word list for names and special terms, added only if tests show fewer name errors. | not started |
| SQ-062 | 2 | Transcription | The Transcribe button says why it is greyed out, and the model download shows progress and restarts cleanly. | not started |
| SQ-063 | 2 | Transcription | Transcript search works across sources, and 'Remove Silences' says so when there is no pause to remove. | not started |
| SQ-064 | 2 | Text & Captions | Caption files can be written for any caption track, with a button in the caption list. | not started |
| SQ-065 | 2 | Text & Captions | Caption look is separate from caption animation, and you can keep several styles and apply your own with one click. | not started |
| SQ-066 | 2 | Text & Captions | Caption styles can be copied and pasted, every style setting shows in preview and export, and karaoke highlighting and free position are available. | not started |
| SQ-067 | 2 | Text & Captions | Safe zones for TikTok, Reels and Shorts keep captions out of the platform's buttons. | not started |
| SQ-068 | 2 | Text & Captions | Arabic, Hebrew, Hindi, Thai and other complex scripts display correctly in titles and captions, including text input. | not started |
| SQ-069 | 2 | Text & Captions | Captions keep their exact frame positions when you ripple, trim or close gaps. | not started |
| SQ-070 | 2 | Text & Captions | Add Title starts with empty text, the length setting works, and the look row shows a preview. | not started |
| SQ-071 | 2 | Text & Captions | A smaller set of redesigned caption animations replaces the current large list. | not started |
| SQ-072 | 2 | Text & Captions | You can type, drag and resize text and captions in the monitor, and edit their keyframes in the Graphics panel. | not started |
| SQ-073 | 2 | Transcription | Whisper transcription with word times runs inside the app on CPU. | done |
| SQ-074 | 2 | Text & Captions | The Captions panel has Transcript, Captions and Style tabs with look, layout and motion, and imports and exports SRT. | done |
| SQ-075 | 3 | AI Assistant | A local MCP server on Mac, Windows and Linux with one button to connect an AI assistant, ideally served by the existing local server. | not started |
| SQ-076 | 3 | AI Assistant | Menus, shortcuts, panels and the assistant share one command list, and every refused command says why. | not started |
| SQ-077 | 3 | AI Assistant | Unknown keys, tracks or out-of-range values return an error with the valid choices, never a silent default. | not started |
| SQ-078 | 3 | AI Assistant | The assistant can read the project, transcript, audio levels and single frames or contact sheets around cuts, in small windowed answers. | not started |
| SQ-079 | 3 | AI Assistant | After each change a measured report lists duration, gaps, overlaps, audio and video offset, and loudness. | not started |
| SQ-080 | 3 | AI Assistant | Destructive edits appear as proposed cuts you accept, and each assistant job is one undo step. | not started |
| SQ-081 | 3 | AI Assistant | A permissions card shows what the assistant may do; it is read-only by default and asks first before deleting or exporting. | not started |
| SQ-082 | 3 | AI Assistant | The app shows when the assistant is connected, working, waiting for approval or has failed. | not started |
| SQ-083 | 3 | AI Assistant | The assistant can only read and write in folders you allow, and path tricks are refused. | not started |
| SQ-084 | 3 | AI Assistant | Exports and transcriptions run as jobs with progress and cancel, and a call that timed out never runs later. | not started |
| SQ-085 | 3 | AI Assistant | No web page or second program can control the local port, and a busy port gives a clear message. | not started |
| SQ-086 | 3 | AI Assistant | The assistant can edit text, export settings and properties, not only cuts (today: 14 cut operations). | not started |
| SQ-087 | 3 | AI Assistant | 'Remove pauses longer than 0.35 s' is the first assistant job, offered as a suggestion. | not started |
| SQ-088 | 3 | AI Assistant | A style profile learned from your own projects lets the assistant cut the way you do. | not started |
| SQ-089 | 3 | AI Assistant | The assistant can build a short clip from raw footage, using only operations a person also needs. | not started |
| SQ-090 | 3 | AI Assistant | An optional chat panel inside the app, after the assistant is measured to work well. | not started |
| SQ-091 | 3 | AI Assistant | The local edit API with 14 cut operations works with a token on localhost, is off by default, and undoes as one step. | done |
| SQ-092 | 4 | Masks & Tracking | Magic Mask shows the mask on click, tracks with Enter, smooths edges, and runs on the GPU or Neural Engine on the Mac. | not started |
| SQ-093 | 4 | Masks & Tracking | Drag a box to select an object for Magic Mask, like other editors. | not started |
| SQ-094 | 4 | Masks & Tracking | Person and face detection as a starting point works on Windows and Linux without Apple Vision. | not started |
| SQ-095 | 4 | Masks & Tracking | Tracking is its own object: put a point on a nose, apply it to text, an effect or a mask. | not started |
| SQ-096 | 4 | Masks & Tracking | Tracking data can become keyframes, and the camera or crop can follow a tracked point. | not started |
| SQ-097 | 4 | Masks & Tracking | Pin text or an image to a flat surface such as a wall or screen with four-corner tracking that survives occlusion. | not started |
| SQ-098 | 4 | Masks & Tracking | Mask tracking and point tracking are tested on real clips, including perspective. | not started |
| SQ-099 | 4 | Masks & Tracking | Auto reframe follows face tracking, handles scene changes, and always explains when it fails. | not started |
| SQ-100 | 4 | Masks & Tracking | Object removal is tried first outside the app and built in only if results are good; the app says shadows and reflections stay. | not started |
| SQ-101 | 4 | Masks & Tracking | Gyroflow is chosen automatically when a clip has gyro data, with a 'Gyro data found' note. | not started |
| SQ-102 | 4 | Masks & Tracking | Stabilization results are cached so a second run starts at once, and long analysis runs use bounded memory and cancel within seconds. | not started |
| SQ-103 | 4 | Masks & Tracking | Stabilize from the Clip menu can queue several clips at once. | not started |
| SQ-104 | 4 | Masks & Tracking | Stabilization says whether it worked, for example 'Partly stabilized'. | not started |
| SQ-105 | 4 | Masks & Tracking | Green-screen keying keeps colored edges such as red hair or flames free of green. | not started |
| SQ-106 | 4 | Masks & Tracking | Magic Mask has a click flow with EdgeTAM; it is marked experimental. | done |
| SQ-107 | 4 | Masks & Tracking | Masks follow footage in position, scale, rotation and perspective. | done |
| SQ-108 | 4 | Masks & Tracking | Gyroflow stabilization, auto reframe and face anonymize are available on all three systems. | done |
| SQ-109 | 5 | Import | The Premiere project import report lists, per clip, what was skipped and is saved with the project. | not started |
| SQ-110 | 5 | Import | Premiere import is checked against many real projects; text style, layer order, folders, audio faders and pan, Lumetri color and time remapping come across. | not started |
| SQ-111 | 5 | Import | You can import one project into the open project to merge two projects. | not started |
| SQ-112 | 5 | Import | Final Cut and Resolve exchange handles .fcpxmld bundles, project picture size and unsupported library files with a clear hint. | not started |
| SQ-113 | 5 | Import | Media import is predictable: copy or leave files, reconnect in one step, search with filters; phone clips with rotation import correctly. | not started |
| SQ-114 | 5 | Learnability | On first start you choose the shortcuts you know (Premiere, Final Cut, Resolve), and Premiere terms work as search words. | not started |
| SQ-115 | 5 | Learnability | The first start opens Home, and every empty panel says in one sentence what to do, with at most one button. | not started |
| SQ-116 | 5 | Learnability | Locked controls explain why, and about twenty fields get a hint line. | not started |
| SQ-117 | 5 | Learnability | The same word means the same thing everywhere, and aliases are only search help. | not started |
| SQ-118 | 5 | Learnability | The Help key opens the manual page for the current panel. | not started |
| SQ-119 | 5 | Learnability | Screen readers (VoiceOver, Narrator) are tested for real, and the findings are fixed. | not started |
| SQ-120 | 5 | Editing | Right-click on a sequence offers 'Other format ...' for 16:9, 4:5 and 9:16 versions. | not started |
| SQ-121 | 5 | Editing | In a format variant, text stays inside the picture, each clip can use fill, fit or blur, and the list shows which clips differ. | not started |
| SQ-122 | 5 | Editing | Transform and crop handles, mask tools and zoom keys work directly in the monitor. | not started |
| SQ-123 | 5 | Editing | Speed ramps are easy to find: the speed band appears by itself and presets sit in one row. | not started |
| SQ-124 | 5 | Editing | You can leave a nested group or Combine again with one command. | not started |
| SQ-125 | 5 | Editing | A four-point edit asks before silently cutting clips, and Append to the end of the timeline has its own shortcut. | not started |
| SQ-126 | 5 | Editing | Hidden tool variants such as Ripple, Roll and Slide are easy to discover in the toolbar. | not started |
| SQ-127 | 5 | Export | Export offers Fit, Fill and Stretch, and warns when the picture shape changes. | not started |
| SQ-128 | 5 | Library & Packs | One library view for presets, looks, LUTs, transitions and titles, with the built-in items as one pack. | not started |
| SQ-129 | 5 | Library & Packs | Packs can be switched off, removed cleanly and show their icon and license. | not started |
| SQ-130 | 5 | Library & Packs | One save dialog stores a preset or only its motion. | not started |
| SQ-131 | 5 | Library & Packs | Importing .cube, .mogrt (more completely) and .prfpset files works from one place, and .lottie files can be read. | not started |
| SQ-132 | 5 | Library & Packs | Presets and effects are found by search words for all effects and transitions, for example 'camera shake' finds Shake. | not started |
| SQ-133 | 5 | Library & Packs | Zoom presets are easy to reach and Dynamic Zoom takes two clicks. | not started |
| SQ-134 | 5 | Library & Packs | Transitions sit in family folders, and one can be set as default for the shortcut. | not started |
| SQ-135 | 5 | Effects | New position, scale and rotation keyframes use smooth easing by default. | not started |
| SQ-136 | 5 | Effects | Look effects that show nothing when applied get a visible start value. | not started |
| SQ-137 | 5 | Color | Dragging a LUT onto a clip applies it, instead of only a double click. | not started |
| SQ-138 | 5 | Color | Clips without a color tag ask for the input color space; camera log is suggested from the file, never applied silently. | not started |
| SQ-139 | 5 | Color | A before/after strip and the scopes are available on the Edit page. | not started |
| SQ-140 | 5 | Audio | Clean Voice has a menu entry and one undo step, and loudness is measured after it. | not started |
| SQ-141 | 5 | Audio | A safety limiter at the final output prevents peaks above -1 dBTP, and ducking timing is tuned by listening tests. | not started |
| SQ-142 | 5 | Audio | One loudness target per sequence replaces the targets in five places. | not started |
| SQ-143 | 5 | Audio | Compressor, limiter and EQ show their effect with level meters and curves. | not started |
| SQ-144 | 5 | Audio | Text-to-speech reads prices, times and dates naturally on every system. | not started |
| SQ-145 | 5 | Community | About five newcomers per release try the first five minutes: import, cut, caption, export. | not started |
| SQ-146 | 5 | Community | People coming from Premiere, Resolve and Final Cut each edit a fixed test project, and results are published. | not started |
| SQ-147 | 5 | Community | A short public yearly survey asks what blocks you. | not started |
| SQ-148 | 5 | Effects | Quick Apply finds every command by name from the keyboard. | done |
| SQ-149 | 5 | Library & Packs | Packs (.sqpack) and Lottie and MOGRT import are available. | done |
| SQ-150 | 5 | Import | Premiere Pro projects import with a report, and FCPXML, OTIO, EDL and XMEML are read and written. | done |
| SQ-151 | 5 | Color | The color picker works in the color panel, and scopes are available. | done |
| SQ-152 | 5 | Audio | Clean Voice, noise reduction, live ducking and Match Loudness are available. | done |
| SQ-153 | 6 | Platform | Zero-copy video on Windows (Direct3D 11 to 12) and Linux (VA-API to Vulkan), with a CPU fallback. | not started |
| SQ-154 | 6 | Platform | Linux uses hardware decoding where the driver offers it. | not started |
| SQ-155 | 6 | Platform | Frames are timed against real display timestamps. | not started |
| SQ-156 | 6 | Platform | The Windows installer is code-signed, so SmartScreen shows no warning. | not started |
| SQ-157 | 6 | Platform | The app updates itself, following your chosen channel. | not started |
| SQ-158 | 6 | Platform | Release builds for all systems are made in the cloud, so a release does not depend on one machine. | not started |
| SQ-159 | 6 | Platform | A render cache for very heavy sections, with timeline stripes showing what is ready, and cache size and 'Delete Cache' in settings. | not started |
| SQ-160 | 6 | Platform | Display color management on Windows and Linux (Windows color management, Wayland color management). | not started |
| SQ-161 | 6 | Export | AV1 export through hardware encoders where available. | not started |
| SQ-162 | 6 | Export | A bundled software HEVC encoder, once the license question is settled. | not started |
| SQ-163 | 6 | Platform | Installers and packages are checked automatically before release: Mac signature, a fresh Windows machine, and the Linux AppImage on an older system. | not started |
| SQ-164 | 6 | Platform | The Windows installer and the Linux AppImage are available. | done |
| SQ-165 | 7 | Plugins | A documented plugin interface, starting with packs and plugins that run as separate programs, with clear license terms for authors. | not started |
| SQ-166 | 7 | Plugins | Plugin authors get wiki pages and a check command, and an Extensions page in the settings lists, starts and stops plugins. | not started |
| SQ-167 | 7 | Plugins | A throw-away trial shows whether OpenFX effects can run in the app; OpenFX and shader packs follow only if fixed thresholds are met. | not started |
| SQ-168 | 7 | Motion Design | A motion-design area built on the layer and compositing foundation, once people use the app for it. | not started |
| SQ-169 | 7 | Color | Color accuracy is measured against a reference grader on generated test images, and camera log curves are checked against manufacturer values. | not started |
| SQ-170 | 7 | Color | LUTs no longer clip above 1.0, and the LUT cache is keyed by content. | not started |
| SQ-171 | 7 | Color | A wide-gamut working color space (ACEScct as second choice) runs on CPU and GPU; old projects stay in their old mode until you switch. | not started |
| SQ-172 | 7 | Color | An output transform at the end of the chain: none, simple or filmic, with dither, and an ACES 2.0 option. | not started |
| SQ-173 | 7 | Color | A color-management indicator warns about double conversions. | not started |
| SQ-174 | 7 | Color | Waveform, parade, vectorscope and histogram run on the GPU and match a reference, with scales, a skin-tone line and a CIE chart. | not started |
| SQ-175 | 7 | Color | The exported file matches the viewer picture, and grading speed is measured on each GPU class and kept inside a budget. | not started |
| SQ-176 | 7 | Color | An optional node view: grade nodes with a data model that converts old pro grades without loss. | not started |
| SQ-177 | 7 | Color | Corrector nodes with fixed order, group switches, a strength slider, labels, colors and locks. | not started |
| SQ-178 | 7 | Color | Parallel, layer, key mixer, splitter and combiner nodes, with all blend modes. | not started |
| SQ-179 | 7 | Color | A list view and a graph view of the nodes, with refused connections shown clearly. | not started |
| SQ-180 | 7 | Color | One eyedropper works for qualifier and curves, and order hints warn about, for example, a qualifier after desaturation. | not started |
| SQ-181 | 7 | Color | RGB mixer, sizing, color space nodes and a gamut limiter. | not started |
| SQ-182 | 7 | Color | Primaries with reference formulas: lift, gamma, gain, offset, contrast, pivot, saturation, hue, temperature, tint. | not started |
| SQ-183 | 7 | Color | HDR zones with exposure-scale controls. | not started |
| SQ-184 | 7 | Color | Full curves: custom curves, soft clip and six hue-saturation-luminance curves. | not started |
| SQ-185 | 7 | Color | Color Warper: draw from one color to another, plus a grid warper for experts. | not started |
| SQ-186 | 7 | Color | Qualifier by hue, saturation, luminance and RGB, with presets, highlight view, matte cleanup, a 3D qualifier and despill. | not started |
| SQ-187 | 7 | Color | Windows (power windows) with on-screen handles and presets, and tracking that makes them follow footage. | not started |
| SQ-188 | 7 | Color | Magic Mask can serve as a matte inside a grade, with negative clicks. | not started |
| SQ-189 | 7 | Color | Blur, sharpen, mist and midtone detail inside the corrector. | not started |
| SQ-190 | 7 | Color | All grade values can be animated with keyframes. | not started |
| SQ-191 | 7 | Color | Viewer aids: highlight, difference, wipe styles, split, zebra, clipping and gamut warnings. | not started |
| SQ-192 | 7 | Color | Every color tool is labeled as measured against a reference or as an approximation. | not started |
| SQ-193 | 7 | Color | Grade layers per clip, versions and stills for comparison, shared nodes (one grade for many clips) and compound nodes. | not started |
| SQ-194 | 7 | Color | Grade templates that apply to many clips at once, with switchable nodes and exposed controls, and a template library. | not started |
| SQ-195 | 7 | Color | CDL and LUT import that lists what could not be carried over, plus LUT export (.cube) and CLF read and write. | not started |
| SQ-196 | 7 | Color | More exchange: a LUT built from a before-and-after pair, CDL values from EDL, ALE and FCPXML files, and ACES AMF files. | not started |
| SQ-197 | 7 | Color | Film emulation: develop, print and scan stages with presets, plus halation and grain. | not started |
| SQ-198 | 7 | Color | Auto balance and shot matching bring several clips to one reference, with skin protection. | not started |
| SQ-199 | 7 | Color | Color tools in the assistant interface: analyze, compare, correct, match, LUT and film, with guard rails and an evaluation suite. | not started |

## Known problems

- **Experimental features.** Magic Mask, mask and point tracking, stabilization (including Gyroflow) and auto reframe
  have had little hands-on testing. Results vary with the footage.
- **The Windows installer is not code-signed.** Windows may show a SmartScreen warning ("Windows protected your PC"); see
  [Troubleshooting](docs/wiki/troubleshooting.md).
- **Windows and Linux are new.** They have had less hands-on testing than the Mac. Some commands answer "not available
  on this computer yet". Hardware encoding depends on the graphics driver and falls back to software.
- **HDR.** HDR export on Windows was checked on one PC; on Linux it is not verified.
- **Not yet tried over long sessions on a real device:** dragging files in from the system, trackpad feel, screen
  readers (VoiceOver, Narrator), audio sync with external devices.
- **Voiceover from Text on Linux** needs `espeak-ng` from your package manager.
- **Premiere import** covers a subset of effects and project features. The import report lists what was skipped.
- **Caption files and cover image on export.** The export dialog offers them, but this build ends with "Caption sidecars
  are not available in this build".
- **Updates are manual.** Download the new installer, AppImage or disk image; Help > Check for Updates tells you when
  one is out.

## Not planned

- Intel Macs, Windows on ARM and Linux on ARM, until someone who uses them every day helps with a port.
- DNx export and Resolve `.drp` or AAF import, unless enough people ask for them.
- Subscriptions, accounts and telemetry: never.
