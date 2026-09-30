# Phase 3 — Color core (CPU reference)

Scope of this slice: pure-Swift, CPU reference math in `Packages/SSRender/Sources/SSRender/Color/`, tests in
`Packages/SSRender/Tests/SSRenderTests/Color/`. No Metal, no AVFoundation. The Metal shaders (later) must match these
functions within tolerance; every function is written per pixel on `SIMD3<Float>` so it ports 1:1 to MSL.
Order follows DECISIONS 2026-09-30: Correction → Conversion (LUT or automatic) → Creative LUT → (curves, wheels … later) → output.

## Signal domains

| Domain | Meaning |
|---|---|
| **source-encoded** | R'G'B' after YCbCr→RGB with range expansion (0…1), in the source's transfer + gamut |
| **source-linear** | scene linear, source gamut, 18 % grey = 0.18, unclipped (S-Log3 peaks ≈ 38) |
| **display-709** | Rec.709 encoded 0…1 (what a camera conversion LUT outputs). Creative LUT works here |
| **working-linear** | inverse BT.709 OETF of display-709; Rec.709 primaries, D65. Compositor input (`rgba16Float`) |

## Per-clip chain

1. `SourceColorSpace.decode`: source-encoded → source-linear.
   - **S-Log3 / S-Gamut3.Cine**: Sony formula on *code values* (`CV/1023`). The compositor range-expands legal range,
     so first map back: `cv = (v·876 + 64)/1023`. Check: 18 % grey = CV 420.
   - **HLG / BT.2020**: BT.2100 inverse OETF (scene light), then × `hlgScale` so HLG 0.38 (BT.2408 grey) → 0.18
     (≈ 3.74, reference white 75 % → ≈ 1.0). No OOTF (scene-referred working space).
   - **Rec.709**: inverse BT.709 OETF (exact constants α = 1.09929682680944, β = 0.018053968510807).
2. `ColorCorrection.apply` in source-linear (Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Saturation), see below.
3. Conversion:
   - with a **Conversion LUT**: re-encode with the source transfer (exact inverse of step 1) → LUT → display-709.
   - **automatic**: gamut matrix source → Rec.709 (from primaries, D65) → tone map (HDR sources only; Rec.709 sources
     bypass it so SDR is untouched) → clamp to ≥ 0 → BT.709 OETF → display-709.
4. **Creative LUT** + intensity: `mix(x, lut(x), intensity)` in display-709.
5. → working-linear (inverse BT.709 OETF). Compositing happens here.
6. **Output Rec.709 1-1-1**: working-linear → clamp 0…1 → BT.709 OETF; tags primaries/transfer/matrix = 1/1/1.

Invariant (test): a Rec.709 source with neutral correction and no LUTs round-trips source-encoded → output unchanged (≤ 1e-5).

## Basic correction (source-linear, value type, all neutral = 0 except saturation = 100)

- **Temperature / Tint** −100…100: Bradford adaptation in XYZ (via the source gamut matrix) from an assumed scene white to the
  reference white. Scene white: CCT with `mired = 1e6/6504 − temperature` (±100 mired), Duv = `+tint · 0.0002` (scene white greener → image more magenta)
  (positive tint → magenta, positive temperature → warmer). Reference = same construction at 0/0, so neutral is exact identity.
- **Exposure** −4…+4 EV: `rgb · 2^ev`.
- **Contrast, Highlights, Shadows** −100…100, on luminance `Y` (source gamut Y row), hue-preserving (RGB × Y′/Y):
  `l = log2(Y/0.18)`; contrast: `l · (1 + 0.5·c/100)` (pivot grey); highlights: `+1.5·h/100 · smoothstep(0, 3, l)` stops;
  shadows: `+1.5·s/100 · smoothstep(0, 3, −l)` stops. `Y ≤ 2⁻¹⁶` → pixel unchanged.
- **Saturation** 0…200, perceptual (log2 ratio to luminance): `rgb′ = Y · (max(rgb, 2⁻¹⁶)/Y)^(s/100)`; `Y ≤ 2⁻¹⁶` → unchanged.
  Never produces negatives (linear `Y + (rgb−Y)·s` did at s > 100).

## Tone mapping (HDR → SDR)

