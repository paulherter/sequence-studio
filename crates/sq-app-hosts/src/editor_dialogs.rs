// Swift: SQAppShell/TimelineEditorDialogs.swift (editTone, the preset and template sheets, presentNewColorMatte, requestAnglesClip)
//! The remaining SQ dialogs the timeline asks for: Tone Settings, New Color Matte, Create Angles Clip and the sheets that
//! save a clip, transition, title block or template into the Library. A dialog only records what was typed; the answer
//! runs on the session through [`Answers`], and a preset waits in the [`Outbox`] for the root, which owns the Library.

use crate::template_thumbnail::PendingTemplate;
use crate::timeline_dialogs::{Answers, Captured, capture, dialog_labeled, number, text};
use sq_core_audio::ToneSpec;
use sq_core_color::ColorMatteColor;
use sq_core_effects::effect_preset::{Anchor, EffectPreset};
use sq_core_effects::transition::TransitionKindExt as _;
use sq_core_time::{Id, Timestamp};
use sq_draw_shell::{FormRow, FormValue, NumberField, ShellDialog, ShellFlow, ShellForm};
use sq_draw_timeline::host::TimelineEditorRequest;
use sq_draw_timeline::menus::TimelineEditorForms;
use sq_editor_session::{AngleSyncMode, EditorSession};
use sq_library::preset_store::PresetItem;
use sq_timeline_ui::timeline_menu_spec::PresetSaveSheet;
use sq_uikit::sqcolor_value::SQColorValue;
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

/// Builds the stored preset once the Library knows the id and the time.
pub(crate) type MakePreset = Box<dyn FnOnce(Id, Timestamp) -> Result<PresetItem, String>>;

/// A preset to add to the Library.
pub(crate) struct Save {
    pub make: MakePreset,
    /// The status line on success.
    pub done: String,
    /// The start of the status line on failure; the error text follows.
    pub failure: &'static str,
}

/// What finished dialogs leave for the root: presets for the Library and status lines.
#[derive(Default)]
pub(crate) struct Outbox {
    pub saves: Vec<Save>,
    /// Templates that wait for the Program frame of their preview image (the root renders it, then saves).
    pub templates: Vec<PendingTemplate>,
    /// Flows the root starts on the executor (Create Angles Clip reads the files for Timecode and Audio sync).
    pub flows: Vec<ShellFlow>,
    pub notes: Vec<String>,
}

pub(crate) type Shared = Rc<RefCell<Outbox>>;

const WIDTH_XS: f64 = 360.0;
const ANCHORS: [(Anchor, &str); 3] = [
    (Anchor::Start, "Anchor to In Point"),
    (Anchor::End, "Anchor to Out Point"),
    (Anchor::Stretch, "Scale to Clip Length"),
];

fn index(seen: &Captured, id: &str) -> Option<usize> {
    match seen.borrow().get(id)? {
        FormValue::Index(i) => usize::try_from(*i).ok(),
        _ => None,
    }
}

fn flag(seen: &Captured, id: &str) -> bool {
    matches!(seen.borrow().get(id), Some(FormValue::Bool(true)))
}

fn note(out: &Shared, line: impl Into<String>) -> Option<(ShellDialog, Captured)> {
    out.borrow_mut().notes.push(line.into());
    None
}

fn first_clip_name(session: &EditorSession, fallback: &str) -> String {
    session.single_selected_clip().map_or_else(|| fallback.to_string(), |c| c.name.clone())
}

/// One unlabeled name field, Save / Cancel; `run` gets the trimmed name (`initial` for a blank field) on Save.
fn ask_name(
    title: &str,
    informative: &str,
    initial: &str,
    run: impl FnOnce(String) + 'static,
) -> (ShellDialog, Captured) {
    let mut form = ShellForm::new(vec![FormRow::field("name", "", initial)]);
    form.begin_editing("name");
    let seen = capture(&mut form);
    let (reported, start) = (Rc::clone(&seen), initial.to_string());
    let d = dialog_labeled("Save", title, informative, form, move |r| {
        if r == SQDialogResponse::FIRST {
            run(PresetSaveSheet::resolved_name(&text(&reported, "name").unwrap_or_default(), &start));
        }
    });
    (d, seen)
}

