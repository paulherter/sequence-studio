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
  reference white. Scene white: CCT with `mired = 1e6/6504 − temperature` (±100 mired), Duv = `−tint · 0.0002`
  (positive tint → magenta, positive temperature → warmer). Reference = same construction at 0/0, so neutral is exact identity.
- **Exposure** −4…+4 EV: `rgb · 2^ev`.
- **Contrast, Highlights, Shadows** −100…100, on luminance `Y` (source gamut Y row), hue-preserving (RGB × Y′/Y):
  `l = log2(Y/0.18)`; contrast: `l · (1 + 0.5·c/100)` (pivot grey); highlights: `+1.5·h/100 · smoothstep(0, 3, l)` stops;
  shadows: `+1.5·s/100 · smoothstep(0, 3, −l)` stops. `Y ≤ 2⁻¹⁶` → pixel unchanged.
- **Saturation** 0…200: `Y + (rgb − Y) · s/100`.

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

## Open questions (for Paul)

1. **"Correction on the full log signal"** is implemented as correction in source *scene-linear* (decoded, unclipped,
   source gamut), then re-encoded before a camera LUT. Same information as the log signal, but exposure/WB are exact
   multiplications. OK, or should the sliders act directly on log code values?
2. **Where the correction model lives:** `ColorCorrection` is defined in SSRender for now. The per-clip model (Clip.color)
   belongs in SSCore; move the value type there when Phase 3 touches the model?
3. **Source detection:** Sony files are untagged. Untagged → Rec.709 by default; S-Log3 needs camera metadata (SSMedia)
   or a user choice in the Source row. No detection code in this slice.
4. **HLG→SDR look:** scene-light mapping (BT.2408 style, no OOTF) + our tone curve. QuickTime's HLG→SDR is Apple's own;
   compare side by side once an HLG clip exists (none in ~/Documents/Videos).
5. **Out-of-gamut:** S-Gamut3.Cine → 709 gives negative components; this slice clamps. Gamut compression later if saturated
   colours look wrong.
