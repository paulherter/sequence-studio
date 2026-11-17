//! Bug 38 (Mac test, 2026-11-14): with an effect selected in Controls, Backspace, Delete and Edit > Delete did nothing; only
//! the section's right-click Delete removed it. The keys are pressed through the real root (focus, key map, enable rule,
//! handlers), so a key that dies between the window and the panel fails here.

use super::disabled_commands_tests::{clip_ids, frame, pick};
use super::menu_click_tests::{click, new_root, open_down_to, send};
use super::*;
use crate::test_rig::Rig;
use sq_core_model::ClipEffect;
use sq_core_time::Id;
use sq_editor_session::EffectSection;
use std::collections::BTreeSet;

const N: InputModifiers = InputModifiers::NONE;

/// A root whose first video clip carries a Shake effect, Controls focused with that effect's header selected.
fn root_with_selected_shake() -> (AppRoot, Rig, Id) {
    let (mut root, mut rig) = new_root();
    let clip = clip_ids(&rig.session)[0];
    pick(&mut rig.session, &[clip]);
    assert!(rig.session.add_effect(ClipEffect::SHAKE_KIND, &BTreeSet::from([clip])));
    root.sync(&rig.session);
    frame(&mut root, &mut rig);
    root.dock.set_focused(Some(PanelID::EffectControls));
    root.shell.shell().focus = Some(PanelID::EffectControls);
    let id = effects_of(&rig, clip)[0].0;
    let section = EffectSection::Effect { id, kind: ClipEffect::SHAKE_KIND.to_string() };
    root.inspector.controls().model.select_effect_header(&section);
    frame(&mut root, &mut rig);
    // The drawn menu bar builds its menus on the first event it sees.
    send(&mut root, &mut rig, InputEvent::MouseMoved { x: 400.0, y: 400.0 });
    (root, rig, clip)
}

/// (id, kind) of the effects of clip `clip`.
fn effects_of(rig: &Rig, clip: Id) -> Vec<(Id, String)> {
    let t = rig.session.active_timeline().expect("sequence");
    let c = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == clip).expect("clip");
    c.effects.iter().map(|e| (e.id, e.kind.clone())).collect()
}

/// The effects of clip `clip`, or `None` once the clip itself is gone.
fn effects_of_or_none(rig: &Rig, clip: Id) -> Option<Vec<(Id, String)>> {
    let t = rig.session.active_timeline()?;
    let c = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == clip)?;
    Some(c.effects.iter().map(|e| (e.id, e.kind.clone())).collect())
}

fn clip_count(rig: &Rig) -> usize {
    rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|tr| tr.clips().len()).sum())
}

#[test]
fn backspace_removes_the_selected_effect_and_undo_brings_it_back() {
    let (mut root, mut rig, clip) = root_with_selected_shake();
    let clips = clip_count(&rig);
    send(&mut root, &mut rig, InputEvent::KeyDown { key: InputKey::Backspace, modifiers: N });
    frame(&mut root, &mut rig);
    assert!(effects_of(&rig, clip).is_empty(), "Backspace left the effect: {:?}", effects_of(&rig, clip));
    assert_eq!(clip_count(&rig), clips, "Backspace in Controls must never delete the timeline clip");
    assert!(rig.session.undo());
    root.sync(&rig.session);
    assert_eq!(effects_of(&rig, clip).len(), 1, "undo brings the effect back");
}

#[test]
fn the_delete_key_removes_the_selected_effect() {
    let (mut root, mut rig, clip) = root_with_selected_shake();
    send(&mut root, &mut rig, InputEvent::KeyDown { key: InputKey::Delete, modifiers: N });
    frame(&mut root, &mut rig);
    assert!(effects_of(&rig, clip).is_empty());
}

#[test]
fn edit_menu_delete_and_cut_act_on_the_selected_effect_not_on_the_timeline_clip() {
    for row in ["Delete", "Cut"] {
        let (mut root, mut rig, clip) = root_with_selected_shake();
        let clips = clip_count(&rig);
        let at = open_down_to(&mut root, &mut rig, "Edit", &[row]);
        click(&mut root, &mut rig, at);
        frame(&mut root, &mut rig);
        assert!(effects_of_or_none(&rig, clip).is_some_and(|e| e.is_empty()), "Edit > {row} left the effect");
        assert_eq!(clip_count(&rig), clips, "Edit > {row} with Controls focused must not touch the timeline clip");
    }
}

#[test]
fn edit_menu_copy_then_paste_copies_the_effect_not_the_clip() {
    let (mut root, mut rig, clip) = root_with_selected_shake();
    let clips = clip_count(&rig);
    let at = open_down_to(&mut root, &mut rig, "Edit", &["Copy"]);
    click(&mut root, &mut rig, at);
    let at = open_down_to(&mut root, &mut rig, "Edit", &["Paste"]);
    click(&mut root, &mut rig, at);
    frame(&mut root, &mut rig);
    assert_eq!(effects_of(&rig, clip).len(), 2, "the copied effect landed on the clip");
    assert_eq!(clip_count(&rig), clips);
}

#[test]
fn backspace_without_a_selected_effect_leaves_the_clip_and_its_effect_alone() {
    let (mut root, mut rig, clip) = root_with_selected_shake();
    root.inspector.controls().model.selected_section = None;
    let clips = clip_count(&rig);
    send(&mut root, &mut rig, InputEvent::KeyDown { key: InputKey::Backspace, modifiers: N });
    frame(&mut root, &mut rig);
    assert_eq!(effects_of(&rig, clip).len(), 1);
    assert_eq!(clip_count(&rig), clips, "Controls has the focus: the timeline's Delete must not run");
}
