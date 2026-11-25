// Swift: ShellExportQueuePopover.swift
//! The export queue popover (kit `dialogs.html` `.qp`): a 40 pt header, then sections (Exporting, Waiting, Finished, In
//! the background) of rows with a 14 pt state icon, the name, a progress bar while a job runs and the state line;
//! Cancel on a waiting or running row and the file's folder on a finished one; "Stop All" and "Clear Finished" in the
//! footer. It opens above the status bar's ring, refreshes while open and closes on a click outside or Escape.
//!
//! Mapping: the Swift callbacks (`onCancel`, `onReveal`, `onClose`, `onCancelBackground`) are [`QueuePopoverEvent`]s the host
//! drains with [`ExportQueuePopover::take_events`].

use sq_core_time::Id;
use sq_draw::scroll::ScrollBody;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, InputKey, TextAlign, UiCx};
use sq_export::core::queue::ExportJobState;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use std::collections::BTreeSet;
use std::path::PathBuf;

/// One job as the queue reports it.
#[derive(Clone, Debug, PartialEq)]
pub struct QueueJob {
    /// The job.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// State.
    pub state: ExportJobState,
    /// 0...1.
    pub progress: f64,
}

impl QueueJob {
    fn is_finished(&self) -> bool {
        !self.state.is_active()
    }
}

/// A background job above the list (the Mac `BackgroundJob`): title, optional progress and Cancel.
#[derive(Clone, Debug, PartialEq)]
pub struct BackgroundJob {
    /// The job's id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Progress, if known.
    pub progress: Option<f64>,
}

/// What the popover asks of the host.
#[derive(Clone, Debug, PartialEq)]
pub enum QueuePopoverEvent {
    /// Stop an export job.
    Cancel(Id),
    /// Stop a background job.
    CancelBackground(String),
    /// Show a finished file in the file browser.
    Reveal(PathBuf),
    /// Stop everything listed: waiting jobs, running jobs and background jobs.
    StopAll { running: Vec<Id>, waiting: Vec<Id>, background: Vec<String> },
    /// Close the popover.
    Close,
}

/// The export queue popover (Swift `ExportQueuePopover`).
pub struct ExportQueuePopover {
    jobs: Vec<QueueJob>,
    frame: CGRect,
    scroll_body: ScrollBody,
    background: Vec<BackgroundJob>,
    cleared: BTreeSet<Id>,
    anchor: CGPoint,
    /// The list height the window leaves (the header, the footer and an 8 pt margin on both sides taken off): a small
    /// window scrolls the list instead of pushing the footer out of the window.
    list_room: f64,
    hover_row: Option<usize>,
    hover_clear: bool,
    hover_stop: bool,
    /// Full texts of the cut names and error lines drawn last (window points): the tooltip under the pointer.
    cut_tips: Vec<(CGRect, String)>,
    /// Poses (`--pose dlg-queue`): the jobs given stay, the host's refresh leaves them alone.
    pub pinned: bool,
    /// "Show in Explorer" / "Reveal in Finder".
    pub reveal_title: String,
    /// The host can show a file in the file browser.
    pub can_reveal: bool,
    /// The status-bar ring that opened it (window points): a press there only closes the popover, any other press outside
    /// it closes it and goes on to what is under the pointer.
    pub opener: CGRect,
    events: Vec<QueuePopoverEvent>,
}

/// One line of the list: a section label, an export job or a background job (indices into the popover's lists).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Entry {
    Section(&'static str),
    Job(usize),
    Background(usize),
}

impl ExportQueuePopover {
    /// The popover's width.
    pub const WIDTH: f64 = 340.0;
    /// The title band (`.qp-h`).
    pub const HEADER_HEIGHT: f64 = 40.0;
    /// A section label (`.qsec`).
    pub const SECTION_HEIGHT: f64 = 25.0;
    /// A row with a state line only (`.qi`).
    pub const ROW_HEIGHT: f64 = 46.0;
    /// A row with a progress bar.
    pub const BAR_ROW_HEIGHT: f64 = 58.0;
    /// The footer with Stop All and Clear Finished.
    pub const FOOTER_HEIGHT: f64 = 42.0;
    /// The list scrolls beyond this height.
    pub const MAX_LIST_HEIGHT: f64 = 360.0;
    /// The empty list.
    const EMPTY_HEIGHT: f64 = 80.0;
    const PAD: f64 = 14.0;
    const BUTTON: f64 = 20.0;
    const ICON: f64 = 14.0;
    const FOOT_BUTTON: f64 = 22.0;

