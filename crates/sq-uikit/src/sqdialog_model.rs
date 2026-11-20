//! Port of `SQUIKit/Sources/SQUIKit/SQDialogModel.swift`.

/// What a dialog button means to the keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQDialogRole {
    /// Plain button, never triggered by a key.
    Normal,
    /// Return presses it. At most one; the first one wins.
    Default,
    /// Esc (and Cmd-.) press it. At most one; the first one wins.
    Cancel,
    /// Red text. Never the implicit Return button unless nothing else qualifies.
    Destructive,
    /// "Don't Save": sits alone at the left edge, Cmd-D presses it. At most one; the first one wins.
    DontSave,
    /// "Save": the main action, Cmd-S presses it. At most one; the first one wins.
    Save,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQDialogButton {
    pub title: String,
    pub role: SQDialogRole,
    /// Sits alone at the left edge of the footer (board: "Delete Marker"); everything else is right aligned.
    pub leading: bool,
}

impl SQDialogButton {
    pub fn new(title: &str, role: SQDialogRole) -> SQDialogButton {
        SQDialogButton { title: title.to_string(), role, leading: false }
    }

    /// Left edge of the footer: asked for explicitly, or the Don't Save role.
    pub fn is_leading(&self) -> bool {
        self.leading || self.role == SQDialogRole::DontSave
    }
}

/// Dialog result: the index of the pressed button.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SQDialogResponse(pub i64);

impl SQDialogResponse {
    pub const FIRST: SQDialogResponse = SQDialogResponse(0);
    pub const SECOND: SQDialogResponse = SQDialogResponse(1);
    pub const THIRD: SQDialogResponse = SQDialogResponse(2);
    /// A dialog dismissed without a button (window closed programmatically).
    pub const DISMISSED: SQDialogResponse = SQDialogResponse(-1);
}

/// Pure button-role logic of `SQDialog` (no AppKit): which button Return and Esc press, in which order the buttons
/// are laid out, and what a response index means. The response of a dialog is the index into `buttons` in the order
/// they were added (so the first added button is `Response.first`, like NSAlert's first button).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SQDialogModel {
    pub buttons: Vec<SQDialogButton>,
}

impl SQDialogModel {
    pub fn new(buttons: Vec<SQDialogButton>) -> SQDialogModel {
        SQDialogModel { buttons }
    }

    /// The main action (rightmost, accent): an explicit `.default`, else `.save`, else the first button that is neither
    /// cancel, destructive nor leading, else a lone destructive button (only when there is no Cancel: with a Cancel
    /// button, Cancel is the default and sits rightmost, r8 17-dialoge), else none.
    pub fn primary_index(&self) -> Option<usize> {
        let b = &self.buttons;
        let has_cancel = self.cancel_index().is_some();
        b.iter()
            .position(|x| x.role == SQDialogRole::Default)
            .or_else(|| b.iter().position(|x| x.role == SQDialogRole::Save))
            .or_else(|| b.iter().position(|x| x.role == SQDialogRole::Normal && !x.is_leading()))
            .or_else(|| {
                b.iter().position(|x| {
                    x.role != SQDialogRole::Cancel
                        && !x.is_leading()
                        && !(has_cancel && x.role == SQDialogRole::Destructive)
                })
            })
    }

    /// The button Return presses: the main action, but never a destructive one while a cancel button exists (Return then
    /// presses Cancel, which also holds the focus); a lone destructive button still answers Return.
    pub fn return_index(&self) -> Option<usize> {
        let Some(p) = self.primary_index() else {
            // No main action (a red button alone at the left plus Cancel): Return still never deletes.
            let safe = |b: &SQDialogButton| !matches!(b.role, SQDialogRole::Cancel | SQDialogRole::Destructive);
            return self
                .buttons
                .iter()
                .position(safe)
                .or_else(|| self.cancel_index())
                .or_else(|| self.buttons.iter().position(|b| b.role != SQDialogRole::Cancel));
        };
        if self.buttons[p].role == SQDialogRole::Destructive
            && let Some(c) = self.cancel_index()
        {
            return Some(c);
        }
        Some(p)
    }

    fn cancel_index(&self) -> Option<usize> {
        self.buttons.iter().position(|b| b.role == SQDialogRole::Cancel)
    }

    /// The button that takes the keyboard focus when the dialog opens: Cancel when Return would press it (destructive
    /// dialogs), else none (the default button answers Return without holding the focus, a text field may take it).
    pub fn initial_focus_index(&self) -> Option<usize> {
        let r = self.return_index()?;
        (self.buttons[r].role == SQDialogRole::Cancel).then_some(r)
    }

