//! Tests of the editor dialogs: a value is reported into the captured map, a button press finishes the dialog, and the
//! answer lands on the session or in the outbox.

use super::*;
use crate::timeline_dialogs::run;
use sq_core_audio::ToneSpec;
use sq_core_color::ColorMatteColor;
use sq_core_effects::effect_preset::EffectPreset;
use sq_core_time::{SequentialIds, Time, Timestamp};
use sq_editor_session::SessionDeps;
use sq_library::preset_store::PresetKind;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-editor-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn report(seen: &Captured, id: &str, v: FormValue) {
    seen.borrow_mut().insert(id.to_string(), v);
}

fn clip_count(s: &EditorSession) -> usize {
    s.active_timeline().map_or(0, |t| t.tracks.iter().map(|tr| tr.clips().len()).sum())
}

#[test]
fn a_color_matte_lands_at_the_playhead_in_one_undo_step() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, seen) = editor_parts(&mut s, &TimelineEditorRequest::NewColorMatte, &answers, &out).expect("dialog");
    report(&seen, "name", FormValue::Text("Backdrop".into()));
    report(&seen, "color", FormValue::Text("FF8000".into()));
    report(&seen, "duration", FormValue::Number(2.0));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    assert_eq!(clip_count(&s), 1);
    let clip = s.active_timeline().and_then(|t| t.tracks.iter().flat_map(|tr| tr.clips()).next().cloned());
    let clip = clip.expect("the matte");
    assert_eq!(clip.name, "Backdrop");
    let d = clip.duration();
    let seconds = d.value() as f64 / d.timescale() as f64;
    assert!((2.0..2.1).contains(&seconds), "snapped to a frame: {seconds}");
    assert!(s.undo());
    assert_eq!(clip_count(&s), 0);
}

#[test]
fn cancel_adds_no_matte() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, _) = editor_parts(&mut s, &TimelineEditorRequest::NewColorMatte, &answers, &out).expect("dialog");
    d.press(SQDialogResponse::SECOND);
    run(&answers, &mut s);
    assert_eq!(clip_count(&s), 0);
}

#[test]
fn tone_settings_change_the_selected_tone_clip() {
    let mut s = session();
    let id = s.add_tone_clip(&ToneSpec::DEFAULT, Time::new(2, 1)).expect("tone clip");
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, seen) = editor_parts(&mut s, &TimelineEditorRequest::ToneClip(id), &answers, &out).expect("dialog");
    report(&seen, "freq", FormValue::Text("440".into()));
    report(&seen, "level", FormValue::Text("-6".into()));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    let (_, spec) = s.selected_tone().expect("tone");
    assert_eq!((spec.frequency_hz(), spec.level_db()), (440.0, -6.0));
}

#[test]
fn saving_a_preset_without_a_selection_leaves_a_status_line() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    assert!(editor_parts(&mut s, &TimelineEditorRequest::SaveClipPreset, &answers, &out).is_none());
    let notes = std::mem::take(&mut out.borrow_mut().notes);
    assert_eq!(notes, ["Select one clip to save its settings as a preset."]);
}

#[test]
fn a_title_block_needs_a_selection_and_a_name_dialog_queues_the_preset() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    assert!(editor_parts(&mut s, &TimelineEditorRequest::SaveTitleBlock, &answers, &out).is_none());
    assert_eq!(out.borrow().notes.len(), 1);

    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Bar", None, None, Time::new(2, 1)).expect("clip");
    s.select(BTreeSet::from([id]), BTreeSet::new());
    let (mut d, seen) =
        editor_parts(&mut s, &TimelineEditorRequest::SaveTitleBlock, &answers, &out).expect("name dialog");
    report(&seen, "name", FormValue::Text("  ".into()));
    d.press(SQDialogResponse::FIRST);
    let saves = std::mem::take(&mut out.borrow_mut().saves);
    assert_eq!(saves.len(), 1, "one preset waits for the Library");
    assert!(saves[0].done.contains("title block"));
}

#[test]
fn the_clip_menu_preset_is_queued_as_an_effect_preset_with_the_typed_name() {
    let mut s = session();
    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Bar", None, None, Time::new(2, 1)).expect("clip");
    s.select(BTreeSet::from([id]), BTreeSet::new());
    let mut clip = s.single_selected_clip().expect("clip").clone();
    clip.animation.opacity.value = 0.5;
    s.replace_clip(&clip, "Opacity", false);
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, seen) = editor_parts(&mut s, &TimelineEditorRequest::SaveClipPreset, &answers, &out).expect("dialog");
    report(&seen, "name", FormValue::Text("  Soft  ".into()));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    let mut saves = std::mem::take(&mut out.borrow_mut().saves);
    assert_eq!(saves.len(), 1, "one preset waits for the Library");
    assert_eq!(saves[0].done, "Saved preset \u{201c}Soft\u{201d}.");
    let item = (saves.remove(0).make)(Id::from_u128(9), Timestamp::from_reference_seconds(0.0)).expect("item");
    assert_eq!((item.name.as_str(), item.kind), ("Soft", PresetKind::Effect));
}