    /// A popover above `anchor` (the status bar's ring).
    pub fn new(anchor: CGPoint) -> ExportQueuePopover {
        ExportQueuePopover {
            jobs: Vec::new(),
            frame: CGRect::default(),
            scroll_body: ScrollBody::new(0.0),
            background: Vec::new(),
            cleared: BTreeSet::new(),
            anchor,
            list_room: Self::MAX_LIST_HEIGHT,
            hover_row: None,
            hover_clear: false,
            hover_stop: false,
            cut_tips: Vec::new(),
            pinned: false,
            reveal_title: "Show in Explorer".to_string(),
            can_reveal: true,
            opener: CGRect::default(),
            events: Vec::new(),
        }
    }

    /// The host's requests since the last call, in order.
    pub fn take_events(&mut self) -> Vec<QueuePopoverEvent> {
        std::mem::take(&mut self.events)
    }

    /// Jobs as the queue reports them (finished ones the user cleared are not listed).
    pub fn jobs(&self) -> &[QueueJob] {
        &self.jobs
    }

    /// The status-bar control the popover opens out of.
    pub fn anchor(&self) -> CGPoint {
        self.anchor
    }

    /// The popover's frame, window points.
    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// The background jobs.
    pub fn background(&self) -> &[BackgroundJob] {
        &self.background
    }

    /// New job states; `bg` replaces the background jobs when given.
    pub fn update(&mut self, all: &[QueueJob], bg: Option<Vec<BackgroundJob>>) {
        if let Some(bg) = bg {
            self.background = bg;
        }
        self.jobs = all.iter().filter(|j| !self.cleared.contains(&j.id)).cloned().collect();
        self.clamp_scroll();
    }

    fn clamp_scroll(&mut self) {
        let v = self.scroll_body.position().min(self.max_scroll());
        self.scroll_body.assign(v);
    }

    /// Hides the finished jobs (the queue itself keeps them).
    pub fn clear_finished(&mut self) {
        self.cleared.extend(self.jobs.iter().filter(|j| j.is_finished()).map(|j| j.id));
        self.jobs.retain(|j| !j.is_finished());
        self.clamp_scroll();
    }

    fn has_finished(&self) -> bool {
        self.jobs.iter().any(QueueJob::is_finished)
    }

    fn has_active(&self) -> bool {
        self.jobs.iter().any(|j| !j.is_finished()) || !self.background.is_empty()
    }

    fn bar_row(progress: Option<f64>) -> bool {
        progress.is_some_and(|p| p > 0.0)
    }

