// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesPair.swift (ported by task M-3)

use crate::AnimatedProperty;
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, Time, Vec2};
use std::collections::BTreeMap;

/// Two scalar tracks shown as one X/Y row (`EffectParamPair`: Transform / Auto Reframe Position and Anchor). Storage
/// stays two scalar tracks; the Stabilizer writes them with different key times. A pair is *aligned* when both members
/// have keys at the same times with the same interpolation and ease handles: then it reads as one Vec2 track
/// (`zipped`) and the graph draws one speed curve (|delta| x ease'), otherwise two. Every edit through a pair row
/// writes both members aligned.
pub struct KeyframesPair;

type Members = (AnimatedProperty<f64>, AnimatedProperty<f64>);

impl KeyframesPair {
    /// Same key times, interpolation and ease handles, key by key. Two unanimated members are aligned.
    pub fn is_aligned(x: &AnimatedProperty<f64>, y: &AnimatedProperty<f64>) -> bool {
        let (a, b) = (&x.track.keys, &y.track.keys);
        a.len() == b.len() && a.iter().zip(b).all(|(p, q)| same_shape(p, q))
    }

    /// Both members with keys at the union of their key times. A key is inserted into a member so that the member's
    /// own curve stays exactly as it was (see `inserting_keeping_curve`, which may rewrite the handles around the
    /// new key). Then, on the split tracks and in time order, each side of every key is settled on its own: the out
    /// side (kind and out-handle) over the stretch to the next key, the in side (in-handle) over the stretch from
    /// the previous key. A member that does not change over that stretch takes the side of the one that does (both
    /// flat: Y takes X's). An in side behind a Hold is not part of the curve, but its handle is what un-holding
    /// brings back, so it is never overwritten. Where both change, both stay: aligning never changes a curve, and
    /// aligning its result again changes nothing. Existing keys keep ids and values. The result is aligned when the
    /// curves allow it (linear and constant stretches always do); otherwise the graph draws two curves, and a pair
    /// row edit (`edit`) gives Y X's shape there. New keys take their ids from `ids`.
    pub fn aligning(x: &AnimatedProperty<f64>, y: &AnimatedProperty<f64>, ids: &mut dyn IdSource) -> Members {
        if Self::is_aligned(x, y) {
            return (x.clone(), y.clone());
        }
        let (mut ax, mut ay) = (x.clone(), y.clone());
        let x_times: Vec<Time> = x.track.keys.iter().map(|k| k.time).collect();
        let y_times: Vec<Time> = y.track.keys.iter().map(|k| k.time).collect();
        for k in x.track.keys.iter().filter(|k| !y_times.contains(&k.time)) {
            ay.inserting_keeping_curve(k.time, k, ids);
        }
        for k in y.track.keys.iter().filter(|k| !x_times.contains(&k.time)) {
            ax.inserting_keeping_curve(k.time, k, ids);
        }
        for i in 0..ax.track.keys.len() {
            let (kx, ky) = (ax.track.keys[i].clone(), ay.track.keys[i].clone());
            if kx.in_handle != ky.in_handle {
                if in_side_is_flat(i, &ay.track) {
                    ay.track.update(ky.id, |k| k.in_handle = kx.in_handle);
                } else if in_side_is_flat(i, &ax.track) {
                    ax.track.update(kx.id, |k| k.in_handle = ky.in_handle);
                }
            }
            let (kx, ky) = (ax.track.keys[i].clone(), ay.track.keys[i].clone());
            if kx.interpolation != ky.interpolation || kx.out_handle != ky.out_handle {
                if out_side_is_flat(i, &ay.track) {
                    ay.track.update(ky.id, |k| {
                        k.interpolation = kx.interpolation;
                        k.out_handle = kx.out_handle;
                    });
                } else if out_side_is_flat(i, &ax.track) {
                    ax.track.update(kx.id, |k| {
                        k.interpolation = ky.interpolation;
                        k.out_handle = ky.out_handle;
                    });
                }
            }
        }
        (ax, ay)
    }

