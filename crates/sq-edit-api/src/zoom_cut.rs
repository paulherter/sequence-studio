//! `addZoomCut`: a zoom transition at a cut, written as plain keys through the same path as `setKeyframe`.
//! Both pictures move in the same direction (in = scale 100 -> 110 %, out = 110 -> 100 %); the outgoing one eases in
//! (fastest at the cut), the incoming one eases out (fastest at the cut); only the upper picture fades.

use crate::clip_params::KeyShape;
use crate::param_ops::{OpFailure, set_keyframe};
use serde_json::{Value, json};
use sq_core_model::{Clip, EditError, Timeline, TrackKind};
use sq_core_time::{IdSource, Time};

/// Preferred move lengths in frames: upper leaving, lower arriving, lower leaving, upper arriving.
const UPPER_LEAVE: i64 = 19;
const LOWER_ARRIVE: i64 = 33;
const LOWER_LEAVE: i64 = 29;
const UPPER_ARRIVE: i64 = 18;
/// A picture visible for less than this gets no zoom (seconds).
const MIN_VISIBLE: Time = Time::new(1, 2);
pub(crate) const DEFAULT_FADE_FRAMES: i64 = 2;

/// Wire fields of the op.
#[derive(Clone, Debug, PartialEq)]
pub struct ZoomCut {
    pub outgoing: sq_core_time::Id,
    pub incoming: sq_core_time::Id,
    /// true = "in" (100 -> 110 %), false = "out" (110 -> 100 %).
    pub zoom_in: bool,
    pub out_frames: Option<i64>,
    pub in_frames: Option<i64>,
    pub fade_frames: Option<i64>,
}

impl ZoomCut {
    pub(crate) fn parse(c: &serde_json::Map<String, Value>) -> Result<ZoomCut, String> {
        let zoom_in = match crate::edit_operation::required::<String>(c, "direction")?.as_str() {
            "in" => true,
            "out" => false,
            other => return Err(format!("direction: unknown '{other}'; known: in, out")),
        };
        let frames = |k: &str, min: i64| -> Result<Option<i64>, String> {
            let v: Option<i64> = crate::edit_operation::optional(c, k)?;
            match v {
                Some(n) if !(min..=600).contains(&n) => Err(format!("{k}: must be {min}...600 frames, got {n}")),
                v => Ok(v),
            }
        };
        Ok(ZoomCut {
            outgoing: crate::edit_operation::required(c, "outgoing")?,
            incoming: crate::edit_operation::required(c, "incoming")?,
            zoom_in,
            out_frames: frames("outFrames", 1)?,
            in_frames: frames("inFrames", 1)?,
            fade_frames: frames("fadeFrames", 0)?,
        })
    }
}

fn find(t: &Timeline, id: sq_core_time::Id) -> Result<(usize, Clip), OpFailure> {
    for (i, tr) in t.tracks.iter().enumerate() {
        if let Some(c) = tr.clip(id) {
            return Ok((i, c.clone()));
        }
    }
    Err(EditError::ClipNotFound.into())
}

pub(crate) fn add_zoom_cut(t: &mut Timeline, z: &ZoomCut, ids: &mut dyn IdSource) -> Result<(), OpFailure> {
    let (out_track, out) = find(t, z.outgoing)?;
    let (in_track, inc) = find(t, z.incoming)?;
    if out.kind != TrackKind::Video || inc.kind != TrackKind::Video {
        return Err("addZoomCut: both clips must be video clips".to_string().into());
    }
    if out.timeline().end() != inc.start {
        return Err("addZoomCut: the outgoing clip must end exactly where the incoming clip starts".to_string().into());
    }
    let fd = t.frame_duration();
    let frames = |n: i64| Time::frames(n, fd);
    // The upper picture is the one on the higher track (tracks run bottom to top); the same track = hard cut.
    let upper_is_outgoing = out_track > in_track;
    let upper_is_incoming = in_track > out_track;
    let fade = z.fade_frames.unwrap_or(DEFAULT_FADE_FRAMES);
    let (lo, hi) = (1.0, 1.1);
    let (from, to) = if z.zoom_in { (lo, hi) } else { (hi, lo) };
    let scale = |s: f64| json!([s, s]);
    let ease = |e: &str| KeyShape::parse(None, Some(e), None, None);
    let linear = ease("linear")?;

    // Outgoing: the move ends on its last frame.
    let out_len = z.out_frames.unwrap_or(if upper_is_outgoing { UPPER_LEAVE } else { LOWER_LEAVE });
    let in_len = z.in_frames.unwrap_or(if upper_is_incoming { UPPER_ARRIVE } else { LOWER_ARRIVE });
    let moves = [(&out, z.outgoing, out_len, true), (&inc, z.incoming, in_len, false)];
    for (clip, id, want, leaving) in moves {
        let dur = clip.duration();
        let dur_frames = dur.frame_index(fd);
        let n = want.min(dur_frames / 2);
        if dur >= MIN_VISIBLE && n >= 1 {
            let (a, b) = if leaving { (dur - frames(n), dur) } else { (Time::new(0, 1), frames(n)) };
            let shape = ease(if leaving { "easeIn" } else { "easeOut" })?;
            set_keyframe(t, id, "motion.scale", a, &scale(from), &shape, ids)?;
            set_keyframe(t, id, "motion.scale", b, &scale(to), &shape, ids)?;
        }
        let is_upper = if leaving { upper_is_outgoing } else { upper_is_incoming };
        let fade_n = fade.min(dur_frames / 2);
        if is_upper && fade_n >= 1 {
            let (a, b, va, vb) = if leaving {
                (dur - frames(fade_n), dur, 1.0, 0.0)
            } else {
                (Time::new(0, 1), frames(fade_n), 0.0, 1.0)
            };
            set_keyframe(t, id, "opacity", a, &json!(va), &linear, ids)?;
            set_keyframe(t, id, "opacity", b, &json!(vb), &linear, ids)?;
        }
    }
    Ok(())
}
