// Swift: KeyboardListing.swift
//! Rows of the read-only Keyboard tab, built from the command map.

use crate::command_catalog::CommandCatalog;
use crate::command_map::CommandMap;
use crate::command_support::CommandSupport;
use crate::editor_command::CommandScope;
use crate::key_binding::KeyBinding;
use crate::key_binding_text::KeyBindingText;
use sq_os::Platform;
use std::collections::HashSet;

/// One row of the shortcut list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub command: String,
    pub shortcut: String,
    pub scope: String,
}

/// Rows of the Keyboard tab.
pub struct KeyboardListing;

/// `String.capitalized` of an ASCII case name: first letter upper, the rest lower.
fn capitalized(s: &str) -> String {
    let mut it = s.chars();
    it.next().map_or_else(String::new, |f| f.to_uppercase().chain(it.flat_map(char::to_lowercase)).collect())
}

fn sorted_rows(mut rows: Vec<Row>) -> Vec<Row> {
    rows.sort_by(|a, b| (&a.command, &a.shortcut).cmp(&(&b.command, &b.shortcut)));
    rows
}

impl KeyboardListing {
    /// Display text of a binding in the wording of the system the app runs on: "⇧⌘Z" on the Mac, "Ctrl+Shift+Z" on
    /// Windows and Linux (the one path every popup, tooltip and list takes, like the menu bar).
    pub fn text_for(b: &KeyBinding) -> String {
        Self::text_on(b, Platform::current())
    }

    /// [`KeyboardListing::text_for`] for a given system.
    pub fn text_on(b: &KeyBinding, platform: Platform) -> String {
        KeyBindingText::text(b, platform)
    }

    pub fn rows(map: &CommandMap) -> Vec<Row> {
        sorted_rows(
            map.entries
                .iter()
                .map(|e| Row {
                    command: e.command.title().to_string(),
                    shortcut: Self::text_for(&e.binding),
                    scope: capitalized(&format!("{:?}", e.scope)),
                })
                .collect(),
        )
    }

    /// Human name of the scope a binding is active in.
    pub fn scope_name(s: CommandScope) -> &'static str {
        match s {
            CommandScope::Global => "Everywhere",
            CommandScope::Timeline => "Timeline",
            CommandScope::Program => "Program",
            CommandScope::Source => "Source",
            CommandScope::Project => "Project",
            CommandScope::EffectControls => "Controls",
        }
    }

    /// Rows of the Keyboard Shortcuts window: every binding, then every wired command that has no key (menu only),
    /// sorted by command name, scopes in plain words.
    pub fn window_rows(map: &CommandMap) -> Vec<Row> {
        // A chord this system cannot press as that command (a Control binding whose Ctrl twin is bound, on Windows and
        // Linux) is no key of it: the command is listed as menu only.
        let pressable: Vec<_> = map.entries.iter().filter(|e| map.is_pressable_on(e, Platform::current())).collect();
        let keyed: HashSet<_> = pressable.iter().map(|e| e.command).collect();
        let mut rows: Vec<Row> = pressable
            .iter()
            .map(|e| Row {
                command: e.command.title().to_string(),
                shortcut: Self::text_for(&e.binding),
                scope: Self::scope_name(e.scope).to_string(),
            })
            .collect();
        rows.extend(
            CommandCatalog::audited(map)
                .into_iter()
                .filter(|c| !keyed.contains(c) && CommandSupport::is_supported(c))
                .map(|c| Row {
                    command: c.title().to_string(),
                    shortcut: String::new(),
                    scope: "Menu only".to_string(),
                }),
        );
        sorted_rows(rows)
    }

    /// Case-insensitive search over command, scope and shortcut; modifier symbols also match their names
    /// ("cmd shift z" finds ⇧⌘Z). Every word of the query must match.
    pub fn filter(rows: &[Row], query: &str) -> Vec<Row> {
        let q = query.to_lowercase();
        let words: Vec<&str> = q.split(char::is_whitespace).filter(|w| !w.is_empty()).collect();
        if words.is_empty() {
            return rows.to_vec();
        }
        rows.iter()
            .filter(|r| {
                let keys = r
                    .shortcut
                    .replace('⌃', " control ")
                    .replace('⌥', " option alt ")
                    .replace('⇧', " shift ")
                    .replace('⌘', " command cmd ")
                    .replace('←', " left ")
                    .replace('→', " right ")
                    .replace('↑', " up ")
                    .replace('↓', " down ")
                    .replace('⌫', " delete backspace ")
                    // The words of Windows and Linux: Ctrl stands for the Command key of the one key map.
                    .replace("Ctrl", " ctrl command cmd ");
                let hay = format!("{} {} {} {}", r.command, r.scope, r.shortcut, keys).to_lowercase();
                words.iter().all(|w| hay.contains(w))
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::key_binding::{Key, KeyModifiers};

    fn row(c: &str, s: &str, scope: &str) -> Row {
        Row { command: c.to_string(), shortcut: s.to_string(), scope: scope.to_string() }
    }

    #[test]
    fn filter_matches_modifier_names_and_needs_every_word() {
        let rows =
            vec![row("Undo", "⌘Z", "Everywhere"), row("Redo", "⇧⌘Z", "Everywhere"), row("Blade", "B", "Timeline")];
        assert_eq!(KeyboardListing::filter(&rows, "cmd shift z"), vec![rows[1].clone()]);
        assert_eq!(KeyboardListing::filter(&rows, "COMMAND z").len(), 2);
        assert_eq!(KeyboardListing::filter(&rows, "timeline blade"), vec![rows[2].clone()]);
        assert_eq!(KeyboardListing::filter(&rows, "  ").len(), 3);
    }

    #[test]
    fn a_binding_reads_in_the_words_of_each_system() {
        let b = KeyBinding::new(Key::Char('v'), KeyModifiers::CONTROL | KeyModifiers::OPTION);
        assert_eq!(KeyboardListing::text_on(&b, Platform::Mac), "⌃⌥V");
        assert_eq!(KeyboardListing::text_on(&b, Platform::Linux), "Ctrl+Alt+V");
        assert_eq!(KeyboardListing::text_on(&b, Platform::Windows), "Ctrl+Alt+V");
        assert_eq!(KeyboardListing::text_for(&b), KeyboardListing::text_on(&b, Platform::current()));
    }

    #[test]
    fn scope_names_and_capitalized_case_names() {
        assert_eq!(KeyboardListing::scope_name(CommandScope::EffectControls), "Controls");
        assert_eq!(capitalized("EffectControls"), "Effectcontrols");
    }
}
