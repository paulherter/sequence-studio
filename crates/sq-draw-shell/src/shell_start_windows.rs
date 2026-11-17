// Swift: ShellStartWindows.swift
//! The start window's lifecycle where the start screen has a window of its own (the Mac, `ShellHost.startWindowSize`),
//! translated from AppController+Start (`showStartWindow`, `closeStartWindow`, `startWindowClosedByUser`,
//! `showEditorWindow`): the start screen opens in its own window; without a real project the editor window goes away
//! meanwhile (never an empty editor), with one (Window > Start Window) the editor stays where it is. Opening or creating a
//! project hides the start window and brings the editor window up. The host applies `steps` to its two windows after each
//! frame. The `ShellHost` side (`startWindowSteps`, `startWindowClosedByUser`, `editorWindowActivated`) lives in
//! `shell_start.rs` with the start screen it reads.

/// What the windows show now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StartWindowState {
    /// The shell shows its start screen.
    pub start_shown: bool,
    /// The start window is on screen.
    pub start_visible: bool,
    /// The editor window is on screen.
    pub editor_visible: bool,
    /// A project other than the empty untitled one is open.
    pub has_real_project: bool,
}

/// One window change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartWindowStep {
    /// Show the start window.
    ShowStart,
    /// Hide the start window.
    HideStart,
    /// Show the editor window.
    ShowEditor,
    /// Hide the editor window.
    HideEditor,
}

/// The window changes that bring the windows in line with the shell.
pub struct ShellStartWindows;

impl ShellStartWindows {
    /// The window changes that bring the windows in line with the shell, in order. The start window shows before the editor
    /// hides (hiding the only visible window first quit the AppKit app).
    pub fn steps(s: StartWindowState) -> Vec<StartWindowStep> {
        if s.start_shown {
            let mut out = if s.start_visible { Vec::new() } else { vec![StartWindowStep::ShowStart] };
            if !s.has_real_project && s.editor_visible {
                out.push(StartWindowStep::HideEditor);
            }
            return out;
        }
        let mut out = Vec::new();
        if !s.editor_visible {
            out.push(StartWindowStep::ShowEditor);
        }
        if s.start_visible {
            out.push(StartWindowStep::HideStart);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::StartWindowStep::*;
    use super::*;

    fn st(start_shown: bool, start_visible: bool, editor_visible: bool, has_real_project: bool) -> StartWindowState {
        StartWindowState { start_shown, start_visible, editor_visible, has_real_project }
    }

    #[test]
    fn start_without_a_project_shows_the_start_window_then_hides_the_editor() {
        assert_eq!(ShellStartWindows::steps(st(true, false, true, false)), vec![ShowStart, HideEditor]);
        assert_eq!(ShellStartWindows::steps(st(true, true, false, false)), vec![]);
    }

    #[test]
    fn start_over_a_project_keeps_the_editor() {
        assert_eq!(ShellStartWindows::steps(st(true, false, true, true)), vec![ShowStart]);
    }

    #[test]
    fn opening_a_project_brings_the_editor_up_then_hides_the_start_window() {
        assert_eq!(ShellStartWindows::steps(st(false, true, false, true)), vec![ShowEditor, HideStart]);
        assert_eq!(ShellStartWindows::steps(st(false, false, true, true)), vec![]);
    }
}
