//! The Export dialog's state: sequences, their formats (outputs), the selected output's settings, derived texts and
//! the checks that gate the Export button. Jobs, audio check, stems and cut-downs are in `model_jobs`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sq_core_edit::cover_frame::CoverFrame;
use sq_core_model::{DeliveryTarget, FormatVariant, Marker, SequenceFormat};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_export::core::audio_delivery::{
    AudioAnalysis, AudioDeliveryTarget, AudioFinding, AudioPreflight, AudioSeverity,
};
use sq_export::core::delivery::{DeliveryAdvice, DeliveryCheck, DeliveryIssue, SourceTraits};
use sq_export::core::encoder_support::{EncoderSupport, no_encoder_message};
use sq_export::core::error::{ExportDecodeError, ExportError};
use sq_export::core::hdr::{HdrDelivery, HdrTransfer};
use sq_export::core::loudness::LoudnessReport;
use sq_export::core::preflight::ExportPreflight;
use sq_export::core::preset::{ExportPreferences, ExportPreset, PresetKind, QualityStep, SequenceShape};
use sq_export::core::queue::ExportSources;
use sq_export::core::settings::{
    BitrateKind, BitrateMode, CaptionMode, CoverImageFormat, EncoderSpeed, ExportSettings, ExportSettingsIssue,
    LoudnessNormalization, RangeSelection, VideoCodec, VideoSettings,
};
use sq_export::core::stems::{Stem, StemPresetStore};
use sq_export::core::traits::{AudioSource, ExportEncoding, FrameSource};
use sq_export::formats::YouTubeChaptersResult;
use sq_media_ffmpeg::encode::{ProbeKind, ProbeState, cached};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqbyte_size::SQByteSize;

use super::format_text::{ExportSeconds, format_g, sanitize_file_name};

/// Builds the footage sources of one sequence for given settings (the host knows the renderer).
// Swift: Export/ExportDialogModel.swift:75
pub type SourceProvider = Arc<dyn Fn(Id, &ExportSettings) -> Result<ExportSources, ExportError> + Send + Sync>;
/// Footage preview source (the settings it gets are the preview's own: small, silent).
// Swift: Export/ExportDialogModel.swift:94
pub type PreviewSourceProvider =
    Arc<dyn Fn(Id, &ExportSettings) -> Result<Box<dyn FrameSource>, ExportError> + Send + Sync>;
/// Free bytes on the volume of a folder (`None` = unknown, no warning). Injected for tests.
// Swift: Export/ExportDialogModel.swift:98
pub type FreeSpaceProvider = Arc<dyn Fn(&Path) -> Option<i64> + Send + Sync>;
/// Builds the mix source of one stem of a sequence (the host knows the renderer); `None` = stems unavailable.
// Swift: Export/ExportDialogModel.swift:887
pub type StemAudioProvider =
    Arc<dyn Fn(Id, &Stem, TimeRange) -> Result<Box<dyn AudioSource>, ExportError> + Send + Sync>;

/// One pickable sequence of the dialog.
// Swift: Export/ExportDialogModel.swift:12
#[derive(Clone, Debug, PartialEq)]
pub struct SequenceItem {
    /// Sequence id.
    // Swift: Export/ExportDialogModel.swift:13
    pub id: Id,
    /// Shown name.
    // Swift: Export/ExportDialogModel.swift:14
    pub name: String,
    /// Length.
    // Swift: Export/ExportDialogModel.swift:15
    pub duration: Time,
    /// The sequence's In/Out range, if the user set one.
    // Swift: Export/ExportDialogModel.swift:17
    pub in_out: Option<TimeRange>,
    /// The sequence format: presets that follow the source (Match Source, YouTube frame rate) read it.
    // Swift: Export/ExportDialogModel.swift:19
    pub format: Option<SequenceFormat>,
    /// The sequence's platform and loudness target: sets its default preset and loudness normalization.
    // Swift: Export/ExportDialogModel.swift:21
    pub delivery_target: Option<DeliveryTarget>,
    /// The sequence's format variants: "Export All Formats" makes one job per variant.
    // Swift: Export/ExportDialogModel.swift:23
    pub variants: Vec<FormatVariant>,
    /// Where the sequence's marker named "Cover" sits; `None` = no such marker.
    // Swift: Export/ExportDialogModel.swift:25
    pub cover_time: Option<Time>,
    /// The sequence plays nested under a clip with Disguise Voice: exported on its own, that voice is not disguised.
    // Swift: Export/ExportDialogModel.swift:27
    pub nested_under_disguise_voice: bool,
    /// Audio clips whose sync offset against their linked picture is not zero: the audio check warns about them.
    // Swift: Export/ExportDialogModel.swift:30
    pub unsynced_audio_clips: i64,
    /// The clips selected in the timeline when the dialog opened (time order; `ExportDialogModel::new` sorts them).
    // Swift: Export/ExportDialogModel.swift:33
    pub selected_clips: Vec<SelectedClipRange>,
    /// The sequence's markers: named ones become the chapter list ("Copy Chapters").
    // Swift: Export/ExportDialogModel.swift:35
    pub markers: Vec<Marker>,
    /// What the sequence's used media looks like (variable frame rate, interlaced): the delivery chips read it.
    // Swift: Export/ExportDialogModel.swift:37
    pub source_traits: SourceTraits,
    /// The HDR transfer the sequence's clips target: the dialog suggests that HDR delivery.
    // Swift: Export/ExportDialogModel.swift:39
    pub hdr_target: Option<HdrTransfer>,
}

impl SequenceItem {
    /// An item with no In/Out, format, target, variants, markers or selection (the Swift defaults).
    // Swift: Export/ExportDialogModel.swift:40
    pub fn new(id: Id, name: &str, duration: Time) -> SequenceItem {
        SequenceItem {
            id,
            name: name.to_string(),
            duration,
            in_out: None,
            format: None,
            delivery_target: None,
            variants: Vec::new(),
            cover_time: None,
            nested_under_disguise_voice: false,
            unsynced_audio_clips: 0,
            selected_clips: Vec::new(),
            markers: Vec::new(),
            source_traits: SourceTraits::default(),
            hdr_target: None,
        }
    }
}

/// A selected clip's name and span on the sequence timeline.
// Swift: Export/ExportDialogModel.swift:56
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectedClipRange {
    /// Clip name.
    // Swift: Export/ExportDialogModel.swift:57
    pub name: String,
    /// Span on the sequence timeline.
    // Swift: Export/ExportDialogModel.swift:58
    pub range: TimeRange,
}

impl SelectedClipRange {
    /// A name and span.
    // Swift: Export/ExportDialogModel.swift:59
    pub fn new(name: &str, range: TimeRange) -> SelectedClipRange {
        SelectedClipRange { name: name.to_string(), range }
    }
}

/// One output of a sequence: a preset (possibly edited by hand) and its settings. A sequence has one or more.
// Swift: Export/ExportDialogModel.swift:63
#[derive(Clone, Debug, PartialEq)]
pub struct FormatEntry {
    /// Identity of the output.
    // Swift: Export/ExportDialogModel.swift:64
    pub id: Id,
    /// The preset it came from, or `ExportDialogModel::CUSTOM_PRESET_ID`.
    // Swift: Export/ExportDialogModel.swift:65
    pub preset_id: String,
    /// Its settings.
    // Swift: Export/ExportDialogModel.swift:66
    pub settings: ExportSettings,
    /// Unchecked formats stay in the list but are not exported.
    // Swift: Export/ExportDialogModel.swift:68
    pub enabled: bool,
    /// The name typed in the dialog's File Name field (`None` = derived from the sequence name).
    // Swift: Export/ExportDialogModel.swift:70
    pub file_name: Option<String>,
    /// The quality step the user picked: state, not a reading of the bitrate. The rate follows it (a new codec, size or
    /// frame rate recomputes it) until the user types a rate or picks a preset. Rust-only (the Swift sheet turns the
    /// bitrate into "Custom" and loses the step).
    pub quality_step: Option<QualityStep>,
}

impl FormatEntry {
    /// An enabled entry without a typed file name.
    // Swift: Export/ExportDialogModel.swift:71
    pub fn new(id: Id, preset_id: &str, settings: ExportSettings) -> FormatEntry {
        FormatEntry {
            id,
            preset_id: preset_id.to_string(),
            settings,
            enabled: true,
            file_name: None,
            quality_step: None,
        }
    }

    /// After a video edit: a typed rate drops the picked step; a new codec, size or frame rate gives the step its new rate.
    fn follow_quality_step(&mut self, before: &VideoSettings) {
        let Some(step) = self.quality_step else { return };
        let v = &mut self.settings.video;
        if v.bitrate.average_bits_per_second() != before.bitrate.average_bits_per_second() {
            self.quality_step = None;
        } else if v.codec != before.codec
            || v.width != before.width
            || v.height != before.height
            || v.frame_duration != before.frame_duration
        {
            v.apply_quality(step);
        }
    }
}

/// Start and end of the exported range in seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RangeSeconds {
    /// Start.
    pub start: f64,
    /// End.
    pub end: f64,
}

/// One row of the flat output list.
// Swift: Export/ExportDialogModel.swift:573
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputRow {
    /// The format entry.
    // Swift: Export/ExportDialogModel.swift:574
    pub id: Id,
    /// Its sequence.
    // Swift: Export/ExportDialogModel.swift:575
    pub sequence_id: Id,
    /// "Main · Vertical 9:16".
    // Swift: Export/ExportDialogModel.swift:576
    pub title: String,
    /// "1080 × 1920".
    // Swift: Export/ExportDialogModel.swift:577
    pub size_text: String,
    /// Ticked.
    // Swift: Export/ExportDialogModel.swift:578
    pub is_checked: bool,
    /// The output the detail properties edit.
    // Swift: Export/ExportDialogModel.swift:579
    pub is_selected: bool,
}