fn queue_save(out: &Shared, make: MakePreset, done: String, failure: &'static str) {
    out.borrow_mut().saves.push(Save { make, done, failure });
}

fn clip_preset(session: &EditorSession, answers: &Answers, out: &Shared) -> Option<(ShellDialog, Captured)> {
    let Some(clip) = session.single_selected_clip() else {
        return note(out, "Select one clip to save its settings as a preset.");
    };
    if session.preset_from_selected_clip(Anchor::Start).is_none() {
        return note(out, format!("\u{201c}{}\u{201d} has no Motion, Opacity or effect changes to save.", clip.name));
    }
    let fallback = clip.name.clone();
    let mut form = ShellForm::new(vec![
        FormRow::field("name", "", &fallback),
        FormRow::popup("anchor", "", &ANCHORS.map(|a| a.1), 0),
    ]);
    form.begin_editing("name");
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let (answers, out) = (Rc::clone(answers), Rc::clone(out));
    let d = dialog_labeled(
        "Save",
        "Save as Preset",
        "Saves Transform, Opacity and effects with their keyframes and easing.",
        form,
        move |r| {
            if r != SQDialogResponse::FIRST {
                return;
            }
            let name = PresetSaveSheet::resolved_name(&text(&reported, "name").unwrap_or_default(), &fallback);
            let anchor = ANCHORS[index(&reported, "anchor").unwrap_or(0).min(ANCHORS.len() - 1)].0;
            answers.borrow_mut().push(Box::new(move |s| {
                let Some(preset) = s.preset_from_selected_clip(anchor) else { return };
                let done = format!("Saved preset \u{201c}{name}\u{201d}.");
                let make: MakePreset =
                    Box::new(move |id, at| EditorSession::effect_preset_item(&name, &preset, id, at));
                queue_save(&out, make, done, "The preset could not be saved: ");
            }));
        },
    );
    Some((d, seen))
}

fn transition_preset(session: &mut EditorSession, id: Id, out: &Shared) -> Option<(ShellDialog, Captured)> {
    session.select_transition(Some(id), false);
    let preset = session.preset_from_selected_transition()?;
    let out = Rc::clone(out);
    let initial = preset.kind.name().to_string();
    Some(ask_name(
        "Save Transition as Preset",
        "Kind, length, alignment, easing and style are saved to the Library (Presets, Transitions).",
        &initial,
        move |name| {
            let done = format!("Saved transition preset \u{201c}{name}\u{201d}.");
            let make: MakePreset =
                Box::new(move |id, at| EditorSession::transition_preset_item(&name, &preset, id, at));
            queue_save(&out, make, done, "The preset could not be saved: ");
        },
    ))
}

fn title_block(session: &mut EditorSession, out: &Shared) -> Option<(ShellDialog, Captured)> {
    let Some(block) = session.title_block_from_selection() else {
        let line = session.last_error().unwrap_or("Select the title clips first.").to_string();
        return note(out, line);
    };
    let out = Rc::clone(out);
    let initial = first_clip_name(session, "Title");
    Some(ask_name(
        "Save to Library",
        "Saves the selected clips with their animations as a title block.",
        &initial,
        move |name| {
            let done = format!("Saved title block \u{201c}{name}\u{201d}.");
            let make: MakePreset = Box::new(move |id, at| block.preset_item(&name, id, at).map_err(|e| e.to_string()));
            queue_save(&out, make, done, "The title block could not be saved: ");
        },
    ))
}

