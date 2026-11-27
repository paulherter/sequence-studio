//! The parameter, effect and text-layer operations end to end on the shared fixture: set, read back, undo.

use crate::clip_params::clip_params_json;
use crate::edit_operation::EditOperation;
use crate::edit_transaction::fixture::Fixture;
use crate::edit_transaction::{EditTransaction, TransactionErrorKind};
use serde_json::{Value, json};
use sq_core_edit::history::History;
use sq_core_model::{EffectCatalog, EffectParamKind, Project};
use sq_core_time::{Id, SequentialIds};

fn ops(v: Value) -> Vec<EditOperation> {
    serde_json::from_value(v).unwrap_or_else(|e| panic!("ops: {e}"))
}

fn t(value: i64, timescale: i64) -> Value {
    json!({"value": value, "timescale": timescale})
}

/// One commit as the host does it: one undo step on a History.
fn commit(h: &mut History<Project>, f: &Fixture, v: Value) -> Result<(), crate::edit_transaction::TransactionError> {
    let list = ops(v);
    h.try_commit("Agent: Test", |p| EditTransaction::apply(&list, p, f.seq, &mut SequentialIds::default()))
}

fn clip_json(h: &History<Project>, id: Id) -> Value {
    let p = h.current();
    let c = p.timelines[0].tracks.iter().find_map(|tr| tr.clip(id)).unwrap_or_else(|| panic!("clip"));
    clip_params_json(c)
}

fn param<'a>(j: &'a Value, path: &str) -> &'a Value {
    j["params"].as_array().and_then(|a| a.iter().find(|p| p["path"] == path)).unwrap_or_else(|| panic!("param {path}"))
}

