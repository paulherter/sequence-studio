# Design System

## The shared draw UI (default on Mac and Windows)
Mac and Windows run the same UI code: `SharedUIController` (`App/Sources/SharedUI/SharedUIController.swift:26-36`, the Mac host;
the Windows host is `Windows/SQWinApp/Sources/SQWinApp/AppController.swift`) over SQDrawKit, SQDrawShell, SQDrawTimeline,
SQDrawMonitor, SQDrawLibrary and SQAppShell. A UI change lands once in that code. Design rules below name the draw-UI
source. The AppKit fallback UI and its `Theme` tokens are gone (2026-11-02); the old record is in
`docs/archive/DESIGN-SYSTEM-APPKIT-THEME.md`.
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
  `SQIcon.isFilled`).
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
