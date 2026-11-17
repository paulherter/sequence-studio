// Swift: ShellAnalysis.swift
//! The analysis commands (Find Scene Changes, Stabilize, Auto Reframe) on the shared shell: the session side is
//! `AnalysisFlows` (also used by the AppKit window); the platform sets the analysis backend and the job line.
//!
//! Mapping: the `AnalysisFlows` object and its worker launcher come from [`crate::ShellServices::analysis`]; what its UI
//! closures did (`setJob`, `flash`) is [`AnalysisFlowsEvent`], forwarded by [`ShellHost::forward_analysis_events`].

use crate::shell_dialog::ShellDialog;
use crate::shell_flow_env::ShellTool;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use crate::shell_menu_bar::ShellMenuState;
use sq_editor_session::{AnalysisFlows, AnalysisFlowsEvent, EditorSession};
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

impl ShellHost {
    /// Runs one of the analysis commands; false for any other.
    pub(crate) fn run_analysis_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        match c {
            C::FindSceneChanges => match self.flow_env.services.analysis() {
                Some((a, launcher)) => a.request_find_scene_changes(cx.session, launcher),
                None => self.flash(&AnalysisFlows::unavailable("Find Scene Changes")),
            },
            C::Stabilize => match self.flow_env.services.analysis() {
                Some((a, launcher)) => a.request_stabilize(cx.session, launcher),
                None => self.flash(&AnalysisFlows::unavailable("Stabilize")),
            },
            C::AutoReframe => {
                let Some((a, _)) = self.flow_env.services.analysis() else {
                    self.flash(&AnalysisFlows::unavailable("Auto Reframe"));
                    return true;
                };
                let what = a.reframe_subject(cx.session);
                self.forward_analysis_events();
                if let Some(what) = what {
                    self.start_flow(ShellFlow::Tool(ShellTool::AutoReframe { what }));
                }
                return true;
            }
            C::MatchColorToClip => {
                let Some((a, _)) = self.flow_env.services.analysis() else {
                    self.flash(&AnalysisFlows::unavailable("Match Color to Clip"));
                    return true;
                };
                if let Some(run) = a.request_color_match_to_clip(cx.session) {
                    self.flow_env.services.color_match_started(run);
                }
            }
            C::NextWeakTracking => self.go_to_next_weak_tracking(cx),
            C::QuickApply => self.toggle_quick_apply(cx),
            _ => return false,
        }
        self.forward_analysis_events();
        true
    }

    /// Menu rule of the analysis commands (`None` = not one of them): a running job keeps its command enabled to cancel it.
    pub(crate) fn analysis_enabled(&self, session: &EditorSession, c: EditorCommand) -> Option<bool> {
        use EditorCommand as C;
        let flows = self.flow_env.services.analysis_flows();
        match c {
            C::FindSceneChanges => Some(
                flows.is_some_and(AnalysisFlows::is_finding_scene_changes)
                    || !session.scene_change_targets().is_empty(),
            ),
            C::Stabilize => {
                Some(flows.is_some_and(AnalysisFlows::is_stabilizing) || !session.stabilize_targets().is_empty())
            }
            C::AutoReframe => {
                Some(flows.is_some_and(AnalysisFlows::is_reframing) || !session.reframe_targets().is_empty())
            }
            C::MatchColorToClip => Some(session.has_color_match_target()),
            _ => None,
        }
    }

    /// Titles of the analysis commands while their job runs.
    pub(crate) fn analysis_titles(&self, s: &mut ShellMenuState) {
        let Some(flows) = self.flow_env.services.analysis_flows() else { return };
        if flows.is_finding_scene_changes() {
            s.titles.insert(EditorCommand::FindSceneChanges, "Cancel Find Scene Changes".to_string());
        }
        if flows.is_stabilizing() {
            s.titles.insert(EditorCommand::Stabilize, "Cancel Stabilize".to_string());
        }
        if flows.is_reframing() {
            s.titles.insert(EditorCommand::AutoReframe, "Cancel Auto Reframe".to_string());
        }
    }

    /// What `AnalysisFlows`' UI closures did: the job line and the flashes. The app calls this after it routed a worker
    /// message to `AnalysisFlows::handle_message`.
    pub fn forward_analysis_events(&mut self) {
        let Some((flows, _)) = self.flow_env.services.analysis() else { return };
        for e in flows.take_events() {
            match e {
                AnalysisFlowsEvent::SetJob(line) => self.emit(ShellEvent::Job(line)),
                AnalysisFlowsEvent::Flash { message, .. } => self.emit(ShellEvent::Status(message)),
                AnalysisFlowsEvent::StabilizeProgress { .. } => {}
            }
        }
    }

    /// One pump of the analysis: the services route the workers' messages, then the job line and flashes go out.
    pub fn pump_analysis(&mut self, session: &mut EditorSession) {
        self.flow_env.services.pump(session);
        self.forward_analysis_events();
        self.forward_anonymize_events();
    }

    /// The Auto Reframe sheet (the AppKit `ReframeOptionsDialog`): Motion and Framing, the last pick remembered. `None` on
    /// Cancel.
    pub async fn ask_reframe<R: ShellRoot + ?Sized>(h: UiRef<R>, subject: &str) -> Option<(i64, i64)> {
        let start = h.with(|r| AnalysisFlows::remembered_reframe_pick(&*r.shell_parts().shell.flow_env.settings))?;
        let mut d = ShellDialog::new(
            "Auto Reframe",
            &format!("{subject}\nKeeps the subject in the frame with Position keys you can edit in Effect Controls."),
        );
        let form = ShellForm::new(vec![
            Row::segmented("motion", "Motion", &AnalysisFlows::reframe_motion_titles(), start.0 as i64, 0.0),
            Row::segmented("framing", "Framing", &AnalysisFlows::reframe_framing_titles(), start.1 as i64, 0.0),
            Row::Text(
                "Quick follows every move. Smooth holds the frame calmer but can trail a fast subject. Closer and Tight zoom in on the subject."
                    .to_string(),
            ),
        ]);
        d.form = Some(Box::new(form));
        d.add_button("Reframe", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return None;
        }
        let f = h.with(|r| r.shell_parts().shell.take_answered_form()).flatten()?;
        Some((f.index("motion").unwrap_or(start.0 as i64), f.index("framing").unwrap_or(start.1 as i64)))
    }

    /// The Auto Reframe flow: the sheet, then the analysis.
    pub(crate) async fn run_auto_reframe<R: ShellRoot + ?Sized>(h: UiRef<R>, what: String) {
        let Some((motion, framing)) = Self::ask_reframe(h.clone(), &what).await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let env = &mut p.shell.flow_env;
            let options = AnalysisFlows::reframe_options(motion, framing, &mut *env.settings);
            if let Some((a, launcher)) = env.services.analysis() {
                a.run_auto_reframe(p.session, launcher, options, &what);
            }
            p.shell.forward_analysis_events();
        });
    }
}
