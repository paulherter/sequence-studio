// Swift: ShortcutTips.swift
//! Tooltip text that carries the command's shortcut, taken from the key map so it can never go stale.

use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding_text::KeyBindingText;

/// Swift `KeyboardListing.tip` (the portable branch): "Mark In (I)"; the bare title when the command has no key.
pub fn keyboard_tip(title: &str, command: EditorCommand, map: &CommandMap) -> String {
    match map.shown_binding_here(&command) {
        Some(b) => format!("{} ({})", title, KeyBindingText::text(&b, Platform::current())),
        None => title.to_string(),
    }
}

/// Swift `extension MonitorAction`.
pub trait MonitorActionTips {
    /// The command a monitor button runs (`None` for the ones without a command: Safe Margins).
    fn command(self) -> Option<EditorCommand>;
    /// Tooltip of the transport button: title plus key.
    fn tip(self, title: &str, map: &CommandMap) -> String;
    /// The footer button's name (Play reads Pause while playing).
    fn button_title(self, playing: bool) -> Option<&'static str>;
}

impl MonitorActionTips for MonitorAction {
    fn command(self) -> Option<EditorCommand> {
        use MonitorAction as A;
        Some(match self {
            A::MarkIn => EditorCommand::MarkIn,
            A::MarkOut => EditorCommand::MarkOut,
            A::GoToIn => EditorCommand::GoToIn,
            A::GoToOut => EditorCommand::GoToOut,
            A::StepBack => EditorCommand::StepBackward,
            A::StepForward => EditorCommand::StepForward,
            A::PlayPause => EditorCommand::PlayPause,
            A::AddMarker => EditorCommand::AddMarker,
            A::Insert => EditorCommand::Insert,
            A::Overwrite => EditorCommand::Overwrite,
            A::Lift => EditorCommand::Lift,
            A::Extract => EditorCommand::Extract,
            A::ExportFrame => EditorCommand::ExportFrame,
            A::Loop => EditorCommand::ToggleLoop,
            A::PlayInToOut => EditorCommand::PlayInToOut,
            A::ClearIn => EditorCommand::ClearIn,
            A::ClearOut => EditorCommand::ClearOut,
            A::ClearInOut => EditorCommand::ClearInOut,
            A::ToggleSafeMargins | A::Replace | A::FitToFill => return None,
        })
    }

    fn tip(self, title: &str, map: &CommandMap) -> String {
        match self.command() {
            Some(c) => keyboard_tip(title, c, map),
            None => title.to_string(),
        }
    }

    fn button_title(self, playing: bool) -> Option<&'static str> {
        use MonitorAction as A;
        match self {
            A::MarkIn => Some("Mark In"),
            A::MarkOut => Some("Mark Out"),
            A::GoToIn => Some("Go to In"),
            A::GoToOut => Some("Go to Out"),
            A::StepBack => Some("Step Back"),
            A::StepForward => Some("Step Forward"),
            A::PlayPause => Some(if playing { "Pause" } else { "Play" }),
            A::AddMarker => Some("Add Marker"),
            A::Insert => Some("Insert"),
            A::Overwrite => Some("Overwrite"),
            A::Lift => Some("Clear Range"),
            A::Extract => Some("Delete Range"),
            A::ExportFrame => Some("Export Frame"),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_and_tips_follow_the_key_map() {
        assert_eq!(MonitorAction::PlayPause.button_title(true), Some("Pause"));
        assert_eq!(MonitorAction::PlayPause.button_title(false), Some("Play"));
        assert_eq!(MonitorAction::Loop.button_title(false), None);
        let map = CommandMap::premiere_default();
        assert!(MonitorAction::PlayPause.tip("Play", &map).starts_with("Play"));
        assert_eq!(MonitorAction::ToggleSafeMargins.tip("Safe Margins", &map), "Safe Margins");
        assert_eq!(MonitorAction::ToggleSafeMargins.command(), None);
    }
}
