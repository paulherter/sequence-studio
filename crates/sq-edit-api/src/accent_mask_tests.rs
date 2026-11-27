//! `setTextAccent` and `addMask` end to end on the shared fixture: apply, read back, render / model check, undo, refusals.

use crate::clip_params::clip_params_json;
use crate::edit_operation::EditOperation;
use crate::edit_transaction::EditTransaction;
use crate::edit_transaction::fixture::Fixture;
use serde_json::{Value, json};
use sq_core_edit::history::History;
use sq_core_masks::ClipMasksExt;
use sq_core_model::{GraphicsContent, Project};
use sq_core_time::{Id, SequentialIds};
use sq_text::portable_text_renderer::PortableTextRenderer;
use sq_text::text_generator::TextGenerator;

fn commit(h: &mut History<Project>, f: &Fixture, v: Value) -> Result<(), crate::edit_transaction::TransactionError> {
    let list: Vec<EditOperation> = serde_json::from_value(v).unwrap_or_else(|e| panic!("ops: {e}"));
    h.try_commit("Agent: Test", |p| EditTransaction::apply(&list, p, f.seq, &mut SequentialIds::default()))
}

fn graphic(h: &History<Project>) -> Id {
    h.current().timelines[0].tracks[0].clips().iter().find(|c| c.is_graphics()).map_or(Id::NIL, |c| c.id)
}

fn clip_of(h: &History<Project>, id: Id) -> sq_core_model::Clip {
    h.current().timelines[0].tracks.iter().find_map(|tr| tr.clip(id)).cloned().unwrap_or_else(|| panic!("clip"))
}

#[test]
fn an_accent_word_renders_in_the_accent_color_and_undoes() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let t = |v: i64| json!({"value": v, "timescale": 1});
    commit(
        &mut h,
        &f,
        json!([{"op":"addGraphic","track":f.v1,"at":t(10),"duration":t(3),
        "layers":[{"text":"one two three","size":80,"color":"#ffffff"}]}]),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let gid = graphic(&h);
    let layer = clip_params_json(&clip_of(&h, gid))["layers"][0]["id"].as_str().unwrap_or("").to_string();
    let render = |h: &History<Project>| {
        let c = clip_of(h, gid);
        let GraphicsContent::Text { generator } =
            &c.graphics_store.as_ref().map_or_else(|| panic!("doc"), |d| d.layers[0].content.clone())
        else {
            panic!("text")
        };
        let (tpl, _) = TextGenerator::decode(generator).unwrap_or_else(|e| panic!("{e}"));
        let r = PortableTextRenderer::render(&tpl.text, &tpl.style, None, None, 1.0, tpl.highlight.as_ref())
            .unwrap_or_else(|| panic!("raster"));
        r.picture.pixels.chunks(4).filter(|p| p[3] > 0.9 && p[0] > 0.9 && p[1] > 0.8 && p[2] < 0.2).count()
    };
    assert_eq!(render(&h), 0, "no yellow before the accent");
    let depth = h.undo_depth();
    commit(&mut h, &f, json!([{"op":"setTextAccent","clip":gid,"layer":layer,"from":1,"color":"#FFEB00"}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(h.undo_depth(), depth + 1);
    assert!(render(&h) > 50, "the accent word has yellow pixels");
    let j = clip_params_json(&clip_of(&h, gid));
    assert_eq!(
        (j["layers"][0]["accent"]["from"].as_u64(), j["layers"][0]["accent"]["to"].as_u64()),
        (Some(1), Some(2))
    );
    commit(&mut h, &f, json!([{"op":"setTextAccent","clip":gid,"layer":layer,"clear":true}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(render(&h), 0);
    assert!(clip_params_json(&clip_of(&h, gid))["layers"][0].get("accent").is_none());
    h.undo();
    h.undo();
    assert_eq!(render(&h), 0);

    for bad in [
        json!({"op":"setTextAccent","clip":gid,"layer":layer,"from":1}),
        json!({"op":"setTextAccent","clip":gid,"layer":layer,"from":2,"to":2,"color":"#fff000"}),
        json!({"op":"setTextAccent","clip":gid,"layer":layer,"from":0,"color":"#fff000","size":3}),
    ] {
        assert!(serde_json::from_value::<Vec<EditOperation>>(json!([bad])).is_err());
    }
    assert!(
        commit(&mut h, &f, json!([{"op":"setTextAccent","clip":gid,"layer":layer,"from":3,"color":"#ffeb00"}]))
            .is_err()
    );
}

#[test]
fn an_ellipse_mask_with_feather_is_one_undo_step_and_reads_back() {
    let f = Fixture::new();
    let mut h = History::with_default_limit(f.project.clone());
    let depth = h.undo_depth();
    assert!(clip_of(&h, f.a).masks().is_empty());
    commit(&mut h, &f, json!([{"op":"addMask","clip":f.a,"shape":"ellipse","center":{"x":0.5,"y":0.4},"size":[0.4,0.6],"feather":60,"invert":true}]))
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(h.undo_depth(), depth + 1);
    let c = clip_of(&h, f.a);
    let m = &c.masks()[0];
    assert!(m.inverted && (m.feather.value - 60.0).abs() < 1e-9);
    let j = clip_params_json(&c)["masks"][0].clone();
    assert!((j["center"]["x"].as_f64().unwrap_or(0.0) - 0.5).abs() < 0.02, "{j}");
    assert!((j["center"]["y"].as_f64().unwrap_or(0.0) - 0.4).abs() < 0.02, "{j}");
    assert!((j["size"]["y"].as_f64().unwrap_or(0.0) - 0.6).abs() < 0.02, "{j}");
    commit(&mut h, &f, json!([{"op":"addMask","clip":f.a,"shape":"rectangle"}])).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(clip_of(&h, f.a).masks().len(), 2);
    h.undo();
    h.undo();
    assert!(clip_of(&h, f.a).masks().is_empty());
    for bad in [
        json!({"op":"addMask","clip":f.a}),
        json!({"op":"addMask","clip":f.a,"shape":"star"}),
        json!({"op":"addMask","clip":f.a,"shape":"ellipse","feather":-1}),
        json!({"op":"addMask","clip":f.a,"shape":"ellipse","size":[0,0.5]}),
        json!({"op":"addMask","clip":f.a,"shape":"ellipse","radius":1}),
    ] {
        assert!(serde_json::from_value::<Vec<EditOperation>>(json!([bad])).is_err());
    }
}
