//! The Export dialog's long-running parts: audio check, stems, cut-downs and the export jobs.
//!
//! Swift runs the audio check and the stem export as `Task`s on the main actor. Here each is a request the host runs
//! on a worker (`begin_*` -> `Request::run` -> `finish_*`); `run_audio_check` and `export_stems` do all three inline
//! (blocking) for hosts without a worker and for tests.

use std::path::Path;
use std::sync::Arc;

use sq_core_edit::cut_down_planner::{CutDownPlanner, Plan};
use sq_core_model::Timeline;
use sq_core_time::{Id, Time, TimeRange};
use sq_export::core::audio_delivery::AudioPreflight;
use sq_export::core::error::{CancelToken, ExportError};
use sq_export::core::queue::{ExportJob, ExportQueue, ExportSources, MakeSourcesFor};
use sq_export::core::settings::{
    AudioFileFormat, AudioSettings, ExportSettings, LoudnessNormalization, RangeSelection,
};
use sq_export::core::stems::{Stem, StemExporter, StemPreset};
use sq_export::core::traits::ExportEncoding;
use sq_uikit::localization::SQL10n;

use super::model::{
    AudioCheckResult, CutDownKey, ExportDialogEvent, ExportDialogModel, FormatEntry, SequenceItem, SourceProvider,
    StemAudioProvider,
};

/// An audio check ready to run (blocking; give it to a worker).
pub struct AudioCheckRequest {
    entry_id: Id,
    sequence: Id,
    probe: ExportSettings,
    range: RangeSelection,
    normalize_target: Option<LoudnessNormalization>,
    provider: SourceProvider,
}

/// What an audio check found; hand it to `ExportDialogModel::finish_audio_check`.
pub struct AudioCheckOutcome {
    entry_id: Id,
    result: Option<AudioCheckResult>,
    failure: Option<String>,
}

impl AudioCheckRequest {
    /// Mixes the sequence once and measures it (and predicts what Normalize will do).
    pub fn run(self, cancel: &CancelToken) -> AudioCheckOutcome {
        let mut result = None;
        let mut failure = None;
        let mut fail = |e: ExportError| {
            if e != ExportError::Cancelled {
                failure = Some(SQL10n::format("The audio could not be read: %@", &[&SQL10n::error_text(&e)]));
            }
        };
        match (self.provider)(self.sequence, &self.probe) {
            Err(e) => fail(e),
            Ok(mut sources) => match sources.audio.as_mut().and_then(|a| a.as_rewindable()) {
                None => failure = Some(SQL10n::string("This sequence has no audio to check.")),
                Some(a) => match AudioPreflight::analyze(a, cancel) {
                    Err(e) => fail(e),
                    Ok(analysis) => {
                        let mut predicted = None;
                        let mut error = None;
                        if let Some(target) = self.normalize_target
                            && !analysis.is_silent()
                        {
                            match AudioPreflight::predict(a, &analysis, target, cancel) {
                                Ok(p) => predicted = Some(p),
                                Err(e) => error = Some(e),
                            }
                        }
                        match error {
                            Some(e) => fail(e),
                            None => {
                                let predicted_target = predicted.map(|_| self.normalize_target).unwrap_or(None);
                                result =
                                    Some(AudioCheckResult { analysis, range: self.range, predicted, predicted_target });
                            }
                        }
                    }
                },
            },
        }
        AudioCheckOutcome { entry_id: self.entry_id, result, failure }
    }
}

/// A stem export ready to run (blocking; give it to a worker).
pub struct StemExportRequest {
    stems: Vec<Stem>,
    base: String,
    directory: std::path::PathBuf,
    format: AudioFileFormat,
    duration: Time,
    audio: AudioSettings,
    encoder: Arc<dyn ExportEncoding>,
    provider: StemAudioProvider,
    sequence: Id,
    range: TimeRange,
}

/// How a stem export ended; hand it to `ExportDialogModel::finish_export_stems`.
pub struct StemExportOutcome(Result<usize, ExportError>);

impl StemExportRequest {
    /// Writes one audio file per stem plus the M&E mix.
    pub fn run(self, cancel: &CancelToken) -> StemExportOutcome {
        let (provider, id, range) = (Arc::clone(&self.provider), self.sequence, self.range);
        let r = StemExporter::export(
            &self.stems,
            &self.base,
            &self.directory,
            self.format,
            self.duration,
            &self.audio,
            self.encoder.as_ref(),
            &mut |stem| provider(id, stem, range),
            cancel,
            &mut |_| {},
        );
        StemExportOutcome(r.map(|w| w.len()))
    }
}

