# sq-text: style, layout, glyph raster, caption presets (group g2)

Ported modules: text_style, text_layout, text_backend, text_backend_portable, text_units_layout, glyph_raster, sfnt_face,
sfnt_kerning, sfnt_tabular_figures, bundled_fonts, inter_font, caption_karaoke, caption_presets, style_kit_text,
style_kit_pauls, text_align_to_frame, text_template_resize, text_look_generator, portable_animated_text,
portable_shape_renderer, portable_text_carets, text_preset_still.

## Not ported
- `TextGenerator+Follow.swift`: whole file is `#if canImport(CoreText)` (Mac-only); the portable build has no Follow measure.
- Font registration (`registerFontFile`, `isInstalled`, `BundledFonts.register`, `InterFont.register`): no counterpart; fonts
  are read from files. Bundled font files are found under a `fonts_root` argument (the package's `Resources/Fonts`), never copied.
- Swift tests gated by `#if canImport(CoreText)` (36 files: Helvetica/Core Text comparisons, Core Graphics rasters) are not
  translated; the portable path is the reference. Translated: TextStyle, WordWrap (layout part), GlyphRaster, InterFont,
  BundledFonts, TextLookGenerator, StyleKitText, PaulsKit, CaptionLook, TextResize, PortableTextCaret, TextPresetStill.

## Deviations / quirks
- `GlyphRasterFont.inter/inter_semibold/inter_medium` (static lazies in Swift) are functions of `fonts_root`, uncached.
- `TextDecorations` and `TextWordRects` (classified "apple" in the file list, but their portable branch is what the raster
  uses) were ported by the other sq-text worker; this branch uses theirs.
- `CJKBreaking` keeps its own copy of the closing/opening mark sets: `sq_core_time::word_segmentation` keeps them private.
  Waiting on: make them `pub` there and drop the copy.
- `portable_animated_text` keeps a copy of the private `MAX_RASTER_SIDE` of `portable_text_renderer`. Waiting on: `pub(crate)` there.
- `CaptionLookRegistry` is a process-wide `Mutex` singleton (Swift `NSLock` + `shared`); tests that touch it take
  `caption_presets::registry_test_lock()`.
- `GeneratedTextLook.id` is a stored field (Swift computes it from `look`) because `generated_caption_looks` reads it.
- `TextShadow.spread` is a public field; use `set_spread` to keep the "never negative" rule (Swift `didSet`).
- Swift `Hashable` on style types is not carried over (f64 fields); `PartialEq` only.
