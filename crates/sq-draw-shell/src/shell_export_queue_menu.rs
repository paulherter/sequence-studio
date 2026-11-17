// Swift: ShellExportQueueMenu.swift
//! The status bar's export ring opens the queue (the Mac `ExportQueueView` popover, as an SQ menu): a header, then per
//! job its name and state; a waiting or running job offers Cancel, a finished one its file in Finder/Explorer.
//! `show_export_queue` opens `ExportQueuePopover` (live bars); the menu rows stay for `export_queue_items` tests.

use crate::shell_dialog::ShellDialog;
use crate::shell_export::ShellExport;
use crate::shell_export_queue_popover::{ExportQueuePopover, QueueJob, QueuePopoverEvent};
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_core_time::Id;
use sq_draw::{InputEvent, TextMeasure, UiCx};
use sq_export::core::queue::ExportJobState;
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

/// One queue job as the menu shows it.
pub type ExportQueueJob = (Id, String, ExportJobState, f64);

impl ShellHost {
    /// The queue rows for `statuses` (pure, tested). A picked row queues a [`ShellFlow`] or an event through `sink`.
    pub fn export_queue_items(&self, statuses: &[ExportQueueJob]) -> Vec<SQMenuItem> {
        let mut rows = vec![SQMenuItem::header("Export Queue")];
        if statuses.is_empty() {
            rows.push(SQMenuItem::caption("No exports yet"));
            return rows;
        }
        let flows: Rc<RefCell<Vec<ShellFlow>>> = Rc::clone(&self.menu_flows);
        let events = self.event_sink();
        for (id, name, state, progress) in statuses {
            let text = match state {
                ExportJobState::Waiting => "Waiting".to_string(),
                ExportJobState::Running => format!("{} %", (progress * 100.0).round() as i64),
                ExportJobState::Done(_) => "Done".to_string(),
                ExportJobState::Failed(why) => format!("Failed: {why}"),
                ExportJobState::Cancelling => "Stopping…".to_string(),
                ExportJobState::Cancelled => "Canceled".to_string(),
            };
            let mut sub: Vec<SQMenuItem> = Vec::new();
            match state {
                ExportJobState::Waiting | ExportJobState::Running => {
                    let (flows, id) = (Rc::clone(&flows), *id);
                    let mut cancel = SQMenuItem::new("Cancel");
                    cancel.action = Some(Rc::new(move || flows.borrow_mut().push(ShellFlow::StopExport(id))));
                    sub.push(cancel);
                }
                ExportJobState::Done(url) => {
                    let (events, url) = (Rc::clone(&events), url.clone());
                    let mut reveal = SQMenuItem::new(Platform::current().reveal_title());
                    reveal.action =
                        Some(Rc::new(move || events.borrow_mut().push(ShellEvent::RevealFile(url.clone()))));
                    sub.push(reveal);
                }
                _ => {}
            }
            let mut row = SQMenuItem::new(&format!("{name} — {text}"));
            row.is_enabled = !sub.is_empty();
            if !sub.is_empty() {
                row.submenu = Some(sub);
            }
            rows.push(row);
        }
        rows
    }

    /// Opens the queue popover above `p` (window points) out of the status bar's `ring`; it refreshes while open. A second
    /// click on the ring closes it (the popover takes that press), a press elsewhere closes it and acts.
    pub fn show_export_queue(&mut self, p: CGPoint, ring: CGRect) {
        if self.export.popover.is_some() {
            self.export.popover = None;
            return;
        }
        let mut pop = ExportQueuePopover::new(p);
        pop.opener = ring;
        pop.reveal_title = Platform::current().reveal_title().to_string();
        pop.can_reveal = true;
        self.menu_bar.dismiss();
        self.export.popover = Some(pop);
        self.export.popover_refreshed = f64::MIN;
        self.refresh_export_queue();
    }

    /// Pulls the queue's statuses and the background jobs into the open popover (every 250 ms while it is open).
    pub(crate) fn refresh_export_queue(&mut self) {
        let now = self.now_seconds();
        if self.export.popover.as_ref().is_none_or(|p| p.pinned) || now - self.export.popover_refreshed < 0.25 {
            return;
        }
        self.export.popover_refreshed = now;
        let jobs: Option<Vec<QueueJob>> = self.export.queue.as_ref().map(|q| {
            q.all_statuses()
                .into_iter()
                .map(|s| QueueJob { id: s.id, name: s.name, state: s.state, progress: s.progress })
                .collect()
        });
        let bg = self.export.background_jobs.clone();
        let window = CGRect::new(0.0, 0.0, self.size().width, self.size().height);
        if let Some(pop) = self.export.popover.as_mut() {
            let current = jobs.unwrap_or_else(|| pop.jobs().to_vec());
            pop.update(&current, Some(bg));
            pop.layout(window);
        }
    }