/// Something the host should do after a model call (Swift `onX` hooks).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExportDialogEvent {
    /// "Export Cut-downs" was pressed (Swift `onExportCutDowns`).
    ExportCutDowns,
}

/// The Export dialog's state (Swift `@Observable` class `ExportDialogModel`): `version` goes up with every change.
// Swift: Export/ExportDialogModel.swift:11
pub struct ExportDialogModel {
    pub(super) sequences: Vec<SequenceItem>,
    pub(super) checked_ids: BTreeSet<Id>,
    pub(super) selected_id: Id,
    pub(super) formats_by_sequence: BTreeMap<Id, Vec<FormatEntry>>,
    pub(super) selected_format_id: Id,
    pub(super) preview_source: Option<PreviewSourceProvider>,
    pub(super) source_provider: SourceProvider,
    pub(super) export_all_formats: bool,
    pub(super) free_space: FreeSpaceProvider,
    /// What the encoder probe knows about a kind of file (`cached` in the app; a test plays other computers).
    probe_state: fn(ProbeKind) -> ProbeState,
    pub(super) output_directory: Option<PathBuf>,
    max_edited_by_hand: BTreeSet<Id>,
    custom_range_ids: BTreeSet<Id>,
    selection_range_ids: BTreeSet<Id>,
    pub(super) one_file_per_clip: bool,
    pub(super) audio_checks: BTreeMap<Id, AudioCheckResult>,
    pub(super) audio_check_running: BTreeSet<Id>,
    pub(super) audio_check_error: Option<String>,
    pub(super) stem_audio: Option<StemAudioProvider>,
    pub(super) stem_encoder: Option<Arc<dyn ExportEncoding>>,
    pub(super) stem_plans: BTreeMap<Id, Vec<Stem>>,
    pub(super) is_exporting_stems: bool,
    pub(super) stem_progress: f64,
    pub(super) stem_status: Option<String>,
    pub(super) stem_preset_store: Option<StemPresetStore>,
    pub(super) user_stem_presets: Vec<sq_export::core::stems::StemPreset>,
    pub(super) stem_unchecked: BTreeSet<String>,
    pub(super) cut_down_unchecked: BTreeSet<CutDownKey>,
    pub(super) events: Vec<ExportDialogEvent>,
    pub(super) ids: Box<dyn IdSource>,
    pub(crate) version: u64,
}

/// One planned cut-down range: target length, position inside that target's plan.
// Swift: Export/ExportDialogModel.swift:974
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CutDownKey {
    /// Target length in seconds.
    // Swift: Export/ExportDialogModel.swift:975
    pub target: i64,
    /// Index inside that target's plan.
    // Swift: Export/ExportDialogModel.swift:976
    pub index: usize,
}

impl CutDownKey {
    /// A key.
    // Swift: Export/ExportDialogModel.swift:977
    pub fn new(target: i64, index: usize) -> CutDownKey {
        CutDownKey { target, index }
    }
}

/// The result of one audio check, kept per output while its range still matches.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct AudioCheckResult {
    pub(super) analysis: AudioAnalysis,
    pub(super) range: RangeSelection,
    /// What Normalize will really do (peak limiter included), predicted for `predicted_target`; `None` without Normalize.
    pub(super) predicted: Option<LoudnessReport>,
    pub(super) predicted_target: Option<LoudnessNormalization>,
}

fn preset_by_id(id: &str) -> Option<ExportPreset> {
    ExportPreset::all().into_iter().find(|p| p.id() == id)
}

fn home_directory() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map_or_else(|| PathBuf::from("."), PathBuf::from)
}

impl ExportDialogModel {
    /// The id of the hand-edited "Custom" entry.
    // Swift: Export/ExportDialogModel.swift:77
    pub const CUSTOM_PRESET_ID: &'static str = "custom";
    /// The frame rates the picker offers.
    // Swift: Export/ExportDialogModel.swift:79
    pub const FRAME_RATES: [f64; 8] = [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0];

    /// Free space for "important usage": the platform probe of the preflight (unknown until the app installs one).
    // Swift: Export/ExportDialogModel.swift:658
    pub fn system_free_space() -> FreeSpaceProvider {
        Arc::new(ExportPreflight::free_bytes)
    }

    /// `initial_preset == None`: every sequence starts with its own platform's preset (`ExportPreset::default_preset`);
    /// the Swift default is `Some(ExportPreset::DEFAULT)`. Panics without a sequence (a Swift precondition). New ids
    /// (formats, jobs, saved stem presets) come from `ids`.
    // Swift: Export/ExportDialogModel.swift:104
    pub fn new(
        mut sequences: Vec<SequenceItem>,
        initial_preset: Option<ExportPreset>,
        free_space: FreeSpaceProvider,
        sources: SourceProvider,
        mut ids: Box<dyn IdSource>,
    ) -> ExportDialogModel {
        assert!(!sequences.is_empty(), "Export needs at least one sequence");
        for s in &mut sequences {
            s.selected_clips.sort_by_key(|c| c.range.start);
        }
        let first = sequences[0].id;
        let mut formats_by_sequence = BTreeMap::new();
        let mut selected_format_id = first;
        for (i, s) in sequences.iter().enumerate() {
            let preset = initial_preset
                .or_else(|| Self::hdr_preset(s))
                .unwrap_or_else(|| ExportPreset::default_preset(s.format.as_ref(), s.delivery_target.as_ref()));
            let mut settings = Self::with_hdr_suggestion(
                Self::with_dialog_defaults(
                    preset.settings_matching_target(s.format.as_ref(), s.delivery_target.as_ref()),
                ),
                s,
            );
            if let Some(r) = Self::default_in_out(s, &settings) {
                settings.range = RangeSelection::InOut(r);
            }
            let entry = FormatEntry::new(ids.next_id(), &preset.id(), settings);
            if i == 0 {
                selected_format_id = entry.id;
            }
            formats_by_sequence.insert(s.id, vec![entry]);
        }
        ExportDialogModel {
            sequences,
            checked_ids: BTreeSet::from([first]),
            selected_id: first,
            formats_by_sequence,
            selected_format_id,
            preview_source: None,
            source_provider: sources,
            export_all_formats: false,
            free_space,
            probe_state: cached,
            output_directory: None,
            max_edited_by_hand: BTreeSet::new(),
            custom_range_ids: BTreeSet::new(),
            selection_range_ids: BTreeSet::new(),
            one_file_per_clip: false,
            audio_checks: BTreeMap::new(),
            audio_check_running: BTreeSet::new(),
            audio_check_error: None,
            stem_audio: None,
            stem_encoder: None,
            stem_plans: BTreeMap::new(),
            is_exporting_stems: false,
            stem_progress: 0.0,
            stem_status: None,
            stem_preset_store: None,
            user_stem_presets: Vec::new(),
            stem_unchecked: BTreeSet::new(),
            cut_down_unchecked: BTreeSet::new(),
            events: Vec::new(),
            ids,
            version: 0,
        }
    }

    /// Goes up with every change a view reads.
    pub fn version(&self) -> u64 {
        self.version
    }

    pub(super) fn bump(&mut self) {
        self.version += 1;
    }

    /// Hooks the host should act on (Swift `onExportCutDowns`), in call order.
    pub fn take_events(&mut self) -> Vec<ExportDialogEvent> {
        std::mem::take(&mut self.events)
    }

    // MARK: Selection

    /// The pickable sequences.
    // Swift: Export/ExportDialogModel.swift:80
    pub fn sequences(&self) -> &[SequenceItem] {
        &self.sequences
    }

    /// Ticked sequences.
    // Swift: Export/ExportDialogModel.swift:82
    pub fn checked_ids(&self) -> &BTreeSet<Id> {
        &self.checked_ids
    }

    /// Replaces the ticked sequences.
    pub fn set_checked_ids(&mut self, ids: BTreeSet<Id>) {
        self.checked_ids = ids;
        self.bump();
    }

    /// The sequence the detail properties edit.
    // Swift: Export/ExportDialogModel.swift:83
    pub fn selected_id(&self) -> Id {
        self.selected_id
    }

    /// Selects a sequence (its selected format stays as set; use `select_format` to move both).
    pub fn set_selected_id(&mut self, id: Id) {
        self.selected_id = id;
        self.bump();
    }

    /// The format the detail properties edit (of the selected sequence); falls back to its first one.
    // Swift: Export/ExportDialogModel.swift:86
    pub fn selected_format_id(&self) -> Id {
        self.selected_format_id
    }

    /// Sets the format id the detail properties edit.
    pub fn set_selected_format_id(&mut self, id: Id) {
        self.selected_format_id = id;
        self.bump();
    }

    /// Footage preview source (`None` = the dialog shows no picture).
    // Swift: Export/ExportDialogModel.swift:88
    pub fn preview_source(&self) -> Option<&PreviewSourceProvider> {
        self.preview_source.as_ref()
    }

    /// Sets the footage preview source.
    pub fn set_preview_source(&mut self, p: Option<PreviewSourceProvider>) {
        self.preview_source = p;
        self.bump();
    }

    /// Also export every format variant of the checked sequences.
    // Swift: Export/ExportDialogModel.swift:91
    pub fn export_all_formats(&self) -> bool {
        self.export_all_formats
    }

