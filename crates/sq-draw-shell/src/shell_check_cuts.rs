// Swift: ShellCheckCuts.swift
//! Sequence > Check Cuts (the Mac `requestCheckCuts` + `CutCheckSheetView`): runs the check, marks the findings on the
//! timeline (Undo removes them) and shows the summary; the platform popup reruns it with that platform's safe zone.
//!
//! Mapping: the Swift reaction ran `session.runCutCheck` inside the dialog's `onChange`. A Rust form reaction cannot
//! reach the session, so the summary of every platform is worked out when the sheet opens (`CutCheck::analyze` is pure)
//! and the reaction swaps the chart; the markers of the platform left on the popup are written when the sheet closes
//! (`run_cut_check` replaces the markers of the last run in one undo step).

use crate::shell_dialog::{FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Bar, Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_edit::cut_check::{CutCheck, CutCheckPlatform};
use sq_editor_session::{CutCheckReport, EditorSession};
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::SQDialogRole;

/// Same key as the Mac sheet, so both shells share the chosen platform.
pub(crate) const CUT_CHECK_PLATFORM_KEY: &str = "sq.cutCheck.platform";

impl ShellHost {
    /// `CutCheckSheetView`: the summary lines, the "Shot length" title and the `ShotHistogramView` bars.
    pub(crate) fn cut_check_chart(r: &CutCheckReport) -> (String, Vec<Bar>) {
        (
            r.board_summary(),
            r.stats.histogram.iter().map(|b| Bar { label: b.label.clone(), count: b.count as i64 }).collect(),
        )
    }

    /// The report `run_cut_check` would give for `platform`, without touching the markers; `None` without a sequence.
    pub(crate) fn cut_check_preview(session: &EditorSession, platform: CutCheckPlatform) -> Option<CutCheckReport> {
        let t = session.active_timeline()?;
        let f = &t.format;
        let aspect = if f.height > 0 { f.display_width() as f64 / f.height as f64 } else { 9.0 / 16.0 };
        let format = t.format.clone();
        let bounds = move |item: &sq_core_model::CaptionItem| Some(EditorSession::caption_box(item, &format));
        let findings = CutCheck::analyze(t, Some(platform), aspect, Some(&bounds));
        Some(CutCheckReport { findings, stats: CutCheck::stats(t), platform })
    }

    /// A caption's drawn box in the active sequence's canvas (`EditorSession.captionBox`); no box without a sequence.
    pub(crate) fn caption_bounds(session: &EditorSession) -> Box<sq_core_edit::cut_check::CaptionBounds> {
        let format = session.active_timeline().map(|t| t.format.clone());
        Box::new(move |item| format.as_ref().map(|f| EditorSession::caption_box(item, f)))
    }

    /// Sequence > Check Cuts.
    pub async fn check_cuts<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let platforms = CutCheckPlatform::ALL;
        let Some(Some((d, saved))) = h.with(|r| {
            let p = r.shell_parts();
            let saved = p
                .shell
                .setting_string(CUT_CHECK_PLATFORM_KEY)
                .and_then(|s| platforms.iter().copied().find(|x| x.raw_value() == s))
                .unwrap_or(CutCheckPlatform::Tiktok);
            let Some(report) = p.session.run_cut_check(saved, Some(&*Self::caption_bounds(p.session))) else {
                p.shell.flash("Nothing to check: open a sequence first.");
                return None;
            };
            p.shell.emit(ShellEvent::ProjectChanged);
            let chart = Self::cut_check_chart(&report);
            let previews: Vec<(String, Vec<Bar>)> = platforms
                .iter()
                .map(|x| {
                    Self::cut_check_preview(p.session, *x).map_or_else(|| chart.clone(), |r| Self::cut_check_chart(&r))
                })
                .collect();
            let mut form = ShellForm::new(vec![
                // `SQSegmented` "Safe Zone" row, segments sized to their titles (52 fits "Shorts" in 11 pt).
                Row::Segmented {
                    id: "platform".into(),
                    label: "Safe Zone".into(),
                    options: platforms.iter().map(|x| x.title().to_string()).collect(),
                    selected: platforms.iter().position(|x| *x == saved).unwrap_or(0) as i64,
                    segment_width: 0.0,
                },
                Row::Chart { note: chart.0, title: "Shot length".into(), bars: chart.1 },
            ]);
            let shown = previews.clone();
            form.on_change = Some(Box::new(move |form, id, value| {
                let FormValue::Index(i) = value else { return };
                let Some((note, bars)) =
                    usize::try_from(*i).ok().and_then(|i| shown.get(i)).filter(|_| id == "platform")
                else {
                    return;
                };
                form.set_chart(1, note, bars.clone());
            }));
            let mut d = ShellDialog::new("Check Cuts", "Findings are marked on the timeline. Undo removes them.");
            d.width = 440.0;
            d.form = Some(Box::new(form));
            d.add_button("Done", SQDialogRole::Default, false);
            Some((d, saved))
        }) else {
            return;
        };
        if Self::ask(&h, d).await.is_none() {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(picked) =
                form.index("platform").and_then(|i| usize::try_from(i).ok()).and_then(|i| platforms.get(i))
            else {
                return;
            };
            if *picked == saved {
                return;
            }
            p.shell.store_setting_string(CUT_CHECK_PLATFORM_KEY, picked.raw_value());
            if p.session.run_cut_check(*picked, Some(&*Self::caption_bounds(p.session))).is_some() {
                p.shell.emit(ShellEvent::ProjectChanged);
            }
        });
    }
}