impl ExportDialogModel {
    // MARK: Audio check (opt-in: it mixes the whole sequence once)

    /// Starts the audio check of the selected output; `None` when audio is off or a check already runs.
    pub fn begin_audio_check(&mut self) -> Option<AudioCheckRequest> {
        let entry = self.selected_format().clone();
        if !self.settings().audio.enabled || self.audio_check_running.contains(&entry.id) {
            return None;
        }
        let mut probe = entry.settings.clone();
        probe.captions = sq_export::core::settings::CaptionMode::None;
        probe.cover_image = None;
        probe.cover_time = None;
        probe.audio.loudness = None;
        self.audio_check_running.insert(entry.id);
        self.audio_check_error = None;
        self.bump();
        Some(AudioCheckRequest {
            entry_id: entry.id,
            sequence: self.selected_id,
            probe,
            range: entry.settings.range,
            normalize_target: entry.settings.audio.loudness,
            provider: Arc::clone(&self.source_provider),
        })
    }

    /// Takes the result of an audio check.
    pub fn finish_audio_check(&mut self, outcome: AudioCheckOutcome) {
        self.audio_check_running.remove(&outcome.entry_id);
        if let Some(r) = outcome.result {
            self.audio_checks.insert(outcome.entry_id, r);
        }
        self.audio_check_error = outcome.failure;
        self.bump();
    }

    /// Mixes the selected output's audio once (no picture, no captions) and measures it. Blocking.
    // Swift: Export/ExportDialogModel.swift:836
    pub fn run_audio_check(&mut self) {
        if let Some(req) = self.begin_audio_check() {
            let outcome = req.run(&CancelToken::new());
            self.finish_audio_check(outcome);
        }
    }

    // MARK: Stems

    /// Whether the host can write stems of the selected sequence.
    // Swift: Export/ExportDialogModel.swift:897
    pub fn can_export_stems(&self) -> bool {
        self.stem_audio.is_some() && self.stem_plans.get(&self.selected_id).is_some_and(|p| !p.is_empty())
    }

    /// The mix source builder of stems (the host knows the renderer); `None` = stems unavailable.
    // Swift: Export/ExportDialogModel.swift:888
    pub fn stem_audio(&self) -> Option<&StemAudioProvider> {
        self.stem_audio.as_ref()
    }

    /// Sets the stem mix source builder.
    pub fn set_stem_audio(&mut self, p: Option<StemAudioProvider>) {
        self.stem_audio = p;
        self.bump();
    }

    /// Writes the stem files (the platform encoder; `None` = stems unavailable on this computer).
    // Swift: Export/ExportDialogModel.swift:890
    pub fn stem_encoder(&self) -> Option<&Arc<dyn ExportEncoding>> {
        self.stem_encoder.as_ref()
    }

    /// Sets the stem encoder.
    pub fn set_stem_encoder(&mut self, e: Option<Arc<dyn ExportEncoding>>) {
        self.stem_encoder = e;
        self.bump();
    }

    /// `StemPlan::stems` of every sequence the host can export stems of.
    // Swift: Export/ExportDialogModel.swift:892
    pub fn stem_plans(&self) -> &std::collections::BTreeMap<Id, Vec<Stem>> {
        &self.stem_plans
    }

    /// Sets the stem plans.
    pub fn set_stem_plans(&mut self, plans: std::collections::BTreeMap<Id, Vec<Stem>>) {
        self.stem_plans = plans;
        self.bump();
    }

    /// Whether a stem export runs.
    pub fn is_exporting_stems(&self) -> bool {
        self.is_exporting_stems
    }

    /// 0...1 progress of the stem export.
    pub fn stem_progress(&self) -> f64 {
        self.stem_progress
    }

    /// Result line under the button: written files or the reason it failed.
    pub fn stem_status(&self) -> Option<&str> {
        self.stem_status.as_deref()
    }

    /// Where the user's saved stem presets live (`None` = presets cannot be saved).
    // Swift: Export/ExportDialogModel.swift:901
    pub fn stem_preset_store(&self) -> Option<&sq_export::core::stems::StemPresetStore> {
        self.stem_preset_store.as_ref()
    }

    /// Sets the store and loads the saved presets from it.
    pub fn set_stem_preset_store(&mut self, store: Option<sq_export::core::stems::StemPresetStore>) {
        self.user_stem_presets = store.as_ref().map(|s| s.load()).unwrap_or_default();
        self.stem_preset_store = store;
        self.bump();
    }

