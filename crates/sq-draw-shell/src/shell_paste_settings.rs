// Swift: ShellPasteSettings.swift
//! Edit > Paste Settings (Cmd+Opt+V): one check per attribute group of the copied clip, all on, plus "Scale Keyframe
//! Times" (off at first, remembered). Translated from the Mac `PasteAttributesDialog` and the `.pasteAttributes` case of
//! `AppController.execute`; the edit is `EditorSession::paste_attributes`.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{SettingValue, ShellHost};
use sq_editor_session::PasteAttributeGroup;
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::collections::BTreeSet;

impl ShellHost {
    /// `sq.pasteAttributes.scaleTimes`.
    pub(crate) const PASTE_SCALE_TIMES_KEY: &'static str = "sq.pasteAttributes.scaleTimes";

    /// Paste Settings…: asks which attribute groups to paste, then pastes them.
    pub async fn paste_settings<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((d, choices))) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.clipboard().is_none() {
                p.shell.flash("Copy a clip first, then select the clips to paste its attributes onto.");
                return None;
            }
            if !p.session.can_paste_attributes() {
                p.shell.flash("Select clips of the same kind as the copied clip.");
                return None;
            }
            let choices = p.session.paste_attribute_choices();
            if choices.is_empty() {
                return None;
            }
            let mut d = ShellDialog::new(
                "Paste Settings",
                "Choose what to paste onto the selected clips. Everything else stays as it is.",
            );
            let mut rows: Vec<Row> = choices.iter().map(|c| Row::check(c.raw_value(), c.title(), true)).collect();
            rows.push(Row::check(
                "scaleTimes",
                "Scale Keyframe Times",
                p.shell.setting_flag(Self::PASTE_SCALE_TIMES_KEY),
            ));
            d.form = Some(Box::new(ShellForm::new(rows)));
            d.add_button("Paste", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((d, choices))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(f) = p.shell.take_answered_form() else { return };
            let scale = f.bool("scaleTimes") == Some(true);
            p.shell.store_setting(Self::PASTE_SCALE_TIMES_KEY, SettingValue::Flag(scale));
            let groups: BTreeSet<PasteAttributeGroup> =
                choices.iter().copied().filter(|c| f.bool(c.raw_value()) == Some(true)).collect();
            // A refused paste reports through the session error.
            if !p.session.paste_attributes(&groups, scale)
                && let Some(e) = p.session.last_error().map(str::to_string)
            {
                p.shell.flash_raw(e);
            }
        });
    }
}
