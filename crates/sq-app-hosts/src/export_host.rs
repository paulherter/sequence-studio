// Swift: SQAppShell/ExportCoordinator (the part that connects the Export sheet to the queue)
//! File > Export on the app root: the project the render thread reads, and the worker that runs the queue.
//!
//! The Export flow lives in `sq-draw-shell` ([`sq_draw_shell::ShellHost::show_export`]); it needs frame sources for a
//! sequence id and a queue. [`ExportSetup`] gives it both: the sources are built from a snapshot of the project that
//! [`crate::ShellHost`] refreshes on every `sync`, so a job that starts later still sees the edit state the user exported.

use sq_core_model::{CowVec, MediaRef, Timeline};
use sq_core_time::{Id, TimeRange};
use sq_draw_shell::FramePixels;
use sq_editor_session::{SourceProvider, StemAudioProvider};
use sq_export::core::error::ExportError;
use sq_export::core::queue::{ExportQueue, ExportSources};
use sq_export::core::settings::ExportSettings;
use sq_export::core::stems::Stem;
use sq_export::core::traits::{AudioSource, ExportEncoding};
use std::sync::{Arc, Mutex, PoisonError};

/// The project as an export job reads it: cheap to take (the lists are shared until an edit touches them).
#[derive(Clone, Default)]
pub struct ExportSnapshot {
    /// Every sequence (the exported one and the ones nested in it).
    pub timelines: CowVec<Timeline>,
    /// The imported media, with their files.
    pub media: CowVec<MediaRef>,
    /// "Use proxies when exporting" as of the last sync; the job carries it (no preferences read on the export thread).
    pub use_proxies_for_export: bool,
}

/// Builds the frame and audio sources of one sequence from the snapshot (the platform's renderer).
pub type MakeExportSources =
    Arc<dyn Fn(&ExportSnapshot, Id, &ExportSettings) -> Result<ExportSources, ExportError> + Send + Sync>;

/// Builds the offline mix of one stem (its timeline has the other roles muted) over `range`.
pub type MakeStemAudio =
    Arc<dyn Fn(&ExportSnapshot, &Stem, TimeRange) -> Result<Box<dyn AudioSource>, ExportError> + Send + Sync>;

/// The latest snapshot, shared between the host (writes in `sync`) and the jobs (read when they start).
pub(crate) type SharedSnapshot = Arc<Mutex<ExportSnapshot>>;

/// What the app gives the shell to export: the queue that writes the files and the renderer of a sequence.
#[derive(Clone)]
pub struct ExportSetup {
    /// Writes the files, one job after the other.
    pub queue: Arc<ExportQueue>,
    /// Renders a sequence of the snapshot.
    pub make_sources: MakeExportSources,
    /// Reads a rendered frame as RGBA for the sheet's preview picture; `None` = the sheet has no preview.
    pub frame_pixels: Option<FramePixels>,
    /// The offline mix of a stem; `None` = the sheet offers no stems.
    pub make_stem_audio: Option<MakeStemAudio>,
    /// Writes the stem files; `None` = the sheet offers no stems.
    pub stem_encoder: Option<Arc<dyn ExportEncoding>>,
}

/// The stem audio provider the Export model calls with a sequence, a stem and a range.
pub(crate) fn stem_provider(snapshot: SharedSnapshot, make: MakeStemAudio) -> StemAudioProvider {
    Arc::new(move |_, stem, range| {
        let snap = snapshot.lock().unwrap_or_else(PoisonError::into_inner).clone();
        make(&snap, stem, range)
    })
}

/// The sources provider the Export model calls with a sequence id.
pub(crate) fn provider(snapshot: SharedSnapshot, make: MakeExportSources) -> SourceProvider {
    Arc::new(move |id, settings| {
        let snap = snapshot.lock().unwrap_or_else(PoisonError::into_inner).clone();
        make(&snap, id, settings)
    })
}

