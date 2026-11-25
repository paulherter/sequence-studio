//! Ports of the Swift tests of ShellMarkerDialog, ShellTrimMode, ShellTimelineOps, ShellPasteMedia, the command fixes of
//! SharedCommandCoverage and the dialogs of this group, on the rig of `tests.rs`.

use super::*;
use crate::shell_sequence_dialogs::ShellSequenceSettings;
use crate::tests::{Rig, measure};
use sq_core_edit::cut_check::CutCheckPlatform;
use sq_core_model::{
    Clip, MarkerColor, Project, SequenceFormat, TimecodeDisplay, Timeline, TimelineEditMode, Track, TrackKind,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange, step_status};
use sq_draw::{DrawTheme, InputKey, InputModifiers};
use sq_editor_session::{EditorSession, PasteContent, SessionDeps};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::path::PathBuf;

fn f(n: i64) -> Time {
    Time::new(n, 30)
}

/// A session over a video clip of two seconds at 25 fps and an empty audio track (the Swift `ShellTimelineOpsTests` rig).
fn session_with_clip() -> (EditorSession, Id) {
    let mut ids = SequentialIds::default();
    let clip = Clip::new(
        ids.next_id(),
        "c",
        ids.next_id(),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(2, 1)),
        Time::ZERO,
    );
    let clip_id = clip.id;
    let mut video = Track::new(ids.next_id(), TrackKind::Video);
    video.overwrite(clip, &mut ids).expect("clip fits");
    let audio = Track::new(ids.next_id(), TrackKind::Audio);
    let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 25)), vec![video, audio]);
    let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-e"));
    deps.ids = Box::new(ids);
    (EditorSession::new(project, deps), clip_id)
}

fn run(c: EditorCommand, s: &mut EditorSession) -> Option<String> {
    ShellCommands::run(c, s, &MemorySettings::default(), &AudioRoleDefaults::standard())
}

use sq_editor_session::AudioRoleDefaults;
use sq_library::library_folder_store::MemorySettings;

fn clip_count(s: &EditorSession) -> usize {
    s.active_timeline().map_or(0, |t| t.tracks.iter().map(|tr| tr.clips().len()).sum())
}

mod markers {
    use super::*;

    fn marker_session() -> (EditorSession, Id) {
        let (mut s, _) = session_with_clip();
        let id = s.mark_at_playhead().expect("a marker").id;
        (s, id)
    }

    #[test]
    fn ok_writes_name_color_comment_and_duration() {
        let (mut s, id) = marker_session();
        let d = ShellHost::marker_dialog(id, None, &s).expect("dialog");
        assert_eq!(d.message_text, "Marker");
        let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
        let mut form = ShellHost::marker_form(&m, false, Time::new(1, 25));
        form.set("name", FormValue::Text("Hook".into()));
        form.set("color", FormValue::Index(1));
        form.set("comment", FormValue::Text("tighten".into()));
        form.set("duration", FormValue::Text("00:00:01:00".into()));
        ShellHost::apply_marker_dialog(&form, SQDialogResponse::FIRST, id, None, &mut s);
        let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
        assert!(m.name == "Hook" && m.color == MarkerColor::Red && m.comment == "tighten");
        assert_eq!(m.duration, Time::new(1, 1));
    }

    #[test]
    fn delete_marker_removes_it() {
        let (mut s, id) = marker_session();
        let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
        let form = ShellHost::marker_form(&m, false, Time::new(1, 25));
        ShellHost::apply_marker_dialog(&form, SQDialogResponse::THIRD, id, None, &mut s);
        assert!(s.active_timeline().is_some_and(|t| t.markers.iter().all(|m| m.id != id)));
        assert!(ShellHost::marker_dialog(id, None, &s).is_none());
    }

    #[test]
    fn the_color_row_carries_the_marker_color_dots() {
        let (s, id) = marker_session();
        let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
        let form = ShellHost::marker_form(&m, false, Time::new(1, 25));
        let dots = &form.dot_rows["color"];
        assert_eq!(dots.len(), 8);
        assert_eq!(dots[0], 0x30D158);
        assert_eq!(dots[1], DrawTheme::marker(MarkerColor::Red).rgb_hex());
    }

    #[test]
    fn a_clip_marker_has_no_duration_row() {
        let (s, id) = marker_session();
        let m = ShellHost::find_marker(id, None, s.active_timeline().expect("timeline")).expect("marker");
        let form = ShellHost::marker_form(&m, true, Time::new(1, 25));
        let ids: Vec<&str> = form
            .rows()
            .iter()
            .filter_map(|r| match r {
                crate::shell_form::Row::Field { id, .. } | crate::shell_form::Row::Segmented { id, .. } => {
                    Some(id.as_str())
                }
                _ => None,
            })
            .collect();
        assert_eq!(ids, vec!["name", "color", "comment"]);
    }
}

mod trim_mode {
    use super::*;

