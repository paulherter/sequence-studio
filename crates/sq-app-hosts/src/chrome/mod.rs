// Swift: SharedUIController.swift:810, 1041-1100 (statusContent, layoutTitleRow, the bars' hit tests)
//! The editing window's chrome around the dock: the title row on top (project name, edit time, Workspace popup, Export)
//! and the status bar at the bottom. The root owns one [`Chrome`], lays it out before the dock and asks it for what a
//! click means.

mod error_line;
mod status_bar;
mod title_row;

use sq_core_model::TrackKind;
use sq_draw::{Canvas, DrawTheme, TextMeasure};
use sq_draw_shell::ShellHost as DrawShell;
use sq_editor_session::{EditorSession, MonitorQuality, SaveStatus, WorkspacePage};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{metrics, spacing, type_size};
use sq_uikit::sqmenu_model::SQMenuItem;
use status_bar::{StatusBarContent, StatusPart};
use std::time::{Duration, SystemTime};
pub use title_row::Mouse;
use title_row::{TitleAction, TitleRow};

/// The traffic lights' share of the title row when no in-window menu titles precede it (points).
const WINDOW_BUTTONS: f64 = 78.0;
/// How long a status line stays in the bar.
const FLASH: Duration = Duration::from_secs(8);

/// What a click on the chrome asks the root to do.
#[derive(Clone, Debug, PartialEq)]
pub enum ChromeAction {
    /// The Export button.
    Export,
    /// Open this popup below the frame (the Workspace items are taken from the menus).
    Workspaces(CGRect),
    /// The Edit | Color switch asks for this page.
    Page(WorkspacePage),
    /// The relink chip: reconnect what is offline.
    Relink,
    /// The export ring: open the queue above this point.
    Queue(CGPoint, CGRect),
}

/// The values the chrome shows, read from the app once per frame.
pub struct ChromeInputs<'a> {
    pub session: &'a EditorSession,
    pub shell: &'a DrawShell,
    pub quality: MonitorQuality,
    pub linked_selection: bool,
    /// The page the dock shows.
    pub page: WorkspacePage,
    /// The Color page's grade text (empty elsewhere).
    pub grade: &'a str,
    pub now: SystemTime,
}

/// Title row and status bar with their frames.
#[derive(Default)]
pub struct Chrome {
    title: TitleRow,
    status: StatusBarContent,
    top: CGRect,
    bar: CGRect,
    right_margin: Option<f64>,
    flash: Option<(String, SystemTime)>,
    error_line: error_line::ErrorLine,
    dirty_since: Option<SystemTime>,
    /// Progress of the analysis jobs; the ring shows it when no export or queue job does.
    job_progress: Option<f64>,
    /// A running job's line ("Anonymize: analyzing ... 42 %"): the status bar shows it while no error or flash does.
    job_line: Option<String>,
}

impl Chrome {
    /// The running job's status line (Swift `shell.onJob`); `None` clears it.
    pub fn set_job_line(&mut self, line: Option<String>) {
        self.job_line = line;
    }

    /// The running job's line.
    #[cfg(test)]
    pub(crate) fn job_line(&self) -> Option<&str> {
        self.job_line.as_deref()
    }

    /// The analysis jobs' progress (`None`: none runs).
    pub fn set_job_progress(&mut self, progress: Option<f64>) {
        self.job_progress = progress;
    }

    /// Shows `line` in the status bar for a while.
    pub fn flash(&mut self, line: String, now: SystemTime) {
        self.flash = Some((line, now));
    }

    /// The title row's clickable frames and the bottom edge of the row, in window points.
    /// Locks Export while the project opens (r8 loading state).
    pub fn set_export_locked(&mut self, locked: bool) {
        self.title.export_locked = locked;
    }

    pub fn title_drag(&self) -> (Vec<CGRect>, f64) {
        (self.title.controls(), self.top.max_y())
    }

