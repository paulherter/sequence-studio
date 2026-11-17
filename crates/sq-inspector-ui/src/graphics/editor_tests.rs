// Scenario tests of `GraphicsEditor` (the Swift editor is covered by app-shell scenario tests).
use std::collections::BTreeSet;

use sq_core_graphics::graphics_editing::GraphicsReorder;
use sq_core_model::{ClipEffect, Project, SequenceFormat, ShapeKind, Timeline, Track, TrackKind, TransitionKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, Vec2};
use sq_editor_session::{EditorSession, EffectDragPayload, SessionDeps};

use crate::graphics::editor::{EffectDrop, GraphicsEditor, LayerDrop, TypeToolOutcome};

pub(super) fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let tracks = vec![Track::new(ids.next_id(), TrackKind::Video), Track::new(ids.next_id(), TrackKind::Audio)];
    let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 30)), tracks);
    let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let dir = std::env::temp_dir().join(format!("sq-inspector-ui-graphics-{}", std::process::id()));
    let mut deps = SessionDeps::headless(dir);
    deps.ids = Box::new(SequentialIds::default());
    EditorSession::new(project, deps)
}

pub(super) fn editor() -> GraphicsEditor {
    GraphicsEditor::new(Box::new(SequentialIds::default()))
}

fn layer_names(e: &GraphicsEditor, s: &EditorSession) -> Vec<String> {
    e.document(s).map(|d| d.layers.iter().map(|l| l.name.clone()).collect()).unwrap_or_default()
}

pub(super) fn with_three_shapes() -> (EditorSession, GraphicsEditor) {
    let mut s = session();
    let mut e = editor();
    assert!(e.new_graphics_clip(&mut s).is_some());
    for k in [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line] {
        e.add_shape(&mut s, k);
    }
    (s, e)
}

#[test]
fn a_new_graphic_is_selected_and_shapes_stack_up_selected() {
    let (s, e) = with_three_shapes();
    assert!(e.clip(&s).is_some());
    assert_eq!(e.document(&s).map(|d| d.layers.len()), Some(3));
    assert_eq!(e.selected_layers(&s).len(), 1);
    let top = e.document(&s).and_then(|d| d.layers.last()).map(|l| l.id);
    assert_eq!(e.selected_layers(&s).iter().next().copied(), top);
    assert_eq!(s.graphic_layer_selection().map(|g| g.layers.len()), Some(1));
}

#[test]
fn selection_keeps_only_existing_layers_and_clears_with_the_clip() {
    let (mut s, mut e) = with_three_shapes();
    e.select_all_layers(&mut s);
    assert_eq!(e.selected_layers(&s).len(), 3);
    e.select(&mut s, BTreeSet::from([Id::fixed(9999)]));
    assert!(e.selected_layers(&s).is_empty());
    e.select_all_layers(&mut s);
    s.select(BTreeSet::new(), BTreeSet::new());
    e.sync(&mut s);
    assert!(e.selected_layers(&s).is_empty() && s.graphic_layer_selection().is_none());
}

#[test]
fn delete_duplicate_group_and_ungroup_are_one_step_each() {
    let (mut s, mut e) = with_three_shapes();
    e.select_all_layers(&mut s);
    e.duplicate_selected(&mut s);
    assert_eq!(e.document(&s).map(|d| d.layers.len()), Some(6));
    assert_eq!(e.selected_layers(&s).len(), 3);
    e.group_selected(&mut s);
    assert_eq!(e.document(&s).map(|d| d.groups.len()), Some(1));
    e.ungroup_selected(&mut s);
    assert_eq!(e.document(&s).map(|d| d.groups.len()), Some(0));
    e.delete_selected(&mut s);
    assert_eq!(e.document(&s).map(|d| d.layers.len()), Some(3));
    assert!(e.selected_layers(&s).is_empty());
}

#[test]
fn reorder_and_drop_move_layers() {
    let (mut s, mut e) = with_three_shapes();
    let bottom = e.document(&s).and_then(|d| d.layers.first()).map(|l| l.id).unwrap_or(Id::NIL);
    e.select(&mut s, BTreeSet::from([bottom]));
    e.reorder(&mut s, GraphicsReorder::Front);
    assert_eq!(e.document(&s).and_then(|d| d.layers.last()).map(|l| l.id), Some(bottom));
    e.apply(&mut s, &LayerDrop { ids: vec![bottom], to_index: 0, group: None });
    assert_eq!(e.document(&s).and_then(|d| d.layers.first()).map(|l| l.id), Some(bottom));
    assert_eq!(e.selected_layers(&s), &BTreeSet::from([bottom]));
}

#[test]
fn visibility_lock_rename_and_isolate() {
    let (mut s, mut e) = with_three_shapes();
    let ids: Vec<Id> = e.document(&s).map(|d| d.layers.iter().map(|l| l.id).collect()).unwrap_or_default();
    e.set_visible(&mut s, ids[0], false);
    e.set_locked(&mut s, ids[1], true);
    assert_eq!(e.document(&s).and_then(|d| d.layer(ids[0])).map(|l| l.is_visible), Some(false));
    assert_eq!(e.document(&s).and_then(|d| d.layer(ids[1])).map(|l| l.is_locked), Some(true));
    e.show_all_layers(&mut s);
    assert!(e.document(&s).is_some_and(|d| d.layers.iter().all(|l| l.is_visible && !l.is_locked)));
    e.rename(&mut s, ids[2], "  Title  ");
    assert_eq!(e.document(&s).and_then(|d| d.layer(ids[2])).map(|l| l.name.as_str()), Some("Title"));
    e.select(&mut s, BTreeSet::from([ids[2]]));
    e.isolate_selection(&mut s, false);
    assert!(e.document(&s).is_some_and(|d| d.layers.iter().filter(|l| !l.is_visible).count() == 2));
}

