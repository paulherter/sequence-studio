// Swift: ShellRelink.swift
//! File > Project > Reconnect Media… (the Mac `RelinkSheet`) as a shell dialog. The Import Checklist… half of the Swift
//! file (`ShellImportChecklist`, `showImportChecklist`, `showImportReport`, `askImportReport`) is here too.

use crate::ShellFlow;
use crate::shell_dialog::{ShellDialog, Tone};
use crate::shell_flow_env::ImportChecklistState;
use crate::shell_flows::ShellRoot;
use crate::shell_host::ShellEvent;
use crate::shell_host::{SettingValue, ShellHost};
use crate::shell_import_report_content::ShellImportReportContent;
use sq_core_model::MediaRef;
use sq_core_model::Project;
use sq_core_project::media_path_resolver::MediaPathResolver;
use sq_editor_session::EditorSession;
use sq_premiere_import::primport_checklist::{Item, Kind};
use sq_premiere_import::primport_report::{PRImportReport, Status};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::Path;
use std::rc::Rc;

impl ShellHost {
    /// Folders Reconnect Media searched, newest first (the Mac key, so both shells share the list).
    pub(crate) const RELINK_FOLDERS_KEY: &'static str = "sq.relink.folders";

    /// Remembers `dir` at the top of the searched folders (at most 10). The list is one path per line.
    pub(crate) fn remember_relink_folder(&mut self, dir: &Path) {
        let path = dir.to_string_lossy().into_owned();
        let mut list: Vec<String> = self
            .setting_string(Self::RELINK_FOLDERS_KEY)
            .map(|s| s.lines().map(str::to_string).collect())
            .unwrap_or_default();
        list.retain(|p| *p != path);
        list.insert(0, path);
        list.truncate(10);
        self.store_setting(Self::RELINK_FOLDERS_KEY, SettingValue::Text(list.join("\n")));
    }

    /// The dialog's title and note for `missing` of `total` offline files after `searched` folders.
    pub(crate) fn relink_text(missing: &[MediaRef], total: usize, searched: usize) -> (String, String) {
        let found = total.saturating_sub(missing.len());
        let title = if searched == 0 {
            if total == 1 {
                SQL10n::string("1 media file is offline")
            } else {
                SQL10n::format("%@ media files are offline", &[&total.to_string()])
            }
        } else {
            SQL10n::format("%@ of %@ found", &[&found.to_string(), &total.to_string()])
        };
        let names =
            missing.iter().take(4).map(|m| MediaPathResolver::file_name_of(&m.path)).collect::<Vec<_>>().join(", ");
        // tight: the list must fit one line (art.html 09)
        let more = if missing.len() > 4 { ",…" } else { "" };
        let detail = if searched == 0 {
            SQL10n::format(
                "Not found: %@.\nChoose the folder they are in; subfolders are searched too.",
                &[&format!("{names}{more}")],
            )
        } else {
            SQL10n::format("Still missing: %@. Add another folder or click Done.", &[&format!("{names}{more}")])
        };
        (title, detail)
    }

    /// Asks for folders until everything is found or Done; each folder is searched with subfolders, one undo step each.
    /// The chooser's suggested name for "Save Report…" (the Mac `saveImportReport`).
    pub(crate) fn import_report_file_name(file_name: &str) -> String {
        format!("{file_name} import report.txt")
    }