    /// The selected sequence's stems.
    // Swift: Export/ExportDialogModel.swift:907
    pub fn stem_plan(&self) -> Vec<Stem> {
        self.stem_plans.get(&self.selected_id).cloned().unwrap_or_default()
    }

    /// The stems that will be written: the plan minus the unchecked ones.
    // Swift: Export/ExportDialogModel.swift:910
    pub fn active_stems(&self) -> Vec<Stem> {
        self.stem_plan().into_iter().filter(|s| !self.stem_unchecked.contains(&s.id)).collect()
    }

    /// Whether a stem is ticked (all start ticked).
    // Swift: Export/ExportDialogModel.swift:911
    pub fn is_stem_checked(&self, id: &str) -> bool {
        !self.stem_unchecked.contains(id)
    }

    /// Ticks or unticks a stem.
    // Swift: Export/ExportDialogModel.swift:912
    pub fn set_stem_checked(&mut self, id: &str, on: bool) {
        if on {
            self.stem_unchecked.remove(id);
        } else {
            self.stem_unchecked.insert(id.to_string());
        }
        self.bump();
    }

    /// Built-in plus saved presets for the selected sequence's stems.
    // Swift: Export/ExportDialogModel.swift:916
    pub fn stem_presets(&self) -> Vec<StemPreset> {
        let mut all = StemPreset::built_in(&self.stem_plan());
        all.extend(self.user_stem_presets.iter().cloned());
        all
    }

    /// The saved (user) stem presets.
    pub fn user_stem_presets(&self) -> &[StemPreset] {
        &self.user_stem_presets
    }

    /// Ticks exactly the stems a preset names.
    // Swift: Export/ExportDialogModel.swift:917
    pub fn apply_stem_preset(&mut self, p: &StemPreset) {
        let plan = self.stem_plan();
        let keep: std::collections::BTreeSet<String> = p.select(&plan).into_iter().map(|s| s.id).collect();
        self.stem_unchecked = plan.into_iter().map(|s| s.id).filter(|id| !keep.contains(id)).collect();
        self.bump();
    }

    /// Saves the current selection under a name made from its stems (an existing preset of that name is replaced).
    // Swift: Export/ExportDialogModel.swift:922
    pub fn save_stem_selection(&mut self) {
        let ids: Vec<String> = self.active_stems().into_iter().map(|s| s.id).collect();
        if ids.is_empty() || self.stem_preset_store.is_none() {
            return;
        }
        let name = StemPreset::auto_name(&ids, &self.stem_plan());
        let id = self.ids.next_id();
        let format = self.settings().audio_only.unwrap_or(AudioFileFormat::Wav);
        let preset = StemPreset { id, name, stem_ids: ids, format };
        if let Some(store) = &self.stem_preset_store
            && let Ok(all) = store.save(&preset)
        {
            self.user_stem_presets = all;
            self.bump();
        }
    }

    /// Estimated size of the checked stem files, in bytes.
    // Swift: Export/ExportDialogModel.swift:929
    pub fn stem_estimated_bytes(&self) -> i64 {
        StemPreset::estimated_bytes(
            self.active_stems().len() as i64,
            self.effective_duration(self.selected_id),
            self.settings().audio_only.unwrap_or(AudioFileFormat::Wav),
            &self.settings().audio,
        )
    }

    /// Starts a stem export into `directory`; `None` when there is nothing to write, one already runs, or the host has
    /// no stem encoder (the status line then says so).
    pub fn begin_export_stems(&mut self, directory: &Path) -> Option<StemExportRequest> {
        let stems = self.active_stems();
        let provider = self.stem_audio.clone()?;
        if stems.is_empty() || self.is_exporting_stems {
            return None;
        }
        let id = self.selected_id;
        let s = self.settings().clone();
        let typed = self.file_name();
        let base = if typed.is_empty() { Self::sanitized_file_name(&self.selected_item().name) } else { typed };
        let duration = self.effective_duration(id);
        let range = match s.range {
            RangeSelection::InOut(r) => r,
            RangeSelection::EntireSequence => TimeRange::new(Time::ZERO, duration),
        };
        let format = s.audio_only.unwrap_or(AudioFileFormat::Wav);
        let mut audio = s.audio.clone();
        audio.codec = format.codec();
        audio.enabled = true;
        audio.loudness = None; // stems keep their level so they sum back to the mix
        let Some(encoder) = self.stem_encoder.clone() else {
            self.stem_status = Some(SQL10n::string("Stems are not available on this computer."));
            self.bump();
            return None;
        };
        self.is_exporting_stems = true;
        self.stem_progress = 0.0;
        self.stem_status = None;
        self.bump();
        Some(StemExportRequest {
            stems,
            base,
            directory: directory.to_path_buf(),
            format,
            duration,
            audio,
            encoder,
            provider,
            sequence: id,
            range,
        })
    }