    /// Three clips on one targeted video track with an edit between each, the playhead near the first edit.
    fn rig() -> Rig {
        let rig = Rig::new();
        let mut ids = SequentialIds::default();
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        v.is_targeted = true;
        for start in [0, 60, 150] {
            let mut c =
                Clip::new(ids.next_id(), "c", ids.next_id(), TrackKind::Video, TimeRange::new(f(30), f(60)), f(start));
            c.media_duration = Some(f(300));
            v.overwrite(c, &mut ids).expect("clip fits");
        }
        let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 30)), vec![v]);
        let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-trim"));
        deps.ids = Box::new(ids);
        rig.with(|r| {
            r.session = EditorSession::new(project, deps);
            r.session.seek(f(58));
        });
        rig
    }

    #[test]
    fn toggle_opens_at_the_nearest_edit_and_closes_again() {
        let rig = rig();
        assert!(rig.execute(EditorCommand::ToggleTrimMode));
        assert!(rig.with(|r| r.shell.trim.is_active()));
        assert!(rig.execute(EditorCommand::ToggleTrimMode));
        assert!(!rig.with(|r| r.shell.trim.is_active()));
    }

    #[test]
    fn arrows_trim_only_while_trim_mode_is_on() {
        let rig = rig();
        rig.with(|r| r.shell.focus = Some(PanelID::Timeline));
        assert!(!rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepForward)));
        rig.execute(EditorCommand::ToggleTrimMode);
        let before = rig.with(|r| r.shell.trim.frames(&r.session));
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepForward)));
        assert!(rig.with(|r| r.shell.trim.frames(&r.session) != before || !r.shell.trim.note().is_empty()));
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::ToggleTrimType)));
        rig.with(|r| r.shell.take_events());
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::PlayPause)));
        assert!(rig.with(|r| r.shell.take_events()).contains(&ShellEvent::Status("Close Trim mode to play.".into())));
    }

    #[test]
    fn shift_arrow_trims_ten_frames_and_plain_arrow_one() {
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers as Modifiers};
        let map = CommandMap::sq_default();
        let key = |k: Key, m: Modifiers| map.command_for(&KeyBinding::new(k, m), Some(PanelID::Timeline));
        assert_eq!(key(Key::Right, Modifiers::SHIFT), Some(EditorCommand::StepForward5));
        assert_eq!(key(Key::Right, Modifiers::EMPTY), Some(EditorCommand::StepForward));
        let rig = rig();
        rig.with(|r| r.shell.focus = Some(PanelID::Timeline));
        rig.execute(EditorCommand::ToggleTrimMode);
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepForward5)));
        assert_eq!(rig.with(|r| r.shell.trim.note().to_string()), "Moved edit +10 frames");
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepBackward)));
        assert_eq!(rig.with(|r| r.shell.trim.note().to_string()), "Moved edit -1 frame");
    }

    #[test]
    fn trim_keys_are_for_the_timeline_and_program_only() {
        let rig = rig();
        rig.execute(EditorCommand::ToggleTrimMode);
        rig.with(|r| r.shell.focus = Some(PanelID::Project));
        assert!(!rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepForward)));
        rig.with(|r| r.shell.focus = Some(PanelID::ProgramMonitor));
        assert!(rig.cx(|h, cx| h.run_trim_command(cx, EditorCommand::StepForward)));
    }

    #[test]
    fn escape_leaves_trim_mode_before_anything_else() {
        let rig = rig();
        rig.execute(EditorCommand::ToggleTrimMode);
        let clip = rig.with(|r| r.session.active_timeline().expect("timeline").tracks[0].clips()[0].id);
        rig.with(|r| r.session.select([clip].into_iter().collect(), Default::default()));
        assert!(rig.key(InputKey::Escape, InputModifiers::NONE));
        assert!(!rig.with(|r| r.shell.trim.is_active()));
        // the selection waits for the next Esc
        assert!(!rig.with(|r| r.session.selection().is_empty()));
        assert!(rig.key(InputKey::Escape, InputModifiers::NONE));
        assert!(rig.with(|r| r.session.selection().is_empty()));
    }
}

mod timeline_ops {
    use super::*;

    #[test]
    fn clipboard_rows_copy_and_paste_and_say_what_is_missing() {
        let (mut s, clip) = session_with_clip();
        assert_eq!(run(EditorCommand::Copy, &mut s).as_deref(), Some("Select clips to copy."));
        assert_eq!(run(EditorCommand::Paste, &mut s).as_deref(), Some("Nothing to paste. Copy clips first."));
        s.select([clip].into_iter().collect(), Default::default());
        assert_eq!(run(EditorCommand::Copy, &mut s).as_deref(), Some(""));
        s.seek(Time::new(2, 1));
        assert_eq!(run(EditorCommand::Paste, &mut s).as_deref(), Some(""));
        assert_eq!(clip_count(&s), 2);
        assert_eq!(run(EditorCommand::Duplicate, &mut s).as_deref(), Some(""));
        assert_eq!(clip_count(&s), 3);
    }

    #[test]
    fn nudge_slide_and_slip_say_the_steps() {
        let (mut s, clip) = session_with_clip();
        assert_eq!(run(EditorCommand::SlideLeft, &mut s).as_deref(), Some("Select clips to slide."));
        s.select([clip].into_iter().collect(), Default::default());
        s.seek(Time::ZERO);
        assert_eq!(run(EditorCommand::NudgeRight, &mut s), Some(step_status::line("Nudge", step_status::SMALL)));
        assert_eq!(s.active_timeline().expect("timeline").tracks[0].clips()[0].timeline().start, Time::new(1, 25));
        assert_eq!(run(EditorCommand::NudgeLeft5, &mut s), Some(step_status::line("Nudge", -step_status::LARGE)));
    }

