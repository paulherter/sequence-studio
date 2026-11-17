//! Replace Modes, Append to Main Track and Export Markers as CSV run from the menus and keys (Swift `SourceHost.command`,
//! `MarkerListHost`): precondition, dispatch through the shell, the effect and its undo.

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_app_shell::PanelFileChooser;
use sq_core_edit::timeline_replace_modes::ReplaceMode;
use sq_core_time::{Id, Time};
use sq_draw::InputModifiers;
use sq_runtime::FakeClock;
use sq_uikit::editor_command::EditorCommand as C;
use sq_uikit::panel_id::PanelID;
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;

struct SaveTo(PathBuf);
impl PanelFileChooser for SaveTo {
    fn choose_subtitles(&mut self) -> Option<PathBuf> {
        None
    }
    fn choose_srt_location(&mut self, _: &str) -> Option<PathBuf> {
        None
    }
    fn choose_frame_location(&mut self, _: &str, _: &[(&str, &str)]) -> Option<PathBuf> {
        None
    }
    fn choose_csv_location(&mut self, _: &str) -> Option<PathBuf> {
        Some(self.0.clone())
    }
    fn choose_luts(&mut self, _: bool) -> Vec<PathBuf> {
        Vec::new()
    }
}

fn rig_and_root(scenario: Scenario) -> (AppRoot, crate::test_rig::Rig, PathBuf) {
    let dir = crate::test_rig::unique_dir("sq-placement");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root_with_source(
        &dir,
        Arc::new(FakeClock::new()),
        DrawTheme::default(),
        crate::MonitorPicture::default(),
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
    )
    .expect("root");
    let mut rig = crate::test_rig::Rig::new(demo_session(scenario));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.shell.shell().focus = Some(PanelID::Timeline);
    (root, rig, dir)
}

fn last_status(rig: &crate::test_rig::Rig) -> String {
    rig.events
        .iter()
        .rev()
        .find_map(|e| if let AppEvent::Status(s) = e { Some(s.clone()) } else { None })
        .unwrap_or_default()
}

fn video_media(rig: &crate::test_rig::Rig) -> Vec<Id> {
    let t = rig.session.active_timeline().expect("sequence");
    t.tracks
        .iter()
        .flat_map(|tr| tr.clips())
        .filter(|c| c.kind == sq_core_model::TrackKind::Video)
        .map(|c| c.media)
        .collect()
}

#[test]
fn replace_mode_swaps_the_selected_clip_for_the_source_clip_and_undoes() {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::FastCut);
    let first = rig.session.active_timeline().expect("t").tracks[0].clips()[0].id;
    let before = video_media(&rig);
    assert_eq!(before[0], Id::from_u128(901));
    rig.session.select(BTreeSet::from([first]), BTreeSet::new());
    // No Source clip: the command says what to do and changes nothing.
    assert!(root.shell.command_enabled(&rig.session, C::ReplaceMode(ReplaceMode::FromStart)));
    assert!(root.shell.run_command(&mut rig.cx(), C::ReplaceMode(ReplaceMode::FromStart)));
    let mut lines = Vec::new();
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(last_status(&rig), "Open a clip in the Source monitor first (double-click it in the Project panel).");
    assert_eq!(video_media(&rig), before);
    // With the Source clip loaded the clip plays it, in one undo step named like the mode.
    assert!(root.source.as_mut().expect("source").open(&mut rig.cx(), Id::from_u128(902)));
    assert!(root.shell.run_command(&mut rig.cx(), C::ReplaceMode(ReplaceMode::FromStart)));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(video_media(&rig)[0], Id::from_u128(902));
    assert_eq!(rig.session.undo_name(), Some(ReplaceMode::FromStart.title()));
    rig.session.undo();
    assert_eq!(video_media(&rig), before);
    // Two clips selected: asked to pick one.
    let all: BTreeSet<Id> =
        rig.session.active_timeline().expect("t").tracks.iter().flat_map(|t| t.clips()).map(|c| c.id).collect();
    rig.session.select(all, BTreeSet::new());
    assert!(root.shell.run_command(&mut rig.cx(), C::ReplaceMode(ReplaceMode::FromEnd)));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(last_status(&rig), "Select one clip in the timeline to replace.");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn append_to_main_track_adds_the_source_clip_at_the_end_and_undoes() {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::FastCut);
    let before = video_media(&rig);
    assert!(root.source.as_mut().expect("source").open(&mut rig.cx(), Id::from_u128(902)));
    assert!(root.shell.command_enabled(&rig.session, C::AppendToMainTrack));
    assert!(root.shell.run_command(&mut rig.cx(), C::AppendToMainTrack));
    let mut lines = Vec::new();
    root.answer_timeline(&mut rig.cx(), &mut lines);
    let after = video_media(&rig);
    assert_eq!(after.len(), before.len() + 1, "{}", last_status(&rig));
    assert_eq!(after.last(), Some(&Id::from_u128(902)));
    assert_eq!(rig.session.undo_name(), Some("Append to Main Track"));
    rig.session.undo();
    assert_eq!(video_media(&rig), before);
    // A Normal sequence says to switch first and changes nothing.
    let (mut root, mut rig, dir2) = rig_and_root(Scenario::Plain);
    let plain = video_media(&rig);
    root.run_placement(&mut rig.cx(), C::AppendToMainTrack);
    assert_eq!(last_status(&rig), "Switch the sequence to Fast Cut first (Shift+G).");
    assert_eq!(video_media(&rig), plain);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&dir2);
}

