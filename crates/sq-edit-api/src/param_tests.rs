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
    assert!(commit(&mut h, &f, json!([{"op":"setKeyframe","clip":a,"param":"audio.volumeDb","at":t(1,1),"value":99}])).is_err());
    assert!(commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":"motion.nope","value":1}])).is_err());

    // An audio effect from the Effects panel catalog, one parameter set.
    let spec = EffectCatalog::offered_audio(false)
        .into_iter()
        .find(|s| s.params.iter().any(|p| matches!(p.kind, EffectParamKind::Slider)))
        .unwrap_or_else(|| panic!("an audio effect with a slider"));
    let p = spec.params.iter().find(|p| matches!(p.kind, EffectParamKind::Slider)).unwrap_or_else(|| panic!("slider"));
    let target = (*p.range.start() + *p.range.end()) / 2.0;
    commit(&mut h, &f, json!([{"op":"addEffect","clip":a,"effect":spec.kind}])).unwrap_or_else(|e| panic!("{e}"));
    let eff = h.current().timelines[0].tracks[1].clip(a).and_then(|c| c.effects.first().map(|e| e.id)).unwrap_or(Id::NIL);
    let path = format!("effect.{eff}.{}", p.key);
    commit(&mut h, &f, json!([{"op":"setParam","clip":a,"param":path,"value":target}])).unwrap_or_else(|e| panic!("{e}"));
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
    let gid = h.current().timelines[0].tracks[0]
        .clips()
        .iter()
        .find(|c| c.is_graphics())
        .map(|c| c.id)
        .unwrap_or(Id::NIL);
    // ONE clip holding the three layers.
    assert_eq!(h.current().timelines[0].tracks[0].clips().len(), 3);
    let j = clip_json(&h, gid);
    let layers = j["layers"].as_array().cloned().unwrap_or_default();
    assert_eq!(layers.len(), 3);
    assert_eq!(layers.iter().map(|l| l["text"].as_str().unwrap_or("")).collect::<Vec<_>>(), ["Title", "Subtitle", "Footer"]);
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
    commit(&mut h, &f, json!([{"op":"addTextLayer","clip":gid,"text":"Extra","size":20}])).unwrap_or_else(|e| panic!("{e}"));
    let j = clip_json(&h, gid);
    assert_eq!(j["layers"].as_array().map(Vec::len), Some(4));
    assert_eq!(j["layers"][1]["text"], json!("Sub 2"));
    assert_eq!(j["layers"][1]["style"]["color"]["blue"], json!(1.0));
    assert_eq!(param(&j, &format!("layer.{l2}.text"))["value"], json!("Sub 2"));
    let extra = j["layers"][3]["id"].as_str().unwrap_or("").to_string();
    commit(&mut h, &f, json!([{"op":"removeTextLayer","clip":gid,"layer":extra}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_json(&h, gid)["layers"].as_array().map(Vec::len), Some(3));
    // The position key goes again.
    commit(&mut h, &f, json!([{"op":"removeKeyframe","clip":gid,"param":pos,"at":t(1,1)}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(param(&clip_json(&h, gid), &pos)["keyframes"].as_array().map(Vec::len), Some(1));

    // Refusals: unknown field, key outside the clip, text layer op on a video clip.
    assert!(serde_json::from_value::<Vec<EditOperation>>(json!([{"op":"addTextLayer","clip":gid,"text":"x","fnt":1}])).is_err());
    assert!(commit(&mut h, &f, json!([{"op":"setKeyframe","clip":gid,"param":pos,"at":t(99,1),"value":[0,0]}])).is_err());
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
