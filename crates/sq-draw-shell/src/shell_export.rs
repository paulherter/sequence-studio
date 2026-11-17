// Swift: ShellExport.swift
//! File > Export helpers shared by the drawn Export sheet and Quick Export: the presets the platform encoder writes, the
//! range choices and the status lines. The host supplies the frame and audio sources ([`ExportHost::sources`]) and the
//! queue with its encoder ([`ExportHost::queue`]). With `file_outputs` (the encoder also writes audio-only files, GIFs and
//! image sequences) every Mac preset is offered.
//!
//! Mapping: the queue's `run_all` blocks, so the app runs it on a worker when it sees [`ShellEvent::RunExportQueue`]; the
//! flow here only submits and then follows the statuses. The Export sheet itself (`ShellExportSheet`, `ShellExportRows`,
//! `ShellExportPreview`) is not ported (see PORTING-NOTES.md, Escalations): [`ShellHost::prepare_export_model`] and
//! [`ShellHost::export_after_sheet`] are the two halves of `showExport` around it.

use crate::shell_dialog::ShellDialog;
use crate::shell_export_queue_popover::{BackgroundJob, ExportQueuePopover};
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_model::Timeline;
use sq_core_project::support_policy::{SupportLinks, SupportReminder};
use sq_core_time::{Id, Timestamp};
use sq_draw::RgbaImage;
use sq_editor_session::{
    AppSettings, EditorSession, ExportDialogModel, ExportPreflightReport, QuickExport, SourceProvider,
    StemAudioProvider,
};
use sq_export::core::preflight::ExportPreflight;
use sq_export::core::preset::{ExportPreferences, ExportPreset};
use sq_export::core::queue::{ExportJobState, ExportJobStatus, ExportQueue};
use sq_export::core::settings::{ExportSettings, VideoCodec};
use sq_export::core::stems::{StemPlan, StemPresetStore};
use sq_export::core::traits::{ExportEncoding, ExportFrame};
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

/// What one export writes; the form's rows follow it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportKind {
    /// A video file.
    Video,
    /// An audio-only file.
    Audio,
    /// An animated GIF.
    Gif,
    /// An image sequence.
    Sequence,
}

/// How [`ShellHost::export_after_sheet`] ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportSubmit {
    /// The jobs are queued and followed (or there was nothing to do).
    Submitted,
    /// The user canceled at a question: the sheet opens again over the same model.
    BackToSheet,
    /// The app root is gone.
    RootGone,
}

/// File > Export helpers (Swift `ShellExport`).
pub struct ShellExport;

impl ShellExport {
    /// The kind of file `s` writes.
    pub fn kind(s: &ExportSettings) -> ExportKind {
        use sq_export::core::frame_output::FrameOutput;
        if s.audio_only.is_some() {
            ExportKind::Audio
        } else if s.frame_output == Some(FrameOutput::Gif) {
            ExportKind::Gif
        } else if s.frame_output.is_some() {
            ExportKind::Sequence
        } else {
            ExportKind::Video
        }
    }

    /// The presets an encoder that writes `codecs` can make: the video ones, plus with `file_outputs` the audio-only, GIF
    /// and image-sequence presets.
    pub fn presets(codecs: &[VideoCodec], file_outputs: bool) -> Vec<ExportPreset> {
        ExportPreset::all()
            .into_iter()
            .filter(|p| {
                let s = p.settings();
                if s.audio_only.is_some() || s.frame_output.is_some() {
                    return file_outputs;
                }
                codecs.contains(&s.video.codec)
            })
            .collect()
    }

    /// The range choices the selected sequence offers, as (`ExportDialogModel::range_mode`, title).
    pub fn ranges(m: &ExportDialogModel) -> Vec<(i64, String)> {
        let mut r = vec![(0, "Entire sequence".to_string())];
        if m.can_use_in_out() {
            r.push((1, "In to Out".to_string()));
        }
        if m.can_use_selection() {
            r.push((3, (if m.selected_clip_count() == 1 { "Selected clip" } else { "Selected clips" }).to_string()));
        }
        r
    }

    /// "1920×1080 · 25 fps · H.264 · 12 Mbit/s · ~ 48 MB".
    pub fn summary(m: &ExportDialogModel) -> String {
        format!("{} · {}", m.summary_text(), m.estimated_size_text())
    }

