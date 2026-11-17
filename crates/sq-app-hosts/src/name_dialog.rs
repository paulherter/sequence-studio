// Swift: SQAppShell/CaptionsHost.swift (panel.style.askName), Inspector/GraphicsHost.swift, Inspector/InspectorHost.swift
//! The SQ dialog of a name the Text block or the Style tab asks for (Save as New Look, Rename Look, Save Animation).

use crate::timeline_dialogs::{capture, dialog_labeled, text};
use sq_draw_shell::{FormRow, ShellDialog, ShellForm};
use sq_inspector_ui::text::block_draw::NameAsk;
use sq_uikit::sqdialog_model::SQDialogResponse;

/// One name field with OK and Cancel; `done` gets the typed name (the suggested one when it was left alone), `None` on Cancel.
pub(crate) fn name_dialog(ask: NameAsk) -> ShellDialog {
    let NameAsk { title, initial, done } = ask;
    let mut form = ShellForm::new(vec![FormRow::field("name", "Name", &initial)]);
    form.begin_editing("name");
    let seen = capture(&mut form);
    dialog_labeled("OK", &title, "", form, move |r| {
        done((r == SQDialogResponse::FIRST).then(|| text(&seen, "name").unwrap_or(initial)));
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    fn asked(answer: SQDialogResponse) -> Option<String> {
        let got: Rc<RefCell<Option<Option<String>>>> = Rc::default();
        let sink = Rc::clone(&got);
        let mut d = name_dialog(NameAsk {
            title: "Save as New Look".into(),
            initial: "My Look".into(),
            done: Box::new(move |n| *sink.borrow_mut() = Some(n)),
        });
        (d.completion.take().expect("completion"))(answer);
        got.take().expect("done ran")
    }

    #[test]
    fn ok_gives_the_suggested_name_and_cancel_gives_none() {
        assert_eq!(asked(SQDialogResponse::FIRST).as_deref(), Some("My Look"));
        assert_eq!(asked(SQDialogResponse::SECOND), None);
    }
}