#[test]
fn volume_with_two_keys_an_audio_effect_and_its_param_read_back_and_undo() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let a = f.a_audio;
    // The list names the audio parameters and no picture ones.
    let before = clip_json(&h, a);
    assert!(param(&before, "audio.volumeDb")["value"].as_f64().is_some_and(|v| v.abs() < 1e-9));
    assert!(before["params"].as_array().is_some_and(|l| !l.iter().any(|p| p["path"] == "opacity")));

    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(0,1),"value":0},
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(2,1),"value":-6,"interpolation":"bezier"},
            {"op":"setParam","clip":a,"param":"audio.gainDb","value":3}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, a);
    let vol = param(&j, "audio.volumeDb");
    let keys = vol["keyframes"].as_array().cloned().unwrap_or_default();
    assert_eq!(keys.len(), 2);
    assert!((keys[1]["value"].as_f64().unwrap_or(9.0) + 6.0).abs() < 1e-6, "{keys:?}");
    assert_eq!((keys[1]["interpolation"].as_str(), keys[1]["at"]["value"].as_i64()), (Some("bezier"), Some(2)));
    assert_eq!(param(&j, "audio.gainDb")["value"].as_f64(), Some(3.0));
    // The model holds the linear gain the inspector uses.
    let stored = h.current().timelines[0].tracks[1].clip(a).map(|c| c.animation.volume.track.keys[1].value);
    assert!(stored.is_some_and(|v| (v - 10f64.powf(-6.0 / 20.0)).abs() < 1e-9));
    // A static set on a keyed parameter is refused, with the reason, and nothing changes.
    let depth = h.undo_depth();
    let e = commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":"audio.volumeDb","value":-3}])).err();
    assert!(e.as_ref().is_some_and(|e| e.kind == TransactionErrorKind::Invalid && e.message().contains("keyframes")));
    assert_eq!(h.undo_depth(), depth);
    // Out of range and unknown paths are refused too.
    assert!(
        commit(&mut h, &f, json!([{"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(1,1),"value":99}]))
            .is_err()
    );
    assert!(commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":"motion.nope","value":1}])).is_err());

    // An audio effect from the Effects panel catalog, one parameter set.
    let spec = EffectCatalog::offered_audio(false)
        .into_iter()
        .find(|s| s.params.iter().any(|p| matches!(p.kind, EffectParamKind::Slider)))
        .unwrap_or_else(|| panic!("an audio effect with a slider"));
    let p = spec.params.iter().find(|p| matches!(p.kind, EffectParamKind::Slider)).unwrap_or_else(|| panic!("slider"));
    let target = (*p.range.start() + *p.range.end()) / 2.0;
    commit(&mut h, &f, json!([{"op":"addEffect","clip":a,"effect":spec.kind}])).unwrap_or_else(|e| panic!("{e}"));
    let eff =
        h.current().timelines[0].tracks[1].clip(a).and_then(|c| c.effects.first().map(|e| e.id)).unwrap_or(Id::NIL);
    let path = format!("effect.{eff}.{}", p.key);
    commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":path,"value":target}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, a);
    assert_eq!(j["effects"][0]["kind"], json!(spec.kind));
    assert!(param(&j, &path)["value"].as_f64().is_some_and(|v| (v - target).abs() < 1e-9));
    // A video effect on an audio clip is refused.
    assert!(commit(&mut h, &f, json!([{"op":"addEffect","clip":a,"effect":"gaussianBlur"}])).is_err());

    // Undo walks back step by step to the original project.
    while h.undo_depth() > 0 {
        assert!(h.undo());
    }
    assert_eq!(h.current(), &f.project);
}

#[test]
fn a_graphic_with_three_text_layers_one_animated_layer_and_undo() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(
        &mut h,
        &f,
        json!([{"op":"addGraphic","track":f.v1,"at":t(10,1),"duration":t(3,1),"name":"Lower third","layers":[
            {"text":"Title","font":"Helvetica-Bold","size":96,"color":"#ff0000","weight":"bold","align":"left","position":{"x":-200,"y":40}},
            {"text":"Subtitle","size":48,"color":[0,1,0,1],"position":[0,-40],"opacity":0.8},
            {"text":"Footer","size":32}
        ]}]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let gid =
        h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map(|c| c.id).unwrap_or(Id::NIL);
    // ONE clip holding the three layers.
    assert_eq!(h.current().timelines[0].tracks[0].clips().len(), 3);
    let j = clip_json(&h, gid);
    let layers = j["layers"].as_array().cloned().unwrap_or_default();
    assert_eq!(layers.len(), 3);
    assert_eq!(
        layers.iter().map(|l| l["text"].as_str().unwrap_or("")).collect::<Vec<_>>(),
        ["Title", "Subtitle", "Footer"]
    );
    assert_eq!(layers[0]["style"]["size"], json!(96.0));
    assert_eq!(layers[0]["style"]["weight"], json!(700));
    assert_eq!(layers[0]["style"]["alignment"], json!("left"));
    assert_eq!(layers[0]["style"]["color"]["red"], json!(1.0));
    let l2 = layers[1]["id"].as_str().unwrap_or("").to_string();
    assert_eq!(param(&j, &format!("layer.{l2}.opacity"))["value"], json!(0.8));

    // Animate layer 2's position with two keys.
    let pos = format!("layer.{l2}.motion.position");
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":gid,"param":pos,"at":t(0,1),"value":{"x":-300,"y":0}},
            {"op":"setKeyframe","clip":gid,"param":pos,"at":t(1,1),"value":{"x":300,"y":0},"interpolation":"bezier"}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, gid);
    let p = param(&j, &pos);
    assert_eq!((p["animated"].as_bool(), p["keyframes"].as_array().map(Vec::len)), (Some(true), Some(2)));
    assert_eq!(p["keyframes"][1]["value"], json!({"x": 300.0, "y": 0.0}));
    let other = layers[0]["id"].as_str().unwrap_or("");
    assert_eq!(param(&j, &format!("layer.{other}.motion.position"))["animated"], json!(false));

    // Edit, add and remove layers.
    commit(&mut h, &f, json!([{"op":"setTextLayer","clip":gid,"layer":l2,"text":"Sub 2","color":"#0000ff"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    commit(&mut h, &f, json!([{"op":"addTextLayer","clip":gid,"text":"Extra","size":20}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, gid);
    assert_eq!(j["layers"].as_array().map(Vec::len), Some(4));
    assert_eq!(j["layers"][1]["text"], json!("Sub 2"));
    assert_eq!(j["layers"][1]["style"]["color"]["blue"], json!(1.0));
    assert_eq!(param(&j, &format!("layer.{l2}.text"))["value"], json!("Sub 2"));
    let extra = j["layers"][3]["id"].as_str().unwrap_or("").to_string();
    commit(&mut h, &f, json!([{"op":"removeTextLayer","clip":gid,"layer":extra}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_json(&h, gid)["layers"].as_array().map(Vec::len), Some(3));
    // The position key goes again.
    commit(&mut h, &f, json!([{"op":"removeKeyframe","clip":gid,"param":pos,"at":t(1,1)}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(param(&clip_json(&h, gid), &pos)["keyframes"].as_array().map(Vec::len), Some(1));

    // Refusals: unknown field, key outside the clip, text layer op on a video clip.
    assert!(
        serde_json::from_value::<Vec<EditOperation>>(json!([{"op":"addTextLayer","clip":gid,"text":"x","fnt":1}]))
            .is_err()
    );
    assert!(
        commit(&mut h, &f, json!([{"op":"setKeyframe","clip":gid,"param":pos,"at":t(99,1),"value":[0,0]}])).is_err()
    );
    assert!(commit(&mut h, &f, json!([{"op":"addTextLayer","clip":f.a,"text":"x"}])).is_err());

    while h.undo_depth() > 0 {
        assert!(h.undo());
    }
    assert_eq!(h.current(), &f.project);
}

#[test]
fn motion_opacity_and_a_video_effect_on_a_picture_clip() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setParam","clip":f.a,"param":"motion.scale","value":1.5},
            {"op":"setParam","clip":f.a,"param":"motion.position","value":{"x":10,"y":-20}},
            {"op":"setParam","clip":f.a,"param":"opacity","value":0.5},
            {"op":"addEffect","clip":f.a,"effect":"gaussianBlur"}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, f.a);
    assert_eq!(param(&j, "motion.scale")["value"], json!({"x": 1.5, "y": 1.5}));
    assert_eq!(param(&j, "motion.position")["value"], json!({"x": 10.0, "y": -20.0}));
    assert_eq!(param(&j, "opacity")["value"], json!(0.5));
    let eff = j["effects"][0]["id"].as_str().unwrap_or("").to_string();
    assert!(param(&j, &format!("effect.{eff}.blurriness"))["value"].as_f64().is_some());
    assert!(commit(&mut h, &f, json!([{"op":"setParam","clip":f.a,"param":"opacity","value":2}])).is_err());
    commit(&mut h, &f, json!([{"op":"removeEffect","clip":f.a,"effect":eff}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_json(&h, f.a)["effects"].as_array().map(Vec::len), Some(0));
}

#[test]
fn text_animators_on_two_layers_read_back_change_remove_and_undo() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(
        &mut h,
        &f,
        json!([{"op":"addGraphic","track":f.v1,"at":t(10,1),"duration":t(3,1),"layers":[{"text":"Line one"},{"text":"Line two"}]}]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let gid =
        h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map(|c| c.id).unwrap_or(Id::NIL);
    let layers = clip_json(&h, gid)["layers"].as_array().cloned().unwrap_or_default();
    let (l1, l2) =
        (layers[0]["id"].as_str().unwrap_or("").to_string(), layers[1]["id"].as_str().unwrap_or("").to_string());
    assert_eq!(layers[0]["animators"], json!({}));
    let depth = h.undo_depth();

    commit(
        &mut h,
        &f,
        json!([
            {"op":"addTextAnimator","clip":gid,"layer":l1,"effect":"slide","unit":"word","direction":"left","distance":120,"stagger":150},
            {"op":"addTextAnimator","clip":gid,"layer":l2,"effect":"pop","unit":"line"},
            {"op":"addTextAnimator","clip":gid,"layer":l2,"side":"out","effect":"fade","duration":500}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, gid);
    let a1 = &j["layers"][0]["animators"]["in"];
    assert_eq!(
        (a1["effect"].as_str(), a1["unit"].as_str(), a1["direction"].as_str()),
        (Some("slide"), Some("word"), Some("left"))
    );
    assert_eq!(
        (a1["distance"].as_f64(), a1["stagger"].as_f64(), a1["duration"].as_f64()),
        (Some(120.0), Some(150.0), Some(300.0))
    );
    let a2 = &j["layers"][1]["animators"];
    // The panel's rules: pop eases with the overshoot, a line's untouched stagger is the line default (150 ms).
    assert_eq!(
        (a2["in"]["effect"].as_str(), a2["in"]["easing"].as_str(), a2["in"]["stagger"].as_f64()),
        (Some("pop"), Some("overshoot"), Some(150.0))
    );
    assert_eq!((a2["out"]["effect"].as_str(), a2["out"]["duration"].as_f64()), (Some("fade"), Some(500.0)));
    assert_eq!(param(&j, &format!("layer.{l1}.animator.in"))["value"]["effect"], json!("slide"));

    // Change a field; the rest stays.
    commit(&mut h, &f, json!([{"op":"setTextAnimator","clip":gid,"layer":l1,"unit":"character","order":"reverse"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let a1 = clip_json(&h, gid)["layers"][0]["animators"]["in"].clone();
    assert_eq!(
        (a1["unit"].as_str(), a1["order"].as_str(), a1["effect"].as_str(), a1["stagger"].as_f64()),
        (Some("character"), Some("reverse"), Some("slide"), Some(150.0))
    );

    commit(&mut h, &f, json!([{"op":"removeTextAnimator","clip":gid,"layer":l2,"side":"out"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let a2 = clip_json(&h, gid)["layers"][1]["animators"].clone();
    assert!(a2.get("out").is_none() && a2.get("in").is_some());

    // Refusals: unknown key, unknown effect, no effect on add, second add on a side, set without animator, shape layer.
    for bad in [
        json!({"op":"addTextAnimator","clip":gid,"layer":l1,"effect":"fade","speed":1}),
        json!({"op":"addTextAnimator","clip":gid,"layer":l1,"effect":"spin"}),
        json!({"op":"addTextAnimator","clip":gid,"layer":l1}),
        json!({"op":"addTextAnimator","clip":gid,"layer":l1,"effect":"fade","duration":-5}),
        json!({"op":"removeTextAnimator","clip":gid,"layer":l1,"side":"middle"}),
    ] {
        assert!(serde_json::from_value::<Vec<EditOperation>>(json!([bad])).is_err());
    }
    assert!(commit(&mut h, &f, json!([{"op":"addTextAnimator","clip":gid,"layer":l1,"effect":"fade"}])).is_err());
    assert!(
        commit(&mut h, &f, json!([{"op":"setTextAnimator","clip":gid,"layer":l1,"side":"out","effect":"fade"}]))
            .is_err()
    );
    assert!(commit(&mut h, &f, json!([{"op":"removeTextAnimator","clip":gid,"layer":l1,"side":"out"}])).is_err());

    while h.undo_depth() > depth {
        assert!(h.undo());
    }
    assert_eq!(clip_json(&h, gid)["layers"][0]["animators"], json!({}));
    while h.undo_depth() > 0 {
        assert!(h.undo());
    }
    assert_eq!(h.current(), &f.project);
}

#[test]
fn text_tracking_is_keyable_with_ease_reads_back_and_undoes() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(&mut h, &f, json!([{"op":"addGraphic","track":f.v1,"at":t(10,1),"duration":t(3,1),"layers":[{"text":"Title","tracking":2}]}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let gid =
        h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map(|c| c.id).unwrap_or(Id::NIL);
    let l = clip_json(&h, gid)["layers"][0]["id"].as_str().unwrap_or("").to_string();
    let path = format!("layer.{l}.tracking");
    assert_eq!(param(&clip_json(&h, gid), &path)["value"], json!(2.0));
    let depth = h.undo_depth();

    // Wide to tight over 8 frames (30 fps) with the shared ease shortcut.
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":gid,"param":path,"at":t(0,1),"value":40,"ease":"easeOut"},
            {"op":"setKeyframe","clip":gid,"param":path,"at":t(8,30),"value":2,"ease":"easeOut"}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(h.undo_depth(), depth + 1);
    let j = clip_json(&h, gid);
    let p = param(&j, &path);
    assert_eq!(p["animated"], json!(true));
    let keys = p["keyframes"].as_array().cloned().unwrap_or_default();
    assert_eq!((keys.len(), keys[0]["value"].as_f64(), keys[1]["value"].as_f64()), (2, Some(40.0), Some(2.0)));
    assert_eq!(keys[0]["interpolation"].as_str(), Some("bezier"));
    assert!(keys[0]["outHandle"]["influence"].as_f64().is_some());
    // The static value is refused while keyed; out-of-range refused.
    assert!(commit(&mut h, &f, json!([{"op":"setParam","clip":gid,"param":path,"value":5}])).is_err());
    assert!(commit(&mut h, &f, json!([{"op":"setKeyframe","clip":gid,"param":path,"at":t(0,1),"value":999}])).is_err());

    // Removing both keys leaves the static style tracking.
    commit(&mut h, &f, json!([{"op":"removeKeyframe","clip":gid,"param":path,"at":t(0,1)},{"op":"removeKeyframe","clip":gid,"param":path,"at":t(8,30)}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(param(&clip_json(&h, gid), &path)["animated"], json!(false));
    commit(&mut h, &f, json!([{"op":"setParam","clip":gid,"param":path,"value":6}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(param(&clip_json(&h, gid), &path)["value"], json!(6.0));
}

#[test]
fn ease_in_pair_stays_below_linear_speeds_up_and_reads_back_its_handles() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let a = f.a_audio;
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(0,1),"value":-60,"ease":"easeIn"},
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(2,1),"value":0,"ease":"easeIn"}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let track = h.current().timelines[0].tracks[1].clip(a).map(|c| c.animation.volume.track.clone());
    let track = track.unwrap_or_else(|| panic!("clip"));
    let at = |n: i64| track.value(sq_core_time::Time::new(n, 4)).unwrap_or(f64::NAN);
    let (lo, hi) = (track.keys[0].value, track.keys[1].value);
    let lin = |p: f64| lo + (hi - lo) * p;
    let (v25, v50, v75) = (at(2), at(4), at(6));
    assert!(v25 < lin(0.25) - 1e-6 && v50 < lin(0.5) - 1e-6 && v75 < lin(0.75) - 1e-6, "{v25} {v50} {v75}");
    // Speed grows: each quarter climbs more than the one before.
    assert!(v50 - v25 < v75 - v50 && v75 - v50 < hi - v75, "{v25} {v50} {v75}");
    // The handles read back: 100 % influence on the outgoing side, flat.
    let j = clip_json(&h, a);
    let keys = param(&j, "audio.volumeDb")["keyframes"].clone();
    assert_eq!(keys[0]["outHandle"]["influence"].as_f64(), Some(100.0));
    assert_eq!(keys[0]["outHandle"]["dy"].as_f64(), Some(0.0));
    assert_eq!(keys[0]["interpolation"], "bezier");
}

#[test]
fn explicit_handles_use_influence_percent_and_the_importers_speed_formula() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let a = f.a_audio;
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(2,1),"value":0},
            {"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(0,1),"value":-60,
             "outHandle":{"influence":50,"speed":0.1}, "inHandle":{"influence":20}}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let keys =
        h.current().timelines[0].tracks[1].clip(a).map(|c| c.animation.volume.track.keys.clone()).unwrap_or_default();
    assert!((keys[0].out_handle.dx - 0.5).abs() < 1e-9 && (keys[0].in_handle.dx - 0.2).abs() < 1e-9);
    let expect = sq_core_time::EaseHandle::from_speed(0.1, 0.5, 2.0, keys[1].value - keys[0].value);
    assert!((keys[0].out_handle.dy - expect.dy).abs() < 1e-12);
    // Speed with no neighbor, a bad influence and both forms together are refused.
    for bad in [
        json!({"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(1,1),"value":0,"inHandle":{"influence":101}}),
        json!({"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(1,1),"value":0,"ease":"easeIn","outHandle":{"influence":5}}),
        json!({"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(1,1),"value":0,"ease":"bounce"}),
    ] {
        assert!(serde_json::from_value::<EditOperation>(bad).is_err());
    }
}

#[test]
fn transitions_are_added_between_clips_on_an_edge_and_removed_and_presets_apply() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let (a, b) = (f.a, f.b);
    commit(
        &mut h,
        &f,
        json!([
            {"op":"addTransition","between":[a, b],"kind":"crossDissolve","duration":t(1,1)},
            {"op":"addTransition","clip":b,"edge":"tail","kind":"zoom","duration":t(1,2)},
            {"op":"applyPreset","clip":a,"preset":"Punch-In"}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let tl = &h.current().timelines[0];
    let kinds: Vec<_> = tl.tracks[0].transitions.iter().map(|x| x.kind).collect();
    assert!(kinds.contains(&sq_core_model::TransitionKind::CrossDissolve), "{kinds:?}");
    assert!(kinds.contains(&sq_core_model::TransitionKind::Zoom), "{kinds:?}");
    let a_effects = tl.tracks[0].clip(a).map_or(0, |c| c.effects.len());
    assert!(a_effects > 0, "the preset added its effects");
    let id = tl.tracks[0].transitions.iter().find(|x| x.kind == sq_core_model::TransitionKind::Zoom).map(|x| x.id);
    commit(&mut h, &f, json!([{"op":"removeTransition","transition":id}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(h.current().timelines[0].tracks[0].transitions.len(), 1);
    // Both places at once, an unknown kind and a preset at the wrong edge are refused.
    for bad in [
        json!({"op":"addTransition","clip":a,"edge":"head","between":[a,b],"kind":"crossDissolve","duration":t(1,1)}),
        json!({"op":"addTransition","clip":a,"edge":"head","kind":"nope","duration":t(1,1)}),
    ] {
        assert!(serde_json::from_value::<EditOperation>(bad).is_err());
    }
    assert!(commit(&mut h, &f, json!([{"op":"applyPreset","clip":a,"preset":"Punch-In","at":"tail"}])).is_err());
    assert_eq!(
        crate::transition_ops::transitions_json()["transitions"]
            .as_array()
            .map(|l| l.iter().any(|k| k["kind"] == "zoomIn")),
        Some(true)
    );
    let listed = crate::transition_ops::presets_json(&[])["presets"].as_array().cloned().unwrap_or_default();
    assert!(listed.iter().any(|k| k["track"] == "video" && k["at"] == "head"), "{listed:?}");
    for (id, at) in [("tailZoom", "tail"), ("headZoom", "head"), ("overlayPop", "head"), ("talkPulse", "head")] {
        assert!(listed.iter().any(|k| k["preset"] == id && k["at"] == at), "{id} listed: {listed:?}");
        commit(&mut h, &f, json!([{"op":"applyPreset","clip":a,"preset":id}])).unwrap_or_else(|e| panic!("{id}: {e}"));
    }
}

#[test]
fn shutter_angle_set_through_the_api_opens_the_motion_blur_samples_a_fast_scale_key_needs() {
    use sq_core_effects::effect_transform_stage::ClipStageEval;
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let a = f.a;
    let blur = |h: &History<Project>| {
        let p = h.current();
        let c = p.timelines[0].tracks[0].clip(a).unwrap_or_else(|| panic!("clip"));
        c.motion_blur(sq_core_time::Time::new(1, 1), p.timelines[0].format.frame_duration, &p.timelines[0].format, 1.0)
    };
    let steps = json!([
        {"op":"setKeyframe","clip":a,"param":"motion.scale","at":t(0,1),"value":{"x":3,"y":3}},
        {"op":"setKeyframe","clip":a,"param":"motion.scale","at":t(2,1),"value":{"x":1,"y":1}}
    ]);
    commit(&mut h, &f, steps).unwrap_or_else(|e| panic!("{e}"));
    assert!(blur(&h).is_none(), "shutter 0: sharp");
    commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":"motion.shutterAngle","value":180}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let mb = blur(&h).unwrap_or_else(|| panic!("shutter 180 must sample"));
    assert!(mb.transforms.first().map(|x| x.scale.x) > mb.transforms.last().map(|x| x.scale.x));
}

#[test]
fn text_animator_overshoot_reads_back_and_is_validated() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(
        &mut h,
        &f,
        json!([{"op":"addGraphic","track":f.v1,"at":t(10,1),"duration":t(3,1),"layers":[{"text":"Pop"}]}]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let gid =
        h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map(|c| c.id).unwrap_or(Id::NIL);
    let l = clip_json(&h, gid)["layers"][0]["id"].as_str().unwrap_or("").to_string();
    commit(&mut h, &f, json!([{"op":"addTextAnimator","clip":gid,"layer":l,"effect":"pop","overshoot":1.08}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_json(&h, gid)["layers"][0]["animators"]["in"]["overshoot"], json!(1.08));
    commit(&mut h, &f, json!([{"op":"setTextAnimator","clip":gid,"layer":l,"overshoot":null}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_json(&h, gid)["layers"][0]["animators"]["in"]["overshoot"], Value::Null);
    for bad in [json!(0.5), json!(4), json!("big")] {
        assert!(
            serde_json::from_value::<Vec<EditOperation>>(
                json!([{"op":"setTextAnimator","clip":gid,"layer":l,"overshoot":bad}])
            )
            .is_err()
        );
    }
}

#[test]
fn a_text_layer_background_can_follow_the_reveal_through_style() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let style = json!({"background": {"color": {"red": 1.0, "green": 0.2, "blue": 0.2, "alpha": 1.0},
        "padding": {"horizontal": 30, "vertical": 14}, "cornerRadius": 35, "followReveal": true}});
    commit(&mut h, &f, json!([{"op":"addGraphic","track":f.v1,"at":t(10,1),"duration":t(3,1),"layers":[{"text":"Pill","style":style}]}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let gid =
        h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map(|c| c.id).unwrap_or(Id::NIL);
    let bg = clip_json(&h, gid)["layers"][0]["style"]["background"].clone();
    assert_eq!((bg["followReveal"].as_bool(), bg["cornerRadius"].as_f64()), (Some(true), Some(35.0)));
}

#[test]
fn transitions_are_read_back_in_state_and_diff() {
    use crate::{edit_diff::EditDiff, project_state::SequenceState};
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let before = h.current().timelines[0].clone();
    assert!(SequenceState::new(&before).transitions.is_empty());
    commit(&mut h, &f, json!([{"op":"addTransition","between":[f.a, f.b],"kind":"crossDissolve","duration":t(1,1)}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let added = h.current().timelines[0].clone();
    let d = EditDiff::new(&before, &added);
    assert!(!d.is_empty() && d.transitions_removed.is_empty());
    let x = &d.transitions_added[0];
    assert_eq!((x.kind.as_str(), x.outgoing, x.incoming), ("crossDissolve", Some(f.a), Some(f.b)));
    assert_eq!(SequenceState::new(&added).transitions, d.transitions_added);
    let id = x.id;
    commit(&mut h, &f, json!([{"op":"removeTransition","transition":id}])).unwrap_or_else(|e| panic!("{e}"));
    let gone = EditDiff::new(&added, &h.current().timelines[0]);
    assert_eq!(
        (gone.transitions_removed.len(), gone.transitions_removed[0].id, gone.transitions_added.len()),
        (1, id, 0)
    );
}

fn keys_of(h: &History<Project>, clip: Id, path: &str) -> Vec<(i64, f64, String)> {
    let j = clip_json(h, clip);
    param(&j, path)["keyframes"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|k| {
                    let at = k["at"]["value"].as_f64().unwrap_or(0.0) / k["at"]["timescale"].as_f64().unwrap_or(1.0);
                    ((at * 1000.0).round() as i64, k["value"].as_f64().unwrap_or(f64::NAN), k["outHandle"].to_string())
                })
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn effect_param_keys_remove_move_and_shift_keep_value_and_ease_and_undo_in_one_step() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    commit(&mut h, &f, json!([{"op":"addEffect","clip":f.a,"effect":"gaussianBlur"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    let eff = clip_json(&h, f.a)["effects"][0]["id"].as_str().unwrap_or("").to_string();
    let path = format!("effect.{eff}.blurriness");
    let opacity = "opacity";
    commit(
        &mut h,
        &f,
        json!([
            {"op":"setKeyframe","clip":f.a,"param":path,"at":t(0,1),"value":0},
            {"op":"setKeyframe","clip":f.a,"param":path,"at":t(1,2),"value":10,"interpolation":"bezier","outHandle":{"influence":60}},
            {"op":"setKeyframe","clip":f.a,"param":path,"at":t(1,1),"value":20},
            {"op":"setKeyframe","clip":f.a,"param":opacity,"at":t(1,4),"value":0.5}
        ]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let before = keys_of(&h, f.a, &path);
    assert_eq!(before.len(), 3);

    // move: value and handles stay; bare seconds work; a key at the target refuses and changes nothing.
    let depth = h.undo_depth();
    commit(&mut h, &f, json!([{"op":"moveKeyframe","clip":f.a,"param":path,"from":0.5,"to":0.75}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(h.undo_depth(), depth + 1);
    let moved = keys_of(&h, f.a, &path);
    assert_eq!((moved[1].0, moved[1].1, &moved[1].2), (750, 10.0, &before[1].2));
    let e = commit(&mut h, &f, json!([{"op":"moveKeyframe","clip":f.a,"param":path,"from":0.75,"to":1}])).err();
    assert!(e.is_some_and(|e| e.message().contains("already")));
    assert!(commit(&mut h, &f, json!([{"op":"moveKeyframe","clip":f.a,"param":path,"from":0.3,"to":0.4}])).is_err());
    assert_eq!(h.undo_depth(), depth + 1);

    // shift: only the keys at or after `after`; the whole move is refused when one would land on a stay key.
    commit(&mut h, &f, json!([{"op":"shiftKeyframes","clip":f.a,"param":path,"by":-0.25,"after":0.75}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys_of(&h, f.a, &path).iter().map(|k| k.0).collect::<Vec<_>>(), vec![0, 500, 750]);
    assert!(
        commit(&mut h, &f, json!([{"op":"shiftKeyframes","clip":f.a,"param":path,"by":-0.5,"after":0.5}])).is_err()
    );
    // no param: every keyed param shifts, the opacity key too.
    commit(&mut h, &f, json!([{"op":"shiftKeyframes","clip":f.a,"by":{"value":1,"timescale":10}}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys_of(&h, f.a, &path).iter().map(|k| k.0).collect::<Vec<_>>(), vec![100, 600, 850]);
    assert_eq!(keys_of(&h, f.a, opacity)[0].0, 350);
    // out of the clip is refused.
    assert!(commit(&mut h, &f, json!([{"op":"shiftKeyframes","clip":f.a,"by":1000}])).is_err());

    // remove on an effect param, until it is static again.
    commit(&mut h, &f, json!([{"op":"removeKeyframe","clip":f.a,"param":path,"at":0.6}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(keys_of(&h, f.a, &path).len(), 2);
    commit(&mut h, &f, json!([{"op":"removeKeyframe","clip":f.a,"param":path,"at":0.1},{"op":"removeKeyframe","clip":f.a,"param":path,"at":0.85}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(param(&clip_json(&h, f.a), &path)["animated"], json!(false));
}

fn user_preset(id: &str, name: &str, built_in: &str) -> crate::transition_ops::UserEffectPreset {
    let p = sq_core_effects::effect_stack_preset::EffectStackPresets::preset(built_in)
        .unwrap_or_else(|| panic!("built-in"));
    crate::transition_ops::UserEffectPreset { id: id.into(), name: name.into(), preset: p.preset() }
}

fn commit_user(
    h: &mut History<Project>,
    f: &Fixture,
    v: Value,
    user: &[crate::transition_ops::UserEffectPreset],
) -> Result<(), String> {
    let list = crate::transition_ops::resolve_user_presets(ops(v), user)?;
    h.try_commit("Agent: Test", |p| EditTransaction::apply(&list, p, f.seq, &mut SequentialIds::default()))
        .map_err(|e| e.message())
}

#[test]
fn a_user_preset_applies_like_the_same_built_in_one_by_name_or_id_and_keeps_its_anchor() {
    let f = Fixture::new();
    let user = [user_preset("2DA03180-B3FA-4475-A816-D34ACF869945", "Zoom Out & In / BOT", "tailZoom")];
    let clip_of = |h: &History<Project>| h.current().timelines[0].tracks[0].clip(f.a).cloned();
    let mut built_in = History::with_default_limit(f.project.clone());
    commit(&mut built_in, &f, json!([{"op":"applyPreset","clip":f.a,"preset":"tailZoom"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    for name in ["Zoom Out & In / BOT", "zoom out & in / bot", "2da03180-b3fa-4475-a816-d34acf869945"] {
        let mut h = History::with_default_limit(f.project.clone());
        commit_user(&mut h, &f, json!([{"op":"applyPreset","clip":f.a,"preset":name}]), &user)
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(clip_of(&h), clip_of(&built_in), "{name}");
        assert_ne!(clip_of(&h), f.project.timelines[0].tracks[0].clip(f.a).cloned(), "the clip changed");
    }
    // Its own anchor (the tail) is enforced like the panel's: `at: head` is refused, `at: tail` accepted.
    let mut h = History::with_default_limit(f.project.clone());
    assert!(
        commit_user(
            &mut h,
            &f,
            json!([{"op":"applyPreset","clip":f.a,"preset":"Zoom Out & In / BOT","at":"head"}]),
            &user
        )
        .is_err()
    );
    commit_user(&mut h, &f, json!([{"op":"applyPreset","clip":f.a,"preset":"Zoom Out & In / BOT","at":"tail"}]), &user)
        .unwrap_or_else(|e| panic!("{e}"));
    // A built-in id wins; two user presets with one name are ambiguous but each id works; unknown stays unknown.
    let twins = [user_preset("A", "Twin", "tailZoom"), user_preset("B", "Twin", "headZoom")];
    assert!(
        commit_user(&mut h, &f, json!([{"op":"applyPreset","clip":f.a,"preset":"Twin"}]), &twins)
            .unwrap_err()
            .contains("several")
    );
    commit_user(&mut h, &f, json!([{"op":"applyPreset","clip":f.a,"preset":"B"}]), &twins)
        .unwrap_or_else(|e| panic!("{e}"));
    let err = commit_user(&mut h, &f, json!([{"op":"applyPreset","clip":f.a,"preset":"Nope"}]), &user).unwrap_err();
    assert!(err.contains("unknown"), "{err}");
}

#[test]
fn the_preset_list_marks_user_presets() {
    let user = [user_preset("2DA03180", "Zoom In & Out / TOP", "headZoom")];
    let listed = crate::transition_ops::presets_json(&user)["presets"].as_array().cloned().unwrap_or_default();
    let mine = listed.iter().find(|k| k["user"] == true).unwrap_or_else(|| panic!("{listed:?}"));
    assert_eq!(
        (mine["name"].as_str(), mine["preset"].as_str(), mine["kind"].as_str()),
        (Some("Zoom In & Out / TOP"), Some("2DA03180"), Some("effect"))
    );
    assert!(mine["anchor"].is_string() && mine["at"].is_string() && mine["track"] == "video", "{mine}");
    assert!(listed.iter().filter(|k| k["user"] == true).count() == 1);
}
