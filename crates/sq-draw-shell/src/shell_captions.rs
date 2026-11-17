// Swift: ShellCaptions.swift
//! The Captions dialogs of the Mac Text panel: Create Captions (`CreateCaptionsDialog`) and the "Replace the transcript?"
//! question (`CaptionsPanelView.makeOverwriteDialog`). They need a transcript, which the shared Text panel's Transcribe
//! tab makes; the hooks that call them are `CaptionsHost.createCaptions(model:)` and `confirmOverwrite(model:)`.

use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{NumberField, Row, ShellForm};
use crate::shell_host::ShellHost;
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// One entry of the Create Captions style list with the limits of its preset.
#[derive(Clone, Debug, PartialEq)]
pub struct ShellCaptionStyle {
    /// The style's name.
    pub name: String,
    /// Characters per line.
    pub max_chars: i64,
    /// 1 or 2.
    pub lines: i64,
    /// Shortest caption in seconds.
    pub min_seconds: f64,
    /// Gap between captions in frames.
    pub gap_frames: i64,
}

/// What the Create Captions dialog returned.
#[derive(Clone, Debug, PartialEq)]
pub struct ShellCreateCaptionsChoice {
    /// The picked style (index).
    pub style: usize,
    /// Characters per line.
    pub max_chars: i64,
    /// 1 or 2.
    pub lines: i64,
    /// Shortest caption in seconds.
    pub min_seconds: f64,
    /// Gap between captions in frames.
    pub gap_frames: i64,
}

/// The four limit fields a style fills in: characters, lines (0 = One, 1 = Two), minimum seconds, gap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct CaptionFields {
    pub chars: f64,
    pub lines: i64,
    pub min_seconds: f64,
    pub gap: f64,
}

impl ShellHost {
    /// The limits the Mac dialog shows for a preset: Characters 8...100, Min. Duration to 2 decimals, Caption Gap in frames.
    pub(crate) fn caption_fields(s: &ShellCaptionStyle) -> CaptionFields {
        CaptionFields {
            chars: s.max_chars.clamp(8, 100) as f64,
            lines: if s.lines <= 1 { 0 } else { 1 },
            min_seconds: (s.min_seconds * 100.0).round() / 100.0,
            gap: s.gap_frames.max(0) as f64,
        }
    }

    /// The Create Captions dialog. `None` on Cancel (or when there is no style).
    pub async fn ask_create_captions<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        styles: Vec<ShellCaptionStyle>,
        selected: usize,
    ) -> Option<ShellCreateCaptionsChoice> {
        if styles.is_empty() {
            return None;
        }
        let pick = selected.min(styles.len() - 1);
        let first = Self::caption_fields(&styles[pick]);
        let mut d = ShellDialog::new("Create Captions", "Captions are made from the transcript of the whole sequence.");
        let scrub = |id: &str, v: f64, range, step, decimals, unit: &str| NumberField {
            id: id.into(),
            value: v,
            range,
            step,
            decimals,
            unit: unit.into(),
            default_value: Some(v),
        };
        let mut form = ShellForm::new(vec![
            Row::Popup {
                id: "style".into(),
                label: "Style".into(),
                options: styles.iter().map(|s| s.name.clone()).collect(),
                selected: pick as i64,
            },
            Row::Number { label: "Characters".into(), field: scrub("chars", first.chars, 8.0..=100.0, 1.0, 0, "") },
            Row::segmented("lines", "Lines", &["One", "Two"], first.lines, 0.0),
            Row::Number {
                label: "Min. Duration".into(),
                field: scrub("minDuration", first.min_seconds, 0.0..=60.0, 0.05, 2, "s"),
            },
            Row::Number { label: "Caption Gap".into(), field: scrub("gap", first.gap, 0.0..=120.0, 1.0, 0, "frames") },
        ]);
        // art.html 27: 62 pt number boxes
        for id in ["chars", "minDuration", "gap"] {
            form.control_widths.insert(id.to_string(), 62.0);
        }
        // A new style refills the four limits with its own.
        let reaction_styles = styles.clone();
        form.on_change = Some(Box::new(move |form, id, value| {
            let FormValue::Index(i) = value else { return };
            let Some(style) = usize::try_from(*i).ok().and_then(|i| reaction_styles.get(i)).filter(|_| id == "style")
            else {
                return;
            };
            let v = ShellHost::caption_fields(style);
            form.set("chars", FormValue::Number(v.chars));
            form.set("lines", FormValue::Index(v.lines));
            form.set("minDuration", FormValue::Number(v.min_seconds));
            form.set("gap", FormValue::Number(v.gap));
        }));
        d.form = Some(Box::new(form));
        d.add_button("Create", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return None;
        }
        let mut f = h.with(|r| r.shell_parts().shell.take_answered_form()).flatten()?;
        f.commit_editing();
        Some(Self::captions_choice(&*f, styles.len(), pick, &first))
    }

    /// Reads the answered Create Captions form.
    pub(crate) fn captions_choice(
        f: &dyn DialogForm,
        style_count: usize,
        pick: usize,
        first: &CaptionFields,
    ) -> ShellCreateCaptionsChoice {
        let style = f.index("style").map_or(pick, |i| usize::try_from(i).unwrap_or(0).min(style_count - 1));
        ShellCreateCaptionsChoice {
            style,
            max_chars: f.number("chars").unwrap_or(first.chars).round() as i64,
            lines: f.index("lines").unwrap_or(first.lines) + 1,
            min_seconds: f.number("minDuration").unwrap_or(first.min_seconds).max(0.0),
            gap_frames: f.number("gap").unwrap_or(first.gap).round() as i64,
        }
    }

    /// "Replace the transcript?": transcribing again drops the current transcript with the user's edits. True = go on.
    pub async fn confirm_replace_transcript<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let mut d = ShellDialog::new(
            "Replace the transcript?",
            "Transcribing again replaces the current transcript, including your edits. Media is not changed.",
        );
        d.add_button("Transcribe Again", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        Self::ask(&h, d).await == Some(SQDialogResponse::FIRST)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style(max_chars: i64, lines: i64, min_seconds: f64, gap_frames: i64) -> ShellCaptionStyle {
        ShellCaptionStyle { name: "S".into(), max_chars, lines, min_seconds, gap_frames }
    }

    #[test]
    fn a_style_fills_the_limits_inside_the_dialog_ranges() {
        let f = ShellHost::caption_fields(&style(3, 1, 0.333, -2));
        assert_eq!(f, CaptionFields { chars: 8.0, lines: 0, min_seconds: 0.33, gap: 0.0 });
        let f = ShellHost::caption_fields(&style(500, 2, 1.0, 12));
        assert_eq!(f, CaptionFields { chars: 100.0, lines: 1, min_seconds: 1.0, gap: 12.0 });
    }
}
