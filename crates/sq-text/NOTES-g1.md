# sq-text, group g1 (txt1) notes

Ported (Swift file -> module): Look, TextPresets, CaptionStyleLooks, GeneratedCaptionLooks, CaptionLayout (portable part), CaptionPill,
DateStampText, TemplateTextStyle, TextTemplate, TextGenerator, TextGenerator+Portable, FontResolver (+Portable), PortableFontMatch,
PortableFallback, GlyphRasterFont+Bundled, SfntVariations, SfntColorGlyphs, LinearCanvas, PortableTextRenderer.
Added two modules that no group owned but the portable raster needs: `text_decorations` (TextDecorations.swift) and
`text_word_rects` (TextWordRects.swift), both "apple" in the file list but pure in their `#else` branch. lib.rs got their two lines.

Not ported (Apple only, as the brief says): TextGenerator+Raster (CoreVideo), TextGenerator+Warm (CoreText, `#if canImport(CoreText)`),
CaptionLayout.pivot/wholePivot (TextRaster), and the Mac-only Swift tests (CaptionLayoutTests, CaptionPillTests, the rendering half of
DateStampTextTests, TextGeneratorTests frame tests, FontWeightTests, the Core Text halves of PortableFontMatchTests/FontAxisTests).
Modules `text_generator_raster` and `text_generator_warm` stay skeletons.

## Decisions
- Fonts folder: `portable_font_match::set_fonts_root(path)` (Swift `Bundle.module`); the app calls it once. Tests call `use_bundled_fonts()`.
- `FontResolver.memo` keeps fonts and fitting sizes; `TextStyle` has no `Hash`, so the fit key is the style's JSON (`FitKey`).
  The encode memo and the scoped payload table of `TextGenerator` are not ported (shortcut comment in text_generator.rs); the decode
  memo is. `FontResolver::with_scoped_cache` just runs the body: the scoped table only held Core Text fonts.
- `LookLibrary.add/duplicate/merge` take `&mut dyn IdSource` (ids for new Looks); `add` takes a `LookValues`.
- `TemplateTextStyle::from_tracks(&template.content.tracks)` stands in for `init(template: TitleTemplate)`: TitleTemplate is not ported yet.
- `TextGenerator::KIND` is `GeneratorRef.text`. Widths and heights of pictures and canvases are `usize`.
- Foundation's trimming is `sq_core_model::trim_spaces(s, true)`.

## Waiting on (other groups / core)
- `text_look_generator` (g2): `TextLookGenerator::{looks, all, families, palettes}`, `GeneratedTextLook {id, family, palette, look}`,
  `LookPalette {name, accent, fill, paper}`, family `.noun`, `ColorContrast::{luminance, composite(color, grey), ratio}`.
  `text_presets` and `generated_caption_looks` call them (checked against a local stub only).
- `portable_animated_text` (g2): `PortableTextRenderer::render_with_states(text, style, max_width, box_height, scale, highlight, &states)`.
- `text_layout`: `TextLayout::make_font` must be `pub(crate)` (text_decorations uses it).
- `sq-core-model` lib.rs lacks `pub use anchored_animation::*` / motion_easing, so crate code imports `sq_core_model::anchored_animation::...`.
  `caption_presets.rs` (g2) calls `KeyframeTemplateCaptionExt::caption_pop()` without the type and does not compile that way.
- `PortableTextRenderer::{Picture, Raster}` are `portable_text_renderer::{Picture, Raster}`; `GlyphPlacer`, `OutlineFonts` are public there
  (`PortableTextCarets` reads `carets`).

## Swift quirks kept
- `CaptionLayout.fittingSize` assumes width grows linearly with the size; Inter's optical size widens smaller text, so the fitted word ends
  about 5% wider than the room (test `a_short_caption_keeps_its_size_and_a_wide_word_shrinks`).
- `LookLibrary.init` checks `look(id)` while the aliases fill in; the Rust version keeps that order (aliases sorted by key).

## Oracle
`oracle/sq-text/run.sh` builds two Swift dumpers (plain swiftc): LinearCanvas + CoverageRasterizer (`golden/linear-canvas.tsv`: polygon
masks, strokes, blur, shift, compositing; Rust matches within 2e-5) and SfntVariations on the bundled Inter (`golden/font-variations.tsv`:
axes, instances, normalization, HVAR advance deltas, gvar point deltas with IUP; Rust matches within 1e-9).