    /// Sets "Export All Formats".
    pub fn set_export_all_formats(&mut self, on: bool) {
        self.export_all_formats = on;
        self.bump();
    }

    /// Whether any checked sequence has variants (the "Export All Formats" checkbox is shown then).
    // Swift: Export/ExportDialogModel.swift:93
    pub fn has_variants(&self) -> bool {
        self.checked_sequences().iter().any(|s| !s.variants.is_empty())
    }

    /// Where the files will go; `None` until the user picks a folder (the check then uses the home volume).
    // Swift: Export/ExportDialogModel.swift:101
    pub fn output_directory(&self) -> Option<&Path> {
        self.output_directory.as_deref()
    }

    /// Sets the output folder.
    pub fn set_output_directory(&mut self, dir: Option<PathBuf>) {
        self.output_directory = dir;
        self.bump();
    }

    /// Every preset of the menu.
    // Swift: Export/ExportDialogModel.swift:127
    pub fn presets(&self) -> Vec<ExportPreset> {
        ExportPreset::all()
    }

    /// Whether a sequence is ticked.
    // Swift: Export/ExportDialogModel.swift:129
    pub fn is_checked(&self, id: Id) -> bool {
        self.checked_ids.contains(&id)
    }

    /// Ticks or unticks a sequence.
    // Swift: Export/ExportDialogModel.swift:131
    pub fn set_checked(&mut self, id: Id, on: bool) {
        if on {
            self.checked_ids.insert(id);
        } else {
            self.checked_ids.remove(&id);
        }
        self.bump();
    }

    /// The ticked sequences, in project order.
    // Swift: Export/ExportDialogModel.swift:134
    pub fn checked_sequences(&self) -> Vec<&SequenceItem> {
        self.sequences.iter().filter(|s| self.checked_ids.contains(&s.id)).collect()
    }

    pub(super) fn selected_item(&self) -> &SequenceItem {
        self.sequences.iter().find(|s| s.id == self.selected_id).unwrap_or(&self.sequences[0])
    }

    // MARK: Formats (several per sequence)

    /// The outputs of a sequence.
    // Swift: Export/ExportDialogModel.swift:138
    pub fn formats(&self, id: Id) -> &[FormatEntry] {
        self.formats_by_sequence.get(&id).map_or(&[], Vec::as_slice)
    }

    /// The selected sequence's format being edited.
    // Swift: Export/ExportDialogModel.swift:142
    pub fn selected_format(&self) -> &FormatEntry {
        let fs = self.formats(self.selected_id);
        fs.iter().find(|f| f.id == self.selected_format_id).unwrap_or(&fs[0])
    }

    fn mutate_selected_format(&mut self, f: impl FnOnce(&mut FormatEntry)) {
        let id = self.selected_format().id;
        if let Some(e) =
            self.formats_by_sequence.get_mut(&self.selected_id).and_then(|fs| fs.iter_mut().find(|e| e.id == id))
        {
            f(e);
        }
        self.bump();
    }

    /// Selects an output (and its sequence).
    // Swift: Export/ExportDialogModel.swift:153
    pub fn select_format(&mut self, id: Id) {
        let owner = self.sequences.iter().find(|s| self.formats(s.id).iter().any(|f| f.id == id)).map(|s| s.id);
        if let Some(seq) = owner {
            self.selected_id = seq;
            self.selected_format_id = id;
            self.bump();
        }
    }

    /// Adds a format to the selected sequence and selects it. `preset_id == None`: the first preset the sequence does
    /// not use yet.
    // Swift: Export/ExportDialogModel.swift:161
    pub fn add_format(&mut self, preset_id: Option<&str>) {
        let used: BTreeSet<String> = self.formats(self.selected_id).iter().map(|f| f.preset_id.clone()).collect();
        let all = ExportPreset::all();
        let Some(p) = all
            .iter()
            .find(|p| Some(p.id()) == preset_id.map(str::to_string))
            .or_else(|| all.iter().find(|p| !used.contains(&p.id())))
            .or_else(|| all.first())
            .copied()
        else {
            return;
        };
        let item = self.selected_item();
        let fresh = Self::with_hdr_suggestion(
            Self::with_dialog_defaults(p.settings_matching_target(item.format.as_ref(), item.delivery_target.as_ref())),
            item,
        );
        let settings = self.carry(fresh, &self.selected_format().settings, &p);
        let entry = FormatEntry::new(self.ids.next_id(), &p.id(), settings);
        self.selected_format_id = entry.id;
        self.formats_by_sequence.entry(self.selected_id).or_default().push(entry);
        self.bump();
    }

    /// Copies an output of the selected sequence right below itself and selects the copy.
    // Swift: Export/ExportDialogModel.swift:170
    pub fn duplicate_format(&mut self, id: Id) {
        let new_id = self.ids.next_id();
        let Some(fs) = self.formats_by_sequence.get_mut(&self.selected_id) else { return };
        let Some(i) = fs.iter().position(|f| f.id == id) else { return };
        let mut copy = fs[i].clone();
        copy.id = new_id;
        fs.insert(i + 1, copy);
        self.selected_format_id = new_id;
        self.bump();
    }

    /// Removes a format of the selected sequence; the last one stays.
    // Swift: Export/ExportDialogModel.swift:180
    pub fn remove_format(&mut self, id: Id) {
        let was_selected = self.selected_format().id == id;
        let Some(fs) = self.formats_by_sequence.get_mut(&self.selected_id) else { return };
        if fs.len() <= 1 {
            return;
        }
        let Some(i) = fs.iter().position(|f| f.id == id) else { return };
        fs.remove(i);
        if was_selected {
            self.selected_format_id = fs[i.min(fs.len() - 1)].id;
        }
        self.bump();
    }

    /// Ticks or unticks one output (the checkbox of its row, without touching its sequence).
    // Swift: Export/ExportDialogModel.swift:187
    pub fn set_format_enabled(&mut self, id: Id, on: bool) {
        for fs in self.formats_by_sequence.values_mut() {
            if let Some(e) = fs.iter_mut().find(|e| e.id == id) {
                e.enabled = on;
                break;
            }
        }
        self.bump();
    }

    /// Enabled formats of the checked sequences, in project order.
    pub(super) fn active_formats(&self) -> Vec<(&SequenceItem, &FormatEntry)> {
        self.checked_sequences()
            .into_iter()
            .flat_map(|item| self.formats(item.id).iter().filter(|f| f.enabled).map(move |f| (item, f)))
            .collect()
    }

    /// Number of files the Export button writes.
    // Swift: Export/ExportDialogModel.swift:200
    pub fn job_count(&self) -> i64 {
        self.active_formats()
            .iter()
            .map(|(item, f)| {
                if let Some(clips) = self.per_clip_ranges(item, &f.settings) {
                    return clips.len() as i64;
                }
                let variants = if self.export_all_formats && f.settings.audio_only.is_none() {
                    item.variants.len() as i64
                } else {
                    0
                };
                1 + variants
            })
            .sum()
    }

    /// "Export 3 files", or "Export".
    // Swift: Export/ExportDialogModel.swift:206
    pub fn export_button_title(&self) -> String {
        let n = self.job_count();
        if n > 1 { SQL10n::format("Export %@ files", &[&n.to_string()]) } else { SQL10n::string("Export") }
    }

    /// Which preset a format came from, by name ("Custom" once edited by hand).
    // Swift: Export/ExportDialogModel.swift:210
    pub fn preset_name(&self, entry: &FormatEntry) -> String {
        preset_by_id(&entry.preset_id).map_or_else(|| SQL10n::string("Custom"), |p| SQL10n::localized(&p.name()))
    }

    /// Short label of a format row: "1080×1920 · H.264".
    // Swift: Export/ExportDialogModel.swift:215
    pub fn format_label(&self, entry: &FormatEntry) -> String {
        let s = &entry.settings;
        if let Some(f) = s.audio_only {
            return SQL10n::format("Audio only · %@", &[&f.file_extension().to_uppercase()]);
        }
        if let Some(o) = &s.frame_output {
            return format!("{}×{} · {}", s.video.width, s.video.height, SQL10n::localized(&o.display_name()));
        }
        format!("{}×{} · {}", s.video.width, s.video.height, s.video.codec.display_name())
    }

    // MARK: Settings of the selected format

    /// Settings of the selected output.
    // Swift: Export/ExportDialogModel.swift:222
    pub fn settings(&self) -> &ExportSettings {
        &self.selected_format().settings
    }

    /// Replaces the settings of the selected output (the preset stays).
    pub fn set_settings(&mut self, s: ExportSettings) {
        self.mutate_selected_format(|e| e.settings = s);
    }

    /// The first enabled format of a sequence (its main output); used where one number per sequence is needed.
    // Swift: Export/ExportDialogModel.swift:229
    pub fn settings_for(&self, id: Id) -> ExportSettings {
        let fs = self.formats(id);
        fs.iter()
            .find(|f| f.enabled)
            .or(fs.first())
            .map_or_else(|| ExportPreset::DEFAULT.settings(), |f| f.settings.clone())
    }

    /// A preset never touches captions/loudness/range: those are per-export choices (kept from `old`).
    fn carry(&self, new: ExportSettings, old: &ExportSettings, preset: &ExportPreset) -> ExportSettings {
        let mut s = new;
        s.captions = old.captions;
        s.range = old.range;
        s.cover_image = old.cover_image;
        s.continue_on_damaged_frames = old.continue_on_damaged_frames;
        s.hdr_to_sdr = old.hdr_to_sdr;
        s.hdr_delivery = old.hdr_delivery;
        s.set_encoder_speed(old.encoder_speed());
        s.audio.loudness = old.audio.loudness.map(|_| self.default_loudness(Some(preset), None));
        if s.audio_only.is_some() && s.captions == CaptionMode::BurnIn {
            s.captions = CaptionMode::None; // no picture to burn into
        }
        s
    }

