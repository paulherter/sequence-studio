//! `addZoomCut` end to end: keys, fades, caps, hard cuts, dry run, refusals.

use crate::clip_params::clip_params_json;
use crate::edit_operation::EditOperation;
use crate::edit_transaction::fixture::Fixture;
use crate::edit_transaction::{EditTransaction, TransactionErrorKind};
use serde_json::{Value, json};
use sq_core_edit::history::History;
use sq_core_model::{Clip, Project, Track, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};

struct Scene {
    f: Fixture,
    project: Project,
    u: Id,
    w: Id,
    short: Id,
}

/// V1 = [a 0-4][b 4-8][short 8-8.4], V2 (above) = [u 0-4][w 4-8]; 25 fps.
fn scene() -> Scene {
    let f = Fixture::new();
    let mut p = f.project.clone();
    let media = p.media[0].id;
    let mk = |n: u128, at: Time, len: Time| {
        let mut c = Clip::new(Id::from_u128(3000 + n), "x", media, TrackKind::Video, TimeRange::new(Time::new(0, 1), len), at);
        c.media_duration = Some(Time::new(20, 1));
        c
    };
    let (u, w, short) = (mk(1, Time::new(0, 1), Time::new(4, 1)), mk(2, Time::new(4, 1), Time::new(4, 1)), mk(3, Time::new(8, 1), Time::new(2, 5)));
    let t = &mut p.timelines[0];
    let mut v2 = Track::new(Id::from_u128(20), TrackKind::Video);
    v2.set_clips(vec![u.clone(), w.clone()]);
    let v1 = t.tracks.iter_mut().find(|x| x.id == f.v1).expect("v1");
    let mut clips = v1.clips().to_vec();
    clips.push(short.clone());
    v1.set_clips(clips);
    t.tracks.push(v2);
    Scene { f, project: p, u: u.id, w: w.id, short: short.id }
}

fn run(s: &Scene, v: Value) -> Result<History<Project>, crate::edit_transaction::TransactionError> {
    let ops: Vec<EditOperation> = serde_json::from_value(v).unwrap_or_else(|e| panic!("ops: {e}"));
    let mut h = History::with_default_limit(s.project.clone());
    h.try_commit("Agent: Zoom cut", |p| EditTransaction::apply(&ops, p, s.f.seq, &mut SequentialIds::default()))?;
    Ok(h)
}

/// (ms, value) of every key of `path`; scale reads its x.
fn keys(h: &History<Project>, clip: Id, path: &str) -> Vec<(i64, f64)> {
    let p = h.current();
    let c = p.timelines[0].tracks.iter().find_map(|tr| tr.clip(clip)).expect("clip");
    let j = clip_params_json(c);
    let param = j["params"].as_array().and_then(|a| a.iter().find(|p| p["path"] == path)).expect("param");
    param["keyframes"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|k| {
                    let at = k["at"]["value"].as_f64().unwrap_or(0.0) / k["at"]["timescale"].as_f64().unwrap_or(1.0);
                    let v = if k["value"].is_object() { k["value"]["x"].as_f64() } else { k["value"].as_f64() };
                    ((at * 1000.0).round() as i64, (v.unwrap_or(f64::NAN) * 1000.0).round() / 1000.0)
                })
                .collect()
        })
        .unwrap_or_default()
}

const SCALE: &str = "motion.scale";

#[test]
fn zoom_cut_upper_arriving_in_zooms_both_and_fades_only_the_upper() {
    let s = scene();
    let (a, w) = (s.f.a, s.w);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":w,"direction":"in"}])).unwrap_or_else(|e| panic!("{e}"));
    // Lower leaving 29 f, ending on the cut at 4 s; upper arriving 18 f from the cut.
    assert_eq!(keys(&h, a, SCALE), vec![(2840, 1.0), (4000, 1.1)]);
    assert_eq!(keys(&h, w, SCALE), vec![(0, 1.0), (720, 1.1)]);
    assert_eq!(keys(&h, w, "opacity"), vec![(0, 0.0), (80, 1.0)]);
    assert!(keys(&h, a, "opacity").is_empty());
    // Ease-in on the leaving clip, ease-out on the arriving one: the fast side is at the cut.
    let p = h.current();
    let out_key = p.timelines[0].tracks[0].clip(a).and_then(|c| c.animation.scale.track.keys.first().cloned()).expect("key");
    let in_key = p.timelines[0].tracks[2].clip(w).and_then(|c| c.animation.scale.track.keys.last().cloned()).expect("key");
    assert!(out_key.out_handle.dx > 0.99, "leaving clip starts slow: {:?}", out_key.out_handle);
    // Ease-out 100 % keeps the first key linear and settles into the last one (in influence 1.0): fast at the cut.
    assert!(in_key.in_handle.dx > 0.99, "arriving clip settles slowly at its end: {:?}", in_key.in_handle);
}

