// Swift: GraphEditorShortcuts.swift
//! Keyboard commands of the Graph Editor.

use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_draw::{InputKey, InputModifiers};

/// Keyboard commands of the Graph Editor: F fits every drawn key, Shift-F the selection, Cmd-A selects every drawn key,
/// F9 / Shift-F9 / Cmd-Shift-F9 apply Smooth / Smooth in / Smooth out to the selected keys (one undo step each).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphEditorShortcut {
    FitAll,
    FitSelection,
    SelectAll,
    Ease(KeyInterpolationChoice),
}

impl GraphEditorShortcut {
    /// The same keys on the shared toolkit (Ctrl on Windows arrives as `.command`).
    pub fn resolve(k: InputKey, modifiers: InputModifiers) -> Option<GraphEditorShortcut> {
        let command = modifiers.contains(InputModifiers::COMMAND);
        let shift = modifiers.contains(InputModifiers::SHIFT);
        let option = modifiers.contains(InputModifiers::OPTION);
        if k == InputKey::Function(9) {
            return match (command, shift, option) {
                (false, false, false) => Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EasyEase)),
                (false, true, false) => Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EaseIn)),
                (true, true, false) => Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EaseOut)),
                _ => None,
            };
        }
        let InputKey::Character(ch) = k else { return None };
        let lower: String = ch.to_lowercase().collect();
        match (lower.as_str(), command, shift, option) {
            ("f", false, false, false) => Some(GraphEditorShortcut::FitAll),
            ("f", false, true, false) => Some(GraphEditorShortcut::FitSelection),
            ("a", true, false, false) => Some(GraphEditorShortcut::SelectAll),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn f_keys_fit_and_command_a_selects() {
        let none = InputModifiers::NONE;
        assert_eq!(GraphEditorShortcut::resolve(InputKey::Character('f'), none), Some(GraphEditorShortcut::FitAll));
        assert_eq!(
            GraphEditorShortcut::resolve(InputKey::Character('F'), InputModifiers::SHIFT),
            Some(GraphEditorShortcut::FitSelection)
        );
        assert_eq!(
            GraphEditorShortcut::resolve(InputKey::Character('a'), InputModifiers::COMMAND),
            Some(GraphEditorShortcut::SelectAll)
        );
        assert_eq!(GraphEditorShortcut::resolve(InputKey::Character('a'), none), None);
    }

    #[test]
    fn f9_applies_the_smooth_family() {
        let both = InputModifiers::SHIFT | InputModifiers::COMMAND;
        assert_eq!(
            GraphEditorShortcut::resolve(InputKey::Function(9), InputModifiers::NONE),
            Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EasyEase))
        );
        assert_eq!(
            GraphEditorShortcut::resolve(InputKey::Function(9), InputModifiers::SHIFT),
            Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EaseIn))
        );
        assert_eq!(
            GraphEditorShortcut::resolve(InputKey::Function(9), both),
            Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EaseOut))
        );
    }
}