    /// One line per job state for the status bar ("Exporting “Name”: 42%").
    pub fn status_line(s: &ExportJobStatus) -> String {
        Self::status_line_of(&s.name, &s.state, s.progress)
    }

    pub(crate) fn status_line_of(name: &str, state: &ExportJobState, progress: f64) -> String {
        match state {
            ExportJobState::Waiting => SQL10n::format("Waiting to export “%@”", &[name]),
            ExportJobState::Running => {
                SQL10n::format("Exporting “%@”: %@%%", &[name, &((progress * 100.0).floor() as i64).to_string()])
            }
            ExportJobState::Done(_) => SQL10n::format("Exported “%@”", &[name]),
            ExportJobState::Failed(why) => SQL10n::format("Export of “%@” failed: %@", &[name, why]),
            ExportJobState::Cancelling => SQL10n::format("Stopping export of “%@”…", &[name]),
            ExportJobState::Cancelled => SQL10n::format("Export of “%@” canceled", &[name]),
        }
    }

    /// The status bar's ring (0...1) over the given job states; `None` when nothing is open (ShellBackgroundOffers.swift).
    pub fn overall_progress(all: &[(ExportJobState, f64)]) -> Option<f64> {
        let open = all.iter().any(|(s, _)| s.is_active());
        if !open || all.is_empty() {
            return None;
        }
        let sum: f64 = all
            .iter()
            .map(|(s, p)| match s {
                ExportJobState::Waiting => 0.0,
                ExportJobState::Running | ExportJobState::Cancelling => p.clamp(0.0, 1.0),
                _ => 1.0,
            })
            .sum();
        Some(sum / all.len() as f64)
    }
}

/// Counts the Magic mask frames of a sequence (and the sequences it uses) without a matte.
pub type MagicFrameCounter = Rc<dyn Fn(&Timeline, &BTreeMap<Id, Timeline>) -> usize>;

/// Reads a rendered frame as an RGBA picture (the platform knows the frame's storage).
pub type FramePixels = Arc<dyn Fn(&ExportFrame) -> Option<RgbaImage> + Send + Sync>;

/// What the host tells Export (the Swift `ShellHost` members `exportSources`, `exportQueue`, `exportCodecs`,
/// `exportFileOutputs`, `exportDirectory`, `backgroundJobs`, `exportProgress`, `untrackedMagicFrames`, `queuePopover`).
pub struct ExportHost {
    /// Reads the pixels of a rendered frame as RGBA (the frame's storage is opaque here); `None` = no preview picture.
    pub frame_pixels: Option<FramePixels>,
    /// Pictures the sheet made for renderer image slots; the app takes them with [`ShellHost::take_export_uploads`].
    pub(crate) uploads: Vec<(usize, RgbaImage)>,
    /// The frame and audio sources of a sequence; `None` = Export is not offered.
    pub sources: Option<SourceProvider>,
    /// The queue that writes the files with the platform's encoder.
    pub queue: Option<Arc<ExportQueue>>,
    /// Builds the offline mix of one stem; with [`ExportHost::stem_encoder`] it turns the sheet's stem rows on.
    pub stem_audio: Option<StemAudioProvider>,
    /// Writes the stem files (the queue's encoder).
    pub stem_encoder: Option<Arc<dyn ExportEncoding>>,
    /// Where the saved stem choices live; `None` = the sheet has no "Save Choice" button.
    pub stem_presets: Option<StemPresetStore>,
    /// The codecs the platform's encoder writes (the presets are filtered to them).
    pub codecs: Vec<VideoCodec>,
    /// The encoder also writes audio-only files, GIFs and image sequences (their presets are offered).
    pub file_outputs: bool,
    /// The folder of the last export.
    pub directory: PathBuf,
    /// Background jobs (proxies, transcription) the queue popover lists above the exports.
    pub background_jobs: Vec<BackgroundJob>,
    /// The status bar's ring while exports run (0...1); `None` hides it.
    pub progress: Option<f64>,
    /// Counts the Magic mask frames of a sequence without a matte (the preflight note); `None` counts none.
    pub untracked_magic_frames: Option<MagicFrameCounter>,
    /// The queue popover while open.
    pub(crate) popover: Option<ExportQueuePopover>,
    pub(crate) popover_refreshed: f64,
}