    /// The pair as one Vec2 property (keys take X's ids, interpolation and handles; straight spatial path), or
    /// `None` when not aligned. Evaluates to (x(t), y(t)) exactly: both members share the eased progress of every
    /// segment.
    pub fn zipped(x: &AnimatedProperty<f64>, y: &AnimatedProperty<f64>) -> Option<AnimatedProperty<Vec2>> {
        if !Self::is_aligned(x, y) {
            return None;
        }
        Some(AnimatedProperty { value: Vec2::new(x.value, y.value), track: zipped_track(&x.track, &y.track) })
    }

    /// The pair as one editable Vec2 property, always: `aligning` first, then Y takes X's interpolation and handles
    /// at every key (only matters for the rare eased split `aligning` cannot keep aligned). Keys carry X's ids. Used
    /// by the X/Y pair rows in Effect Controls; read the exact current value from the members, not from this.
    pub fn editable(
        x: &AnimatedProperty<f64>,
        y: &AnimatedProperty<f64>,
        ids: &mut dyn IdSource,
    ) -> AnimatedProperty<Vec2> {
        let (ax, ay) = aligned_for_edit(x, y, ids);
        AnimatedProperty { value: Vec2::new(ax.value, ay.value), track: zipped_track(&ax.track, &ay.track) }
    }

    /// Splits a Vec2 pair property back into its two scalar members. X keys keep the Vec2 key ids; Y keys reuse the
    /// id of `y_ids_from`'s key at the same time, else get a fresh id (members never share key ids).
    pub fn split(v: &AnimatedProperty<Vec2>, y_ids_from: &AnimatedProperty<f64>, ids: &mut dyn IdSource) -> Members {
        let mut y_ids: BTreeMap<Time, Id> = BTreeMap::new();
        for k in &y_ids_from.track.keys {
            y_ids.entry(k.time).or_insert(k.id);
        }
        let xs = v.track.keys.iter().map(|k| shaped(k, k.id, k.value.x)).collect();
        let ys = v
            .track
            .keys
            .iter()
            .map(|k| {
                let id = y_ids.get(&k.time).copied().unwrap_or_else(|| ids.next_id());
                shaped(k, id, k.value.y)
            })
            .collect();
        (
            AnimatedProperty { value: v.value.x, track: KeyframeTrack::with_keys(xs) },
            AnimatedProperty { value: v.value.y, track: KeyframeTrack::with_keys(ys) },
        )
    }

    /// One edit through a pair row: both members as one Vec2 property (`editable`), written back aligned (`split`).
    pub fn edit(
        x: &mut AnimatedProperty<f64>,
        y: &mut AnimatedProperty<f64>,
        ids: &mut dyn IdSource,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>, &mut dyn IdSource),
    ) {
        let (ax, ay) = aligned_for_edit(x, y, ids);
        let mut v =
            AnimatedProperty { value: Vec2::new(ax.value, ay.value), track: zipped_track(&ax.track, &ay.track) };
        body(&mut v, ids);
        (*x, *y) = Self::split(&v, y, ids);
    }

    /// A paste through a pair row: both members take their part of every key, aligned. X keys carry the ids of
    /// `keys`, Y keys fresh ones (or the one of the key they replace).
    pub fn paste(
        keys: &[Keyframe<Vec2>],
        x: &mut AnimatedProperty<f64>,
        y: &mut AnimatedProperty<f64>,
        ids: &mut dyn IdSource,
    ) {
        if keys.is_empty() {
            return;
        }
        Self::edit(x, y, ids, |v, _| {
            for k in keys {
                v.track.insert(k.clone());
            }
        });
    }

    /// Copies interpolation and both handles of `from` into `k`.
    pub(crate) fn copy_shape(from: &Keyframe<f64>, k: &mut Keyframe<f64>) {
        k.interpolation = from.interpolation;
        k.in_handle = from.in_handle;
        k.out_handle = from.out_handle;
    }
}

