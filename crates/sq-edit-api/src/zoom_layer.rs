//! `addAdjustmentLayer` and `addZoomCut{asLayer:true}`: the zoom of a cut laid as ONE adjustment layer over both
//! pictures. Curves and rules come from `zoom_profile.json` (the editor's transition profile, a copy of
//! Schnitt-Profil/uebergaenge.json): two keys per move, the cut-side key is the fastest point (steep short handle), the
//! calm side's handle is pulled out to 100 %, both moves run at the same speed at the cut (the longer move sets it, the
//! shorter one zooms less), never below 100 %. The direction (in = 100 -> 110, out = 110 -> 100) is the caller's: it
//! alternates from cut to cut.
//!
//! shortcut: the 2-frame offsets of the lower picture's move (starts at c-2 / ends at c+2 in the per-clip form) are not
//! reproduced: one layer moves both pictures, so the outgoing move ends on the last frame before the cut and the incoming
//! one starts on the cut frame. The upper picture's 2-frame fade stays an opacity key on the upper clip.
//! A picture shorter than the minimum move (profile `min_move` frames / 70 % of the clip) is refused, the per-clip form
//! (no layer) has no such limit; upgrade when single-move pictures are needed on layers.

use crate::clip_params::KeyShape;
use crate::param_ops::{OpFailure, set_keyframe};
use crate::zoom_cut::{ZoomCut, find};
use serde_json::{Value, json};
use sq_core_effects::adjustment_clip::adjustment_layer;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time};

const PROFILE: &str = include_str!("zoom_profile.json");

/// The numbers of the profile this module uses.
pub(crate) struct Profile {
    pub fast_influence: f64,
    pub peak: f64,
    pub upper_leave: i64,
    pub lower_arrive: i64,
    pub lower_leave: i64,
    pub upper_arrive: i64,
    pub min_move: i64,
    pub fade_frames: i64,
    pub hold_share: f64,
    pub lo: f64,
    pub hi: f64,
}

pub(crate) fn profile() -> Profile {
    let j: Value = serde_json::from_str(PROFILE).unwrap_or_else(|e| panic!("zoom_profile.json is valid: {e}"));
    let n = |p: &str| j.pointer(p).and_then(Value::as_i64).unwrap_or_else(|| panic!("zoom_profile.json: {p}"));
    let f = |p: &str| j.pointer(p).and_then(Value::as_f64).unwrap_or_else(|| panic!("zoom_profile.json: {p}"));
    Profile {
        fast_influence: f("/curves/fast_side_handle_influence"),
        // The reference's PEAK (speed at the cut / average speed of a short move): the fast handle's height is PEAK x its
        // influence; the profile file states the influence, the peak ratio is the reference's constant.
        peak: 2.6,
        upper_leave: n("/timing_frames/upper_leave"),
        lower_arrive: n("/timing_frames/lower_arrive"),
        lower_leave: n("/timing_frames/lower_leave"),
        upper_arrive: n("/timing_frames/upper_arrive"),
        min_move: n("/timing_frames/min_move"),
        fade_frames: n("/pair/upper_fade_frames"),
        hold_share: f("/holds/min_share"),
        lo: f("/pair/scale_range/0") / 100.0,
        hi: f("/pair/scale_range/1") / 100.0,
    }
}

fn bezier_x(s: f64, a: f64, b: f64) -> f64 {
    let u = 1.0 - s;
    3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s
}

/// Eased progress of a segment for handles (dx, dy) out and in, like `keyframe_math::bezier_progress`.
pub(crate) fn progress(t: f64, out: (f64, f64), inh: (f64, f64)) -> f64 {
    let (x1, x2) = (out.0.clamp(0.0, 1.0), 1.0 - inh.0.clamp(0.0, 1.0));
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..60 {
        let m = (lo + hi) / 2.0;
        if bezier_x(m, x1, x2) < t { lo = m } else { hi = m }
    }
    bezier_x((lo + hi) / 2.0, out.1, 1.0 - inh.1)
}

