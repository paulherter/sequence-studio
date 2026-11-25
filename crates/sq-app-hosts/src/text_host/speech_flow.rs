// Swift: SQInspectorUI/Draw/TextPanelDraw.swift (`useTranscription`, `syncTranscript`, `addCaptions`), SQAppShell/CaptionsHost.swift
//! The Transcribe tab's flow: one `CaptionsPanelModel` per sequence, the model's events served (transcription job on a worker,
//! seek, captions written as one undo step), and the Create Captions and "Replace the transcript?" dialogs.

use crate::persist::{FileDefaults, FileView};
use crate::speech::{RandomIds, SpeechJob, SpeechMessage, TranscribeState};
use sq_core_model::{CaptionItem, CaptionWord};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw_shell::{FormRow, FormValue, NumberField, ShellDialog, ShellForm};
use sq_editor_session::{AppSettings, CaptionLookLibrary, CaptionMapping, EditorSession, LookStore, LookStoreCaptions};
use sq_inspector_ui::captions::panel_model::CaptionsState;
use sq_inspector_ui::captions::panel_model::{CaptionsPanelEvent, CaptionsPanelModel, SequenceSource};
use sq_inspector_ui::captions::transcript_tab_draw::SharedModel;
use sq_transcribe::caption_segmenter::Caption;
use sq_transcribe::timeline_transcription::TimelineTranscription;
use sq_transcribe::transcription_service::TranscriptionService;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// What the tab asked the host to ask the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Ask {
    CreateCaptions,
    ReplaceTranscript,
}

/// The Transcribe tab's state in the Text host.
pub(super) struct Speech {
    service: Arc<dyn TranscriptionService>,
    defaults: Rc<RefCell<FileDefaults>>,
    models: BTreeMap<Id, SharedModel>,
    active: Option<Id>,
    job: Option<SpeechJob>,
    /// The sequence whose model asked for the running job.
    job_model: Option<Id>,
    pub(super) asks: Rc<RefCell<Vec<Ask>>>,
    flush_at: Option<Instant>,
    /// The run's state; its line is sent when it changes (a download reports many small steps).
    transcribe: TranscribeState,
    /// Remove Filler Words found no captions and started the transcription: scan when the captions exist (Swift awaits it).
    filler_after: bool,
    /// The app's Look store: the saved caption Looks Create Captions picks its default from.
    looks: Option<Arc<LookStore>>,
}

/// The model of the shared limits of one caption style, as the Create Captions dialog shows them.
struct StyleLimits {
    name: String,
    chars: f64,
    lines: i64,
    min_seconds: f64,
    gap_frames: f64,
}

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

impl Speech {
    pub(super) fn new(service: Arc<dyn TranscriptionService>, defaults: Rc<RefCell<FileDefaults>>) -> Speech {
        Speech {
            service,
            defaults,
            models: BTreeMap::new(),
            active: None,
            job: None,
            job_model: None,
            asks: Rc::default(),
            flush_at: None,
            transcribe: TranscribeState::Idle,
            filler_after: false,
            looks: None,
        }
    }

    /// Gives the flow the app's Look store (Swift `CaptionLookLibrary.shared`).
    pub(super) fn set_looks(&mut self, looks: Arc<LookStore>) {
        self.looks = Some(looks);
    }

    /// The saved caption Looks; each one is registered so captions that carry its refs render.
    fn look_library(&self) -> CaptionLookLibrary {
        let library = match &self.looks {
            Some(store) => CaptionLookLibrary::new(&LookStoreCaptions(store)),
            None => CaptionLookLibrary::empty(),
        };
        for l in library.looks() {
            sq_text::caption_presets::CaptionLookRegistry::shared().register(l.look.clone(), &l.id.to_string());
        }
        library
    }

    pub(super) fn is_busy(&self) -> bool {
        self.job.is_some()
    }