    /// The report card's "Save Report…" (`saveImportReport`): the save chooser, then `report.summary` as UTF-8 text.
    pub async fn save_import_report<R: ShellRoot + ?Sized>(h: UiRef<R>, report: PRImportReport, file_name: String) {
        let Some(ask) = h.with(|r| {
            r.shell_parts()
                .files
                .choose_save_location(&Self::import_report_file_name(&file_name), &SQL10n::string("Save Report"))
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        if let Err(e) = std::fs::write(&url, report.summary()) {
            let _ = h.with(|r| {
                r.shell_parts().shell.present_message(
                    &SQL10n::string("Could not save the report"),
                    &SQL10n::error_text(&e),
                    Some(Tone::Error),
                )
            });
        }
    }

    /// The card's dialog (`askImportReport`): Done closes it, Save Report… keeps it open and queues the save flow.
    pub fn import_report_dialog(
        content: ShellImportReportContent,
        title: &str,
        note: &str,
        report: &PRImportReport,
        file_name: &str,
        flows: Rc<RefCell<Vec<ShellFlow>>>,
    ) -> ShellDialog {
        let mut d = ShellDialog::new(title, note);
        d.width = 600.0; // SQModal.Size.m
        d.content = Some(Box::new(content));
        d.add_button("Done", SQDialogRole::Default, false);
        d.add_button("Save Report…", SQDialogRole::Normal, false);
        // Save Report… keeps the card open (the Mac sheet writes the file and stays).
        let (report, file_name) = (report.clone(), file_name.to_string());
        d.can_close = Some(Box::new(move |r| {
            if r != SQDialogResponse(1) {
                return true;
            }
            flows.borrow_mut().push(ShellFlow::SaveImportReport(report.clone(), file_name.clone()));
            false
        }));
        d
    }

    /// The report card with a mapped, an approximated and a dropped item, for the `--pose import-report` shot.
    pub fn present_sample_import_report(&mut self) {
        let mut report = PRImportReport::default();
        report.note("Cross Dissolve", Status::Mapped, "");
        report.note("Lumetri Color", Status::Dropped, "Not supported");
        report.note("Speed ramp", Status::Approximated, "Approximated as constant speed");
        let content = ShellImportReportContent::new(ShellImportReportContent::rows_for_report(&report));
        let d = Self::import_report_dialog(
            content,
            "Imported Cut.prproj",
            "1 mapped, 1 approximated, 1 dropped. Fix the last two by hand.",
            &report,
            "Cut.prproj",
            self.menu_flows_handle(),
        );
        drop(self.present(d));
    }

    /// The card without a checklist (report mode of the Mac sheet): rows worst first, Save Report… and Done.
    pub async fn show_import_report<R: ShellRoot + ?Sized>(h: UiRef<R>, report: PRImportReport, file_name: String) {
        let total = |s: Status| report.entries().iter().filter(|e| e.status == s).map(|e| e.count).sum::<i64>();
        let note = SQL10n::format(
            "%@ mapped, %@ approximated, %@ dropped. Fix the last two by hand.",
            &[
                &total(Status::Mapped).to_string(),
                &total(Status::Approximated).to_string(),
                &total(Status::Dropped).to_string(),
            ],
        );
        let title = SQL10n::format("Imported %@", &[&file_name]);
        let content = ShellImportReportContent::new(ShellImportReportContent::rows_for_report(&report));
        let Some(d) = h.with(|r| {
            Self::import_report_dialog(
                content,
                &title,
                &note,
                &report,
                &file_name,
                Rc::clone(&r.shell_parts().shell.menu_flows),
            )
        }) else {
            return;
        };
        let _ = Self::ask(&h, d).await;
    }

    /// File > Import Checklist… and the card after a project import (`showImportChecklist`). True when Reconnect was
    /// chosen and ran.
    pub async fn show_import_checklist<R: ShellRoot + ?Sized>(h: UiRef<R>) -> bool {
        let sink: Rc<RefCell<Option<Item>>> = Rc::new(RefCell::new(None));
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            let Some(state) = p.shell.flow_env.import_checklist.as_ref() else {
                p.shell.flash("No project import to check.");
                return None;
            };
            let rows = ShellImportReportContent::rows_for_checklist(&state.checklist, p.session.can_relink());
            let note = if state.checklist.needs_attention() {
                "Show jumps to the affected clips. This list stays under File > Import Checklist."
            } else {
                "Everything came over as is."
            };
            let mut content = ShellImportReportContent::new(rows);
            content.sink = Some(Rc::clone(&sink));
            let title = SQL10n::format("Imported %@", &[&state.file_name]);
            Some(Self::import_report_dialog(
                content,
                &title,
                &SQL10n::string(note),
                &state.report,
                &state.file_name,
                Rc::clone(&p.shell.menu_flows),
            ))
        }) else {
            return false;
        };
        let _ = Self::ask(&h, d).await;
        let chosen = sink.borrow_mut().take();
        match chosen {
            Some(item) if item.kind == Kind::MissingFiles => {
                Self::relink_media(h).await;
                true
            }
            Some(item) => {
                let _ = h.with(|r| {
                    let p = r.shell_parts();
                    p.shell.show_affected_clip(p.session, &item);
                });
                false
            }
            None => false,
        }
    }

