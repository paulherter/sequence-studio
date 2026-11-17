//! Linux AppImage: the app menu entry in Settings > General. The row shows whether the AppImage sits in the user's
//! apps folder and offers Add or Remove; Remove asks first (the kit's destructive question, design/installer/spec.md
//! 6.5a and 10.3) and every run ends in a result card. The file work is the host's (`ShellEvent::AppMenu`).

use crate::shell_dialog::{ShellDialog, Tone};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use crate::shell_preferences::Page;
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// Settings > General > App menu, as the host reads it from the files on disk.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum AppMenuRow {
    /// Not an AppImage run: no row.
    #[default]
    Hidden,
    /// Not in the menu: the row offers Add.
    NotAdded,
    /// In the menu; `file` is the integrated AppImage as shown (`~/Applications/SequenceStudio.AppImage`).
    Added {
        /// The path text.
        file: String,
    },
}

impl AppMenuRow {
    /// The status line under the row's label; `None` when the row is hidden.
    pub(crate) fn status(&self) -> Option<String> {
        match self {
            AppMenuRow::Hidden => None,
            AppMenuRow::NotAdded => Some("Not added".to_string()),
            AppMenuRow::Added { file } => Some(format!("Added \u{b7} {file}")),
        }
    }

    /// The settings row (label and a small button; the status is its help line); `None` when it is hidden.
    pub(crate) fn row(&self) -> Option<Row> {
        let title = match self {
            AppMenuRow::Hidden => return None,
            AppMenuRow::NotAdded => "Add…",
            AppMenuRow::Added { .. } => "Remove…",
        };
        Some(Row::buttons("appMenu", "App menu", "", &[title]))
    }
}

/// What the user asked of the app menu entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppMenuRequest {
    /// Move the AppImage to the apps folder and add the entry.
    Add,
    /// Take the entry out; optionally the app file goes to the Trash.
    Remove {
        /// "Move the app file to the Trash" was ticked.
        trash_file: bool,
    },
}

/// How a request ended, for the result card.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppMenuOutcome {
    /// Added; the integrated file as shown.
    Added {
        /// The path text.
        file: String,
    },
    /// Removed; whether the app file went to the Trash.
    Removed {
        /// The app file is in the Trash.
        trashed: bool,
    },
    /// Failed; the sentence of the `SQI-3xx` code with the state sentence.
    Failed {
        /// The request was an add (else a remove).
        adding: bool,
        /// What the card says.
        sentence: String,
    },
}

/// The card width of the design kit's setup dialogs (spec section 2).
const CARD_WIDTH: f64 = 520.0;

impl ShellHost {
    /// A card of `label` over its text lines, then `extra` rows (the kit's help line sits under the label).
    fn app_menu_card(lines: &[(&str, &str)], extra: Vec<Row>) -> Box<ShellForm> {
        let mut rows: Vec<Row> = lines.iter().map(|(label, _)| Row::buttons(label, label, "", &[])).collect();
        rows.extend(extra);
        let mut form = ShellForm::new(rows);
        for (label, text) in lines {
            form.helps.insert((*label).to_string(), (*text).to_string());
        }
        Box::new(form)
    }

    /// The Remove question: the card of spec 6.5a for the Linux app menu. Remove is red at the far left and never takes
    /// Enter (the model hands Return to Cancel).
    pub(crate) fn app_menu_remove_dialog() -> ShellDialog {
        let mut d = ShellDialog::new("Remove from the app menu?", "");
        d.form = Some(Self::app_menu_card(
            &[("Removes", "Menu entry and the .sqproj link"), ("Keeps", "The app file, your projects and settings")],
            vec![Row::check("trash", "Move the app file to the Trash", false)],
        ));
        d.width = CARD_WIDTH;
        d.add_button("Remove", SQDialogRole::Destructive, true);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d
    }

    /// The card after a request ran: what was removed or added, or the error sentence.
    pub(crate) fn app_menu_done_dialog(outcome: &AppMenuOutcome) -> ShellDialog {
        let (mut d, rows) = match outcome {
            AppMenuOutcome::Added { file } => (
                ShellDialog::new("Added to the app menu", ""),
                vec![("Location", file.as_str()), ("Added", "Menu entry \u{b7} .sqproj projects")],
            ),
            AppMenuOutcome::Removed { trashed } => (
                ShellDialog::new("Removed from the app menu", ""),
                (if *trashed {
                    [("Removed", "Menu entry, .sqproj link"), ("Also", "The app file is in the Trash")]
                } else {
                    [("Removed", "Menu entry, .sqproj link"), ("Kept", "The app file, your projects and settings")]
                })
                .to_vec(),
            ),
            AppMenuOutcome::Failed { adding, sentence } => {
                let title = if *adding { "Couldn't add to the app menu" } else { "Couldn't remove from the app menu" };
                let mut d = ShellDialog::new(title, sentence);
                d.header_icon = Some(Tone::Error);
                (d, Vec::new())
            }
        };
        d.width = CARD_WIDTH;
        if !rows.is_empty() {
            d.form = Some(Self::app_menu_card(&rows, Vec::new()));
        }
        d.add_button("Close", SQDialogRole::Default, false);
        d
    }

    /// Settings > General > App menu > Remove…: asks, then hands the request to the host. Cancel opens Settings again.
    pub(crate) async fn app_menu_remove_flow<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        if Self::ask(&h, Self::app_menu_remove_dialog()).await == Some(SQDialogResponse::FIRST) {
            let _ = h.with(|r| {
                let shell = &mut *r.shell_parts().shell;
                let trash_file = shell.take_answered_form().and_then(|f| f.bool("trash")).unwrap_or(false);
                shell.emit(ShellEvent::AppMenu(AppMenuRequest::Remove { trash_file }));
            });
        } else {
            Self::reopen_settings(&h);
        }
    }

    /// The result card; Close opens Settings again on General, where the row shows the new state.
    pub(crate) async fn app_menu_done_flow<R: ShellRoot + ?Sized>(h: UiRef<R>, outcome: AppMenuOutcome) {
        let _ = Self::ask(&h, Self::app_menu_done_dialog(&outcome)).await;
        Self::reopen_settings(&h);
    }

    fn reopen_settings<R: ShellRoot + ?Sized>(h: &UiRef<R>) {
        let _ = h.with(|r| r.shell_parts().shell.start_flow(ShellFlow::ShowPreferencesAt(Page::General, false)));
    }

    /// The host finished an app menu request (the row is already updated): shows the result card.
    pub fn show_app_menu_result(&mut self, outcome: AppMenuOutcome) {
        self.start_flow(ShellFlow::AppMenuDone(outcome));
    }
}
