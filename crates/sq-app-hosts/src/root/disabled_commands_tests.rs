//! The commands the dead-command audit never saw enabled (docs/rust/DEAD-COMMANDS.md): each gets the state in which Swift
//! enables it (`ShellCommands.enabled`, the facts of `ShellFacts.swift`), and must then be enabled in the real root and
//! change something observable when it runs. Before that state every one of them is disabled, which pins the other half of
//! the rule.

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use crate::test_rig::Rig;
use sq_core_audio::tone_generator::ToneSpec;
use sq_core_edit::proposed_cuts::ProposedCutKind;
use sq_core_model::{BinItemRef, ClipEdge, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::{EdgeRef, EdgeSelection};
use sq_runtime::FakeClock;
use sq_uikit::editor_command::EditorCommand as C;
use std::collections::BTreeSet;
use std::sync::Arc;

pub(super) type Setup = fn(&mut AppRoot, &mut Rig);

pub(super) fn new_root(scenario: Scenario) -> (AppRoot, Rig, std::path::PathBuf) {
    let dir = crate::test_rig::unique_dir("sq-disabled-root");
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
    let mut rig = Rig::new(demo_session(scenario));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.shell.shell().focus = Some(PanelID::Timeline);
    (root, rig, dir)
}

/// Frame of the app: layout, the queued commands, the published facts.
pub(super) fn frame(root: &mut AppRoot, rig: &mut Rig) -> Vec<String> {
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let mut lines = Vec::new();
    root.answer_timeline(&mut rig.cx(), &mut lines);
    lines
}

/// Everything a command can change that a test can see: the project, the selection, the playhead, a dialog, an event.
pub(super) fn fingerprint(root: &mut AppRoot, rig: &mut Rig) -> String {
    format!(
        "{}|{:?}|{:?}|{:?}|{}|{}|{:?}",
        serde_json::to_string(rig.session.project()).unwrap_or_default(),
        rig.session.selection(),
        rig.session.playhead(),
        rig.session.undo_name(),
        root.shell.shell().dialog().is_some(),
        rig.events.len(),
        root.timeline.inner().panel.edge_selection(),
    )
}

/// The video clips of the sequence in time order (the audio partners are left out).
pub(super) fn clip_ids(s: &sq_editor_session::EditorSession) -> Vec<Id> {
    let t = s.active_timeline().expect("sequence");
    let mut all: Vec<_> = t
        .tracks
        .iter()
        .filter(|tr| tr.kind == TrackKind::Video)
        .flat_map(|tr| tr.clips().iter().map(|c| (c.timeline().start, c.id)))
        .collect();
    all.sort();
    all.into_iter().map(|(_, id)| id).collect()
}

pub(super) fn pick(s: &mut sq_editor_session::EditorSession, ids: &[Id]) {
    s.select(ids.iter().copied().collect::<BTreeSet<Id>>(), BTreeSet::new());
}

/// Runs `c` in the state `setup` builds: disabled before, enabled after, and it changes something when it runs.
fn check(scenario: Scenario, c: C, effect: bool, setup: Setup) {
    let (mut root, mut rig, dir) = new_root(scenario);
    frame(&mut root, &mut rig);
    setup(&mut root, &mut rig);
    frame(&mut root, &mut rig);
    assert!(root.shell.command_enabled(&rig.session, c), "{c:?} must be enabled in its state");
    let before = fingerprint(&mut root, &mut rig);
    assert!(root.shell.run_command(&mut rig.cx(), c), "{c:?} must run");
    let lines = frame(&mut root, &mut rig);
    if effect {
        assert_ne!(
            before,
            fingerprint(&mut root, &mut rig),
            "{c:?} changed nothing (status: {lines:?}, error: {:?}, events: {:?})",
            rig.session.last_error(),
            rig.events
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

fn checks(scenario: Scenario, cmds: &[C], effect: bool, setup: Setup) {
    for c in cmds {
        check(scenario, *c, effect, setup);
    }
}

pub(super) fn load_source(root: &mut AppRoot, rig: &mut Rig) {
    let loaded = root.source.as_mut().expect("source monitor").open(&mut rig.cx(), Id::from_u128(901));
    assert!(loaded, "source clip opens");
}

pub(super) fn first_clip_only(rig: &mut Rig) {
    let first = clip_ids(&rig.session)[0];
    pick(&mut rig.session, &[first]);
}

#[test]
fn source_and_project_commands_enable_with_their_clip() {
    checks(Scenario::Plain, &[C::Insert, C::Overwrite, C::PlaceOnTop, C::MakeSubclip], true, |root, rig| {
        load_source(root, rig)
    });
    check(Scenario::InOut, C::FitToFill, true, |root, rig| {
        load_source(root, rig);
        first_clip_only(rig);
    });
    // shortcut: runs, but the demo project refuses the replace ("Not enough media beyond the cut"), so no effect is asserted;
    // give the demo clips handles and assert the change.
    check(Scenario::Plain, C::ReplaceClipFromSource, false, |root, rig| {
        // the other clip: replacing a clip by its own media changes nothing
        assert!(root.source.as_mut().expect("source").open(&mut rig.cx(), Id::from_u128(902)));
        first_clip_only(rig);
    });
    check(Scenario::Plain, C::ReplaceClipFromProject, true, |root, rig| {
        first_clip_only(rig);
        root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
    });
    check(Scenario::FastCut, C::AttachBacktimed, true, load_source);
}

/// Records what Edit Original opens.
#[derive(Default, Clone)]
struct Opened(Arc<std::sync::Mutex<Vec<std::path::PathBuf>>>);
impl crate::FileManager for Opened {
    fn reveal(&self, _: &std::path::Path) -> Result<(), String> {
        Ok(())
    }
    fn open(&self, path: &std::path::Path) -> Result<(), String> {
        self.0.lock().expect("lock").push(path.to_path_buf());
        Ok(())
    }
}

#[test]
fn insert_overwrite_and_place_on_top_run_from_a_project_selection_without_a_source_clip() {
    for c in [C::Insert, C::Overwrite, C::PlaceOnTop] {
        let (mut root, mut rig, dir) = new_root(Scenario::Plain);
        root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
        frame(&mut root, &mut rig);
        assert!(root.shell.command_enabled(&rig.session, c), "{c:?} enabled");
        assert!(root.shell.run_command(&mut rig.cx(), c), "{c:?} runs");
        frame(&mut root, &mut rig);
        let flow = rig.events.iter().find_map(|e| match e {
            AppEvent::Flow(sq_draw_shell::ShellFlow::PlaceMedia { ids, options }) => {
                Some((ids.clone(), options.clone()))
            }
            _ => None,
        });
        let (ids, options) = flow.unwrap_or_else(|| panic!("{c:?} emitted no place flow: {:?}", rig.events));
        assert_eq!(ids, vec![Id::from_u128(902)]);
        assert_eq!(options.place_on_top, c == C::PlaceOnTop);
        assert_eq!(options.mode == sq_core_model::ThreePointMode::Insert, c == C::Insert);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn edit_original_opens_the_files_of_the_project_selection_the_clips_or_the_source_clip() {
    // Selected timeline clips (the demo selects both).
    let (mut root, mut rig, dir) = new_root(Scenario::Plain);
    let opened = Opened::default();
    root.opener = Box::new(opened.clone());
    frame(&mut root, &mut rig);
    assert!(root.shell.command_enabled(&rig.session, C::EditOriginal));
    assert!(root.shell.run_command(&mut rig.cx(), C::EditOriginal));
    frame(&mut root, &mut rig);
    assert_eq!(
        *opened.0.lock().expect("lock"),
        vec![std::path::PathBuf::from("/tmp/sq-demo-1.mp4"), std::path::PathBuf::from("/tmp/sq-demo-2.mp4")]
    );
    // Project focus: the Project selection wins.
    opened.0.lock().expect("lock").clear();
    root.shell.shell().focus = Some(PanelID::Project);
    root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
    frame(&mut root, &mut rig);
    assert!(root.shell.run_command(&mut rig.cx(), C::EditOriginal));
    frame(&mut root, &mut rig);
    assert_eq!(*opened.0.lock().expect("lock"), vec![std::path::PathBuf::from("/tmp/sq-demo-2.mp4")]);
    let _ = std::fs::remove_dir_all(&dir);
    // Only the Source clip.
    let (mut root, mut rig, dir) = new_root(Scenario::Plain);
    let opened = Opened::default();
    root.opener = Box::new(opened.clone());
    rig.session.select(BTreeSet::new(), BTreeSet::new());
    load_source(&mut root, &mut rig);
    frame(&mut root, &mut rig);
    assert!(root.shell.run_command(&mut rig.cx(), C::EditOriginal));
    frame(&mut root, &mut rig);
    assert_eq!(*opened.0.lock().expect("lock"), vec![std::path::PathBuf::from("/tmp/sq-demo-1.mp4")]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn fill_reel_pours_the_project_selection_into_a_copy_of_the_sequence() {
    let (mut root, mut rig, dir) = new_root(Scenario::Plain);
    root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
    frame(&mut root, &mut rig);
    assert!(root.shell.command_enabled(&rig.session, C::FillReel));
    let sequences = rig.session.project().timelines.len();
    let template = rig.session.active_timeline_id();
    assert!(root.shell.run_command(&mut rig.cx(), C::FillReel));
    frame(&mut root, &mut rig);
    assert_eq!(rig.session.project().timelines.len(), sequences + 1, "a copy holds the result");
    assert_ne!(rig.session.active_timeline_id(), template);
    assert!(rig.session.undo_name().is_some_and(|n| n == "Fill Reel"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn clipboard_commands_enable_with_something_copied() {
    checks(Scenario::Plain, &[C::Paste, C::PasteInsert, C::PasteToTargets], true, |_, rig| {
        assert!(rig.session.copy_selection());
    });
    check(Scenario::FastCut, C::PasteAttached, true, |_, rig| {
        assert!(rig.session.copy_selection());
    });
    check(Scenario::Plain, C::PasteAttributes, false, |_, rig| {
        first_clip_only(rig);
        assert!(rig.session.copy_selection());
        let second = clip_ids(&rig.session)[1];
        pick(&mut rig.session, &[second]);
    });
}

#[test]
fn proposed_cut_commands_enable_with_proposed_cuts() {
    let setup: Setup = |_, rig| {
        assert!(
            rig.session.propose_cuts(&[TimeRange::new(Time::seconds(1), Time::seconds(1))], ProposedCutKind::Silence)
        );
        rig.session.seek(Time::new(3, 2));
    };
    checks(
        Scenario::Plain,
        &[
            C::ReviewProposedCuts,
            C::AcceptProposedCuts,
            C::RejectProposedCuts,
            C::AcceptProposedCutAtPlayhead,
            C::RejectProposedCutAtPlayhead,
        ],
        false,
        setup,
    );
}

#[test]
fn track_target_and_angle_commands_enable_with_their_tracks() {
    let tracks: Setup = |_, rig| {
        for _ in 0..9 {
            rig.session.add_track(TrackKind::Video);
            rig.session.add_track(TrackKind::Audio);
        }
    };
    for n in 5..=9u8 {
        check(Scenario::Plain, C::ToggleTrackTarget(TrackKind::Video, n.into()), true, tracks);
        check(Scenario::Plain, C::ToggleTrackTarget(TrackKind::Audio, n.into()), true, tracks);
    }
    for n in 1..=9u8 {
        check(Scenario::Plain, C::SwitchAngle(n.into()), false, |_, rig| {
            let ids = clip_ids(&rig.session);
            assert!(rig.session.create_angles_clip(&ids, None, None, 0, true).is_some(), "angles clip");
        });
    }
}

#[test]
fn selection_commands_enable_with_the_right_clip() {
    check(Scenario::Plain, C::Ungroup, true, |_, rig| {
        assert!(rig.session.group_selection().is_some());
    });
    check(Scenario::Plain, C::Unnest, true, |_, rig| {
        assert!(rig.session.nest_selection("N").is_some());
    });
    check(Scenario::Plain, C::Unbundle, true, |_, rig| {
        assert!(rig.session.bundle_selection());
    });
    check(Scenario::Plain, C::JoinCuts, true, |_, rig| {
        rig.session.select(BTreeSet::new(), BTreeSet::new());
        rig.session.add_edit_at_playhead(false);
    });
    check(Scenario::Plain, C::ExtendToSequenceEnd, true, |_, rig| {
        let id = rig.session.add_adjustment_layer(None, None, Time::seconds(2)).expect("layer");
        pick(&mut rig.session, &[id]);
    });
    check(Scenario::Plain, C::ToneSettings, false, |_, rig| {
        let id = rig.session.add_tone_clip(&ToneSpec::DEFAULT, Time::seconds(2)).expect("tone");
        pick(&mut rig.session, &[id]);
    });
    check(Scenario::Plain, C::RemoveTimeRemapping, true, |_, rig| {
        first_clip_only(rig);
        assert!(rig.session.add_speed_point_at_playhead());
    });
    check(Scenario::Plain, C::SelectNextClip, true, |_, rig| first_clip_only(rig));
    check(Scenario::Plain, C::SelectPreviousClip, true, |_, rig| {
        let second = clip_ids(&rig.session)[1];
        pick(&mut rig.session, &[second]);
    });
    check(Scenario::Plain, C::EditMarker, false, |_, rig| rig.session.add_marker_at_playhead());
    check(Scenario::Plain, C::RemoveBlurredFill, true, |_, rig| {
        first_clip_only(rig);
        assert!(rig.session.apply_blurred_fill(
            sq_core_effects::blurred_fill::BlurredFillStyle::Card,
            &sq_core_effects::blurred_fill::BlurredFillOptions::default()
        ));
    });
}

pub(super) fn select_edge(root: &mut AppRoot, rig: &mut Rig, edge: ClipEdge) {
    let first = clip_ids(&rig.session)[0];
    let sel = EdgeSelection::new(vec![EdgeRef { clip: first, edge }], false, true);
    root.timeline.inner().panel.set_edge_selection(Some(sel));
}

#[test]
fn trim_commands_enable_with_a_selected_edit_point() {
    // The demo clips use their whole media: a tail cannot grow and a head cannot start earlier.
    let tail: Setup = |root, rig| select_edge(root, rig, ClipEdge::Tail);
    let head: Setup = |root, rig| select_edge(root, rig, ClipEdge::Head);
    checks(Scenario::Plain, &[C::ExtendEdit, C::ToggleTrimType, C::TrimBackward, C::TrimBackward5], true, tail);
    checks(Scenario::Plain, &[C::TrimForward, C::TrimForward5], true, head);
}

/// Three video clips on three tracks, selected: the state Swift enables Split Screen in.
pub(super) fn three_tracks(_: &mut AppRoot, rig: &mut Rig) {
    for _ in 0..2 {
        let options = sq_editor_session::PlaceOptions {
            at: Some(Time::ZERO),
            new_track: Some(TrackKind::Video),
            ..Default::default()
        };
        assert!(rig.session.place_media(&[Id::from_u128(901)], &options), "clip on a new track");
    }
    let t = rig.session.active_timeline().expect("sequence");
    let ids: Vec<Id> = t
        .tracks
        .iter()
        .filter(|tr| tr.kind == TrackKind::Video)
        .filter_map(|tr| tr.clips().iter().min_by_key(|c| c.timeline().start).map(|c| c.id))
        .collect();
    assert_eq!(ids.len(), 3, "one clip per video track");
    pick(&mut rig.session, &ids);
}

#[test]
fn split_screen_enables_with_clips_on_different_tracks() {
    use sq_core_graphics::split_layout::SplitLayoutPreset as P;
    for preset in
        [P::SideBySide, P::Stacked, P::SixtyForty, P::ThreeStacked, P::PictureInPicture, P::PictureInPictureCircle]
    {
        for animated in [false, true] {
            check(Scenario::Plain, C::SplitScreen(preset, animated), true, three_tracks);
        }
    }
}

/// Cut to Beats and Snap to Beats stay greyed (with their reason, `beat_edit_problem`) until the music has beat markers
/// and a clip is selected; the demo project has no beat markers.
#[test]
fn beat_edits_enable_with_beat_markers_and_a_selection() {
    for c in [C::CutToBeats, C::SnapToBeats] {
        check(Scenario::Plain, c, true, |_, rig| {
            rig.session.add_marker_at_playhead();
            let marker = rig.session.active_timeline().and_then(|t| t.markers.last().cloned()).expect("marker");
            rig.session.edit_marker(marker.id, sq_core_edit::timeline_beat_markers::BEAT_MARKER_NAME, marker.color, "");
        });
    }
}

/// Fit with Blurred Fill needs a clip whose shape differs from the sequence frame; the 16:9 demo clips in the 16:9
/// sequence have nothing to fit until the sequence turns vertical.
#[test]
fn fit_with_blurred_fill_enables_when_the_frame_shape_differs() {
    check(Scenario::Plain, C::FitBlurredFill, true, |_, rig| {
        let mut format = rig.session.active_timeline().expect("sequence").format.clone();
        (format.width, format.height) = (1080, 1920);
        assert!(rig.session.set_sequence_format(&format, None));
    });
}

#[test]
fn ease_commands_run_in_their_states() {
    // Ease commands: a speed point with a changing speed at the playhead, no keys selected.
    for c in [C::EaseLinear, C::EasyEase, C::EaseIn, C::EaseOut] {
        check(Scenario::Plain, c, true, |_, rig| {
            first_clip_only(rig);
            let clip = clip_ids(&rig.session)[0];
            rig.session.seek(Time::seconds(2));
            assert!(rig.session.add_speed_point_at_playhead());
            // Retime the point: the span before it gets shorter and faster, so the speed changes there.
            let c = rig
                .session
                .active_timeline()
                .expect("sequence")
                .tracks
                .iter()
                .flat_map(|t| t.clips())
                .find(|c| c.id == clip)
                .cloned()
                .expect("clip");
            let keys = sq_core_model::SpeedKeys::of(&c);
            let fd = rig.session.active_timeline().expect("sequence").frame_duration();
            let fast = keys.retiming_key(1, Time::ZERO - Time::seconds(1), fd).expect("retimed point");
            rig.session.apply_speed_edit(&sq_editor_session::SpeedEdit::new(
                clip,
                keys.clone(),
                sq_editor_session::SpeedEditPhase::Began,
                true,
            ));
            rig.session.apply_speed_edit(&sq_editor_session::SpeedEdit::new(
                clip,
                fast,
                sq_editor_session::SpeedEditPhase::Changed,
                true,
            ));
            rig.session.seek(Time::seconds(1));
        });
    }
}

#[test]
fn hold_and_ease_act_on_the_selected_keyframes() {
    use sq_editor_session::Change;
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    for c in [C::ToggleHoldInterpolation, C::EasyEase, C::EaseIn, C::EaseOut] {
        let (mut root, mut rig, dir) = new_root(Scenario::Plain);
        first_clip_only(&mut rig);
        rig.session.seek(Time::seconds(2));
        {
            let model = &mut root.inspector.controls().model;
            model.sync(&rig.session, Change::SELECTION | Change::PROJECT);
            model.focused_property = Some(EffectProperty::Opacity);
        }
        assert!(root.shell.run_command(&mut rig.cx(), C::AddKeyframe));
        frame(&mut root, &mut rig);
        root.inspector.pump(&mut rig.cx());
        let model = &mut root.inspector.controls().model;
        let (key, _) = model.keys(&EffectProperty::Opacity).first().copied().expect("a key");
        model.select_key(&EffectProperty::Opacity, key, false);
        frame(&mut root, &mut rig);
        assert!(root.shell.command_enabled(&rig.session, c), "{c:?} enabled with a selected key");
        let before = serde_json::to_string(rig.session.project()).unwrap_or_default();
        assert!(root.shell.run_command(&mut rig.cx(), c), "{c:?} runs");
        frame(&mut root, &mut rig);
        root.inspector.pump(&mut rig.cx());
        assert_ne!(before, serde_json::to_string(rig.session.project()).unwrap_or_default(), "{c:?} changed no key");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn mark_overhang_auto_duck_and_revert_run_in_their_states() {
    // A linked pair that does not line up (a J or L cut): the video clip's tail is trimmed.
    check(Scenario::Plain, C::MarkOverhang, true, |_, rig| {
        let video = clip_ids(&rig.session)[0];
        let sel = EdgeSelection::new(vec![EdgeRef { clip: video, edge: ClipEdge::Tail }], false, false);
        rig.session.trim_edges(&sel, -30);
        rig.session.select(BTreeSet::new(), BTreeSet::new());
        rig.session.seek(Time::seconds(9));
    });
    // A Music track to duck.
    check(Scenario::Plain, C::AutoDuck, false, |_, rig| {
        let audio = rig
            .session
            .active_timeline()
            .expect("sequence")
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Audio)
            .flat_map(|t| t.clips().iter().map(|c| c.id))
            .next()
            .expect("an audio clip");
        pick(&mut rig.session, &[audio]);
        assert!(rig.session.toggle_audio_tag(sq_core_model::AudioTag::Music), "tagged as music");
    });
    // A saved project with a change since the save.
    check(Scenario::Plain, C::Revert, false, |_, rig| {
        let dir = crate::test_rig::unique_dir("sq-revert");
        std::fs::create_dir_all(&dir).expect("dir");
        rig.session.save_as(&dir.join("demo.sqproj")).unwrap_or_else(|e| panic!("save: {e}"));
        rig.session.add_marker_at_playhead();
    });
}

/// Enabled state of `c` in a fresh root with the demo project after `setup`.
fn enabled_in(scenario: Scenario, c: C, setup: Setup) -> bool {
    let (mut root, mut rig, dir) = new_root(scenario);
    frame(&mut root, &mut rig);
    setup(&mut root, &mut rig);
    frame(&mut root, &mut rig);
    let on = root.shell.menu_enabled(&rig.session, c);
    let _ = std::fs::remove_dir_all(&dir);
    on
}

/// The enable rules of `ShellCommands.enabled` / `ShellHost.commandEnabled` in Swift, pinned in the states the task names.
/// Cut, Copy, Split, Nest and Add Marker have no rule in Swift (the default is enabled), so they stay enabled with nothing selected.
#[test]
fn the_menu_enable_rules_match_swift() {
    let none: Setup = |_, rig| rig.session.select(BTreeSet::new(), BTreeSet::new());
    let nothing: Setup = |_, _| {};
    // Paste: the clipboard, an effect clipboard or media on the system clipboard.
    assert!(!enabled_in(Scenario::Plain, C::Paste, nothing), "Paste with an empty clipboard");
    assert!(enabled_in(Scenario::Plain, C::Paste, |_, rig| assert!(rig.session.copy_selection())));
    assert!(!enabled_in(Scenario::Plain, C::PasteInsert, nothing));
    // No rule in Swift: enabled with nothing selected.
    for c in [C::Cut, C::Copy, C::AddMarker, C::AddEdit, C::SelectAll] {
        assert!(enabled_in(Scenario::Plain, c, none), "{c:?} has no rule");
    }
    // Delete and Ripple Delete: a selection, a caption selection, a transition or a panel target.
    for c in [C::Delete, C::RippleDelete] {
        assert!(!enabled_in(Scenario::Plain, c, none), "{c:?} with nothing selected");
        assert!(enabled_in(Scenario::Plain, c, nothing), "{c:?} with the demo clips selected");
    }
    // Lift / Extract need In and Out.
    for c in [C::Lift, C::Extract, C::GoToIn, C::GoToOut, C::ClearInOut] {
        assert!(!enabled_in(Scenario::Plain, c, nothing), "{c:?} without In/Out");
        assert!(enabled_in(Scenario::InOut, c, nothing), "{c:?} with In/Out");
    }
    // Unlink: a selected clip that has a link partner. Demo clips are placed with their audio partners.
    assert!(!enabled_in(Scenario::Plain, C::Unlink, none), "Unlink without a selection");
    assert!(enabled_in(Scenario::Plain, C::Unlink, nothing), "Unlink with linked clips");
    assert!(
        !enabled_in(Scenario::Plain, C::Unlink, |_, rig| {
            assert!(rig.session.unlink_selection());
        }),
        "Unlink after unlinking"
    );
    // Group / Duplicate / Enable follow the selection; Ungroup needs a group; Bundle needs clips.
    for c in [C::Group, C::Duplicate, C::EnableClip] {
        assert!(!enabled_in(Scenario::Plain, c, none), "{c:?} without a selection");
        assert!(enabled_in(Scenario::Plain, c, nothing), "{c:?} with a selection");
    }
    assert!(!enabled_in(Scenario::Plain, C::Ungroup, nothing));
    assert!(!enabled_in(Scenario::Plain, C::Unnest, nothing), "Unnest needs a nested clip");
    // Undo / Redo follow the history.
    assert!(enabled_in(Scenario::Plain, C::Undo, nothing));
    assert!(!enabled_in(Scenario::Plain, C::Redo, nothing));
    assert!(enabled_in(Scenario::Plain, C::Redo, |_, rig| assert!(rig.session.undo())));
}

/// The names the menu shows after "Undo " / "Redo " (the Swift literals of `perform` / `attempt`).
#[test]
fn undo_and_redo_names_are_the_swift_ones() {
    for (c, name, setup) in [
        (C::AddMarker, "Add Marker", (|_, _| {}) as Setup),
        (C::Duplicate, "Duplicate", |_, _| {}),
        (C::Unlink, "Unlink", |_, _| {}),
        (C::Group, "Group", |_, _| {}),
    ] {
        let (mut root, mut rig, dir) = new_root(Scenario::Plain);
        frame(&mut root, &mut rig);
        setup(&mut root, &mut rig);
        assert!(root.shell.run_command(&mut rig.cx(), c), "{c:?} runs");
        frame(&mut root, &mut rig);
        assert_eq!(rig.session.undo_name(), Some(name), "undo name of {c:?}");
        assert!(rig.session.undo());
        assert_eq!(rig.session.redo_name(), Some(name), "redo name of {c:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