maxRGB, hue-preserving: `m = max(r,g,b)`; above knee `k` (default 0.8): `m′ = k + (1−k)(1 − e^−(m−k)/(1−k))`,
`rgb · m′/m`. C¹ at the knee, asymptote 1.0, monotonic. Parameters in a struct so Paul can tune by eye later.

## LUT

`.cube` parser (Adobe spec): `TITLE`, `LUT_3D_SIZE` (2…256), `LUT_1D_SIZE`, `DOMAIN_MIN/MAX`, `#` comments, blank lines,
red varies fastest. Typed errors with line numbers (missing size, wrong entry count, bad number, size out of range).
Lookup: 3D = tetrahedral interpolation, 1D = linear per channel; input clamped to the domain.

## Slices

1. Transfer functions (S-Log3, HLG, BT.709) + gamut matrices from primaries (S-Gamut3.Cine, BT.2020, Rec.709) + Bradford.
2. `.cube` parser + tetrahedral / 1D lookup.
3. `ColorCorrection` + tone mapping.
4. `ColorPipeline` (chain above) + `Rec709Output`.

## Decisions (Paul, 2026-09-30)

1. Exposure and WB in linear; contrast, highlights, shadows, saturation in log2 around 18 % grey (perceptual).
2. `ColorCorrection` moves to SSCore later (Phase 4 is changing the clip model now) → slice 9.
3. S-Log3 detection from Sony NonRealTimeMeta XML: sidecar `<clip>M01.XML` or embedded in the MP4 (top-level `meta` box →
   `xml ` box; ZV-E1 files have it, no sidecars). Items `CaptureGammaEquation` (`s-log3-cine`), `CaptureColorPrimaries`
   (`s-gamut3-cine`). Plus per-clip override ("Interpret Footage") → with slice 9.
4. HLG→SDR is compared to QuickTime once `TestMedia/iphone-hlg.mov` exists.
5. Out-of-gamut: clipping for now.

## Slices, part 2

5. Saturation in log2 (above).
6. SSMedia `SonyMetadata.swift` (new file): NRT XML parser + reader (sidecar first, then embedded box; only top-level box
   headers are read, no full-file scan). Tests on real clips in ~/Documents/Videos, skipped when missing.
7. Metal color chain (`Color/ColorShaders.metal` + `ColorPipelineGPU.swift`): one compute pass per layer,
   source-encoded → working-linear, rgba16Float in/out. Uniforms from `ColorPipeline` (prepared matrices), LUTs as
   3D/1D float textures, tetrahedral via 4 `read()`s (no filtering). Must match the CPU reference (float32 textures ≤ 1e-4).
   Entry point for the compositor (E-07): `ColorPipelineGPU.encode(_:source:destination:commandBuffer:)`.
8. GPU scopes (`ScopeShaders.metal` + `Scopes.swift` + CPU reference): waveform (luma / RGB parade, IRE on Rec.709 output),
   vectorscope (709 Cb/Cr, Cb → x, Cr → y up), histogram (R, G, B, Y). Atomic counts in buffers, resolve kernel → float texture;
   graticule, skin-tone line and glow are UI.
9. Later: move `ColorCorrection` to SSCore, per-clip source override, wire SonyMetadata → `SourceColorSpace`.

## Open questions (for Paul)

1. ~~**"Correction on the full log signal"** is implemented as correction in source *scene-linear* (decoded, unclipped,
   source gamut), then re-encoded before a camera LUT. Same information as the log signal, but exposure/WB are exact
   multiplications. OK, or should the sliders act directly on log code values?~~ Decided, see Decisions.
2. **Where the correction model lives:** `ColorCorrection` is defined in SSRender for now. The per-clip model (Clip.color)
   belongs in SSCore; move the value type there when Phase 3 touches the model?
3. **Source detection:** Sony files are untagged. Untagged → Rec.709 by default; S-Log3 needs camera metadata (SSMedia)
   or a user choice in the Source row. No detection code in this slice.
4. **HLG→SDR look:** scene-light mapping (BT.2408 style, no OOTF) + our tone curve. QuickTime's HLG→SDR is Apple's own;
   compare side by side once an HLG clip exists (none in ~/Documents/Videos).
5. **Out-of-gamut:** S-Gamut3.Cine → 709 gives negative components; this slice clamps. Gamut compression later if saturated
   colours look wrong.
