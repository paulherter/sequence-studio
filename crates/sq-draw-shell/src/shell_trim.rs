// Swift: ShellTrim.swift
//! Trim mode (TL-08 / TL-09) in the shared shell: the Mac `AppController.executeTrimModeCommand` and its Esc rule, written
//! once for the Mac shared window and Windows. The hosts only show it (the two-up monitor, the bar under the timeline).

use crate::shell_host::{ShellCx, ShellHost};
use sq_core_edit::playback::ShuttleKey;
use sq_core_edit::timeline_trim_mode::TrimPoint;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;

impl ShellHost {
    /// Ctrl+Shift+T toggles; while on, Left / Right (Shift: 10 frames), Ctrl+T and J / K / L trim the edit. False = not a Trim
    /// mode command (or Trim mode is off), the command goes on to the panels.
    pub(crate) fn run_trim_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        if c == C::ToggleTrimMode {
            if self.trim.is_active() {
                self.trim.exit();
                return true;
            }
            cx.session.stop_playback();
            if !self.trim.enter_nearest_playhead(cx.session) {
                self.flash("Trim mode needs an edit in the sequence.");
            }
            return true;
        }
        if !self.trim.is_active()
            || !matches!(self.focus, None | Some(PanelID::Timeline) | Some(PanelID::ProgramMonitor))
        {
            return false;
        }
        match c {
            C::StepBackward => {
                self.trim.step(cx.session, -1);
            }
            C::StepForward => {
                self.trim.step(cx.session, 1);
            }
            C::StepBackward5 => {
                self.trim.step(cx.session, -10);
            }
            C::StepForward5 => {
                self.trim.step(cx.session, 10);
            }
            C::ToggleTrimType => self.trim.cycle_side(),
            C::ShuttleForward => {
                self.trim.dynamic_trim(cx.session, ShuttleKey::L);
            }
            C::ShuttleReverse => {
                self.trim.dynamic_trim(cx.session, ShuttleKey::J);
            }
            C::ShuttleStop => {
                self.trim.dynamic_trim(cx.session, ShuttleKey::K);
            }
            C::PlayPause | C::ShuttleSlowForward | C::ShuttleSlowReverse => self.flash("Close Trim mode to play."),
            _ => return false,
        }
        true
    }

    /// Opens Trim mode at an edit (a double-click on an edge, `TimelineEditorRequest.trimMode`).
    pub fn enter_trim_mode(&mut self, cx: &mut ShellCx, p: TrimPoint, pointer_before: bool) {
        cx.session.stop_playback();
        self.trim.enter(p, None, pointer_before);
    }
}