    fn entries(&self) -> Vec<Entry> {
        let mut out = Vec::new();
        let group = |out: &mut Vec<Entry>, title: &'static str, pick: &dyn Fn(&QueueJob) -> bool| {
            let at: Vec<usize> = (0..self.jobs.len()).filter(|&i| pick(&self.jobs[i])).collect();
            if !at.is_empty() {
                out.push(Entry::Section(title));
                out.extend(at.into_iter().map(Entry::Job));
            }
        };
        group(&mut out, "Exporting", &|j| matches!(j.state, ExportJobState::Running | ExportJobState::Cancelling));
        group(&mut out, "Waiting", &|j| j.state == ExportJobState::Waiting);
        // Finished rows alone need no label (the kit's "Done and failed" list has none).
        let finished: Vec<usize> = (0..self.jobs.len()).filter(|&i| self.jobs[i].is_finished()).collect();
        if !finished.is_empty() {
            if self.jobs.len() > finished.len() || !self.background.is_empty() {
                out.push(Entry::Section("Finished"));
            }
            out.extend(finished.into_iter().map(Entry::Job));
        }
        if !self.background.is_empty() {
            out.push(Entry::Section("In the background"));
            out.extend((0..self.background.len()).map(Entry::Background));
        }
        out
    }

    fn entry_height(&self, e: Entry) -> f64 {
        match e {
            Entry::Section(_) => Self::SECTION_HEIGHT,
            Entry::Job(i) => {
                // A failed row keeps a bar (red, where the job stopped) so the failure reads like the running rows.
                if matches!(self.jobs[i].state, ExportJobState::Running | ExportJobState::Failed(_)) {
                    Self::BAR_ROW_HEIGHT
                } else {
                    Self::ROW_HEIGHT
                }
            }
            Entry::Background(i) => {
                if Self::bar_row(self.background[i].progress) {
                    Self::BAR_ROW_HEIGHT
                } else {
                    Self::ROW_HEIGHT
                }
            }
        }
    }

    fn content_height(&self) -> f64 {
        self.entries().into_iter().map(|e| self.entry_height(e)).sum()
    }

    fn list_height(&self) -> f64 {
        if self.jobs.is_empty() && self.background.is_empty() {
            Self::EMPTY_HEIGHT
        } else {
            self.content_height().min(Self::MAX_LIST_HEIGHT).min(self.list_room)
        }
    }

    fn max_scroll(&self) -> f64 {
        (self.content_height() - self.list_height()).max(0.0)
    }

    fn footer_height(&self) -> f64 {
        if self.jobs.is_empty() { 0.0 } else { Self::FOOTER_HEIGHT }
    }

    fn list_rect(&self) -> CGRect {
        CGRect::new(self.frame.min_x(), self.frame.min_y() + Self::HEADER_HEIGHT, self.frame.width, self.list_height())
    }

    fn footer_rect(&self) -> CGRect {
        CGRect::new(
            self.frame.min_x(),
            self.frame.min_y() + Self::HEADER_HEIGHT + self.list_height(),
            self.frame.width,
            Self::FOOTER_HEIGHT,
        )
    }

    /// Stop All, the rightmost footer button.
    fn stop_rect(&self) -> CGRect {
        let f = self.footer_rect();
        CGRect::new(f.max_x() - 12.0 - 72.0, f.mid_y() - Self::FOOT_BUTTON / 2.0, 72.0, Self::FOOT_BUTTON)
    }

    /// Clear Finished: right of Stop All, or at the right edge when nothing runs.
    fn clear_rect(&self) -> CGRect {
        let f = self.footer_rect();
        let right = if self.has_active() { self.stop_rect().min_x() - 8.0 } else { f.max_x() - 12.0 };
        CGRect::new(right - 104.0, f.mid_y() - Self::FOOT_BUTTON / 2.0, 104.0, Self::FOOT_BUTTON)
    }

    /// Places the popover above its anchor (the ring in the status bar), right edges aligned, inside `window`.
    pub fn layout(&mut self, window: CGRect) {
        self.list_room = (window.height - 16.0 - Self::HEADER_HEIGHT - self.footer_height()).max(Self::ROW_HEIGHT);
        let h = Self::HEADER_HEIGHT + self.list_height() + self.footer_height();
        let x = (self.anchor.x - Self::WIDTH + 24.0).max(window.min_x() + 8.0).min(window.max_x() - Self::WIDTH - 8.0);
        // Swift clamps with `min(max(x, lo), hi)`; the order matters when the window is narrower than the popover.
        let x = if window.max_x() - Self::WIDTH - 8.0 < window.min_x() + 8.0 {
            window.max_x() - Self::WIDTH - 8.0
        } else {
            x
        };
        let y = (self.anchor.y - 14.0 - h).max(window.min_y() + 8.0);
        self.frame = CGRect::new(x, y, Self::WIDTH, h);
    }

    /// Every entry with its frame, scrolled.
    fn laid_out(&mut self) -> Vec<(Entry, CGRect)> {
        let scroll = self.scroll_body.position();
        let mut y = self.list_rect().min_y() - scroll;
        self.entries()
            .into_iter()
            .map(|e| {
                let h = self.entry_height(e);
                let r = CGRect::new(self.frame.min_x(), y, self.frame.width, h);
                y += h;
                (e, r)
            })
            .collect()
    }

    fn entry_at(&mut self, p: CGPoint) -> Option<(Entry, CGRect)> {
        self.laid_out().into_iter().find(|(_, r)| r.contains(p))
    }

    fn action_rect(r: CGRect) -> CGRect {
        CGRect::new(r.max_x() - 12.0 - Self::BUTTON, r.mid_y() - Self::BUTTON / 2.0, Self::BUTTON, Self::BUTTON)
    }

    /// The icon and tip of a row's action button.
    fn action(&self, j: &QueueJob) -> Option<(SQIcon, String)> {
        match j.state {
            ExportJobState::Waiting | ExportJobState::Running => Some((SQIcon::CloseCircleFilled, "Stop".to_string())),
            ExportJobState::Done(_) => self.can_reveal.then(|| (SQIcon::FindFolder, self.reveal_title.clone())),
            _ => None,
        }
    }

    /// The state line of a job.
    pub fn state_text(s: &ExportJobState) -> String {
        match s {
            ExportJobState::Waiting => "Waiting".to_string(),
            ExportJobState::Running => "Exporting".to_string(),
            ExportJobState::Done(_) => "Done".to_string(),
            ExportJobState::Failed(why) => SQL10n::format("Failed: %@", &[why]),
            ExportJobState::Cancelling => "Stopping…".to_string(),
            ExportJobState::Cancelled => "Canceled".to_string(),
        }
    }

    /// The kit's 14 pt state icon and its color.
    fn state_icon(s: &ExportJobState, t: &DrawTheme) -> (SQIcon, Color) {
        match s {
            ExportJobState::Running | ExportJobState::Cancelling => (SQIcon::Upload, t.accent()),
            ExportJobState::Waiting => (SQIcon::Clock, t.label3()),
            ExportJobState::Done(_) => (SQIcon::CheckCircle, t.green()),
            ExportJobState::Failed(_) => (SQIcon::Warning, t.red()),
            ExportJobState::Cancelled => (SQIcon::Close, t.label4()),
        }
    }

    /// The accent bar (`.prog b`) on the well track.
    fn draw_bar(c: &mut Canvas, bar: CGRect, value: f64, fill: Color, t: &DrawTheme) {
        c.fill_rounded(bar, 2.0, t.well());
        if value > 0.0 {
            let w = (bar.width * value.clamp(0.0, 1.0)).max(4.0);
            c.fill_rounded(CGRect::new(bar.min_x(), bar.min_y(), w, bar.height), 2.0, fill);
        }
    }

    // MARK: Drawing

    /// Draws the popover. `now` is the steady clock in seconds.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        if self.frame.width <= 0.0 {
            return;
        }
        let body = f64::from(type_size::BODY);
        let caption = f64::from(type_size::CAPTION);
        let semibold = c.semibold();
        c.shadow(self.frame, 10.0, 18.0, 6.0, Color::new(0.0, 0.0, 0.0, 0.5), true);
        c.fill_rounded(self.frame, 10.0, t.overlay());
        c.stroke_rounded(self.frame, 10.0, 1.0, t.separator());
        let head = CGRect::new(self.frame.min_x(), self.frame.min_y(), self.frame.width, Self::HEADER_HEIGHT);
        c.draw_text_in(&SQL10n::string("Export Queue"), head, body, t.label(), TextAlign::Left, Self::PAD, semibold);
        let count = self.jobs.len() + self.background.len();
        if count > 0 {
            let text =
                if count == 1 { SQL10n::string("1 job") } else { SQL10n::format("%@ jobs", &[&count.to_string()]) };
            let area = CGRect::new(head.min_x(), head.min_y(), head.width - 12.0 - 16.0 - 8.0, head.height);
            c.draw_text_in(&text, area, caption, t.label3(), TextAlign::Right, 0.0, 0);
        }
        c.draw_icon(
            SQIcon::Ellipsis,
            CGPoint::new(head.max_x() - 12.0 - 16.0, head.mid_y() - 8.0),
            16.0,
            t.label3(),
            None,
        );
        c.fill(CGRect::new(head.min_x(), head.max_y() - 1.0, head.width, 1.0), t.separator());
        let list = self.list_rect();
        self.cut_tips.clear();
        c.save_gstate();
        c.clip_to(list);
        if self.jobs.is_empty() {
            let text = if self.background.is_empty() { "No tasks running" } else { "No exports" };
            let top = CGRect::new(list.min_x(), list.min_y(), list.width, list.height / 2.0 + 4.0);
            c.draw_text_in(&SQL10n::string(text), top, body, t.label2(), TextAlign::Center, 0.0, 0);
            let low = CGRect::new(list.min_x(), top.max_y(), list.width, list.height / 2.0 - 4.0);
            let hint = SQL10n::string("Exports you start show up here. You can keep editing meanwhile.");
            c.draw_text_in(&hint, low, caption, t.label4(), TextAlign::Center, 0.0, 0);
        }
        for (i, (entry, r)) in self.laid_out().into_iter().enumerate() {
            if r.max_y() < list.min_y() || r.min_y() > list.max_y() {
                continue;
            }
            let _ = i;
            let (title, line, bar, icon, line_color, act, why) = match entry {
                Entry::Section(name) => {
                    let label = CGRect::new(r.min_x(), r.min_y() + 10.0, r.width, 14.0);
                    c.draw_text_in(
                        &SQL10n::string(name),
                        label,
                        caption,
                        t.label3(),
                        TextAlign::Left,
                        Self::PAD,
                        semibold,
                    );
                    continue;
                }
                Entry::Job(i) => {
                    let j = self.jobs[i].clone();
                    if self.hover_row == Some(i) {
                        c.fill_rounded(r.inset_by(4.0, 2.0), f64::from(radius::SMALL), t.fill_hover());
                    }
                    let line = match j.state {
                        ExportJobState::Running => format!("{} %", (j.progress.clamp(0.0, 1.0) * 100.0).round()),
                        _ => Self::state_text(&j.state),
                    };
                    let failed = matches!(j.state, ExportJobState::Failed(_));
                    let bar = (j.state == ExportJobState::Running || failed).then_some(j.progress);
                    let line_color = if failed { t.err_text() } else { t.label3() };
                    let act = self.action(&j).is_some();
                    let why = failed.then(|| line.clone());
                    (j.name.clone(), line, bar, Self::state_icon(&j.state, t), line_color, act, why)
                }
                Entry::Background(i) => {
                    let b = &self.background[i];
                    let icon =
                        if b.title.to_lowercase().contains("transcri") { SQIcon::Captions } else { SQIcon::Stack };
                    let line = match b.progress.filter(|p| *p > 0.0) {
                        Some(p) => format!("{} %", (p.clamp(0.0, 1.0) * 100.0).round()),
                        None => SQL10n::string("Waiting"),
                    };
                    (b.title.clone(), line, b.progress.filter(|p| *p > 0.0), (icon, t.label3()), t.label3(), true, None)
                }
            };
            let text_x = r.min_x() + Self::PAD + Self::ICON + 10.0;
            let text_w = r.max_x() - 12.0 - text_x - if act { Self::BUTTON + 6.0 } else { 0.0 };
            c.draw_icon(
                icon.0,
                CGPoint::new(r.min_x() + Self::PAD, r.mid_y() - Self::ICON / 2.0),
                Self::ICON,
                icon.1,
                None,
            );
            // Names are cut in the middle (Finder-style), so "Cut v1" and "Cut v12" stay apart; the full name is the tip.
            let cut = c.truncated_name(&title, body, 0, text_w);
            let title_rect = CGRect::new(text_x, r.min_y() + 8.0, text_w, 18.0);
            if let Some(tip) = cut.tip() {
                self.cut_tips.push((title_rect, tip.to_string()));
            }
            c.draw_text_in(&cut.shown, title_rect, body, t.label(), TextAlign::Left, 0.0, 0);
            let line_y = if bar.is_some() { r.min_y() + 38.0 } else { r.min_y() + 26.0 };
            if let Some(p) = bar {
                let fill = if why.is_some() { t.red() } else { t.accent() };
                Self::draw_bar(c, CGRect::new(text_x, r.min_y() + 30.0, text_w, 4.0), p, fill, t);
            }
            let line_rect = CGRect::new(text_x, line_y, text_w, 16.0);
            // The error reads whole in the tip when the line is cut.
            let shown = c.ellipsized(&line, caption, 0, text_w);
            if let Some(full) = why.filter(|_| shown != line) {
                self.cut_tips.push((line_rect, full));
            }
            c.draw_text_in(&shown, line_rect, caption, line_color, TextAlign::Left, 0.0, 0);
            if act {
                let a = Self::action_rect(r);
                let glyph = match entry {
                    Entry::Job(i) => self.action(&self.jobs[i]).map_or(SQIcon::CloseCircleFilled, |a| a.0),
                    _ => SQIcon::CloseCircleFilled,
                };
                c.draw_icon(
                    glyph,
                    CGPoint::new(a.min_x() + 2.0, a.min_y() + 2.0),
                    Self::BUTTON - 4.0,
                    t.label2(),
                    None,
                );
            }
        }
        c.restore_gstate();
        let content = self.content_height();
        self.scroll_body.draw_scroller(c, list, content, t, now);
        if !self.jobs.is_empty() {
            let f = self.footer_rect();
            c.fill(CGRect::new(f.min_x(), f.min_y(), f.width, 1.0), t.separator());
            if self.has_active() {
                let touch = Touch { hovering: self.hover_stop, ..Touch::default() };
                c.stone_button(self.stop_rect(), ButtonKind::Raised, touch, t);
                let label = SQL10n::string("Stop All");
                c.draw_text_in(&label, self.stop_rect(), body, t.label(), TextAlign::Center, 0.0, 0);
            }
            if self.has_finished() {
                let touch = Touch { hovering: self.hover_clear, ..Touch::default() };
                c.stone_button(self.clear_rect(), ButtonKind::Quiet, touch, t);
                let label = SQL10n::string("Clear Finished");
                c.draw_text_in(&label, self.clear_rect(), body, t.label(), TextAlign::Center, 0.0, 0);
            }
        }
    }

    // MARK: Events (window points; `scale` converts the event's pixels)

    /// True when the popover took the event (it is modal: every press outside closes it).
    pub fn handle(&mut self, e: &InputEvent, scale: f32, ui: &mut UiCx, now: f64) -> bool {
        let list = self.list_rect();
        let content = self.content_height();
        if self.scroll_body.scroller_event(e, scale, list, content, now) {
            return true;
        }
        let k = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                let over = if self.frame.contains(p) && list.contains(p) { self.entry_at(p) } else { None };
                self.hover_row = match over {
                    Some((Entry::Job(i), _)) => Some(i),
                    _ => None,
                };
                let foot = !self.jobs.is_empty();
                self.hover_clear = foot && self.has_finished() && self.clear_rect().contains(p);
                self.hover_stop = foot && self.has_active() && self.stop_rect().contains(p);
                if let Some((Entry::Job(i), r)) = over
                    && let Some((_, tip)) = self.action(&self.jobs[i])
                    && Self::action_rect(r).contains(p)
                {
                    ui.hover.offer_tip(Some(&SQL10n::string(&tip)));
                }
                if list.contains(p)
                    && let Some((_, full)) = self.cut_tips.iter().find(|(r, _)| r.contains(p))
                {
                    ui.hover.offer_tip(Some(full));
                }
                true
            }
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                if !self.frame.contains(p) {
                    self.events.push(QueuePopoverEvent::Close);
                    return e.closing_popover_is_taken(scale, self.opener);
                }
                if !self.jobs.is_empty() {
                    if self.has_finished() && self.clear_rect().contains(p) {
                        self.clear_finished();
                        return true;
                    }
                    if self.has_active() && self.stop_rect().contains(p) {
                        let of = |running: bool| -> Vec<Id> {
                            let state = |j: &&QueueJob| {
                                if running {
                                    matches!(j.state, ExportJobState::Running)
                                } else {
                                    j.state == ExportJobState::Waiting
                                }
                            };
                            self.jobs.iter().filter(state).map(|j| j.id).collect()
                        };
                        let ev = QueuePopoverEvent::StopAll {
                            running: of(true),
                            waiting: of(false),
                            background: self.background.iter().map(|b| b.id.clone()).collect(),
                        };
                        self.events.push(ev);
                        return true;
                    }
                }
                if list.contains(p)
                    && let Some((entry, r)) = self.entry_at(p)
                    && Self::action_rect(r).inset_by(-4.0, -4.0).contains(p)
                {
                    match entry {
                        Entry::Background(i) => {
                            self.events.push(QueuePopoverEvent::CancelBackground(self.background[i].id.clone()))
                        }
                        Entry::Job(i) => {
                            let j = &self.jobs[i];
                            match &j.state {
                                ExportJobState::Waiting | ExportJobState::Running => {
                                    self.events.push(QueuePopoverEvent::Cancel(j.id))
                                }
                                ExportJobState::Done(url) => self.events.push(QueuePopoverEvent::Reveal(url.clone())),
                                _ => {}
                            }
                        }
                        Entry::Section(_) => {}
                    }
                }
                true
            }
            InputEvent::MouseDragged { .. } | InputEvent::MouseUp { .. } => true,
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                if !self.frame.contains(pt(x, y)) {
                    return true;
                }
                let max = self.max_scroll();
                self.scroll_body.wheel(Some(ui.gesture_or_wheel(dx, dy)), dx, dy, k, max, list.height, now);
                true
            }
            InputEvent::KeyDown { key, .. } => {
                if key == InputKey::Escape {
                    self.events.push(QueuePopoverEvent::Close);
                }
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::InputModifiers;

    const WINDOW: CGRect = CGRect { x: 0.0, y: 0.0, width: 1000.0, height: 700.0 };

    fn jobs() -> Vec<QueueJob> {
        vec![
            QueueJob {
                id: Id::from_u128(1),
                name: "Cut A".into(),
                state: ExportJobState::Done(PathBuf::from("/tmp/a.mp4")),
                progress: 1.0,
            },
            QueueJob { id: Id::from_u128(2), name: "Cut B".into(), state: ExportJobState::Running, progress: 0.4 },
            QueueJob { id: Id::from_u128(3), name: "Cut C".into(), state: ExportJobState::Waiting, progress: 0.0 },
        ]
    }

    fn make() -> ExportQueuePopover {
        let mut p = ExportQueuePopover::new(CGPoint::new(980.0, 690.0));
        p.update(&jobs(), None);
        p.layout(WINDOW);
        p
    }

    fn press(p: &mut ExportQueuePopover, x: f32, y: f32) -> bool {
        p.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, 1.0, &mut UiCx::new(), 0.0)
    }

    #[test]
    fn opens_above_the_ring_inside_the_window() {
        let p = make();
        assert!(p.frame().max_y() <= 690.0 && p.frame().min_x() >= 8.0 && p.frame().max_x() <= 992.0);
        assert_eq!(p.frame().width, ExportQueuePopover::WIDTH);
    }

    /// At the smallest window (640 x 400) a long queue scrolls inside the popover: its header and footer stay in the window.
    #[test]
    fn a_long_queue_stays_inside_the_smallest_window_and_scrolls() {
        let window = CGRect { x: 0.0, y: 0.0, width: 640.0, height: 400.0 };
        let many: Vec<QueueJob> = (1..=12)
            .map(|n| QueueJob {
                id: Id::from_u128(n),
                name: format!("Cut {n}"),
                state: ExportJobState::Waiting,
                progress: 0.0,
            })
            .collect();
        let mut p = ExportQueuePopover::new(CGPoint::new(620.0, 390.0));
        p.update(&many, None);
        p.layout(window);
        let f = p.frame();
        assert!(
            f.min_y() >= 8.0 - 0.01 && f.max_y() <= window.height - 8.0 + 0.01,
            "{f:?} leaves the 640 x 400 window"
        );
        assert!(f.min_x() >= 8.0 - 0.01 && f.max_x() <= window.width - 8.0 + 0.01, "{f:?} leaves the 640 x 400 window");
        assert!(p.max_scroll() > 0.0, "the rows that do not fit scroll");
    }

    #[test]
    fn clear_finished_hides_only_finished_jobs_and_stays_hidden() {
        let mut p = make();
        let all = p.jobs().to_vec();
        p.clear_finished();
        assert_eq!(p.jobs().iter().map(|j| j.name.as_str()).collect::<Vec<_>>(), ["Cut B", "Cut C"]);
        p.update(&all, None); // the queue still reports the done job
        assert_eq!(p.jobs().iter().map(|j| j.name.as_str()).collect::<Vec<_>>(), ["Cut B", "Cut C"]);
    }

    #[test]
    fn a_cancelling_job_says_stopping_and_offers_no_second_stop() {
        let p = make();
        let s = ExportJobState::Cancelling;
        assert_eq!(ExportQueuePopover::state_text(&s), "Stopping…");
        let j = QueueJob { id: Id::from_u128(9), name: "X".into(), state: s, progress: 0.4 };
        assert!(!j.is_finished());
        assert!(p.action(&j).is_none());
    }

    #[test]
    fn rows_sit_in_sections_with_the_finished_ones_last() {
        let p = make();
        assert_eq!(
            p.entries(),
            [
                Entry::Section("Exporting"),
                Entry::Job(1),
                Entry::Section("Waiting"),
                Entry::Job(2),
                Entry::Section("Finished"),
                Entry::Job(0)
            ]
        );
        let h = ExportQueuePopover::HEADER_HEIGHT;
        let list = ExportQueuePopover::SECTION_HEIGHT * 3.0
            + ExportQueuePopover::BAR_ROW_HEIGHT
            + ExportQueuePopover::ROW_HEIGHT * 2.0;
        assert_eq!(p.frame().height, h + list + ExportQueuePopover::FOOTER_HEIGHT);
    }

    #[test]
    fn the_action_buttons_cancel_and_reveal() {
        let mut p = make();
        let x = (p.frame().max_x() - 22.0) as f32;
        let top = p.frame().min_y() + ExportQueuePopover::HEADER_HEIGHT;
        let (s, r, b) =
            (ExportQueuePopover::SECTION_HEIGHT, ExportQueuePopover::ROW_HEIGHT, ExportQueuePopover::BAR_ROW_HEIGHT);
        // the running job is the first row after "Exporting", the done one the last after "Finished"
        press(&mut p, x, (top + s + b / 2.0) as f32);
        press(&mut p, x, (top + s + b + s + r + s + r / 2.0) as f32);
        assert_eq!(
            p.take_events(),
            [QueuePopoverEvent::Cancel(Id::from_u128(2)), QueuePopoverEvent::Reveal(PathBuf::from("/tmp/a.mp4"))]
        );
    }

    #[test]
    fn stop_all_names_every_running_waiting_and_background_job() {
        let mut p = make();
        let jobs = p.jobs().to_vec();
        p.update(&jobs, Some(vec![BackgroundJob { id: "proxy-1".into(), title: "Proxy".into(), progress: None }]));
        p.layout(WINDOW);
        let r = p.stop_rect();
        press(&mut p, r.mid_x() as f32, r.mid_y() as f32);
        assert_eq!(
            p.take_events(),
            [QueuePopoverEvent::StopAll {
                running: vec![Id::from_u128(2)],
                waiting: vec![Id::from_u128(3)],
                background: vec!["proxy-1".into()]
            }]
        );
    }

    #[test]
    fn a_press_outside_or_escape_closes() {
        let mut p = make();
        assert!(!press(&mut p, 5.0, 5.0), "a press elsewhere closes it and goes on to the panel under the pointer");
        p.opener = CGRect::new(970.0, 680.0, 20.0, 20.0);
        assert!(press(&mut p, 980.0, 690.0), "a press on the ring only closes it");
        assert!(p.handle(
            &InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE },
            1.0,
            &mut UiCx::new(),
            0.0
        ));
        assert_eq!(p.take_events(), [QueuePopoverEvent::Close, QueuePopoverEvent::Close, QueuePopoverEvent::Close]);
    }

    #[test]
    fn draws_a_bar_for_the_running_job() {
        let mut p = make();
        let mut c = Canvas::with_size(1000.0, 700.0, None, 1.0);
        let before = c.list.quads().len();
        p.draw(&mut c, &DrawTheme::default(), 0.0);
        assert!(c.list.quads().len() > before);
    }

    #[test]
    fn background_jobs_sit_in_their_own_section_and_cancel() {
        let mut p = make();
        let plain = p.frame().height;
        let jobs = p.jobs().to_vec();
        p.update(
            &jobs,
            Some(vec![BackgroundJob { id: "proxy-1".into(), title: "Proxy: a.mov".into(), progress: Some(0.4) }]),
        );
        p.layout(WINDOW);
        assert_eq!(p.frame().height, plain + ExportQueuePopover::SECTION_HEIGHT + ExportQueuePopover::BAR_ROW_HEIGHT);
        let x = (p.frame().max_x() - 22.0) as f32;
        let bg_row = p.frame().min_y() + p.frame().height
            - ExportQueuePopover::FOOTER_HEIGHT
            - ExportQueuePopover::BAR_ROW_HEIGHT;
        press(&mut p, x, (bg_row + ExportQueuePopover::BAR_ROW_HEIGHT / 2.0) as f32);
        assert_eq!(p.take_events(), [QueuePopoverEvent::CancelBackground("proxy-1".into())]);
    }

    #[test]
    fn a_failed_row_has_a_bar_and_names_stay_distinct() {
        let failed = ExportJobState::Failed("disk full".into());
        let mut p = make();
        let row = QueueJob {
            id: Id::from_u128(7),
            name: "Interview final export for the festival screening in the main hall v12".into(),
            state: failed,
            progress: 0.3,
        };
        p.update(&[row], None);
        assert_eq!(p.entry_height(Entry::Job(0)), ExportQueuePopover::BAR_ROW_HEIGHT);
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(1000.0, 700.0, None, 1.0);
        p.layout(WINDOW);
        p.draw(&mut c, &t, 0.0);
        // Without a font atlas nothing measures wide, so only the drawing path is run here.
        let (v1, v12) = ("Interview final export for the festival v1", "Interview final export for the festival v12");
        let fits = |t: &str| t.chars().count() <= 24;
        let (a, b) = (sq_draw::middle_fit::truncate_name(v1, fits), sq_draw::middle_fit::truncate_name(v12, fits));
        assert_ne!(a.shown, b.shown);
        assert_eq!(b.tip(), Some(v12));
    }
}
