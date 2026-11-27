//! `addAdjustmentLayer` and `addZoomCut{asLayer}` end to end: ids, keys, handles against the transition profile, undo.

use crate::clip_params::clip_params_json;
use crate::edit_operation::EditOperation;
use crate::edit_transaction::EditTransaction;
use crate::zoom_cut_tests::{run, scene};
use crate::zoom_layer::{factor, profile, progress};
use serde_json::json;
use sq_core_edit::history::History;
use sq_core_model::{Clip, Project};
use sq_core_time::{Id, SequentialIds, Time};

fn layers(p: &Project) -> Vec<(usize, Clip)> {
    let mut v = Vec::new();
    for (i, tr) in p.timelines[0].tracks.iter().enumerate() {
        for c in tr.clips() {
            if c.generator.as_ref().is_some_and(|g| g.kind == "adjustment") {
                v.push((i, c.clone()));
            }
        }
    }
    v
}

fn scale_at(c: &Clip, frame: i64) -> f64 {
    c.animation.scale.value_at_local(Time::frames(frame, Time::new(1, 25))).x
}

#[test]
fn add_adjustment_layer_places_a_generator_clip_that_takes_effects_and_keys() {
    let s = scene();
    let v2 = s.project.timelines[0].tracks.iter().find(|t| t.clips().iter().any(|c| c.id == s.u)).map(|t| t.id);
    let track = v2.expect("v2");
    let ops = json!([{"op":"addAdjustmentLayer","track":track,"at":{"value":1,"timescale":1},"duration":{"value":2,"timescale":1}}]);
    let parsed: Vec<EditOperation> = serde_json::from_value(ops).unwrap_or_else(|e| panic!("{e}"));
    // The wire form round-trips (the router and the history log serialize ops).
    let again = serde_json::to_value(&parsed).unwrap_or_default();
    assert_eq!(again[0]["op"], "addAdjustmentLayer");
    let mut h = History::with_default_limit(s.project.clone());
    // The track above V1 holds u and w over 0-8 s: the layer overwrites a piece of them, as any generator drop does.
    h.try_commit("t", |p| EditTransaction::apply(&parsed, p, s.f.seq, &mut SequentialIds::default()))
        .unwrap_or_else(|e| panic!("{e}"));
    let found = layers(h.current());
    assert_eq!(found.len(), 1);
    let id = found[0].1.id;
    // addEffect, setParam and setKeyframe work on it like on any clip.
    let ops: Vec<EditOperation> = serde_json::from_value(json!([
        {"op":"setKeyframe","clip":id,"param":"motion.scale","at":{"value":0,"timescale":1},"value":[1.0,1.0]},
        {"op":"setKeyframe","clip":id,"param":"motion.scale","at":{"value":1,"timescale":1},"value":[1.1,1.1]},
        {"op":"addEffect","clip":id,"effect":"gaussianBlur"}
    ]))
    .unwrap_or_else(|e| panic!("{e}"));
    h.try_commit("t2", |p| EditTransaction::apply(&ops, p, s.f.seq, &mut SequentialIds::default()))
        .unwrap_or_else(|e| panic!("{e}"));
    let c = layers(h.current())[0].1.clone();
    assert_eq!(c.animation.scale.track.keys.len(), 2);
    assert_eq!(c.effects.len(), 1);
    let j = clip_params_json(&c);
    assert!(j["params"].as_array().is_some_and(|a| a.iter().any(|p| p["path"] == "motion.scale")));
}

/// Layer lengths for a lower leaving (42 f) and an upper arriving (26 f) clip, direction in; the values come from the
/// profile's curve (the reference numbers: peak speed factors 6.1711 / 6.0321, the shorter move zooms 6.333 %).
#[test]
fn zoom_layer_curve_matches_the_profile() {
    let s = scene();
    let (a, w) = (s.f.a, s.w);
    let h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":w,"direction":"in","asLayer":true}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let found = layers(h.current());
    assert_eq!(found.len(), 1);
    let (track_index, layer) = &found[0];
    // above both clips: V1 (a) and V2 (w) exist, so a new top track
    assert_eq!(*track_index, 3);
    // lower leaving 42 f ends on the frame before the cut (4 s = frame 100); upper arriving 26 f from the cut.
    assert_eq!(layer.start, Time::frames(100 - 43, Time::new(1, 25)));
    assert_eq!(layer.duration(), Time::frames(43 + 26, Time::new(1, 25)));
    let p = profile();
    assert_eq!((p.upper_arrive, p.lower_leave), (26, 42));
    assert!((factor(&p, 42) - 6.171119).abs() < 1e-5 && (factor(&p, 26) - 6.032107).abs() < 1e-5);
    // Reference values (uebergaenge.py math): outgoing move frame 10/30/38/42, incoming move frame 1/5/26.
    let expect_out = [(10, 1.00192), (30, 1.02553), (38, 1.05635), (42, 1.1)];
    let expect_in = [(1, 1.01469), (5, 1.03983), (26, 1.06333)];
    let at_prog = |f: f64| 1.0 + 0.1 * progress(f / 42.0, (1.0, 0.0), (p.fast_influence, p.peak * p.fast_influence));
    for (f, v) in expect_out {
        let got = scale_at(layer, f);
        assert!((got - v).abs() < 2e-3, "out frame {f}: {got} vs {v}");
        assert!((got - at_prog(f as f64)).abs() < 2e-3);
    }
    for (f, v) in expect_in {
        let got = scale_at(layer, 43 + f);
        assert!((got - v).abs() < 2e-3, "in frame {f}: {got} vs {v}");
    }
    // never below 100 %, no key outside 1.0...1.1
    assert!((0..69).all(|f| scale_at(layer, f) >= 1.0 - 1e-9));
    // same speed at the cut: last step before it and first step after it are close
    let (before, after) = (scale_at(layer, 42) - scale_at(layer, 41), scale_at(layer, 44) - scale_at(layer, 43));
    assert!(before > 0.0 && after > 0.0 && (before / after).max(after / before) < 2.0, "{before} vs {after}");
    // the upper picture (w, arriving) fades 2 frames; the lower (a) none
    let pj = h.current();
    let wc = pj.timelines[0].tracks.iter().find_map(|t| t.clip(w)).expect("w");
    assert_eq!(wc.animation.opacity.track.keys.len(), 2);
    let ac = pj.timelines[0].tracks.iter().find_map(|t| t.clip(a)).expect("a");
    assert!(ac.animation.opacity.track.keys.is_empty() && ac.animation.scale.track.keys.is_empty());
}

#[test]
fn zoom_layer_refuses_a_clip_under_half_a_second_and_undoes_in_one_step() {
    let s = scene();
    let (b, short) = (s.f.b, s.short);
    let r = run(&s, json!([{"op":"addZoomCut","outgoing":b,"incoming":short,"direction":"in","asLayer":true}]));
    assert!(r.is_err());
    let (a, bb) = (s.f.a, s.f.b);
    let mut h = run(&s, json!([{"op":"addZoomCut","outgoing":a,"incoming":bb,"direction":"out","asLayer":true}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(layers(h.current()).len(), 1);
    // same track = hard cut: no fade
    let bc = h.current().timelines[0].tracks.iter().find_map(|t| t.clip(bb)).expect("b").clone();
    assert!(bc.animation.opacity.track.keys.is_empty());
    h.undo();
    assert!(layers(h.current()).is_empty());
    let _ = Id::from_u128(0);
}