    #[test]
    fn tracks_markers_and_fast_cut_rows() {
        let (mut s, _) = session_with_clip();
        assert_eq!(run(EditorCommand::AddVideoTrack, &mut s).as_deref(), Some(""));
        assert_eq!(
            s.active_timeline().expect("timeline").tracks.iter().filter(|t| t.kind == TrackKind::Video).count(),
            2
        );
        assert_eq!(run(EditorCommand::ClearAllMarkers, &mut s).as_deref(), Some("There are no markers to clear."));
        assert_eq!(run(EditorCommand::AddMarker, &mut s).as_deref(), Some(""));
        assert_eq!(s.active_timeline().expect("timeline").markers.len(), 1);
        assert_eq!(
            run(EditorCommand::MoveClipLeft, &mut s).as_deref(),
            Some("Switch the sequence to Fast Cut first (Shift+G).")
        );
        assert_eq!(run(EditorCommand::TrimToRange, &mut s).as_deref(), Some("Mark In and Out first."));
    }

    #[test]
    fn view_rows_stay_with_the_host() {
        let (mut s, _) = session_with_clip();
        assert_eq!(run(EditorCommand::TrimForward, &mut s), None);
        assert_eq!(run(EditorCommand::ToggleSnapping, &mut s), None);
    }

    #[test]
    fn audio_gain_without_a_clip_says_so() {
        let (mut s, _) = session_with_clip();
        assert_eq!(run(EditorCommand::AudioGainUp, &mut s).as_deref(), Some("Select an audio clip first."));
    }

    #[test]
    fn beat_edits_need_beat_markers() {
        let (mut s, _) = session_with_clip();
        let line = Some("Run Markers on Beat on the music first.".to_string());
        assert_eq!(run(EditorCommand::CutToBeats, &mut s), line);
        assert_eq!(run(EditorCommand::SnapToBeats, &mut s), line);
    }

    /// The menu rows of `s` as the host builds them: every disabled row carries the reason the session gives.
    fn menu_rows(s: &EditorSession) -> Vec<crate::shell_menu_bar::ShellMenu> {
        use crate::shell_menu_bar::{ShellMenuBar, ShellMenuState};
        let mut state = ShellMenuState::default();
        state.reasons.extend(sq_editor_session::EditorLookCommands::disabled_reasons(s));
        let facts = crate::shell_commands::ShellPanelFacts::default();
        let validate = |c: EditorCommand| ShellCommands::enabled(c, s, &facts);
        ShellMenuBar::build(
            &state,
            &sq_uikit::command_map::CommandMap::premiere_default(),
            sq_os::Platform::Mac,
            Some(&validate),
            std::rc::Rc::new(|_| {}),
        )
    }

    fn find_row<'a>(
        items: &'a [sq_uikit::sqmenu_model::SQMenuItem],
        title: &str,
    ) -> Option<&'a sq_uikit::sqmenu_model::SQMenuItem> {
        items.iter().find_map(|i| {
            if i.title == title { Some(i) } else { i.submenu.as_deref().and_then(|sub| find_row(sub, title)) }
        })
    }

    #[test]
    fn cut_to_beats_is_greyed_with_its_reason_and_the_status_line_says_the_same() {
        let (mut s, _) = session_with_clip();
        let why = "Run Markers on Beat on the music first.";
        let menus = menu_rows(&s);
        let row = menus.iter().find_map(|m| find_row(&m.items, "Cut to Beats")).expect("Cut to Beats row");
        assert!(!row.is_enabled);
        assert_eq!(row.help.as_deref(), Some(why));
        assert_eq!(run(EditorCommand::CutToBeats, &mut s).as_deref(), Some(why));
    }

    #[test]
    fn fit_with_blurred_fill_and_split_screen_say_why_in_a_plain_project() {
        let (s, _) = session_with_clip();
        let menus = menu_rows(&s);
        let fit = menus.iter().find_map(|m| find_row(&m.items, "Fit with Blurred Fill")).expect("Fit row");
        assert!(!fit.is_enabled);
        assert_eq!(fit.help.as_deref(), Some("Select a video clip whose shape differs from the sequence frame."));
        let split = menus.iter().find_map(|m| find_row(&m.items, "Side by Side 50/50")).expect("Split Screen row");
        assert!(!split.is_enabled);
        assert_eq!(split.help.as_deref(), Some("Select 2 video clips on stacked tracks for a split screen."));
    }

    #[test]
    fn switch_angle_without_an_angles_clip_says_so() {
        let (mut s, _) = session_with_clip();
        assert_eq!(
            run(EditorCommand::SwitchAngle(2), &mut s).as_deref(),
            Some("No Angles clip is selected or under the playhead.")
        );
    }

    #[test]
    fn revert_needs_a_file_and_changes_and_range_commands_need_a_range() {
        let (mut s, _) = session_with_clip();
        let p = ShellPanelFacts::default();
        assert!(!ShellCommands::enabled(EditorCommand::Revert, &s, &p));
        assert!(!ShellCommands::enabled(EditorCommand::Lift, &s, &p));
        s.mark_in();
        assert!(ShellCommands::enabled(EditorCommand::Lift, &s, &p));
        // dirty but never saved
        assert!(!ShellCommands::enabled(EditorCommand::Revert, &s, &p));
        // no source loaded
        assert!(!ShellCommands::enabled(EditorCommand::Insert, &s, &p));
    }

    #[test]
    fn edit_rows_follow_the_selection() {
        let (mut s, clip) = session_with_clip();
        let p = ShellPanelFacts::default();
        assert!(!ShellCommands::enabled(EditorCommand::Duplicate, &s, &p));
        assert!(!ShellCommands::enabled(EditorCommand::Delete, &s, &p));
        s.select([clip].into_iter().collect(), Default::default());
        assert!(ShellCommands::enabled(EditorCommand::Duplicate, &s, &p));
        assert!(ShellCommands::enabled(EditorCommand::Delete, &s, &p));
        assert!(ShellCommands::enabled(EditorCommand::SetToFrameSize, &s, &p));
    }
}

