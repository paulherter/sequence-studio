// Swift: ShellSequenceDialogs.swift
//! New Sequence and Sequence Settings, translated from the Mac `SequenceSettingsSheet`: Name, Preset, Frame Size, Pixel
//! Shape, Frame Rate, Sample Rate; Sequence Settings adds Channels, Live Ducking, Timeline mode, Starts at, Display and
//! Preview Quality. The rules (preset follows the fields, Starts at keeps its time across rate changes) are the Mac ones.
//!
//! Mapping: the Swift `State` class that the form's `onChange` and `canClose` share is an `Rc<RefCell<..>>`; `canClose`
//! cannot read the form the dialog owns, so the form's change reaction keeps a `usable` flag current (the Mac `canConfirm`).

use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{NumberField, Row, ShellForm};
use crate::shell_host::{ShellCx, ShellFlow, ShellHost};
use crate::shell_settings::NumbersView;
use sq_core_audio::{LiveDucking, ToneSpec};
use sq_core_model::sequence_settings::SequenceSettings;
use sq_core_model::{
    ChannelLayout, DeliveryTarget, PixelAspect, ProjectLiveDucking, SequenceFormat, SequencePreviewQuality,
    TimecodeDisplay, TimelineEditMode,
};
use sq_core_project::sequence_format_presets::SequenceFormatPresets;
use sq_core_time::Time;
use sq_editor_session::{
    EditorSession, MonitorQuality, PixelAspectChoices, ProjectLiveDuckingChoice, ProjectLiveDuckingChoices,
};
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::timecode::Timecode;
use sq_uikit::timecode_start_entry::TimecodeStartEntry;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const CUSTOM_TITLE: &str = "Custom";
const QUALITIES: [Option<SequencePreviewQuality>; 4] = [
    None,
    Some(SequencePreviewQuality::Full),
    Some(SequencePreviewQuality::Half),
    Some(SequencePreviewQuality::Quarter),
];

/// What the Sequence Settings form's rules need besides its rows.
pub struct SequenceSettingsState {
    is_new: bool,
    original: SequenceFormat,
    shapes: Vec<PixelAspect>,
    target: Option<DeliveryTarget>,
    start: TimecodeStartEntry,
    ducking_choices: Vec<ProjectLiveDuckingChoice>,
}

/// The form and the state its rules share; `usable` is false while the size or Starts at cannot be taken (the Mac sheet
/// stays open then).
pub struct SequenceSettingsForm {
    /// The rows.
    pub form: ShellForm,
    /// The state the change reaction and the answer share.
    pub state: Rc<RefCell<SequenceSettingsState>>,
    /// Whether OK may close the dialog.
    pub usable: Rc<Cell<bool>>,
}

/// The edited settings and the project's Live Ducking choice (`None` when unchanged).
#[derive(Clone, Debug, PartialEq)]
pub struct SequenceSettingsAnswer {
    /// The settings to apply.
    pub settings: SequenceSettings,
    /// `Some(setting)` when the Live Ducking choice changed (`setting` may be `None` = follow Preferences).
    pub ducking: Option<Option<ProjectLiveDucking>>,
}

/// The titles as the `&str` slice the popup rows take.
fn strs(v: &[String]) -> Vec<&str> {
    v.iter().map(String::as_str).collect()
}

/// `SequenceSettings(name:format:)`: the other fields at their defaults.
fn new_settings(name: String, format: SequenceFormat) -> SequenceSettings {
    SequenceSettings {
        name,
        format,
        delivery_target: None,
        edit_mode: TimelineEditMode::Normal,
        timecode_start: Time::ZERO,
        timecode_display: TimecodeDisplay::Timecode,
        preview_quality: None,
        channel_layout: ChannelLayout::Stereo,
    }
}

/// The Sequence Settings and New Sequence form (Swift `ShellSequenceSettings`).
pub enum ShellSequenceSettings {}

impl ShellSequenceSettings {
    /// "29.97", "24": the rate with trailing zeros dropped (`SequenceSettingsSheet.label`).
    pub(crate) fn rate_label(d: Time) -> String {
        let s = format!("{:.3}", d.timescale() as f64 / d.value() as f64);
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }

    pub(crate) fn sample_rate_title(r: i64) -> String {
        format!("{}.{} kHz", r / 1000, r % 1000 / 100).replace(".0 ", " ")
    }