/// The two members `editable` zips: aligned, Y with X's shapes.
fn aligned_for_edit(x: &AnimatedProperty<f64>, y: &AnimatedProperty<f64>, ids: &mut dyn IdSource) -> Members {
    let (ax, mut ay) = KeyframesPair::aligning(x, y, ids);
    for (kx, ky) in ax.track.keys.iter().zip(ay.track.keys.clone()) {
        if !same_shape(kx, &ky) {
            ay.track.update(ky.id, |k| KeyframesPair::copy_shape(kx, k));
        }
    }
    (ax, ay)
}

/// The keys of both members zipped (X's ids and shapes).
fn zipped_track(x: &KeyframeTrack<f64>, y: &KeyframeTrack<f64>) -> KeyframeTrack<Vec2> {
    KeyframeTrack::with_keys(
        x.keys.iter().zip(&y.keys).map(|(a, b)| shaped(a, a.id, Vec2::new(a.value, b.value))).collect(),
    )
}

/// A key with `a`'s time, interpolation and handles and the given id and value (no tangents).
fn shaped<A, B>(a: &Keyframe<A>, id: Id, value: B) -> Keyframe<B> {
    let mut k = Keyframe::new(id, a.time, value);
    k.interpolation = a.interpolation;
    k.in_handle = a.in_handle;
    k.out_handle = a.out_handle;
    k
}

/// The track does not change from key `i` to its next key (or `i` is the last one): any kind and out-handle on it
/// give the same curve.
fn out_side_is_flat(i: usize, track: &KeyframeTrack<f64>) -> bool {
    let keys = &track.keys;
    i + 1 >= keys.len() || keys[i + 1].value == keys[i].value
}

/// The track does not change from the key before key `i` (or `i` is the first one): any in-handle on it gives the
/// same curve. A Hold before a changing key does not count: the handle is not drawn, but un-holding brings it back.
fn in_side_is_flat(i: usize, track: &KeyframeTrack<f64>) -> bool {
    let keys = &track.keys;
    i == 0 || keys[i - 1].value == keys[i].value
}

fn same_shape(a: &Keyframe<f64>, b: &Keyframe<f64>) -> bool {
    a.time == b.time && a.interpolation == b.interpolation && a.in_handle == b.in_handle && a.out_handle == b.out_handle
}

