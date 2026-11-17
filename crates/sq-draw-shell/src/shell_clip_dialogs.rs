// Swift: ShellClipDialogs.swift
//! Clip > Audio Gain (the Mac `AudioGainDialog.makeView`), Clip > Speed/Duration (the Mac `SpeedDurationSheet`) and the
//! other Clip and Sequence commands that open a dialog and need nothing but the session.

use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_flow_env::ShellTool;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Link, NumberField, Row, ShellForm};
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use sq_core_audio::audio_gain::AudioGain;
use sq_core_audio::audio_gain_plan::{AudioGainChoice, AudioGainItem, AudioGainPlan};
use sq_core_edit::timeline_speed::SpeedChange;
use sq_core_model::{AudioTag, TimeInterpolation};
use sq_core_time::{Id, Time};
use sq_editor_session::{SpeedDialogModel, TitleBuilder, TransitionDefaults, TransitionScope};
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::timecode::Timecode;
use std::cell::RefCell;
use std::rc::Rc;

/// Clip > Audio Gain (the Mac `AudioGainDialog.makeView`): five radio rows, each with its number field, the loudness note
/// and a live warning (yellow) under them. Normalize Loudness is off until a loudness was measured.
pub struct ShellAudioGain;

impl ShellAudioGain {
    const TITLES: [&'static str; 5] =
        ["Set Gain to", "Adjust Gain by", "Normalize Max Peak to", "Normalize All Peaks to", "Normalize Loudness to"];
    const FIELD_IDS: [&'static str; 5] = ["set", "adjust", "peak", "peaks", "lufs"];
    /// The warning note's row (after the radio group and the loudness note).
    const WARNING_ROW: usize = 2;

    /// The form for the clips `items`; `target` is the loudness target, `ready` false while no loudness was measured.
    pub fn form(items: &[AudioGainItem], target: f64, ready: bool) -> ShellForm {
        let fields: Vec<NumberField> = Self::FIELD_IDS
            .iter()
            .enumerate()
            .map(|(n, id)| {
                if n == 4 {
                    NumberField {
                        id: (*id).into(),
                        value: target,
                        range: -40.0..=0.0,
                        step: 0.5,
                        decimals: 1,
                        unit: "LUFS".into(),
                        default_value: Some(target),
                    }
                } else {
                    NumberField {
                        id: (*id).into(),
                        value: if n == 0 && items.len() == 1 { (items[0].gain_db * 10.0).round() / 10.0 } else { 0.0 },
                        range: AudioGain::MIN_GAIN_DB..=AudioGain::MAX_GAIN_DB,
                        step: 0.1,
                        decimals: 1,
                        unit: "dB".into(),
                        default_value: Some(0.0),
                    }
                }
            })
            .collect();
        let mut rows = vec![
            Row::RadioNumbers {
                id: "mode".into(),
                options: Self::TITLES.iter().map(|s| (*s).to_string()).collect(),
                selected: 1,
                fields,
            },
            Row::Text(AudioGainPlan::loudness_text(items, false)),
            Row::Text(" ".to_string()),
        ];
        if let Some(n) = AudioGainPlan::peak_mode_note(items.len()) {
            rows.push(Row::Text(n.to_string()));
        }
        let mut form = ShellForm::new(rows);
        // the Mac loudness note has a 4 pt top inset
        form.extra_gap_before.insert(1, 2.0);
        if !ready {
            form.disabled.insert("lufs".to_string());
        }
        let items = items.to_vec();
        let again = move |form: &mut ShellForm| {
            let w = Self::choice(&*form).and_then(|c| AudioGainPlan::warning_text(c, &items));
            form.set_note(Self::WARNING_ROW, w.as_deref().unwrap_or(" "), w.is_some(), false, false);
        };
        again(&mut form);
        form.on_change = Some(Box::new(move |form, _, _| again(form)));
        form
    }

    /// The picked mode with its field's value.
    pub fn choice(form: &dyn DialogForm) -> Option<AudioGainChoice> {
        let i = usize::try_from(form.index("mode")?).ok().filter(|i| *i < Self::FIELD_IDS.len())?;
        Some(AudioGainPlan::choice(i, form.number(Self::FIELD_IDS[i]).unwrap_or(0.0)))
    }
}

/// Clip > Speed/Duration (the Mac `SpeedDurationSheet`) on the shared `SpeedDialogModel`: Speed %, Duration timecode,
/// the link between them, Frames (video), Reverse, Keep Pitch (audio) and Move Later Clips.
pub struct ShellSpeedDuration;

/// The form and the model its changes go through.
pub struct SpeedState {
    /// The dialog's form.
    pub form: ShellForm,
    /// The model the form edits.
    pub model: Rc<RefCell<SpeedDialogModel>>,
}

impl ShellSpeedDuration {
    const INTERPOLATIONS: [TimeInterpolation; 3] =
        [TimeInterpolation::FrameSampling, TimeInterpolation::FrameBlend, TimeInterpolation::OpticalFlow];

    /// Frames in `t` (`SpeedDurationSheet.frameCount`).
    pub fn frame_count(t: Time, fd: Time) -> f64 {
        (t.value() * fd.timescale()) as f64 / (t.timescale() * fd.value()) as f64
    }

    /// The form for `model`.
    pub fn make(model: SpeedDialogModel, timecode: Timecode) -> SpeedState {
        // `SpeedDurationSheet.buildView`: Speed % and Duration (a frame count shown as timecode) as scrub fields with the link
        // beside them, Frames for video, the three checks; Duration and the link are off for several clips, Keep Pitch
        // without audio.
        let fd = model.frame_duration();
        let limit = *SpeedDialogModel::PERCENT_RANGE.end();
        let mut rows = vec![
            Row::Number {
                label: "Speed".into(),
                field: NumberField {
                    id: "speed".into(),
                    value: model.percent(),
                    range: -limit..=limit,
                    step: 1.0,
                    decimals: 1,
                    unit: "%".into(),
                    default_value: Some(100.0),
                },
            },
            Row::Number {
                label: "Duration".into(),
                field: NumberField {
                    id: "duration".into(),
                    value: Self::frame_count(model.duration(), fd),
                    range: 1.0..=10_000_000.0,
                    step: 1.0,
                    decimals: 0,
                    unit: String::new(),
                    default_value: Some(Self::frame_count(model.duration(), fd)),
                },
            },
        ];
        if model.has_video() {
            rows.push(Row::Popup {
                id: "frames".into(),
                label: "Frames".into(),
                options: Self::INTERPOLATIONS.iter().map(|i| i.title().to_string()).collect(),
                selected: Self::INTERPOLATIONS.iter().position(|i| *i == model.time_interpolation).unwrap_or(0) as i64,
            });
        }
        rows.push(Row::check("reverse", "Reverse", model.reversed));
        rows.push(Row::check("pitch", "Keep Pitch", model.keeps_pitch));
        rows.push(Row::check("ripple", "Move Later Clips", model.ripple));
        let mut form = ShellForm::new(rows);
        form.link = Some(Link { id: "link".into(), fields: vec!["speed".into(), "duration".into()] });
        // art.html 23
        form.control_widths.extend([
            ("speed".to_string(), 87.0),
            ("duration".to_string(), 118.0),
            ("frames".to_string(), 198.0),
        ]);
        form.show_unit_inside("speed");
        form.set("link", FormValue::Bool(model.is_linked));
        form.set_format(
            "duration",
            Box::new(move |frames| timecode.format(Time::new(frames.round() as i64 * fd.value(), fd.timescale()))),
            Box::new(move |text| timecode.parse(text).map(|t| Self::frame_count(t, fd))),
        );
        if !model.can_edit_duration() {
            form.disabled.insert("duration".to_string());
        }
        if !model.has_audio() {
            form.disabled.insert("pitch".to_string());
        }
        let model = Rc::new(RefCell::new(model));
        let m = Rc::clone(&model);
        form.on_change = Some(Box::new(move |form, id, v| {
            let mut model = m.borrow_mut();
            match (id, v) {
                ("speed", FormValue::Number(p)) => model.set_percent(*p),
                ("duration", FormValue::Number(f)) => {
                    model.set_duration(Time::new(f.round() as i64 * fd.value(), fd.timescale()));
                }
                ("link", FormValue::Bool(b)) => model.is_linked = *b,
                ("frames", FormValue::Index(i)) => {
                    if let Some(t) = usize::try_from(*i).ok().and_then(|i| Self::INTERPOLATIONS.get(i)) {
                        model.time_interpolation = *t;
                    }
                }
                ("reverse", FormValue::Bool(b)) => model.reversed = *b,
                ("pitch", FormValue::Bool(b)) => model.keeps_pitch = *b,
                ("ripple", FormValue::Bool(b)) => model.ripple = *b,
                _ => return,
            }
            Self::refresh(form, &model);
        }));
        SpeedState { form, model }
    }

    /// Writes the model back into the rows (a typed speed changes the duration and the other way round).
    fn refresh(form: &mut ShellForm, model: &SpeedDialogModel) {
        form.set("speed", FormValue::Number(model.percent()));
        form.set("duration", FormValue::Number(Self::frame_count(model.duration(), model.frame_duration())));
        form.set("reverse", FormValue::Bool(model.reversed));
    }

    /// The change to apply on OK; `None` when nothing changed.
    pub fn answer(model: &SpeedDialogModel) -> Option<SpeedChange> {
        model.has_changes().then(|| model.change())
    }
}

impl ShellHost {
    /// Clip > Speed/Duration (Ctrl+R): one undo step for the selected clips.
    pub async fn speed_duration<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((d, model))) = h.with(|r| {
            let p = r.shell_parts();
            let (Some(model), Some(tl)) = (p.session.speed_dialog_model(), p.session.active_timeline()) else {
                p.shell.flash("Select a clip first.");
                return None;
            };
            let fd = tl.frame_duration();
            let drop_frame = fd == Time::new(1001, 30000) || fd == Time::new(1001, 60000);
            let s = ShellSpeedDuration::make(model, Timecode::new(fd, drop_frame));
            let mut d = ShellDialog::new("Speed", "");
            d.form = Some(Box::new(s.form));
            d.add_button("OK", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((d, s.model))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let Some(change) = ShellSpeedDuration::answer(&model.borrow()) else { return };
        let _ = h.with(|r| {
            let session = r.shell_parts().session;
            session.stop_playback();
            session.apply_speed(change);
        });
    }

    /// Clip > Audio Gain (G), the Mac `AudioGainDialog`: Set / Adjust / Normalize Max Peak / Normalize All Peaks /
    /// Normalize Loudness. Loudness is measured before the dialog opens (the Mac measures while it is up).
    pub async fn audio_gain<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((clips, mut items, jobs))) = h.with(|r| {
            let p = r.shell_parts();
            let clips = p.session.audio_gain_targets();
            if clips.is_empty() {
                p.shell.flash("Select an audio clip first.");
                return None;
            }
            let items: Vec<AudioGainItem> = clips
                .iter()
                .map(|c| AudioGainItem {
                    id: c.id,
                    name: c.name.clone(),
                    gain_db: c.audio_gain_db,
                    peak: p.shell.peak_of(c),
                    volume: AudioGainPlan::volume_peak(c),
                    lufs: None,
                })
                .collect();
            p.shell.flash("Measuring loudness...");
            let jobs: Vec<_> = clips.iter().map(|c| p.session.loudness_job(std::slice::from_ref(c))).collect();
            Some((clips, items, jobs))
        }) else {
            return;
        };
        let Some(measured) = Self::measure_loudness_jobs(&h, jobs).await else { return };
        let Some(Some((d, items))) = h.with(|r| {
            let p = r.shell_parts();
            for (item, lufs) in items.iter_mut().zip(&measured) {
                item.lufs = *lufs;
            }
            let target = p
                .session
                .active_timeline()
                .map_or_else(|| AudioTag::Dialogue.target_lufs(), |t| AudioGain::target_lufs_for_clips(&clips, t));
            let ready = items.iter().any(|i| i.lufs.unwrap_or(AudioGain::SILENT_LUFS) > AudioGain::SILENT_LUFS);
            let form = ShellAudioGain::form(&items, target, ready);
            // art.html 24: the clip name is a dim subtitle beside the title, the peak line is the body.
            let info = AudioGainPlan::info_text(&items).replace("Peak amplitude: -", "Peak amplitude: \u{2212}");
            let (head, body) = info.split_once('\n').map_or((info.as_str(), ""), |(a, b)| (a, b));
            let mut d = ShellDialog::new("Audio Gain", body);
            d.header_subtitle = Some(head.to_string());
            d.form = Some(Box::new(form));
            d.add_button("OK", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((d, items))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(choice) = ShellAudioGain::choice(&*form) else { return };
            let gains = AudioGainPlan::plan(choice, &items);
            if gains.is_empty() {
                p.shell.flash("The audio is silent or not analyzed yet.");
                return;
            }
            p.session.set_audio_gain(&gains);
            if gains.len() < items.len() {
                let n = (items.len() - gains.len()) as i64;
                p.shell.emit(ShellEvent::Status(SQL10n::plural(
                    n,
                    "%@ clip was skipped: silent or not analyzed yet.",
                    "%@ clips were skipped: silent or not analyzed yet.",
                )));
            }
            if !AudioGainPlan::clipping_clips(choice, &items).is_empty() {
                let w = AudioGainPlan::warning_text(choice, &items).unwrap_or_default();
                p.shell.flash(&w);
            }
        });
    }

    /// Clip > Match Loudness: each selected audio clip to its role's target (the Mac `requestMatchLoudness`).
    pub fn match_loudness(&mut self, cx: &mut ShellCx) {
        let clips = cx.session.selected_audio_clips();
        if clips.is_empty() {
            self.flash("Select an audio clip first.");
            return;
        }
        self.start_flow(ShellFlow::Tool(ShellTool::MatchLoudness));
    }

    /// Clip > Make Subclip (Ctrl+U) from the one media item selected in the Project panel (the Mac takes the Source
    /// monitor's clip first; that one is the host's, which runs before this).
    pub fn make_subclip(&mut self, cx: &mut ShellCx) {
        let ids: Vec<Id> = self
            .project_selection
            .iter()
            .filter_map(|r| if let sq_core_model::BinItemRef::Media(id) = r { Some(*id) } else { None })
            .collect();
        let [media] = ids.as_slice() else {
            self.flash("Open a clip in the Source view and set In and Out first.");
            return;
        };
        if cx.session.make_subclip(*media, None).is_none() {
            let line = cx.session.last_error().map_or_else(|| "Could not make a subclip.".to_string(), str::to_string);
            self.flash(&line);
        } else {
            self.flash("Subclip added to the Project panel.");
        }
    }

    /// Sequence > Add Title (Ctrl+T): the title lines at the playhead.
    pub fn add_title(&mut self, cx: &mut ShellCx) {
        cx.session.stop_playback();
        let env = &self.flow_env;
        let Some(store) = env.services.look_store() else {
            self.flash(crate::shell_platform_text::ShellPlatformText::not_available());
            return;
        };
        let ids = cx.session.add_title(None, TitleBuilder::DEFAULT_DURATION, &*env.settings, store);
        if ids.is_empty() {
            if let Some(e) = cx.session.last_error().map(str::to_string) {
                self.flash(&e);
            }
            return;
        }
        let at = cx.session.playhead();
        cx.session.seek(at);
        self.flash("Title added. Double-click a line to type.");
    }

    /// Apply Video / Audio Transition and Apply Default Transitions to Selection, at the timeline's selected edits.
    pub fn apply_transitions(&mut self, cx: &mut ShellCx, scope: TransitionScope) {
        cx.session.stop_playback();
        let edges = cx.hooks.edge_selection();
        let defaults = TransitionDefaults::load(&self.bytes_view());
        let n = cx.session.apply_default_transitions_with_roles(
            scope,
            edges.as_ref(),
            None,
            &defaults,
            &self.audio_role_defaults,
        );
        if n > 0 {
            self.flash(&if n == 1 { "Transition applied.".to_string() } else { format!("{n} transitions applied.") });
        } else if let Some(m) = cx.session.last_error().map(str::to_string) {
            self.flash(&m);
        }
    }

    /// The commands of the Mac `execute` that open a dialog and need nothing but the session (and the hooks above).
    /// True when the command is one of these.
    pub(crate) fn perform_dialog_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        let tool = match c {
            C::NewSequence => {
                self.start_flow(ShellFlow::NewSequence);
                return true;
            }
            C::ImportProject => {
                self.start_flow(ShellFlow::ImportProject);
                return true;
            }
            C::SequenceSettings | C::ProjectLiveDucking => {
                self.start_flow(ShellFlow::SequenceSettings);
                return true;
            }
            C::ProjectNotes => {
                self.start_flow(ShellFlow::ProjectNotes);
                return true;
            }
            C::EditMarker => {
                if let Some(id) = cx.session.marker_at_playhead() {
                    self.start_flow(ShellFlow::EditMarker(id));
                }
                return true;
            }
            C::AddAndEditMarker | C::AddMarker => {
                // M on a marker (or Add and Edit) opens the marker dialog; a plain M on empty time only adds one.
                if let Some(m) = cx.session.mark_at_playhead()
                    && (m.open_edit || c == C::AddAndEditMarker)
                {
                    self.start_flow(ShellFlow::EditMarker(m.id));
                }
                return true;
            }
            C::GoToTimecode => {
                self.go_to_timecode_command(cx);
                return true;
            }
            C::NewTone | C::ToneSettings => {
                self.start_flow(ShellFlow::Tone { editing: c == C::ToneSettings });
                return true;
            }
            C::PunchInCuts => {
                self.start_flow(ShellFlow::PunchInCuts);
                return true;
            }
            C::PasteAttributes => {
                self.start_flow(ShellFlow::PasteSettings);
                return true;
            }
            C::Find => ShellTool::Find,
            C::SpeedDuration => ShellTool::SpeedDuration,
            C::AudioGain => ShellTool::AudioGain,
            C::MatchLoudness => {
                self.match_loudness(cx);
                return true;
            }
            C::MakeSubclip => {
                self.make_subclip(cx);
                return true;
            }
            C::AddTitle => {
                self.add_title(cx);
                return true;
            }
            C::ApplyVideoTransition => {
                self.apply_transitions(cx, TransitionScope::Video);
                return true;
            }
            C::ApplyAudioTransition => {
                self.apply_transitions(cx, TransitionScope::Audio);
                return true;
            }
            C::ApplyDefaultTransitions => {
                self.apply_transitions(cx, TransitionScope::Both);
                return true;
            }
            C::ExportEDL | C::ExportFCPXML | C::ExportFinalCutXML | C::ExportOpenTimelineIO => {
                ShellTool::ExportInterchange(c)
            }
            C::ImportTimeline => ShellTool::ChooseAndImportTimeline,
            C::ImportPremiereProject => ShellTool::ChooseAndImportPremiereProject,
            C::CheckCuts => ShellTool::CheckCuts,
            C::Anonymize => {
                self.anonymize_command(cx);
                return true;
            }
            C::AutoDuck => ShellTool::AutoDuck,
            C::RemoveSilences => ShellTool::RemoveSilences,
            C::SyncAudioToReference => ShellTool::SyncAudio,
            _ => return self.perform_view_command(cx, c),
        };
        self.start_flow(ShellFlow::Tool(tool));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(gain_db: f64, peak: Option<f64>) -> AudioGainItem {
        AudioGainItem { id: Id::fixed(1), name: "A".into(), gain_db, peak, volume: 1.0, lufs: None }
    }

    #[test]
    fn frame_count_is_exact_for_whole_frames() {
        let fd = Time::new(1001, 30000);
        assert_eq!(ShellSpeedDuration::frame_count(Time::new(1001 * 24, 30000), fd), 24.0);
        assert_eq!(ShellSpeedDuration::frame_count(Time::new(2, 1), Time::new(1, 25)), 50.0);
    }

    /// The Speed dialog as `speed_duration` builds it, over one 2 s clip.
    fn speed_dialog() -> (ShellDialog, SpeedState) {
        use sq_core_model::{Clip, TrackKind};
        use sq_core_time::TimeRange;
        let fd = Time::new(1, 25);
        let clip = Clip::new(
            Id::fixed(1),
            "c",
            Id::fixed(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::ZERO,
        );
        let model = SpeedDialogModel::new(&[clip], fd).expect("one clip");
        let s = ShellSpeedDuration::make(model, Timecode::new(fd, false));
        let mut d = ShellDialog::new("Speed", "");
        d.add_button("OK", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        (d, s)
    }

    #[test]
    fn typing_into_a_fresh_speed_dialog_replaces_the_speed_and_return_answers() {
        use sq_draw::{InputEvent, InputKey, InputModifiers, UiCx};
        let (mut d, s) = speed_dialog();
        let (form, model) = (s.form, Rc::clone(&s.model));
        d.form = Some(Box::new(form));
        let got: Rc<RefCell<Vec<SQDialogResponse>>> = Rc::default();
        let g = Rc::clone(&got);
        d.completion = Some(Box::new(move |r| g.borrow_mut().push(r)));
        let tm = crate::tests::measure();
        d.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 1000.0, 800.0), &tm);
        let mut cx = UiCx::new();
        let mut send = |d: &mut ShellDialog, k: InputKey| {
            d.handle(&InputEvent::KeyDown { key: k, modifiers: InputModifiers::NONE }, 1.0, &tm, &mut cx);
        };
        for ch in "200".chars() {
            send(&mut d, InputKey::Character(ch));
        }
        send(&mut d, InputKey::Enter);
        assert_eq!(model.borrow().percent(), 200.0);
        assert_eq!(*got.borrow(), vec![SQDialogResponse::FIRST]);
    }

    #[test]
    fn audio_gain_form_starts_on_adjust_with_the_single_clips_gain_in_set() {
        let form = ShellAudioGain::form(&[item(-3.04, Some(0.5))], -14.0, false);
        assert_eq!(form.index("mode"), Some(1));
        assert_eq!(form.number("set"), Some(-3.0));
        assert_eq!(form.number("lufs"), Some(-14.0));
        assert!(form.disabled.contains("lufs"));
        assert_eq!(ShellAudioGain::choice(&form), Some(AudioGainChoice::Adjust(0.0)));
    }

    #[test]
    fn the_choice_reads_the_picked_rows_field_and_warns_when_it_clips() {
        let items = [item(0.0, Some(1.0))];
        let mut form = ShellAudioGain::form(&items, -14.0, true);
        assert!(matches!(&form.rows()[ShellAudioGain::WARNING_ROW], Row::Text(t) if t == " "));
        form.set("mode", FormValue::Index(0));
        form.set("set", FormValue::Number(6.0));
        let choice = ShellAudioGain::choice(&form);
        assert_eq!(choice, Some(AudioGainChoice::Set(6.0)));
        assert_eq!(
            AudioGainPlan::warning_text(AudioGainChoice::Set(6.0), &items).as_deref(),
            Some("1 clip would peak above 0 dB.")
        );
    }
}