    /// The form for `settings`; `project_ducking` and `preferred_ducking` fill the Live Ducking choices of an existing
    /// sequence.
    pub fn make(
        settings: &SequenceSettings,
        is_new: bool,
        project_ducking: Option<&ProjectLiveDucking>,
        preferred_ducking: Option<&LiveDucking>,
    ) -> SequenceSettingsForm {
        let format = &settings.format;
        let mut shapes: Vec<PixelAspect> = PixelAspect::PRESETS.to_vec();
        if !shapes.contains(&format.pixel_aspect()) {
            shapes.push(format.pixel_aspect());
        }
        let named = SequenceFormatPresets::named();
        let mut presets = vec![CUSTOM_TITLE.to_string()];
        presets.extend(named.iter().map(|n| n.name.clone()));
        let mut rates: Vec<String> =
            SequenceFormatPresets::FRAME_RATES.iter().map(|r| format!("{} fps", r.label)).collect();
        if SequenceFormatPresets::frame_rate(format.frame_duration).is_none() {
            rates.push(format!("{} fps", Self::rate_label(format.frame_duration)));
        }
        let rate = SequenceFormatPresets::FRAME_RATES
            .iter()
            .position(|r| r.frame_duration == format.frame_duration)
            .unwrap_or(rates.len() - 1);
        let mut audio: Vec<String> =
            SequenceFormatPresets::SAMPLE_RATES.iter().map(|r| Self::sample_rate_title(*r)).collect();
        if !SequenceFormatPresets::SAMPLE_RATES.contains(&format.audio_sample_rate) {
            audio.push(format!("{} Hz", format.audio_sample_rate));
        }
        let sr = SequenceFormatPresets::SAMPLE_RATES
            .iter()
            .position(|r| *r == format.audio_sample_rate)
            .unwrap_or(audio.len() - 1);
        let start = TimecodeStartEntry::new(
            settings.timecode_start,
            format.frame_duration,
            settings.timecode_display == TimecodeDisplay::Frames,
        );
        let ducking = ProjectLiveDuckingChoices::choices(project_ducking, preferred_ducking);
        let dims = 1.0..=SequenceFormatPresets::MAX_DIMENSION as f64;
        let shape_titles: Vec<String> = shapes
            .iter()
            .map(|s| {
                if s.is_square() {
                    "Square".to_string()
                } else {
                    format!("Anamorphic {}", PixelAspectChoices::ratio_text(s))
                }
            })
            .collect();
        let mut rows = vec![
            Row::field("name", "Name", &settings.name),
            Row::Caption("Video".into()),
            Row::popup("preset", "Preset", &strs(&presets), 0),
            Row::Size {
                label: "Frame Size".into(),
                width: NumberField::new("width", format.width as f64, dims.clone()),
                height: NumberField::new("height", format.height as f64, dims),
            },
            Row::popup(
                "shape",
                "Pixel Shape",
                &strs(&shape_titles),
                shapes.iter().position(|s| *s == format.pixel_aspect()).unwrap_or(0) as i64,
            ),
            Row::popup("rate", "Frame Rate", &strs(&rates), rate as i64),
            Row::Caption("Audio".into()),
            Row::popup("audio", "Sample Rate", &strs(&audio), sr as i64),
        ];
        if !is_new {
            let ducking_titles: Vec<String> = ducking.iter().map(|d| d.title.clone()).collect();
            let quality_titles: Vec<String> =
                QUALITIES.iter().map(|q| q.map_or("App setting", |q| monitor_quality(q).title()).to_string()).collect();
            rows.extend([
                Row::segmented(
                    "channels",
                    "Channels",
                    &["Stereo", "Mono"],
                    if settings.channel_layout == ChannelLayout::Mono { 1 } else { 0 },
                    0.0,
                ),
                Row::popup(
                    "ducking",
                    "Live Ducking",
                    &strs(&ducking_titles),
                    ProjectLiveDuckingChoices::index(project_ducking, &ducking) as i64,
                ),
                Row::Caption("Working".into()),
                Row::segmented(
                    "mode",
                    "Timeline",
                    &["Normal", "Fast Cut"],
                    if settings.edit_mode == TimelineEditMode::Magnetic { 1 } else { 0 },
                    0.0,
                ),
                Row::Caption("Timecode".into()),
                Row::field("start", "Starts at", start.text()),
                Row::segmented(
                    "display",
                    "Display",
                    &["Timecode", "Frames"],
                    if settings.timecode_display == TimecodeDisplay::Frames { 1 } else { 0 },
                    0.0,
                ),
                Row::Caption("Preview".into()),
                Row::popup(
                    "quality",
                    "Quality",
                    &strs(&quality_titles),
                    QUALITIES.iter().position(|q| *q == settings.preview_quality).unwrap_or(0) as i64,
                ),
            ]);
        }
        let mut form = ShellForm::new(rows);
        // art.html sequence settings: the hints sit under their control, in the field column, label3.
        if !is_new {
            form.helps.insert("ducking".into(), "Music tracks get quieter while a Dialogue track speaks, in playback and export. Applies to the whole project; a track can opt out in its header menu.".into());
            form.helps.insert(
                "mode".into(),
                "Normal keeps classic tracks. Fast Cut closes gaps on the main track by itself.".into(),
            );
            form.helps.insert(
                "quality".into(),
                "Starts at and Display change only what is shown. Quality is used while this sequence is open.".into(),
            );
        }
        // `SequenceSettingsSheet.accessory`: the short popups and Starts at are 120 wide, Live Ducking 200.
        for id in ["shape", "rate", "audio", "start", "quality"] {
            form.control_widths.insert(id.to_string(), 120.0);
        }
        form.control_widths.insert("ducking".to_string(), 200.0);
        let state = Rc::new(RefCell::new(SequenceSettingsState {
            is_new,
            original: format.clone(),
            shapes,
            target: settings.delivery_target.clone(),
            start,
            ducking_choices: ducking,
        }));
        let usable = Rc::new(Cell::new(true));
        Self::sync_preset(&state.borrow(), &mut form);
        let (st, ok, seed) = (Rc::clone(&state), Rc::clone(&usable), settings.clone());
        form.on_change = Some(Box::new(move |form, id, v| {
            {
                let mut state = st.borrow_mut();
                match id {
                    "preset" => {
                        let FormValue::Index(i) = v else { return };
                        let named = SequenceFormatPresets::named();
                        let Some(n) = usize::try_from(*i).ok().filter(|i| *i > 0).and_then(|i| named.get(i - 1)) else {
                            return;
                        };
                        state.target = n.delivery_target.clone();
                        form.set("width", FormValue::Number(n.format.width as f64));
                        form.set("height", FormValue::Number(n.format.height as f64));
                        if let Some(r) = SequenceFormatPresets::FRAME_RATES
                            .iter()
                            .position(|r| r.frame_duration == n.format.frame_duration)
                        {
                            form.set("rate", FormValue::Index(r as i64));
                        }
                        Self::refresh_start(&mut state, form);
                    }
                    "width" | "height" | "shape" => Self::sync_preset(&state, form),
                    "rate" => {
                        Self::sync_preset(&state, form);
                        Self::refresh_start(&mut state, form);
                    }
                    "display" => Self::refresh_start(&mut state, form),
                    "start" => {
                        let text = form.text("start").unwrap_or_default();
                        state.start.set_text(&text);
                    }
                    _ => {}
                }
            }
            ok.set(Self::answer(&mut st.borrow_mut(), form, &seed, None).is_some());
        }));
        SequenceSettingsForm { form, state, usable }
    }

