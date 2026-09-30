# Phase 4 — Keyframe core (SSCore)

Scope: new files in `Packages/SSCore` only (`Keyframes*.swift`, `Tests/SSCoreTests/Keyframe*Tests.swift`). No existing SSCore API changes. Value types, rational `Time`, no AppKit/AVFoundation. Tests first.

## Model
- `KeyframeValue` protocol: `Sendable, Hashable, Codable`; `lerp`, `+`, `-`. Conformers: `Double`, `Vec2` (x, y).
- `Keyframe<V>`: `id: UUID`, `time: Time`, `value: V`, `interpolation: Interpolation` (shape of the **outgoing** segment), `inHandle` / `outHandle: EaseHandle`, `inTangent` / `outTangent: Vec2` (spatial, Vec2 only, zero = straight).
- `Interpolation`: `.linear | .hold | .bezier`. Glyph (UI): diamond / square / circle.
- `EaseHandle`: `(dx, dy)`, dx in 0…1 (time influence), dy free (overshoot allowed). Segment curve = cubic bezier `(0,0) (out.dx,out.dy) (1-in.dx, 1-in.dy) (1,1)` in normalised time/progress. Linear = handles (1/3,1/3). Segment uses left key's `interpolation`/`outHandle` and right key's `inHandle`.
- `KeyframeTrack<V>`: sorted keys, unique times. `insert/remove/move/set`, `value(at:)`, `nextKey/previousKey(of:)`.

## Slices (each with tests)
1. **Track + temporal eval**: linear, hold, bezier; before first/after last = clamp; single key = constant. Solve bezier x(s)=t by Newton + bisection.
2. **Graph math**: `valueGraph(samples:)` and `speedGraph(samples:)` per segment (speed = dv/dt, in value units per second; Vec2 → magnitude). Handle ↔ (speed, influence) conversion for the AE-style speed graph handles.
3. **Spatial interpolation** (Vec2 position): cubic bezier path from out/in tangents; temporal ease maps to **arc length** (constant speed on linear). Path sampling for the motion path in the monitor.
4. **Easing presets**: `EasingCurve` (interpolation + out handle + in handle), built-ins (Linear, Hold, Ease in/out, Ease in, Ease out, Fast start, Fast end), `EasingLibrary` with user presets (add/rename/remove, Codable, "save curve from key").
5. **Apply easing to many keys**: `apply(curve, to: Set<ID>)` (also F9 / Shift+F9 / Cmd+Shift+F9 variants: in only, out only, both; toggle hold).
6. **Clipboard**: copy keys from several tracks (by property key) as relative times + easing; paste at a time, replace keys at identical times, easing kept.
7. **Relative multi-key editing** (UX.md delta rule): `setValue(v, at: t, selected:)`. Reference = selected key's value if one sits at `t`, else interpolated value at `t`. All selected keys of this track get `+ delta`. Non-selected keys and other properties untouched. No selection → caller creates a key (not this API).
8. **Summary keyframes**: `KeyframeSummary` over `[PropertyID: track]`: groups keys at identical times across children; select / move in time / ease act on all members. Move keeps order and clamps against non-selected neighbours (collision rule below).

## Decisions taken here (raise in review if wrong)
- Key moved onto a non-selected key's time: the moved key wins, the old one is removed.
- Copy/paste: paste at playhead aligns the earliest copied key; pasting onto a different property type is rejected (returns false).
- Hold on the **out** side only; `Cmd+Opt+H` toggles hold on the selected keys' out side.

## Open questions (for Paul)
- Does a key's bezier `outHandle` need *separate* in/out influence for Vec2 components (x/y separated like AE "Separate Dimensions")? Not modelled; Position is one track with a shared curve.
- Project-file integration (how clip properties reference tracks, schema version bump) is out of scope here; needs the model owner.
- Rotation > 360° / Scale as linked Vec2: modelled as plain `Double` / `Vec2`, no wrap logic.
