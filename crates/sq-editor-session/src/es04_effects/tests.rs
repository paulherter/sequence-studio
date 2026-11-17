//! Session tests of ES4 (ports of SplitScreenSessionTests, ColorMatteSessionTests, EditorLookCommandsTests,
//! VariantOverrideResetTests and the matte view of ColorMattePreviewTests).

use std::collections::BTreeSet;

use sq_core_color::ColorMatteColor;
use sq_core_graphics::split_layout::SplitLayoutPreset;
use sq_core_model::{Clip, ClipEdge, ConformMode, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use sq_uikit::editor_command::EditorCommand;

use super::*;
use crate::{EditorSession, SessionDeps};

fn video_clip(n: u128, start: Time, secs: i64) -> Clip {
    Clip::new(
        Id::from_u128(n),
        &format!("c{n}"),
        Id::from_u128(900 + n),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(secs, 1)),
        start,
    )
}

/// A session with one video clip per track.
fn session(tracks: usize) -> (EditorSession, Vec<Id>) {
    let mut ids = SequentialIds::default();
    let mut clips = Vec::new();
    let mut list = Vec::new();
    for i in 0..tracks {
        let c = video_clip(9000 + i as u128, Time::ZERO, 10);
        clips.push(c.id);
        let mut t = Track::new(Id::from_u128(100 + i as u128), TrackKind::Video);
        assert!(t.overwrite(c, &mut ids).is_ok());
        list.push(t);
    }
    let fmt = SequenceFormat::new(Time::new(1, 30));
    let tl = Timeline::new(Id::from_u128(50), "Main", fmt, list);
    let p = Project::new(Id::from_u128(1), "P", Vec::new(), vec![tl]);
    let dir = std::env::temp_dir().join("sq-es04-tests");
    (EditorSession::new(p, SessionDeps::headless(dir)), clips)
}

fn select(s: &mut EditorSession, ids: &[Id]) {
    s.set_selection_raw(ids.iter().copied().collect());
}

#[test]
fn split_screen_is_one_undo_step() {
    let (mut s, ids) = session(2);
    select(&mut s, &ids);
    assert!(s.apply_split_screen(SplitLayoutPreset::Stacked, true, 0.0));
    assert!(s.undo());
    assert!(!s.can_undo());
}

#[test]
fn split_screen_refuses_too_few_clips_and_same_track() {
    let (mut s, ids) = session(2);
    select(&mut s, &ids);
    assert!(!s.apply_split_screen(SplitLayoutPreset::ThreeStacked, false, 0.0));
    assert_eq!(
        s.split_screen_problem(SplitLayoutPreset::ThreeStacked),
        Some(SplitScreenProblem::TooFewClips { required: 3 })
    );
    assert!(!s.can_undo());

    // Two clips on one track.
    let mut ids_src = SequentialIds::default();
    let (a, b) = (video_clip(1, Time::ZERO, 5), video_clip(2, Time::new(5, 1), 5));
    let mut t = Track::new(Id::from_u128(100), TrackKind::Video);
    assert!(t.overwrite(a.clone(), &mut ids_src).is_ok() && t.overwrite(b.clone(), &mut ids_src).is_ok());
    let tl = Timeline::new(Id::from_u128(50), "Main", SequenceFormat::new(Time::new(1, 30)), vec![t]);
    let mut s = EditorSession::new(
        Project::new(Id::from_u128(1), "P", Vec::new(), vec![tl]),
        SessionDeps::headless(std::env::temp_dir()),
    );
    select(&mut s, &[a.id, b.id]);
    assert_eq!(s.split_screen_problem(SplitLayoutPreset::SideBySide), Some(SplitScreenProblem::SameTrack));
    assert!(!s.apply_split_screen(SplitLayoutPreset::SideBySide, false, 0.0));
    assert!(!s.can_undo());
}

#[test]
fn split_screen_reports_extra_clips() {
    let (mut s, ids) = session(3);
    select(&mut s, &ids);
    assert_eq!(s.split_screen_problem(SplitLayoutPreset::SideBySide), None);
    assert_eq!(s.split_screen_extra_clips(SplitLayoutPreset::SideBySide), 1);
}