    /// Frame duration the rate popup shows right now.
    fn frame_duration(s: &SequenceSettingsState, form: &dyn DialogForm) -> Time {
        let rates = SequenceFormatPresets::FRAME_RATES;
        form.index("rate")
            .and_then(|i| usize::try_from(i).ok())
            .and_then(|i| rates.get(i))
            .map_or(s.original.frame_duration, |r| r.frame_duration)
    }

    /// Frame rate or Display changed: the start stays a time and is written again in the new rate and mode.
    fn refresh_start(s: &mut SequenceSettingsState, form: &mut ShellForm) {
        if s.is_new {
            return;
        }
        let text = form.text("start").unwrap_or_else(|| s.start.text().to_string());
        s.start.set_text(&text);
        let fd = Self::frame_duration(s, form);
        s.start.reconfigure(fd, form.index("display") == Some(1));
        form.set("start", FormValue::Text(s.start.text().to_string()));
    }

    /// The preset popup follows the fields: the preset when size and rate match one, else Custom.
    fn sync_preset(s: &SequenceSettingsState, form: &mut ShellForm) {
        let named = SequenceFormatPresets::named();
        let found = Self::chosen(s, form).and_then(|c| {
            named
                .iter()
                .find(|n| n.format == c && n.delivery_target == s.target)
                .cloned()
                .or_else(|| SequenceFormatPresets::preset_matching(&c))
        });
        match found.and_then(|n| named.iter().position(|x| x.name == n.name)) {
            Some(i) => form.set("preset", FormValue::Index(i as i64 + 1)),
            None => form.set("preset", FormValue::Index(0)),
        }
    }