#[test]
fn export_markers_csv_writes_the_markers_where_the_user_picks() {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::Plain);
    let mut lines = Vec::new();
    assert!(root.shell.run_command(&mut rig.cx(), C::ExportMarkersCSV));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(last_status(&rig), "There are no markers to export.");
    rig.session.add_marker_at_playhead();
    let file = dir.join("markers.csv");
    rig.services.panel_files = Box::new(SaveTo(file.clone()));
    assert!(root.shell.run_command(&mut rig.cx(), C::ExportMarkersCSV));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(last_status(&rig), "Exported markers.csv.");
    let text = std::fs::read_to_string(&file).expect("csv");
    assert!(text.lines().count() >= 2, "{text}");
    let _ = std::fs::remove_dir_all(&dir);
}

fn word(text: &str, i: i64) -> sq_core_model::CaptionWord {
    let ms = sq_core_time::Time::new(1, 1000);
    sq_core_model::CaptionWord {
        text: text.to_string(),
        range: sq_core_time::TimeRange::from_end(ms * (i * 500), ms * (i * 500 + 450)),
        confidence: None,
    }
}

#[test]
fn remove_filler_words_proposes_the_cuts_in_one_undo_step() {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::Plain);
    root.text = Some(crate::TextHost::new());
    let mut lines = Vec::new();
    // No captions yet and no transcription service: it says what is missing.
    assert!(root.shell.run_command(&mut rig.cx(), C::RemoveFillerWords));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(last_status(&rig), "Create captions first: the filler words come from the transcript.");
    // With timed caption words the fillers become proposed cuts.
    let r = sq_core_time::TimeRange::from_end(sq_core_time::Time::seconds(1), sq_core_time::Time::seconds(3));
    let item = sq_core_model::CaptionItem {
        id: Id::from_u128(7001),
        lines: vec!["so um this uh works".to_string()],
        range: r,
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: ["so", "um", "this", "uh", "works"].iter().enumerate().map(|(i, w)| word(w, i as i64)).collect(),
        position: None,
    };
    assert!(rig.session.add_captions(vec![item]));
    assert!(root.shell.run_command(&mut rig.cx(), C::RemoveFillerWords));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert!(last_status(&rig).starts_with("2 filler words marked ("), "{}", last_status(&rig));
    assert_eq!(rig.session.undo_name(), Some("Propose Cuts"));
    rig.session.undo();
    assert_ne!(rig.session.undo_name(), Some("Propose Cuts"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn disguise_voice_puts_the_effect_on_the_selected_audio_and_undoes() {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::Plain);
    root.text = Some(crate::TextHost::new());
    let mut lines = Vec::new();
    let audio: Vec<Id> = rig.session.selected_audio_clips().iter().map(|c| c.id).collect();
    assert!(!audio.is_empty());
    // Only video selected: asked for an audio clip.
    let video: BTreeSet<Id> = rig
        .session
        .active_timeline()
        .expect("t")
        .tracks
        .iter()
        .flat_map(|t| t.clips())
        .filter(|c| c.kind == sq_core_model::TrackKind::Video)
        .map(|c| c.id)
        .collect();
    rig.session.select(video, BTreeSet::new());
    root.run_placement(&mut rig.cx(), C::DisguiseVoice);
    assert_eq!(last_status(&rig), "Select an audio clip first.");
    rig.session.select(audio.into_iter().collect(), BTreeSet::new());
    assert!(root.shell.command_enabled(&rig.session, C::DisguiseVoice));
    assert!(root.shell.run_command(&mut rig.cx(), C::DisguiseVoice));
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert!(last_status(&rig).starts_with("Disguise Voice on "), "{}", last_status(&rig));
    assert_eq!(rig.session.undo_name(), Some("Disguise Voice"));
    rig.session.undo();
    assert_ne!(rig.session.undo_name(), Some("Disguise Voice"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A point (device pixels) over the first clip of the timeline panel, and that clip.
fn point_on_a_clip(root: &mut AppRoot, rig: &mut crate::test_rig::Rig) -> (f32, f32, Id) {
    root.sync(&rig.session);
    let scale = rig.cx().scale;
    let frame = root.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let panel = &mut root.timeline.inner().panel;
    let mut y = frame.min_y() + 4.0;
    while y < frame.max_y() {
        let mut x = frame.min_x() + 4.0;
        while x < frame.max_x() {
            let (px, py) = ((x * f64::from(scale)) as f32, (y * f64::from(scale)) as f32);
            if let Some(id) = panel.clip_id(px, py) {
                return (px, py, id);
            }
            x += 8.0;
        }
        y += 8.0;
    }
    panic!("no clip in the timeline panel");
}

fn drop_on_clip(shift: bool, option: bool) -> (String, Vec<Id>) {
    let (mut root, mut rig, dir) = rig_and_root(Scenario::FastCut);
    assert!(root.source.as_mut().expect("source").open(&mut rig.cx(), Id::from_u128(902)));
    rig.session.seek(Time::new(1, 3));
    let (x, y, clip) = point_on_a_clip(&mut root, &mut rig);
    let mut mods = InputModifiers::NONE;
    if option {
        mods = mods | InputModifiers::OPTION;
    }
    if shift {
        mods = mods | InputModifiers::SHIFT;
    }
    root.live_modifiers = mods;
    let ids = vec![Id::from_u128(902)];
    root.project_dragged(&mut rig.cx(), ids.clone(), DragPhase::Moved, (x, y));
    root.project_dragged(&mut rig.cx(), ids, DragPhase::Ended, (x, y));
    let t = rig.session.active_timeline().expect("t");
    let shown = t.tracks.iter().flat_map(|k| k.clips()).find(|c| c.id == clip).map(|c| format!("{c:?}"));
    let out = (format!("{:?} {:?}", shown, rig.session.last_error()), video_media(&rig));
    let _ = std::fs::remove_dir_all(&dir);
    out
}

#[test]
fn an_option_drop_replaces_the_clip_and_shift_lines_up_the_source_frame() {
    let (plain, plain_media) = drop_on_clip(false, false);
    let (replaced, media) = drop_on_clip(false, true);
    assert_ne!(plain_media, media, "Option replaces a clip instead of adding one");
    assert!(media.contains(&Id::from_u128(902)));
    assert_eq!(media.len(), plain_media.len() - 1, "{plain}");
    let (matched, _) = drop_on_clip(true, true);
    assert_ne!(replaced, matched, "Shift lines the Source frame up with the playhead");
}