fn title_template(session: &mut EditorSession, answers: &Answers, out: &Shared) -> Option<(ShellDialog, Captured)> {
    let fallback = first_clip_name(session, "Title");
    if session.title_template_from_selection(&fallback).is_none() {
        let line = session.last_error().unwrap_or("Select the title layers first.").to_string();
        return note(out, line);
    }
    let (answers, out) = (Rc::clone(answers), Rc::clone(out));
    Some(ask_name(
        "Save as Template",
        "Saves the selected layers as a template with editable text, color, font and size, and keeps the intro and \
         outro when the clip is trimmed.",
        &fallback,
        move |name| {
            answers.borrow_mut().push(Box::new(move |s| {
                let Some(template) = s.title_template_from_selection(&name) else { return };
                let Ok(value) = serde_json::to_value(&template) else { return };
                let pending = PendingTemplate { name, template: value };
                // Inside the selected video the preview is the Program frame (the root renders it); elsewhere there is none.
                if s.playhead_is_inside_selected_video() {
                    s.stop_playback();
                    out.borrow_mut().templates.push(pending);
                } else {
                    out.borrow_mut().saves.push(pending.into_save(None, false));
                }
            }));
        },
    ))
}

/// "Tone Settings": frequency in Hz and level in dB, one undo step.
fn tone(session: &mut EditorSession, id: Id, answers: &Answers) -> Option<(ShellDialog, Captured)> {
    session.select(BTreeSet::from([id]), BTreeSet::new());
    let (_, spec) = session.selected_tone()?;
    let (hz, db) = (spec.frequency_hz(), spec.level_db());
    let unit = |id: &str, label: &str, v: f64, unit: &str| FormRow::Field {
        id: id.into(),
        label: label.into(),
        value: v.to_string(),
        unit: unit.into(),
    };
    let mut form = ShellForm::new(vec![unit("freq", "Frequency", hz, "Hz"), unit("level", "Level", db, "dB")]);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let answers = Rc::clone(answers);
    let mut d = dialog_labeled("OK", "Tone Settings", "Sine tone, 1 kHz at \u{2212}12 dB by default", form, move |r| {
        if r == SQDialogResponse::FIRST {
            let spec =
                ToneSpec::from_hz_db(number(&reported, "freq").unwrap_or(hz), number(&reported, "level").unwrap_or(db));
            answers.borrow_mut().push(Box::new(move |s| s.set_tone(id, &spec)));
        }
    });
    d.width = WIDTH_XS;
    Some((d, seen))
}

/// "New Color Matte": name, color, duration; the matte lands at the playhead.
fn color_matte(session: &EditorSession, answers: &Answers, out: &Shared) -> Option<(ShellDialog, Captured)> {
    if session.active_timeline().is_none() {
        return note(out, "Open a sequence first.");
    }
    let c = ColorMatteColor::DEFAULT;
    let start = SQColorValue::from_rgb(f64::from(c.r) / 255.0, f64::from(c.g) / 255.0, f64::from(c.b) / 255.0, 1.0);
    let mut form = ShellForm::new(vec![
        FormRow::field("name", "Name", "Color Matte"),
        FormRow::Color { id: "color".into(), label: "Color".into(), value: start },
        FormRow::SliderNumber {
            label: "Duration".to_string(),
            field: NumberField {
                step: 0.5,
                decimals: 1,
                unit: "s".to_string(),
                default_value: Some(5.0),
                ..NumberField::new("duration", 5.0, 0.1..=3600.0)
            },
        },
    ]);
    form.slider_track_width = Some(110.0);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let (answers, out) = (Rc::clone(answers), Rc::clone(out));
    let mut d = dialog_labeled(
        "Add",
        "New Color Matte",
        "A flat color layer for when there is no video. It goes on the timeline at the playhead.",
        form,
        move |r| {
            if r != SQDialogResponse::FIRST {
                return;
            }
            let name = PresetSaveSheet::resolved_name(&text(&reported, "name").unwrap_or_default(), "Color Matte");
            let color = text(&reported, "color").and_then(|h| TimelineEditorForms::matte_color(&h)).unwrap_or(c);
            let duration = TimelineEditorForms::matte_duration(number(&reported, "duration").unwrap_or(5.0));
            answers.borrow_mut().push(Box::new(move |s| {
                s.stop_playback();
                if s.add_color_matte(color, &name, None, None, duration).is_none() {
                    let line = s.last_error().unwrap_or("The color matte could not be added.").to_string();
                    out.borrow_mut().notes.push(line);
                }
            }));
        },
    );
    d.width = WIDTH_XS;
    Some((d, seen))
}

