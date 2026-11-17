// Swift: ShellAnonymize.swift
//! Clip > Video Options > Anonymize: the sheets. Translated from the Mac `AnonymizeDialog` (the texts are shared in
//! `AnonymizeText`). The people finder and the tracker run in the host (the Mac: SQAnalysis through `runAnonymize`); the
//! edit is `EditorSession::apply_anonymize`.

use crate::shell_dialog::ShellDialog;
use crate::shell_dialog::Tone;
use crate::shell_flow_env::{AnonymizeEvent, ShellTool};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use sq_core_masks::anonymize::{AnonymizeCover, AnonymizePerson, AnonymizeTargetExt};
use sq_core_model::AnonymizeTarget;
use sq_core_time::Time;
use sq_editor_session::{AnonymizeCheckLine, AnonymizeChoice, AnonymizeText};
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

const TARGETS: [AnonymizeTarget; 3] = [AnonymizeTarget::Face, AnonymizeTarget::Person, AnonymizeTarget::Skin];
const COVERS: [AnonymizeCover; 2] = [AnonymizeCover::Mosaic, AnonymizeCover::Blur];

impl ShellHost {
    /// What to cover, with what and which of the people found on the playhead's frame. `None`: canceled or nobody ticked.
    pub async fn ask_anonymize<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        clip_name: &str,
        people: Vec<AnonymizePerson>,
    ) -> Option<AnonymizeChoice> {
        let (target, cover) = h.with(|r| AnonymizeChoice::remembered(&*r.shell_parts().shell.flow_env.settings))?;
        // art.html 31: the clip name is a dim subtitle beside the title.
        let info = AnonymizeText::info(clip_name);
        let informative = info.split_once('\n').map_or("", |(_, rest)| rest);
        let mut d = ShellDialog::new("Anonymize", informative);
        d.header_subtitle = Some(clip_name.to_string());
        let titles = |v: Vec<&str>| v.into_iter().map(String::from).collect::<Vec<_>>();
        let mut rows = vec![
            Row::Segmented {
                id: "target".into(),
                label: "Cover".into(),
                options: titles(TARGETS.iter().map(|t| t.title()).collect()),
                selected: TARGETS.iter().position(|t| *t == target).unwrap_or(0) as i64,
                segment_width: 0.0,
            },
            Row::Segmented {
                id: "cover".into(),
                label: "With".into(),
                options: titles(COVERS.iter().map(|c| c.title()).collect()),
                selected: COVERS.iter().position(|c| *c == cover).unwrap_or(0) as i64,
                segment_width: 0.0,
            },
            // strong below: `formText(note: false)`
            Row::Text(AnonymizeText::people_note(people.len())),
        ];
        for (i, p) in people.iter().enumerate() {
            rows.push(Row::check(&format!("person{i}"), &AnonymizeText::person_label(i, p), true));
        }
        rows.push(Row::Text(AnonymizeText::HINT.to_string()));
        let last = rows.len() - 1;
        let mut form = ShellForm::new(rows);
        form.flush_checks = true;
        form.info_notes.insert(last);
        // `formText(top: 6)` over the stack spacing: measured 8 pt against the Mac PNG
        form.extra_gap_before.extend([(2, 8.0), (3, 8.0), (last, 6.0)]);
        form.set_note(2, &AnonymizeText::people_note(people.len()), false, true, true);
        d.form = Some(Box::new(form));
        d.add_button("Anonymize", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return None;
        }
        h.with(|r| {
            let p = r.shell_parts();
            let f = p.shell.take_answered_form()?;
            let pick = |id: &str, len: usize| f.index(id).unwrap_or(0).clamp(0, len as i64 - 1) as usize;
            let choice = AnonymizeChoice::new(
                TARGETS[pick("target", TARGETS.len())],
                COVERS[pick("cover", COVERS.len())],
                (0..people.len()).filter(|i| f.bool(&format!("person{i}")) == Some(true)).collect(),
            );
            if choice.people.is_empty() {
                return None;
            }
            choice.remember(&mut *p.shell.flow_env.settings);
            Some(choice)
        })
        .flatten()
    }

    /// The frames to check by hand after a run: ranges where a person may be outside the cover first (all of them), then at
    /// most `AnonymizeText::MAX_LINES` others. The time of the first line when "Go to First" was pressed (the caller seeks
    /// there).
    pub async fn ask_anonymize_checks<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        lines: Vec<AnonymizeCheckLine>,
    ) -> Option<Time> {
        let (shown, more) = AnonymizeCheckLine::shown(&lines, AnonymizeText::MAX_LINES);
        let first = shown.first()?.time;
        let mut d = ShellDialog::new("Anonymize: Check These Frames", &AnonymizeText::checks_text(&lines));
        // Theme.Modal.widthSList
        d.width = 480.0;
        let mut rows: Vec<Row> = shown.iter().map(|l| Row::Text(l.text.clone())).collect();
        if more > 0 {
            rows.push(Row::Text(AnonymizeText::more_note(more)));
        }
        d.form = Some(Box::new(ShellForm::new(rows)));
        d.add_button("Go to First", SQDialogRole::Default, false);
        d.add_button("Close", SQDialogRole::Cancel, false);
        (Self::ask(&h, d).await == Some(SQDialogResponse::FIRST)).then_some(first)
    }

    /// Clip > Video Options > Anonymize. The host runs the analysis (`ShellServices::run_anonymize`, which also cancels a
    /// running one); without one the command says so.
    pub(crate) fn anonymize_command(&mut self, cx: &mut ShellCx) {
        if !self.flow_env.services.run_anonymize(cx.session) {
            self.flash("Anonymize needs the people finder, which this build does not have.");
        }
        self.forward_anonymize_events();
    }

    /// What the Anonymize flow wants shown (job line, flashes, messages, the sheets); the app calls this after each pump.
    pub fn forward_anonymize_events(&mut self) {
        for e in self.flow_env.services.take_anonymize_events() {
            match e {
                AnonymizeEvent::Job(line) => self.emit(ShellEvent::Job(line)),
                AnonymizeEvent::Flash(text) => self.flash(&text),
                AnonymizeEvent::Warn(title, text) => self.present_message(&title, &text, Some(Tone::Warning)),
                AnonymizeEvent::Info(title, text) => self.present_message(&title, &text, None),
                AnonymizeEvent::Ask { clip_name, people } => {
                    self.start_flow(ShellFlow::Tool(ShellTool::AnonymizeAsk { clip_name, people }));
                }
                AnonymizeEvent::Checks(lines) => self.start_flow(ShellFlow::Tool(ShellTool::AnonymizeChecks(lines))),
            }
        }
    }

    /// The sheet, then the run: the answer goes back to the flow.
    pub(crate) async fn run_anonymize_ask<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        clip_name: String,
        people: Vec<AnonymizePerson>,
    ) {
        let choice = Self::ask_anonymize(h.clone(), &clip_name, people).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            p.shell.flow_env.services.anonymize_answer(p.session, choice);
            p.shell.forward_anonymize_events();
        });
    }

    /// The check list; "Go to First" moves the playhead there.
    pub(crate) async fn run_anonymize_checks<R: ShellRoot + ?Sized>(h: UiRef<R>, lines: Vec<AnonymizeCheckLine>) {
        if let Some(t) = Self::ask_anonymize_checks(h.clone(), lines).await {
            let _ = h.with(|r| r.shell_parts().session.seek(t));
        }
    }
}