    /// The title row's frame in window points (empty before the first layout).
    #[cfg(test)]
    pub fn title_frame(&self) -> CGRect {
        self.top
    }

    /// The status bar's frame in window points.
    #[cfg(test)]
    pub fn status_frame(&self) -> CGRect {
        self.bar
    }

    fn update(&mut self, i: &ChromeInputs) {
        let s = i.session;
        let mut c = StatusBarContent::default();
        if let Some(t) = s.active_timeline() {
            let f = &t.format;
            let vfr = t.tracks.iter().filter(|k| k.kind == TrackKind::Video).flat_map(|k| k.clips()).any(|clip| {
                s.project()
                    .media(clip.media)
                    .and_then(|m| m.info.as_ref())
                    .and_then(|info| info.video.as_ref())
                    .is_some_and(|v| v.is_variable_frame_rate)
            });
            let fd = f.frame_duration;
            let fps = fd.timescale() as f64 / fd.value().max(1) as f64;
            c.format = StatusBarContent::format_text(f.width, f.height, fps, vfr);
        }
        if s.is_dirty() {
            self.dirty_since.get_or_insert(i.now);
        } else {
            self.dirty_since = None;
        }
        let status = SaveStatus::make(s.is_dirty(), s.file_url().is_some(), None, None, 0);
        c.save = Some(if s.salvaged_from().is_some() { status.repaired() } else { status });
        let error = self.error_line.show(s.last_error(), s.error_serial(), i.now);
        c.message = match (error, &self.flash) {
            (Some(e), _) => e,
            (None, Some((line, at))) if i.now.duration_since(*at).is_ok_and(|d| d < FLASH) => line.clone(),
            _ => self.job_line.clone().unwrap_or_default(),
        };
        c.playback = StatusBarContent::playback_text(i.quality);
        c.grade = i.grade.to_string();
        c.linked_selection_off = !i.linked_selection;
        c.relink_offer = i.shell.flow_env.relink_offer.as_ref().map(|o| o.text.clone()).unwrap_or_default();
        // The ring covers exports and the queue's background jobs (analysis, proxies) as the Mac job center does.
        let jobs: Vec<f64> = i.shell.export.background_jobs.iter().filter_map(|j| j.progress).collect();
        c.export_progress = i
            .shell
            .export
            .progress
            .or_else(|| (!jobs.is_empty()).then(|| jobs.iter().sum::<f64>() / jobs.len() as f64))
            .or(self.job_progress);
        self.status = c;
        self.title.project_name = s.display_name();
        self.title.edited = if s.is_dirty() { self.dirty_since } else { saved_time(s) };
        self.title.saved = !s.is_dirty();
        self.title.color_page = i.page == WorkspacePage::Color;
        self.title.workspace_name = sq_uikit::platform_wording::PlatformWording::workspace_name(
            &i.shell.dock.store().current().name,
            sq_os::Platform::current(),
        );
    }

    /// Sets where the Export button's right edge sits from the window's right edge (the Windows caption buttons take
    /// 138 pt there; the spec keeps Export 146 pt from the edge, 10 pt on Linux).
    pub fn set_right_margin(&mut self, margin: f64) {
        self.right_margin = Some(margin);
    }

    /// The room the menu titles may take from the bar's origin in a window `width` wide: they end before the Export button,
    /// the last ones fold into the overflow menu.
    pub fn menu_room(&self, width: f64, origin_x: f64, m: &TextMeasure) -> f64 {
        let right = width - self.right_margin.unwrap_or(f64::from(spacing::MD));
        (TitleRow::menu_room(right, m) - origin_x).max(0.0)
    }

