//! Hooks the shell calls that the app has to answer: each case goes through the real root (`AppRoot` with the app's own
//! `TimelineHooks` and services), never a test double. A hook the app forgot to override shows up here as a command that
//! does nothing.

use super::disabled_commands_tests::{clip_ids, frame, pick, select_edge};
use super::host_commands_tests::{Setup, add_two_layer_graphic, key, type_chars};
use super::*;
use sq_core_model::{BinItemRef, ClipEdge};
use sq_core_time::{Id, Time, Timestamp};
use sq_editor_session::{FindCriteria, FindField};
use sq_uikit::editor_command::EditorCommand as C;

fn statuses(t: &mut Setup) -> Vec<String> {
    t.root
        .shell
        .shell()
        .take_events()
        .into_iter()
        .filter_map(|e| if let sq_draw_shell::ShellEvent::Status(s) = e { Some(s) } else { None })
        .collect()
}

fn graphic_layer_count(t: &Setup) -> usize {
    let tl = t.rig.session.active_timeline().expect("sequence");
    tl.tracks.iter().flat_map(|tr| tr.clips()).filter_map(|c| c.graphics().map(|g| g.layers.len())).sum()
}

/// Edit > Find: the Project panel selects the matches and the status line counts them.
#[test]
fn find_selects_the_matches_in_the_project_list() {
    let mut t = Setup::new();
    t.root.shell.shell().select_found(&FindCriteria::new("clip2", FindField::Name, false));
    let mut lines = Vec::new();
    t.root.answer_timeline(&mut t.rig.cx(), &mut lines);
    assert_eq!(t.root.project.view().selection(), [BinItemRef::Media(Id::from_u128(902))]);
    assert_eq!(statuses(&mut t), vec!["1 match."]);

    t.root.shell.shell().select_found(&FindCriteria::new("zzz", FindField::Name, false));
    t.root.answer_timeline(&mut t.rig.cx(), &mut lines);
    assert_eq!(statuses(&mut t), vec!["No match."]);
}

/// Edit > Select All and Delete with the Graphics panel focused act on its layers, not on the timeline's clips.
#[test]
fn select_all_and_delete_run_on_the_graphics_layers() {
    let mut t = Setup::new();
    add_two_layer_graphic(&mut t);
    let total = graphic_layer_count(&t);
    t.root.shell.shell().focus = Some(PanelID::Graphics);
    t.run(C::SelectLayerAbove);
    let one = t.rig.session.graphic_layer_selection().map(|s| s.layers.len());
    assert_eq!(one, Some(1));
    t.run(C::SelectAll);
    assert_eq!(t.rig.session.graphic_layer_selection().map(|s| s.layers.len()), Some(total));
    t.run(C::Delete);
    assert_eq!(graphic_layer_count(&t), 0, "Delete removed the selected layers");
}

/// Edit > Delete with the Text panel focused deletes the selected captions.
#[test]
fn delete_removes_the_selected_captions_of_the_text_panel() {
    let mut t = Setup::new();
    let caption = t.rig.session.add_caption_at_playhead().expect("caption");
    assert!(t.rig.session.caption_selection().contains(&caption));
    t.root.shell.shell().focus = Some(PanelID::Text);
    t.run(C::Delete);
    assert!(t.rig.session.caption_selection().is_empty());
    assert!(!serde_json::to_string(t.rig.session.project()).unwrap_or_default().contains(&format!("{caption:?}")));
}

/// Apply Video Transition reads the timeline's selected edit points, with no clip selected.
#[test]
fn apply_transition_uses_the_selected_edges() {
    let mut t = Setup::new();
    let first = clip_ids(&t.rig.session)[0];
    pick(&mut t.rig.session, &[]);
    // Away from every edit point, so only the edge selection can say where the transition goes.
    t.rig.session.seek(Time::seconds(3));
    select_edge(&mut t.root, &mut t.rig, ClipEdge::Head);
    frame(&mut t.root, &mut t.rig);
    let before = serde_json::to_string(t.rig.session.project()).unwrap_or_default();
    t.run(C::ApplyVideoTransition);
    let after = serde_json::to_string(t.rig.session.project()).unwrap_or_default();
    assert_ne!(before, after, "a transition went onto the edge of {first:?}");
    let said =
        t.rig.events.iter().any(|e| matches!(e, sq_app_shell::AppEvent::Status(s) if s == "Transition applied."));
    assert!(said, "the status line says so");
}

/// Quick Apply applies a Library preset: the palette lists it and Return applies the same preset.
#[test]
fn quick_apply_applies_a_library_preset() {
    use sq_core_effects::effect_preset::{Anchor, EffectPreset};
    use sq_core_model::ClipEffect;
    let mut t = Setup::new();
    let mut preset = EffectPreset::new(Anchor::Start, Time::seconds(5));
    preset.effects.push(ClipEffect::new(Id::from_u128(77), ClipEffect::GAUSSIAN_BLUR_KIND));
    let item = sq_editor_session::EditorSession::effect_preset_item(
        "Soft Glow",
        &preset,
        Id::from_u128(7),
        Timestamp::from_unix_seconds(0.0),
    )
    .expect("preset item");
    t.root.library.panel_host().panel.model.save_preset(item).expect("saved");
    sq_app_shell::AppHost::sync(&mut t.root, &t.rig.session); // the frame step that publishes the Library's presets
    frame(&mut t.root, &mut t.rig);
    let first = clip_ids(&t.rig.session)[0];
    pick(&mut t.rig.session, &[first]);
    let blur = |t: &Setup| serde_json::to_string(t.rig.session.project()).unwrap_or_default().contains("gaussianBlur");
    assert!(!blur(&t));
    t.run(C::QuickApply);
    assert!(t.root.shell.shell().quick_apply_open());
    type_chars(&mut t, "soft glow");
    key(&mut t, InputKey::Enter, InputModifiers::NONE);
    let (q, open, err) = (
        t.root.shell.shell().quick_apply_query().map(str::to_string),
        t.root.shell.shell().quick_apply_open(),
        t.rig.session.last_error().map(str::to_string),
    );
    assert!(blur(&t), "the preset's effect is on the clip: {q:?} {open} {err:?} {:?}", statuses(&mut t));
}
