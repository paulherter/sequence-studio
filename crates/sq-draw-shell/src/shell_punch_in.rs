// Swift: ShellPunchIn.swift
//! Sequence > Punch In Cuts…: zoom levels, ease and pattern for consecutive shots. Translated from the Mac
//! `requestPunchInCuts` and `PunchInCutsSheetView`; the edit is `EditorSession::punch_in_cuts`.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{SettingValue, ShellHost};
use crate::shell_settings::numbers_text;
use sq_core_edit::punch_in_cuts::{PunchInCutsOptions, PunchInEase, PunchInPattern};
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// `PunchInCutsOptions.Ease.rawValue`.
fn ease_raw(e: PunchInEase) -> &'static str {
    match e {
        PunchInEase::Hold => "hold",
        PunchInEase::Linear => "linear",
        PunchInEase::EaseInOut => "easeInOut",
        PunchInEase::FastStart => "fastStart",
    }
}

/// `PunchInCutsOptions.Pattern.rawValue`.
fn pattern_raw(p: PunchInPattern) -> &'static str {
    match p {
        PunchInPattern::Alternate => "alternate",
        PunchInPattern::Cyclic => "cyclic",
    }
}

/// "100 % (no zoom)", "115 %", "126.5 %".
fn zoom_title(v: f64) -> String {
    if v == 100.0 {
        "100 % (no zoom)".to_string()
    } else if v == v.round() {
        format!("{} %", v as i64)
    } else {
        format!("{v:.1} %")
    }
}

impl ShellHost {
    /// `sq.punchInCuts`.
    pub(crate) const PUNCH_IN_CUTS_KEY: &'static str = "sq.punchInCuts";
    /// The XS card (`Theme.Modal.widthXS`; the token is AppKit-only).
    pub(crate) const PUNCH_IN_CUTS_WIDTH: f64 = 360.0;

    /// Punch In Cuts…: asks for the zoom pattern, then applies it.
    pub async fn punch_in_cuts<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            if !p.session.punch_in_cuts_enabled() {
                p.shell.flash("Select two or more video clips, or target a video track with several shots.");
                return None;
            }
            let key = Self::PUNCH_IN_CUTS_KEY;
            let scales = p.shell.setting_numbers(&format!("{key}.scales")).unwrap_or_else(|| vec![115.0]);
            let ease = p.shell.setting_string(&format!("{key}.ease"))
                .and_then(|s| PunchInEase::ALL.into_iter().find(|e| ease_raw(*e) == s))
                .unwrap_or(PunchInEase::Hold);
            let pattern = p.shell.setting_string(&format!("{key}.pattern"))
                .and_then(|s| [PunchInPattern::Alternate, PunchInPattern::Cyclic].into_iter().find(|p| pattern_raw(*p) == s))
                .unwrap_or(PunchInPattern::Alternate);
            let mut d = ShellDialog::new(
                "Punch In Cuts",
                "Zooms consecutive shots in turn. Alternate swaps 100% and the lowest zoom ticked; Cycle walks through all ticked levels.",
            );
            d.width = Self::PUNCH_IN_CUTS_WIDTH;
            let choices = PunchInCutsOptions::SCALE_CHOICES;
            let ease_titles: Vec<&str> = PunchInEase::ALL.iter().map(|e| e.title()).collect();
            let mut rows = vec![
                Row::segmented(
                    "pattern",
                    "Pattern",
                    &["Alternate", "Cycle"],
                    if pattern == PunchInPattern::Alternate { 0 } else { 1 },
                    0.0,
                ),
                Row::popup(
                    "ease",
                    "Ease",
                    &ease_titles,
                    PunchInEase::ALL.iter().position(|e| *e == ease).unwrap_or(0) as i64,
                ),
            ];
            for (i, v) in choices.iter().enumerate() {
                rows.push(Row::check(&format!("zoom{i}"), &zoom_title(*v), scales.contains(v)));
            }
            let mut form = ShellForm::new(rows);
            // art.html 28
            form.control_widths.insert("ease".to_string(), 178.0);
            // The first level carries the "Zoom" label, the others sit under it in the control column.
            for i in 0..choices.len() {
                form.check_labels.insert(format!("zoom{i}"), if i == 0 { "Zoom" } else { "" }.to_string());
            }
            d.form = Some(Box::new(form));
            d.add_button("Apply", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some(d)
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(f) = p.shell.take_answered_form() else { return };
            let choices = PunchInCutsOptions::SCALE_CHOICES;
            let ease =
                PunchInEase::ALL[f.index("ease").unwrap_or(0).clamp(0, PunchInEase::ALL.len() as i64 - 1) as usize];
            let mut o = PunchInCutsOptions::new(
                (0..choices.len()).filter(|i| f.bool(&format!("zoom{i}")) == Some(true)).map(|i| choices[i]).collect(),
            );
            o.ease = ease;
            o.pattern = if f.index("pattern") == Some(1) { PunchInPattern::Cyclic } else { PunchInPattern::Alternate };
            let key = Self::PUNCH_IN_CUTS_KEY;
            p.shell.store_setting(&format!("{key}.scales"), SettingValue::Text(numbers_text(&o.scales)));
            p.shell.store_setting(&format!("{key}.ease"), SettingValue::Text(ease_raw(o.ease).to_string()));
            p.shell.store_setting(&format!("{key}.pattern"), SettingValue::Text(pattern_raw(o.pattern).to_string()));
            if !p.session.punch_in_cuts(&o) {
                let line =
                    p.session.last_error().unwrap_or("Tick a zoom above 100% (Cycle needs two levels).").to_string();
                p.shell.flash_raw(line);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_titles() {
        assert_eq!(zoom_title(100.0), "100 % (no zoom)");
        assert_eq!(zoom_title(110.0), "110 %");
        assert_eq!(zoom_title(126.5), "126.5 %");
    }
}
