# Review 1: SSCore and SSRender/Color

Date: 2026-09-30. Scope: committed code at `24f89a0` in `Packages/SSCore` and `Packages/SSRender/Sources/SSRender/Color`. For `ColorCorrection.swift` this is the HEAD version, not the uncommitted edits. This review is read-only and nothing was fixed.

How each finding was checked:
- Findings 1-4 were reproduced in a throwaway harness outside the repo.
- Finding 5 was traced by hand and not run.
- Findings 1, 2 and 5 were re-read against the source.
- Color findings were checked with a scratch Swift harness against reference values.

Checked and found correct:
- History (undo/redo)
- Snapping
- Keyframe easing and interpolation math
- Project-file migrations
- The S-Log3, HLG and BT.709 transfer functions
- The gamut matrices (S-Gamut3.Cine to 709 matches Sony's values) and Bradford/CCT
- Cube LUT indexing and tetrahedral interpolation
- Tone-map continuity
- Pipeline order

## Findings (most severe first)

### 1. High: split/clear keep `link` on the right half, so one link group becomes four clips
**Fixed in `0153c84`.** Split, clear, overwrite, move and insert share one old→new link map per edit. Tests: `LinkedEditTests`.

`Packages/SSCore/Sources/SSCore/Model.swift:141` (`clear`), `Model.swift:164` (`split`). `Timeline.insert` (`Timeline.swift:~162`) goes through both.

The right half gets a new `id` but keeps the original `link`. Only `addEdit` relinks the halves.

**Scenario:**
1. Take linked V[0,10) and A[0,10) with link L.
2. Run `Timeline.insert` at t=5 on ripple tracks.
3. V-left, V-right, A-left and A-right all carry L.

`linkedGroup`, trim, ripple delete, move and slide then act on all four clips. Deleting V-left also removes V-right, A-left and A-right. Lift/extract and overwrite have the same defect.

**Premiere:** each half stays linked only to its counterpart on the other track.

### 2. Med: ripple delete of a J/L-cut group moves later linked pairs out of sync
**Fixed in `0153c84`.** All involved tracks close by one common amount, the group's span reduced by the largest collision shortfall. Test `lCutAudioEndsLater` was updated to the new behaviour.

`Timeline.swift:89-101` (`rippleDeleteOne`).

Each track in the group closes by its own clip's duration, with its own clip's end as the pivot.

**Scenario:**
1. V[10,20) and A[8,20) share link L1. V2[20,30) and A2[20,30) share link L2.
2. Run `rippleDeleteOne(V)`.
3. V2 now starts at 10 and A2 at 8, a 2 s A/V desync between clips that were in sync.

**Premiere:** all sync-locked tracks ripple by the same amount, so later linked pairs stay aligned.

### 3. Med: trim head, roll and slide don't shift keyframes, so they drift on the timeline
**Fixed in `120cabb`.** `Clip.shiftSourceStart(by:)` applies to head trim, ripple-trim head (which covers Q), roll and slide. Slip keeps keys clip-relative. Tests: `KeyframeEditFollowTests`.

- `Timeline+Edits.swift:49` (trim head)
- `Timeline+Edits.swift:86` (roll)
- `Timeline+RangeEdits.swift:95` (slide)

These edits change `start` and `source.start` together but never call `animation.shifted`. Keyframes are clip-local, so they move on the timeline.

**Scenario:** a clip with start=10 has an opacity key at local 2 (sequence 12). `trim(.head, by: 1s)` leaves the key at sequence 13.

`Clip.cropped` (`Model.swift:60`) deliberately keeps keys on the same frames, so split/overwrite and trim/roll/slide disagree.

**Premiere:** keyframes stay attached to the source frame.

### 4. Med: decoding `Time` bypasses normalization and validation
**Fixed in `bf908f3`.** A custom `init(from:)` normalises and throws `DecodingError` for timescale ≤ 0. The encoded format is unchanged.

`Time.swift:3-5`.

`Time` uses the synthesized `Decodable`, which skips the gcd normalization and the `timescale > 0` precondition in `init`. Equality and hashing are synthesized member-wise, which contradicts the doc comment ("1/2 == 2/4").

**Scenario:**
- `{"value":2,"timescale":60}` decodes to 2/60, and `== Time(1,30)` is `false`.
- A `Set` containing both values has 2 elements.

Anything that depends on == breaks for a non-normalized value from a file: boundary checks, edit-point and snap-point dedup, keyframe uniqueness. `timescale: 0` in a file crashes with an Int128 divide-by-zero in `frameIndex`.

**Fix direction:** add a custom `init(from:)` that goes through `init(_:_:)` and throws on timescale ≤ 0.

### 5. Low/Med: ripple trim pivots every track on the primary clip's end, so J/L-cut trims collide
**Fixed in `0153c84`.** Each track pivots on its own member's end.

`Timeline.swift:114` and `Timeline.swift:138` (`rippleTrim`).

**Scenario:**
1. V[10,20) is linked to A[8,15). An unlinked clip C[15,18) sits on A's track.
2. `rippleTrim` V's tail by +2.
3. A extends to 17. C starts before the pivot (20), so it is not shifted, and the edit throws `.collision`.

**Premiere:** C is pushed along. The pivot on each track should be that track's own group member's end, as `rippleDeleteOne` already does.

This finding was traced by hand, not run.

### 6. Low: `KeyframeSummary.toggleHold` destroys custom bezier out-handles
**Fixed in `bf908f3`.** Handles are never touched. Turning hold off restores bezier if any adjacent handle is non-linear, and linear otherwise. The model has no stored "previous interpolation".

`KeyframesEditing.swift:178-179`.

It applies `EasingCurve.linear` or `.hold` with side `.out`. That overwrites `outHandle` as well as the interpolation.

**Scenario:** toggling hold on and then off on a bezier-eased key resets its out handle to linear.

`KeyframeTrack.toggleHold` (`KeyframesEasing.swift:79`) changes only the interpolation, so the two paths are inconsistent.

### 7. Low: the contrast/shadows curve is discontinuous and non-monotonic near black
`Packages/SSRender/Sources/SSRender/Color/ColorCorrection.swift:73-80` (HEAD, `apply`).

The `y > minLuma` guard skips the curve entirely below the threshold.

**Scenario (contrast=100, neutral grey):**
- y = 1/65535 → 1.4e-7
- y = 1/65537 → 1.5e-5, unchanged

Darker input gives brighter output. With shadows=+100 the jump at the boundary is about 2.8x (+1.5 EV). This mostly shows up as near-black noise in log footage.

**Fix direction:** blend toward identity near zero instead of skipping.

### 8. Low: `.cube` parser rejects inline trailing comments
`CubeLUT.swift:61-67` and `CubeLUT.swift:96-97`.

**Scenario:** `0.1 0.2 0.3 # note` splits into 5 tokens, so `triple` throws `malformedLine` and the whole LUT fails to load. Some exporters write lines like this.

**Fix direction:** strip from `#` to the end of the line before tokenizing.

### 9. Low (known gap): `LUT_IN_VIDEO_RANGE` and `LUT_OUT_VIDEO_RANGE` are parsed but ignored
`CubeLUT.swift:19-21`.

The code comments say this is intentional, but video-range LUTs will render with wrong levels until it is implemented.

### 10. Note, not a proven bug: HLG has no OOTF
`ColorPipeline.swift:69-74`.

HLG is treated as scene light scaled by `hlgScale`, with no system gamma 1.2. Signal 0.75 maps to about 0.99, so highlights above 75% go into the tone-map roll-off. This is fine if intended, but it is not BT.2100 display rendering. Worth a line in DECISIONS.md either way.