#[test]
fn command_clips_follow_the_selection_else_the_playhead() {
    let (mut s, ids) = session(2);
    // Nothing selected: both clips lie under the playhead at 0.
    assert_eq!(s.command_clips_for_menu(Some(TrackKind::Video)).len(), 2);
    assert!(s.command_clips_for_menu(Some(TrackKind::Audio)).is_empty());
    select(&mut s, &ids[..1]);
    assert_eq!(s.command_clips(None).iter().map(|c| c.id).collect::<Vec<_>>(), vec![ids[0]]);
    assert_eq!(s.effect_drop_targets(ids[1]), BTreeSet::from([ids[1]]));
    assert_eq!(s.effect_drop_targets(ids[0]), BTreeSet::from([ids[0]]));
}

#[test]
fn fade_in_and_frame_hold_commands_run_through_the_look_commands() {
    let (mut s, ids) = session(1);
    select(&mut s, &ids);
    assert!(EditorLookCommands::handles(&EditorCommand::VideoFadeIn));
    assert!(!EditorLookCommands::handles(&EditorCommand::Delete));
    assert_eq!(EditorLookCommands::enabled(&EditorCommand::VideoFadeIn, &s), Some(true));
    assert_eq!(EditorLookCommands::run(&EditorCommand::VideoFadeIn, &mut s), Some(String::new()));
    assert!(s.can_undo());
    select(&mut s, &[]);
    assert_eq!(EditorLookCommands::run(&EditorCommand::Delete, &mut s), None);
}

#[test]
fn fade_video_refuses_audio_selection() {
    let (mut s, _) = session(1);
    select(&mut s, &[Id::from_u128(777)]);
    assert!(!s.fade_video(ClipEdge::Head, EditorSession::DEFAULT_FADE_DURATION));
    assert!(!s.can_undo());
}

#[test]
fn color_matte_is_added_edited_and_undone() {
    let (mut s, _) = session(1);
    let id = s.add_color_matte(ColorMatteColor::DEFAULT, "Color Matte", Some(Time::new(20, 1)), None, Time::new(5, 1));
    let Some(id) = id else { panic!("no matte: {:?}", s.last_error()) };
    assert_eq!(s.selection(), &BTreeSet::from([id]));
    let steps = s.history().undo_depth();
    let other = ColorMatteColor { r: 1, g: 2, b: 3 };
    s.set_color_matte(id, other, false);
    assert_eq!(s.history().undo_depth(), steps + 1);
    // Same color again: no new step.
    s.set_color_matte(id, other, false);
    assert_eq!(s.history().undo_depth(), steps + 1);
    assert!(s.undo() && s.undo());
    assert!(!s.can_undo());
}

#[test]
fn adjustment_layer_goes_on_a_free_track_and_is_selected() {
    let (mut s, _) = session(1);
    // The only video track is busy at 0: the layer lands on it only by overwrite (no free track above).
    let made = s.add_adjustment_layer(Some(Time::new(30, 1)), None, Time::new(5, 1));
    assert!(made.is_some());
    assert_eq!(s.selection().len(), 1);
    assert!(s.undo());
}

#[test]
fn variants_are_added_activated_and_removed() {
    let (mut s, _) = session(1);
    assert_eq!(s.active_variant_id(), None);
    let Some(v) = s.add_variant("Vertical", 1080, 1920, ConformMode::Fill) else { panic!("{:?}", s.last_error()) };
    assert_eq!(s.active_variant_id(), Some(v));
    assert_eq!(s.display_format().map(|f| (f.width, f.height)), Some((1080, 1920)));
    s.remove_variant(v);
    assert_eq!(s.active_variant_id(), None);
    assert!(s.undo());
}

#[test]
fn color_clipboard_keeps_eight_memories() {
    let mut c = ColorClipboard::new();
    assert!(!c.has_color() && !c.save_memory(1));
    c.copy(Vec::new(), None);
    assert!(c.has_color() && c.save_memory(8) && !c.save_memory(9) && !c.save_memory(0));
    assert!(c.has_memory(8) && !c.has_memory(1));
    c.copy(Vec::new(), None);
    assert!(c.load_memory(8) && !c.load_memory(2));
}

