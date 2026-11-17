// Swift: SQAppShell/TimelineEditorDialogs.swift (presentTrackMix, presentSequenceVolume, editCaptionText), ShellMarkerDialog.swift
//! The SQ dialogs the timeline asks for: text prompts, track mix, sequence volume, marker editors and the caption line
//! editor. A dialog only records what was typed; the answer waits as a closure that [`Answers`] runs on the session.

use sq_core_model::TrackPan;
use sq_core_time::Id;
use sq_draw::monitor::track_mix_text::TrackMixText;
use sq_draw_shell::{FormRow, FormValue, NumberField, ShellDialog, ShellForm, ShellHost};
use sq_draw_timeline::host::{TimelineEditorRequest, TimelinePrompt};
use sq_editor_session::EditorSession;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

/// What a finished dialog does to the session.
type Answer = Box<dyn FnOnce(&mut EditorSession)>;
/// Answers waiting for the next pump.
pub(crate) type Answers = Rc<RefCell<Vec<Answer>>>;
/// The values a form reported, by row id.
pub(crate) type Captured = Rc<RefCell<BTreeMap<String, FormValue>>>;

/// The dialog width of the small mix cards (`widthXS`).
const WIDTH_XS: f64 = 360.0;

/// Records every value `form` reports. A dialog's form is out of reach once it answered, so the closures read this.
pub(crate) fn capture(form: &mut ShellForm) -> Captured {
    let seen: Captured = Rc::default();
    let into = Rc::clone(&seen);
    form.on_change = Some(Box::new(move |_, id, v| {
        into.borrow_mut().insert(id.to_string(), v.clone());
    }));
    seen
}

