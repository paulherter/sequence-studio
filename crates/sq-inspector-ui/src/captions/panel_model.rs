// Swift: CaptionsPanelModel.swift, CaptionsPanelModel+AutoCaptions.swift
//! State and logic of the transcript / captions panel. Text edits never touch media: they only rewrite the transcript
//! via `Transcript::applying_text`.
//!
//! The Swift model starts a `Task` for the transcription and one for the edit debounce. Here the host drives them
//! (PORTING section 9, no executor yet): `transcribe` and `text_changed` queue a [`CaptionsPanelEvent`]; the host runs the
//! `TranscriptionService` and reports back through `report_preparation`, `preparation_done`, `report_progress` and
//! `finish`, and calls `flush_edits` once the debounce interval has passed.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use sq_core_model::{AudioChannelMap, Timeline};
use sq_core_time::text::standard_compare;
use sq_core_time::{Id, IdSource, Time};
use sq_editor_session::{AppSettings, CaptionLookLibrary};
use sq_library::library_folder_store::SettingsStore;
use sq_transcribe::caption_preset::{CaptionPreset, CaptionPresetOptions};
use sq_transcribe::caption_segmenter::{Caption, CaptionSegmenter};
use sq_transcribe::timeline_transcription::{Layout, TimelineTranscription};
use sq_transcribe::transcript::Transcript;
use sq_transcribe::transcription_service::{Locale, TranscriptionError};
use sq_uikit::localization::SQL10n;

use crate::captions::named_look_preset;
use sq_core_model::StyleKit;

/// The two steps of making captions, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptionsStep {
    /// Step 1: write down what is said.
    Transcribe,
    /// Step 2: make captions from the transcript.
    CreateCaptions,
}

/// Transcription state.
#[derive(Clone, Debug, PartialEq)]
pub enum CaptionsState {
    Idle,
    Transcribing { progress: f64 },
    Ready,
    Failed(String),
}

/// A preset with its dialog name.
#[derive(Clone, Debug, PartialEq)]
pub struct NamedPreset {
    pub name: String,
    pub preset: CaptionPreset,
}

impl NamedPreset {
    pub fn new(name: &str, preset: CaptionPreset) -> NamedPreset {
        NamedPreset { name: name.to_string(), preset }
    }
}

/// The whole active sequence: the audible clips' media files; words come back in sequence time. Wins over `source_url`.
#[derive(Clone, Debug)]
pub struct SequenceSource {
    pub timeline: Timeline,
    pub urls: BTreeMap<Id, PathBuf>,
    /// Media whose clips play chosen channels: transcribed from those channels.
    pub channel_maps: BTreeMap<Id, AudioChannelMap>,
    /// Channel count each map was chosen against (the item's stored count): a file that now counts another number is
    /// transcribed with its own layout.
    pub expected_channels: BTreeMap<Id, i64>,
}

impl SequenceSource {
    pub fn new(timeline: Timeline, urls: BTreeMap<Id, PathBuf>) -> SequenceSource {
        SequenceSource { timeline, urls, channel_maps: BTreeMap::new(), expected_channels: BTreeMap::new() }
    }
}

/// What the host must run for a transcription (the body of the Swift `Task`).
#[derive(Clone, Debug)]
pub struct TranscribeRequest {
    /// Pass it back to `report_preparation`, `preparation_done`, `report_progress` and `finish`.
    pub run: u64,
    pub locale: Locale,
    pub url: Option<PathBuf>,
    pub sequence: Option<SequenceSource>,
}

/// What the model reports to its host.
#[derive(Clone, Debug)]
pub enum CaptionsPanelEvent {
    /// `onLanguageChanged`: the host stores it as the project's override.
    LanguageChanged(String),
    /// `onSeek`: source time of the clicked word's start.
    Seek(Time),
    /// `onCreateCaptions`.
    CreateCaptions(Vec<Caption>),
    /// Start `prepare` then `transcribe` of the service (the previous run, if any, is canceled).
    Transcribe(Box<TranscribeRequest>),
    /// Cancel the running transcription.
    CancelTranscription,
    /// Call `flush_edits` after `after_ms` of quiet; a newer request replaces an older one.
    ScheduleFlush { after_ms: i64 },
}