    /// Takes the end of a stem export.
    pub fn finish_export_stems(&mut self, outcome: StemExportOutcome) {
        self.is_exporting_stems = false;
        match outcome.0 {
            Ok(n) => {
                self.stem_progress = 1.0;
                self.stem_status = Some(SQL10n::format("%@ stem files written.", &[&n.to_string()]));
            }
            Err(ExportError::Cancelled) => {}
            Err(e) => {
                self.stem_status = Some(SQL10n::format("Stems could not be exported: %@", &[&SQL10n::error_text(&e)]));
            }
        }
        self.bump();
    }

    /// Writes one audio file per role plus the M&E mix next to the output, named after the output file name. WAV unless
    /// the output is an audio-only file (then its format and audio settings). Blocking.
    // Swift: Export/ExportDialogModel.swift:936
    pub fn export_stems(&mut self, directory: &Path, cancel: &CancelToken) {
        if let Some(req) = self.begin_export_stems(directory) {
            let outcome = req.run(cancel);
            self.finish_export_stems(outcome);
        }
    }

    // MARK: Cut-downs

    /// "Export Cut-downs" was pressed: the host gets `ExportDialogEvent::ExportCutDowns` (Swift `onExportCutDowns`).
    // Swift: Export/ExportDialogModel.swift:982
    pub fn on_export_cut_downs(&mut self) {
        self.events.push(ExportDialogEvent::ExportCutDowns);
    }

    /// The selected sequence's cut-down plans that hold at least one range; empty without cut-down markers.
    // Swift: Export/ExportDialogModel.swift:985
    pub fn cut_down_plans(&self) -> Vec<Plan> {
        CutDownPlanner::plans(&self.selected_item().markers, &CutDownPlanner::TARGET_SECONDS)
            .into_iter()
            .filter(|p| !p.ranges.is_empty())
            .collect()
    }

    /// Whether a planned range is ticked (all start ticked).
    // Swift: Export/ExportDialogModel.swift:988
    pub fn is_cut_down_checked(&self, k: CutDownKey) -> bool {
        !self.cut_down_unchecked.contains(&k)
    }

    /// Ticks or unticks a planned range.
    // Swift: Export/ExportDialogModel.swift:989
    pub fn set_cut_down_checked(&mut self, k: CutDownKey, on: bool) {
        if on {
            self.cut_down_unchecked.remove(&k);
        } else {
            self.cut_down_unchecked.insert(k);
        }
        self.bump();
    }

    /// How many planned ranges are ticked.
    // Swift: Export/ExportDialogModel.swift:992
    pub fn checked_cut_down_count(&self) -> usize {
        self.cut_down_plans()
            .iter()
            .map(|p| {
                (0..p.ranges.len()).filter(|&i| self.is_cut_down_checked(CutDownKey::new(p.target_seconds, i))).count()
            })
            .sum()
    }

    /// One job per checked range of the selected sequence: the in/out range path, file name suffixed `_60s` (`_60s_2`
    /// for a second range of the same target).
    // Swift: Export/ExportDialogModel.swift:998
    pub fn build_cut_down_jobs(&mut self, output_directory: &Path) -> Vec<ExportJob> {
        let item = self.selected_item().clone();
        let f: FormatEntry =
            self.formats(item.id).iter().find(|f| f.enabled).unwrap_or_else(|| self.selected_format()).clone();
        let cleaned = Self::sanitized_file_name(&item.name);
        let base = if cleaned.is_empty() { item.name.clone() } else { cleaned };
        let mut jobs = Vec::new();
        for plan in self.cut_down_plans() {
            for (i, range) in plan.ranges.iter().enumerate() {
                if !self.is_cut_down_checked(CutDownKey::new(plan.target_seconds, i)) {
                    continue;
                }
                let mut s = f.settings.for_delivery();
                s.range = RangeSelection::InOut(*range);
                s.cover_time = None;
                let suffix =
                    format!("_{}s{}", plan.target_seconds, if i == 0 { String::new() } else { format!("_{}", i + 1) });
                let name = format!("{}{suffix}", f.file_name.clone().unwrap_or_else(|| base.clone()));
                jobs.push(self.job(item.id, &name, s, output_directory));
            }
        }
        jobs
    }

