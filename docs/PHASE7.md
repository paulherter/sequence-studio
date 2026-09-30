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