pub(crate) fn number(seen: &Captured, id: &str) -> Option<f64> {
    match seen.borrow().get(id)? {
        FormValue::Number(v) => Some(*v),
        FormValue::Text(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub(crate) fn text(seen: &Captured, id: &str) -> Option<String> {
    match seen.borrow().get(id)? {
        FormValue::Text(s) => Some(s.clone()),
        _ => None,
    }
}

/// OK and Cancel; `done` runs with the response when the dialog closes.
fn dialog(
    title: &str,
    informative: &str,
    form: ShellForm,
    done: impl FnOnce(SQDialogResponse) + 'static,
) -> ShellDialog {
    dialog_labeled("OK", title, informative, form, done)
}

/// [`dialog`] with its own title on the default button ("Save", "Add").
pub(crate) fn dialog_labeled(
    ok: &str,
    title: &str,
    informative: &str,
    form: ShellForm,
    done: impl FnOnce(SQDialogResponse) + 'static,
) -> ShellDialog {
    let mut d = ShellDialog::new(title, informative);
    d.form = Some(Box::new(form));
    d.add_button(ok, SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.completion = Some(Box::new(done));
    d
}

/// One unlabeled text field over the card's width (the Mac prompts); `done` gets the text on OK only.
pub(crate) fn prompt(p: TimelinePrompt, done: Box<dyn FnOnce(String)>) -> ShellDialog {
    prompt_parts(p, done).0
}

/// [`prompt`] and the values its form reported (tests fill them in).
fn prompt_parts(p: TimelinePrompt, done: Box<dyn FnOnce(String)>) -> (ShellDialog, Captured) {
    let mut form = ShellForm::new(vec![FormRow::field("text", "", &p.text)]);
    let seen = capture(&mut form);
    let start = p.text;
    let reported = Rc::clone(&seen);
    let d = dialog(&p.title, &p.message, form, move |r| {
        if r == SQDialogResponse::FIRST {
            done(text(&reported, "text").unwrap_or(start));
        }
    });
    (d, seen)
}

/// The Volume row: fader range, 0.1 dB steps, "-inf" at the floor, a double click resets to 0 dB.
fn volume_row(db: f64) -> FormRow {
    FormRow::SliderNumber {
        label: "Volume".to_string(),
        field: NumberField {
            step: 0.1,
            decimals: 1,
            unit: "dB".to_string(),
            default_value: Some(0.0),
            ..NumberField::new("volume", db, TrackPan::MIN_VOLUME_DB..=TrackPan::MAX_VOLUME_DB)
        },
    }
}

fn format_volume(form: &mut ShellForm) {
    form.set_format("volume", Box::new(TrackMixText::capsule_text), Box::new(TrackMixText::parse_volume_db));
}

/// "Track Volume and Pan": Volume and Pan, one undo step.
fn track_mix(session: &EditorSession, id: Id, answers: &Answers) -> Option<(ShellDialog, Captured)> {
    let track = session.active_timeline()?.tracks.iter().find(|t| t.id == id)?;
    let (volume, pan) = (track.volume_db, track.pan * 100.0);
    let mut form = ShellForm::new(vec![
        volume_row(volume),
        FormRow::SliderNumber {
            label: "Pan".to_string(),
            field: NumberField { default_value: Some(0.0), ..NumberField::new("pan", pan, -100.0..=100.0) },
        },
    ]);
    form.slider_track_width = Some(120.0);
    format_volume(&mut form);
    form.set_format("pan", Box::new(TrackMixText::text_pan), Box::new(TrackMixText::parse_pan));
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let answers = Rc::clone(answers);
    let mut d = dialog("Track Volume and Pan", "", form, move |r| {
        if r == SQDialogResponse::FIRST {
            let (v, p) = (number(&reported, "volume").unwrap_or(volume), number(&reported, "pan").unwrap_or(pan));
            answers.borrow_mut().push(Box::new(move |s| {
                s.set_track_mix(id, v, p / 100.0);
            }));
        }
    });
    d.header_subtitle = Some(track.name.clone());
    d.width = WIDTH_XS;
    Some((d, seen))
}

/// "Sequence Volume": Volume and Keyframe at Playhead.
fn sequence_volume(session: &EditorSession, answers: &Answers) -> Option<(ShellDialog, Captured)> {
    let t = session.active_timeline()?;
    let level = t.master_volume_db_at(session.playhead());
    let mut form = ShellForm::new(vec![
        volume_row(level),
        FormRow::check("animate", "Keyframe at Playhead", t.is_master_volume_keyed()),
    ]);
    format_volume(&mut form);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let answers = Rc::clone(answers);
    let mut d = dialog("Sequence Volume", "", form, move |r| {
        if r == SQDialogResponse::FIRST {
            let v = number(&reported, "volume").unwrap_or(level);
            let animate = matches!(reported.borrow().get("animate"), Some(FormValue::Bool(true)));
            answers.borrow_mut().push(Box::new(move |s| {
                s.set_sequence_volume_animated(v, animate);
            }));
        }
    });
    d.header_subtitle = Some(if t.name.is_empty() {
        "Every track of this sequence".to_string()
    } else {
        format!("Every track of {}", t.name)
    });
    d.width = WIDTH_XS;
    Some((d, seen))
}

/// The marker sheet of a sequence marker (`clip == None`) or a clip marker.
fn marker(session: &EditorSession, id: Id, clip: Option<Id>, answers: &Answers) -> Option<(ShellDialog, Captured)> {
    let t = session.active_timeline()?;
    let m = ShellHost::find_marker(id, clip, t)?;
    let frame_duration = t.frame_duration();
    let mut form = ShellHost::marker_form(&m, clip.is_some(), frame_duration);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let answers = Rc::clone(answers);
    let mut d = ShellDialog::new(if clip.is_none() { "Marker" } else { "Clip Marker" }, "");
    d.form = Some(Box::new(form));
    d.add_button("OK", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.add_button("Delete Marker", SQDialogRole::Destructive, true);
    d.ghost_buttons.insert(2);
    d.completion = Some(Box::new(move |r| {
        answers.borrow_mut().push(Box::new(move |s| {
            // The shell reads a fresh form carrying the reported values.
            let Some(t) = s.active_timeline() else { return };
            let Some(m) = ShellHost::find_marker(id, clip, t) else { return };
            let mut f = ShellHost::marker_form(&m, clip.is_some(), t.frame_duration());
            for (k, v) in reported.borrow().iter() {
                f.set(k, v.clone());
            }
            ShellHost::apply_marker_dialog(&f, r, id, clip, s);
        }));
    }));
    Some((d, seen))
}

/// Without a Text panel: the caption's lines in one field, separated by " / ", one undo step.
// The fallback of Swift's `editCaptionText`: the Text panel's row edits the caption in place (root `edit_caption_in_panel`).
fn caption_text(session: &mut EditorSession, id: Id, answers: &Answers) -> Option<(ShellDialog, Captured)> {
    let item = session.active_timeline()?.caption_tracks.iter().flat_map(|t| t.items().iter()).find(|i| i.id == id)?;
    let start = item.lines.join(" / ");
    session.select(BTreeSet::new(), BTreeSet::from([id]));
    let mut form = ShellForm::new(vec![FormRow::field("text", "Text", &start)]);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let answers = Rc::clone(answers);
    let d = dialog("Edit Caption", "Separate lines with \" / \".", form, move |r| {
        if r != SQDialogResponse::FIRST {
            return;
        }
        let Some(typed) = text(&reported, "text") else { return };
        let lines: Vec<&str> = typed.split(" / ").map(str::trim).collect();
        let joined = lines.join("\n");
        answers.borrow_mut().push(Box::new(move |s| {
            s.set_caption_text(id, &joined, false);
        }));
    });
    Some((d, seen))
}

/// The dialog for an editor request this module owns; `None` for every other request (and a vanished target).
pub(crate) fn editor_dialog(
    session: &mut EditorSession,
    r: &TimelineEditorRequest,
    answers: &Answers,
) -> Option<ShellDialog> {
    editor_parts(session, r, answers).map(|(d, _)| d)
}

/// [`editor_dialog`] and the values its form reported (tests fill them in).
fn editor_parts(
    session: &mut EditorSession,
    r: &TimelineEditorRequest,
    answers: &Answers,
) -> Option<(ShellDialog, Captured)> {
    match r {
        TimelineEditorRequest::TrackMix(id) => track_mix(session, *id, answers),
        TimelineEditorRequest::SequenceVolume => sequence_volume(session, answers),
        TimelineEditorRequest::Marker(id) => marker(session, *id, None, answers),
        TimelineEditorRequest::ClipMarker { clip, marker: id } => marker(session, *id, Some(*clip), answers),
        TimelineEditorRequest::CaptionText(id) => caption_text(session, *id, answers),
        _ => None,
    }
}

/// Runs the answers of finished dialogs on the session.
pub(crate) fn run(answers: &Answers, session: &mut EditorSession) {
    let waiting = std::mem::take(&mut *answers.borrow_mut());
    for a in waiting {
        a(session);
    }
}

#[cfg(test)]
mod tests;
