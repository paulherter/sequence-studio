# Phase 7: Text core (new package `SSText`)

Standalone package. Depends only on SSCore's stable `Time`/`TimeRange` (committed code). Core Text/CoreGraphics allowed (not SSCore). No project.yml changes, no UI, no rendering.
Keyframe types are being built in SSCore by another session: SSText defines its own small placeholder (`KeyframeTemplate`), to be mapped to SSCore keyframes later.
`scripts/test.sh SSText` works as is (script takes any package name).

## Slices (tests first, one commit each)
1. **Text style model** (`TextStyle.swift`): font family/postscript name, size, weight, color (sRGB RGBA value type), stroke (color, width), background box (color, padding, corner radius), shadow (color, offset, blur), alignment, line spacing. Codable, Sendable, Hashable.
2. **Core Text layout** (`TextLayout.swift`): line breaking to a max width, per-line bounds, total measured bounds, alignment, line spacing, background box rect. Deterministic pure function of (text, style, maxWidth). Tested with system font.
3. **Keyframe template + caption animation** (`KeyframeTemplate.swift`, `CaptionPresets.swift`): placeholder `KeyframeTemplate` (tracks of property name + normalized-time keyframes with value and easing enum), "pop in" (scale 0.8→1.0 overshoot + opacity 0→1, short), "none", "fade". `CaptionPresetLibrary` resolves the opaque `styleRef` / `animationRef` strings (as in SSTranscribe `CaptionPreset`) to `TextStyle` / `KeyframeTemplate`, with a default and fallback for unknown IDs. Built-in caption styles (e.g. "Classic", "Bold box", "Outline").
4. **Template file format** (`TextTemplate.swift`): `TextTemplate` (name, text, style, optional animation `KeyframeTemplate`), versioned JSON (`formatVersion`), encode/decode, unknown newer version → clear error, stable key order output for diffs.

## Open questions
(collected during implementation)
- Font weight: only bold trait is applied (weight >= semibold); real weight axes per family need a font resolver later.
- Layout `bounds` exclude stroke width and shadow; renderer must inflate for ink bounds if it clips.
- Layout coordinates: y down, origin top-left, units points; alignment container = maxWidth (nil: widest line). Confirm with renderer convention.
- Line pitch uses font-level ascent+descent+leading+lineSpacing (uniform); per-line glyph metrics (fallback fonts/emoji) not used.
- Word longer than maxWidth: Core Text breaks by character; a single glyph wider than maxWidth overflows.
- `Fraction` (normalized keyframe time) and `Easing` are SSText-local; map to SSCore keyframe types when they land (overshoot/hold may need bezier equivalents).
- Animation durations (pop-in 250ms, fade 200ms) and the built-in style values (sizes, fonts) are guesses; Paul to judge feel.
- Style ref "default" aliases "classic" to match SSTranscribe `CaptionPreset.standard`; SSTranscribe is not a dependency.
- Template JSON: no migration path yet (only v1); font files/embedded assets not part of the template.
