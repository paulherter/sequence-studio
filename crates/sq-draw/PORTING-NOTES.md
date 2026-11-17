# sq-draw porting notes

## Swift quirks kept (DK2/DK3)
- `InspectorControlsTests.sliderFractionInvertsTheKnobPosition` expects `sliderFraction(x: 5)` to be 0 on a 110 pt rect, but the
  slider maps the pointer through knob-centered end points (x0 = 2), so 5 gives 0.028. The Rust test uses x = 1.
- `MonitorFooterTests.drawsPlayheadBandAndGrips` probes row 14 for the In-Out band; the band is drawn at y 7 of the strip
  (row 15 of the footer) since the "thin range line" change. The Rust test probes row 15.
- `ScrubFieldControl.commitEditing`: a `valueParser` that returns `nil` does not fall back to `ScrubMath.evaluate` (the optional
  chain `valueParser.map { $0(text) } ?? evaluate` keeps the inner `nil`). Kept.
- `SafeMarginSizes`, `MeterBallistics.dB(fromLinear:)` and the other clamps keep Swift's order of operations; NaN inputs now
  clamp through `f64::clamp` (NaN stays NaN) where Swift's `min(max())` could return a bound.

## Mapping decisions
- Swift singletons used by the controls (`HostRequests.current`, `HostTypedText.shared`, `TextClipboard.shared`, `ScrollGesture.published`)
  become the `&mut UiCx` / `&UiCx` parameter of the call that read them (`TextEditState::handle`, `ScrubFieldControl::{mouse_dragged, key, scroll}`,
  `InspectorDraw::edit_text`, `MonitorFooter::{draw, timecode_key}`).
- `TextEditState` holds `Vec<char>` (Swift `Character` is a grapheme cluster): a combining sequence is several characters here.
  Caret and selection are char indexes. Same limit as the Swift `shortcut` (no IME composition).
- `ScreenColorSampler` (a static hook) is a plain struct the app owns.
- `MeterFeed` takes a `usize` source id instead of `ObjectIdentifier`.
- `CGVector` (a swift-corelibs shim) is a small struct in `mask_overlay_geometry`.
- `ClickCounter`, `typographic_minus` (a `ScrubMath` extension) and `TAB` (an `InputKey` extension) live next to the Swift file that declares them.
- `ZoomScrollBarControl` sits at the crate root like the Swift file.

## Not ported
- `ScopeImage` (ScopesDrawing.swift): the CPU form of the scope shader reads `ScopeCounts`/`ScopeLayout`, which live in sq-render.
  sq-draw must not depend on sq-render; port it in the monitor panel crate (DM) where both are visible.
  The `ScopeGraticule` test that compares targets with `ScopeBinning.cbcr` is left out for the same reason (the formula is asserted directly).
- `EditorFooterTests` (SQDrawEditor/EditorScreen) and `ImageQuadTests` (DrawList, K1) are not part of this batch.
- `CGShim.swift` (Windows/Linux only shim).

## Escalations
None.
