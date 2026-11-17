use super::*;
use crate::analysis_links::magic_job::add_magic_mask_with;
use sq_core_model::{Clip, MagicPoint, MediaFingerprint, MediaRef, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange, Vec2};
use sq_editor_session::SessionDeps;
use std::collections::BTreeSet;

fn session() -> (EditorSession, Clip) {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-tint"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        p.media.push(MediaRef::new(Id::from_u128(101), "m", "/tmp/m.mov", MediaFingerprint::new(1)));
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let c = Clip::new(
            Id::from_u128(1),
            "clip",
            Id::from_u128(101),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        assert!(t.tracks[0].insert(c, &mut ids).is_ok());
    });
    s.select(BTreeSet::from([Id::from_u128(1)]), BTreeSet::new());
    let clip = s.display_timeline().and_then(|t| t.tracks[0].clip(Id::from_u128(1)).cloned()).expect("clip");
    (s, clip)
}

fn key_of(s: &EditorSession) -> String {
    let t = s.display_timeline().expect("timeline");
    let clip = t.tracks[0].clip(Id::from_u128(1)).expect("clip");
    clip.masks().iter().find_map(|m| m.magic.as_ref().map(|g| g.cache_key(clip.media))).expect("magic mask")
}

#[test]
fn a_tracked_matte_under_the_playhead_tints_the_picture_once() {
    let (mut s, clip) = session();
    let point = MagicPoint { position: Vec2::new(0.5, 0.5), subtract: false, source_time: Time::ZERO };
    add_magic_mask_with(&mut s, &clip, Id::from_u128(9), vec![point]);
    let store = Arc::new(FrameMatteStore::new(None));
    let mut tint = MatteTint::new(Arc::clone(&store), 4);
    assert!(!tint.update(&s), "nothing tracked yet");
    store.put(&key_of(&s), 0.0, SubjectMatte::new(2, 1, vec![1.0, 0.0]));
    assert!(tint.update(&s));
    let up = tint.take_upload().expect("a picture");
    assert_eq!((up.slot, up.image.width, up.image.height), (4, 2, 1));
    assert_eq!((up.image.pixels[3], up.image.pixels[7]), (77, 0), "30 % where the matte is, clear elsewhere");
    assert!(tint.update(&s) && tint.take_upload().is_none(), "unchanged mattes are not sent again");
}

#[test]
fn without_a_selected_clip_there_is_no_tint() {
    let (mut s, _) = session();
    s.select(BTreeSet::new(), BTreeSet::new());
    assert!(!MatteTint::new(Arc::new(FrameMatteStore::new(None)), 4).update(&s));
}