    /// The media files, channel maps and channel counts of the audible clips (a relinked file keeps its media id: the path is
    /// read fresh on every call).
    fn sequence_source(session: &EditorSession, id: Id) -> Option<SequenceSource> {
        let timeline = session.project().timelines.iter().find(|t| t.id == id)?.clone();
        let mut urls = BTreeMap::new();
        let mut source = SequenceSource::new(timeline.clone(), BTreeMap::new());
        for clip in TimelineTranscription::audible_clips(&timeline) {
            let Some(media) = session.project().media(clip.media) else { continue };
            urls.insert(clip.media, PathBuf::from(&media.path));
            if let Some(audio) = media.info.as_ref().and_then(|i| i.audio.as_ref())
                && let Some(map) = &audio.channel_map
            {
                source.channel_maps.insert(clip.media, map.clone());
                source.expected_channels.insert(clip.media, audio.channels);
            }
        }
        source.urls = urls;
        Some(source)
    }

    /// Makes sure the active sequence has its model and the model knows the sequence's media; returns the model to show.
    pub(super) fn sync(&mut self, session: &EditorSession) -> Option<SharedModel> {
        let live: Vec<Id> = session.project().timelines.iter().map(|t| t.id).collect();
        self.models.retain(|id, _| live.contains(id));
        let Some(tl) = session.active_timeline() else {
            self.active = None;
            return None;
        };
        let (id, frame_duration) = (tl.id, tl.format.frame_duration);
        let model = match self.models.get(&id) {
            Some(m) => Rc::clone(m),
            None => {
                let view = FileView(Rc::clone(&self.defaults));
                let mut m = CaptionsPanelModel::with_ids(Box::new(RandomIds));
                let language = AppSettings::caption_language_for_project(session.project().id, &view);
                m.apply_supported_languages(&self.service.supported_languages());
                if !m.languages.contains(&language) {
                    m.languages.insert(0, language.clone());
                }
                m.set_language(&language);
                // The change above is the initial value, not a choice of the user.
                m.take_events();
                m.auto_detect_language = AppSettings::load(&view).caption_auto_language;
                let m = Rc::new(RefCell::new(m));
                self.models.insert(id, Rc::clone(&m));
                m
            }
        };
        {
            let mut m = model.borrow_mut();
            m.frame_duration = frame_duration;
            m.set_sequence_source(Self::sequence_source(session, id));
        }
        self.active = Some(id);
        Some(model)
    }

    /// Sequence > Transcribe and Create Captions (Swift `CaptionsHost.autoCaptions`): the status line to say, and whether the
    /// transcription started.
    pub(super) fn auto_captions(&self, session: &EditorSession) -> (String, bool) {
        let Some(model) = self.active_model() else { return ("Open a sequence first.".to_string(), false) };
        if matches!(model.borrow().state(), CaptionsState::Transcribing { .. }) {
            return ("Transcription is already running.".to_string(), false);
        }
        model.borrow_mut().use_default_caption_look(
            session.project().style_kit.as_ref(),
            &self.look_library(),
            &FileView(Rc::clone(&self.defaults)),
        );
        model.borrow_mut().transcribe_and_create_captions();
        ("Transcribing the sequence…".to_string(), true)
    }

    /// Remove Filler Words (Swift `CaptionsHost.removeFillerWords`): marks "um / uh / äh / ähm" in the timed captions as
    /// proposed cuts and says how many. With no caption words yet it transcribes and creates the captions first, then scans.
    pub(super) fn remove_filler_words(&mut self, session: &mut EditorSession) -> String {
        if session.active_timeline().is_some_and(has_captions) {
            return self.scan_filler_words(session);
        }
        let (line, started) = self.auto_captions(session);
        self.filler_after = started;
        line
    }

    /// The scan itself: proposed cuts for every filler word, in the language of the project's transcription.
    pub(super) fn scan_filler_words(&self, session: &mut EditorSession) -> String {
        let language =
            AppSettings::caption_language_for_project(session.project().id, &FileView(Rc::clone(&self.defaults)));
        scan_filler_words_in(session, &language)
    }

    /// Clip > Audio Options > Disguise Voice (Swift `CaptionsHost.disguiseVoice`): the effect on the selected range plus
    /// captions from the transcript that exists. It never starts a transcription.
    pub(super) fn disguise_voice(&self, session: &mut EditorSession) -> String {
        disguise_voice_with(self.active_model(), session)
    }

    fn active_model(&self) -> Option<SharedModel> {
        self.active.and_then(|id| self.models.get(&id)).cloned()
    }