mod paste_media {
    use super::*;

    /// Hooks that report a clipboard.
    struct Clipboard(Option<PasteContent>);

    impl ShellHooks for Clipboard {
        fn media_clipboard(&self) -> Option<PasteContent> {
            self.0.clone()
        }
    }

    fn files() -> Option<PasteContent> {
        Some(PasteContent::new(vec![PathBuf::from("/a.mov")], None))
    }

    fn enabled(rig: &Rig, hooks: &Clipboard, focus: PanelID) -> bool {
        rig.with(|r| {
            r.shell.focus = Some(focus);
            r.shell.menu_enabled(&r.session, hooks, EditorCommand::Paste)
        })
    }

    #[test]
    fn paste_is_off_without_a_clipboard_reader() {
        let rig = Rig::new();
        assert!(!enabled(&rig, &Clipboard(None), PanelID::Project));
    }

    #[test]
    fn files_on_the_clipboard_enable_paste_in_project_and_timeline_only() {
        let rig = Rig::new();
        let hooks = Clipboard(files());
        assert!(enabled(&rig, &hooks, PanelID::Project));
        assert!(enabled(&rig, &hooks, PanelID::Timeline));
        assert!(!enabled(&rig, &hooks, PanelID::EffectControls));
    }

    #[test]
    fn an_image_enables_paste_and_an_empty_clipboard_does_not() {
        let rig = Rig::new();
        assert!(enabled(&rig, &Clipboard(Some(PasteContent::new(Vec::new(), Some(vec![1])))), PanelID::Project));
        assert!(!enabled(&rig, &Clipboard(Some(PasteContent::new(Vec::new(), None))), PanelID::Project));
    }

    #[test]
    fn the_facts_of_a_menu_build_do_not_outlive_it() {
        let rig = Rig::new();
        let (session, _) = session_with_clip();
        let hooks = Clipboard(files());
        rig.with(|r| {
            r.session = session;
            let before = r.shell.current_facts(&r.session, &hooks).has_angles_clip;
            assert!(!r.shell.menus(&r.session, &hooks).is_empty());
            r.shell.panels.panels_loaded = true;
            assert!(r.shell.current_facts(&r.session, &hooks).panels_loaded, "a stale memo hid the new fact");
            assert_eq!(r.shell.current_facts(&r.session, &hooks).has_angles_clip, before);
        });
    }

    #[test]
    fn own_clip_data_keeps_priority_over_the_clipboard() {
        let rig = Rig::new();
        let (session, clip) = session_with_clip();
        rig.with(|r| {
            r.session = session;
            r.session.select([clip].into_iter().collect(), Default::default());
            assert!(r.session.copy_selection());
        });
        let hooks = Clipboard(files());
        rig.with(|r| r.shell.focus = Some(PanelID::Timeline));
        assert!(!rig.with(|r| r.shell.current_facts(&r.session, &hooks).can_paste_media));
        // the own clipboard pastes
        assert!(enabled(&rig, &hooks, PanelID::Timeline));
    }

    /// A host with cheap facts: the menu must ask only the offer, never the data.
    struct Cheap(std::cell::Cell<u32>);

    impl ShellHooks for Cheap {
        fn media_clipboard(&self) -> Option<PasteContent> {
            self.0.set(self.0.get() + 1);
            Some(PasteContent::new(Vec::new(), Some(vec![0; 4_000_000])))
        }
        fn media_clipboard_offer(&self) -> Option<sq_editor_session::PasteOffer> {
            Some(sq_editor_session::PasteOffer { has_files: false, has_image: true })
        }
    }

    #[test]
    fn menu_refresh_with_a_big_picture_does_not_read_the_clipboard() {
        let rig = Rig::new();
        let hooks = Cheap(std::cell::Cell::new(0));
        rig.with(|r| r.shell.focus = Some(PanelID::Project));
        assert!(rig.with(|r| r.shell.menu_enabled(&r.session, &hooks, EditorCommand::Paste)));
        rig.with(|r| {
            let _ = r.shell.menus(&r.session, &hooks);
            let _ = r.shell.refresh_menus(&r.session, &hooks);
        });
        assert_eq!(hooks.0.get(), 0, "image data is read only when the user pastes");
    }

