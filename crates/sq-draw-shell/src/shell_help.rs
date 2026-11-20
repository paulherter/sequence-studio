// Swift: ShellHelp.swift
//! The app menu's About and the Help menu rows on the canvas, translated from the Mac AppController+About / +Help /
//! +HistoryWelcome: About (name, version line, tagline, Support and GitHub), the support pages, Send Feedback (prefilled
//! mail), Reveal Logs and Reports and Check for Updates (`UpdateCheck`). Links open through [`ShellEvent::OpenUrl`].
//! The supporters list comes from the host; there is no Acknowledgments page chrome beyond the canvas body, as in Swift
//! `ShellHelp`.
//!
//! Mapping: `revealLogs` has no `SQLog` yet (the Rust logger is missing): it asks the host to reveal the log directory
//! ([`ShellHost::log_directory`], set by the app).

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use crate::shell_menu_bar::ShellAction;
use sq_core_project::support_policy::{FeedbackLinks, IssueLinks, SupportLinks};
use sq_editor_session::{UpdateCheck, UpdateOutcome};
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::app_version::AppVersion;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

impl ShellHost {
    /// The Help and About rows; false for other actions.
    pub(crate) fn perform_help(&mut self, _cx: &mut ShellCx, a: &ShellAction) -> bool {
        match a {
            ShellAction::About => self.start_flow(ShellFlow::ShowAbout),
            ShellAction::Support(e) => {
                if let Some(u) = SupportLinks::url_for(*e) {
                    self.emit(ShellEvent::OpenUrl(u.to_string()));
                }
            }
            ShellAction::SendFeedback => {
                let system = format!("{} {}", Platform::current().feedback_os_name(), self.os_version);
                let u = FeedbackLinks::mail_url(&AppVersion::display(), &AppVersion::build(), &system);
                self.emit(ShellEvent::OpenUrl(u));
            }
            ShellAction::ReportIssue => {
                let system = format!("{} {}", Platform::current().feedback_os_name(), self.os_version);
                self.emit(ShellEvent::OpenUrl(IssueLinks::new_issue_url(&AppVersion::display(), &system)));
            }
            ShellAction::RevealLogs => self.reveal_logs(),
            ShellAction::CheckForUpdates => self.start_flow(ShellFlow::CheckForUpdates),
            _ => return false,
        }
        true
    }

    /// The current app log selected in the file browser (Swift `revealLogs`); the folder when it holds no log yet.
    // The current log is the most recently written file of the folder (the Rust logger names no single file).
    pub fn reveal_logs(&mut self) {
        let Some(dir) = self.log_directory.clone() else { return };
        let newest = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
            .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
            .max()
            .map(|(_, p)| p);
        self.emit(ShellEvent::RevealFile(newest.unwrap_or(dir)));
    }

    /// Help > Check for Updates (`checkForUpdatesItem` / `presentUpdate`). The address is `ShellHost::update_feed`.
    pub async fn check_for_updates<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(feed) = h.with(|r| r.shell_parts().shell.update_feed.clone()) else { return };
        let outcome = if feed.is_empty() {
            UpdateOutcome::NotConfigured
        } else {
            let Some(ask) = h.with(|r| r.shell_parts().files.fetch(&feed)) else { return };
            let data = ask.await;
            UpdateCheck::check(&sq_editor_session::ReleaseChannel::local_version(), &feed, |_| async move { data })
                .await
        };
        let mut d = ShellDialog::new("Check for Updates", "");
        match outcome {
            UpdateOutcome::NotConfigured => {
                d.informative_text = "Update checking is not set up in this build. New versions come as a download from the person who sent you this one.".into();
            }
            UpdateOutcome::UpToDate => {
                d.slot = Some(crate::shell_dialog::SlotIcon::Ok);
                d.informative_text =
                    SQL10n::format("Sequence Studio %@ is the newest version.", &[&AppVersion::display()]);
            }
            UpdateOutcome::Failed => {
                d.header_icon = Some(crate::shell_dialog::Tone::Error);
                d.informative_text =
                    "The update information could not be read. Check your connection and try again later.".into();
            }
            UpdateOutcome::Available(r) => {
                d.message_text = SQL10n::format("Version %@ is available", &[&r.version]);
                d.informative_text = format!(
                    "{}{}",
                    r.notes.map(|n| format!("{n}\n\n")).unwrap_or_default(),
                    SQL10n::format("You have %@.", &[&AppVersion::display()])
                );
                d.add_button("Download", SQDialogRole::Default, false);
                d.add_button("Later", SQDialogRole::Normal, true);
                if Self::ask(&h, d).await == Some(SQDialogResponse::FIRST) {
                    let _ = h.with(|root| root.shell_parts().shell.emit(ShellEvent::OpenUrl(r.url)));
                }
                return;
            }
        }
        d.add_button("OK", SQDialogRole::Default, false);
        let _ = Self::ask(&h, d).await;
    }
}
