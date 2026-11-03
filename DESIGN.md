# Sequence Studio design (short form)

Source of truth: the design artifact (v11) and its boards in `build/design-boards/` (HTML in `html/`), values in
`docs/design-source/sq.css`. The shared draw UI reads values only through `DrawTheme` and the SQDrawKit `Canvas`. Token API: `docs/DESIGN-SYSTEM.md`.
Where this file and a board differ, the board wins.

## The shared draw UI (default on Mac and Windows)
Mac and Windows run the same UI code: `SharedUIController` (`App/Sources/SharedUI/SharedUIController.swift:26-36`, the Mac host;
the Windows host is `Windows/SQWinApp/Sources/SQWinApp/AppController.swift`) over SQDrawKit, SQDrawShell, SQDrawTimeline,
SQDrawMonitor, SQDrawLibrary and SQAppShell. A UI change lands once in that code. Design rules below name the draw-UI
source (the AppKit fallback UI is gone since 2026-11-02; its notes are in `docs/archive/DESIGN-APPKIT-COMPONENTS.md`).
- **Tokens: `DrawTheme`** (`Packages/SQDrawKit/Sources/SQDrawKit/DrawTheme.swift:7`), the source of design values today. Surfaces and
  text (canvas, divider, titlebar, panel, content, lane, timeline, overlay, label/label2/label3, accent, accentFill) come from
  SQUIKit `AppearancePalette.resolve(settings)` (`DrawTheme.swift:13`, `Packages/SQUIKit/Sources/SQUIKit/AppearancePalette.swift:86`).
  Translucent fills and lines are `inkFill(_:)` / `inkLine(_:)` over the palette ink (`DrawTheme.swift:38-39`); metrics, spacing,
  radii and type sizes are `DrawTheme.Metrics` / `Spacing` / `Radius` / `TypeSize` (`DrawTheme.swift:69-106`); marker colors
  `DrawTheme.marker(_:)` (`DrawTheme.swift:111`). Lengths are points; `px(_:)` multiplies by the window `scale` (`DrawTheme.swift:18`).
  Timeline colors: `TimelineSkin` over a `DrawTheme` (`Packages/SQDrawTimeline/Sources/SQDrawTimeline/TimelineSkin.swift:13`).
- **Draw API: `Canvas`** (`Canvas.swift:8`) writes quads into a `DrawList` (`DrawList.swift:47`: shape, glyph, video, triangle,
  segment, image). A panel draws once; the backend decides the pixels.
- **Icons:** the same Lucide set as ever (`SQIcon`). Path data is parsed by `SQIconPathData` (`Packages/SQUIKit/Sources/SQUIKit/SQIconPathData.swift:14`)
  into a `SQIconPathSink`; the draw UI's sink is `IconOutline` (`Canvas+Icon.swift:7`), which flattens curves to polylines, and
  `Canvas.draw(icon:at:size:_:)` (`Canvas+Icon.swift:71`) strokes them (1.6 on the 24 grid, thicker below 16 pt; filled shapes for
  `SQIcon.isFilled`). The AppKit fallback renders the same files to a `CGMutablePath` (`SQIconPathData.swift:1-4`).
- **Text:** the `GlyphAtlas` (`GlyphAtlas.swift:11`) packs glyph coverage into one 8-bit page; quads sample it. Windows sets all UI
  text in the bundled Inter (`Windows/.../AppController.swift:110`, `GlyphAtlas.init` default `.inter`, `GlyphAtlas.swift:37`). The Mac
  sets UI text in the system font (SF, `GlyphRasterFont.macSystemUI`, `SharedUIController.swift:208`) and falls back to Inter for
  characters SF lacks (`GlyphAtlas.swift:9-10`, `76-92`). A character that SF lacks therefore looks the same on both systems; the
  letterforms of ordinary text differ (SF on Mac, Inter on Windows).
- **Renderers:** Windows: `UIRenderer` (`Windows/SQWinApp/Sources/SQWinApp/UIRenderer.swift:11`) draws the quads with D3D12 (HLSL
  generated from `DrawQuads.slang`, lines 26-27). Mac: `MetalDrawListRenderer` (`MetalDrawListRenderer.swift:14`; MSL of the same module,
  line 34) is the default (`SharedUIView.swift:55`); `CoreGraphicsRenderer` (`CoreGraphicsRenderer.swift:10`) is the Mac CPU path, used when
  Metal is unavailable or `SQ_SHARED_UI_CG=1` (`SharedUIView.swift:55-58, 210-225`) and for UI screenshots (`SharedUIShot.swift:24`).
  `SoftwareRenderer` (`SoftwareRenderer.swift:18`) is the CPU renderer that returns an `RGBAImage`.

