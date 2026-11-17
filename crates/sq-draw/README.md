# sq-draw

Foundation of the shared draw UI (Swift SQDrawKit): `DrawList`/`DrawQuad` (80-byte instances, painter's order), `Canvas`
(point-space builder), `DrawTheme`, `GlyphAtlas` (sq-text rasterizer, dirty-rect tracking), `TextMeasure`, `InputEvent`,
`UiCx` (replaces the Host* singletons), scroll physics, the `Panel` trait, and both renderers: `SoftwareRenderer` (the
oracle) and `WgpuRenderer` (sq-gpu `DrawQuads` pipeline). Widget parts: inspector controls (`inspector/`: text and scrub fields, color picker, sliders, checkbox, popup, button) and the zoom scroll bar; monitor parts (`monitor/`: footer, meters, scopes graticule, overlay geometry). Design: docs/rust/session-ui-design.md 1 and 3.

## Notes (K1)
- Not ported (other tasks / host glue): widgets, `EditorScreen` (SQDrawEditor), `CoreGraphicsRenderer`, `MetalDrawListRenderer`, `MacKeys`/`MacScroll`, the PNG writer, `DrawCursorGlyph`/`DrawCursorImage` (cursor strokes), the empty-state mascot hook.
- No global clock or registry: time is `UiCx::now`, `ScrollBody::needs_frames(now)` is asked per panel (replaces `HostScroll`).
- `Panel::layout(&mut self, frame: CGRect, m: &TextMeasure)` (points); the design left its signature open.
- Icons: the SVGs are embedded in sq-uikit (`resources/Icons`, `SQIcon::svg_source`).
- `WgpuRenderer` needs `sq_gpu::pipelines::Blend::StraightOver` (added): the shader outputs straight-alpha color.
- One `WgpuRenderer` per window and atlas (one display scale); the page texture is updated from `GlyphAtlas::take_dirty`.