impl ExportHost {
    /// The folder a fresh Export sheet offers: the user's movies folder (`~/Movies` on the Mac, `~/Videos` elsewhere), the
    /// temporary folder when the environment names no home.
    fn default_directory(platform: Platform, env: impl Fn(&str) -> Option<OsString>) -> PathBuf {
        platform.movies_dir(env).unwrap_or_else(std::env::temp_dir)
    }
}

impl Default for ExportHost {
    fn default() -> ExportHost {
        ExportHost {
            frame_pixels: None,
            uploads: Vec::new(),
            sources: None,
            queue: None,
            stem_audio: None,
            stem_encoder: None,
            stem_presets: None,
            codecs: vec![VideoCodec::H264, VideoCodec::Hevc],
            file_outputs: false,
            directory: Self::default_directory(Platform::current(), |name| std::env::var_os(name)),
            background_jobs: Vec::new(),
            progress: None,
            untracked_magic_frames: None,
            popover: None,
            popover_refreshed: f64::MIN,
        }
    }
}

impl ShellHost {
    /// The pictures the Export sheet made for renderer image slots since the last call.
    pub fn take_export_uploads(&mut self) -> Vec<(usize, RgbaImage)> {
        std::mem::take(&mut self.export.uploads)
    }

    const EXPORT_PREFERENCES_KEY: &'static str = "sq.export.preferences";
    const EXPORT_DIRECTORY_KEY: &'static str = "sq.export.lastDirectory";
    const LAST_PRESET_KEY: &'static str = "sq.export.lastPresetID";

    /// The first half of `showExport`: the model over the sequences, the last preset and choices, the encoder speed and the
    /// output folder. `None` (with a status line) when Export is not offered or there is no sequence.
    pub fn prepare_export_model(&mut self, session: &EditorSession) -> Option<ExportDialogModel> {
        let Some(sources) = self.export.sources.clone() else {
            self.flash("Export is not available.");
            return None;
        };
        let items = ExportDialogModel::sequence_items(session, None);
        if items.is_empty() {
            self.flash("There is no sequence to export.");
            return None;
        }
        let active = session.active_timeline_id();
        let preview_sources = Arc::clone(&sources);
        let mut model = ExportDialogModel::new(
            items.clone(),
            None,
            ExportDialogModel::system_free_space(),
            sources,
            Box::new(sq_core_time::SequentialIds::default()),
        );
        model.set_preview_source(Some(Arc::new(move |id, settings| preview_sources(id, settings).map(|s| s.video))));
        // `ExportCoordinator.makeModel`: one plan per sequence; the audio of a stem is the sequence with the other roles muted.
        if self.export.stem_audio.is_some() && self.export.stem_encoder.is_some() {
            model.set_stem_plans(
                session
                    .project()
                    .timelines
                    .iter()
                    .map(|t| (t.id, StemPlan::stems(t)))
                    .filter(|(_, stems)| !stems.is_empty())
                    .collect(),
            );
            model.set_stem_audio(self.export.stem_audio.clone());
            model.set_stem_encoder(self.export.stem_encoder.clone());
            model.set_stem_preset_store(self.export.stem_presets.clone());
        }
        if let Some(id) = active.filter(|id| items.iter().any(|i| i.id == *id)) {
            model.set_selected_id(id);
            model.set_checked_ids([id].into_iter().collect());
        }
        // `ExportCoordinator.makeModel` / `presentDialog`: the last preset and choices, the per-Mac encoder speed.
        QuickExport::apply_preset(&mut model, self.defaults.string(Self::LAST_PRESET_KEY).as_deref());
        if let Some(p) = ExportPreferences::decode(self.defaults.data(Self::EXPORT_PREFERENCES_KEY).as_deref()) {
            model.apply_preferences(&p);
        }
        model.set_encoder_speed(AppSettings::load(&*self.defaults).export_encoder_speed);
        let offered = ShellExport::presets(&self.export.codecs, self.export.file_outputs);
        if !offered.iter().any(|p| p.id() == model.preset_id())
            && model.preset_id() != ExportPreferences::CUSTOM_PRESET_ID
            && let Some(p) = offered.first()
        {
            model.open_with_preset_id(&p.id());
        }
        // `ExportCoordinator.quickDirectory`: a saved project exports into its Exports folder, else the last folder.
        let dir = if session.file_url().is_none() {
            self.export.directory.clone()
        } else {
            QuickExport::directory(
                session.file_url(),
                Some(&self.export.directory.to_string_lossy()),
                Some(&self.export.directory),
            )
        };
        model.set_output_directory(Some(dir));
        Some(model)
    }