## Tokens (sq.css var -> role; the draw UI reads the roles from `DrawTheme`, the table's last column is the old `Theme` name)
| Role | Value | Token |
|---|---|---|
| Bar (top bar, panel headers) | #232326 | `titlebar` |
| Support heart and its filled button (Support entries only) | #EA4AAA | `Colors.support` |
| Panel body | #1e1e21 | `panel` |
| Content (lists, wells, key canvases) | #19191c | `content` |
| Timeline / lane | #151518 / #18181b | `timeline` / `lane` |
| Layer (menus, popovers, dialogs) | #2a2a2e | `overlay` |
| Picture surround (Program, Source, Color viewer; Metal clear color `Presenter.surround` equals it) | #2c2c2c | `monitorBackdrop` (1.5:1 over the picture's black) |
| Scopes / export preview backdrop | #0c0c0c | `viewer` |
| Gap between panel cards and around the workspace (2 pt; cards have 3 pt radius, no divider line under the top bar) | #080809 (never pure black) | `divider` |
| Hairline | white 6.5 % | `separator` |
| Text 1 / 2 / 3 | #e6e6e8 / #b2b2b8 / #9c9ca2 (opaque) | `label` `label2` `label3` |
| Fill / fill2 / hover / pressed | white 11 / 6 / 16 / 22 % | `fill` `fill2` `fillHover` `fillPressed` |
| Field / edge | black 28 % / white 10 % | `field` `fieldEdge` |
| Selection (gray pill, list row) | white 14 % | `selection` |
| Accent / primary fill / tint | #A56BFF dark, #7A33E0 light / #7C3AED / accent 22 % (P3 Violett, 2026-10-13) | `accent` `accentFill` `accentTint` |
| Selected keyframe, In/Out | accent | `keyframeSelected` `inOutTint` `inOutEdge` |
| Tracked frame of a Magic mask (lanes: 60 % key size; selected = accent) | text 3 | `keyframeTracked` |
| In/Out wash, track row line | white 6 %, 9 % (header 12 %) | `inOutWash` `trackRowLine` `trackHeaderLine` |
| Playhead K1 | line 2 pt `playhead` (white 92 %); head 12 x 12, icon head shape, porcelain gradient #FFFFFF to #C3C9D9, dark hairline in light | `playhead` `PlayheadSkin` |
| Icon gradient (export progress, finished) | #350670, #8727C7, #EF3A87, #FE9E46 | `IconGradient.stops` |
| Yellow / orange / red | #ffd60a / #ff9f0a / #ff453a | `yellow` (clips, tiles, snap) `marker` `red` |

Color roles: blue fill = the one primary button and checked boxes; gray pill or blue tint = selected option; menu highlight
gray; yellow = selected clips, tiles, snap line; selected keyframes = accent; orange = markers/warnings; red = errors/offline.
Clip colors are unchanged (`clipVideo` ...).
Project panel item types wear exactly the colors of their timeline clips: one source, `LabelColor` (SQCore) resolved through
`Project.clipLabels(of:)` (same rules as `LabelResolver`, so user labels apply to both). Defaults, a bit poppier than before:
video blue `#2f6fb0`, audio green `#1e8449`, video with audio both (split chip / two-tone icon), photo violet `#9a50c8`,
folder pink `#bc4f78`, sequence forest `#3f7a4a`, nested sequence `#4f78a3`, title `#7350c0`. All keep white clip text at >= 4.5:1.
`Theme.Colors.clip*` derive from `LabelColor`; there is no `clipStill`. Tests pin panel color == timeline color for every kind.
Project list rows show the kind as a 16 pt chip (radius `Radius.small`) in the item's color (video with audio: two halves; offline: red) with the kind's `SQIcon` (11 pt, 1.6 stroke) in `LabelColor.onFill`, so the kind reads without the color. Row height and text baseline unchanged.
Icons: video `film`; audio `waveform`; video+audio `film` on a two-tone chip; photo `image`; folder `folder`; sequence `sequence`;
nested sequence `stack`; title `text`; generator `generator`.
Timeline sequence tabs: the open sequence's underline is always `accent`; the panel's focus line (`PanelActiveMarker`) stays the app-wide focus marker.
Tools that only act in the monitor (Create/Text, shapes, Pen, Mask) behave as Selection inside the timeline (`TimelineTool.effectiveTimelineTool`); the active tool does not change.

## Shape rules
- Buttons, popups, segments and single-line fields (scrub field, search, text): capsule, 22 high, radius 11 (`Metrics.capsule`).
- Multi-line boxes, lists, wells: radius 8 (`Radius.well`). Checkbox 14 px, radius 4 (`Radius.checkbox`).
- Slider: 2 px track, 10 px knob (`Metrics.sliderTrack`, `sliderKnob`), accent filled part, arrow cursor always.
- Popup: one down chevron (7 x 10, gray). Scrub / number values: accent text.
- States: default, hover (fill .16, fields white .18 edge), pressed (.22), selected, disabled (opacity .4),
  keyboard focus = inner 1.5 px accent line (`State.focusLine`, `ControlShape.drawFocusLine`).
- A control sits centered in its row; a row of buttons has 8 px above and below; every clickable part is at least 22 x 22 pt.
- One disclosure: `InspectorSection` (whole 24 pt row is the hit area, drawn chevron, 120 ms).