    /// Hooks whose clipboard read is a worker job (the gate lets the test finish it when it wants).
    struct Job(std::cell::RefCell<Option<std::sync::mpsc::Receiver<()>>>);

    impl ShellHooks for Job {
        fn media_clipboard_offer(&self) -> Option<sq_editor_session::PasteOffer> {
            Some(sq_editor_session::PasteOffer { has_files: true, has_image: false })
        }
        fn media_clipboard_job(&self) -> Option<Box<dyn FnOnce() -> PasteContent + Send>> {
            let gate = self.0.borrow_mut().take()?;
            Some(Box::new(move || {
                let _ = gate.recv();
                PasteContent::new(vec![PathBuf::from("/b.mov")], None)
            }))
        }
    }

    fn poll_until_done(rig: &Rig, hooks: &mut Job) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while rig.with(|r| r.shell.pending_paste_waits()) && std::time::Instant::now() < deadline {
            rig.with(|r| {
                let mut ui = sq_draw::UiCx::new();
                let mut cx = ShellCx { session: &mut r.session, measure: measure(), ui: &mut ui, hooks };
                r.shell.poll_paste(&mut cx);
            });
            std::thread::yield_now();
        }
    }

    #[test]
    fn a_worker_paste_imports_once_into_the_panel_it_was_made_in_and_a_second_paste_waits() {
        let rig = Rig::new();
        rig.with(|r| r.shell.focus = Some(PanelID::Project));
        let (open, gate) = std::sync::mpsc::channel();
        let mut hooks = Job(std::cell::RefCell::new(Some(gate)));
        let paste = |rig: &Rig, hooks: &mut Job| {
            rig.with(|r| {
                let mut ui = sq_draw::UiCx::new();
                let mut cx = ShellCx { session: &mut r.session, measure: measure(), ui: &mut ui, hooks };
                r.shell.paste_media(&mut cx)
            })
        };
        assert!(paste(&rig, &mut hooks));
        assert!(rig.with(|r| r.shell.pending_paste_waits()));
        // a second Paste only says it waits; then focus moves while the read runs
        assert!(paste(&rig, &mut hooks));
        rig.with(|r| r.shell.focus = Some(PanelID::EffectControls));
        assert!(rig.with(|r| r.shell.take_flows()).is_empty(), "nothing imported before the read is done");
        open.send(()).expect("gate");
        poll_until_done(&rig, &mut hooks);
        assert_eq!(rig.with(|r| r.shell.take_flows()), vec![ShellFlow::ImportMixed(vec![PathBuf::from("/b.mov")])]);
        poll_until_done(&rig, &mut hooks);
        assert!(rig.with(|r| r.shell.take_flows()).is_empty(), "the result is delivered once");
    }

    #[test]
    fn pasting_files_starts_the_import() {
        let rig = Rig::new();
        rig.with(|r| r.shell.focus = Some(PanelID::Project));
        let mut hooks = Clipboard(files());
        let took = rig.with(|r| {
            let mut ui = sq_draw::UiCx::new();
            let mut cx = ShellCx { session: &mut r.session, measure: measure(), ui: &mut ui, hooks: &mut hooks };
            r.shell.paste_media(&mut cx)
        });
        assert!(took);
        assert_eq!(rig.with(|r| r.shell.take_flows()), vec![ShellFlow::ImportMixed(vec![PathBuf::from("/a.mov")])]);
    }
}

mod sequence_settings {
    use super::*;
    use sq_core_model::ChannelLayout;
    use sq_core_model::sequence_settings::SequenceSettings;

    fn settings() -> SequenceSettings {
        SequenceSettings {
            name: "Main".into(),
            format: SequenceFormat::new(Time::new(1001, 30000)),
            delivery_target: None,
            edit_mode: TimelineEditMode::Normal,
            timecode_start: Time::ZERO,
            timecode_display: TimecodeDisplay::Timecode,
            preview_quality: None,
            channel_layout: ChannelLayout::Stereo,
        }
    }

    /// A value the user changed: stored, then the form's reaction runs.
    fn change(form: &mut crate::shell_form::ShellForm, id: &str, v: FormValue) {
        form.set(id, v.clone());
        form.notify(id, v);
    }

    #[test]
    fn a_new_sequence_form_has_no_working_rows() {
        let f = ShellSequenceSettings::make(&settings(), true, None, None);
        assert!(f.form.index("channels").is_none() && f.form.text("start").is_none());
        assert!(f.form.text("name").as_deref() == Some("Main"));
    }

    #[test]
    fn the_preset_follows_the_size_and_rate_fields() {
        let mut f = ShellSequenceSettings::make(&settings(), false, None, None);
        change(&mut f.form, "width", FormValue::Number(1234.0));
        assert_eq!(f.form.index("preset"), Some(0), "an odd size is Custom");
        assert!(f.usable.get());
    }