    /// Places the rows in `frame`; returns the body left for the dock. The menu titles (Windows, Linux) sit in the title
    /// row itself, which starts at the top of the frame.
    pub fn layout(&mut self, frame: CGRect, i: &ChromeInputs, m: &TextMeasure) -> CGRect {
        let top_h = f64::from(metrics::TOP_BAR);
        let status_h = f64::from(metrics::STATUS_BAR);
        self.update(i);
        self.top = CGRect::new(frame.x, frame.y, frame.width, top_h);
        self.bar = CGRect::new(frame.x, frame.max_y() - status_h, frame.width, status_h);
        // With in-window menu titles the row starts after them; otherwise after the window buttons.
        let right = frame.width - self.right_margin.unwrap_or(f64::from(spacing::MD));
        let bar = &i.shell.menu_bar;
        let after =
            bar.overflow_frame().or_else(|| bar.title_frames().last().copied()).map_or(WINDOW_BUTTONS, |r| r.max_x());
        self.title.icon_in_menu_bar = bar.shows_titles();
        self.title.layout(after, (frame.width, right), self.top.min_y(), top_h, m, i.now);
        CGRect::new(frame.x, self.top.max_y(), frame.width, (self.bar.min_y() - self.top.max_y()).max(0.0))
    }

    /// Draws both rows. Call before the panels so the dock's card gaps sit on the same ground.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, i: &ChromeInputs) {
        self.update(i);
        c.fill(self.top, t.titlebar());
        c.fill(CGRect::new(self.top.min_x(), self.top.max_y() - 1.0, self.top.width, 1.0), t.hair());
        self.title.draw(c, t, i.now);
        status_bar::draw(c, &self.status, self.bar, t);
    }

    /// Hover and clicks on the rows; `p` in window points. Returns whether the chrome took the event.
    pub fn handle(&mut self, mouse: Mouse, p: CGPoint, m: &TextMeasure, actions: &mut Vec<ChromeAction>) -> bool {
        let (taken, action) = self.title.mouse(mouse, p);
        match action {
            Some(TitleAction::Export) => actions.push(ChromeAction::Export),
            Some(TitleAction::Workspaces(r)) => actions.push(ChromeAction::Workspaces(r)),
            Some(TitleAction::Page(p)) => actions.push(ChromeAction::Page(p)),
            None => {}
        }
        if taken || mouse != Mouse::Down || !self.bar.contains(p) {
            return taken;
        }
        let width = |s: &str| m.width(s, f64::from(type_size::BODY), 0);
        let chip = |s: &str| m.width(s, f64::from(type_size::CAPTION), 0);
        match status_bar::part_at(p, &self.status, self.bar, &width, &chip) {
            Some(StatusPart::Relink) => actions.push(ChromeAction::Relink),
            Some(StatusPart::Ring) => {
                let ring = status_bar::layout(&self.status, self.bar, &width, &chip).ring.unwrap_or_default();
                actions.push(ChromeAction::Queue(CGPoint::new(p.x, self.bar.min_y()), ring));
            }
            None => return false,
        }
        true
    }

    /// The Workspace button's frame in window points.
    #[cfg(test)]
    pub fn workspace_button(&self) -> Option<CGRect> {
        self.title.workspace_frame()
    }

    /// The Workspace popup's rows: the "Workspaces" submenu of the shell's menus.
    pub fn workspace_items(shell: &DrawShell) -> Vec<SQMenuItem> {
        shell
            .menu_bar
            .menus()
            .iter()
            .flat_map(|menu| menu.items.iter())
            .find(|item| item.title == "Workspaces")
            .and_then(|item| item.submenu.clone())
            .unwrap_or_default()
    }
}

/// When the project file last changed on disk.
fn saved_time(s: &EditorSession) -> Option<SystemTime> {
    std::fs::metadata(s.file_url()?).and_then(|m| m.modified()).ok()
}

#[cfg(test)]
mod tests;

/// What the component catalogue renderer (`catalogue_shots.rs`) draws; test builds only.
#[cfg(test)]
pub(crate) mod test_access {
    pub use super::status_bar::{StatusBarContent, draw as status_bar_draw};
    pub use super::title_row::{Mouse, TitleRow};
    pub mod status_bar {
        pub use super::status_bar_draw as draw;
    }
}
