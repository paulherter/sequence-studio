// Swift: PanelCycle.swift
//! Select Next / Previous Panel: wraps around the visible panels in layout order.

use crate::panel_id::PanelID;

/// The panel after (or before) `current` in `panels`, wrapping around. No current panel, or one that is not listed,
/// starts at the first (or last) panel; no panels give `None`.
pub fn step(current: Option<PanelID>, panels: &[PanelID], forward: bool) -> Option<PanelID> {
    if panels.is_empty() {
        return None;
    }
    let Some(i) = current.and_then(|c| panels.iter().position(|p| *p == c)) else {
        return if forward { panels.first().copied() } else { panels.last().copied() };
    };
    let n = panels.len();
    Some(panels[(i + if forward { 1 } else { n - 1 }) % n])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command_map::CommandMap;
    use crate::command_support::CommandSupport;
    use crate::editor_command::EditorCommand;

    #[test]
    fn steps_and_wraps() {
        let p = [PanelID::Project, PanelID::Timeline, PanelID::ProgramMonitor];
        assert_eq!(step(Some(PanelID::Project), &p, true), Some(PanelID::Timeline));
        assert_eq!(step(Some(PanelID::ProgramMonitor), &p, true), Some(PanelID::Project));
        assert_eq!(step(Some(PanelID::Project), &p, false), Some(PanelID::ProgramMonitor));
    }

    #[test]
    fn unknown_or_no_focus_starts_at_the_ends() {
        let p = [PanelID::Project, PanelID::Timeline];
        assert_eq!(step(None, &p, true), Some(PanelID::Project));
        assert_eq!(step(Some(PanelID::Scopes), &p, false), Some(PanelID::Timeline));
        assert_eq!(step(Some(PanelID::Project), &[], true), None);
    }

    #[test]
    fn default_keys_are_bound_and_supported() {
        assert!(
            CommandSupport::is_shell_command(&EditorCommand::SelectNextPanel)
                && CommandSupport::is_shell_command(&EditorCommand::SelectPreviousPanel)
        );
        assert!(CommandMap::current().binding_for(&EditorCommand::SelectNextPanel).is_some());
    }
}