    #[test]
    fn a_size_out_of_range_or_a_bad_start_keeps_the_sheet_open() {
        let mut f = ShellSequenceSettings::make(&settings(), false, None, None);
        change(&mut f.form, "width", FormValue::Number(0.0));
        assert!(!f.usable.get());
        f.form.set("width", FormValue::Number(1920.0));
        change(&mut f.form, "start", FormValue::Text("nonsense".into()));
        assert!(!f.usable.get());
    }

    #[test]
    fn the_answer_carries_the_edited_settings() {
        let mut f = ShellSequenceSettings::make(&settings(), false, None, None);
        f.form.set("name", FormValue::Text("Cut".into()));
        f.form.set("mode", FormValue::Index(1));
        change(&mut f.form, "channels", FormValue::Index(1));
        let a = ShellSequenceSettings::answer(&mut f.state.borrow_mut(), &f.form, &settings(), None).expect("answer");
        assert_eq!(a.settings.name, "Cut");
        assert_eq!(a.settings.edit_mode, TimelineEditMode::Magnetic);
        assert_eq!(a.settings.channel_layout, ChannelLayout::Mono);
        assert_eq!(a.ducking, None);
    }

    /// The Frame Size pair with its swap button is wider than a dialog card's control slot: it used to start at the
    /// slot and run past the card (the height field 5 pt over its edge, the swap button hidden behind it).
    #[test]
    fn the_frame_size_pair_stays_inside_the_dialog_card() {
        use crate::shell_dialog::DialogForm;
        use sq_uikit::controls_grid::CGPoint;
        for (is_new, width, label) in [(true, 502.0, 96.0), (false, 600.0, 104.0)] {
            let mut f = ShellSequenceSettings::make(&settings(), is_new, None, None).form;
            f.set_fixed_label_column(Some(label));
            f.set_kit_cards(true);
            f.layout_at(CGPoint::new(0.0, 0.0), width, &measure());
            // The kit card: 20 pad + 12 side on each side.
            let right = width - 32.0;
            // Captions are text lines across the card; every control box ends at the card's inner edge.
            for (k, c) in f.control_frames().iter().enumerate().filter(|(_, c)| c.height > 20.0) {
                assert!(c.max_x() <= right + 0.5, "{width}: control {k} ends at {} past {right}", c.max_x());
            }
            let s = f.scrub_frames();
            let (w, h) = (s["width"], s["height"]);
            assert!(h.max_x() <= right + 0.5 && w.min_x() > 32.0, "{width}: {w:?} {h:?}");
            assert!(w.max_x() < h.min_x(), "{width}: the fields keep apart");
        }
    }
}

mod view_commands {
    use super::*;
    use sq_core_model::BinItemRef;

    fn status(rig: &Rig) -> Vec<String> {
        rig.with(|r| r.shell.take_events())
            .into_iter()
            .filter_map(|e| if let ShellEvent::Status(s) = e { Some(s) } else { None })
            .collect()
    }

    #[test]
    fn selection_follows_playhead_toggles_and_is_remembered() {
        let rig = Rig::new();
        let before = rig.with(|r| r.session.selection_follows_playhead());
        assert!(rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ToggleSelectionFollowsPlayhead)));
        let on = !before;
        assert_eq!(rig.with(|r| r.session.selection_follows_playhead()), on);
        let line = if on { "Selection follows playhead on" } else { "Selection follows playhead off" };
        assert_eq!(status(&rig), vec![line.to_string()]);
        assert_eq!(rig.with(|r| r.shell.setting_flag("sq.selectionFollowsPlayhead")), on);
        let checked =
            rig.with(|r| r.shell.view_checks(&r.session)).contains(&EditorCommand::ToggleSelectionFollowsPlayhead);
        assert_eq!(checked, on);
    }

    #[test]
    fn interface_size_steps_and_resets() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::UiScaleLarger));
        assert_eq!(status(&rig), vec!["Interface size 110 %".to_string()]);
        rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::UiScaleReset));
        assert_eq!(status(&rig), vec!["Interface size 100 %".to_string()]);
    }

    #[test]
    fn the_project_list_rows_belong_to_the_host() {
        let rig = Rig::new();
        assert!(!rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ProjectListView)));
        assert!(!rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ToggleHoverScrub)));
    }

    #[test]
    fn replace_from_project_needs_one_clip_and_one_item() {
        let rig = Rig::new();
        assert!(rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ReplaceClipFromProject)));
        assert_eq!(status(&rig), vec!["Select one clip in the timeline to replace.".to_string()]);
        let (session, clip) = session_with_clip();
        rig.with(|r| {
            r.session = session;
            r.session.select([clip].into_iter().collect(), Default::default());
        });
        assert!(rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ReplaceClipFromProject)));
        assert_eq!(status(&rig), vec!["Select one item in the Project panel to replace with.".to_string()]);
        rig.with(|r| r.shell.project_selection = vec![BinItemRef::Bin(Id::from_u128(9))]);
        assert!(rig.cx(|h, cx| h.perform_view_command(cx, EditorCommand::ReplaceClipFromProject)));
        assert_eq!(status(&rig), vec!["Select one item in the Project panel to replace with.".to_string()]);
    }
}