/// Runs the queue on its own thread: `run_all` blocks until every waiting job ended, and the shell follows the statuses.
/// A second start while a run is going only adds its job: the queue's worker takes it up after the running one (the
/// queue, as in Swift), and the second thread returns at once.
pub(crate) fn run_queue(queue: Arc<ExportQueue>) {
    std::thread::spawn(move || queue.run_all());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ShellDeferred, ShellHost};
    use sq_draw_shell::{NoHooks, ShellFlow, ShellHost as DrawShell};
    use sq_export::core::traits::ExportEncoding;
    use sq_runtime::FakeClock;
    use sq_uikit::command_map::CommandMap;
    use sq_uikit::editor_command::EditorCommand;

    use sq_core_time::Time;
    use sq_export::core::queue::ExportJob;
    use sq_export::core::queue_state::ExportJobState;
    use sq_export::core::traits::FrameSource;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// An encoder that holds its first export until the gate opens, and logs the files in the order they started.
    struct Gate(Arc<AtomicBool>, Arc<Mutex<Vec<String>>>);
    impl ExportEncoding for Gate {
        fn export(
            &self,
            _: &mut dyn FrameSource,
            _: Option<&mut dyn AudioSource>,
            _: &ExportSettings,
            url: &std::path::Path,
            _: &sq_export::core::error::CancelToken,
            _: &mut dyn FnMut(f64),
        ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, ExportError> {
            self.1.lock().unwrap().push(url.file_name().unwrap().to_string_lossy().into_owned());
            while !self.0.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            std::fs::write(url, [1u8]).map_err(|e| ExportError::Other(e.to_string()))?;
            Ok(None)
        }
    }

    struct OneFrame;
    impl FrameSource for OneFrame {
        fn frame_count(&self) -> usize {
            1
        }
        fn frame_duration(&self) -> Time {
            Time::new(1, 30)
        }
        fn frame(&mut self, _: usize) -> Result<sq_export::core::traits::ExportFrame, ExportError> {
            Err(ExportError::EmptySource)
        }
    }

    fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < end {
            if cond() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        panic!("timed out waiting for {what}");
    }

    /// Swift queues a second export behind the running one. Starting twice must run both, one after the other, and the
    /// second start must not run a second worker beside the first.
    #[test]
    fn a_second_export_start_while_one_runs_is_queued_behind_it() {
        let dir = crate::test_rig::unique_dir("sq-export-second-start");
        std::fs::create_dir_all(&dir).unwrap();
        let (open, log) = (Arc::new(AtomicBool::new(false)), Arc::new(Mutex::new(Vec::new())));
        let queue = Arc::new(ExportQueue::new(Arc::new(Gate(Arc::clone(&open), Arc::clone(&log)))));
        let job = |n: u128| {
            let mut settings = ExportSettings::default();
            settings.video.width = 64;
            settings.video.height = 112;
            settings.audio.enabled = false;
            ExportJob::new(
                Id::from_u128(n),
                &format!("J{n}"),
                settings,
                dir.clone(),
                Arc::new(|| Ok(ExportSources::new(Box::new(OneFrame), None))),
            )
        };
        let first = queue.enqueue(job(1));
        run_queue(Arc::clone(&queue));
        wait_until("the first export to run", || {
            queue.status(first).is_some_and(|s| s.state == ExportJobState::Running)
        });
        let second = queue.enqueue(job(2));
        run_queue(Arc::clone(&queue));
        assert_eq!(queue.status(second).map(|s| s.state), Some(ExportJobState::Waiting), "queued, not started");
        assert_eq!(log.lock().unwrap().len(), 1, "one export at a time");
        open.store(true, Ordering::SeqCst);
        let ended = |id: Id| queue.status(id).is_some_and(|s| matches!(s.state, ExportJobState::Done(_)));
        let states =
            || format!("{:?} {:?}", queue.status(first).map(|s| s.state), queue.status(second).map(|s| s.state));
        wait_until("both exports to end", || ended(first) && ended(second) || states().contains("Failed"));
        assert!(ended(first) && ended(second), "{}", states());
        assert_eq!(*log.lock().unwrap(), ["J1.mp4", "J2.mp4"]);
    }

    struct NoEncoder;
    impl ExportEncoding for NoEncoder {
        fn export(
            &self,
            _: &mut dyn sq_export::core::traits::FrameSource,
            _: Option<&mut dyn sq_export::core::traits::AudioSource>,
            _: &ExportSettings,
            _: &std::path::Path,
            _: &sq_export::core::error::CancelToken,
            _: &mut dyn FnMut(f64),
        ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, ExportError> {
            Err(ExportError::Other("test".into()))
        }
    }

    fn shell() -> ShellHost {
        let draw = DrawShell::new(
            CommandMap::premiere_default(),
            sq_editor_session::RecentProjects::new(Vec::new()),
            std::sync::Arc::new(FakeClock::new()),
            Box::new(|| sq_core_time::Timestamp::from_unix_seconds(0.0)),
        );
        ShellHost::new(draw, Some(Box::new(NoHooks)))
    }

    fn setup() -> ExportSetup {
        ExportSetup {
            queue: Arc::new(ExportQueue::new(Arc::new(NoEncoder))),
            make_sources: Arc::new(|_, _, _| Err(ExportError::Other("no renderer".into()))),
            frame_pixels: None,
            make_stem_audio: None,
            stem_encoder: None,
        }
    }

    fn run_export_command(host: &mut ShellHost) -> Vec<ShellDeferred> {
        run_command(host, EditorCommand::Export)
    }

    fn run_command(host: &mut ShellHost, command: EditorCommand) -> Vec<ShellDeferred> {
        let mut ids = sq_core_time::SequentialIds::default();
        let project = sq_editor_session::EditorSession::make_untitled(&mut ids);
        let session = sq_editor_session::EditorSession::new(
            project,
            sq_editor_session::SessionDeps::headless(crate::test_rig::unique_dir("sq-export-host-tests")),
        );
        let mut rig = crate::test_rig::Rig::new(session);
        host.run_command(&mut rig.cx(), command);
        host.take_deferred()
    }

    #[test]
    fn the_export_command_starts_the_export_flow_once_export_is_set_up() {
        let mut host = shell();
        assert!(!run_export_command(&mut host).contains(&ShellDeferred::Flow(ShellFlow::ShowExport)));
        host.enable_export(setup());
        assert!(run_export_command(&mut host).contains(&ShellDeferred::Flow(ShellFlow::ShowExport)));
    }

    #[test]
    fn quick_export_starts_its_own_flow_without_a_sheet() {
        let mut host = shell();
        assert!(
            !run_command(&mut host, EditorCommand::QuickExport).contains(&ShellDeferred::Flow(ShellFlow::QuickExport))
        );
        host.enable_export(setup());
        let deferred = run_command(&mut host, EditorCommand::QuickExport);
        assert!(deferred.contains(&ShellDeferred::Flow(ShellFlow::QuickExport)));
        assert!(!deferred.contains(&ShellDeferred::Flow(ShellFlow::ShowExport)));
    }
}
