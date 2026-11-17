// Swift: ShellHost.swift `ask` together with `ShellForm.onChange` closures that spawn
//! A dialog whose flow keeps working while it is open: Swift form closures `spawn`ed a file chooser or a preview from
//! `onChange`; here the flow awaits the next form change or the answer, whichever comes first, and does that work itself.
//! The host wakes the waiting flow when a change is queued (`ShellHost::route_form_changes`).

use crate::shell_dialog::{FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_host::ShellHost;
use sq_runtime::{ModalAsk, UiRef};
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::future::{Future, poll_fn};
use std::pin::Pin;
use std::task::Poll;

/// What happened to a dialog shown with [`ShellHost::present_live`].
#[derive(Debug, PartialEq)]
pub(crate) enum Live {
    /// Values the user changed since the last call, in order.
    Changed(Vec<(String, FormValue)>),
    /// A button closed the dialog; the typed values wait in `ShellHost::take_answered_form`.
    Answered(SQDialogResponse),
}

/// The pending answer of a live dialog.
pub(crate) struct LiveAsk(ModalAsk<SQDialogResponse>);

impl ShellHost {
    /// Shows `d` and returns the handle to wait on; `None` when the root is gone.
    pub(crate) fn present_live<R: ShellRoot + ?Sized>(h: &UiRef<R>, d: ShellDialog) -> Option<LiveAsk> {
        h.with(|r| r.shell_parts().shell.present(d)).map(LiveAsk)
    }
}

impl LiveAsk {
    /// The next change or the answer. `None` when the root is gone.
    pub(crate) async fn next<R: ShellRoot + ?Sized>(&mut self, h: &UiRef<R>) -> Option<Live> {
        poll_fn(|cx| {
            if let Poll::Ready(a) = Pin::new(&mut self.0).poll(cx) {
                return Poll::Ready(Some(Live::Answered(a)));
            }
            let polled = h.with(|r| {
                let shell = &mut *r.shell_parts().shell;
                let changes = shell.take_form_changes();
                if changes.is_empty() {
                    shell.form_waker = Some(cx.waker().clone());
                }
                changes
            });
            match polled {
                None => Poll::Ready(None),
                Some(c) if !c.is_empty() => Poll::Ready(Some(Live::Changed(c))),
                Some(_) => Poll::Pending,
            }
        })
        .await
    }
}

#[cfg(test)]
pub(crate) mod test_rig {
    use crate::shell_dialog::FormValue;
    use crate::tests::Rig;
    use sq_draw::InputEvent;
    use sq_uikit::sqdialog_model::SQDialogResponse;

    /// Types `value` into the open dialog's form row `id`.
    pub(crate) fn type_into(rig: &Rig, id: &str, value: FormValue) {
        rig.with(|r| {
            if let Some(f) = r.shell.dialog_mut().and_then(|d| d.form.as_mut()) {
                f.set_value(id, value);
            }
        });
    }

    /// Presses a button of the open dialog and lets the host sweep it (the next event does) before the flow resumes, as
    /// in the app, so the flow finds the answered form.
    pub(crate) fn answer_swept(rig: &Rig, r: SQDialogResponse) {
        rig.with(|root| {
            if let Some(d) = root.shell.dialog_mut() {
                d.press(r);
            }
        });
        rig.cx(|h, cx| h.handle(cx, &InputEvent::MouseMoved { x: 0.0, y: 0.0 }, 1.0));
        rig.rt.run_until_stalled();
    }
}
