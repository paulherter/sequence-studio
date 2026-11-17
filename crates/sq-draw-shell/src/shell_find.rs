// Swift: ShellFind.swift
//! Edit > Find (the Mac `ProjectPanelView.showFind` + `selectFound`): text in the name or label name and/or offline
//! media only; OK shows the Project panel and selects the matches (their bins opened), the status line counts them.
//! The field (placeholder "Text") and the Name / Label popup share the first line, as on the Mac.

use crate::shell_dialog::{FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_model::BinItemRef;
use sq_editor_session::{FindCriteria, FindField};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;
use std::cell::Cell;
use std::rc::Rc;

impl ShellHost {
    /// Opens the Find sheet and selects the matches.
    pub async fn find<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let mut form = ShellForm::new(vec![
            Row::field("text", "", ""),
            Row::popup("field", "", &["Name", "Label"], 0),
            Row::check("offline", "Offline media only", false),
        ]);
        form.set_placeholders([("text".to_string(), "Text".to_string())].into_iter().collect());
        // Drawn without labels (the field and the popup share one line); a screen reader says what they are.
        form.a11y_labels.insert("text".to_string(), "Search text".to_string());
        form.a11y_labels.insert("field".to_string(), "Search in".to_string());
        form.inline_popups.insert("field".to_string());
        form.field_icons.insert("text".to_string(), SQIcon::Search);
        form.begin_editing("text");
        // art.html 17: Find stays dimmed while there is nothing to look for (no text and not offline-only). The dialog's
        // `button_enabled` cannot see the form, so the reaction keeps the two facts.
        let (has_text, offline) = (Rc::new(Cell::new(false)), Rc::new(Cell::new(false)));
        let (t, o) = (Rc::clone(&has_text), Rc::clone(&offline));
        form.on_change = Some(Box::new(move |_, id, value| match (id, value) {
            ("text", FormValue::Text(s)) => t.set(!s.is_empty()),
            ("offline", FormValue::Bool(b)) => o.set(*b),
            _ => {}
        }));
        let mut d = ShellDialog::new("Find", "Select the clips and sequences that match.");
        d.width = 440.0;
        d.form = Some(Box::new(form));
        d.add_button("Find", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.button_enabled = Some(Box::new(move |i| i != 0 || has_text.get() || offline.get()));
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(f) = p.shell.take_answered_form() else { return };
            let field = if f.index("field") == Some(1) { FindField::Label } else { FindField::Name };
            let c = FindCriteria::new(&f.text("text").unwrap_or_default(), field, f.bool("offline").unwrap_or(false));
            p.shell.select_found(&c);
        });
    }

    /// `ProjectPanelView.selectFound`, first half: asks the app to run the Project panel's find. The Project model lives
    /// in the app root, which answers with [`ShellHost::show_found`] in the same pass.
    pub fn select_found(&mut self, c: &FindCriteria) {
        self.find_request = Some(c.clone());
    }

    /// The find the Find sheet asked for since the last call.
    pub fn take_find_request(&mut self) -> Option<FindCriteria> {
        self.find_request.take()
    }

    /// `ProjectPanelView.selectFound`, second half: reports what the app found. True when the app has to clear the
    /// Project search and select `found` in its list; false when there was nothing to show (the status line said so).
    pub fn show_found(&mut self, c: &FindCriteria, found: &[BinItemRef]) -> bool {
        if found.is_empty() {
            self.flash(if c.is_empty() { "Nothing to find." } else { "No match." });
            return false;
        }
        // `execute(.focusPanel(.project))`; the next layout pass relays the dock out.
        self.dock.show(PanelID::Project);
        self.focus = self.dock.focused().or(self.focus);
        self.emit(ShellEvent::Status(SQL10n::plural(found.len() as i64, "%@ match.", "%@ matches.")));
        true
    }
}