    /// Enqueues the cut-down jobs and returns their ids. The queue runs on the caller's thread (`queue.run_all()`), so
    /// the host calls that on a worker after this (Swift's `run:` flag).
    // Swift: Export/ExportDialogModel.swift:1019
    pub fn submit_cut_downs(&mut self, queue: &ExportQueue, output_directory: &Path) -> Vec<Id> {
        self.build_cut_down_jobs(output_directory).into_iter().map(|j| queue.enqueue(j)).collect()
    }

    // MARK: Jobs

    /// A job for `settings` whose sources come from the dialog's provider.
    fn job(&mut self, sequence: Id, name: &str, settings: ExportSettings, dir: &Path) -> ExportJob {
        let provider = Arc::clone(&self.source_provider);
        let own = settings.clone();
        let make = Arc::new(move || -> Result<ExportSources, ExportError> { provider(sequence, &own) });
        ExportJob::new(self.ids.next_id(), name, settings, dir.to_path_buf(), make)
    }

    /// One job per checked sequence format, in project order.
    // Swift: Export/ExportDialogModel.swift:1031
    pub fn build_jobs(&mut self, output_directory: &Path) -> Vec<ExportJob> {
        let items: Vec<SequenceItem> = self.checked_sequences().into_iter().cloned().collect();
        let mut jobs = Vec::new();
        for item in items {
            let active: Vec<FormatEntry> = self.formats(item.id).iter().filter(|f| f.enabled).cloned().collect();
            for f in &active {
                let mut settings = f.settings.for_delivery();
                settings.cover_time = if settings.cover_image.is_none() { None } else { item.cover_time };
                // Several formats of one sequence: the file name says which one it is.
                let cleaned = Self::sanitized_file_name(&item.name);
                let base = if cleaned.is_empty() { item.name.clone() } else { cleaned };
                let name = f.file_name.clone().unwrap_or_else(|| {
                    if active.len() > 1 { format!("{base} {}", Self::file_tag(f)) } else { base.clone() }
                });
                if let Some(clips) = self.per_clip_ranges(&item, &settings) {
                    for (i, clip) in clips.iter().enumerate() {
                        let mut edited = settings.clone();
                        edited.range = RangeSelection::InOut(clip.range);
                        edited.cover_time = None;
                        let tag = Self::sanitized_file_name(&clip.name);
                        let clip_name = format!(
                            "{name} - {}{}",
                            i + 1,
                            if tag.is_empty() { String::new() } else { format!(" {tag}") }
                        );
                        jobs.push(self.job(item.id, &clip_name, edited, output_directory));
                    }
                    continue;
                }
                if self.export_all_formats
                    && settings.audio_only.is_none()
                    && !item.variants.is_empty()
                    && let Some(format) = &item.format
                {
                    let mut shape = Timeline::new(self.ids.next_id(), &item.name, format.clone(), Vec::new());
                    shape.variants = item.variants.clone();
                    let provider = Arc::clone(&self.source_provider);
                    let id = item.id;
                    let make: MakeSourcesFor = Arc::new(move |vs: &ExportSettings| provider(id, vs));
                    jobs.extend(ExportJob::variant_jobs(
                        &name,
                        &settings,
                        output_directory,
                        &shape,
                        self.ids.as_mut(),
                        make,
                    ));
                    continue;
                }
                jobs.push(self.job(item.id, &name, settings, output_directory));
            }
        }
        jobs
    }

    /// "1080x1920 H.264": distinguishes the files of one sequence.
    fn file_tag(f: &FormatEntry) -> String {
        format!("{}x{} {}", f.settings.video.width, f.settings.video.height, f.settings.video.codec.display_name())
    }

    /// Enqueues the jobs and returns their ids (none when the dialog cannot export). The queue runs on the caller's
    /// thread (`queue.run_all()`), so the host calls that on a worker after this (Swift's `run:` flag).
    // Swift: Export/ExportDialogModel.swift:1074
    pub fn submit(&mut self, queue: &ExportQueue, output_directory: &Path, replace_existing: bool) -> Vec<Id> {
        if !self.can_export() {
            return Vec::new();
        }
        self.build_jobs(output_directory)
            .into_iter()
            .map(|mut j| {
                j.replace_existing = replace_existing;
                queue.enqueue(j)
            })
            .collect()
    }
}