    /// The button Esc presses: an explicit `.cancel`; else a button titled "Cancel" (any case); else the only button
    /// of a one-button dialog; else none (a choice dialog must be answered).
    pub fn escape_index(&self) -> Option<usize> {
        if let Some(i) = self.cancel_index() {
            return Some(i);
        }
        if let Some(i) = self.buttons.iter().position(|b| b.title.to_lowercase() == "cancel") {
            return Some(i);
        }
        (self.buttons.len() == 1).then_some(0)
    }

    /// Cmd-D.
    pub fn dont_save_index(&self) -> Option<usize> {
        self.buttons.iter().position(|b| b.role == SQDialogRole::DontSave)
    }

    /// Cmd-S.
    pub fn save_index(&self) -> Option<usize> {
        self.buttons.iter().position(|b| b.role == SQDialogRole::Save)
    }

    /// Button indices left to right, the fixed footer order: leading buttons ("Don't Save") alone on the left, then the
    /// other secondary actions, Cancel, and the main action last on the right. Within a group the first added button is
    /// the rightmost (the macOS way).
    pub fn display_order(&self) -> Vec<usize> {
        let p = self.primary_index();
        let rank = |i: usize| -> i64 {
            if Some(i) == p {
                2
            } else if self.buttons[i].role == SQDialogRole::Cancel {
                1
            } else {
                0
            }
        };
        let is_left = |i: usize| self.buttons[i].is_leading() && Some(i) != p;
        let left: Vec<usize> = (0..self.buttons.len()).filter(|&i| is_left(i)).collect();
        let mut right: Vec<usize> = (0..self.buttons.len()).filter(|&i| !is_left(i)).collect();
        right.sort_by_key(|&i| (rank(i), -(i as i64)));
        left.into_iter().chain(right).collect()
    }

    /// Response for a key press, nil when the key does nothing here.
    pub fn response(&self, for_return: bool) -> Option<SQDialogResponse> {
        let index = if for_return { self.return_index() } else { self.escape_index() };
        index.map(|i| SQDialogResponse(i as i64))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SQDialogRole::*;

    fn model(buttons: &[(&str, SQDialogRole)]) -> SQDialogModel {
        SQDialogModel::new(buttons.iter().map(|(t, r)| SQDialogButton::new(t, *r)).collect())
    }

    #[test]
    fn save_prompt_layout_is_dont_save_alone_then_cancel_then_save() {
        let m = model(&[("Save", Save), ("Cancel", Cancel), ("Don\u{2019}t Save", DontSave)]);
        assert_eq!(m.primary_index(), Some(0));
        assert_eq!(m.return_index(), Some(0));
        assert_eq!(m.escape_index(), Some(1));
        assert_eq!(m.dont_save_index(), Some(2));
        assert_eq!(m.save_index(), Some(0));
        assert_eq!(m.display_order(), vec![2, 1, 0]);
    }

    #[test]
    fn destructive_dialog_returns_cancel_and_focuses_it() {
        let m = model(&[("Delete", Destructive), ("Cancel", Cancel)]);
        // Cancel is the default and sits rightmost; the red button is never the main action.
        assert_eq!(m.primary_index(), None);
        assert_eq!(m.display_order(), vec![0, 1]);
        assert_eq!(m.return_index(), Some(1));
        assert_eq!(m.initial_focus_index(), Some(1));
        assert_eq!(m.response(true), Some(SQDialogResponse::SECOND));
        let lone = model(&[("Delete", Destructive)]);
        assert_eq!(lone.return_index(), Some(0));
        assert_eq!(lone.escape_index(), Some(0));
    }

    #[test]
    fn a_leading_destructive_button_with_cancel_never_takes_return() {
        let mut m = model(&[("Remove", Destructive), ("Cancel", Cancel)]);
        m.buttons[0].leading = true;
        assert_eq!(m.primary_index(), None);
        assert_eq!(m.return_index(), Some(1));
        assert_eq!(m.initial_focus_index(), Some(1));
    }

    #[test]
    fn escape_finds_a_button_titled_cancel_and_choice_dialogs_have_none() {
        assert_eq!(model(&[("OK", Default), ("cancel", Normal)]).escape_index(), Some(1));
        assert_eq!(model(&[("A", Normal), ("B", Normal)]).escape_index(), None);
        assert_eq!(model(&[("A", Normal), ("B", Normal)]).response(false), None);
    }

    #[test]
    fn explicit_default_wins_and_leading_buttons_stay_left() {
        let mut m = model(&[("Delete Marker", Normal), ("OK", Normal), ("Cancel", Cancel)]);
        m.buttons[0].leading = true;
        assert_eq!(m.primary_index(), Some(1));
        assert_eq!(m.display_order(), vec![0, 2, 1]);
        assert_eq!(SQDialogResponse::DISMISSED.0, -1);
    }
}