6. **Embedded camera LUT:** ZV-E1 files reference the in-camera LUT (`<RelatedTo file="NeutralPaul_v5.cube" rel="LUT"/>`),
   and the MP4 `meta` box has a 442 KB `idat` item — probably that .cube. Load it automatically as the Conversion LUT
   (with the option to turn it off), or only offer it in the popup?
   **Findings (2026-09-30, `SSMedia/EmbeddedLUT.swift`, 36 ZV-E1 clips checked):** the `meta` box (top level, after `moov`) has
   items "Look Control data" (434,617 B, only in clips shot with a look; the `meta` box is 444,9xx B) and "Lens profile" (7,903 B,
   every clip), both `application/octet-stream`, `construction_method` 1 (idat). The 442 KB item is **not** `.cube` text: it is
   SMPTE KLV ("ELUT") wrapping a big-endian "SONYBCUB" block: file name `NeutralPaul.cube`, **33^3 LUT**, 431,244 B of big-endian
   f32 RGB triplets (red fastest, domain 0…1, values 0…1.2) plus a 3,328 B header. `EmbeddedMeta.lut(inClip:)` decodes it to
   `.cube` text (970 KB) so SSRender's parser loads it unchanged. Clips without a look item (older ones) return nil.

## Done (2026-09-30)

Slices 1–4 + review fixes (commits 7fad1ed…dfe44b8), 47 SSRender tests. Reviewer re-derived S-Log3/HLG/709 constants,
S-Gamut3.Cine→709 (matches Sony's matrix) and all 6 tetrahedral branches. `.cube` also accepts Resolve `LUT_*_INPUT_RANGE`;
`LUT_IN/OUT_VIDEO_RANGE` are parsed and stored but not applied yet. Per pixel for Metal: `PreparedCorrection.apply`,
`ColorPipeline.process`, `Rec709Output.encode`. Conversion-LUT input = range-expanded S-Log3 (Resolve convention, 18 % grey ≈ 0.406).

## Done, part 2 (2026-09-30)

Slices 5, 7, 8 + REVIEW-1 items 7–10 + GPU review hardening (753ac61…4833c72), 68 SSRender tests.
- **Metal:** SwiftPM CLI neither compiles nor bundles `.metal` (no `Bundle.module` without a Package.swift change), so MSL
  lives in `ColorShaderSource.swift` / `ScopeShaderSource.swift` and is compiled at runtime (`mathMode = .safe`). Relevant for E-07's planned `Shaders.metal`.
- **Compositor entry (E-07):** `ColorPipelineGPU(device:)` once per device, then per layer
  `try encode(_ pipeline:, source:, destination:, commandBuffer:)` (rgba16Float/32Float, same size, in place allowed; throws
  `ColorPipelineGPUError` on caller mistakes before touching the command buffer). GPU vs CPU: ≤ 0.52 of the
  1e-4·max(|y|,1e-3)+1e-6 bound on float32; 9.5e-4 rel. on half. 4K pass ≈ 3.0–3.4 ms.
- **Scopes:** `ScopesGPU` + `ScopesReference` (mappings documented on `ScopeCounts`). 4K all scopes: 11.8 ms at stride 1,
  0.8 ms at stride 4 → the live viewer should use stride 4.
- HLG decode = inverse OETF → OOTF γ 1.2 → × 4.9224 (reference white = 1.0). After the 0.8 knee, HLG reference white
  outputs ≈ 0.93: judge against QuickTime (open question 4).
- Slice 6 (1c811d7): `SonyMetadata.read(forClip:)` — sidecar `<clip>M01.XML` first, then the embedded `xml ` box, which is
  top-level in most ZV-E1 files but inside `moov` in C2157 (64-bit mdat). The embedded XML ends with a NUL (stripped before parsing).
  All 8 real clips → s-log3-cine / s-gamut3-cine in 0.3–1.5 ms. Slice 9 stays on hold until Phase 4's clip model lands.

- **Slice 9 (done, engine/export/inspector wiring is the follow-up):** `ClipColor` in SSCore (`Clip.color`, carried by
  `LayerRequest.color`), `MediaInfo.detectedColorSpace/embeddedLUTName` set by `MediaImporter` via `ColorDetection.detect`,
  project file v7 (identity). SSRender: `ColorPipeline.from(clipColor:mediaID:mediaInfo:lutProvider:)`, `LUTProvider`,
  `CachingLUTProvider(file:embedded:)` (embedded loader = app glue over `EmbeddedMeta.lut(inClip:)`, not yet written).
