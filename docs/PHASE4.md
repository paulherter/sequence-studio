# Phase 4 — Keyframe core (SQCore)

Scope: `Packages/SQCore`. Originally new files only; integration (see Decisions from Paul) now changes Clip/ProjectFile/Evaluation. Value types, rational `Time`, no AppKit/AVFoundation. Tests first.

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

## Decisions from Paul (resolved)
1. Easing never modifies unselected keys. AE model: each key owns in/out handles; a segment uses the left key's out handle and the right key's in handle regardless of the left key's `.linear`/`.bezier` (a linear out-handle plus an eased in-handle already eases). `.hold` on the left key still wins. The "upgrade left neighbour to bezier" behaviour is removed.
2. Position is one linked `Vec2` (no separate dimensions). Rotation is unbounded degrees (no wrapping). Scale is never wrapped and clamped to >= 0 at read time in `Clip.transform(at:)` (no upper limit). Opacity is clamped to 0...1 there, volume >= 0 in `Clip.volume(at:)`.
3. Project integration done: `Clip.animation: ClipAnimation` with `AnimatedProperty<V>` (static `value` fallback + `KeyframeTrack`) for position, scale (Vec2), rotation, opacity, anchor and volume. Keyframe times are clip-local (0 = `Clip.start`); `cropped(to:)` (split/trim/clear) shifts keys so they stay on the same frames. `Timeline.videoLayers` fills `LayerRequest.transform`. File format v3 (`migrateV2toV3`, identity: old clips decode to static defaults, no keyframes). Undo = snapshots keep working since everything is value types in `Clip`.

## Open questions (for Paul)
- Units of position/anchor: default `Vec2.zero` is meant as offset from canvas centre / anchor at clip centre, in canvas pixels. Renderer (SQRender) must agree; not wired yet.
- Scale is stored as linked `Vec2` (x, y), default (1, 1), so non-uniform scale is possible; UI may show a single linked value. Say if it should be a plain `Double`.
- Volume is linear gain (1 = unity), stored on every clip but only meaningful for audio; `AudioSegment` does not carry it yet (audio engine should call `Clip.volume(at:)`).
- Trimming a clip's left edge shifts keys (same frames); keys that fall outside the remaining range are kept (clamped evaluation), not deleted.

### Open questions found during implementation (simplest option taken)
- Overshoot (progress outside 0...1) on a curved spatial path is clamped to the path ends; straight segments (zero tangents) overshoot like a scalar lerp.
- Summary/track moves clamp only against non-selected neighbours, not against time 0 or the clip bounds; the caller must clamp to the clip range.
- Vec2 "value graph" returns the vector per sample (no per-component split); speed graph returns the magnitude.
- Pasting a property that has no track yet creates one. Dictionary `[PropertyID: ...]` encodes as a key/value array in JSON (struct key).
- Speed/influence conversion uses the segment's scalar `valueDelta` (for Vec2 pass the path length).