impl AnimatedProperty<f64> {
    /// Inserts a key at `t` (no-op if one exists) without changing the evaluated curve. `partner`'s shape is used
    /// where any shape gives the same curve (constant stretch). Inside a Hold segment the key holds; inside a linear
    /// segment it is linear; inside an eased segment the segment's timing bezier is split (de Casteljau) and both
    /// halves get renormalised handles. Only if the split point's progress is exactly 0 or 1 on a non-constant
    /// segment (overshoot handles) can a half not be renormalised: then the key is value-exact at `t` and that half
    /// becomes linear.
    pub(crate) fn inserting_keeping_curve(&mut self, t: Time, partner: &Keyframe<f64>, ids: &mut dyn IdSource) {
        let keys = self.track.keys.clone();
        if keys.iter().any(|k| k.time == t) {
            return;
        }
        let mut k = Keyframe::new(ids.next_id(), t, self.value_at_local(t));
        KeyframesPair::copy_shape(partner, &mut k);
        // Constant stretch.
        let Some(hi) = keys.iter().position(|k| k.time > t).filter(|&hi| hi > 0) else {
            self.track.insert(k);
            return;
        };
        let (a, b) = (&keys[hi - 1], &keys[hi]);
        if a.interpolation == Interpolation::Hold {
            k.interpolation = Interpolation::Hold;
            self.track.insert(k);
            return;
        }
        // Constant from the new key on (equal neighbors, or a Hold Ahead: the key sits on the next key's value
        // already): any shape keeps it.
        if a.interpolation == Interpolation::HoldAhead || a.value == b.value {
            self.track.insert(k);
            return;
        }
        k.interpolation = a.interpolation;
        if a.out_handle == EaseHandle::LINEAR && b.in_handle == EaseHandle::LINEAR {
            k.in_handle = EaseHandle::LINEAR;
            k.out_handle = EaseHandle::LINEAR;
            self.track.insert(k);
            return;
        }
        // Timing bezier P0 (0,0), P1 (x1,y1), P2 (x2,y2), P3 (1,1) as `keyframe_math::bezier_progress` reads the
        // handles; split at the parameter s whose x is the time fraction of `t`.
        let x1 = a.out_handle.dx.clamp(0.0, 1.0);
        let x2 = 1.0 - b.in_handle.dx.clamp(0.0, 1.0);
        let (y1, y2) = (a.out_handle.dy, 1.0 - b.in_handle.dy);
        let s = keyframe_math::solve(keyframe_math::ratio(t - a.time, b.time - a.time), x1, x2);
        let mix = |p: f64, q: f64| p + (q - p) * s;
        let (l1x, l1y) = (mix(0.0, x1), mix(0.0, y1));
        let (cx, cy) = (mix(x1, x2), mix(y1, y2));
        let (r2x, r2y) = (mix(x2, 1.0), mix(y2, 1.0));
        let (l2x, l2y) = (mix(l1x, cx), mix(l1y, cy));
        let (r1x, r1y) = (mix(cx, r2x), mix(cy, r2y));
        // (time fraction, eased progress) at t
        let (mx, my) = (mix(l2x, r1x), mix(l2y, r1y));
        let (mut a_out, mut b_in) = (EaseHandle::LINEAR, EaseHandle::LINEAR);
        k.in_handle = EaseHandle::LINEAR;
        k.out_handle = EaseHandle::LINEAR;
        if mx > 0.0 && my != 0.0 {
            a_out = EaseHandle { dx: l1x / mx, dy: l1y / my };
            k.in_handle = EaseHandle { dx: 1.0 - l2x / mx, dy: 1.0 - l2y / my };
        }
        if mx < 1.0 && my != 1.0 {
            k.out_handle = EaseHandle { dx: (r1x - mx) / (1.0 - mx), dy: (r1y - my) / (1.0 - my) };
            b_in = EaseHandle { dx: 1.0 - (r2x - mx) / (1.0 - mx), dy: 1.0 - (r2y - my) / (1.0 - my) };
        }
        self.track.update(a.id, |p| p.out_handle = a_out);
        self.track.update(b.id, |p| p.in_handle = b_in);
        self.track.insert(k);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{FreshIds, key, t};
    use crate::keyframes_graph::KeyframeGraph;

    fn prop(keys: Vec<Keyframe<f64>>, v: f64) -> AnimatedProperty<f64> {
        AnimatedProperty { value: v, track: KeyframeTrack::with_keys(keys) }
    }

    fn eased(n: u128, s: i64, v: f64, out: EaseHandle, in_h: EaseHandle) -> Keyframe<f64> {
        let mut k = key(n, s, v);
        k.interpolation = Interpolation::Bezier;
        k.out_handle = out;
        k.in_handle = in_h;
        k
    }

    fn kind(mut k: Keyframe<f64>, i: Interpolation) -> Keyframe<f64> {
        k.interpolation = i;
        k
    }

    fn h(dx: f64, dy: f64) -> EaseHandle {
        EaseHandle { dx, dy }
    }

    /// Keys of the second member get ids from 100 up so the two members never share an id.
    fn shifted(keys: Vec<Keyframe<f64>>) -> Vec<Keyframe<f64>> {
        keys.into_iter()
            .map(|mut k| {
                k.id = Id::from_u128(k.id.as_u128() + 100);
                k
            })
            .collect()
    }

    fn times(p: &AnimatedProperty<f64>) -> Vec<Time> {
        p.track.keys.iter().map(|k| k.time).collect()
    }

    fn values(p: &AnimatedProperty<f64>) -> Vec<f64> {
        p.track.keys.iter().map(|k| k.value).collect()
    }

    fn same_curve(a: &AnimatedProperty<f64>, b: &AnimatedProperty<f64>, end: i64) {
        for i in -4..=(end * 20 + 4) {
            let at = Time::new(i, 20);
            assert!((a.value_at_local(at) - b.value_at_local(at)).abs() < 1e-6, "t = {}", i as f64 / 20.0);
        }
    }

    #[test]
    fn aligned_when_times_and_easing_match() {
        let x = prop(vec![eased(1, 0, 0.0, h(0.4, 0.0), EaseHandle::LINEAR), key(2, 2, 10.0)], 0.0);
        let y = prop(shifted(vec![eased(1, 0, 5.0, h(0.4, 0.0), EaseHandle::LINEAR), key(2, 2, -3.0)]), 0.0);
        assert!(KeyframesPair::is_aligned(&x, &y));
        assert!(KeyframesPair::is_aligned(&prop(vec![], 0.0), &prop(vec![], 0.0)));
    }

    #[test]
    fn not_aligned_on_different_times_or_easing() {
        let p = |ks: Vec<Keyframe<f64>>| prop(ks, 0.0);
        assert!(!KeyframesPair::is_aligned(
            &p(vec![key(1, 0, 0.0), key(2, 2, 1.0)]),
            &p(vec![key(1, 0, 0.0), key(2, 3, 1.0)])
        ));
        assert!(!KeyframesPair::is_aligned(
            &p(vec![key(1, 0, 0.0), key(2, 2, 1.0)]),
            &p(vec![kind(key(1, 0, 0.0), Interpolation::Hold), key(2, 2, 1.0)])
        ));
        let (a, b) =
            (eased(1, 0, 0.0, h(0.4, 0.0), EaseHandle::LINEAR), eased(1, 0, 0.0, h(0.3, 0.0), EaseHandle::LINEAR));
        assert!(!KeyframesPair::is_aligned(&p(vec![a, key(2, 2, 1.0)]), &p(vec![b, key(2, 2, 1.0)])));
        assert!(!KeyframesPair::is_aligned(&p(vec![key(1, 0, 0.0)]), &p(vec![])));
    }

    /// Stabilizer-style: X and Y written with different key times.
    #[test]
    fn aligning_diverged_tracks_unions_times() {
        let x = prop(vec![key(1, 0, 0.0), key(2, 2, 20.0), key(3, 4, 0.0)], 0.0);
        let y = prop(shifted(vec![key(1, 0, 100.0), key(2, 3, 130.0)]), 0.0);
        assert!(!KeyframesPair::is_aligned(&x, &y));
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert!(KeyframesPair::is_aligned(&ax, &ay));
        assert_eq!(times(&ax), vec![t(0), t(2), t(3), t(4)]);
        // Original keys kept (ids and values), missing ones interpolated.
        assert!(ax.track.keys[0].id == x.track.keys[0].id && ax.track.keys[1].id == x.track.keys[1].id);
        assert_eq!(values(&ax), vec![0.0, 20.0, 10.0, 0.0]);
        assert_eq!(values(&ay), vec![100.0, 120.0, 130.0, 130.0]);
        for i in 0..=16 {
            let at = Time::new(i, 4);
            assert!((ax.value_at_local(at) - x.value_at_local(at)).abs() < 1e-9);
            assert!((ay.value_at_local(at) - y.value_at_local(at)).abs() < 1e-9);
        }
    }

    #[test]
    fn aligning_copies_easing_to_a_missing_member() {
        let ease = h(0.5, 0.0);
        let mut hold = kind(key(2, 2, 7.0), Interpolation::Hold);
        hold.in_handle = h(0.2, 0.1);
        let x = prop(vec![eased(1, 0, 0.0, ease, ease), hold], 0.0);
        let y = prop(vec![], 42.0);
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert!(KeyframesPair::is_aligned(&ax, &ay));
        assert_eq!(values(&ay), vec![42.0, 42.0]);
        let k = &ay.track.keys;
        assert!(k[0].interpolation == Interpolation::Bezier && k[0].out_handle == ease && k[0].in_handle == ease);
        assert!(k[1].interpolation == Interpolation::Hold && k[1].in_handle == h(0.2, 0.1));
        // The full member is untouched, new keys get fresh ids.
        assert_eq!(ax, x);
        assert!(k.iter().all(|a| ax.track.keys.iter().all(|b| a.id != b.id)));
    }

    /// Both change over the stretch with different easing: aligning keeps both curves (unaligned); a pair row edit
    /// then gives Y X's shape.
    #[test]
    fn aligning_same_time_different_easing_follows_x_on_edit() {
        let x = prop(vec![eased(1, 0, 0.0, h(0.4, 0.0), EaseHandle::LINEAR), key(2, 2, 1.0)], 0.0);
        let y = prop(shifted(vec![key(1, 0, 5.0), key(2, 2, 6.0)]), 0.0);
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert!(ax == x && ay == y && !KeyframesPair::is_aligned(&ax, &ay));
        let (mut ex, mut ey) = (x.clone(), y.clone());
        KeyframesPair::edit(&mut ex, &mut ey, &mut FreshIds::new(), |_, _| {});
        assert!(KeyframesPair::is_aligned(&ex, &ey) && ex == x);
        assert_eq!(values(&ey), vec![5.0, 6.0]);
        assert_eq!(
            ey.track.keys.iter().map(|k| k.id).collect::<Vec<_>>(),
            y.track.keys.iter().map(|k| k.id).collect::<Vec<_>>()
        );
        assert_eq!(ey.track.keys[0].out_handle, h(0.4, 0.0));
    }

    #[test]
    fn aligning_an_aligned_pair_is_the_identity() {
        let x = prop(vec![key(1, 0, 0.0), key(2, 2, 10.0)], 0.0);
        let y = prop(shifted(vec![key(1, 0, 1.0), key(2, 2, 2.0)]), 0.0);
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert!(ax == x && ay == y);
    }

    #[test]
    fn zipped_only_when_aligned_and_evaluates_like_the_members() {
        assert!(
            KeyframesPair::zipped(&prop(vec![key(1, 0, 0.0), key(2, 2, 1.0)], 0.0), &prop(vec![key(3, 1, 0.0)], 0.0))
                .is_none()
        );
        let z = KeyframesPair::zipped(&prop(vec![], 3.0), &prop(vec![], 4.0)).expect("aligned");
        assert!(z.value == Vec2::new(3.0, 4.0) && !z.is_animated());
        let e = h(0.6, 0.1);
        let x = prop(
            vec![eased(1, 0, 0.0, e, e), eased(2, 2, 30.0, e, e), kind(key(3, 4, 30.0), Interpolation::Hold)],
            0.0,
        );
        let y = prop(
            shifted(vec![eased(1, 0, 0.0, e, e), eased(2, 2, 40.0, e, e), kind(key(3, 4, 0.0), Interpolation::Hold)]),
            0.0,
        );
        let z = KeyframesPair::zipped(&x, &y).expect("aligned");
        assert_eq!(
            z.track.keys.iter().map(|k| k.id).collect::<Vec<_>>(),
            x.track.keys.iter().map(|k| k.id).collect::<Vec<_>>()
        );
        for i in 0..=16 {
            let at = Time::new(i, 4);
            let v = z.value_at_local(at);
            assert!((v.x - x.value_at_local(at)).abs() < 1e-9 && (v.y - y.value_at_local(at)).abs() < 1e-9);
        }
    }

    /// Speed of the zipped track = |delta| / duration x ease'(t): one curve for an aligned pair.
    #[test]
    fn zipped_speed_is_delta_length_times_ease_slope() {
        let (out, in_h) = (h(0.5, 0.0), h(0.25, 0.0));
        let x = prop(vec![eased(1, 0, 0.0, out, EaseHandle::LINEAR), eased(2, 2, 30.0, EaseHandle::LINEAR, in_h)], 0.0);
        let y = prop(
            shifted(vec![eased(1, 0, 0.0, out, EaseHandle::LINEAR), eased(2, 2, 40.0, EaseHandle::LINEAR, in_h)]),
            0.0,
        );
        let z = KeyframesPair::zipped(&x, &y).expect("aligned");
        let samples = &z.track.speed_graph(21)[0].samples;
        let (dur, delta) = (2.0, 50.0);
        for s in samples {
            let tn = s.time / dur;
            let eps = 1e-4;
            let (lo, hi) = ((tn - eps).max(0.0), (tn + eps).min(1.0));
            let slope = (keyframe_math::bezier_progress(hi, out, in_h) - keyframe_math::bezier_progress(lo, out, in_h))
                / (hi - lo);
            assert!((s.speed - delta / dur * slope).abs() < 1e-3);
        }
        assert!(samples[0].speed < 0.5 && samples[10].speed > delta / dur);
    }

    /// A partner's Hold key must not turn a key inserted into this member into a Hold (x(3s) stays 30, not 20).
    #[test]
    fn aligning_partner_hold_keeps_own_ramp() {
        let x = prop(vec![key(1, 0, 0.0), key(2, 4, 40.0)], 0.0);
        let y = prop(shifted(vec![key(1, 0, 5.0), kind(key(2, 2, 7.0), Interpolation::Hold), key(3, 4, 9.0)]), 0.0);
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert_eq!(times(&ax), vec![t(0), t(2), t(4)]);
        assert_eq!(ax.value_at_local(t(3)), 30.0);
        same_curve(&ax, &x, 4);
        same_curve(&ay, &y, 4);
    }

    /// A key inserted into this member's own Hold segment stays Hold (no ramp).
    #[test]
    fn aligning_own_hold_segment_stays_hold() {
        let x = prop(vec![kind(key(1, 0, 0.0), Interpolation::Hold), key(2, 4, 40.0)], 0.0);
        let y = prop(shifted(vec![key(1, 1, 0.0), key(2, 2, 5.0), key(3, 4, 9.0)]), 0.0);
        let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
        assert_eq!(times(&ax), vec![t(0), t(1), t(2), t(4)]);
        assert_eq!(ax.track.keys[2].interpolation, Interpolation::Hold);
        assert_eq!(ax.value_at_local(t(3)), 0.0);
        same_curve(&ax, &x, 4);
        same_curve(&ay, &y, 4);
    }

    /// A key inserted into an eased segment splits it: both halves get renormalised handles, the curve is unchanged.
    #[test]
    fn aligning_splits_an_eased_segment_exactly() {
        for (out, in_h) in [(h(0.5, 0.0), h(0.25, 0.0)), (h(0.3, 0.6), h(0.7, -0.2)), (h(0.9, 0.1), h(0.05, 0.4))] {
            let x =
                prop(vec![eased(1, 0, 0.0, out, EaseHandle::LINEAR), eased(2, 4, 40.0, EaseHandle::LINEAR, in_h)], 0.0);
            let y = prop(shifted(vec![key(1, 1, 1.0), key(2, 3, 2.0)]), 0.0);
            let (ax, ay) = KeyframesPair::aligning(&x, &y, &mut FreshIds::new());
            assert_eq!(times(&ax), vec![t(0), t(1), t(3), t(4)]);
            assert!(ax.track.keys[0].id == x.track.keys[0].id && ax.track.keys[3].id == x.track.keys[1].id);
            same_curve(&ax, &x, 4);
            same_curve(&ay, &y, 4);
        }
    }

    #[test]
    fn editable_reads_both_members_as_one_vec2() {
        let x = prop(vec![key(1, 0, 0.0), key(2, 4, 40.0)], 1.0);
        let y = prop(shifted(vec![key(1, 0, 10.0), key(2, 2, 30.0)]), 2.0);
        let v = KeyframesPair::editable(&x, &y, &mut FreshIds::new());
        assert_eq!(v.track.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(0), t(2), t(4)]);
        for s in 0..=4 {
            let at = Time::new(s * 10, 10);
            assert!((v.value_at_local(at).x - x.value_at_local(at)).abs() < 1e-9);
            assert!((v.value_at_local(at).y - y.value_at_local(at)).abs() < 1e-9);
        }
        // X's ids lead.
        assert_eq!(v.track.keys[0].id, x.track.keys[0].id);
        let still = KeyframesPair::editable(&prop(vec![], 3.0), &prop(vec![], 4.0), &mut FreshIds::new());
        assert!(still.value == Vec2::new(3.0, 4.0) && !still.is_animated());
    }

