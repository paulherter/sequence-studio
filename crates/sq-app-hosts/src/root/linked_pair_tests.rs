//! A linked video and audio pair (Linked Selection is on by default and selects both clips of a click) counts as ONE clip
//! for the commands that ask for "one clip": Replace Clip from Source and from Project, Rename and the grade rows of the
//! clip menu. Their guards read `selection().len() == 1`, so a clip with sound was refused as "two clips" (found by the shown
//! shortcut audit, 2026-11-16; Swift has the same guards, but there the click selected the picture clip alone more often).

use super::disabled_commands_tests::{clip_ids, frame, load_source, new_root, pick};
use crate::test_rig::Rig;
use sq_core_model::{BinItemRef, ClipEffect, TrackKind};
use sq_core_time::Id;
use sq_uikit::editor_command::EditorCommand as C;
use std::collections::BTreeSet;

/// The `n`-th video clip and its linked audio partner.
fn pair(rig: &Rig, n: usize) -> (Id, Id) {
    let video = clip_ids(&rig.session)[n];
    let t = rig.session.active_timeline().expect("sequence");
    let link = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == video).and_then(|c| c.link).expect("a link");
    let audio = t
        .tracks
        .iter()
        .flat_map(|tr| tr.clips())
        .find(|c| c.kind == TrackKind::Audio && c.link == Some(link))
        .map(|c| c.id)
        .expect("the audio partner");
    (video, audio)
}

fn clip_named(rig: &Rig, id: Id) -> sq_core_model::Clip {
    let t = rig.session.active_timeline().expect("sequence");
    t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id).cloned().expect("clip")
}

#[test]
fn replace_clip_from_source_and_from_project_are_offered_for_a_linked_pair() {
    let (mut root, mut rig, dir) = new_root(super::dead_commands_tests::Scenario::Plain);
    frame(&mut root, &mut rig);
    load_source(&mut root, &mut rig);
    root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
    let (video, audio) = pair(&rig, 0);
    pick(&mut rig.session, &[video, audio]);
    frame(&mut root, &mut rig);
    for c in [C::ReplaceClipFromSource, C::ReplaceClipFromProject] {
        assert!(root.shell.command_enabled(&rig.session, c), "{c:?} for a linked pair");
    }
    // Two clips that are not a pair stay refused.
    let (other, _) = pair(&rig, 1);
    pick(&mut rig.session, &[video, other]);
    frame(&mut root, &mut rig);
    for c in [C::ReplaceClipFromSource, C::ReplaceClipFromProject] {
        assert!(!root.shell.command_enabled(&rig.session, c), "{c:?} for two separate clips");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn replace_clip_from_project_replaces_a_linked_pair_as_one_clip() {
    let (mut root, mut rig, dir) = new_root(super::dead_commands_tests::Scenario::Plain);
    frame(&mut root, &mut rig);
    let (video, audio) = pair(&rig, 0);
    pick(&mut rig.session, &[video, audio]);
    root.project.view().select(vec![BinItemRef::Media(Id::from_u128(902))]);
    frame(&mut root, &mut rig);
    // The window's pass over a key or click hands the Project selection to the shell before the command runs.
    root.answer(&mut rig.cx());
    assert!(root.shell.run_command(&mut rig.cx(), C::ReplaceClipFromProject));
    frame(&mut root, &mut rig);
    assert_eq!(
        clip_named(&rig, video).media,
        Id::from_u128(902),
        "the picture clip plays the new media ({:?}, {:?})",
        rig.session.last_error(),
        rig.events
    );
    assert_eq!(clip_named(&rig, audio).media, Id::from_u128(902), "its audio partner follows");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn rename_and_the_grade_rows_work_on_a_linked_pair() {
    let (_root, mut rig, dir) = new_root(super::dead_commands_tests::Scenario::Plain);
    let (video, audio) = pair(&rig, 1);
    pick(&mut rig.session, &[video, audio]);
    rig.session.rename_selected_clip("Hero");
    assert_eq!(clip_named(&rig, video).name, "Hero", "the picture clip is renamed");
    assert_ne!(clip_named(&rig, audio).name, "Hero", "its audio partner keeps its name");
    // Grade From Previous Clip: the picture clip takes the grade, the partner (no picture) does not fail the edit.
    let first = clip_ids(&rig.session)[0];
    assert!(rig.session.add_effect(ClipEffect::COLOR_KIND, &BTreeSet::from([first])), "a grade to copy");
    pick(&mut rig.session, &[video, audio]);
    assert!(
        rig.session.grade_from_previous_clip(1),
        "Grade From Previous Clip for a linked pair ({:?})",
        rig.session.last_error()
    );
    let _ = std::fs::remove_dir_all(&dir);
}