    /// The format in the fields; `None` when the size is not a number in range.
    fn chosen(s: &SequenceSettingsState, form: &dyn DialogForm) -> Option<SequenceFormat> {
        let (w, h) = (form.number("width")?, form.number("height")?);
        let max = SequenceFormatPresets::MAX_DIMENSION as f64;
        if !w.is_finite() || !h.is_finite() || w < 1.0 || h < 1.0 || w > max || h > max {
            return None;
        }
        let sr = form
            .index("audio")
            .and_then(|i| usize::try_from(i).ok())
            .and_then(|i| SequenceFormatPresets::SAMPLE_RATES.get(i).copied())
            .unwrap_or(s.original.audio_sample_rate);
        let mut f = SequenceFormat {
            width: w.round() as i64,
            height: h.round() as i64,
            frame_duration: Self::frame_duration(s, form),
            audio_sample_rate: sr,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        };
        let shape = form.index("shape").unwrap_or(0).clamp(0, s.shapes.len() as i64 - 1) as usize;
        f.set_pixel_aspect(s.shapes[shape]);
        f.is_valid().then_some(f)
    }

    /// The edited settings and the project's Live Ducking choice; `None` when the size or Starts at is not usable (the Mac
    /// sheet stays open then).
    pub fn answer(
        s: &mut SequenceSettingsState,
        form: &dyn DialogForm,
        settings: &SequenceSettings,
        project_ducking: Option<&ProjectLiveDucking>,
    ) -> Option<SequenceSettingsAnswer> {
        let f = Self::chosen(s, form)?;
        let mut out = settings.clone();
        out.name = form.text("name").unwrap_or_else(|| settings.name.clone());
        out.format = f;
        out.delivery_target = s.target.clone();
        let mut ducking = None;
        if !s.is_new {
            let text = form.text("start").unwrap_or_else(|| s.start.text().to_string());
            s.start.set_text(&text);
            if !s.start.is_valid() {
                return None;
            }
            out.channel_layout =
                if form.index("channels") == Some(1) { ChannelLayout::Mono } else { ChannelLayout::Stereo };
            out.edit_mode =
                if form.index("mode") == Some(1) { TimelineEditMode::Magnetic } else { TimelineEditMode::Normal };
            out.timecode_display =
                if form.index("display") == Some(1) { TimecodeDisplay::Frames } else { TimecodeDisplay::Timecode };
            out.timecode_start = s.start.start();
            out.preview_quality =
                QUALITIES[form.index("quality").unwrap_or(0).clamp(0, QUALITIES.len() as i64 - 1) as usize];
            if let Some(choice) =
                form.index("ducking").and_then(|i| usize::try_from(i).ok()).and_then(|i| s.ducking_choices.get(i))
            {
                let mut c = choice.setting.clone();
                if let Some(c) = c.as_mut().filter(|c| c.is_on) {
                    c.timing = project_ducking.and_then(|p| p.timing.clone());
                }
                if c.as_ref() != project_ducking {
                    ducking = Some(c);
                }
            }
        }
        Some(SequenceSettingsAnswer { settings: out, ducking })
    }
}

/// `MonitorQuality(rawValue: q.rawValue)`: the sequence's fixed qualities are the monitor's.
fn monitor_quality(q: SequencePreviewQuality) -> MonitorQuality {
    MonitorQuality::from_sequence(q)
}