    /// One event for the open popover (before the menu bar, while no menu is open); true when it took the event.
    pub(crate) fn handle_export_popover(
        &mut self,
        e: &InputEvent,
        scale: f32,
        ui: &mut UiCx,
        _m: &TextMeasure,
    ) -> bool {
        if self.menu_bar.controller.is_open() {
            return false;
        }
        let now = self.now_seconds();
        let Some(pop) = self.export.popover.as_mut() else { return false };
        let took = pop.handle(e, scale, ui, now);
        for ev in pop.take_events() {
            match ev {
                QueuePopoverEvent::Close => self.export.popover = None,
                QueuePopoverEvent::Reveal(url) => self.emit(ShellEvent::RevealFile(url)),
                QueuePopoverEvent::CancelBackground(id) => self.emit(ShellEvent::CancelBackgroundJob(id)),
                QueuePopoverEvent::StopAll { running, waiting, background } => {
                    for id in background {
                        self.emit(ShellEvent::CancelBackgroundJob(id));
                    }
                    if let Some(q) = self.export.queue.clone() {
                        for id in waiting {
                            q.cancel(id);
                            self.note_export_canceled(id);
                        }
                        // a running export asks first; one at a time
                        if let Some(id) = running.into_iter().next() {
                            self.start_flow(ShellFlow::StopExport(id));
                        }
                    }
                }
                QueuePopoverEvent::Cancel(id) => {
                    if self.export.queue.is_some() {
                        self.start_flow(ShellFlow::StopExport(id));
                    }
                }
            }
            if self.export.popover.is_none() {
                break;
            }
        }
        took
    }

    /// Cancel on a job. A running one asks first (the Mac progress window's inline "Stop the export? The partial file is
    /// deleted." with Keep Exporting / Stop Export); a waiting one has no file yet and is dropped at once. True when the job
    /// was canceled.
    pub async fn stop_export<R: ShellRoot + ?Sized>(h: UiRef<R>, id: Id) -> bool {
        let Some(Some(running)) = h.with(|r| {
            let q = r.shell_parts().shell.export.queue.clone()?;
            Some(q.status(id).is_some_and(|s| s.state == ExportJobState::Running))
        }) else {
            return false;
        };
        if running {
            let mut d =
                ShellDialog::new(&SQL10n::string("Stop the export?"), &SQL10n::string("The partial file is deleted."));
            d.add_button(&SQL10n::string("Keep Exporting"), SQDialogRole::Cancel, false);
            d.add_button(&SQL10n::string("Stop Export"), SQDialogRole::Destructive, false);
            if Self::ask(&h, d).await != Some(SQDialogResponse::SECOND) {
                return false;
            }
        }
        h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            if let Some(q) = shell.export.queue.clone() {
                q.cancel(id);
                shell.note_export_canceled(id);
            }
        })
        .is_some()
    }

    /// Replaces the status bar's "Exporting 48%" at once when a job is canceled (the follower polls only every 250 ms).
    pub(crate) fn note_export_canceled(&mut self, id: Id) {
        let name = self.export.queue.as_ref().and_then(|q| q.status(id)).map(|s| s.name);
        if let Some(name) = name {
            self.emit(ShellEvent::Status(ShellExport::status_line_of(&name, &ExportJobState::Cancelled, 0.0)));
        }
    }

    /// The jobs the open queue popover lists (none when it is closed).
    pub fn export_queue_popover_jobs(&self) -> Vec<(Id, ExportJobState)> {
        self.export
            .popover
            .as_ref()
            .map(|p| p.jobs().iter().map(|j| (j.id, j.state.clone())).collect())
            .unwrap_or_default()
    }

    /// The export queue's popover frame, for hosts that anchor other things to it.
    pub fn export_queue_popover_frame(&self) -> Option<CGRect> {
        self.export.popover.as_ref().map(ExportQueuePopover::frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Rig;
    use std::path::PathBuf;

    #[test]
    fn the_ring_menu_lists_each_job_with_its_state_and_action() {
        let rig = Rig::new();
        let out = PathBuf::from("/tmp/a.mp4");
        let titles = |rows: &[SQMenuItem]| rows.iter().map(|r| r.title.clone()).collect::<Vec<_>>();
        assert_eq!(titles(&rig.with(|r| r.shell.export_queue_items(&[]))), ["Export Queue", "No exports yet"]);
        let jobs: Vec<ExportQueueJob> = vec![
            (Id::from_u128(1), "Cut A".into(), ExportJobState::Running, 0.424),
            (Id::from_u128(2), "Cut B".into(), ExportJobState::Done(out.clone()), 1.0),
            (Id::from_u128(3), "Cut C".into(), ExportJobState::Cancelled, 0.0),
        ];
        let rows = rig.with(|r| r.shell.export_queue_items(&jobs));
        assert_eq!(titles(&rows), ["Export Queue", "Cut A — 42 %", "Cut B — Done", "Cut C — Canceled"]);
        assert_eq!(rows[1].submenu.as_ref().map(|s| titles(s)), Some(vec!["Cancel".to_string()]));
        assert!(rows[3].submenu.is_none() && !rows[3].is_enabled);
        let show = rows[2].submenu.as_ref().and_then(|s| s.first()).expect("reveal row");
        (show.action.as_ref().expect("action"))();
        assert!(rig.with(|r| r.shell.take_events()).contains(&ShellEvent::RevealFile(out)));
    }
}
