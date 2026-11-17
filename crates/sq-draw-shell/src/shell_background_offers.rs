// Swift: ShellBackgroundOffers.swift
//! The background relink offer for the status bar chip (the Mac `offerRelinkIfNeeded`): found files for offline media,
//! applied on a click as one undo step. Also the export queue ring's fill.

use crate::shell_flow_env::ShellTool;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_core_time::Id;
use sq_editor_session::EditorSession;
use sq_export::core::queue::ExportJobState;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

/// The settings key of the folders Reconnect Media searched before (`ShellHost.relinkFoldersKey`).
pub(crate) const RELINK_FOLDERS_KEY: &str = "sq.relink.folders";

/// A found-files plan for the offline media, shown as a chip until it is accepted or the project changes.
#[derive(Clone, Debug, PartialEq)]
pub struct ShellRelinkOffer {
    /// "Found 4 offline files · Reconnect".
    pub text: String,
    pub(crate) plan: BTreeMap<Id, String>,
    pub(crate) project_id: Id,
}

impl ShellRelinkOffer {
    /// The Mac chip text for `found` of `total` offline files.
    pub fn text(found: usize, total: usize) -> String {
        if found == total {
            SQL10n::format("Found %@ offline files · Reconnect", &[&total.to_string()])
        } else {
            SQL10n::format("Found %@ of %@ offline files · Reconnect", &[&found.to_string(), &total.to_string()])
        }
    }
}

fn reconnected(n: i64) -> String {
    SQL10n::plural(n, "Reconnected %@ media file.", "Reconnected %@ media files.")
}

impl ShellHost {
    /// Never modal: first links the offline files beside the project file quietly (a copied project, `relinkNearProject`),
    /// then looks in their old folders and the folders Reconnect Media searched before and shows the chip; nothing when
    /// nothing is found (File > Reconnect Media… still works).
    pub fn offer_relink_if_needed(&mut self) {
        self.flow_env.relink_offer = None;
        self.start_flow(ShellFlow::Tool(ShellTool::OfferRelink));
    }

    /// The flow behind [`ShellHost::offer_relink_if_needed`].
    pub(crate) async fn run_offer_relink<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((folder, extra, project_id, pool))) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.missing_media().is_empty() {
                return None;
            }
            let folder = p.session.file_url().and_then(|u| u.parent()).map(|f| f.to_path_buf());
            let extra: Vec<PathBuf> = p.shell.setting_list(RELINK_FOLDERS_KEY).into_iter().map(PathBuf::from).collect();
            // A copied project (Mac project on Windows, moved folder): media beside the project file links quietly first.
            Some((folder, extra, p.session.project().id, p.shell.flow_env.services.worker_pool()))
        }) else {
            return;
        };
        // No pool (a headless host): nothing is searched.
        let Some(pool) = pool else { return };
        let near = EditorSession::relink_near_project(h.clone(), Arc::clone(&pool)).await;
        let Some(Some(total)) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.project().id != project_id {
                return None;
            }
            if near > 0 {
                p.shell.emit(ShellEvent::Status(reconnected(near as i64)));
                p.shell.emit(ShellEvent::ProjectChanged);
            }
            let total = p.session.missing_media().len();
            (total > 0).then_some(total)
        }) else {
            return;
        };
        let plan = EditorSession::relink_offer(h.clone(), pool, folder, extra, None).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            if plan.is_empty() || p.session.project().id != project_id {
                return;
            }
            p.shell.flow_env.relink_offer =
                Some(ShellRelinkOffer { text: ShellRelinkOffer::text(plan.len(), total), plan, project_id });
        });
    }

    /// The chip's click: reconnects what is still offline (one undo step) and says how many.
    pub fn accept_relink_offer(&mut self, session: &mut sq_editor_session::EditorSession) {
        let Some(offer) = self.flow_env.relink_offer.take() else { return };
        if offer.project_id != session.project().id {
            return;
        }
        let n = session.apply_relink_offer(&offer.plan);
        if n > 0 {
            self.emit(ShellEvent::Status(reconnected(n as i64)));
        }
    }

    /// The ring's fill for the jobs of one Export: finished jobs count whole; `None` once none waits or runs.
    pub fn overall_progress(all: &[(ExportJobState, f64)]) -> Option<f64> {
        let open = all.iter().any(|(s, _)| s.is_active());
        if !open || all.is_empty() {
            return None;
        }
        let sum: f64 = all
            .iter()
            .map(|(s, progress)| match s {
                ExportJobState::Waiting => 0.0,
                ExportJobState::Running | ExportJobState::Cancelling => progress.clamp(0.0, 1.0),
                ExportJobState::Done(_) | ExportJobState::Failed(_) | ExportJobState::Cancelled => 1.0,
            })
            .sum();
        Some(sum / all.len() as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chip_text_counts_found_and_total() {
        assert_eq!(ShellRelinkOffer::text(4, 4), "Found 4 offline files · Reconnect");
        assert_eq!(ShellRelinkOffer::text(2, 5), "Found 2 of 5 offline files · Reconnect");
    }

    #[test]
    fn ring_fill_counts_finished_jobs_whole() {
        use ExportJobState::*;
        let all = [(Done(PathBuf::from("a")), 1.0), (Running, 0.5), (Waiting, 0.9), (Failed("x".into()), 0.0)];
        assert_eq!(ShellHost::overall_progress(&all), Some((1.0 + 0.5 + 0.0 + 1.0) / 4.0));
        assert_eq!(ShellHost::overall_progress(&[(Cancelled, 0.0)]), None);
        assert_eq!(ShellHost::overall_progress(&[]), None);
    }
}