    #[test]
    fn split_round_trip_keeps_ids_and_curves() {
        let x = prop(vec![key(1, 0, 0.0), key(2, 2, 20.0)], 0.0);
        let y = prop(shifted(vec![key(1, 0, 5.0), key(2, 2, 7.0)]), 0.0);
        let mut ids = FreshIds::new();
        let (sx, sy) = KeyframesPair::split(&KeyframesPair::editable(&x, &y, &mut ids), &y, &mut ids);
        assert!(sx == x && sy == y);
    }

    #[test]
    fn edit_through_vec2_writes_both_members_aligned() {
        let mut x = prop(vec![eased(1, 0, 0.0, h(0.5, 0.0), EaseHandle::LINEAR), key(2, 4, 40.0)], 0.0);
        let mut y = prop(shifted(vec![key(1, 0, 10.0), key(2, 4, 10.0)]), 0.0);
        KeyframesPair::edit(&mut x, &mut y, &mut FreshIds::new(), |v, ids| {
            v.track.insert(Keyframe::new(ids.next_id(), t(2), Vec2::new(99.0, 77.0)));
        });
        assert!(KeyframesPair::is_aligned(&x, &y));
        assert_eq!(times(&x), vec![t(0), t(2), t(4)]);
        assert!(x.value_at_local(t(2)) == 99.0 && y.value_at_local(t(2)) == 77.0);
        // Members never share key ids; Y follows X's easing on a pair edit.
        assert_ne!(x.track.keys[1].id, y.track.keys[1].id);
        assert_eq!(y.track.keys[0].out_handle, x.track.keys[0].out_handle);
    }

    #[test]
    fn edit_of_a_static_value() {
        let (mut x, mut y) = (prop(vec![], 1.0), prop(vec![], 2.0));
        KeyframesPair::edit(&mut x, &mut y, &mut FreshIds::new(), |v, _| v.value = Vec2::new(5.0, 6.0));
        assert!(x.value == 5.0 && y.value == 6.0 && !x.is_animated() && !y.is_animated());
    }

    #[test]
    fn paste_through_a_pair_row_writes_both_members() {
        let (mut x, mut y) = (prop(vec![], 0.0), prop(vec![], 0.0));
        let keys = vec![Keyframe::new(Id::from_u128(7), t(1), Vec2::new(3.0, 4.0))];
        KeyframesPair::paste(&keys, &mut x, &mut y, &mut FreshIds::new());
        assert!(KeyframesPair::is_aligned(&x, &y));
        assert!(x.track.keys[0].id == Id::from_u128(7) && y.track.keys[0].id != Id::from_u128(7));
        assert_eq!((x.value_at_local(t(1)), y.value_at_local(t(1))), (3.0, 4.0));
    }
}