/// Peak speed / average speed of a one-sided move of `frames` frames (fast handle at one end, calm 100 % at the other).
pub(crate) fn factor(p: &Profile, frames: i64) -> f64 {
    let (o, i) = ((p.fast_influence, p.peak * p.fast_influence), (1.0, 0.0));
    let v: Vec<f64> = (0..=frames).map(|k| progress(k as f64 / frames as f64, o, i)).collect();
    v.windows(2).map(|w| w[1] - w[0]).fold(0.0, f64::max) * frames as f64
}

/// Places an Adjustment Layer clip (`addAdjustmentLayer`).
pub(crate) fn place_adjustment(
    t: &mut Timeline,
    track: Id,
    at: Time,
    duration: Time,
    name: Option<&str>,
    ids: &mut dyn IdSource,
) -> Result<Id, OpFailure> {
    let fd = t.frame_duration();
    let (start, duration) = (at.snapped(fd), duration.snapped(fd).max(fd));
    let placement = GeneratorPlacement { timeline: t.id, track, start, duration };
    Ok(t.place_generator_clip(adjustment_layer(), Some(name.unwrap_or("Adjustment Layer")), placement, ids)?)
}

/// One bezier key of the layer's scale: `handle` = (side, influence %, speed) as the wire handle.
struct Key {
    at: i64,
    value: f64,
    in_handle: Option<Value>,
    out_handle: Option<Value>,
    hold: bool,
}