    /// Preset id, or `CUSTOM_PRESET_ID` once a video detail was edited by hand.
    // Swift: Export/ExportDialogModel.swift:249
    pub fn preset_id(&self) -> &str {
        &self.selected_format().preset_id
    }

    /// The preset the sheet names: `preset_id`, unless the output's size is not the size that preset gives this
    /// sequence (YouTube 1080p on a vertical sequence keeps 1080 x 1920), then `CUSTOM_PRESET_ID`. The label never
    /// names a size the file will not have.
    pub fn shown_preset_id(&self) -> &str {
        let id = self.preset_id();
        let Some(p) = preset_by_id(id) else { return id };
        let want = p.settings_matching(self.selected_item().format.as_ref()).video;
        let have = &self.settings().video;
        if (want.width, want.height) == (have.width, have.height) { id } else { Self::CUSTOM_PRESET_ID }
    }

    /// Applies a preset the user picked to the selected output: the preset's own size (an unknown id changes nothing).
    pub fn set_preset_id(&mut self, id: &str) {
        self.apply_preset_id(id, false);
    }

    /// Applies a preset to the selected output while the sheet opens (the last preset exported with): a preset of another
    /// shape than the sequence keeps the sequence's size.
    pub fn open_with_preset_id(&mut self, id: &str) {
        self.apply_preset_id(id, true);
    }

    fn apply_preset_id(&mut self, id: &str, keep_sequence_shape: bool) {
        let Some(p) = preset_by_id(id) else { return };
        let item = self.selected_item();
        let fresh = if keep_sequence_shape {
            p.settings_matching_target(item.format.as_ref(), item.delivery_target.as_ref())
        } else {
            p.settings_matching(item.format.as_ref())
        };
        let s = self.carry(fresh, self.settings(), &p);
        let fid = self.selected_format().id;
        self.max_edited_by_hand.remove(&fid);
        self.mutate_selected_format(|e| {
            e.settings = s;
            e.preset_id = p.id();
            e.quality_step = None;
        });
    }

    /// What double-click resets a numeric field to: the selected preset's settings for this sequence, or the default
    /// preset's once the format is "Custom".
    // Swift: Export/ExportDialogModel.swift:264
    pub fn preset_settings(&self) -> ExportSettings {
        let p = preset_by_id(self.preset_id()).unwrap_or(ExportPreset::DEFAULT);
        let item = self.selected_item();
        p.settings_matching_target(item.format.as_ref(), item.delivery_target.as_ref())
    }

    /// Edits the selected format's settings; a change to the video part turns the preset into "Custom".
    // Swift: Export/ExportDialogModel.swift:270
    pub fn edit(&mut self, f: impl FnOnce(&mut ExportSettings)) {
        self.mutate_selected_format(|e| {
            let before = e.settings.video.clone();
            f(&mut e.settings);
            if e.settings.video != before {
                e.preset_id = Self::CUSTOM_PRESET_ID.to_string();
                e.follow_quality_step(&before);
            }
        });
    }

    /// Sets the target bitrate to a quality step (Smaller / Standard / Best). Unlike a typed bitrate it keeps the chosen
    /// preset (the Rust sheet differs from Swift on purpose); the step is how the preset is used.
    pub fn set_quality_step(&mut self, step: QualityStep) {
        self.mutate_selected_format(|e| {
            e.settings.video.apply_quality(step);
            if step.bits_per_pixel(e.settings.video.codec).is_some() {
                e.quality_step = Some(step);
            }
        });
    }

    /// The quality step the sheet lights: the one the user picked, else the one the bitrate sits on, else the nearest
    /// (a preset's own bitrate rarely sits on a step), so one is always on for H.264 and HEVC. The one source for the
    /// highlight; the rate shown beside it is the bitrate this step produced.
    pub fn quality_step(&self) -> Option<QualityStep> {
        let v = &self.settings().video;
        self.selected_format().quality_step.or_else(|| v.quality_step()).or_else(|| v.nearest_quality_step())
    }

    fn edit_video(&mut self, f: impl FnOnce(&mut VideoSettings)) {
        self.mutate_selected_format(|e| {
            let before = e.settings.video.clone();
            f(&mut e.settings.video);
            e.preset_id = Self::CUSTOM_PRESET_ID.to_string();
            e.follow_quality_step(&before);
        });
    }

    /// Edits the settings without turning the preset into "Custom" (captions, loudness, range...).
    fn edit_settings(&mut self, f: impl FnOnce(&mut ExportSettings)) {
        self.mutate_selected_format(|e| f(&mut e.settings));
    }

    /// Video codec.
    // Swift: Export/ExportDialogModel.swift:281
    pub fn codec(&self) -> VideoCodec {
        self.settings().video.codec
    }

    /// Sets the codec (the preset becomes "Custom").
    pub fn set_codec(&mut self, c: VideoCodec) {
        self.edit_video(|v| v.codec = c);
    }

    /// Width in pixels.
    // Swift: Export/ExportDialogModel.swift:286
    pub fn width(&self) -> i64 {
        self.settings().video.width
    }

    /// Sets the width (the preset becomes "Custom").
    pub fn set_width(&mut self, w: i64) {
        self.edit_video(|v| v.width = w);
    }

    /// Height in pixels.
    // Swift: Export/ExportDialogModel.swift:290
    pub fn height(&self) -> i64 {
        self.settings().video.height
    }

    /// Sets the height (the preset becomes "Custom").
    pub fn set_height(&mut self, h: i64) {
        self.edit_video(|v| v.height = h);
    }

    /// Frame rate; the NTSC rates (24000/1001...) report the picker's tag (23.976) so the picker can match it.
    // Swift: Export/ExportDialogModel.swift:294
    pub fn fps(&self) -> f64 {
        let d = self.settings().video.frame_duration;
        if d.value() <= 0 {
            return 0.0;
        }
        let raw = d.timescale() as f64 / d.value() as f64;
        Self::FRAME_RATES.iter().copied().find(|r| (r - raw).abs() < 0.01).unwrap_or(raw)
    }

    /// Sets the frame rate (the preset becomes "Custom").
    pub fn set_fps(&mut self, fps: f64) {
        let t = if fps == 23.976 {
            Time::new(1001, 24000)
        } else if fps == 29.97 {
            Time::new(1001, 30000)
        } else if fps == 59.94 {
            Time::new(1001, 60000)
        } else {
            Time::new(1, (fps.round() as i64).max(1))
        };
        self.edit_video(|v| v.frame_duration = t);
    }

    /// Average video bitrate in Mbit/s.
    // Swift: Export/ExportDialogModel.swift:317
    pub fn bitrate_mbps(&self) -> f64 {
        self.settings().video.bitrate.average_bits_per_second() as f64 / 1_000_000.0
    }

    /// Sets the average bitrate in Mbit/s. A max bitrate, if present, follows at 1.5x until it was edited by hand;
    /// then it stays, but is raised to the target when the target goes above it.
    pub fn set_bitrate_mbps(&mut self, v: f64) {
        let avg = (v * 1_000_000.0).round() as i64;
        let manual = self.max_edited_by_hand.contains(&self.selected_format().id);
        self.edit_video(|vs| {
            vs.bitrate = match vs.bitrate.max_bits_per_second() {
                None => BitrateMode::Average(avg),
                Some(old_max) => BitrateMode::AverageAndMax {
                    average: avg,
                    max: if manual { old_max.max(avg) } else { avg * 3 / 2 },
                },
            };
        });
    }

    /// VBR or CBR (H.264 / HEVC).
    // Swift: Export/ExportDialogModel.swift:331
    pub fn bitrate_kind(&self) -> BitrateKind {
        self.settings().video.bitrate_kind()
    }

    /// CBR has no Maximum: the hand-edit state resets and a stored Maximum goes back to following Target at 1.5x, so
    /// it is sensible again when the mode returns to VBR.
    pub fn set_bitrate_kind(&mut self, kind: BitrateKind) {
        if kind == self.settings().video.bitrate_kind() {
            return;
        }
        if kind == BitrateKind::Cbr {
            let fid = self.selected_format().id;
            self.max_edited_by_hand.remove(&fid);
        }
        self.edit_video(|v| {
            v.set_bitrate_kind(kind);
            let avg = v.bitrate.average_bits_per_second();
            if kind == BitrateKind::Cbr && v.bitrate.max_bits_per_second().is_some() {
                v.bitrate = BitrateMode::AverageAndMax { average: avg, max: avg * 3 / 2 };
            }
        });
    }

    /// Whether a maximum bitrate is set.
    // Swift: Export/ExportDialogModel.swift:343
    pub fn has_max_bitrate(&self) -> bool {
        self.settings().video.bitrate.max_bits_per_second().is_some()
    }

    /// Turns the maximum bitrate on (1.5x the target) or off.
    pub fn set_has_max_bitrate(&mut self, on: bool) {
        let fid = self.selected_format().id;
        self.max_edited_by_hand.remove(&fid);
        self.edit_video(|v| {
            let avg = v.bitrate.average_bits_per_second();
            v.bitrate = if on {
                BitrateMode::AverageAndMax { average: avg, max: avg * 3 / 2 }
            } else {
                BitrateMode::Average(avg)
            };
        });
    }

