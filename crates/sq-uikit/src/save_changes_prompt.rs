//! Port of `SQUIKit/Sources/SQUIKit/SaveChangesPrompt.swift`.

use crate::sqdialog_model::{SQDialogButton, SQDialogResponse, SQDialogRole};

/// The "Save changes?" question (the dialog: `makeDialog` in SQEditorUI on the Mac, `ShellDialog` in SQDrawShell) of every place that can discard a document (open, new, close, quit): one button set,
/// one order (board, left to right: Don't Save, Cancel, Save), Return and Cmd-S = Save, Esc = Cancel, Cmd-D = Don't Save (alone on the left).
pub struct SaveChangesPrompt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveChoice {
    Save,
    Cancel,
    DontSave,
}

/// What the caller does after the question (and, for Save, after the write): carry on with the quit / close /
/// replace, or stay in the project. A failed save never counts as a decision to leave: the project stays open
/// (the error dialog already told why) and the user asks again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveOutcome {
    Proceed,
    Stay,
}

impl SaveChangesPrompt {
    /// In the order they are added to the dialog (the first sits rightmost).
    pub fn buttons() -> Vec<SQDialogButton> {
        vec![
            SQDialogButton::new("Save", SQDialogRole::Save),
            SQDialogButton::new("Cancel", SQDialogRole::Cancel),
            SQDialogButton::new("Don\u{2019}t Save", SQDialogRole::DontSave),
        ]
    }

    pub fn choice(response: SQDialogResponse) -> SaveChoice {
        match response {
            SQDialogResponse::FIRST => SaveChoice::Save,
            SQDialogResponse::THIRD => SaveChoice::DontSave,
            _ => SaveChoice::Cancel,
        }
    }

    /// `save_succeeded` is only read for `Save`; pass `None` when no write happened.
    pub fn outcome(choice: SaveChoice, save_succeeded: Option<bool>) -> SaveOutcome {
        match choice {
            SaveChoice::DontSave => SaveOutcome::Proceed,
            SaveChoice::Cancel => SaveOutcome::Stay,
            SaveChoice::Save => {
                if save_succeeded == Some(true) {
                    SaveOutcome::Proceed
                } else {
                    SaveOutcome::Stay
                }
            }
        }
    }

    /// Second line of the dialog: a never-saved project says it asks for a place next.
    pub fn detail(has_file: bool) -> &'static str {
        if has_file {
            "Your changes are lost if you don\u{2019}t save them."
        } else {
            "Your changes are lost if you don\u{2019}t save them. This project was never saved: Save asks for a place."
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sqdialog_model::SQDialogModel;

    #[test]
    fn responses_map_to_choices() {
        assert_eq!(SaveChangesPrompt::choice(SQDialogResponse::FIRST), SaveChoice::Save);
        assert_eq!(SaveChangesPrompt::choice(SQDialogResponse::SECOND), SaveChoice::Cancel);
        assert_eq!(SaveChangesPrompt::choice(SQDialogResponse::THIRD), SaveChoice::DontSave);
        assert_eq!(SaveChangesPrompt::choice(SQDialogResponse::DISMISSED), SaveChoice::Cancel);
    }

    #[test]
    fn a_failed_save_stays() {
        assert_eq!(SaveChangesPrompt::outcome(SaveChoice::Save, Some(true)), SaveOutcome::Proceed);
        assert_eq!(SaveChangesPrompt::outcome(SaveChoice::Save, Some(false)), SaveOutcome::Stay);
        assert_eq!(SaveChangesPrompt::outcome(SaveChoice::Save, None), SaveOutcome::Stay);
        assert_eq!(SaveChangesPrompt::outcome(SaveChoice::DontSave, None), SaveOutcome::Proceed);
        assert_eq!(SaveChangesPrompt::outcome(SaveChoice::Cancel, None), SaveOutcome::Stay);
    }

    #[test]
    fn board_order_is_dont_save_cancel_save() {
        let m = SQDialogModel::new(SaveChangesPrompt::buttons());
        assert_eq!(m.display_order(), vec![2, 1, 0]);
        assert!(SaveChangesPrompt::detail(false).contains("never saved"));
        assert!(!SaveChangesPrompt::detail(true).contains("never saved"));
    }
}