    /// Serves what the model asked for and polls the running job. Returns status lines for the status bar.
    pub(super) fn pump(&mut self, session: &mut EditorSession) -> Vec<String> {
        let mut lines = Vec::new();
        for (id, model) in self.models.clone() {
            let events = model.borrow_mut().take_events();
            for e in events {
                match e {
                    CaptionsPanelEvent::LanguageChanged(l) => {
                        let project = session.project().id;
                        AppSettings::set_caption_language_for_project(
                            Some(&l),
                            project,
                            &mut *self.defaults.borrow_mut(),
                        );
                    }
                    CaptionsPanelEvent::Seek(t) => session.seek(t),
                    CaptionsPanelEvent::CreateCaptions(captions) => {
                        lines.push(Self::add_captions(session, id, &captions));
                        if std::mem::take(&mut self.filler_after) {
                            lines.push(self.scan_filler_words(session));
                        }
                    }
                    CaptionsPanelEvent::Transcribe(request) => {
                        if let Some(old) = self.job.take() {
                            old.cancel();
                        }
                        let auto = model.borrow().auto_detect_language;
                        self.transcribe = TranscribeState::Idle;
                        self.job = Some(SpeechJob::start(Arc::clone(&self.service), *request, auto));
                        self.job_model = Some(id);
                    }
                    CaptionsPanelEvent::CancelTranscription => {
                        if let Some(job) = &self.job {
                            job.cancel();
                        }
                    }
                    CaptionsPanelEvent::ScheduleFlush { after_ms } => {
                        let wait = u64::try_from(after_ms.max(0)).unwrap_or(0);
                        self.flush_at = Some(Instant::now() + Duration::from_millis(wait));
                    }
                }
            }
        }
        if self.flush_at.is_some_and(|t| Instant::now() >= t) {
            self.flush_at = None;
            if let Some(m) = self.active_model() {
                m.borrow_mut().flush_edits();
            }
        }
        lines.extend(self.poll_job());
        lines
    }

    fn poll_job(&mut self) -> Vec<String> {
        let Some(job) = &self.job else { return Vec::new() };
        let mut lines = Vec::new();
        let (run, megabytes) = (job.run, job.megabytes);
        let mut ended = false;
        // The run belongs to the model that asked, also after a switch to another sequence.
        let model = self.job_model.and_then(|id| self.models.get(&id)).cloned();
        for message in job.poll() {
            let Some(model) = &model else { continue };
            let mut m = model.borrow_mut();
            match &message {
                SpeechMessage::Preparing(p) => m.report_preparation(*p, run),
                SpeechMessage::PreparationDone => m.preparation_done(run),
                SpeechMessage::Progress(p) => m.report_progress(*p, run),
                SpeechMessage::Done(_) => ended = true,
            }
            let before = self.transcribe.clone();
            self.transcribe = before.clone().next(&message, megabytes);
            if let SpeechMessage::Done(result) = message {
                m.finish(result, run);
            }
            // The same line again (a download reports many small steps) is not sent twice.
            if self.transcribe != before {
                lines.extend(self.transcribe.line());
            }
        }
        if ended {
            self.job = None;
        }
        lines.retain(|l| !l.is_empty());
        lines
    }

    /// Swift `addCaptions`: the captions (sequence time already) become caption items on the frame grid, one undo step.
    fn add_captions(session: &mut EditorSession, timeline: Id, captions: &[Caption]) -> String {
        let snapped = caption_items(session, timeline, captions);
        if snapped.is_empty() {
            return "There are no captions to create.".to_string();
        }
        let count = snapped.len();
        if session.add_captions(snapped) {
            SQL10n::plural(count as i64, "Created %@ caption.", "Created %@ captions.")
        } else {
            String::new()
        }
    }

    /// The dialogs the tab's buttons asked for.
    pub(super) fn dialogs(&mut self) -> Vec<ShellDialog> {
        let asked: Vec<Ask> = self.asks.borrow_mut().drain(..).collect();
        let Some(model) = self.active_model() else { return Vec::new() };
        asked
            .into_iter()
            .filter_map(|a| match a {
                Ask::CreateCaptions => Some(create_captions_dialog(Rc::clone(&model))),
                Ask::ReplaceTranscript => {
                    model.borrow().needs_overwrite_confirmation().then(|| replace_dialog(Rc::clone(&model)))
                }
            })
            .collect()
    }
}