    /// File > Quick Export (`quickExport`): the active sequence with the last preset and settings, into `Exports/` next to
    /// the project; no sheet. The preflight notes and the question about files already there still come first.
    pub async fn quick_export<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(mut model)) = h.with(|r| {
            let p = r.shell_parts();
            p.shell.prepare_export_model(p.session)
        }) else {
            return;
        };
        let Some(Some(problem)) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            if let Some(n) = QuickExport::range_notice(&model) {
                shell.emit(ShellEvent::Status(n));
            }
            let problems = model.validation_messages();
            let problem = problems.first().cloned();
            if let Some(m) = &problem {
                shell.flash(m);
            }
            Some(problem)
        }) else {
            return;
        };
        if problem.is_none() {
            Self::export_after_sheet(h, &mut model).await;
        }
    }

    /// Stores the selected output's preset and per-export choices (format, quality step, captions...) for the next time the
    /// sheet opens. Swift stores them only when Export is pressed; the Rust sheet also stores them when it is closed
    /// another way, so a Cancel does not throw away what was picked (the sheet opens again with the last picks).
    pub(crate) fn remember_export_choices(&mut self, model: &ExportDialogModel) {
        self.defaults.set_string(Self::LAST_PRESET_KEY, model.preset_id());
        if let Some(data) = model.preferences().encoded() {
            self.defaults.set_data(Self::EXPORT_PREFERENCES_KEY, &data);
        }
    }

    /// The second half of `showExport`, after the sheet answered Export: creates the folder, remembers the choices, asks the
    /// preflight questions and submits. See [`ExportSubmit`].
    pub async fn export_after_sheet<R: ShellRoot + ?Sized>(h: UiRef<R>, model: &mut ExportDialogModel) -> ExportSubmit {
        let Some(dir) = model.output_directory().map(std::path::Path::to_path_buf) else {
            return ExportSubmit::Submitted;
        };
        let Some(made) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            if let Err(e) = std::fs::create_dir_all(&dir) {
                shell.present_error("Could not create the export folder", &e);
                return false;
            }
            shell.export.directory = dir.clone();
            shell.defaults.set_string(Self::EXPORT_DIRECTORY_KEY, &dir.to_string_lossy());
            shell.remember_export_choices(model);
            true
        }) else {
            return ExportSubmit::RootGone;
        };
        if !made {
            return ExportSubmit::Submitted;
        }
        let Some(queue) = h.with(|r| r.shell_parts().shell.export.queue.clone()) else { return ExportSubmit::RootGone };
        let Some(queue) = queue else { return ExportSubmit::Submitted };
        // Canceled at a question: the dialog comes back with the same settings (ExportCoordinator.submitFromDialog).
        let Some(ids) = Self::preflight_and_submit(&h, model, &dir, &queue).await else {
            return ExportSubmit::BackToSheet;
        };
        if !ids.is_empty() {
            Self::follow_exports(&h, &ids, &queue).await;
        }
        ExportSubmit::Submitted
    }

    /// The preflight question ("Not much disk space" and the other notes): Cancel, Export Anyway (main).
    pub(crate) fn export_warning_dialog(title: &str, message: &str) -> ShellDialog {
        let mut q = ShellDialog::new(&SQL10n::string(title), message);
        q.add_button(&SQL10n::string("Export Anyway"), SQDialogRole::Default, false);
        q.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
        q
    }

    /// "<name> already exists in this folder": Replace (red), Cancel, Keep Both (main).
    pub(crate) fn name_taken_dialog(title: &str, message: &str) -> ShellDialog {
        let mut q = ShellDialog::new(title, message);
        q.add_button(&SQL10n::string("Keep Both"), SQDialogRole::Default, false);
        q.add_button(&SQL10n::string("Replace"), SQDialogRole::Destructive, false);
        q.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
        q
    }

    /// `ExportCoordinator.preflightAndSubmit`: the notes of `ExportPreflightReport` (one question, "Export Anyway"), the
    /// question about files already in the folder (Keep Both / Replace), then the queue. `None` = canceled at a question.
    pub(crate) async fn preflight_and_submit<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        model: &mut ExportDialogModel,
        dir: &std::path::Path,
        queue: &ExportQueue,
    ) -> Option<Vec<Id>> {
        let report = h.with(|r| {
            let shell = &*r.shell_parts().shell;
            let magic = shell.export.untracked_magic_frames.clone();
            let session = &*r.shell_parts().session;
            ExportPreflightReport::build(model, session.project(), dir, magic.as_deref())
        })?;
        if !report.is_empty() {
            let q = Self::export_warning_dialog(&report.title, &report.lines.join("\n\n"));
            if Self::ask(h, q).await != Some(SQDialogResponse::FIRST) {
                return None;
            }
        }
        let mut replace = false;
        let existing = ExportPreflight::existing_targets(&model.build_jobs(dir));
        if let Some((title, message)) = ExportPreflightReport::existing_files_question(&existing) {
            let q = Self::name_taken_dialog(&title, &message);
            match Self::ask(h, q).await {
                Some(SQDialogResponse::FIRST) => replace = false,
                Some(SQDialogResponse::SECOND) => replace = true,
                _ => return None,
            }
        }
        let ids = model.submit(queue, dir, replace);
        h.with(|r| r.shell_parts().shell.emit(ShellEvent::RunExportQueue))?;
        Some(ids)
    }

    /// Status lines while the jobs run; the outcome as a dialog at the end.
    pub(crate) async fn follow_exports<R: ShellRoot + ?Sized>(h: &UiRef<R>, ids: &[Id], queue: &ExportQueue) {
        let mut last = String::new();
        loop {
            let all: Vec<ExportJobStatus> = queue.all_statuses().into_iter().filter(|s| ids.contains(&s.id)).collect();
            let current = all
                .iter()
                .find(|s| s.state.is_exporting())
                .or_else(|| all.iter().find(|s| s.state == ExportJobState::Waiting))
                .cloned();
            let alive = h.with(|r| {
                let shell = &mut *r.shell_parts().shell;
                shell.export.progress = ShellExport::overall_progress(
                    &all.iter().map(|s| (s.state.clone(), s.progress)).collect::<Vec<_>>(),
                );
                match &current {
                    None => shell.finish_exports(&all),
                    Some(c) => {
                        let line = ShellExport::status_line(c);
                        if line != last {
                            shell.emit(ShellEvent::Status(line.clone()));
                            last = line;
                        }
                    }
                }
            });
            if alive.is_none() || current.is_none() {
                return;
            }
            if sq_runtime::sleep(Duration::from_millis(250)).await.is_err() {
                return;
            }
        }
    }

    pub(crate) fn finish_exports(&mut self, all: &[ExportJobStatus]) {
        self.export.progress = None;
        let failed: Vec<String> = all
            .iter()
            .filter_map(|s| match &s.state {
                ExportJobState::Failed(why) => Some(format!("“{}”: {why}", s.name)),
                _ => None,
            })
            .collect();
        let done: Vec<PathBuf> = all
            .iter()
            .filter_map(|s| match &s.state {
                ExportJobState::Done(url) => Some(url.clone()),
                _ => None,
            })
            .collect();
        self.emit(ShellEvent::ExportsFinished { done: done.clone(), failed: failed.clone() });
        if !failed.is_empty() {
            self.present_message("Export failed", &failed.join("\n"), None);
            return;
        }
        let Some(url) = done.first().cloned() else {
            // Nothing finished: a canceled job must not leave "Exporting 48%" in the status bar.
            if let Some(s) = all.iter().rev().find(|s| s.state == ExportJobState::Cancelled) {
                self.emit(ShellEvent::Status(ShellExport::status_line_of(&s.name, &s.state, s.progress)));
            }
            return;
        };
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.emit(ShellEvent::Status(SQL10n::format("Exported “%@”", &[&name])));
        self.start_flow(crate::ShellFlow::ExportFinished(done));
    }

    /// "Export finished": the files, Show in Explorer/Finder, and the quiet support reminder of the Mac progress window
    /// (at most once per 7 days, off for good with "Don’t show again").
    /// Button indexes of the "Export finished" dialog: OK is 0, Show in Explorer/Finder only when the host can reveal (Swift `revealFile != nil`),
    /// then the support reminder's two buttons.
    pub(crate) fn finished_slots(remind: bool, can_reveal: bool) -> FinishedSlots {
        let reveal = can_reveal.then_some(1);
        let next = 1 + usize::from(can_reveal);
        FinishedSlots { reveal, support: remind.then_some(next), off: remind.then_some(next + 1) }
    }

    pub async fn present_export_finished<R: ShellRoot + ?Sized>(h: UiRef<R>, done: Vec<PathBuf>) {
        let Some(url) = done.first().cloned() else { return };
        let Some(d) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let now = shell.wall_now();
            let last = shell.defaults.string(SupportReminder::DEFAULTS_KEY).and_then(|s| s.parse::<f64>().ok());
            let off = shell.defaults.integer(SupportReminder::OFF_KEY) == Some(1);
            let remind = SupportReminder::may_show(true, last.map(Timestamp::from_unix_seconds), now, off);
            let paths: Vec<String> = done.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            let mut d = ShellDialog::new("Export finished", &paths.join("\n"));
            let can_reveal = shell.can_reveal_file;
            d.add_button("OK", SQDialogRole::Default, false);
            // The kit's left slot: the side actions are quiet buttons on the left, OK alone on the right.
            if can_reveal {
                d.add_button(sq_os::Platform::current().reveal_title(), SQDialogRole::Normal, true);
                d.ghost_buttons.insert(d.model.buttons.len() - 1);
            }
            if remind {
                d.add_button("Enjoying Sequence Studio? Support it", SQDialogRole::Normal, true);
                d.ghost_buttons.insert(d.model.buttons.len() - 1);
                d.add_button("Don’t show again", SQDialogRole::Normal, true);
                d.ghost_buttons.insert(d.model.buttons.len() - 1);
                shell.defaults.set_string(SupportReminder::DEFAULTS_KEY, &now.unix_seconds().to_string());
            }
            (d, remind, can_reveal)
        }) else {
            return;
        };
        let (d, remind, can_reveal) = d;
        let slots = Self::finished_slots(remind, can_reveal);
        let Some(answer) = Self::ask(&h, d).await else { return };
        let _ = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            match answer.0 {
                i if Some(i as usize) == slots.reveal => shell.emit(ShellEvent::RevealFile(url)),
                i if Some(i as usize) == slots.support => {
                    shell.emit(ShellEvent::OpenUrl(SupportLinks::URL.to_string()))
                }
                i if Some(i as usize) == slots.off => shell.defaults.set_integer(SupportReminder::OFF_KEY, 1),
                _ => {}
            }
        });
    }
}

