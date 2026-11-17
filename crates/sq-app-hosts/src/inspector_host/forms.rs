// Swift: SQAppShell/Inspector/InspectorHost.swift (ask)
//! The SQ dialog of a key tool prompt: one text field per prompt field, the typed texts handed back in order.

use sq_draw_shell::{FormRow, FormValue, ShellDialog, ShellForm};
use sq_inspector_ui::keyframes::key_tools_input::KeyToolPrompt;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::rc::Rc;

/// A dialog for `prompt`; `done` gets the typed texts in field order, `None` when canceled. Fields are read as the form
/// reports them (a button press commits a field that is still being typed in).
pub(super) fn ask(prompt: &KeyToolPrompt, done: Box<dyn FnOnce(Option<Vec<String>>)>) -> ShellDialog {
    let mut d = ShellDialog::new(&prompt.title, &prompt.informative);
    let texts: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(prompt.fields.iter().map(|f| f.text.clone()).collect()));
    if !prompt.fields.is_empty() {
        let rows = prompt
            .fields
            .iter()
            .enumerate()
            .map(|(i, f)| FormRow::field(&format!("f{i}"), &f.label, &f.text))
            .collect();
        let mut form = ShellForm::new(rows);
        let typed = Rc::clone(&texts);
        form.on_change = Some(Box::new(move |_, id, value| {
            let index = id.strip_prefix('f').and_then(|n| n.parse::<usize>().ok());
            if let (Some(i), FormValue::Text(s)) = (index, value)
                && let Some(slot) = typed.borrow_mut().get_mut(i)
            {
                slot.clone_from(s);
            }
        }));
        d.form = Some(Box::new(form));
    }
    d.add_button("Cancel", SQDialogRole::Cancel, false);
    d.add_button(&prompt.confirm, SQDialogRole::Default, false);
    d.completion = Some(Box::new(move |r: SQDialogResponse| {
        done((r.0 == 1).then(|| texts.borrow().clone()));
    }));
    d
}
