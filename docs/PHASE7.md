# Phase 7: Text core (new package `SSText`)

Standalone package. Depends only on SSCore's stable `Time`/`TimeRange` (committed code). Core Text/CoreGraphics allowed (not SSCore). No project.yml changes, no UI, no rendering.
`KeyframeTemplate` uses SSCore keyframe types (`KeyframeTrack<Double>`, template-local `Time`); revised 2026-09-30 per Paul's decisions (see Revision log).
`scripts/test.sh SSText` works as is (script takes any package name).

## Slices (tests first, one commit each)
1. **Text style model** (`TextStyle.swift`): font family/postscript name, size, weight, color (sRGB RGBA value type), stroke (color, width), background box (color, padding, corner radius), shadow (color, offset, blur), alignment, line spacing. Codable, Sendable, Hashable.
2. **Core Text layout** (`TextLayout.swift`): line breaking to a max width, per-line bounds, total measured bounds, alignment, line spacing, background box rect. Deterministic pure function of (text, style, maxWidth). Tested with system font.
3. **Keyframe template + caption animation** (`KeyframeTemplate.swift`, `CaptionPresets.swift`): placeholder `KeyframeTemplate` (tracks of property name + normalized-time keyframes with value and easing enum), "pop in" (scale 0.8→1.0 overshoot + opacity 0→1, short), "none", "fade". `CaptionPresetLibrary` resolves the opaque `styleRef` / `animationRef` strings (as in SSTranscribe `CaptionPreset`) to `TextStyle` / `KeyframeTemplate`, with a default and fallback for unknown IDs. Built-in caption styles (e.g. "Classic", "Bold box", "Outline").
4. **Template file format** (`TextTemplate.swift`): `TextTemplate` (name, text, style, optional animation `KeyframeTemplate`), versioned JSON (`formatVersion`), encode/decode, unknown newer version → clear error, stable key order output for diffs.

## Revision log (2026-09-30)
- Layout coordinates documented: sequence pixels, top-left, y down (ARCHITECTURE "Coordinate convention").
- Real weights: `FontResolver` (weight trait / variable axis, else nearest face of the family).
- `inkBounds` (result and per line): stroke width, background, shadow offset+blur.
- Lines measured with CTLine typographic bounds (fallback fonts, emoji); per-line pitch.
- Keyframes: SSText-local Fraction/Easing/Keyframe/KeyframeTrack removed. `AnimationTrack` = property + `SSCore.KeyframeTrack<Double>`, key times are template-local `Time` (0...duration), shapes via `SegmentShape` (overshoot = bezier, handle dy 1.56; hold = `.hold`). TextTemplate formatVersion 2; v1 files still decode (fraction * duration).

## Open questions
(resolved items from the first pass removed; new ones below)
- Word longer than maxWidth: Core Text breaks by character; a single glyph wider than maxWidth overflows.
- Animation durations (pop-in 250ms, fade 200ms) and the built-in style values (sizes, fonts) are guesses; Paul to judge feel.
- Style ref "default" aliases "classic" to match SSTranscribe `CaptionPreset.standard`; SSTranscribe is not a dependency.
- Font files/embedded assets are not part of the template.
- Weight always picks the face within the named font's family: "Helvetica-Bold" with `.regular` resolves to Helvetica Regular. Should an explicit PostScript face name win over `weight`?
- `inkBounds` uses the full stroke width on every side (conservative; a centred CG stroke needs only half) and the full blur radius. Tighten once the renderer's stroke/blur model is fixed.
- Classic preset shadow `offsetY` changed from -2 to +2: shadow offsets are in layout space (y down), so positive = down. Check SSTranscribe/renderer do not assume y-up offsets.
- Line pitch now uses each line's own runs (emoji/CJK lines can be taller than the main font), so pitch is no longer strictly uniform for mixed text; leading = max(font leading, line leading).
- Template keys carry deterministic index-based UUIDs for built-ins and migrated v1 tracks; user-edited tracks get random ids (fine for SSCore, but template equality then depends on ids).
- Template times are absolute within the template (not normalized): retiming a template to another duration needs a scale helper (not written yet).
- v1 files with duration 0 and keyframes read their fractions as seconds (degenerate case).