fn angles_clip(session: &EditorSession, out: &Shared) -> Option<(ShellDialog, Captured)> {
    let clips = session.angle_selection();
    let angles = session.angle_candidates_clips(&clips);
    if angles.len() < 2 {
        return note(out, "Select at least two clips, in the timeline or in the Project panel.");
    }
    let names: Vec<String> = session.project().timelines.iter().map(|t| t.name.clone()).collect();
    let fallback = AngleSyncMode::default_name(&names);
    let syncs = AngleSyncMode::choices(&angles, true);
    let sync_titles: Vec<&str> = syncs.iter().map(|m| m.title()).collect();
    let sound: Vec<String> = angles.iter().enumerate().map(|(i, a)| format!("{} {}", i + 1, a.name)).collect();
    let sound_refs: Vec<&str> = sound.iter().map(String::as_str).collect();
    let mut form = ShellForm::new(vec![
        FormRow::field("name", "Name", &fallback),
        FormRow::popup("sync", "Sync by", &sync_titles, 0),
        FormRow::popup("sound", "Sound from", &sound_refs, AngleSyncMode::default_audio_angle(&angles) as i64),
        FormRow::check("follows", "Audio Follows Video", false),
    ]);
    let seen = capture(&mut form);
    let reported = Rc::clone(&seen);
    let out = Rc::clone(out);
    let informative =
        format!("{} angles become one clip. Cut it and choose an angle per piece with the keys 1 to 9.", angles.len());
    let d = dialog_labeled("OK", "Create Angles Clip", &informative, form, move |r| {
        if r != SQDialogResponse::FIRST {
            return;
        }
        let name = PresetSaveSheet::resolved_name(&text(&reported, "name").unwrap_or_default(), &fallback);
        let sync = syncs[index(&reported, "sync").unwrap_or(0).min(syncs.len() - 1)];
        let sound = index(&reported, "sound").unwrap_or(0);
        let follows = flag(&reported, "follows");
        // The sync may read the files: the root runs the rest as a flow (`ShellHost::create_angles`).
        out.borrow_mut().flows.push(ShellFlow::CreateAngles { clips: clips.clone(), name, sync, sound, follows });
    });
    Some((d, seen))
}

/// "Save Effects as Preset" from the Graphics panel: a name, then the Library.
pub(crate) fn effect_preset(preset: EffectPreset, out: &Shared) -> ShellDialog {
    let out = Rc::clone(out);
    ask_name(
        "Save Effects as Preset",
        "Saves the layer's effects with their keyframes and easing.",
        "Effect Preset",
        move |name| {
            let done = format!("Saved preset \u{201c}{name}\u{201d}.");
            let make: MakePreset = Box::new(move |id, at| EditorSession::effect_preset_item(&name, &preset, id, at));
            queue_save(&out, make, done, "The preset could not be saved: ");
        },
    )
    .0
}

/// The dialog for an editor request this module owns; `None` for every other request and for a refused one (its status
/// line waits in the outbox).
pub(crate) fn editor_dialog(
    session: &mut EditorSession,
    r: &TimelineEditorRequest,
    answers: &Answers,
    out: &Shared,
) -> Option<ShellDialog> {
    editor_parts(session, r, answers, out).map(|(d, _)| d)
}

/// [`editor_dialog`] and the values its form reported (tests fill them in).
pub(crate) fn editor_parts(
    session: &mut EditorSession,
    r: &TimelineEditorRequest,
    answers: &Answers,
    out: &Shared,
) -> Option<(ShellDialog, Captured)> {
    match r {
        TimelineEditorRequest::ToneClip(id) => tone(session, *id, answers),
        TimelineEditorRequest::SaveClipPreset => clip_preset(session, answers, out),
        TimelineEditorRequest::SaveTransitionPreset(id) => transition_preset(session, *id, out),
        TimelineEditorRequest::SaveTitleBlock => title_block(session, out),
        TimelineEditorRequest::SaveTemplate => title_template(session, answers, out),
        TimelineEditorRequest::NewColorMatte => color_matte(session, answers, out),
        TimelineEditorRequest::CreateAnglesClip => angles_clip(session, out),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