/// The presets of `model` as the dialog's style list (the limits of each preset; the gap in frames of the sequence).
fn styles(model: &CaptionsPanelModel) -> Vec<StyleLimits> {
    let fd = seconds(model.frame_duration);
    model
        .presets
        .iter()
        .map(|n| StyleLimits {
            name: n.name.clone(),
            chars: n.preset.max_chars_per_line as f64,
            lines: n.preset.max_lines.clamp(1, 2),
            min_seconds: seconds(n.preset.min_duration),
            gap_frames: if fd > 0.0 { (seconds(n.preset.gap) / fd).round() } else { 0.0 },
        })
        .collect()
}

/// The Create Captions dialog over `model`'s transcript: the chosen style and limits go into the model, then it makes the captions.
pub(super) fn create_captions_dialog(model: SharedModel) -> ShellDialog {
    let styles = styles(&model.borrow());
    let pick = model.borrow().selected_preset_index.min(styles.len().saturating_sub(1));
    let first = styles.get(pick);
    let (chars, lines, min, gap) =
        first.map_or((42.0, 2, 1.0, 0.0), |s| (s.chars, s.lines, s.min_seconds, s.gap_frames));
    let names: Vec<&str> = styles.iter().map(|s| s.name.as_str()).collect();
    let number = |id: &str, label: &str, value: f64, range, step: f64, decimals: i64, unit: &str| FormRow::Number {
        label: label.to_string(),
        field: NumberField {
            step,
            decimals,
            unit: unit.to_string(),
            default_value: Some(value),
            ..NumberField::new(id, value, range)
        },
    };
    let mut form = ShellForm::new(vec![
        FormRow::popup("style", "Style", &names, pick as i64),
        number("chars", "Characters", chars, 8.0..=100.0, 1.0, 0, ""),
        FormRow::segmented("lines", "Lines", &["One", "Two"], lines - 1, 0.0),
        number("minDuration", "Min. Duration", min, 0.0..=60.0, 0.05, 2, "s"),
        number("gap", "Caption Gap", gap, 0.0..=120.0, 1.0, 0, "frames"),
    ]);
    form.control_widths =
        BTreeMap::from([("chars".to_string(), 62.0), ("minDuration".to_string(), 62.0), ("gap".to_string(), 62.0)]);
    let seen: Rc<RefCell<BTreeMap<String, FormValue>>> = Rc::default();
    let into = Rc::clone(&seen);
    let all = styles;
    // A new style refills the four limits with its own.
    form.on_change = Some(Box::new(move |f, id, v| {
        into.borrow_mut().insert(id.to_string(), v.clone());
        if id != "style" {
            return;
        }
        let FormValue::Index(i) = v else { return };
        let Some(s) = usize::try_from(*i).ok().and_then(|i| all.get(i)) else { return };
        for (key, value) in [
            ("chars", FormValue::Number(s.chars)),
            ("lines", FormValue::Index(s.lines - 1)),
            ("minDuration", FormValue::Number(s.min_seconds)),
            ("gap", FormValue::Number(s.gap_frames)),
        ] {
            into.borrow_mut().insert(key.to_string(), value.clone());
            f.set(key, value);
        }
    }));
    let mut d = ShellDialog::new("Create Captions", "Captions are made from the transcript of the whole sequence.");
    d.form = Some(Box::new(form));
    d.add_button("Create", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.completion = Some(Box::new(move |r| {
        if r != SQDialogResponse::FIRST {
            return;
        }
        let get = |k: &str| seen.borrow().get(k).cloned();
        let number = |k: &str, fallback: f64| match get(k) {
            Some(FormValue::Number(v)) => v,
            Some(FormValue::Text(t)) => t.trim().parse().unwrap_or(fallback),
            _ => fallback,
        };
        let index = |k: &str, fallback: i64| match get(k) {
            Some(FormValue::Index(i)) => i,
            _ => fallback,
        };
        let mut m = model.borrow_mut();
        m.selected_preset_index = usize::try_from(index("style", pick as i64)).unwrap_or(pick);
        m.set_options(
            number("chars", chars).round() as i64,
            index("lines", lines - 1) + 1,
            CaptionsPanelModel::min_duration(number("minDuration", min).max(0.0)),
            number("gap", gap).round() as i64,
        );
        m.create_captions();
    }));
    d
}

/// "Replace the transcript?": transcribing again drops the current transcript with the user's edits.
pub(super) fn replace_dialog(model: SharedModel) -> ShellDialog {
    let mut d = ShellDialog::new(
        "Replace the transcript?",
        "Transcribing again replaces the current transcript, including your edits. Media is not changed.",
    );
    d.add_button("Transcribe Again", SQDialogRole::Default, false);
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.completion = Some(Box::new(move |r| {
        if r == SQDialogResponse::FIRST {
            model.borrow_mut().confirm_overwrite();
        } else {
            model.borrow_mut().cancel_overwrite();
        }
    }));
    d
}

fn has_captions(t: &sq_core_model::Timeline) -> bool {
    t.caption_tracks.iter().any(|c| !c.items().is_empty())
}

/// The status line after a filler word scan (Swift `CaptionsHost.fillerWordsText`).
pub(super) fn filler_words_text(scan: &sq_core_audio::filler_words::FillerScan, has_captions: bool) -> String {
    if scan.cuts.is_empty() {
        let hint = if scan.untimed_captions > 0 {
            " Captions without word timings are skipped: transcribe again."
        } else {
            ""
        };
        return if has_captions {
            format!("No filler words found.{hint}")
        } else {
            "Create captions first: the filler words come from the transcript.".to_string()
        };
    }
    let total = scan.total();
    let seconds = format!("{:.1}", total.value() as f64 / total.timescale() as f64);
    let word = if scan.count == 1 { "word" } else { "words" };
    format!(
        "{} filler {word} marked ({seconds} s). Clip > Audio Options > Accept All Proposed Cuts removes them, or reject.",
        scan.count
    )
}

/// Disguise Voice over `model`'s transcript (None: no Text panel model, so only the effect).
pub(super) fn disguise_voice_with(model: Option<SharedModel>, session: &mut EditorSession) -> String {
    if session.selected_audio_clips().is_empty() {
        return "Select an audio clip first.".to_string();
    }
    if let Some(m) = &model {
        m.borrow_mut().flush_edits();
    }
    let (transcript, preset) = model.as_ref().map_or((None, None), |m| {
        let m = m.borrow();
        (m.can_create_captions().then(|| m.transcript().cloned()).flatten(), m.selected_preset().cloned())
    });
    session.clear_error();
    let out = session.disguise_voice(transcript.as_ref(), preset.as_ref(), 0);
    let fd = session.active_timeline().map(|t| t.frame_duration());
    match (out, fd) {
        (Some(out), Some(fd)) => out.status_text(fd, transcript.is_some()),
        _ => session
            .last_error()
            .map_or_else(|| "Nothing changed: this range already has Disguise Voice.".to_string(), str::to_string),
    }
}

/// The scan over the sequence's caption words in `language`: proposed cuts and the status line.
pub(super) fn scan_filler_words_in(session: &mut EditorSession, language: &str) -> String {
    let scan = session.propose_filler_word_cuts(language);
    filler_words_text(&scan, session.active_timeline().is_some_and(has_captions))
}

/// The captions (sequence time) as caption items on `timeline`'s frame grid; the one conversion the Captions panel and the
/// Edit API share.
pub(crate) fn caption_items(session: &EditorSession, timeline: Id, captions: &[Caption]) -> Vec<CaptionItem> {
    let fd = session.project().timelines.iter().find(|t| t.id == timeline).map(|t| t.format.frame_duration);
    let mut ids = RandomIds;
    let items: Vec<CaptionItem> = captions
        .iter()
        .map(|c| CaptionItem {
            id: sq_core_time::IdSource::next_id(&mut ids),
            lines: c.lines.clone(),
            range: c.range,
            style_ref: c.style_ref.clone(),
            animation_ref: c.animation_ref.clone(),
            style_overridden: false,
            words: c
                .words
                .iter()
                .map(|w| CaptionWord {
                    text: w.text.clone(),
                    range: TimeRange::from_end(w.range.start - c.range.start, w.range.end() - c.range.start),
                    confidence: w.confidence,
                })
                .collect(),
            position: c.position,
        })
        .collect();
    fd.map_or(items.clone(), |fd| CaptionMapping::snapped(&items, fd))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::SequentialIds;
    use sq_editor_session::{EditorSession, SessionDeps};
    use sq_transcribe::caption_preset::CaptionPreset;
    use sq_transcribe::caption_segmenter::CaptionSegmenter;
    use sq_transcribe::transcript::{Transcript, TranscriptWord};
    use sq_transcribe::transcription_service::{CancelToken, Locale, TranscriptionError};

    fn t(n: i64) -> Time {
        Time::new(n, 1000)
    }

    /// Says three words at 1 s, 2 s and 3 s of any file; remembers the language it was asked for.
    struct Fake(std::sync::Mutex<Vec<String>>);

    impl TranscriptionService for Fake {
        fn transcribe(
            &self,
            _url: &std::path::Path,
            locale: &Locale,
            progress: &mut dyn FnMut(f64),
            _cancel: &CancelToken,
            ids: &mut dyn sq_core_time::IdSource,
        ) -> Result<Transcript, TranscriptionError> {
            self.0.lock().expect("lock").push(locale.identifier().to_string());
            progress(0.5);
            let words = ["Hallo", "liebe", "Leute"]
                .iter()
                .enumerate()
                .map(|(i, w)| {
                    let at = (i as i64 + 1) * 1000;
                    TranscriptWord::new(ids.next_id(), w, TimeRange::from_end(t(at), t(at + 500)))
                })
                .collect();
            Ok(Transcript::new(&locale.bcp47(), words))
        }

        fn detects_language(&self) -> bool {
            true
        }
    }

    fn defaults() -> Rc<RefCell<FileDefaults>> {
        FileDefaults::shared(&crate::test_rig::unique_dir("sq-speech-flow-tests"))
    }

    fn session() -> EditorSession {
        let mut ids = SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-speech-flow-tests")))
    }

    /// A sequence with one audio clip that plays the media's source 0.5 s..3.5 s from 10 s on.
    fn sequence() -> SequenceSource {
        let media = Id::fixed(77);
        let mut clip =
            Clip::new(Id::fixed(5), "a", media, TrackKind::Audio, TimeRange::from_end(t(500), t(3500)), t(10_000));
        clip.media_duration = Some(t(60_000));
        let mut track = Track::new(Id::fixed(2), TrackKind::Audio);
        track.set_clips(vec![clip]);
        let timeline = Timeline::new(Id::fixed(1), "S", SequenceFormat::new(Time::new(1, 30)), vec![track]);
        SequenceSource::new(timeline, BTreeMap::from([(media, PathBuf::from("talk.wav"))]))
    }

    #[test]
    fn the_caption_language_setting_is_the_language_of_a_new_sequence_model() {
        for language in ["fr-FR", "it-IT"] {
            let d = defaults();
            AppSettings { caption_language: language.to_string(), ..AppSettings::standard() }
                .save(&mut *d.borrow_mut());
            let mut speech = Speech::new(Arc::new(Fake(std::sync::Mutex::new(Vec::new()))), d);
            let model = speech.sync(&session()).expect("the untitled project has a sequence");
            assert_eq!(model.borrow().language(), language, "Caption Language is the transcription default");
        }
    }

    #[test]
    fn a_transcribe_request_runs_on_a_worker_and_the_words_land_in_sequence_time() {
        let service = Arc::new(Fake(std::sync::Mutex::new(Vec::new())));
        let mut speech = Speech::new(Arc::<Fake>::clone(&service), defaults());
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        let id = Id::fixed(1);
        speech.models.insert(id, Rc::clone(&model));
        speech.active = Some(id);
        model.borrow_mut().set_sequence_source(Some(sequence()));
        model.borrow_mut().auto_detect_language = true;
        model.borrow_mut().transcribe(false);
        let mut session = session();
        let start = Instant::now();
        let mut statuses = Vec::new();
        while model.borrow().state() != &CaptionsState::Ready {
            statuses.extend(speech.pump(&mut session));
            assert!(start.elapsed() < Duration::from_secs(20), "the job never ended: {:?}", model.borrow().state());
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!speech.is_busy());
        assert_eq!(service.0.lock().expect("lock").as_slice(), ["auto"], "auto language asks the engine to detect");
        assert!(statuses.iter().any(|s| s == "Transcribed 3 words."), "{statuses:?}");
        let m = model.borrow();
        let words = &m.transcript().expect("transcript").words;
        // Source 1.0 s is 0.5 s into the clip: 10.5 s on the timeline; the word at 3.0 s lies on the clip's edge.
        assert_eq!(words[0].range.start, t(10_500));
        assert_eq!(words[1].range.start, t(11_500));
    }

    #[test]
    fn captions_from_a_transcript_are_one_undo_step_with_words_relative_to_the_caption() {
        let mut session = session();
        let timeline = session.active_timeline_id().expect("timeline");
        let words: Vec<TranscriptWord> = ["Hallo", "liebe", "Leute"]
            .iter()
            .enumerate()
            .map(|(i, w)| {
                let at = i as i64 * 400;
                TranscriptWord::new(Id::fixed(i as u64 + 1), w, TimeRange::from_end(t(at), t(at + 300)))
            })
            .collect();
        let preset = CaptionPreset::standard();
        let captions = CaptionSegmenter::apply_timing(
            &CaptionSegmenter::segment(&Transcript::new("de-DE", words), &preset),
            &preset,
        );
        assert!(!captions.is_empty());
        let before = session.can_undo();
        let line = Speech::add_captions(&mut session, timeline, &captions);
        assert!(line.starts_with("Created "), "{line}");
        let track = session.current_caption_track().expect("caption track").clone();
        assert!(!track.items().is_empty());
        let first = &track.items()[0];
        assert_eq!(first.words.first().map(|w| w.range.start), Some(Time::ZERO));
        assert_eq!(session.undo_name(), Some("Create Captions"));
        session.undo();
        assert!(session.current_caption_track().is_none_or(|t| t.items().is_empty()));
        assert_eq!(session.can_undo(), before);
    }

    /// A speech flow whose model already holds a transcript of the test sequence (no caption track exists yet).
    fn speech_with_transcript() -> (Speech, SharedModel, EditorSession) {
        let mut speech = Speech::new(Arc::new(Fake(std::sync::Mutex::new(Vec::new()))), defaults());
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        speech.models.insert(Id::fixed(1), Rc::clone(&model));
        speech.active = Some(Id::fixed(1));
        model.borrow_mut().set_sequence_source(Some(sequence()));
        model.borrow_mut().transcribe(false);
        let mut session = session();
        let start = Instant::now();
        while model.borrow().state() != &CaptionsState::Ready {
            speech.pump(&mut session);
            assert!(start.elapsed() < Duration::from_secs(20), "the job never ended");
            std::thread::sleep(Duration::from_millis(5));
        }
        (speech, model, session)
    }

    #[test]
    fn cancel_in_the_create_captions_dialog_leaves_the_project_untouched() {
        let (mut speech, model, mut session) = speech_with_transcript();
        let (undo, tracks) = (session.can_undo(), session.active_timeline().map_or(0, |t| t.caption_tracks.len()));
        let mut dialog = create_captions_dialog(Rc::clone(&model));
        assert_eq!(session.active_timeline().map_or(0, |t| t.caption_tracks.len()), tracks, "opening changes nothing");
        dialog.press(SQDialogResponse(1));
        let lines = speech.pump(&mut session);
        assert!(lines.is_empty(), "{lines:?}");
        assert_eq!(session.active_timeline().map_or(0, |t| t.caption_tracks.len()), tracks);
        assert_eq!(session.can_undo(), undo);
        assert_eq!(session.undo_name(), None);
    }

    #[test]
    fn create_in_the_create_captions_dialog_adds_track_and_clips_as_one_undo_step() {
        let (mut speech, model, mut session) = speech_with_transcript();
        let undo = session.can_undo();
        let mut dialog = create_captions_dialog(Rc::clone(&model));
        assert!(session.active_timeline().is_some_and(|t| t.caption_tracks.is_empty()), "nothing before Create");
        dialog.press(SQDialogResponse::FIRST);
        let lines = speech.pump(&mut session);
        assert!(lines.iter().any(|l| l.starts_with("Created ")), "{lines:?}");
        assert!(session.current_caption_track().is_some_and(|t| !t.items().is_empty()));
        assert_eq!(session.undo_name(), Some("Create Captions"));
        session.undo();
        assert!(
            session.active_timeline().is_some_and(|t| t.caption_tracks.is_empty()),
            "one undo removes track and clips"
        );
        assert_eq!(session.can_undo(), undo);
    }

    #[test]
    fn auto_captions_pick_the_project_kit_caption_as_the_look() {
        let mut speech = Speech::new(Arc::new(Fake(std::sync::Mutex::new(Vec::new()))), defaults());
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        let id = Id::fixed(1);
        speech.models.insert(id, Rc::clone(&model));
        speech.active = Some(id);
        model.borrow_mut().set_sequence_source(Some(sequence()));
        let mut ids = SequentialIds::default();
        let mut project = EditorSession::make_untitled(&mut ids);
        project.style_kit = Some(<sq_core_model::StyleKit as sq_text::style_kit_text::StyleKitTextExt>::starter());
        let session = EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-speech-kit")));
        let _ = speech.auto_captions(&session);
        let m = model.borrow();
        assert_eq!(m.presets[m.selected_preset_index].name, "Project Kit");
    }

    #[test]
    fn auto_captions_pick_the_saved_default_look() {
        let defaults = defaults();
        let store = Arc::new(LookStore::new(None, None, None, None));
        let mut speech = Speech::new(Arc::new(Fake(std::sync::Mutex::new(Vec::new()))), Rc::clone(&defaults));
        speech.set_looks(Arc::clone(&store));
        let mut host = super::super::look_host::AppCaptionLooks::new(store, defaults);
        let saved = sq_inspector_ui::captions::style_tab_draw::CaptionLookHost::save(
            &mut host,
            "Saved",
            &sq_text::caption_presets::CaptionLook::default_look(),
            &sq_transcribe::caption_preset::CaptionPreset::standard(),
        );
        assert!(saved.is_some());
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        let id = Id::fixed(1);
        speech.models.insert(id, Rc::clone(&model));
        speech.active = Some(id);
        model.borrow_mut().set_sequence_source(Some(sequence()));
        let _ = speech.auto_captions(&session());
        let m = model.borrow();
        assert_eq!(m.presets[m.selected_preset_index].name, "Saved");
    }

    #[test]
    fn auto_captions_say_when_they_start_and_when_one_already_runs() {
        let mut speech = Speech::new(Arc::new(Fake(std::sync::Mutex::new(Vec::new()))), defaults());
        assert_eq!(speech.auto_captions(&session()), ("Open a sequence first.".to_string(), false));
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        let id = Id::fixed(1);
        speech.models.insert(id, Rc::clone(&model));
        speech.active = Some(id);
        model.borrow_mut().set_sequence_source(Some(sequence()));
        assert_eq!(speech.auto_captions(&session()), ("Transcribing the sequence…".to_string(), true));
        assert!(matches!(model.borrow().state(), CaptionsState::Transcribing { .. }));
        assert_eq!(speech.auto_captions(&session()), ("Transcription is already running.".to_string(), false));
    }

    #[test]
    fn cancel_ends_the_run_without_a_transcript() {
        struct Slow;
        impl TranscriptionService for Slow {
            fn transcribe(
                &self,
                _: &std::path::Path,
                _: &Locale,
                _: &mut dyn FnMut(f64),
                cancel: &CancelToken,
                _: &mut dyn sq_core_time::IdSource,
            ) -> Result<Transcript, TranscriptionError> {
                loop {
                    cancel.check()?;
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
        }
        let mut speech = Speech::new(Arc::new(Slow), defaults());
        let model = Rc::new(RefCell::new(CaptionsPanelModel::with_ids(Box::new(RandomIds))));
        let id = Id::fixed(1);
        speech.models.insert(id, Rc::clone(&model));
        speech.active = Some(id);
        model.borrow_mut().set_sequence_source(Some(sequence()));
        model.borrow_mut().transcribe(false);
        let mut session = session();
        speech.pump(&mut session);
        assert!(speech.is_busy());
        model.borrow_mut().cancel_transcription();
        speech.pump(&mut session);
        let start = Instant::now();
        while speech.is_busy() && start.elapsed() < Duration::from_secs(5) {
            speech.pump(&mut session);
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(model.borrow().transcript().is_none());
    }
}