/// See [`ShellHost::finished_slots`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct FinishedSlots {
    pub reveal: Option<usize>,
    pub support: Option<usize>,
    pub off: Option<usize>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_export_folder_is_the_movies_folder_of_each_system() {
        let env = |k: &str| match k {
            "HOME" => Some(OsString::from("/u")),
            "USERPROFILE" => Some(OsString::from("C:/u")),
            _ => None,
        };
        assert_eq!(ExportHost::default_directory(Platform::Mac, env), PathBuf::from("/u/Movies"));
        assert_eq!(ExportHost::default_directory(Platform::Windows, env), PathBuf::from("C:/u/Videos"));
        assert_eq!(ExportHost::default_directory(Platform::Linux, env), PathBuf::from("/u/Videos"));
        assert_eq!(ExportHost::default_directory(Platform::Mac, |_| None), std::env::temp_dir());
    }

    #[test]
    fn a_new_shell_cannot_reveal_until_the_app_says_so() {
        let h = crate::test_support::shell();
        assert!(!h.can_reveal_file);
    }

    #[test]
    fn export_finished_offers_reveal_only_when_the_host_can() {
        let s = ShellHost::finished_slots(false, true);
        assert_eq!(s, FinishedSlots { reveal: Some(1), support: None, off: None });
        assert_eq!(ShellHost::finished_slots(false, false).reveal, None);
        let s = ShellHost::finished_slots(true, false);
        assert_eq!((s.reveal, s.support, s.off), (None, Some(1), Some(2)));
        let s = ShellHost::finished_slots(true, true);
        assert_eq!((s.reveal, s.support, s.off), (Some(1), Some(2), Some(3)));
    }

    #[test]
    fn the_four_button_export_card_fits_its_width() {
        let mut d = ShellDialog::new("Export finished", "/out/a.mp4");
        d.add_button("OK", SQDialogRole::Default, false);
        d.add_button("Show in Explorer", SQDialogRole::Normal, false);
        d.add_button("Enjoying Sequence Studio? Support it", SQDialogRole::Normal, false);
        d.add_button("Don’t show again", SQDialogRole::Normal, true);
        let m = crate::tests::measure();
        d.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 1100.0, 720.0), &m);
        let card = d.card();
        let frames = d.button_frames();
        assert_eq!(frames.len(), 4);
        for r in frames.values() {
            assert!(r.min_x() >= card.min_x() && r.max_x() <= card.max_x(), "{r:?} sticks out of {card:?}");
        }
    }

    /// No button label is cut: every button is at least as wide as its text plus padding, in English and German.
    #[test]
    fn the_export_card_shows_every_button_label_in_full() {
        let sets = [
            ["OK", "Show in Explorer", "Enjoying Sequence Studio? Support it", "Don’t show again"],
            ["OK", "Im Explorer zeigen", "Gefällt dir Sequence Studio? · Unterstützen…", "Nicht mehr anzeigen"],
        ];
        let m = crate::tests::measure();
        for titles in sets {
            let mut d = ShellDialog::new("Export finished", "/out/a.mp4");
            for (i, t) in titles.iter().enumerate() {
                d.add_button(t, if i == 0 { SQDialogRole::Default } else { SQDialogRole::Normal }, i == 3);
            }
            d.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 1100.0, 720.0), &m);
            let card = d.card();
            for (i, t) in titles.iter().enumerate() {
                let r = d.button_frames()[&i];
                let need = m.width(t, sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64, m.medium()).ceil();
                assert!(r.width >= need, "{t:?} is {} wide, its text needs {need}", r.width);
                assert!(r.min_x() >= card.min_x() && r.max_x() <= card.max_x(), "{t:?} sticks out of {card:?}");
            }
        }
    }

    #[test]
    fn shrink_widths_cuts_only_the_widest() {
        let w = ShellDialog::shrink_widths(&[40.0, 100.0, 300.0], &[false; 3], 300.0, 8.0, 50.0);
        assert_eq!(w[0], 40.0);
        assert!((w.iter().sum::<f64>() + 16.0 - 300.0).abs() < 0.01 && w[2] < 300.0 && w[1] == 100.0, "{w:?}");
        assert_eq!(ShellDialog::shrink_widths(&[40.0, 60.0], &[false; 2], 300.0, 8.0, 50.0), vec![40.0, 60.0]);
    }

    fn done() -> ExportJobState {
        ExportJobState::Done(PathBuf::from("/tmp/a.mp4"))
    }

    #[test]
    fn status_lines_follow_the_job_state() {
        let line = |s: ExportJobState, p: f64| ShellExport::status_line_of("Cut", &s, p);
        assert_eq!(line(ExportJobState::Waiting, 0.0), "Waiting to export “Cut”");
        assert_eq!(line(ExportJobState::Running, 0.429), "Exporting “Cut”: 42%");
        assert_eq!(line(done(), 1.0), "Exported “Cut”");
        assert_eq!(line(ExportJobState::Failed("disk full".into()), 0.0), "Export of “Cut” failed: disk full");
        assert_eq!(line(ExportJobState::Cancelled, 0.0), "Export of “Cut” canceled");
        assert_eq!(line(ExportJobState::Cancelling, 0.4), "Stopping export of “Cut”…");
    }

    #[test]
    fn the_ring_counts_finished_jobs_whole_and_running_ones_partly() {
        assert_eq!(ShellExport::overall_progress(&[]), None);
        assert_eq!(ShellExport::overall_progress(&[(done(), 1.0)]), None);
        let p = ShellExport::overall_progress(&[
            (done(), 1.0),
            (ExportJobState::Running, 0.5),
            (ExportJobState::Waiting, 0.0),
        ]);
        assert_eq!(p, Some(0.5));
    }

    #[test]
    fn the_offered_presets_follow_the_codecs_and_the_file_outputs() {
        let video = ShellExport::presets(&[VideoCodec::H264], false);
        assert!(!video.is_empty());
        assert!(video.iter().all(|p| {
            let s = p.settings();
            s.audio_only.is_none() && s.frame_output.is_none() && s.video.codec == VideoCodec::H264
        }));
        let all = ShellExport::presets(&[VideoCodec::H264, VideoCodec::Hevc], true);
        assert!(all.iter().any(|p| p.settings().audio_only.is_some()));
        assert!(
            ShellExport::kind(
                &all.iter().find(|p| p.settings().audio_only.is_some()).map(ExportPreset::settings).unwrap_or_default()
            ) == ExportKind::Audio
        );
    }
}