#[test]
fn matte_white_sends_every_pixel_to_white() {
    let p = matte_white();
    assert_eq!((p.gain, p.offset), (sq_core_model::ColorTriple::all(0.0), sq_core_model::ColorTriple::all(1.0)));
}

#[test]
fn id_source_is_untouched_by_a_refused_edit() {
    let (mut s, _) = session(1);
    let mut probe = SequentialIds::default();
    let first = probe.next_id();
    assert!(!s.remove_transition(Id::from_u128(5)));
    assert!(s.last_error().is_some());
    assert_eq!(s.ids.next_id(), first);
}

#[test]
fn a_motion_preset_applies_to_the_selected_video_clip_in_one_undo_step() {
    use sq_core_effects::keystone::Keystone;
    use sq_library::keystone_library::preset_item;
    let (mut s, ids) = session(1);
    let k = Keystone::built_ins().into_iter().next().expect("a built-in motion");
    let item = preset_item(&k, sq_core_time::Timestamp::from_unix_seconds(0.0)).expect("payload");
    assert!(!s.apply_preset(&item, None, sq_core_effects::effect_preset::ApplyMode::Absolute), "no selection");
    assert!(s.last_error().is_some_and(|e| e.starts_with("Select a video clip")));
    select(&mut s, &ids);
    assert!(s.apply_preset(&item, None, sq_core_effects::effect_preset::ApplyMode::Absolute));
    assert!(s.undo_name().is_some_and(|n| n.contains(&k.name)));
    s.undo();
    assert!(!s.can_undo());
}

#[test]
fn a_motion_preset_dropped_on_a_clip_lands_on_that_clip_without_a_selection() {
    use sq_core_effects::keystone::Keystone;
    let (mut s, ids) = session(1);
    let k = Keystone::built_ins().into_iter().next().expect("a built-in motion");
    let item = sq_library::keystone_library::preset_item(&k, sq_core_time::Timestamp::from_unix_seconds(0.0))
        .expect("payload");
    let target: BTreeSet<Id> = ids.iter().copied().collect();
    assert!(s.apply_preset(&item, Some(&target), sq_core_effects::effect_preset::ApplyMode::Absolute));
    assert!(s.undo_name().is_some_and(|n| n.contains(&k.name)));
}

#[test]
fn undoing_a_grade_edit_keeps_the_clip_selected() {
    let (mut s, ids) = session(2);
    select(&mut s, &ids[..1]);
    assert!(s.edit_clip_color(ids[0], "Color", false, |c| {
        c.name = "graded".to_string();
        true
    }));
    assert_eq!(s.selection(), &BTreeSet::from([ids[0]]));
    assert!(s.undo());
    assert_eq!(s.selection(), &BTreeSet::from([ids[0]]), "the grade's clip stays selected after Undo");
    assert!(s.redo());
    assert_eq!(s.selection(), &BTreeSet::from([ids[0]]));
}

/// A value edit that changes only some of the selected clips (a grade on one, an Audio Gain on another) leaves the whole
/// selection alone through Undo and Redo: the inspector, the Color page and the audio rows keep their target.
#[test]
fn undo_and_redo_of_a_value_edit_on_part_of_the_selection_keep_the_whole_selection() {
    let (mut s, ids) = session(3);
    let all: BTreeSet<Id> = ids.iter().copied().collect();
    select(&mut s, &ids);
    assert!(s.edit_clip_color(ids[1], "Color", false, |c| {
        c.name = "graded".to_string();
        true
    }));
    assert!(s.set_audio_gain(&std::collections::BTreeMap::from([(ids[0], -6.0)])));
    assert_eq!(s.selection(), &all);
    for round in 0..2 {
        assert!(s.undo(), "gain, round {round}");
        assert_eq!(s.selection(), &all, "undo of the gain, round {round}");
        assert!(s.undo(), "grade, round {round}");
        assert_eq!(s.selection(), &all, "undo of the grade, round {round}");
        assert!(s.redo() && s.redo());
        assert_eq!(s.selection(), &all, "redo, round {round}");
    }
}