impl ShellHost {
    /// File > New > Sequence…: the active sequence's format as the start (the Mac `requestNewSequence`).
    pub async fn new_sequence<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some((d, usable, state, settings)) = h.with(|r| {
            let p = r.shell_parts();
            let base = p
                .session
                .active_timeline()
                .map_or_else(|| SequenceFormat::new(Time::new(1001, 30000)), |t| t.format.clone());
            let settings = new_settings(p.session.suggested_sequence_name(), base);
            let f = ShellSequenceSettings::make(&settings, true, None, None);
            let d = Self::sequence_settings_dialog(f.form, "New Sequence", "", "Create", true, &f.usable);
            (d, f.usable, f.state, settings)
        }) else {
            return;
        };
        let _ = usable;
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(a) = ShellSequenceSettings::answer(&mut state.borrow_mut(), &*form, &settings, None) else {
                return;
            };
            p.session.stop_playback();
            p.session.add_sequence(Some(&a.settings.name), Some(a.settings.format), a.settings.delivery_target);
        });
    }

    /// Sequence > Sequence Settings… of the active sequence (one undo step; the project's Live Ducking on its own).
    pub async fn sequence_settings<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((d, state, current, duck))) = h.with(|r| {
            let p = r.shell_parts();
            let Some(current) = p.session.active_timeline().map(|t| t.settings()) else {
                p.shell.flash("Open a sequence first.");
                return None;
            };
            let duck = p.session.project().live_ducking.clone();
            let preferred = LiveDucking::current(&NumbersView(Rc::clone(&p.shell.settings)));
            let f = ShellSequenceSettings::make(&current, false, duck.as_ref(), preferred.as_ref());
            let d = Self::sequence_settings_dialog(
                f.form,
                "Sequence Settings",
                "Clips keep their scale and position.",
                "OK",
                false,
                &f.usable,
            );
            Some((d, f.state, current, duck))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(a) = ShellSequenceSettings::answer(&mut state.borrow_mut(), &*form, &current, duck.as_ref())
            else {
                return;
            };
            if let Some(d) = a.ducking {
                p.session.set_project_live_ducking(d);
            }
            p.session.stop_playback();
            p.session.apply_sequence_settings(&a.settings);
        });
    }

    fn sequence_settings_dialog(
        form: ShellForm,
        title: &str,
        info: &str,
        button: &str,
        is_new: bool,
        usable: &Rc<Cell<bool>>,
    ) -> ShellDialog {
        let mut d = ShellDialog::new(title, info);
        // art.html 12 (New Sequence 502); Mac SequenceSettingsSheet widthM (SQModal.Size.m is AppKit-only)
        d.width = if is_new { 502.0 } else { 600.0 };
        d.form = Some(Box::new(form));
        d.add_button(button, SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        // OK closes only with a usable size and Starts at (the Mac `canConfirm`); nothing typed is lost.
        let usable = Rc::clone(usable);
        d.can_close = Some(Box::new(move |r| r != SQDialogResponse::FIRST || usable.get()));
        d
    }

    /// File > Project Notes…: the project's free text, one undo step on OK.
    pub async fn project_notes<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(d) = h.with(|r| {
            let p = r.shell_parts();
            // `ProjectNotesDialog`: a multi-line box over the sheet width, the caret in it.
            let mut form = ShellForm::new(vec![Row::TextBox {
                id: "notes".into(),
                value: p.session.project().notes().to_string(),
                height: 180.0,
            }]);
            form.set_placeholders(
                [("notes".to_string(), "Client, deadline, delivery format…".to_string())].into_iter().collect(),
            );
            form.begin_editing("notes");
            let mut d = ShellDialog::new(
                "Project Notes",
                "Notes stay with the project file: who it is for, deadlines, delivery specs, to-dos.",
            );
            d.width = 520.0;
            d.form = Some(Box::new(form));
            d.add_button("OK", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            d
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            if let Some(text) = form.text("notes").filter(|t| t != p.session.project().notes()) {
                p.session.set_project_notes(&text);
            }
        });
    }

    /// The active sequence's timecode (start offset and display) for typed positions.
    pub(crate) fn sequence_timecode(session: &EditorSession) -> Option<Timecode> {
        let tl = session.active_timeline()?;
        let fd = tl.frame_duration();
        let mut tc = Timecode::new(fd, fd == Time::new(1001, 30000) || fd == Time::new(1001, 60000));
        tc.origin = tl.timecode_start();
        tc.frames_only = tl.timecode_display() == TimecodeDisplay::Frames;
        Some(tc)
    }

    /// Go to Timecode: the Mac focuses the monitor's timecode field (`focusTimecode`); a host without that hook gets a
    /// dialog: type a position, the playhead goes there. Starts the dialog flow when the hook did not take it.
    // The dialog stays for hosts that do not answer `focus_timecode`, as in Swift `ShellSequenceDialogs`.
    pub fn go_to_timecode_command(&mut self, cx: &mut ShellCx) {
        if Self::sequence_timecode(cx.session).is_none() {
            self.flash("Open a sequence first.");
            return;
        }
        if cx.hooks.focus_timecode() {
            return;
        }
        self.start_flow(ShellFlow::GoToTimecode);
    }

    /// The Go to Timecode dialog.
    pub async fn go_to_timecode<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            let tc = Self::sequence_timecode(p.session)?;
            let form = ShellForm::new(vec![Row::field("tc", "Timecode", &tc.position(p.session.playhead()))]);
            let mut d = ShellDialog::new("Go to Timecode", "hh:mm:ss:ff, a shorter form like 1:00, or frames.");
            d.width = 360.0;
            d.form = Some(Box::new(form));
            d.add_button("Go", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some(d)
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(tc) = Self::sequence_timecode(p.session) else { return };
            match tc.parse_position(&form.text("tc").unwrap_or_default()) {
                Some(t) => p.session.seek(t.max(Time::ZERO)),
                None => p.shell.flash("That is not a timecode."),
            }
        });
    }

    /// New Tone and Tone Settings (the Mac `ToneDialog`): frequency and level of a sine tone.
    pub async fn tone_dialog<R: ShellRoot + ?Sized>(h: UiRef<R>, editing: bool) {
        let Some(Some((d, selected))) = h.with(|r| {
            let p = r.shell_parts();
            let sel = p.session.selected_tone();
            if editing && sel.is_none() {
                p.shell.flash("Select a tone clip first.");
                return None;
            }
            let spec = sel.as_ref().map_or(ToneSpec::DEFAULT, |s| s.1);
            // `ToneSpec.frequencyRange` (20 Hz...20 kHz) and `levelRange` (-60...0 dB) in their display units.
            let mut form = ShellForm::new(vec![
                Row::Slider {
                    id: "hz".into(),
                    label: "Frequency".into(),
                    value: spec.frequency_hz(),
                    range: 20.0..=20_000.0,
                    unit: "Hz".into(),
                },
                Row::Slider {
                    id: "db".into(),
                    label: "Level".into(),
                    value: spec.level_db(),
                    range: -60.0..=0.0,
                    unit: "dB".into(),
                },
            ]);
            // art.html 31
            form.slider_track_width = Some(170.0);
            let mut d = ShellDialog::new("Tone Settings", "Sine tone, 1 kHz at \u{2212}12 dB by default");
            d.width = 400.0;
            d.form = Some(Box::new(form));
            d.add_button(if editing { "OK" } else { "Add" }, SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((d, sel))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let spec = selected.as_ref().map_or(ToneSpec::DEFAULT, |s| s.1);
            let out = ToneSpec::from_hz_db(
                form.number("hz").unwrap_or_else(|| spec.frequency_hz()),
                form.number("db").unwrap_or_else(|| spec.level_db()),
            );
            p.session.stop_playback();
            if let (true, Some((id, _))) = (editing, &selected) {
                p.session.set_tone(*id, &out);
            } else if p.session.add_tone_clip(&out, Time::new(5, 1)).is_none() {
                let line = p.session.last_error().unwrap_or("Could not add the tone.").to_string();
                p.shell.flash_raw(line);
            } else {
                let at = p.session.playhead();
                p.session.seek(at);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_labels_drop_trailing_zeros() {
        assert_eq!(ShellSequenceSettings::rate_label(Time::new(1001, 30000)), "29.97");
        assert_eq!(ShellSequenceSettings::rate_label(Time::new(1, 24)), "24");
        assert_eq!(ShellSequenceSettings::rate_label(Time::new(1, 100)), "100");
    }

    #[test]
    fn sample_rate_titles() {
        assert_eq!(ShellSequenceSettings::sample_rate_title(44_100), "44.1 kHz");
        assert_eq!(ShellSequenceSettings::sample_rate_title(48_000), "48 kHz");
        assert_eq!(ShellSequenceSettings::sample_rate_title(96_000), "96 kHz");
    }
}