#[test]
fn translate_moves_the_selection_and_undo_is_one_step() {
    let (mut s, mut e) = with_three_shapes();
    let id = *e.selected_layers(&s).iter().next().unwrap_or(&Id::NIL);
    let before = e.document(&s).and_then(|d| d.layer(id)).map(|l| l.animation.position.value);
    let depth = s.undo_depth();
    e.begin_gesture(&mut s);
    e.translate_selected(&mut s, Vec2::new(10.0, 4.0));
    e.translate_selected(&mut s, Vec2::new(5.0, 1.0));
    e.end_gesture();
    let after = e.document(&s).and_then(|d| d.layer(id)).map(|l| l.animation.position.value);
    assert_eq!(after, before.map(|b| Vec2::new(b.x + 15.0, b.y + 5.0)));
    assert_eq!(s.undo_depth(), depth + 1);
}

#[test]
fn text_layers_are_added_and_edited_and_the_type_tool_decides() {
    let mut s = session();
    let mut e = editor();
    e.new_graphics_clip(&mut s);
    e.add_text(&mut s, "Hello");
    assert_eq!(layer_names(&e, &s), ["Hello"]);
    assert_eq!(e.text_template(&s).map(|t| t.text), Some("Hello".to_string()));
    e.update_text(&mut s, "Edit Text", None, |t| t.text = "Bye".to_string());
    assert_eq!(layer_names(&e, &s), ["Bye"]);
    assert_eq!(e.text_template(&s).map(|t| t.text), Some("Bye".to_string()));
    assert!(e.text_animations(&s).is_some());
    // With no Graphic open the Type tool makes a new one (measuring text on an open Graphic needs the bundled font).
    let fresh = session();
    let out = editor().type_tool_outcome(&fresh, Vec2::new(5.0, 5.0), None, None, false);
    assert_eq!(out, TypeToolOutcome::NewGraphic { at: Vec2::new(5.0, 5.0), box_: None });
}

#[test]
fn a_stroke_needs_two_points() {
    let mut ids = SequentialIds::default();
    let white = sq_core_model::EffectColor::WHITE;
    assert!(GraphicsEditor::stroke_layer(&mut ids, &[Vec2::ZERO], false, white, 8.0, 2.0).is_none());
    let l = GraphicsEditor::stroke_layer(&mut ids, &[Vec2::ZERO, Vec2::new(100.0, 0.0)], false, white, 8.0, 2.0);
    assert!(l.is_some());
}

#[test]
fn zone_lengths_set_the_clip_zones() {
    let (mut s, mut e) = with_three_shapes();
    e.set_zone_lengths(&mut s, Some(1.0), Some(0.5));
    let z = e.clip(&s).and_then(|c| c.zones.clone());
    assert_eq!(z.map(|z| (z.intro_end, z.outro_length)), Some((Time::new(600, 600), Time::new(300, 600))));
}

#[test]
fn effects_drop_on_a_layer_and_refusals_add_nothing() {
    let (mut s, mut e) = with_three_shapes();
    let id = e.selected_layer(&s).map(|l| l.id);
    assert!(id.is_some());
    let before = e.selected_layer(&s).map_or(0, |l| l.effects.len());
    let kinds = vec![EffectDragPayload::transition_id(TransitionKind::CrossDissolve), "no.such.effect".to_string()];
    let r = e.add_effects(&mut s, &kinds, id);
    assert_eq!(r, EffectDrop::Refused("Transitions go on the timeline, not on a layer.".to_string()));
    assert_eq!(e.selected_layer(&s).map(|l| l.effects.len()), Some(before));
    let r = e.add_effects(&mut s, &[ClipEffect::GAUSSIAN_BLUR_KIND.to_string()], id);
    assert_eq!(r, EffectDrop::Added);
    assert_eq!(e.selected_layer(&s).map(|l| l.effects.len()), Some(before + 1));
    e.set_locked(&mut s, id.unwrap_or(Id::fixed(0)), true);
    assert_eq!(e.add_effects(&mut s, &[], id), EffectDrop::Refused("The layer is locked.".to_string()));
    assert_eq!(
        e.add_effects(&mut s, &[], Some(Id::fixed(9999))),
        EffectDrop::Refused("Select a layer first.".to_string())
    );
}

#[test]
fn seek_local_moves_the_playhead_into_the_clip() {
    let (mut s, e) = with_three_shapes();
    let start = e.clip(&s).map(|c| c.start).unwrap_or(Time::ZERO);
    e.seek_local(&mut s, Time::new(1, 1));
    assert_eq!(s.playhead(), start + Time::new(1, 1));
    assert!(e.playhead_in_clip(&s));
    e.seek_local(&mut s, Time::new(60, 1));
    assert!(!e.playhead_in_clip(&s));
}

#[test]
fn the_text_layer_under_a_point_is_found_and_has_a_box_for_the_field() {
    // Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
    sq_text::portable_font_match::set_fonts_root(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
    );
    let mut s = session();
    let mut e = editor();
    e.new_graphics_clip(&mut s);
    e.add_text(&mut s, "Hello");
    let id = *e.selected_layers(&s).iter().next().expect("the text layer is selected");
    let target = e.text_edit_target(&s, id).expect("the field box");
    assert!(target.is_text && target.size.width > 0.0 && target.size.height > 0.0);
    let hit = e.text_layer_hit(&s, Vec2::new(0.0, 0.0)).expect("the layer at the center");
    assert_eq!((hit.layer, hit.track_index), (id, 0));
    assert!(e.text_layer_hit(&s, Vec2::new(900.0, 500.0)).is_none(), "empty canvas");
}