pub struct CaptionsPanelModel {
    state: CaptionsState,
    transcript: Option<Transcript>,
    status_note: Option<String>,
    language: String,
    pub languages: Vec<String>,
    /// Auto language: when the text of a finished run is clearly another supported language, the model switches to it and
    /// transcribes once more (the host sets this from Settings).
    pub auto_detect_language: bool,
    retried_for_language: bool,
    pub presets: Vec<NamedPreset>,
    pub selected_preset_index: usize,
    /// Audio source to transcribe: one file, words in that file's time.
    pub source_url: Option<PathBuf>,
    sequence_source: Option<SequenceSource>,
    is_outdated: bool,
    transcribed_layout: Option<Layout>,
    transcribed_maps: BTreeMap<Id, AudioChannelMap>,
    ran_maps: BTreeMap<Id, AudioChannelMap>,
    ran_layout: Option<Layout>,
    /// Frame duration of the sequence: the gap in Create Captions is counted in frames.
    pub frame_duration: Time,
    current_word_id: Option<Id>,
    needs_overwrite_confirmation: bool,
    pending_text: Option<String>,
    run_id: u64,
    create_when_ready: bool,
    events: Vec<CaptionsPanelEvent>,
    ids: Box<dyn IdSource>,
    /// Quiet interval of the edit debounce.
    pub debounce_ms: i64,
    version: u64,
}