#[test]
fn zoom_cut_upper_leaving_out_fades_out_and_zooms_110_to_100() {
    let s = scene();
    let (u, b) = (s.u, s.f.b);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":u,"incoming":b,"direction":"out"}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys(&h, u, SCALE), vec![(3240, 1.1), (4000, 1.0)]); // upper leaving 19 f
    assert_eq!(keys(&h, u, "opacity"), vec![(3920, 1.0), (4000, 0.0)]);
    assert_eq!(keys(&h, b, SCALE), vec![(0, 1.1), (1320, 1.0)]); // lower arriving 33 f
    assert!(keys(&h, b, "opacity").is_empty());
}

#[test]
fn zoom_cut_same_track_is_a_hard_cut_without_fade() {
    let s = scene();
    let (a, b) = (s.f.a, s.f.b);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":b,"direction":"in","fadeFrames":4}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys(&h, a, SCALE).len(), 2);
    assert_eq!(keys(&h, b, SCALE).len(), 2);
    assert!(keys(&h, a, "opacity").is_empty() && keys(&h, b, "opacity").is_empty());
}

#[test]
fn zoom_cut_clip_visible_under_half_a_second_gets_no_zoom() {
    let s = scene();
    let (b, short) = (s.f.b, s.short);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":b,"incoming":short,"direction":"in"}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys(&h, b, SCALE).len(), 2);
    assert!(keys(&h, short, SCALE).is_empty());
}

#[test]
fn zoom_cut_length_is_capped_at_half_the_visible_time() {
    let s = scene();
    let (a, b) = (s.f.a, s.f.b);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":b,"direction":"in","outFrames":90,"inFrames":90}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys(&h, a, SCALE)[0].0, 2000); // 100 f clip: at most 50 f
    assert_eq!(keys(&h, b, SCALE)[1].0, 2000);
}

#[test]
fn zoom_cut_dry_run_writes_nothing_and_reads_the_keys_back() {
    let s = scene();
    let ops: Vec<EditOperation> =
        serde_json::from_value(json!([{"op":"addZoomCut","outgoing":s.f.a,"incoming":s.w,"direction":"in"}])).expect("ops");
    let (p, diff) = EditTransaction::preview(&ops, &s.project, s.f.seq, &mut SequentialIds::default()).expect("preview");
    assert_ne!(p, s.project);
    assert!(serde_json::to_string(&diff).is_ok_and(|j| j.contains("motion.scale")));
    // The original is untouched.
    let clip = s.project.timelines[0].tracks[0].clip(s.f.a).expect("a");
    assert!(!clip.animation.scale.is_animated());
}

#[test]
fn zoom_cut_refusals_and_undo() {
    let s = scene();
    let (a, b, w) = (s.f.a, s.f.b, s.w);
    for bad in [
        json!([{"op":"addZoomCut","outgoing":a,"incoming":b,"direction":"sideways"}]),
        json!([{"op":"addZoomCut","outgoing":a,"incoming":b,"direction":"in","zzz":1}]),
        json!([{"op":"addZoomCut","outgoing":a,"incoming":b}]),
        json!([{"op":"addZoomCut","outgoing":a,"incoming":b,"direction":"in","outFrames":0}]),
    ] {
        assert!(serde_json::from_value::<Vec<EditOperation>>(bad).is_err());
    }
    // Clips that do not touch are refused with a message.
    let e = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":w,"direction":"in"},{"op":"addZoomCut","outgoing":a,"incoming":s.u,"direction":"in"}]));
    assert!(e.err().is_some_and(|e| e.kind == TransactionErrorKind::Invalid && e.message().contains("exactly")));
    // One undo step.
    let mut h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":w,"direction":"in"}])).expect("applies");
    assert!(h.undo());
    assert!(keys(&h, a, SCALE).is_empty());
}