    /// Maximum video bitrate in Mbit/s (only meaningful while `has_max_bitrate`).
    // Swift: Export/ExportDialogModel.swift:356
    pub fn max_bitrate_mbps(&self) -> f64 {
        let b = self.settings().video.bitrate;
        b.max_bits_per_second().unwrap_or_else(|| b.average_bits_per_second()) as f64 / 1_000_000.0
    }

    /// Sets the maximum (never below the average) and marks it as edited by hand.
    pub fn set_max_bitrate_mbps(&mut self, v: f64) {
        let fid = self.selected_format().id;
        self.max_edited_by_hand.insert(fid);
        self.edit_video(|vs| {
            let avg = vs.bitrate.average_bits_per_second();
            vs.bitrate = BitrateMode::AverageAndMax { average: avg, max: ((v * 1_000_000.0).round() as i64).max(avg) };
        });
    }

    /// Loudness normalization on or off.
    // Swift: Export/ExportDialogModel.swift:363
    pub fn normalize_loudness(&self) -> bool {
        self.settings().audio.loudness_target().is_some()
    }

    /// Turns normalization on (to the sequence's or preset's target) or off.
    pub fn set_normalize_loudness(&mut self, on: bool) {
        let l = on.then(|| self.default_loudness(preset_by_id(self.preset_id()).as_ref(), None));
        self.edit_settings(|s| s.audio.loudness = l);
    }

    /// The sequence's delivery target wins over the preset's platform target.
    fn default_loudness(&self, preset: Option<&ExportPreset>, item: Option<&SequenceItem>) -> LoudnessNormalization {
        if let Some(t) = &item.unwrap_or_else(|| self.selected_item()).delivery_target {
            return LoudnessNormalization::new(t.target_lufs, t.true_peak_db);
        }
        preset.map_or_else(LoudnessNormalization::default, ExportPreset::loudness)
    }

    /// Toggle label: the active target and true-peak ceiling.
    // Swift: Export/ExportDialogModel.swift:378
    pub fn loudness_label(&self) -> String {
        let l = self
            .settings()
            .audio
            .loudness
            .unwrap_or_else(|| self.default_loudness(preset_by_id(self.preset_id()).as_ref(), None));
        SQL10n::format(
            "Normalize loudness to %@ LUFS, max %@ dBTP",
            &[&(l.target_lufs.round() as i64).to_string(), &(l.true_peak_ceiling_db.round() as i64).to_string()],
        )
    }

    /// Caption mode.
    // Swift: Export/ExportDialogModel.swift:382
    pub fn captions(&self) -> CaptionMode {
        self.settings().captions
    }

    /// Sets the caption mode.
    pub fn set_captions(&mut self, c: CaptionMode) {
        self.edit_settings(|s| s.captions = c);
    }

    /// "Also save cover image": a still next to the video, taken at the sequence's "Cover" marker (else the first frame).
    // Swift: Export/ExportDialogModel.swift:389
    pub fn cover_image(&self) -> Option<CoverImageFormat> {
        self.settings().cover_image
    }

    /// Sets the cover image format (`None` = no cover).
    pub fn set_cover_image(&mut self, c: Option<CoverImageFormat>) {
        self.edit_settings(|s| s.cover_image = c);
    }

    /// What the cover image shows, for the dialog: the marker's time or the first-frame fallback.
    // Swift: Export/ExportDialogModel.swift:395
    pub fn cover_frame_text(&self) -> String {
        let Some(t) = self.selected_item().cover_time else {
            return SQL10n::string("First frame (add a marker named \"Cover\" to choose)");
        };
        let fd = self.settings().video.frame_duration;
        SQL10n::format("Marker \"%@\" at %@", &[CoverFrame::MARKER_NAME, &ExportDecodeError::timecode(t, fd)])
    }

    /// Encoder speed (a per-Mac choice).
    // Swift: Export/ExportDialogModel.swift:404
    pub fn encoder_speed(&self) -> EncoderSpeed {
        self.settings().encoder_speed()
    }

    /// Sets the encoder speed for every format at once; it never turns a preset into "Custom".
    pub fn set_encoder_speed(&mut self, speed: EncoderSpeed) {
        for e in self.formats_by_sequence.values_mut().flatten() {
            e.settings.set_encoder_speed(speed);
        }
        self.bump();
    }

    /// Note under the Encoder Speed row: on a Mac with 8 GB or less, while Quality is picked, suggest Balanced.
    // Swift: Export/ExportDialogModel.swift:414
    pub fn encoder_speed_hint(speed: EncoderSpeed, physical_memory: u64) -> Option<String> {
        Self::encoder_speed_hint_on(sq_os::Platform::current(), speed, physical_memory)
    }

    /// `encoder_speed_hint` for a given system: "this Mac" on the Mac, "this computer" elsewhere.
    pub fn encoder_speed_hint_on(
        platform: sq_os::Platform,
        speed: EncoderSpeed,
        physical_memory: u64,
    ) -> Option<String> {
        if speed != EncoderSpeed::Quality {
            return None;
        }
        EncoderSpeed::suggested(physical_memory).map(|s| {
            let machine = if platform == sq_os::Platform::Mac { "Mac" } else { "computer" };
            format!("{} exports faster on this {machine}", s.display_name())
        })
    }

    /// A frame that cannot be decoded is drawn as a placeholder instead of stopping the export.
    // Swift: Export/ExportDialogModel.swift:419
    pub fn continue_on_damaged_frames(&self) -> bool {
        self.settings().continue_on_damaged_frames
    }

    /// Sets "Continue on damaged frames".
    pub fn set_continue_on_damaged_frames(&mut self, on: bool) {
        self.edit_settings(|s| s.continue_on_damaged_frames = on);
    }

    /// What the export covers: the In/Out range when it is on, else the whole selected sequence.
    pub fn exported_range(&self) -> TimeRange {
        match self.settings().range {
            RangeSelection::InOut(r) => r,
            RangeSelection::EntireSequence => TimeRange::new(Time::ZERO, self.selected_item().duration),
        }
    }

    /// Whether the selected sequence has an In/Out range.
    // Swift: Export/ExportDialogModel.swift:424
    pub fn can_use_in_out(&self) -> bool {
        self.selected_item().in_out.is_some()
    }

    /// Whether the range is the sequence's In/Out.
    // Swift: Export/ExportDialogModel.swift:426
    pub fn use_in_out(&self) -> bool {
        matches!(self.settings().range, RangeSelection::InOut(_))
    }

    /// In/Out on (the sequence's range) or off (entire sequence).
    pub fn set_use_in_out(&mut self, on: bool) {
        let r = self.selected_item().in_out;
        self.edit_settings(|s| {
            s.range = match (on, r) {
                (true, Some(r)) => RangeSelection::InOut(r),
                _ => RangeSelection::EntireSequence,
            }
        });
    }

    // MARK: Custom range

    /// Export every selected clip as its own file (only while the range is "Selected clips").
    // Swift: Export/ExportDialogModel.swift:441
    pub fn one_file_per_clip(&self) -> bool {
        self.one_file_per_clip
    }

    /// Sets "One file per clip".
    pub fn set_one_file_per_clip(&mut self, on: bool) {
        self.one_file_per_clip = on;
        self.bump();
    }

    /// Number of clips selected in the timeline when the dialog opened.
    // Swift: Export/ExportDialogModel.swift:442
    pub fn selected_clip_count(&self) -> usize {
        self.selected_item().selected_clips.len()
    }

    /// Whether "Selected clips" can be picked.
    // Swift: Export/ExportDialogModel.swift:444
    pub fn can_use_selection(&self) -> bool {
        !self.selected_item().selected_clips.is_empty()
    }

    /// First start to last end of the selected clips of `item`.
    pub(super) fn selection_span(item: &SequenceItem) -> Option<TimeRange> {
        let first = item.selected_clips.first()?;
        let end = item.selected_clips.iter().map(|c| c.range.end()).max().unwrap_or_else(|| first.range.end());
        Some(TimeRange::from_end(first.range.start, end))
    }