impl CaptionsPanelModel {
    pub const DEFAULT_LANGUAGES: [&'static str; 6] = ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"];
    /// The languages most footage is in, in the order the pop-up lists them on top (every one is a language of the speech
    /// engine). A listed id belongs to the group by its language code ("en-GB" is English).
    pub const COMMON_LANGUAGES: [&'static str; 15] =
        ["en", "de", "es", "fr", "it", "pt", "nl", "pl", "tr", "ru", "ja", "zh", "ko", "ar", "hi"];

    /// A model whose new words take their ids from `ids`.
    pub fn with_ids(ids: Box<dyn IdSource>) -> CaptionsPanelModel {
        CaptionsPanelModel {
            state: CaptionsState::Idle,
            transcript: None,
            status_note: None,
            language: AppSettings::default_caption_language(),
            languages: Self::DEFAULT_LANGUAGES.iter().map(|s| s.to_string()).collect(),
            auto_detect_language: false,
            retried_for_language: false,
            presets: vec![
                NamedPreset::new("Standard", CaptionPreset::standard()),
                NamedPreset::new("Short Video", CaptionPreset::short_video()),
            ],
            selected_preset_index: 0,
            source_url: None,
            sequence_source: None,
            is_outdated: false,
            transcribed_layout: None,
            transcribed_maps: BTreeMap::new(),
            ran_maps: BTreeMap::new(),
            ran_layout: None,
            frame_duration: Time::new(1, 30),
            current_word_id: None,
            needs_overwrite_confirmation: false,
            pending_text: None,
            run_id: 0,
            create_when_ready: false,
            events: Vec::new(),
            ids,
            debounce_ms: 400,
            version: 0,
        }
    }

    /// A model with sequential ids (tests and previews).
    pub fn new() -> CaptionsPanelModel {
        Self::with_ids(Box::new(sq_core_time::RandomIds))
    }

    /// Bumped by every change of what the panel shows.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The events since the last call, in order.
    pub fn take_events(&mut self) -> Vec<CaptionsPanelEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn state(&self) -> &CaptionsState {
        &self.state
    }

    pub fn transcript(&self) -> Option<&Transcript> {
        self.transcript.as_ref()
    }

    /// Shown next to the progress while the language model is downloaded and installed (first use of a language).
    pub fn status_note(&self) -> Option<&str> {
        self.status_note.as_deref()
    }

    /// BCP-47 identifier of the recognition language.
    pub fn language(&self) -> &str {
        &self.language
    }

    pub fn set_language(&mut self, language: &str) {
        if self.language != language {
            self.language = language.to_string();
            self.events.push(CaptionsPanelEvent::LanguageChanged(self.language.clone()));
            self.version += 1;
        }
    }

    pub fn sequence_source(&self) -> Option<&SequenceSource> {
        self.sequence_source.as_ref()
    }

    /// True when the audio layout of the sequence changed after the transcript was made (trim, move, ripple, speed): its
    /// words no longer match the timeline, so seek and Create Captions are off until Transcribe is run again.
    pub fn is_outdated(&self) -> bool {
        self.is_outdated
    }

    /// Word under the playhead (`None` between words).
    pub fn current_word_id(&self) -> Option<Id> {
        self.current_word_id
    }

    /// True when Transcribe was requested while a transcript exists: the view asks, then calls `confirm_overwrite()`.
    pub fn needs_overwrite_confirmation(&self) -> bool {
        self.needs_overwrite_confirmation
    }

    /// Hands the model the current sequence. Does nothing when audio layout and media files are unchanged, so a running
    /// edit in the transcript is not disturbed by unrelated project changes.
    pub fn set_sequence_source(&mut self, new: Option<SequenceSource>) {
        if let (Some(old), Some(new)) = (&self.sequence_source, &new)
            && old.urls == new.urls
            && old.channel_maps == new.channel_maps
            && TimelineTranscription::layout(&old.timeline) == TimelineTranscription::layout(&new.timeline)
        {
            return;
        }
        if let (Some(new), Some(t)) = (&new, &self.transcribed_layout) {
            // Other channels are other words: a changed map of any media the sequence plays outdates the transcript too.
            self.is_outdated = self.transcript.is_some()
                && (TimelineTranscription::layout(&new.timeline) != *t
                    || Self::used_maps(new) != self.transcribed_maps);
        }
        self.sequence_source = new;
        self.version += 1;
    }

    fn used_maps(s: &SequenceSource) -> BTreeMap<Id, AudioChannelMap> {
        s.channel_maps.iter().filter(|(k, _)| s.urls.contains_key(k)).map(|(k, v)| (*k, v.clone())).collect()
    }

    // MARK: Derived

    pub fn can_transcribe(&self) -> bool {
        if matches!(self.state, CaptionsState::Transcribing { .. }) {
            return false;
        }
        self.source_url.is_some() || self.sequence_source.is_some()
    }

    /// Which of the two steps is due: 1 Transcribe (writes the words down) until a usable transcript exists, then
    /// 2 Create Captions (makes captions from it).
    pub fn step(&self) -> CaptionsStep {
        if self.can_create_captions() { CaptionsStep::CreateCaptions } else { CaptionsStep::Transcribe }
    }

    pub fn can_create_captions(&self) -> bool {
        if self.state != CaptionsState::Ready || self.is_outdated {
            return false;
        }
        self.transcript.as_ref().is_some_and(|t| !t.words.is_empty())
    }

    pub fn edited_word_ids(&self) -> BTreeSet<Id> {
        self.transcript.iter().flat_map(|t| &t.words).filter(|w| w.is_edited).map(|w| w.id).collect()
    }

    pub fn selected_preset(&self) -> Option<&CaptionPreset> {
        self.presets.get(self.selected_preset_index).map(|p| &p.preset)
    }

    // MARK: Languages

    /// Replaces the language list with the locales the recognizer reports. An empty report keeps the defaults; the
    /// selected language stays in the list so the pop-up never loses it.
    /// Sorted by the display name like Swift (`language_title`); identifiers without a name sort by the identifier.
    pub fn apply_supported_languages(&mut self, reported: &[String]) {
        if reported.is_empty() {
            return;
        }
        let mut list: Vec<String> = reported.iter().cloned().collect::<BTreeSet<_>>().into_iter().collect();
        if !list.contains(&self.language) {
            list.push(self.language.clone());
        }
        list.sort_by(|a, b| {
            Self::common_rank(a).unwrap_or(usize::MAX).cmp(&Self::common_rank(b).unwrap_or(usize::MAX)).then_with(
                || standard_compare(&Self::language_title(a), &Self::language_title(b)).then_with(|| a.cmp(b)),
            )
        });
        self.languages = list;
        self.version += 1;
    }

    /// The place of a language id in the common group, `None` for every other language.
    fn common_rank(id: &str) -> Option<usize> {
        let code = id.split(['-', '_']).next().unwrap_or(id);
        Self::COMMON_LANGUAGES.iter().position(|c| *c == code)
    }

    /// How many of the first `languages` form the common group (the pop-up draws a divider after them).
    pub fn common_language_count(&self) -> usize {
        self.languages.iter().take_while(|l| Self::common_rank(l).is_some()).count()
    }

    /// The display name of a locale identifier (Swift asked `Locale`): the regional ones in English, every other language by
    /// `sq_uikit::local_format::language_name`; only an identifier no table knows shows as written.
    pub fn language_title(id: &str) -> String {
        match id {
            "de-DE" => "German (Germany)",
            "de-AT" => "German (Austria)",
            "de-CH" => "German (Switzerland)",
            "en-US" => "English (United States)",
            "en-GB" => "English (United Kingdom)",
            "en-AU" => "English (Australia)",
            "en-CA" => "English (Canada)",
            "en-IN" => "English (India)",
            "fr-FR" => "French (France)",
            "fr-CA" => "French (Canada)",
            "es-ES" => "Spanish (Spain)",
            "es-MX" => "Spanish (Mexico)",
            "it-IT" => "Italian (Italy)",
            "pt-BR" => "Portuguese (Brazil)",
            "pt-PT" => "Portuguese (Portugal)",
            "nl-NL" => "Dutch (Netherlands)",
            "sv-SE" => "Swedish (Sweden)",
            "da-DK" => "Danish (Denmark)",
            "nb-NO" => "Norwegian Bokmål (Norway)",
            "fi-FI" => "Finnish (Finland)",
            "pl-PL" => "Polish (Poland)",
            "tr-TR" => "Turkish (Türkiye)",
            "ru-RU" => "Russian (Russia)",
            "uk-UA" => "Ukrainian (Ukraine)",
            "ja-JP" => "Japanese (Japan)",
            "ko-KR" => "Korean (South Korea)",
            "zh-CN" => "Chinese (China mainland)",
            "zh-TW" => "Chinese (Taiwan)",
            "ar-SA" => "Arabic (Saudi Arabia)",
            // Every other language: its full name in the interface language, never the bare code.
            other => return sq_uikit::local_format::language_name(other, None),
        }
        .to_string()
    }

    // MARK: Transcribe

    /// Starts transcription. With an existing transcript this only raises `needs_overwrite_confirmation` (re-transcribe
    /// overwrites, including manual edits) unless `confirmed` is true.
    pub fn transcribe(&mut self, confirmed: bool) {
        if !self.can_transcribe() {
            return;
        }
        if self.transcript.is_some() && !confirmed {
            self.needs_overwrite_confirmation = true;
            self.version += 1;
            return;
        }
        self.needs_overwrite_confirmation = false;
        self.pending_text = None;
        self.run_id += 1;
        self.state = CaptionsState::Transcribing { progress: 0.0 };
        self.status_note = Some(SQL10n::format("Preparing the %@ language model", &[&self.language]));
        let sequence = self.sequence_source.clone();
        self.ran_layout = sequence.as_ref().map(|s| TimelineTranscription::layout(&s.timeline));
        self.ran_maps = sequence.as_ref().map(Self::used_maps).unwrap_or_default();
        self.events.push(CaptionsPanelEvent::Transcribe(Box::new(TranscribeRequest {
            run: self.run_id,
            locale: Locale::new(&self.language),
            url: self.source_url.clone(),
            sequence,
        })));
        self.version += 1;
    }

    pub fn confirm_overwrite(&mut self) {
        self.transcribe(true);
    }

    pub fn cancel_overwrite(&mut self) {
        self.needs_overwrite_confirmation = false;
        self.version += 1;
    }

    pub fn cancel_transcription(&mut self) {
        if !matches!(self.state, CaptionsState::Transcribing { .. }) {
            return;
        }
        self.run_id += 1;
        self.events.push(CaptionsPanelEvent::CancelTranscription);
        self.retried_for_language = false;
        self.create_when_ready = false;
        self.status_note = None;
        self.state = if self.transcript.is_none() { CaptionsState::Idle } else { CaptionsState::Ready };
        self.version += 1;
    }

    pub fn report_progress(&mut self, p: f64, run: u64) {
        if run != self.run_id || !matches!(self.state, CaptionsState::Transcribing { .. }) {
            return;
        }
        self.state = CaptionsState::Transcribing { progress: p.clamp(0.0, 1.0) };
        self.version += 1;
    }

    /// A model download reports its share: the note says "Downloading the German language model: 42 %".
    pub fn report_preparation(&mut self, p: f64, run: u64) {
        if run != self.run_id
            || !matches!(self.state, CaptionsState::Transcribing { .. })
            || self.status_note.is_none()
            || p <= 0.0
            || p >= 1.0
        {
            return;
        }
        let percent = format!("{} %", (p * 100.0).round() as i64);
        self.status_note = Some(SQL10n::format("Downloading the %@ language model: %@", &[&self.language, &percent]));
        self.version += 1;
    }

    pub fn preparation_done(&mut self, run: u64) {
        if run == self.run_id {
            self.status_note = None;
            self.version += 1;
        }
    }

    // known limit: no language guess (Swift guesses only where NaturalLanguage exists); upgrade when a portable language
    // identifier exists.
    fn guessed_retry_language(_text: &str, _used: &str, _supported: &[String]) -> Option<String> {
        None
    }

    /// The host reports the end of a run.
    pub fn finish(&mut self, result: Result<Transcript, TranscriptionError>, run: u64) {
        if run != self.run_id {
            return;
        }
        self.status_note = None;
        self.version += 1;
        match result {
            Ok(t) => {
                let text = t.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
                if self.auto_detect_language
                    && !self.retried_for_language
                    && let Some(other) = Self::guessed_retry_language(&text, &self.language, &self.languages)
                {
                    self.retried_for_language = true;
                    self.set_language(&other);
                    // `transcribe` refuses while a run is shown.
                    self.state = CaptionsState::Idle;
                    self.transcribe(true);
                    return;
                }
                self.retried_for_language = false;
                self.transcript = Some(t);
                self.current_word_id = None;
                self.state = CaptionsState::Ready;
                self.transcribed_layout = self.ran_layout.clone();
                self.transcribed_maps = self.ran_maps.clone();
                self.is_outdated = false;
                if self.create_when_ready {
                    self.create_when_ready = false;
                    self.create_captions();
                }
            }
            Err(e) => {
                self.retried_for_language = false;
                self.create_when_ready = false;
                self.state = CaptionsState::Failed(Self::message(&e));
            }
        }
    }

    fn message(error: &TranscriptionError) -> String {
        match error {
            TranscriptionError::LocaleUnsupported(l) => {
                SQL10n::format("Language %@ is not supported for on-device transcription.", &[l])
            }
            TranscriptionError::NoAudio => {
                SQL10n::string("There is no audio to transcribe: no audible clips in this sequence.")
            }
            e => SQL10n::error_text(e),
        }
    }

    // MARK: Editing

    /// Called on every keystroke; the host calls `flush_edits` after `debounce_ms` of quiet.
    pub fn text_changed(&mut self, text: &str) {
        if self.transcript.is_none() {
            return;
        }
        self.pending_text = Some(text.to_string());
        self.events.push(CaptionsPanelEvent::ScheduleFlush { after_ms: self.debounce_ms });
    }

    /// Applies a pending edit immediately.
    pub fn flush_edits(&mut self) {
        let Some(text) = self.pending_text.take() else { return };
        let Some(t) = &self.transcript else { return };
        let updated = t.applying_text(&text, self.ids.as_mut());
        if updated != *t {
            self.transcript = Some(updated);
            self.version += 1;
        }
    }

    // MARK: Word <-> time / text

    /// UTF-16 ranges of every word in the transcript text (words joined by single spaces).
    pub fn word_ranges(&self) -> Vec<std::ops::Range<usize>> {
        let mut out = Vec::new();
        let mut location = 0;
        for w in self.transcript.iter().flat_map(|t| &t.words) {
            let len = w.text.encode_utf16().count();
            out.push(location..location + len);
            location += len + 1;
        }
        out
    }

    /// Index of the word containing UTF-16 offset `offset`; a separator maps to the preceding word, offsets past the end
    /// to the last word.
    pub fn word_index_at_character(&self, offset: usize) -> Option<usize> {
        let ranges = self.word_ranges();
        if ranges.is_empty() {
            return None;
        }
        let mut result = 0;
        for (i, r) in ranges.iter().enumerate() {
            if r.start <= offset {
                result = i;
            } else {
                break;
            }
        }
        Some(result)
    }

    /// Click-to-seek: moves the playhead to the start of the word at `offset`.
    pub fn seek_to_character(&mut self, offset: usize) {
        self.flush_edits();
        if self.is_outdated {
            return;
        }
        let Some(i) = self.word_index_at_character(offset) else { return };
        let Some(w) = self.transcript.as_ref().and_then(|t| t.words.get(i)) else { return };
        let start = w.range.start;
        self.events.push(CaptionsPanelEvent::Seek(start));
    }

    /// Updates the highlighted word from the playhead (source time). Binary search over sorted words.
    pub fn update_playhead(&mut self, time: Time) {
        let Some(words) = self.transcript.as_ref().map(|t| &t.words).filter(|w| !w.is_empty()) else {
            self.current_word_id = None;
            return;
        };
        let (mut lo, mut hi, mut found) = (0_i64, words.len() as i64 - 1, None);
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let r = words[mid as usize].range;
            if time < r.start {
                hi = mid - 1;
            } else if time >= r.end() {
                lo = mid + 1;
            } else {
                found = Some(mid as usize);
                break;
            }
        }
        let id = found.map(|i| words[i].id);
        if id != self.current_word_id {
            self.current_word_id = id;
            self.version += 1;
        }
    }

    // MARK: Captions

    /// Create Captions dialog: changes the limits of the selected preset (for this session; presets are not persisted).
    pub fn set_options(&mut self, max_chars_per_line: i64, lines: i64, min_duration: Time, gap_frames: i64) {
        let frame_duration = self.frame_duration;
        let Some(p) = self.presets.get_mut(self.selected_preset_index) else { return };
        p.preset = p.preset.with(&CaptionPresetOptions {
            max_chars_per_line: Some(max_chars_per_line),
            lines: Some(lines),
            min_duration: Some(min_duration),
            gap_frames: Some(gap_frames.min(3600)),
            frame_duration,
        });
        self.version += 1;
    }

    /// Create Captions dialog: the typed "Minimum duration" in seconds as time, clamped to 0...1 hour (a typed 1e30 or
    /// "inf" must not overflow the conversion).
    pub fn min_duration(seconds: f64) -> Time {
        if seconds.is_nan() {
            return Time::ZERO;
        }
        Time::new((seconds.clamp(0.0, 3600.0) * 1000.0).round() as i64, 1000)
    }

    /// The gap of the selected preset in frames (rounded).
    pub fn gap_frames(&self) -> i64 {
        let Some(p) = self.selected_preset() else { return 0 };
        let fd = self.frame_duration;
        if fd <= Time::ZERO {
            return 0;
        }
        (((p.gap.value() as f64) / (p.gap.timescale() as f64)) / ((fd.value() as f64) / (fd.timescale() as f64)) + 0.5)
            as i64
    }

    /// Segments the transcript with the selected preset and hands the result to the host (`CreateCaptions`).
    pub fn create_captions(&mut self) -> Vec<Caption> {
        self.flush_edits();
        let (true, Some(t), Some(preset)) = (self.can_create_captions(), &self.transcript, self.selected_preset())
        else {
            return Vec::new();
        };
        let captions = CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(t, preset), preset);
        self.events.push(CaptionsPanelEvent::CreateCaptions(captions.clone()));
        captions
    }

