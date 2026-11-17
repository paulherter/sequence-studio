//! Add Edit (Ctrl+K) right after a fresh placement: the playhead cuts the picture and its linked sound together.

use super::PlaceOptions;
use crate::es08_media::testing::{info, video};
use crate::{EditorSession, SessionDeps};
use sq_core_model::{AudioTrackInfo, MediaFingerprint, MediaRef, TrackKind};
use sq_core_time::{Id, SequentialIds, Time};

fn fresh_session_with_a_video_and_sound_clip() -> (EditorSession, Id) {
    let mut ids = SequentialIds::default();
    let dir = std::env::temp_dir().join(format!("sq-es01-blade-{}", std::process::id()));
    let mut s = EditorSession::new(EditorSession::make_empty(&mut ids), SessionDeps::headless(dir));
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..500 {
        s.ids.next_id();
    }
    let media = Id::from_u128(300);
    let mut m = MediaRef::new(media, "talk.mp4", "/talk.mp4", MediaFingerprint::new(1));
    let mut i = info(Time::seconds(11), Some(video(1920, 1080)));
    i.audio = Some(AudioTrackInfo {
        sample_rate: 48_000,
        channels: 2,
        codec: "aac".into(),
        channel_map: None,
        first_track_channels: None,
    });
    m.duration = Some(Time::seconds(11));
    m.info = Some(i);
    s.perform("Import", None, |p| p.add(m));
    (s, media)
}

fn clips_per_kind(s: &EditorSession) -> (usize, usize) {
    let t = s.active_timeline().expect("timeline");
    let n = |k| t.tracks.iter().filter(|tr| tr.kind == k).map(|tr| tr.clips().len()).sum();
    (n(TrackKind::Video), n(TrackKind::Audio))
}

#[test]
fn add_edit_after_a_fresh_placement_cuts_video_and_its_linked_sound() {
    let (mut s, media) = fresh_session_with_a_video_and_sound_clip();
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    assert_eq!(clips_per_kind(&s), (1, 1), "one picture clip with its sound");
    s.seek(Time::seconds(4));
    s.add_edit_at_playhead(false);
    assert_eq!(clips_per_kind(&s), (2, 2), "both V1 and A1 are cut at the playhead");
}

#[test]
fn add_edit_cuts_both_with_nothing_selected_and_with_the_sound_clip_alone_selected() {
    let (mut s, media) = fresh_session_with_a_video_and_sound_clip();
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    s.select(Default::default(), Default::default());
    s.seek(Time::seconds(4));
    s.add_edit_at_playhead(false);
    assert_eq!(clips_per_kind(&s), (2, 2), "no selection: the targeted tracks V1 and A1");
}

#[test]
fn add_edit_cuts_both_after_a_drop_on_v1_and_in_a_fast_cut_sequence() {
    for fast in [false, true] {
        let (mut s, media) = fresh_session_with_a_video_and_sound_clip();
        if fast {
            s.set_new_sequence_edit_mode(sq_core_model::TimelineEditMode::Magnetic);
        }
        // The first placement makes the sequence; then drop on its V1 as the timeline drop does.
        assert!(s.place_media(&[media], &PlaceOptions::default()));
        s.undo();
        let v1 = s
            .active_timeline()
            .and_then(|t| t.tracks.iter().find(|tr| tr.kind == TrackKind::Video).map(|tr| tr.id))
            .expect("v1");
        let opts = PlaceOptions { at: Some(Time::ZERO), video_track: Some(v1), ..PlaceOptions::default() };
        assert!(s.place_media(&[media], &opts));
        s.seek(Time::new(11011, 3000));
        s.add_edit_at_playhead(false);
        assert_eq!(clips_per_kind(&s), (2, 2), "fast cut: {fast}");
    }
}