mod quick_apply {
    use super::*;
    use crate::{QuickApplyEvent, QuickApplyPopup};
    use sq_draw::ui_cx::DrawCursor;
    use sq_draw::{InputEvent, UiCx};
    use sq_editor_session::{QuickApplyAction, QuickApplyItem, QuickApplyModel};
    use sq_library::library_folder_store::MemorySettings;
    use sq_uikit::controls_grid::CGRect;

    fn popup() -> QuickApplyPopup {
        let items = vec![
            QuickApplyItem::new("a", "Alpha", "Effect", QuickApplyAction::Effect("alpha".into())),
            QuickApplyItem::new("b", "Beta", "Effect", QuickApplyAction::Effect("beta".into())),
        ];
        let mut p = QuickApplyPopup::new(QuickApplyModel::new(items, Box::new(MemorySettings::default())));
        p.open(CGRect::new(0.0, 0.0, 1000.0, 700.0));
        p
    }

    fn key(p: &mut QuickApplyPopup, k: InputKey) -> bool {
        p.handle(&InputEvent::KeyDown { key: k, modifiers: InputModifiers::NONE }, 1.0, false, &mut UiCx::new())
    }

    #[test]
    fn the_card_is_centered_at_28_percent_and_fits_the_rows() {
        let p = popup();
        let r = p.frame();
        assert_eq!(r.width, 640.0);
        assert!((r.min_y() - 196.0).abs() < 1e-9);
        assert_eq!(r.min_x(), 180.0);
        assert_eq!(r.height, 52.0 + 2.0 * 28.0 + 10.0);
    }

    #[test]
    fn dragging_the_card_background_moves_the_palette_inside_the_window() {
        let mut p = popup();
        let before = p.frame();
        // The strip right of the field's text height, above the field: the card's own background.
        let (gx, gy) = (before.min_x() + 4.0, before.min_y() + 2.0);
        let mut ui = UiCx::new();
        assert!(p.handle(
            &InputEvent::MouseDown { x: gx as f32, y: gy as f32, modifiers: InputModifiers::NONE },
            1.0,
            false,
            &mut ui
        ));
        assert!(p.take_events().is_empty(), "a press on the card's edge strip does not close it");
        p.handle(&InputEvent::dragged((gx + 50.0) as f32, (gy + 30.0) as f32), 1.0, false, &mut ui);
        p.handle(&InputEvent::MouseUp { x: (gx + 50.0) as f32, y: (gy + 30.0) as f32 }, 1.0, false, &mut ui);
        let after = p.frame();
        assert_eq!((after.min_x() - before.min_x(), after.min_y() - before.min_y()), (50.0, 30.0));
        // Dragged far out, the card stays 8 pt inside the window.
        p.handle(
            &InputEvent::MouseDown {
                x: (after.min_x() + 4.0) as f32,
                y: (after.min_y() + 2.0) as f32,
                modifiers: InputModifiers::NONE,
            },
            1.0,
            false,
            &mut ui,
        );
        p.handle(&InputEvent::dragged(5000.0, 5000.0), 1.0, false, &mut ui);
        let far = p.frame();
        assert!(far.max_x() <= 1000.0 - 8.0 + 1e-9 && far.min_y() <= 700.0 - 8.0 - 52.0 + 1e-9, "{far:?}");
    }

    /// A press at `x`, `y` points on a screen at `scale` device pixels per point.
    fn press(p: &mut QuickApplyPopup, ui: &mut UiCx, (x, y): (f64, f64), scale: f32) -> bool {
        let e = InputEvent::MouseDown { x: x as f32 * scale, y: y as f32 * scale, modifiers: InputModifiers::NONE };
        ui.hover.begin_event(&e);
        p.handle(&e, scale, false, ui)
    }

    #[test]
    fn the_grip_strip_drags_the_card_exactly_with_the_pointer_on_every_event() {
        for scale in [1.0_f32, 1.5, 2.0] {
            let mut p = popup();
            let mut ui = UiCx::new();
            let start = p.frame();
            // The grip bar sits in the middle of the strip on top; the press is 7 pt right and 5 pt below the corner.
            let down = (start.mid_x() + 7.0, start.min_y() + 5.0);
            assert!(press(&mut p, &mut ui, down, scale));
            assert!(p.take_events().is_empty(), "a press on the grip does not close or choose");
            let grab = (down.0 - start.min_x(), down.1 - start.min_y());
            // Every drag event puts the card at the pointer minus the grab offset, with no trailing step in between.
            for (dx, dy) in [(1.0, 0.0), (3.5, -2.0), (40.0, 25.0), (-60.0, 90.0), (0.25, 0.25)] {
                let at = (down.0 + dx, down.1 + dy);
                let e = InputEvent::dragged(at.0 as f32 * scale, at.1 as f32 * scale);
                ui.hover.begin_event(&e);
                p.handle(&e, scale, false, &mut ui);
                let f = p.frame();
                assert!(
                    (f.min_x() - (at.0 - grab.0)).abs() < 1e-4 && (f.min_y() - (at.1 - grab.1)).abs() < 1e-4,
                    "scale {scale}: card {f:?} for pointer {at:?}"
                );
                assert_eq!(ui.hover.cursor, Some(DrawCursor::ClosedHand), "the closed hand while it moves");
            }
        }
    }