    // MARK: Auto captions

    /// Sequence > Transcribe and Create Captions: one command for "transcribe the whole timeline, add as captions". A
    /// transcript that still matches the sequence is reused (its typed corrections stay); otherwise the sequence is
    /// transcribed first (no overwrite question: the command asked for it). Then Create Captions runs with the selected
    /// preset, which the host sets to the default caption look. Returns the captions handed to the host when they are
    /// ready now; when a transcription has to run first, the captions follow as the `CreateCaptions` event after
    /// `finish` (empty when transcription failed or found no words: `state` says why).
    pub fn transcribe_and_create_captions(&mut self) -> Vec<Caption> {
        self.flush_edits();
        if matches!(self.state, CaptionsState::Transcribing { .. }) {
            self.create_when_ready = true;
            return Vec::new();
        }
        if self.transcript.is_none() || self.is_outdated || self.state != CaptionsState::Ready {
            if !self.can_transcribe() {
                return Vec::new();
            }
            self.create_when_ready = true;
            self.transcribe(true);
            return Vec::new();
        }
        self.create_captions()
    }

    /// Selects the preset Create Captions would pick in the Captions tab: the project's kit caption, else the default
    /// caption look (the last look saved as default), else Standard.
    pub fn use_default_caption_look(
        &mut self,
        kit: Option<&StyleKit>,
        library: &CaptionLookLibrary,
        settings: &dyn SettingsStore,
    ) {
        named_look_preset::install(self, library, settings, kit);
    }
}