    /// Selects the next clip of a checklist row (wrapping), switching to its sequence and moving the playhead to it.
    pub(crate) fn show_affected_clip(&mut self, session: &mut EditorSession, item: &Item) {
        let Some(state) = self.flow_env.import_checklist.as_mut() else { return };
        if item.locations.is_empty() {
            self.flash("This row has no clips to show.");
            return;
        }
        let at = state.cursor.get(&item.id).copied().unwrap_or(0) % item.locations.len();
        state.cursor.insert(item.id.clone(), at + 1);
        let loc = item.locations[at];
        let start = session
            .project()
            .timeline(loc.timeline)
            .and_then(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == loc.clip))
            .map(|c| c.timeline().start);
        let Some(start) = start else {
            self.flash("That clip is gone.");
            return;
        };
        if session.active_timeline_id() != Some(loc.timeline) {
            session.set_active_timeline(loc.timeline);
        }
        session.select(BTreeSet::from([loc.clip]), BTreeSet::new());
        session.seek(start);
        self.emit(ShellEvent::Status(SQL10n::format(
            "%@: clip %@ of %@. For the next, open File > Import Checklist",
            &[&item.title, &(at + 1).to_string(), &item.locations.len().to_string()],
        )));
    }

    /// The Mac importers' tail: remember the checklist, then show it when something needs a look or media is missing,
    /// then offer Reconnect Media for what is still missing.
    pub(crate) fn remember_import(&mut self, report: PRImportReport, project: &Project, file_name: &str) {
        self.flow_env.import_checklist = Some(ImportChecklistState::new(report, project, file_name));
    }

    /// True when the card should show after an import (`needsAttention || canRelink`).
    pub(crate) fn import_card_due(&self, session: &EditorSession) -> bool {
        self.flow_env.import_checklist.as_ref().is_some_and(|s| s.checklist.needs_attention()) || session.can_relink()
    }

    /// The card and then Reconnect Media, as the importers start them.
    pub async fn import_card_flow<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        if !Self::show_import_checklist(h.clone()).await
            && h.with(|r| r.shell_parts().session.can_relink()).unwrap_or(false)
        {
            Self::relink_media(h).await;
        }
    }

    pub async fn relink_media<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(total) = h.with(|r| r.shell_parts().session.missing_media().len()) else { return };
        if total == 0 {
            let _ = h.with(|r| r.shell_parts().shell.flash("All media is online."));
            return;
        }
        let mut searched = 0;
        let mut note: Option<String> = None;
        loop {
            let Some(d) = h.with(|r| {
                let p = r.shell_parts();
                let missing = p.session.missing_media();
                if missing.is_empty() {
                    return None;
                }
                let (title, detail) = Self::relink_text(&missing, total, searched);
                let info = note.as_ref().map_or(detail.clone(), |n| format!("{n}\n{detail}"));
                let mut d = ShellDialog::new(&title, &info);
                d.width = 440.0;
                d.add_button(if searched == 0 { "Locate…" } else { "Add Folder…" }, SQDialogRole::Default, false);
                d.add_button("Done", SQDialogRole::Cancel, false);
                // art.html 09: the amber triangle before the title
                d.header_icon = Some(Tone::Warning);
                // the Mac RelinkSheet: band footer, 56 pt header
                d.sheet_style = true;
                // Pip (`SQMascotPlace.mediaOffline`) at the left of the footer; the host draws him
                d.footer_mascot = true;
                Some(d)
            }) else {
                break;
            };
            let Some(d) = d else { break };
            if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
                break;
            }
            let prompt = SQL10n::string("Choose the folder that contains the offline media");
            let Some(ask) = h.with(|r| r.shell_parts().files.choose_folder(&prompt)) else { return };
            let Some(dir) = ask.await else { continue };
            searched += 1;
            let name = dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            note = h
                .with(|r| {
                    let p = r.shell_parts();
                    p.shell.remember_relink_folder(&dir);
                    p.shell.flash_raw(SQL10n::format("Searching %@…", &[&name]));
                    let outcome = p.session.relink_missing(&dir);
                    (outcome.size_differs > 0).then(|| {
                        SQL10n::format(
                            "%@ files have the right name but another size; they were left offline.",
                            &[&outcome.size_differs.to_string()],
                        )
                    })
                })
                .flatten();
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let found = total.saturating_sub(p.session.missing_media().len());
            if found > 0 {
                p.shell.flash_raw(SQL10n::plural(
                    found as i64,
                    "Reconnected %@ media file.",
                    "Reconnected %@ media files.",
                ));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;
    use sq_core_time::Id;

    fn media(path: &str) -> MediaRef {
        MediaRef::new(Id::from_u128(1), "clip", path, MediaFingerprint { size: 1, modified: None, head_hash: None })
    }

    /// Three imported items: one came over, one is unsupported, one is missing.
    fn three_file_report() -> PRImportReport {
        let mut r = PRImportReport::default();
        r.note("Cross Dissolve", Status::Mapped, "");
        r.note("Lumetri Color", Status::Dropped, "Not supported");
        r.note(
            sq_premiere_import::primport_checklist::PRImportChecklist::OFFLINE_FEATURE,
            Status::Approximated,
            "clip3.mov",
        );
        r
    }

    #[test]
    fn the_report_card_rows_list_each_feature_worst_first() {
        let rows = ShellImportReportContent::rows_for_report(&three_file_report());
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].tone, crate::ReportTone::Red);
        assert!(rows[0].head.contains("Lumetri Color"), "{:?}", rows[0].head);
        assert_eq!(rows[2].tone, crate::ReportTone::Green);
    }

    #[test]
    fn the_checklist_card_counts_clips_and_flags_what_needs_attention() {
        let mut h = crate::test_support::shell();
        let session = crate::test_support::session();
        h.remember_import(three_file_report(), session.project(), "Cut.prproj");
        assert!(h.import_card_due(&session));
        let state = h.flow_env.import_checklist.as_ref().unwrap();
        let rows = ShellImportReportContent::rows_for_checklist(&state.checklist, false);
        assert!(rows.len() >= 3, "came over + dropped + missing: {}", rows.len());
        assert!(rows.iter().any(|r| r.tone == crate::ReportTone::Red));
        // "Show" on a row without clips says so.
        let item = state.checklist.items()[1].clone();
        h.show_affected_clip(&mut crate::test_support::session(), &item);
        assert!(
            h.take_events().iter().any(|e| matches!(e, ShellEvent::Status(l) if l == "This row has no clips to show."))
        );
    }

    #[test]
    fn save_report_keeps_the_card_open_and_queues_the_save() {
        let mut h = crate::test_support::shell();
        let report = three_file_report();
        let content = ShellImportReportContent::new(ShellImportReportContent::rows_for_report(&report));
        let flows = Rc::clone(&h.menu_flows);
        let mut d =
            ShellHost::import_report_dialog(content, "Imported Cut.prproj", "note", &report, "Cut.prproj", flows);
        d.press(SQDialogResponse(1));
        assert!(!d.finished());
        assert_eq!(h.menu_flows.borrow().len(), 1);
        assert!(matches!(&h.menu_flows.borrow()[0], ShellFlow::SaveImportReport(_, n) if n == "Cut.prproj"));
        d.press(SQDialogResponse(0));
        assert!(d.finished());
        let _ = &mut h;
    }

    #[test]
    fn the_report_file_is_named_after_the_import_and_holds_the_summary() {
        use sq_premiere_import::primport_report::Status;
        assert_eq!(ShellHost::import_report_file_name("Cut.prproj"), "Cut.prproj import report.txt");
        let mut report = PRImportReport::default();
        report.note("Lumetri", Status::Dropped, "not supported");
        report.note("Cross Dissolve", Status::Mapped, "");
        let dir = std::env::temp_dir().join(format!("sq-report-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("r.txt");
        std::fs::write(&path, report.summary()).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(text.lines().count(), 2);
        assert!(text.lines().next().unwrap().ends_with("1x Lumetri - not supported"), "{text}");
    }

    #[test]
    fn text_before_the_first_search_names_the_files() {
        let (title, detail) = ShellHost::relink_text(&[media("/a/one.mov")], 1, 0);
        assert_eq!(title, "1 media file is offline");
        assert!(detail.starts_with("Not found: one.mov."));
    }

    #[test]
    fn text_after_a_search_counts_found_files_and_cuts_the_list_at_four() {
        let missing: Vec<MediaRef> = (0..5).map(|i| media(&format!("/a/{i}.mov"))).collect();
        let (title, detail) = ShellHost::relink_text(&missing, 7, 1);
        assert_eq!(title, "2 of 7 found");
        assert_eq!(detail, "Still missing: 0.mov, 1.mov, 2.mov, 3.mov,…. Add another folder or click Done.");
    }

    /// A session whose Main sequence has two clips (at 1 s and 5 s) and a second, empty sequence active.
    fn two_clip_session() -> (EditorSession, sq_core_time::Id, [sq_core_time::Id; 2]) {
        use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
        use sq_core_time::{SequentialIds, Time, TimeRange};
        let (main, other, c1, c2) = (Id::from_u128(10), Id::from_u128(11), Id::from_u128(21), Id::from_u128(22));
        let len = TimeRange::new(Time::ZERO, Time::new(2, 1));
        let mut a = Clip::new(c1, "a", Id::from_u128(1), TrackKind::Video, len, Time::new(1, 1));
        a.id = c1;
        let mut b = Clip::new(c2, "b", Id::from_u128(1), TrackKind::Video, len, Time::new(5, 1));
        b.id = c2;
        let mut track = Track::new(Id::from_u128(30), TrackKind::Video);
        track.set_clips(vec![a, b]);
        let fmt = SequenceFormat::new(Time::new(1, 30));
        let tls =
            vec![Timeline::new(main, "Main", fmt.clone(), vec![track]), Timeline::new(other, "Other", fmt, vec![])];
        let mut ids = SequentialIds::default();
        let mut project = EditorSession::make_untitled(&mut ids);
        project.timelines = tls.into();
        let mut deps = sq_editor_session::SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-sh2"));
        deps.ids = Box::new(ids);
        let mut session = EditorSession::new(project, deps);
        session.set_active_timeline(other);
        (session, main, [c1, c2])
    }

    #[test]
    fn show_cycles_through_the_affected_clips_and_wraps() {
        use sq_premiere_import::primport_report::Location;
        let (mut session, main, [c1, c2]) = two_clip_session();
        let mut report = PRImportReport::default();
        report.note("Gaussian Blur", Status::Approximated, "radius scaled");
        for c in [c1, c2] {
            report.attach("Gaussian Blur", Status::Approximated, Location { timeline: main, clip: c });
        }
        let mut h = crate::test_support::shell();
        h.remember_import(report, session.project(), "Edit.prproj");
        let item = h
            .flow_env
            .import_checklist
            .as_ref()
            .unwrap()
            .checklist
            .items()
            .iter()
            .find(|i| i.count > 0 && !i.locations.is_empty())
            .unwrap()
            .clone();
        for (want, secs) in [(c1, 1), (c2, 5), (c1, 1)] {
            h.show_affected_clip(&mut session, &item);
            assert_eq!(session.active_timeline_id(), Some(main), "switches to the clip's sequence");
            assert_eq!(session.selection().iter().copied().collect::<Vec<_>>(), vec![want]);
            assert_eq!(session.playhead(), sq_core_time::Time::new(secs, 1));
        }
        let said: Vec<String> = h
            .take_events()
            .into_iter()
            .filter_map(|e| if let ShellEvent::Status(l) = e { Some(l) } else { None })
            .collect();
        assert!(
            said[0].contains("clip 1 of 2") && said[1].contains("clip 2 of 2") && said[2].contains("clip 1 of 2"),
            "{said:?}"
        );
    }

    #[test]
    fn import_checklist_menu_item_is_enabled_only_after_an_import() {
        let session = crate::test_support::session();
        let mut h = crate::test_support::shell();
        let mut s = crate::shell_menu_bar::ShellMenuState::default();
        h.fill_project_state(&session, &crate::shell_host::NoHooks, &mut s);
        assert!(!s.has_import_checklist, "a fresh shell has none");
        h.remember_import(three_file_report(), session.project(), "Cut.prproj");
        h.fill_project_state(&session, &crate::shell_host::NoHooks, &mut s);
        assert!(s.has_import_checklist);
    }

    #[test]
    fn the_relink_flow_from_the_project_footer_opens_its_dialog() {
        use crate::tests::Rig;
        let rig = Rig::new();
        rig.with(|r| {
            r.session.perform("Add media", None, |p| p.media.push(media("/nonexistent/missing.mp4")));
        });
        assert!(rig.with(|r| r.session.can_relink()), "the offline item counts as relinkable");
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::Project(crate::ShellAction::RelinkMedia)));
        rig.run_flows();
        assert!(rig.has_dialog(), "Reconnect Media asks where to look");
    }
}
