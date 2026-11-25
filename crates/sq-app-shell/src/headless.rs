//! The headless frame loop (no window, no platform): scenario scripts, fuzzing and oracle dumps drive the app here
//! exactly as the binary does, one loop turn at a time.

use crate::{App, AppDeps, AppServices, PanelFileChooser, ShellFilePicker, answered};
use sq_draw::{DrawList, DrawTheme, InputEvent};
use sq_draw_shell::ShellHost;
use sq_editor_session::EditorSession;
use sq_editor_session::ProjectPanelDeps;
use sq_runtime::{Clock, FrameStats, ModalAsk, UiExecutor, UiRef, UiRoot};
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// Choosers that cancel every dialog (headless runs).
pub struct CancelAllFiles;

static CANCELLED: AtomicUsize = AtomicUsize::new(0);

/// How many file choosers [`CancelAllFiles`] has cancelled in this process: a click sweep tells a button that opens a
/// chooser from a button that does nothing.
pub fn file_pickers_cancelled() -> usize {
    CANCELLED.load(Ordering::Relaxed)
}

fn cancelled<T>(answer: T) -> T {
    CANCELLED.fetch_add(1, Ordering::Relaxed);
    answer
}

impl ShellFilePicker for CancelAllFiles {
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_save_location(&mut self, _suggested_name: &str, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
        answered(cancelled(Vec::new()))
    }
    fn choose_shortcut_file(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_shortcut_export_location(&mut self, _suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_style_kit(&mut self, _save: bool, _suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    // The Export sheet's "Change..." and Reconnect Media ask for a folder: a sweep must see them open a chooser.
    fn choose_folder(&mut self, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_file(&mut self, _prompt: &str, _directory: Option<&Path>) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
    fn choose_export_location(
        &mut self,
        _suggested_name: &str,
        _extension: &str,
        _prompt: &str,
    ) -> ModalAsk<Option<PathBuf>> {
        answered(cancelled(None))
    }
}

impl PanelFileChooser for CancelAllFiles {
    fn choose_subtitles(&mut self) -> Option<PathBuf> {
        cancelled(None)
    }
    fn choose_srt_location(&mut self, _suggested_name: &str) -> Option<PathBuf> {
        cancelled(None)
    }
    fn choose_frame_location(&mut self, _suggested_name: &str, _formats: &[(&str, &str)]) -> Option<PathBuf> {
        cancelled(None)
    }
    fn choose_csv_location(&mut self, _suggested_name: &str) -> Option<PathBuf> {
        cancelled(None)
    }
    fn choose_luts(&mut self, _multiple: bool) -> Vec<PathBuf> {
        cancelled(Vec::new())
    }
}

impl AppServices {
    /// No platform: every chooser cancels, no monitor backend, sampler or segmenter.
    pub fn headless() -> AppServices {
        AppServices {
            files: Box::new(CancelAllFiles),
            panel_files: Box::new(CancelAllFiles),
            monitor: None,
            sampler: None,
            magic: None,
            audio_notices: Default::default(),
        }
    }
}

impl AppDeps {
    /// Headless services, no glyph atlas, the default theme, no wake-up.
    pub fn headless(clock: Arc<dyn Clock>) -> AppDeps {
        AppDeps {
            services: AppServices::headless(),
            clock,
            atlas: None,
            theme: DrawTheme::default(),
            wake: Box::new(|| {}),
            import: ProjectPanelDeps::headless(),
        }
    }
}

thread_local! {
    static PHASES: std::cell::RefCell<Vec<(&'static str, Duration)>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Runs `f` and files its time under `name` for the slow-frame log (`App::frame` moves it into the frame profile).
pub fn timed<R>(name: &'static str, f: impl FnOnce() -> R) -> R {
    let began = Instant::now();
    let r = f();
    PHASES.with(|p| p.borrow_mut().push((name, began.elapsed())));
    r
}

/// The phases `timed` filed since the last call.
pub fn take_phases() -> Vec<(&'static str, Duration)> {
    PHASES.with(|p| std::mem::take(&mut *p.borrow_mut()))
}

/// Where the last [`Headless::turn_with`] spent its time (the window loop logs a slow turn with it).
#[derive(Debug, Default, Clone, Copy)]
pub struct TurnTimes {
    /// The inbox drain.
    pub drain: Duration,
    /// Flow starts plus the first poll of every ready task (UI-thread futures).
    pub tasks: Duration,
    /// `App::settle` and the follow-up polls of tasks that became ready meanwhile.
    pub settle: Duration,
    /// Sync, layout and draw of every host (`App::frame`); zero when no frame was built.
    pub frame: Duration,
    /// The longest single task poll and the task's name.
    pub slowest_poll: (Duration, &'static str),
    /// Whether this turn built a frame (`App::frame_profile` is then fresh).
    pub drew: bool,
}

/// The app in its root plus the UI executor, with a fixed window size.
pub struct Headless {
    root: UiRoot<App>,
    executor: UiExecutor,
    width: i64,
    height: i64,
    last_turn: Cell<TurnTimes>,
}

impl Headless {
    /// A loop around `session`; the executor and the app share `clock`.
    pub fn new(session: EditorSession, deps: AppDeps, width: i64, height: i64) -> Headless {
        let executor = UiExecutor::new(Arc::clone(&deps.clock));
        Headless { root: UiRoot::new(App::new(session, deps)), executor, width, height, last_turn: Cell::default() }
    }

    /// Closure-only access to the app (`None` only on a re-entrant call).
    pub fn with<R>(&self, f: impl FnOnce(&mut App) -> R) -> Option<R> {
        self.root.with(f)
    }

    /// A weak handle for async flows (`UiRef<dyn SessionRoot>` coerces from it via `UiRef::new(root.weak())`).
    pub fn handle(&self) -> UiRef<App> {
        UiRef::new(self.root.weak())
    }

    /// The executor (spawn flows, read the next deadline).
    pub fn executor(&self) -> &UiExecutor {
        &self.executor
    }

    /// Resizes the window; the next turn draws.
    pub fn resize(&mut self, width: i64, height: i64) {
        self.width = width;
        self.height = height;
        self.root.with(App::set_needs_redraw);
    }

    /// One input event; true when a host took it.
    pub fn input(&self, e: &InputEvent) -> bool {
        self.root.with(|a| a.handle(e)).unwrap_or(false)
    }

    /// Starts the project folder watcher on the executor: every tick, new media in the project folder is filed into the
    /// bins and vanished files turn offline (while the project's watch-folder setting is on). Call it once.
    pub fn watch_project_folder(&self) {
        drop(self.executor.spawn_local(sq_editor_session::FolderWatch::run(self.handle())));
    }

    /// Starts the menu commands the hosts queued as tasks on the executor.
    fn spawn_flows(&self) {
        for flow in self.root.with(App::take_flows).unwrap_or_default() {
            drop(self.executor.spawn_local(ShellHost::run_flow(self.handle(), flow)));
        }
    }

    /// One loop turn: drain the inbox, poll the ready tasks outside the root borrow, then draw if anything changed.
    pub fn turn(&self) -> (FrameStats, Option<DrawList>) {
        self.turn_with(true)
    }

    /// [`turn`](Self::turn) that draws only when `may_draw` (the window loop holds the frame back during a drag, see
    /// `sequence-studio/src/drag_pacing.rs`): inbox and tasks run, the app stays dirty and the next turn that may draw lays out
    /// once for everything that arrived meanwhile.
    pub fn turn_with(&self, may_draw: bool) -> (FrameStats, Option<DrawList>) {
        let began = Instant::now();
        self.root.with(App::drain);
        let drained = Instant::now();
        self.spawn_flows();
        let stats = self.executor.poll_frame();
        let polled = Instant::now();
        self.root.with(App::settle);
        self.spawn_flows();
        // A task that ended may have queued a flow (the "Export finished" card): run it now, or it waits for the next
        // input event because a ready task does not wake an idle loop. Bounded: a flow that starts flows forever stops.
        for _ in 0..4 {
            if !self.executor.has_ready() {
                break;
            }
            self.executor.poll_frame();
            self.root.with(App::settle);
            self.spawn_flows();
        }
        let settled = Instant::now();
        let (w, h) = (self.width, self.height);
        let list = self.root.with(|a| (may_draw && a.needs_redraw()).then(|| a.frame(w, h))).flatten();
        self.last_turn.set(TurnTimes {
            drain: drained - began,
            tasks: polled - drained,
            settle: settled - polled,
            frame: settled.elapsed(),
            slowest_poll: self.executor.take_slowest_poll(),
            drew: list.is_some(),
        });
        (stats, list)
    }

    /// The phase times of the last turn.
    pub fn last_turn(&self) -> TurnTimes {
        self.last_turn.get()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sweep tells a button that opens a chooser from a dead one by the count: every chooser of the shell counts, the folder
    /// chooser of the Export sheet's "Change..." among them.
    #[test]
    fn every_chooser_of_the_shell_counts() {
        let mut files = CancelAllFiles;
        let before = file_pickers_cancelled();
        drop(ShellFilePicker::choose_project(&mut files));
        drop(ShellFilePicker::choose_save_location(&mut files, "a", "b"));
        drop(ShellFilePicker::choose_media(&mut files));
        drop(files.choose_shortcut_file());
        drop(files.choose_shortcut_export_location("a"));
        drop(files.choose_style_kit(true, "a"));
        drop(files.choose_folder("a"));
        drop(files.choose_file("a", None));
        drop(files.choose_export_location("a", "mov", "b"));
        // Other tests of the process may count too, never fewer.
        assert!(file_pickers_cancelled() >= before + 9, "{} -> {}", before, file_pickers_cancelled());
    }
}
