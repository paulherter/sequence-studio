//! Port of `SQUIKit/Sources/SQUIKit/Tooltip.swift`.

use crate::command_map::CommandMap;
use crate::editor_command::EditorCommand;
use crate::key_binding::KeyBinding;
use crate::keyboard_listing::KeyboardListing;

/// Tooltip text convention (INTERACTION-AUDIT section 9): the control's name plus its key, "Name (Key)"; just the name when it
/// has no key. Never a sentence: explanations belong in DESIGN.md or the status line, so a trailing period is dropped.
/// Keys come from the live `CommandMap`, so a rebinding never leaves a stale tooltip.
pub struct Tooltip;

impl Tooltip {
    /// "Mark In (I)"; "Snap" when `shortcut` is nil or empty.
    pub fn text(name: &str, shortcut: Option<&str>) -> String {
        let mut n = name.trim().to_string();
        if n.ends_with('.') && !n.ends_with("..") {
            n.pop();
        }
        match shortcut.map(|s| s.trim_matches(|c| c == ' ' || c == '\t')) {
            Some(k) if !k.is_empty() => format!("{n} ({k})"),
            _ => n,
        }
    }

    /// Name plus the binding's display text ("⇧⌘Z").
    pub fn text_binding(name: &str, binding: Option<&KeyBinding>) -> String {
        let shortcut = binding.map(KeyboardListing::text_for);
        Self::text(name, shortcut.as_deref())
    }

    /// Name plus the command's current key.
    pub fn text_command(name: &str, command: EditorCommand, map: &CommandMap) -> String {
        Self::text_binding(name, map.shown_binding_here(&command).as_ref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_and_key() {
        assert_eq!(Tooltip::text("Mark In", Some("I")), "Mark In (I)");
        assert_eq!(Tooltip::text("Snap", None), "Snap");
        assert_eq!(Tooltip::text("Snap", Some("  ")), "Snap");
    }

    #[test]
    fn trailing_period_is_dropped_but_not_an_ellipsis() {
        assert_eq!(Tooltip::text("Mark In.", Some("I")), "Mark In (I)");
        assert_eq!(Tooltip::text("Export..", None), "Export..");
    }
}