#[test]
fn angles_need_two_clips() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    assert!(editor_parts(&mut s, &TimelineEditorRequest::CreateAnglesClip, &answers, &out).is_none());
    assert_eq!(out.borrow().notes, ["Select at least two clips, in the timeline or in the Project panel."]);
}

#[test]
fn other_requests_are_not_ours() {
    let mut s = session();
    let (answers, out) = (Answers::default(), Shared::default());
    assert!(editor_parts(&mut s, &TimelineEditorRequest::SequenceVolume, &answers, &out).is_none());
    assert!(out.borrow().notes.is_empty());
}

#[test]
fn the_graphics_effect_preset_dialog_queues_a_named_save() {
    let out = Shared::default();
    let mut s = session();
    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Bar", None, None, Time::new(2, 1)).expect("clip");
    let clip =
        s.active_timeline().and_then(|t| t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id).cloned());
    let preset = EffectPreset::capture(&clip.expect("clip"), Anchor::Start, None, None, None);
    let mut d = effect_preset(preset, &out);
    d.press(SQDialogResponse::FIRST);
    let saves = std::mem::take(&mut out.borrow_mut().saves);
    assert_eq!(saves.len(), 1);
    assert_eq!(saves[0].done, "Saved preset \u{201c}Effect Preset\u{201d}.");
}

/// Saves the selected matte as a template with the typed name and runs the answer; returns the outbox.
fn save_template(s: &mut EditorSession) -> Shared {
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, seen) = editor_parts(s, &TimelineEditorRequest::SaveTemplate, &answers, &out).expect("name dialog");
    report(&seen, "name", FormValue::Text("Lower Third".into()));
    d.press(SQDialogResponse::FIRST);
    run(&answers, s);
    out
}

#[test]
fn a_template_inside_the_selected_video_waits_for_its_preview_frame() {
    let mut s = session();
    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Bar", None, None, Time::new(2, 1)).expect("clip");
    s.select(BTreeSet::from([id]), BTreeSet::new());
    s.seek(Time::new(1, 1));
    let out = save_template(&mut s);
    let out = out.borrow();
    assert!(out.saves.is_empty(), "the Library save waits for the frame");
    assert_eq!(out.templates.len(), 1);
    assert_eq!(out.templates[0].name, "Lower Third");
}

#[test]
fn a_template_with_the_playhead_outside_the_video_saves_at_once_without_a_note() {
    let mut s = session();
    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Bar", None, None, Time::new(2, 1)).expect("clip");
    s.select(BTreeSet::from([id]), BTreeSet::new());
    s.seek(Time::new(9, 1));
    s.select(BTreeSet::from([id]), BTreeSet::new());
    let out = save_template(&mut s);
    let out = out.borrow();
    assert!(out.templates.is_empty());
    assert_eq!(out.saves.len(), 1);
    assert!(!out.saves[0].done.contains("preview"), "{}", out.saves[0].done);
}

/// Two mattes on two video tracks, both selected: two angles.
fn two_angles(s: &mut EditorSession) -> Vec<Id> {
    let first = s.add_color_matte(ColorMatteColor::DEFAULT, "A", Some(Time::ZERO), None, Time::new(2, 1)).expect("a");
    s.add_track(sq_core_model::TrackKind::Video);
    let track = s.active_timeline().and_then(|t| t.tracks.last().map(|t| t.id)).expect("track");
    let second =
        s.add_color_matte(ColorMatteColor::DEFAULT, "B", Some(Time::ZERO), Some(track), Time::new(2, 1)).expect("b");
    let ids = vec![first, second];
    s.select(ids.iter().copied().collect(), BTreeSet::new());
    ids
}

#[test]
fn the_angles_sheet_offers_every_sync_and_queues_the_flow_with_the_chosen_one() {
    let mut s = session();
    let ids = two_angles(&mut s);
    let (answers, out) = (Answers::default(), Shared::default());
    let (mut d, seen) = editor_parts(&mut s, &TimelineEditorRequest::CreateAnglesClip, &answers, &out).expect("sheet");
    let offered = AngleSyncMode::choices(&s.angle_candidates_clips(&ids), true);
    assert!(offered.contains(&AngleSyncMode::Timecode), "Timecode is on the sheet");
    let at = offered.iter().position(|m| *m == AngleSyncMode::Timecode).expect("timecode") as i64;
    report(&seen, "sync", FormValue::Index(at));
    report(&seen, "name", FormValue::Text("Talk".into()));
    report(&seen, "follows", FormValue::Bool(true));
    d.press(SQDialogResponse::FIRST);
    let flows = std::mem::take(&mut out.borrow_mut().flows);
    assert_eq!(
        flows,
        [ShellFlow::CreateAngles {
            clips: s.angle_selection(),
            name: "Talk".into(),
            sync: AngleSyncMode::Timecode,
            sound: 0,
            follows: true
        }]
    );
}
