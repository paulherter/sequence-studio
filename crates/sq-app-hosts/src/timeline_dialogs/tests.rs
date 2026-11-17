//! Tests of the timeline dialogs: a form value is reported into the captured map, a button press finishes the dialog,
//! and `run` applies the answer to the session.

use super::*;
use sq_core_model::{MarkerColor, TrackKind};
use sq_core_time::SequentialIds;
use sq_editor_session::SessionDeps;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn audio_track(s: &mut EditorSession) -> Id {
    let find = |s: &EditorSession| {
        s.active_timeline().and_then(|t| t.tracks.iter().find(|t| t.kind == TrackKind::Audio).map(|t| t.id))
    };
    if find(s).is_none() {
        s.add_track(TrackKind::Audio);
    }
    find(s).expect("an audio track")
}

fn report(seen: &Captured, id: &str, v: FormValue) {
    seen.borrow_mut().insert(id.to_string(), v);
}

#[test]
fn the_prompt_hands_back_the_typed_text_on_ok_only() {
    let got: Rc<RefCell<Option<String>>> = Rc::default();
    let sink = Rc::clone(&got);
    let (mut d, seen) =
        prompt_parts(TimelinePrompt::new("Rename", "V1"), Box::new(move |t| *sink.borrow_mut() = Some(t)));
    report(&seen, "text", FormValue::Text("Hook".into()));
    d.press(SQDialogResponse::SECOND);
    assert_eq!(*got.borrow(), None);

    let sink = Rc::clone(&got);
    let (mut d, _) = prompt_parts(TimelinePrompt::new("Rename", "V1"), Box::new(move |t| *sink.borrow_mut() = Some(t)));
    d.press(SQDialogResponse::FIRST);
    assert_eq!(got.borrow().as_deref(), Some("V1"), "an untouched field answers with its start text");
}

#[test]
fn track_mix_writes_volume_and_pan_as_one_undo_step() {
    let mut s = session();
    let id = audio_track(&mut s);
    let answers = Answers::default();
    let (mut d, seen) = track_mix(&s, id, &answers).expect("dialog");
    assert!(d.header_subtitle.is_some());
    report(&seen, "volume", FormValue::Number(-6.0));
    report(&seen, "pan", FormValue::Number(-50.0));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    let t = s.active_timeline().expect("timeline").tracks.iter().find(|t| t.id == id).expect("track").clone();
    assert!((t.volume_db + 6.0).abs() < 1e-9 && (t.pan + 0.5).abs() < 1e-9);
    assert!(s.undo(), "one undo step brings the mix back");
    assert_eq!(s.active_timeline().and_then(|t| t.tracks.iter().find(|t| t.id == id).map(|t| t.volume_db)), Some(0.0));
}

#[test]
fn cancel_changes_nothing() {
    let mut s = session();
    let id = audio_track(&mut s);
    let answers = Answers::default();
    let (mut d, seen) = track_mix(&s, id, &answers).expect("dialog");
    report(&seen, "volume", FormValue::Number(-6.0));
    d.press(SQDialogResponse::SECOND);
    run(&answers, &mut s);
    assert_eq!(s.active_timeline().and_then(|t| t.tracks.iter().find(|t| t.id == id).map(|t| t.volume_db)), Some(0.0));
}

#[test]
fn sequence_volume_sets_the_level_and_can_key_it() {
    let mut s = session();
    let answers = Answers::default();
    let (mut d, seen) = sequence_volume(&s, &answers).expect("dialog");
    report(&seen, "volume", FormValue::Number(-3.0));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    assert!((s.active_timeline().expect("timeline").master_volume_db() + 3.0).abs() < 1e-9);

    let (mut d, seen) = sequence_volume(&s, &answers).expect("dialog");
    report(&seen, "volume", FormValue::Number(-9.0));
    report(&seen, "animate", FormValue::Bool(true));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    assert!(s.active_timeline().expect("timeline").is_master_volume_keyed());
}

#[test]
fn the_marker_sheet_applies_the_reported_values_and_deletes() {
    let mut s = session();
    let id = s.mark_at_playhead().expect("a marker").id;
    let answers = Answers::default();
    let (mut d, seen) = marker(&s, id, None, &answers).expect("dialog");
    report(&seen, "name", FormValue::Text("Hook".into()));
    report(&seen, "color", FormValue::Index(1));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
    assert!(m.name == "Hook" && m.color == MarkerColor::Red);

    let (mut d, _) = marker(&s, id, None, &answers).expect("dialog");
    d.press(SQDialogResponse::THIRD);
    run(&answers, &mut s);
    assert!(marker(&s, id, None, &answers).is_none(), "the marker is gone");
}

#[test]
fn the_caption_editor_selects_the_caption_and_joins_lines() {
    let mut s = session();
    let id = s.add_caption_at_playhead().expect("a caption");
    let answers = Answers::default();
    let (mut d, seen) = caption_text(&mut s, id, &answers).expect("dialog");
    report(&seen, "text", FormValue::Text("one /  two".into()));
    d.press(SQDialogResponse::FIRST);
    run(&answers, &mut s);
    let lines = s.active_timeline().and_then(|t| {
        t.caption_tracks.iter().flat_map(|c| c.items().iter()).find(|i| i.id == id).map(|i| i.lines.clone())
    });
    assert_eq!(lines, Some(vec!["one".to_string(), "two".to_string()]));
}

#[test]
fn only_the_owned_requests_make_a_dialog() {
    let mut s = session();
    let answers = Answers::default();
    assert!(editor_dialog(&mut s, &TimelineEditorRequest::SequenceVolume, &answers).is_some());
    assert!(editor_dialog(&mut s, &TimelineEditorRequest::Marker(Id::from_u128(9)), &answers).is_none());
    assert!(editor_dialog(&mut s, &TimelineEditorRequest::NewColorMatte, &answers).is_none());
}