#[test]
fn j_and_l_cut_say_why_when_the_clips_have_no_handle() {
    let (mut s, media) = fresh_session_with_a_video_and_sound_clip();
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    let next = PlaceOptions { at: Some(Time::seconds(11)), ..PlaceOptions::default() };
    assert!(s.place_media(&[media], &next));
    s.seek(Time::seconds(5));
    let depth = s.undo_name().map(str::to_string);
    assert!(!s.jl_cut_to_playhead(sq_core_edit::timeline_cut_keys::JLCut::JCut));
    assert_eq!(s.last_error(), Some("No room to move the audio edit."));
    assert_eq!(s.undo_name().map(str::to_string), depth, "nothing changed");
    s.seek(Time::seconds(16));
    assert!(!s.jl_cut_to_playhead(sq_core_edit::timeline_cut_keys::JLCut::LCut));
    assert_eq!(s.last_error(), Some("No room to move the audio edit."));
}

fn track_of(s: &EditorSession, kind: TrackKind, n: usize) -> Id {
    s.active_timeline().expect("timeline").tracks.iter().filter(|t| t.kind == kind).nth(n).expect("track").id
}

/// V1/A1 placement first (it makes the sequence), then a second V2 track and a drop on it.
fn session_with_a_drop_on_v2() -> (EditorSession, Id) {
    let (mut s, media) = fresh_session_with_a_video_and_sound_clip();
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    s.undo();
    s.add_track(TrackKind::Video);
    // No A2 yet: the drop creates it (drop_targets' new audio ordinal), as a real V2 drop does.
    let v2 = track_of(&s, TrackKind::Video, 1);
    let opts = PlaceOptions { at: Some(Time::ZERO), video_track: Some(v2), ..PlaceOptions::default() };
    assert!(s.place_media(&[media], &opts));
    (s, v2)
}

#[test]
fn a_drop_on_v2_puts_the_sound_on_a2_linked_to_the_picture() {
    let (s, v2) = session_with_a_drop_on_v2();
    let t = s.active_timeline().expect("timeline");
    let a2 = track_of(&s, TrackKind::Audio, 1);
    let v = t.track(v2).expect("v2").clips()[0].clone();
    let a = t.track(a2).expect("a2").clips()[0].clone();
    assert!(v.link.is_some(), "V2 clip has a link group");
    assert_eq!(v.link, a.link, "V2 and A2 clips share it");
    let targeted: Vec<_> = t.tracks.iter().filter(|x| x.is_targeted).map(|x| x.id).collect();
    println!("targeted after the drop: {targeted:?}, v2 {v2:?}, a2 {a2:?}");
}

#[test]
fn add_edit_with_the_v2_clip_selected_cuts_v2_and_a2() {
    let (mut s, v2) = session_with_a_drop_on_v2();
    let v = s.active_timeline().unwrap().track(v2).unwrap().clips()[0].id;
    s.select_with_partners([v].into_iter().collect());
    s.seek(Time::seconds(4));
    s.add_edit_at_playhead(false);
    let a2 = track_of(&s, TrackKind::Audio, 1);
    let t = s.active_timeline().unwrap();
    assert_eq!(t.track(v2).unwrap().clips().len(), 2, "V2 cut");
    assert_eq!(t.track(a2).unwrap().clips().len(), 2, "A2 cut");
}

#[test]
fn add_edit_right_after_a_v2_drop_cuts_v2_and_a2() {
    // The drop selects the new picture and sound; Ctrl+K then acts on the tracks of that selection.
    let (mut s, v2) = session_with_a_drop_on_v2();
    s.seek(Time::seconds(4));
    s.add_edit_at_playhead(false);
    let a2 = track_of(&s, TrackKind::Audio, 1);
    let t = s.active_timeline().unwrap();
    assert_eq!(t.track(v2).unwrap().clips().len(), 2, "V2 cut");
    assert_eq!(t.track(a2).unwrap().clips().len(), 2, "A2 cut");
}

#[test]
fn add_edit_with_nothing_selected_after_a_v2_drop_follows_the_targets() {
    let (mut s, v2) = session_with_a_drop_on_v2();
    s.select(Default::default(), Default::default());
    s.seek(Time::seconds(4));
    s.add_edit_at_playhead(false);
    let a2 = track_of(&s, TrackKind::Audio, 1);
    let t = s.active_timeline().unwrap();
    println!(
        "nothing selected: V2 {} clips, A2 {} clips, targeted {:?}",
        t.track(v2).unwrap().clips().len(),
        t.track(a2).unwrap().clips().len(),
        t.tracks.iter().filter(|x| x.is_targeted).map(|x| x.id).collect::<Vec<_>>()
    );
}