pub(crate) fn add_zoom_layer(t: &mut Timeline, z: &ZoomCut, ids: &mut dyn IdSource) -> Result<(), OpFailure> {
    let (out_track, out) = find(t, z.outgoing)?;
    let (in_track, inc) = find(t, z.incoming)?;
    if out.kind != TrackKind::Video || inc.kind != TrackKind::Video {
        return Err("addZoomCut: both clips must be video clips".to_string().into());
    }
    if out.timeline().end() != inc.start {
        return Err("addZoomCut: the outgoing clip must end exactly where the incoming clip starts".to_string().into());
    }
    let p = profile();
    let fd = t.frame_duration();
    let frames = |n: i64| Time::frames(n, fd);
    let cut = inc.start;
    let upper_is_outgoing = out_track > in_track;
    let upper_is_incoming = in_track > out_track;
    // Lengths: the profile's, shortened to leave a calm hold (`min_share` of the picture) in each clip.
    let want_out = z.out_frames.unwrap_or(if upper_is_outgoing { p.upper_leave } else { p.lower_leave });
    let want_in = z.in_frames.unwrap_or(if upper_is_incoming { p.upper_arrive } else { p.lower_arrive });
    let room = |c: &sq_core_model::Clip| (c.duration().frame_index(fd) as f64 * (1.0 - p.hold_share)).floor() as i64;
    let (x, m) = (want_out.min(room(&out) - 1), want_in.min(room(&inc)));
    if x < p.min_move || m < p.min_move {
        return Err(format!(
            "addZoomCut asLayer: both clips need room for a move of at least {} frames (clips of about 0.5 s or longer)",
            p.min_move
        )
        .into());
    }
    // Speed at the cut: the longer move at full zoom sets it; the shorter one zooms less.
    let long = x.max(m);
    let v = factor(&p, long) * (p.hi - p.lo) / long as f64;
    let amount = |n: i64| if n == long { p.hi - p.lo } else { (v * n as f64 / factor(&p, n)).clamp(0.03, p.hi - p.lo) };
    let (a_out, a_in) = (amount(x), amount(m));

    // Layer range: the outgoing move ends on the last frame before the cut, the incoming one starts on the cut frame.
    let start = cut - frames(x + 1);
    let duration = frames(x + 1 + m);
    let track = layer_track(t, z.track, out_track.max(in_track), start, start + duration, ids)?;
    let layer = place_adjustment(t, track, start, duration, Some("Zoom Layer"), ids)?;

    let fi = p.fast_influence;
    let secs = |n: i64| (n as f64) * sq_core_time::keyframes_model::keyframe_math::seconds(fd);
    // API speed of a handle: value units per second (the scale key is a 2D value: its speed measure is the vector length).
    let fast = |dy: f64, n: i64, amount: f64| json!({"influence": fi * 100.0, "speed": dy / fi * amount * std::f64::consts::SQRT_2 / secs(n)});
    let calm = json!({"influence": 100.0, "speed": 0.0});
    let (out_from, out_to, in_from, in_to) =
        if z.zoom_in { (p.lo, p.lo + a_out, p.lo, p.lo + a_in) } else { (p.lo + a_out, p.lo, p.lo + a_in, p.lo) };
    let keys = [
        Key { at: 0, value: out_from, in_handle: None, out_handle: Some(calm.clone()), hold: false },
        Key { at: x, value: out_to, in_handle: Some(fast(p.peak * fi, x, a_out)), out_handle: None, hold: true },
        Key { at: x + 1, value: in_from, in_handle: None, out_handle: Some(fast(p.peak * fi, m, a_in)), hold: false },
        Key { at: x + 1 + m, value: in_to, in_handle: Some(calm), out_handle: None, hold: false },
    ];
    let linear = KeyShape::parse(Some("linear"), None, None, None)?;
    // First all keys, then the handles: a speed needs the neighbor key.
    for k in &keys {
        set_keyframe(t, layer, "motion.scale", frames(k.at), &json!([k.value, k.value]), &linear, ids)?;
    }
    for k in &keys {
        let shape = KeyShape::parse(
            Some(if k.hold { "hold" } else { "bezier" }),
            None,
            k.in_handle.as_ref(),
            k.out_handle.as_ref(),
        )?;
        set_keyframe(t, layer, "motion.scale", frames(k.at), &json!([k.value, k.value]), &shape, ids)?;
    }

    // The upper picture fades over the profile's 2 frames (an opacity key on the clip, the layer cannot fade one picture).
    let fade = z.fade_frames.unwrap_or(p.fade_frames);
    let linear_shape = KeyShape::parse(Some("linear"), None, None, None)?;
    for (clip, id, leaving, upper) in
        [(&out, z.outgoing, true, upper_is_outgoing), (&inc, z.incoming, false, upper_is_incoming)]
    {
        let dur = clip.duration();
        let n = fade.min(dur.frame_index(fd) / 2);
        if upper && n >= 1 {
            let (a, b, va, vb) =
                if leaving { (dur - frames(n), dur, 1.0, 0.0) } else { (Time::new(0, 1), frames(n), 0.0, 1.0) };
            set_keyframe(t, id, "opacity", a, &json!(va), &linear_shape, ids)?;
            set_keyframe(t, id, "opacity", b, &json!(vb), &linear_shape, ids)?;
        }
    }
    Ok(())
}

/// The layer's track: the given one, else the first video track above both clips that is free over the range, else a new
/// top video track.
fn layer_track(
    t: &mut Timeline,
    given: Option<Id>,
    above: usize,
    start: Time,
    end: Time,
    ids: &mut dyn IdSource,
) -> Result<Id, OpFailure> {
    if let Some(g) = given {
        return Ok(g);
    }
    let free = |tr: &sq_core_model::Track| !tr.clips().iter().any(|c| c.start < end && c.timeline().end() > start);
    if let Some(tr) = t.tracks.iter().enumerate().find(|(i, tr)| *i > above && tr.kind == TrackKind::Video && free(tr))
    {
        return Ok(tr.1.id);
    }
    use sq_core_edit::timeline_add_track::AddTrackExt;
    Ok(t.insert_track_after_last(TrackKind::Video, ids))
}