impl Default for CaptionsPanelModel {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::TimeRange;
    use sq_transcribe::transcript::TranscriptWord;

    fn words(n: i64) -> Transcript {
        Transcript::new(
            "de-DE",
            (0..n)
                .map(|i| {
                    let r = TimeRange::from_end(Time::new(i, 2), Time::new(i + 1, 2));
                    TranscriptWord::new(Id::fixed(i as u64 + 1), &format!("Wort{i}"), r)
                })
                .collect(),
        )
    }

    fn ready(n: i64) -> CaptionsPanelModel {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.transcribe(false);
        let run = m.run_id;
        m.finish(Ok(words(n)), run);
        m
    }

    fn requests(m: &mut CaptionsPanelModel) -> Vec<TranscribeRequest> {
        m.take_events()
            .into_iter()
            .filter_map(|e| if let CaptionsPanelEvent::Transcribe(r) = e { Some(*r) } else { None })
            .collect()
    }

    #[test]
    fn the_two_steps_follow_the_transcript() {
        let mut m = CaptionsPanelModel::new();
        assert_eq!(m.step(), CaptionsStep::Transcribe);
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.transcribe(false);
        assert_eq!(m.step(), CaptionsStep::Transcribe, "still step 1 while it runs");
        let run = m.run_id;
        m.finish(Ok(words(3)), run);
        assert_eq!(m.step(), CaptionsStep::CreateCaptions);
        let empty = ready(0);
        assert_eq!(empty.step(), CaptionsStep::Transcribe, "no words: nothing to make captions from");
    }

