// Swift: ShellSequenceMatch.swift
//! "This clip does not match the sequence settings": asked when the first clip lands in an empty, never configured sequence
//! of another size or frame rate. Translated from the Mac `askChangeSequenceFormat`; the session asks it through
//! `askFormatChange` (`EditorSession::place_media_asking`). True = adopt the clip's format.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_host::ShellHost;
use sq_core_model::SequenceFormat;
use sq_core_time::Id;
use sq_editor_session::PlaceOptions;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// C `%.{sig}g`: `sig` significant digits, trailing zeros dropped, exponent form outside 1e-4...1e{sig}.
// shortcut: a copy of sq-editor-session's crate-private `format_g`; use that one when it is made public.
fn format_g(v: f64, sig: usize) -> String {
    if v == 0.0 || !v.is_finite() {
        return if v == 0.0 { "0".to_string() } else { v.to_string() };
    }
    let sig = sig.max(1);
    let sci = format!("{:.*e}", sig - 1, v);
    let (mantissa, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let trim = |s: &str| -> String {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s.to_string() }
    };
    if exp < -4 || exp >= sig as i32 {
        let sign = if exp < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", trim(mantissa), exp.abs());
    }
    let decimals = (sig as i32 - 1 - exp).max(0) as usize;
    trim(&format!("{v:.decimals$}"))
}

impl ShellHost {
    /// `EditorSession::place_media_asking` for the shell root: asks the format question first when the media would
    /// reformat an empty, never configured sequence, then places with the answer. Returns whether something was placed.
    pub async fn place_media_asking<R: ShellRoot + ?Sized>(h: UiRef<R>, ids: Vec<Id>, options: PlaceOptions) -> bool {
        let ask = h
            .with(|r| {
                let s = r.session();
                Some((s.active_timeline()?.format.clone(), s.format_mismatch(&ids)?))
            })
            .flatten();
        let adopt = match ask {
            Some((current, proposed)) => Self::ask_change_sequence_format(h.clone(), &current, &proposed).await,
            None => true,
        };
        h.with(|r| r.session().place_media(&ids, &PlaceOptions { adopt_format: adopt, ..options })).unwrap_or(false)
    }

    /// Asks whether the sequence takes the clip's format. `true` when the root is gone (Swift: `?? true`).
    pub async fn ask_change_sequence_format<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        current: &SequenceFormat,
        proposed: &SequenceFormat,
    ) -> bool {
        let mut d = ShellDialog::new(
            "This clip does not match the sequence settings.",
            &SQL10n::format(
                "Sequence: %@. Clip: %@. Change the sequence settings to match the clip?",
                &[&Self::format_text(current), &Self::format_text(proposed)],
            ),
        );
        d.add_button("Change Sequence Settings", SQDialogRole::Default, false);
        d.add_button("Keep Existing Settings", SQDialogRole::Cancel, false);
        Self::ask(&h, d).await.is_none_or(|r| r == SQDialogResponse::FIRST)
    }

    /// "1920×1080, 29.97 fps" (`%.5g`).
    pub(crate) fn format_text(f: &SequenceFormat) -> String {
        let fps = f.frame_duration.timescale() as f64 / f.frame_duration.value() as f64;
        format!("{}×{}, {} fps", f.width, f.height, format_g(fps, 5))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    #[test]
    fn format_text_uses_five_significant_digits() {
        let mut f = SequenceFormat::new(Time::new(1001, 30000));
        assert_eq!(ShellHost::format_text(&f), "1920×1080, 29.97 fps");
        f.frame_duration = Time::new(1, 24);
        assert_eq!(ShellHost::format_text(&f), "1920×1080, 24 fps");
    }
}