    /// The per-clip ranges a format of `item` is split into; `None` when it is one file.
    pub(super) fn per_clip_ranges<'a>(
        &self,
        item: &'a SequenceItem,
        settings: &ExportSettings,
    ) -> Option<&'a [SelectedClipRange]> {
        let RangeSelection::InOut(r) = settings.range else { return None };
        (self.one_file_per_clip
            && self.selection_range_ids.contains(&item.id)
            && !item.selected_clips.is_empty()
            && Some(r) == Self::selection_span(item))
        .then_some(item.selected_clips.as_slice())
    }

    /// 0 = entire sequence, 1 = In to Out, 2 = custom start and end, 3 = the selected clips.
    // Swift: Export/ExportDialogModel.swift:461
    pub fn range_mode(&self) -> i64 {
        let RangeSelection::InOut(r) = self.settings().range else { return 0 };
        if self.selection_range_ids.contains(&self.selected_id) && Some(r) == Self::selection_span(self.selected_item())
        {
            return 3;
        }
        if self.custom_range_ids.contains(&self.selected_id) { 2 } else { 1 }
    }

    /// Switches the range mode (see `range_mode`).
    pub fn set_range_mode(&mut self, mode: i64) {
        let id = self.selected_id;
        if mode != 3 {
            self.selection_range_ids.remove(&id);
        }
        match mode {
            3 => {
                if let Some(span) = Self::selection_span(self.selected_item()) {
                    self.custom_range_ids.remove(&id);
                    self.selection_range_ids.insert(id);
                    self.edit_settings(|s| s.range = RangeSelection::InOut(span));
                }
            }
            2 => {
                self.custom_range_ids.insert(id);
                if !matches!(self.settings().range, RangeSelection::InOut(_)) {
                    let item = self.selected_item();
                    let r = item.in_out.unwrap_or_else(|| TimeRange::new(Time::ZERO, item.duration));
                    self.edit_settings(|s| s.range = RangeSelection::InOut(r));
                }
            }
            1 => {
                self.custom_range_ids.remove(&id);
                self.set_use_in_out(true);
            }
            _ => {
                self.custom_range_ids.remove(&id);
                self.set_use_in_out(false);
            }
        }
        self.bump();
    }

    /// Start and end of the exported range in seconds (the whole sequence when no range is set).
    // Swift: Export/ExportDialogModel.swift:490
    pub fn range_seconds(&self) -> RangeSeconds {
        match self.settings().range {
            RangeSelection::InOut(r) => RangeSeconds { start: r.start.export_seconds(), end: r.end().export_seconds() },
            RangeSelection::EntireSequence => {
                RangeSeconds { start: 0.0, end: self.selected_item().duration.export_seconds() }
            }
        }
    }

    /// The range the export covers, as the sheet shows it: the picked In/Out, custom or selection span, or the whole
    /// sequence for Entire. Never the marks of a sequence whose Range is Entire: a stray one-frame mark would read as
    /// the export range.
    pub fn effective_range(&self) -> TimeRange {
        match self.settings().range {
            RangeSelection::InOut(r) => r,
            RangeSelection::EntireSequence => TimeRange::new(Time::ZERO, self.selected_item().duration),
        }
    }

    /// Sets one edge of the custom range, snapped to whole frames and kept inside the sequence with at least one frame.
    // Swift: Export/ExportDialogModel.swift:496
    pub fn set_custom_range(&mut self, start_seconds: Option<f64>, end_seconds: Option<f64>) {
        let fd = self.settings().video.frame_duration;
        let frame = fd.export_seconds().max(0.000_001);
        let total = self.selected_item().duration.export_seconds();
        let snap = |v: f64| Time::new((v / frame).round() as i64 * fd.value(), fd.timescale());
        let RangeSeconds { start: mut a, end: mut b } = self.range_seconds();
        if let Some(v) = start_seconds {
            a = v.max(0.0).min((total - frame).max(0.0));
        }
        if let Some(v) = end_seconds {
            b = v.max(frame).min(total);
        }
        let (mut start, mut end) = (snap(a), snap(b));
        if end <= start {
            if start_seconds.is_some() {
                end = start + fd;
            } else {
                start = end - fd;
            }
        }
        if start < Time::ZERO {
            start = Time::ZERO;
        }
        let id = self.selected_id;
        self.custom_range_ids.insert(id);
        self.selection_range_ids.remove(&id);
        self.edit_settings(|s| s.range = RangeSelection::InOut(TimeRange::from_end(start, end)));
    }

    // MARK: Derived

    /// Length of the main output of a sequence.
    // Swift: Export/ExportDialogModel.swift:513
    pub fn effective_duration(&self, id: Id) -> Time {
        self.effective_duration_with(id, &self.settings_for(id))
    }

    /// Length of a sequence exported with `settings`.
    // Swift: Export/ExportDialogModel.swift:515
    pub fn effective_duration_with(&self, id: Id, settings: &ExportSettings) -> Time {
        if let RangeSelection::InOut(r) = settings.range {
            return r.duration;
        }
        self.sequences.iter().find(|s| s.id == id).map_or(Time::ZERO, |s| s.duration)
    }

    /// Total estimated size of every enabled format of all checked sequences, in bytes.
    // Swift: Export/ExportDialogModel.swift:522
    pub fn estimated_bytes(&self) -> i64 {
        self.active_formats()
            .iter()
            .map(|(item, f)| f.settings.estimated_file_size(self.effective_duration_with(item.id, &f.settings)))
            .sum()
    }

    /// The frame rate as written: exact NTSC tags (23.976, 29.97, 59.94), whole rates without decimals. Derived from
    /// the frame duration the export writer receives, so the summary can never disagree with the file.
    // Swift: Export/ExportDialogModel.swift:530
    pub fn frame_rate_text(d: Time) -> String {
        if d.value() <= 0 {
            return "0".to_string();
        }
        let raw = d.timescale() as f64 / d.value() as f64;
        if let Some(tag) = Self::FRAME_RATES.iter().copied().find(|t| (t - raw).abs() < 0.01) {
            return if tag == tag.round() { format!("{}", tag as i64) } else { format_g(tag, 6) };
        }
        if raw == raw.round() { format!("{}", raw as i64) } else { format!("{raw:.2}") }
    }

    /// "1920×1080 · 29.97 fps · H.264 · 12 Mbit/s" for the selected output.
    // Swift: Export/ExportDialogModel.swift:538
    pub fn summary_text(&self) -> String {
        let v = &self.settings().video;
        let codec = format!(
            "{}{}",
            v.codec.display_name(),
            if !v.codec.is_pro_res() && v.bit_depth() == 10 { " 10-bit" } else { "" }
        );
        let mut parts = vec![
            format!("{}×{}", v.width, v.height),
            format!("{} fps", Self::frame_rate_text(v.frame_duration)),
            codec,
        ];
        if !v.codec.is_mastering() {
            parts.push(format!("{} Mbit/s", format_g(self.bitrate_mbps(), 3)));
        }
        parts.join(" · ")
    }

    /// Whether the estimate is a ceiling, not a forecast: an encoder given an average bitrate (VBR) or a constant quality
    /// only spends what the picture needs, so a simple clip comes out smaller (a "Best" 21.8 Mbit/s target wrote 11.9).
    /// Only a constant bitrate, ProRes and audio keep to the rate they were given.
    pub fn estimated_size_is_upper_bound(&self) -> bool {
        self.active_formats().iter().any(|(_, f)| {
            let s = &f.settings;
            s.audio_only.is_none()
                && s.frame_output.is_none()
                && !s.video.codec.is_mastering()
                && !s.video.uses_constant_bitrate()
        })
    }

    /// "~ 48 MB": bitrate x duration (+ audio) of every enabled output of the checked sequences; "up to 48 MB" when the
    /// encoder may stay below its target ([`Self::estimated_size_is_upper_bound`]).
    // Swift: Export/ExportDialogModel.swift:547
    pub fn estimated_size_text(&self) -> String {
        let size = SQByteSize::string(self.estimated_bytes());
        if self.estimated_size_is_upper_bound() { format!("up to {size}") } else { format!("~ {size}") }
    }

    /// A sequence without a platform target whose clips target HDR starts on the HEVC 10-bit preset (H.264 cannot carry it).
    // Swift: Export/ExportDialogModel.swift:553
    pub(crate) fn hdr_preset(item: &SequenceItem) -> Option<ExportPreset> {
        (item.hdr_target.is_some() && item.delivery_target.is_none()).then_some(ExportPreset::HEVC_10)
    }

    /// Switches the HDR delivery on for the clips' target transfer (HEVC only); the user can set it back to SDR.
    // Swift: Export/ExportDialogModel.swift:558
    pub(crate) fn with_hdr_suggestion(s: ExportSettings, item: &SequenceItem) -> ExportSettings {
        Self::with_hdr_target(s, item.hdr_target)
    }

    /// `with_hdr_suggestion` for a bare target transfer (the headless export has no `SequenceItem`).
    pub fn with_hdr_target(s: ExportSettings, target: Option<HdrTransfer>) -> ExportSettings {
        let Some(t) = target else { return s };
        if s.video.codec != VideoCodec::Hevc
            || s.audio_only.is_some()
            || s.frame_output.is_some()
            || s.hdr_delivery.is_some()
        {
            return s;
        }
        let mut s = s;
        s.hdr_delivery = Some(HdrDelivery { transfer: t, ..HdrDelivery::default() });
        s
    }

    /// Settings every new output starts with that the presets do not own: captions are burned in.
    // Swift: Export/ExportDialogModel.swift:564
    pub fn with_dialog_defaults(s: ExportSettings) -> ExportSettings {
        let mut s = s;
        s.captions = CaptionMode::BurnIn;
        s
    }

    // MARK: Output list (one flat list, one row per output file)

    /// "Vertical 9:16", "Horizontal 16:9", "Square 1:1", "Portrait 4:5"; other shapes read as their size.
    // Swift: Export/ExportDialogModel.swift:583
    pub fn aspect_name(width: i64, height: i64) -> String {
        if width <= 0 || height <= 0 {
            return format!("{width} × {height}");
        }
        let is = |a: i64, b: i64| width * b == height * a;
        if is(9, 16) {
            SQL10n::string("Vertical 9:16")
        } else if is(16, 9) {
            SQL10n::string("Horizontal 16:9")
        } else if is(1, 1) {
            SQL10n::string("Square 1:1")
        } else if is(4, 5) {
            SQL10n::string("Portrait 4:5")
        } else {
            format!("{width} × {height}")
        }
    }

    /// One row per output of every sequence.
    // Swift: Export/ExportDialogModel.swift:592
    pub fn output_rows(&self) -> Vec<OutputRow> {
        let selected = self.selected_format().id;
        self.sequences
            .iter()
            .flat_map(|item| {
                self.formats(item.id).iter().map(move |f| {
                    let v = &f.settings.video;
                    let audio_only = f.settings.audio_only;
                    OutputRow {
                        id: f.id,
                        sequence_id: item.id,
                        title: if audio_only.is_none() {
                            format!("{} · {}", item.name, Self::aspect_name(v.width, v.height))
                        } else {
                            SQL10n::format("%@ · Audio only", &[&item.name])
                        },
                        size_text: audio_only
                            .map(|a| a.file_extension().to_uppercase())
                            .or_else(|| f.settings.frame_output.as_ref().map(|o| SQL10n::localized(&o.display_name())))
                            .unwrap_or_else(|| format!("{} × {}", v.width, v.height)),
                        is_checked: self.checked_ids.contains(&item.id) && f.enabled,
                        is_selected: f.id == selected && item.id == self.selected_id,
                    }
                })
            })
            .collect()
    }

    /// Ticks or unticks one output. Ticking also ticks its sequence; unticking the last output of a sequence unticks it.
    // Swift: Export/ExportDialogModel.swift:609
    pub fn set_output_checked(&mut self, id: Id, on: bool) {
        let Some(seq) = self.sequences.iter().find(|s| self.formats(s.id).iter().any(|f| f.id == id)).map(|s| s.id)
        else {
            return;
        };
        if on && !self.checked_ids.contains(&seq) {
            // The sequence was unticked: its other outputs carry stale "enabled" flags and must not start exporting with it.
            let others: Vec<Id> = self.formats(seq).iter().filter(|f| f.id != id).map(|f| f.id).collect();
            for o in others {
                self.set_format_enabled(o, false);
            }
        }
        self.set_format_enabled(id, on);
        if on {
            self.checked_ids.insert(seq);
        } else if !self.formats(seq).iter().any(|f| f.enabled) {
            self.checked_ids.remove(&seq);
        }
        self.bump();
    }

    /// Selects an output.
    // Swift: Export/ExportDialogModel.swift:619
    pub fn select_output(&mut self, id: Id) {
        self.select_format(id);
    }

    /// "2 files · about 72 MB · 00:00:18:00 each" under the list.
    // Swift: Export/ExportDialogModel.swift:623
    pub fn output_summary_text(&self) -> String {
        let n = self.job_count();
        let size = SQByteSize::string(self.estimated_bytes());
        let mut parts = vec![SQL10n::plural(n, "%@ file", "%@ files"), SQL10n::format("about %@", &[&size])];
        let active = self.active_formats();
        if let Some((_, first)) = active.first() {
            let durations: Vec<Time> =
                active.iter().map(|(i, f)| self.effective_duration_with(i.id, &f.settings)).collect();
            let fd = first.settings.video.frame_duration;
            let each = if n > 1 && durations.iter().all(|d| *d == durations[0]) {
                SQL10n::string(" each")
            } else {
                String::new()
            };
            parts.push(format!("{}{each}", ExportDecodeError::timecode(durations[0], fd)));
        }
        parts.join(" · ")
    }

    // MARK: File name

    /// Characters a file name cannot carry, plus control characters; leading and trailing dots/blanks go too.
    // Swift: Export/ExportDialogModel.swift:639
    pub fn sanitized_file_name(s: &str) -> String {
        sanitize_file_name(s)
    }

    /// The name of the selected output without extension: what was typed, else the sequence name.
    // Swift: Export/ExportDialogModel.swift:647
    pub fn file_name(&self) -> String {
        self.selected_format().file_name.clone().unwrap_or_else(|| sanitize_file_name(&self.selected_item().name))
    }

    /// Sets the typed file name (cleaned; empty = derived from the sequence name again).
    pub fn set_file_name(&mut self, name: &str) {
        let clean = sanitize_file_name(name);
        self.mutate_selected_format(|e| e.file_name = (!clean.is_empty()).then_some(clean));
    }

    /// Extension of the selected output's file.
    // Swift: Export/ExportDialogModel.swift:654
    pub fn file_extension(&self) -> &'static str {
        self.settings().file_extension()
    }

    /// Free bytes on the target volume, `None` if unknown.
    // Swift: Export/ExportDialogModel.swift:671
    pub fn available_bytes(&self) -> Option<i64> {
        (self.free_space)(&self.output_directory.clone().unwrap_or_else(home_directory))
    }

    /// EXP-19: the estimated output does not fit on the target volume.
    // Swift: Export/ExportDialogModel.swift:676
    pub fn disk_space_message(&self) -> Option<String> {
        if self.checked_ids.is_empty() {
            return None;
        }
        let free = self.available_bytes()?;
        let est = self.estimated_bytes();
        (est > free).then(|| {
            SQL10n::format(
                "Not enough free disk space: the export needs about %@, %@ available.",
                &[&SQByteSize::string(est), &SQByteSize::string(free.max(0))],
            )
        })
    }

    /// Everything that blocks the Export button, in plain words; empty = ready.
    // Swift: Export/ExportDialogModel.swift:681
    pub fn validation_messages(&self) -> Vec<String> {
        if self.checked_ids.is_empty() {
            return vec![SQL10n::string("Select at least one sequence to export.")];
        }
        if self.job_count() == 0 {
            return vec![SQL10n::string("Tick at least one format to export.")];
        }
        let mut issues = BTreeSet::new();
        let mut empty_range = false;
        for (item, f) in self.active_formats() {
            issues.extend(f.settings.validate());
            if self.effective_duration_with(item.id, &f.settings) <= Time::ZERO {
                empty_range = true;
            }
        }
        let mut out = Vec::new();
        let mut add = |i: ExportSettingsIssue, text: &str| {
            if issues.contains(&i) {
                out.push(SQL10n::string(text));
            }
        };
        add(ExportSettingsIssue::OddDimensions, "Width and height must be even numbers greater than 0.");
        add(
            ExportSettingsIssue::NonPositiveBitrate,
            "Bitrate must be greater than 0, and the maximum not below the average.",
        );
        add(ExportSettingsIssue::InvalidKeyframeInterval, "Keyframe interval must be at least 1 frame.");
        add(ExportSettingsIssue::InvalidFrameDuration, "Frame rate is not valid.");
        add(ExportSettingsIssue::InvalidAudio, "Audio settings are not valid.");
        if empty_range {
            out.push(SQL10n::string("The export range is empty."));
        }
        out.extend(self.no_encoder_messages());
        out.extend(self.platform_limit_messages());
        out.extend(self.disk_space_message());
        out
    }

    /// Upload limits of a checked format's platform preset (X: length and file size) that the export would exceed.
    // Swift: Export/ExportDialogModel.swift:704
    pub fn platform_limit_messages(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (item, f) in self.active_formats() {
            let Some(preset) = preset_by_id(&f.preset_id) else { continue };
            let Some(lim) = preset.limits() else { continue };
            let d = self.effective_duration_with(item.id, &f.settings);
            let bytes = f.settings.estimated_file_size(d);
            let name = SQL10n::localized(&preset.name());
            if d > lim.max_duration {
                out.push(SQL10n::format(
                    "%@ allows at most %@ seconds; this export is %@ seconds.",
                    &[
                        &name,
                        &(lim.max_duration.export_seconds() as i64).to_string(),
                        &(d.export_seconds().round() as i64).to_string(),
                    ],
                ));
            } else if bytes > lim.max_file_bytes {
                out.push(SQL10n::format(
                    "%@ allows at most %@; this export is about %@.",
                    &[&name, &SQByteSize::string(lim.max_file_bytes), &SQByteSize::string(bytes)],
                ));
            }
        }
        out
    }

    /// Whether the Export button is enabled.
    // Swift: Export/ExportDialogModel.swift:718
    pub fn can_export(&self) -> bool {
        self.validation_messages().is_empty()
    }

    /// Delivery chips for the checked formats (source traits, frame rate, audio rate, platform length); never block.
    // Swift: Export/ExportDialogModel.swift:722
    pub fn delivery_issues(&self) -> Vec<DeliveryIssue> {
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        for (item, f) in self.active_formats() {
            let Some(preset) = preset_by_id(&f.preset_id) else { continue };
            let d = self.effective_duration_with(item.id, &f.settings);
            let platform = item.delivery_target.as_ref().map(|t| t.platform);
            for issue in DeliveryCheck::issues(&f.settings, &preset, d, item.source_traits, platform) {
                if seen.insert(issue.id) {
                    out.push(issue);
                }
            }
        }
        out
    }

    /// Quiet note lines under the chips: odd sequence size and which encoder runs (and why software).
    // Swift: Export/ExportDialogModel.swift:735
    pub fn delivery_notes(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for (item, f) in self.active_formats() {
            let Some(preset) = preset_by_id(&f.preset_id) else { continue };
            if let Some(fmt) = &item.format
                && let Some(w) = DeliveryAdvice::odd_size_note(fmt.width, fmt.height)
                && matches!(
                    preset.kind,
                    PresetKind::MatchSource
                        | PresetKind::Hevc10
                        | PresetKind::ProRes
                        | PresetKind::ProRes422
                        | PresetKind::ProRes4444
                )
            {
                out.push(w);
            }
        }
        if let Some(e) = DeliveryCheck::encoder(self.settings()) {
            // Once this computer's encoder was probed, the note names it and what it cannot do.
            out.push(match self.encoder_support() {
                Some(support) if e.is_hardware && !support.hardware => {
                    format!("This computer has no hardware encoder for this file. {}", support.note())
                }
                Some(support) if e.is_hardware => support.note(),
                Some(support) => format!("{} {}", e.reason, support.note()),
                None => e.reason,
            });
        }
        let mut seen = BTreeSet::new();
        out.retain(|s| seen.insert(s.clone()));
        out
    }

    /// The encoder of this computer for the selected output and what it cannot do; `None` until the encoder probe ran.
    pub fn encoder_support(&self) -> Option<EncoderSupport> {
        self.encoder_support_of(self.settings())
    }

    fn encoder_support_of(&self, settings: &ExportSettings) -> Option<EncoderSupport> {
        EncoderSupport::of_with(settings, self.probe_state)
    }

    /// Replaces the encoder probe's answers (tests of a computer without a 10-bit encoder, with or without hardware).
    pub fn set_probe_state(&mut self, state: fn(ProbeKind) -> ProbeState) {
        self.probe_state = state;
    }

    /// The refusal of every checked output whose chosen codec or depth no encoder of this computer opens.
    fn no_encoder_messages(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (_, f) in self.active_formats() {
            if self.encoder_support_of(&f.settings).is_some_and(|s| !s.has_encoder()) {
                let text = no_encoder_message(&f.settings);
                if !out.contains(&text) {
                    out.push(text);
                }
            }
        }
        out
    }

    /// Everything the sheet shows as a quiet note line under the warning.
    // Swift: Export/ExportDialogModel.swift:748
    pub fn export_notes(&self) -> String {
        let mut lines: Vec<String> = self.disguise_voice_hint().into_iter().collect();
        lines.extend(self.delivery_notes().iter().map(|n| SQL10n::localized(n)));
        lines.join("\n")
    }

    /// A one-line note (no block) when a checked sequence sits under a Disguise Voice clip of another sequence.
    // Swift: Export/ExportDialogModel.swift:753
    pub fn disguise_voice_hint(&self) -> Option<String> {
        self.checked_sequences().iter().any(|s| s.nested_under_disguise_voice).then(|| {
            SQL10n::string(
                "Disguise Voice sits on a clip outside this sequence. Exported alone, the original voice is heard.",
            )
        })
    }

    // MARK: Remembered choices (kept by the app)

    /// The selected output's preset and per-export choices, for the app to store after an export.
    // Swift: Export/ExportDialogModel.swift:761
    pub fn preferences(&self) -> ExportPreferences {
        let f = self.selected_format();
        // A step is only worth remembering when it moved the bitrate off the preset's own.
        let own = self.preset_settings().video.bitrate;
        let step =
            f.quality_step.or_else(|| f.settings.video.quality_step()).filter(|_| f.settings.video.bitrate != own);
        let item = self.selected_item();
        ExportPreferences::new(&f.preset_id, &f.settings, self.export_all_formats)
            .with_quality_step(step)
            .with_sequence_shape(SequenceShape::of(item.format.as_ref(), item.delivery_target.as_ref()))
    }

    /// The sequence's In/Out as the sheet's starting range: only a real one (longer than one output frame). A stray
    /// mark pair (Out at the In, a single frame) never narrows the export to nothing; "In to Out" stays pickable.
    fn default_in_out(item: &SequenceItem, settings: &ExportSettings) -> Option<TimeRange> {
        let r = item.in_out?;
        (r.duration > settings.video.frame_duration).then_some(r)
    }

    /// Whether a stored size has the aspect of the sequence's frame (within 1 %); no format: it fits.
    fn fits_aspect(width: i64, height: i64, format: Option<&SequenceFormat>) -> bool {
        let Some(f) = format else { return true };
        let (a, b) = (i128::from(width) * i128::from(f.height), i128::from(height) * i128::from(f.width));
        (a - b).abs() * 100 <= a.max(b)
    }

    /// Starts every sequence's first output from the remembered choices. A sequence with a delivery target keeps its own
    /// platform preset and loudness target (the remembered preset only decides sequences without one, and audio-only);
    /// captions, cover, audio and the other choices apply to all.
    // Swift: Export/ExportDialogModel.swift:768
    pub fn apply_preferences(&mut self, p: &ExportPreferences) {
        self.export_all_formats = p.export_all_formats && self.has_variants();
        let items = self.sequences.clone();
        for item in &items {
            if self.formats_by_sequence.get(&item.id).is_none_or(Vec::is_empty) {
                continue;
            }
            let own = ExportPreset::default_preset(item.format.as_ref(), item.delivery_target.as_ref());
            // Picks made on a sequence of this shape and target come back as they were, over the platform preset.
            let same_shape = p.sequence_shape.is_some()
                && p.sequence_shape == SequenceShape::of(item.format.as_ref(), item.delivery_target.as_ref());
            let free = item.delivery_target.is_none() || same_shape;
            let mut preset = own;
            if let Some(c) = p.preset()
                && (free || c.is_audio_only())
            {
                preset = c;
            }
            // A remembered Custom size only returns on a sequence of its own aspect: an 8K 16:9 Custom from an earlier
            // project must not push 7680 x 4320 onto a 9:16 sequence (it starts at its own size instead).
            let custom = p.preset_id == ExportPreferences::CUSTOM_PRESET_ID
                && free
                && p.custom_video.as_ref().is_none_or(|v| Self::fits_aspect(v.width, v.height, item.format.as_ref()));
            let mut s = Self::with_hdr_suggestion(
                Self::with_dialog_defaults(
                    preset.settings_matching_target(item.format.as_ref(), item.delivery_target.as_ref()),
                ),
                item,
            );
            if let Some(r) = Self::default_in_out(item, &s) {
                s.range = RangeSelection::InOut(r);
            }
            let mut pref = p.clone();
            if !custom {
                // The step belongs to the remembered preset: a sequence on its own platform preset keeps its bitrate.
                if pref.preset_id != preset.id() {
                    pref.quality_step = None;
                }
                pref.preset_id = preset.id();
            }
            pref.apply(&mut s, self.default_loudness(Some(&preset), Some(item)));
            if s.audio_only.is_some() {
                s.audio.enabled = true;
                if s.captions == CaptionMode::BurnIn {
                    s.captions = CaptionMode::None;
                }
            }
            if let Some(first) = self.formats_by_sequence.get_mut(&item.id).and_then(|fs| fs.first_mut()) {
                first.settings = s;
                first.preset_id = if custom { Self::CUSTOM_PRESET_ID.to_string() } else { preset.id() };
                first.quality_step = if custom { None } else { pref.quality_step };
            }
        }
        self.audio_checks.clear();
        self.bump();
    }

    // MARK: Audio check state

    /// The outputs whose audio check is running.
    // Swift: Export/ExportDialogModel.swift:803
    pub fn audio_check_running(&self) -> &BTreeSet<Id> {
        &self.audio_check_running
    }

    /// Set when the check could not read the audio (shown under the button).
    // Swift: Export/ExportDialogModel.swift:805
    pub fn audio_check_error(&self) -> Option<&str> {
        self.audio_check_error.as_deref()
    }

    /// Whether the selected output has an audio check that still matches its range.
    // Swift: Export/ExportDialogModel.swift:808
    pub fn has_audio_check(&self) -> bool {
        self.audio_checks.get(&self.selected_format().id).is_some_and(|r| r.range == self.settings().range)
    }

    /// Whether the selected output's audio check is running.
    // Swift: Export/ExportDialogModel.swift:809
    pub fn is_checking_audio(&self) -> bool {
        self.audio_check_running.contains(&self.selected_format().id)
    }

    /// The result of the audio check of the selected output, judged against its loudness target; empty before a check.
    // Swift: Export/ExportDialogModel.swift:812
    pub fn audio_findings(&self) -> Vec<AudioFinding> {
        let Some(r) = self.audio_checks.get(&self.selected_format().id).filter(|r| r.range == self.settings().range)
        else {
            return Vec::new();
        };
        let s = self.settings();
        let normalizing = s.audio.loudness.is_some();
        let target =
            s.audio.loudness.unwrap_or_else(|| self.default_loudness(preset_by_id(self.preset_id()).as_ref(), None));
        let predicted = (normalizing && r.predicted_target == Some(target)).then_some(r.predicted.as_ref()).flatten();
        AudioPreflight::evaluate(
            &r.analysis,
            target,
            normalizing,
            usize::try_from(self.selected_item().unsynced_audio_clips).unwrap_or(0),
            predicted,
            AudioDeliveryTarget::matching(target)
                .map_or(AudioPreflight::LOUDNESS_TOLERANCE_LU, AudioDeliveryTarget::tolerance_lu),
        )
    }

    /// Loudness Range (EBU Tech 3342) is meaningless under 60 s: the dialog greys it out for short programs.
    // Swift: Export/ExportDialogModel.swift:823
    pub fn loudness_range_available(&self) -> bool {
        AudioDeliveryTarget::loudness_range_available(self.effective_duration(self.selected_item().id).export_seconds())
    }

    /// Index into `AudioDeliveryTarget::ALL` of the current normalization target, `None` when custom or off.
    // Swift: Export/ExportDialogModel.swift:828
    pub fn delivery_target_index(&self) -> Option<usize> {
        let t = AudioDeliveryTarget::matching(self.settings().audio.loudness?)?;
        AudioDeliveryTarget::ALL.iter().position(|x| *x == t)
    }

    /// Findings that make the export unwise (a pass or a warning never blocks).
    // Swift: Export/ExportDialogModel.swift:833
    pub fn audio_check_failures(&self) -> Vec<AudioFinding> {
        self.audio_findings().into_iter().filter(|f| f.severity == AudioSeverity::Fail).collect()
    }

    // MARK: Chapters

    /// The selected output's chapter list from the sequence's named markers (shifted to the export range); `None`
    /// without markers.
    // Swift: Export/ExportDialogModel.swift:876
    pub fn chapters(&self) -> Option<YouTubeChaptersResult> {
        let item = self.selected_item();
        if item.markers.is_empty() {
            return None;
        }
        let start = match self.settings().range {
            RangeSelection::InOut(r) => r.start,
            RangeSelection::EntireSequence => Time::ZERO,
        };
        Some(sq_export::formats::YouTubeChapters::make(
            &item.markers,
            start,
            Some(self.effective_duration(self.selected_id)),
        ))
    }
}