    #[test]
    fn transcribing_asks_the_host_to_prepare_and_run() {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.set_language("de-DE");
        m.take_events();
        m.transcribe(false);
        let r = requests(&mut m);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].locale.identifier(), "de-DE");
        assert!(matches!(m.state(), CaptionsState::Transcribing { .. }) && m.status_note().is_some());
        m.preparation_done(r[0].run);
        m.finish(Ok(words(1)), r[0].run);
        assert!(*m.state() == CaptionsState::Ready && m.status_note().is_none());
    }

    #[test]
    fn a_failed_run_shows_its_message_and_a_stale_run_is_ignored() {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.transcribe(false);
        let run = m.run_id;
        m.finish(Err(TranscriptionError::LocaleUnsupported("xx-XX".into())), run + 1);
        assert!(matches!(m.state(), CaptionsState::Transcribing { .. }));
        m.finish(Err(TranscriptionError::LocaleUnsupported("xx-XX".into())), run);
        match m.state() {
            CaptionsState::Failed(msg) => assert!(msg.contains("xx-XX")),
            other => panic!("not failed: {other:?}"),
        }
        assert!(m.status_note().is_none());
    }

    #[test]
    fn model_download_progress_is_shown_in_the_note() {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.transcribe(false);
        let run = m.run_id;
        m.report_preparation(0.5, run);
        assert!(m.status_note().is_some_and(|n| n.contains("50 %")));
        m.report_preparation(1.0, run);
        assert!(m.status_note().is_some_and(|n| n.contains("50 %")));
        m.report_progress(7.0, run);
        assert_eq!(*m.state(), CaptionsState::Transcribing { progress: 1.0 });
    }

    #[test]
    fn transcribing_again_asks_before_overwriting() {
        let mut m = ready(3);
        m.take_events();
        m.transcribe(false);
        assert!(m.needs_overwrite_confirmation() && requests(&mut m).is_empty());
        m.cancel_overwrite();
        assert!(!m.needs_overwrite_confirmation());
        m.confirm_overwrite();
        assert_eq!(requests(&mut m).len(), 1);
    }

    #[test]
    fn canceling_returns_to_the_transcript_or_idle() {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        m.transcribe(false);
        m.cancel_transcription();
        assert_eq!(*m.state(), CaptionsState::Idle);
        let mut m = ready(2);
        m.transcribe(true);
        m.cancel_transcription();
        assert_eq!(*m.state(), CaptionsState::Ready);
    }

    #[test]
    fn edits_apply_when_the_host_flushes_after_the_debounce() {
        let mut m = ready(3);
        m.take_events();
        m.text_changed("Wort0 Neu Wort2");
        assert!(matches!(m.take_events()[..], [CaptionsPanelEvent::ScheduleFlush { after_ms: 400 }]));
        assert!(m.edited_word_ids().is_empty());
        m.flush_edits();
        assert_eq!(m.transcript().map(|t| t.text()).as_deref(), Some("Wort0 Neu Wort2"));
        assert_eq!(m.edited_word_ids().len(), 1);
    }

    #[test]
    fn word_ranges_are_utf16_and_clicks_map_to_words() {
        let mut m = ready(3);
        assert_eq!(m.word_ranges(), [0..5, 6..11, 12..17]);
        assert_eq!(m.word_index_at_character(5), Some(0));
        assert_eq!(m.word_index_at_character(6), Some(1));
        assert_eq!(m.word_index_at_character(999), Some(2));
        m.take_events();
        m.seek_to_character(7);
        assert!(matches!(m.take_events()[..], [CaptionsPanelEvent::Seek(t)] if t == Time::new(1, 2)));
    }

    #[test]
    fn the_playhead_finds_the_word_under_it() {
        let mut m = ready(40);
        m.update_playhead(Time::new(5, 4));
        assert_eq!(m.current_word_id(), Some(Id::fixed(3)));
        m.update_playhead(Time::new(100, 1));
        assert_eq!(m.current_word_id(), None);
    }

    #[test]
    fn create_captions_hands_the_segments_to_the_host() {
        let mut m = ready(6);
        m.take_events();
        let captions = m.create_captions();
        assert!(!captions.is_empty());
        assert!(matches!(&m.take_events()[..], [CaptionsPanelEvent::CreateCaptions(c)] if *c == captions));
        let mut idle = CaptionsPanelModel::new();
        assert!(idle.create_captions().is_empty());
    }

    #[test]
    fn transcribe_and_create_captions_runs_the_transcription_first() {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        assert!(m.transcribe_and_create_captions().is_empty());
        let run = requests(&mut m)[0].run;
        m.finish(Ok(words(6)), run);
        assert!(m.take_events().iter().any(|e| matches!(e, CaptionsPanelEvent::CreateCaptions(c) if !c.is_empty())));
        // A transcript that still matches is reused.
        assert!(!m.transcribe_and_create_captions().is_empty());
        assert!(requests(&mut m).is_empty());
    }

    #[test]
    fn options_gap_and_minimum_duration() {
        let mut m = CaptionsPanelModel::new();
        m.set_options(500, 5, Time::new(1, 2), 9999);
        let p = m.selected_preset().cloned();
        assert_eq!(p.as_ref().map(|p| (p.max_chars_per_line, p.max_lines)), Some((100, 2)));
        assert_eq!(m.gap_frames(), 3600);
        assert_eq!(CaptionsPanelModel::min_duration(f64::NAN), Time::ZERO);
        assert_eq!(CaptionsPanelModel::min_duration(1e30), Time::new(3_600_000, 1000));
        assert_eq!(CaptionsPanelModel::min_duration(-4.0), Time::ZERO);
        assert_eq!(CaptionsPanelModel::min_duration(0.25), Time::new(250, 1000));
    }

    #[test]
    fn supported_languages_sort_by_display_name() {
        let mut m = CaptionsPanelModel::new();
        let ids = ["en-US", "de-DE", "fr-FR", "en-GB"].map(String::from);
        m.apply_supported_languages(&ids);
        let got: Vec<&str> = m.languages.iter().map(String::as_str).collect();
        assert_eq!(got, ["en-GB", "en-US", "de-DE", "fr-FR"], "the common languages first, in the common order");
    }

    #[test]
    fn the_pop_up_lists_the_common_languages_then_the_rest_alphabetically_and_every_language_has_a_name() {
        let mut m = CaptionsPanelModel::new();
        m.apply_supported_languages(&sq_transcribe::whisper_languages::WhisperLanguages::supported());
        let shown: Vec<String> = m.languages.iter().map(|l| CaptionsPanelModel::language_title(l)).collect();
        for (id, title) in m.languages.iter().zip(&shown) {
            assert_ne!(title, id, "{id} shows as a bare code");
            let code = id.split('-').next().unwrap_or(id);
            assert!(title.chars().next().is_some_and(char::is_uppercase), "{id} -> {title}");
            assert!(title.chars().count() >= 3, "{id} -> {title}");
            assert!(!title.eq_ignore_ascii_case(code), "{id} -> {title}");
        }
        let common = m.common_language_count();
        assert_eq!(common, 16, "fifteen languages, English listed with two regions: {shown:?}");
        let head: Vec<&str> = shown[..common].iter().map(String::as_str).collect();
        assert_eq!(
            head,
            [
                "English (United Kingdom)",
                "English (United States)",
                "German (Germany)",
                "Spanish (Spain)",
                "French (France)",
                "Italian (Italy)",
                "Portuguese",
                "Dutch",
                "Polish",
                "Turkish",
                "Russian",
                "Japanese",
                "Chinese",
                "Korean",
                "Arabic",
                "Hindi"
            ][..head.len()]
        );
        let rest = &shown[common..];
        assert!(rest.windows(2).all(|w| standard_compare(&w[0], &w[1]).is_le()), "the rest is alphabetical");
        for name in ["Luxembourgish", "Lingala", "Lao", "Lithuanian", "Latvian", "Malagasy"] {
            assert!(rest.iter().any(|s| s == name), "{name}");
        }
    }

    #[test]
    fn supported_languages_keep_the_selected_one() {
        let mut m = CaptionsPanelModel::new();
        m.set_language("sv-SE");
        m.apply_supported_languages(&[]);
        assert_eq!(m.languages.len(), 6);
        m.apply_supported_languages(&["en-US".to_string(), "de-DE".to_string()]);
        assert!(m.languages.contains(&"sv-SE".to_string()) && m.languages.len() == 3);
    }
}