    #[test]
    fn the_hand_cursor_shows_on_the_grip_and_not_on_a_row_or_the_field() {
        let mut p = popup();
        let mut ui = UiCx::new();
        let f = p.frame();
        let mut hover = |p: &mut QuickApplyPopup, at: (f64, f64)| {
            let e = InputEvent::MouseMoved { x: at.0 as f32, y: at.1 as f32 };
            ui.hover.begin_event(&e);
            p.handle(&e, 1.0, false, &mut ui);
            ui.hover.cursor
        };
        assert_eq!(hover(&mut p, (f.mid_x(), f.min_y() + 6.0)), Some(DrawCursor::OpenHand));
        assert_eq!(hover(&mut p, (f.mid_x(), f.min_y() + 30.0)), None, "the search field keeps its own cursor");
        assert_eq!(hover(&mut p, (f.mid_x(), f.min_y() + 52.0 + 14.0)), None, "a row is no handle");
    }

    #[test]
    fn a_press_in_the_search_field_does_not_start_a_drag() {
        let mut p = popup();
        let mut ui = UiCx::new();
        let before = p.frame();
        assert!(press(&mut p, &mut ui, (before.mid_x(), before.min_y() + 30.0), 1.0));
        p.handle(&InputEvent::dragged(before.mid_x() as f32 + 80.0, before.min_y() as f32 + 90.0), 1.0, false, &mut ui);
        assert_eq!(p.frame(), before);
    }

    #[test]
    fn down_then_return_chooses_the_second_row_and_closes() {
        let mut p = popup();
        assert!(key(&mut p, InputKey::Down));
        assert!(key(&mut p, InputKey::Enter));
        let events = p.take_events();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0], QuickApplyEvent::Close);
        assert!(matches!(&events[1], QuickApplyEvent::Choose(item, None) if item.id == "b"));
    }

    #[test]
    fn escape_and_a_press_outside_close_it() {
        let mut p = popup();
        assert!(key(&mut p, InputKey::Escape));
        assert_eq!(p.take_events(), vec![QuickApplyEvent::Close]);
        let down = InputEvent::MouseDown { x: 5.0, y: 5.0, modifiers: InputModifiers::NONE };
        assert!(p.handle(&down, 1.0, false, &mut UiCx::new()));
        assert_eq!(p.take_events(), vec![QuickApplyEvent::Close]);
    }

    #[test]
    fn command_keys_belong_to_the_palette_never_to_the_editor() {
        // The palette owns the keyboard: a chord is a text edit or nothing, and the shell (not the palette) closes it on
        // its own key before the event gets here.
        let mut p = popup();
        for modifiers in [InputModifiers::OPTION, InputModifiers::COMMAND, InputModifiers::CONTROL] {
            let e = InputEvent::KeyDown { key: InputKey::Space, modifiers };
            assert!(p.handle(&e, 1.0, false, &mut UiCx::new()), "{modifiers:?} is taken");
        }
    }
}

mod marker_dialog_and_cut_check {
    use super::*;

    #[test]
    fn add_and_edit_opens_the_marker_dialog_and_m_twice_does_too() {
        let rig = Rig::new();
        assert!(rig.execute(EditorCommand::AddMarker));
        assert!(rig.with(|r| r.shell.take_flows()).is_empty(), "a first M only adds the marker");
        let id = rig.with(|r| r.session.marker_at_playhead()).expect("a marker was added");
        assert!(rig.execute(EditorCommand::AddMarker));
        assert_eq!(
            rig.with(|r| r.shell.take_flows()),
            vec![ShellFlow::EditMarker(id)],
            "M on a marker opens its dialog"
        );
        assert!(rig.execute(EditorCommand::EditMarker));
        assert_eq!(rig.with(|r| r.shell.take_flows()), vec![ShellFlow::EditMarker(id)]);
        rig.with(|r| r.session.undo());
        let _ = rig.with(|r| r.shell.take_flows());
        assert!(rig.execute(EditorCommand::AddAndEditMarker));
        let flows = rig.with(|r| r.shell.take_flows());
        assert!(matches!(flows.as_slice(), [ShellFlow::EditMarker(_)]), "{flows:?}");
    }

    #[test]
    fn check_cuts_gets_a_caption_box_function() {
        // The box itself needs the bundled fonts (not in the unit-test environment); the wiring is what is checked: an
        // active sequence yields a box function and the preview runs with it.
        let rig = Rig::new();
        assert!(rig.with(|r| ShellHost::cut_check_preview(&r.session, CutCheckPlatform::Tiktok)).is_some());
    }
}

mod history_rows {
    use super::*;

    #[test]
    fn the_history_dialog_lists_every_step() {
        let (mut s, _) = session_with_clip();
        for _ in 0..30 {
            run(EditorCommand::AddVideoTrack, &mut s);
        }
        let titles = ShellHost::history_options(&s);
        assert!(titles.len() > 30, "{} steps", titles.len());
        assert_eq!(titles.len(), s.history_list().rows.len());
        assert!(ShellHost::history_dialog(&s).form.is_some());
    }
}
