//! Session-level tests of the ES6 audio commands (Swift: AudioShortformSessionTests, AudioGainReportTests,
//! VoiceChainSessionTests, VoiceoverSessionTests, LiveDuckingSessionTests, ProposedCutSessionTests).

use std::collections::BTreeSet;

use sq_audiofx::track_preset::TrackPresetExt as _;
use sq_core_audio::audio_gain::AudioGain;
use sq_core_audio::live_ducking::{DefaultsStore, LiveDucking};
use sq_core_edit::proposed_cuts::{ProposedCutKind, TimelineProposedCutsExt};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_model::{AudioTag, Clip, Project, SequenceFormat, Timeline, Track, TrackKind, TrackPan};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};

use super::{AudioShortform, AudioTagMenuState};
use crate::{EditorSession, SessionDeps};

pub(crate) fn s(n: i64) -> Time {
    Time::new(n, 1)
}

pub(crate) const FD: Time = Time::new(1, 30);

/// No stored preferences.
pub(crate) struct NoDefaults;

impl DefaultsStore for NoDefaults {
    fn number(&self, _: &str) -> Option<f64> {
        None
    }
    fn set_number(&mut self, _: &str, _: f64) {}
    fn remove(&mut self, _: &str) {}
}

pub(crate) fn clip(ids: &mut SequentialIds, name: &str, kind: TrackKind, secs: i64, start: i64) -> Clip {
    Clip::new(ids.next_id(), name, ids.next_id(), kind, TimeRange::new(Time::ZERO, s(secs)), s(start))
}

pub(crate) fn session_with(tracks: Vec<Track>, ids: &mut SequentialIds) -> EditorSession {
    let tl = Timeline::new(ids.next_id(), "T", SequenceFormat::new(FD), tracks);
    let dir = std::env::temp_dir().join(format!("sq-es6-{}", std::process::id()));
    let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let mut deps = SessionDeps::headless(dir);
    deps.ids = Box::new(std::mem::take(ids)); // the session goes on counting where the fixture stopped
    EditorSession::new(project, deps)
}

pub(crate) fn track_of(ids: &mut SequentialIds, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(ids.next_id(), kind);
    for c in clips {
        t.overwrite(c, ids).expect("clip fits");
    }
    t
}

/// Video v (linked to audio a), music m, dialogue d, a third audio x.
struct Rig {
    sess: EditorSession,
    v: Clip,
    a: Clip,
    m: Clip,
    d: Clip,
    x: Clip,
}

fn rig() -> Rig {
    let mut ids = SequentialIds::default();
    let link = ids.next_id();
    let mut v = clip(&mut ids, "v", TrackKind::Video, 10, 0);
    let mut a = clip(&mut ids, "a", TrackKind::Audio, 10, 0);
    v.link = Some(link);
    a.link = Some(link);
    let mut m = clip(&mut ids, "m", TrackKind::Audio, 10, 0);
    let mut d = clip(&mut ids, "d", TrackKind::Audio, 10, 0);
    let x = clip(&mut ids, "x", TrackKind::Audio, 10, 0);
    m.audio_tag = Some(AudioTag::Music);
    d.audio_tag = Some(AudioTag::Dialogue);
    let tracks = vec![
        track_of(&mut ids, TrackKind::Video, vec![v.clone()]),
        track_of(&mut ids, TrackKind::Audio, vec![a.clone()]),
        track_of(&mut ids, TrackKind::Audio, vec![m.clone()]),
        track_of(&mut ids, TrackKind::Audio, vec![d.clone()]),
        track_of(&mut ids, TrackKind::Audio, vec![x.clone()]),
    ];
    Rig { sess: session_with(tracks, &mut ids), v, a, m, d, x }
}

fn get(sess: &EditorSession, id: Id) -> Clip {
    sess.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip")
}

fn select(sess: &mut EditorSession, ids: &[Id]) {
    sess.set_selection_raw(ids.iter().copied().collect());
}

fn role(sess: &EditorSession, track: usize) -> Option<AudioTag> {
    sess.active_timeline().expect("timeline").tracks[track].audio_role
}

fn quiet_from(secs: i64) -> impl Fn(&Clip) -> Vec<TimeRange> {
    move |_| vec![TimeRange::new(s(secs), s(10 - secs))]
}

const FADE: Time = Time::new(1, 2);

#[test]
fn bracket_keys_raise_three_clips_in_one_undo_step() {
    let Rig { mut sess, v, a, m, d, .. } = rig();
    select(&mut sess, &[v.id, a.id, m.id, d.id]);
    let depth = sess.undo_step_depth();
    assert!(sess.nudge_audio_gain(1.0));
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!([&a, &m, &d].iter().all(|c| get(&sess, c.id).audio_gain_db == 1.0));
    assert_eq!(get(&sess, v.id).audio_gain_db, 0.0); // video ignored
    assert!(sess.nudge_audio_gain(6.0));
    assert_eq!(get(&sess, a.id).audio_gain_db, 7.0);
    sess.undo();
    sess.undo();
    assert!([&a, &m, &d].iter().all(|c| get(&sess, c.id).audio_gain_db == 0.0));
}

#[test]
fn gain_stops_at_the_floor_and_does_not_mute() {
    let Rig { mut sess, a, v, .. } = rig();
    select(&mut sess, &[a.id]);
    for _ in 0..40 {
        sess.nudge_audio_gain(-6.0);
    }
    assert_eq!(get(&sess, a.id).audio_gain_db, AudioGain::MIN_GAIN_DB);
    assert!(sess.nudge_audio_gain(1.0));
    assert_eq!(get(&sess, a.id).audio_gain_db, AudioGain::MIN_GAIN_DB + 1.0);
    select(&mut sess, &[v.id]);
    assert!(!sess.nudge_audio_gain(1.0)); // only a video clip: nothing to do
}

#[test]
fn audio_gain_targets_follow_the_link_of_a_selected_video_clip() {
    let Rig { mut sess, v, a, .. } = rig();
    select(&mut sess, &[v.id]);
    assert_eq!(sess.audio_gain_targets().iter().map(|c| c.id).collect::<Vec<_>>(), vec![a.id]);
    let gains = [(a.id, 500.0)].into();
    assert!(sess.set_audio_gain(&gains));
    assert_eq!(get(&sess, a.id).audio_gain_db, AudioGain::MAX_GAIN_DB);
    assert!(!sess.set_audio_gain(&Default::default()));
}

#[test]
fn track_mix_is_clamped_and_one_undo_step() {
    let Rig { mut sess, .. } = rig();
    let tracks: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    let depth = sess.undo_step_depth();
    assert!(sess.set_track_mix(tracks[1], -200.0, 4.0));
    let t = &sess.active_timeline().expect("tl").tracks[1];
    assert_eq!((t.volume_db, t.pan), (TrackPan::MIN_VOLUME_DB, 1.0));
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!(!sess.set_track_mix(tracks[0], -3.0, 0.0)); // video track: refused
    sess.undo();
    let t = &sess.active_timeline().expect("tl").tracks[1];
    assert_eq!((t.volume_db, t.pan), (0.0, 0.0));
}

#[test]
fn track_mix_ignores_nan_and_unchanged_values_make_no_undo_step() {
    let Rig { mut sess, .. } = rig();
    let id = sess.active_timeline().expect("tl").tracks[1].id;
    let depth = sess.undo_step_depth();
    assert!(!sess.set_track_mix(id, 0.0, 0.0));
    assert_eq!(sess.undo_step_depth(), depth);
    assert!(!sess.set_track_mix(id, f64::NAN, f64::NAN)); // NaN reads as 0 dB / center
    let t = &sess.active_timeline().expect("tl").tracks[1];
    assert_eq!((t.volume_db, t.pan), (0.0, 0.0));
    assert_eq!(sess.undo_step_depth(), depth);
}

#[test]
fn sequence_volume_is_one_clamped_undo_step() {
    let Rig { mut sess, .. } = rig();
    let depth = sess.undo_step_depth();
    assert!(sess.set_sequence_volume(-6.0));
    assert_eq!(sess.active_timeline().expect("tl").master_volume_db(), -6.0);
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!(sess.set_sequence_volume(40.0));
    assert_eq!(sess.active_timeline().expect("tl").master_volume_db(), TrackPan::MAX_VOLUME_DB);
    assert!(!sess.set_sequence_volume(TrackPan::MAX_VOLUME_DB)); // unchanged: no undo step
    assert_eq!(sess.undo_step_depth(), depth + 2);
    sess.undo();
    sess.undo();
    assert_eq!(sess.active_timeline().expect("tl").master_volume_db(), 0.0);
}

#[test]
fn sequence_volume_keys_at_the_playhead_and_flattens_back() {
    let Rig { mut sess, .. } = rig();
    let depth = sess.undo_step_depth();
    sess.playhead = s(1);
    assert!(sess.set_sequence_volume_animated(-12.0, true));
    let tl = sess.active_timeline().expect("tl");
    assert!(tl.is_master_volume_keyed() && tl.master_volume_db_at(s(1)) == -12.0);
    sess.playhead = s(3);
    assert!(sess.set_sequence_volume_animated(0.0, true));
    assert_eq!(sess.active_timeline().expect("tl").master_volume_db_at(s(2)), -6.0);
    assert_eq!(sess.undo_step_depth(), depth + 2);
    assert!(sess.set_sequence_volume_animated(-3.0, false)); // unticked: keys go, the level stays constant
    let tl = sess.active_timeline().expect("tl");
    assert!(!tl.is_master_volume_keyed() && tl.master_volume_db() == -3.0);
    sess.undo();
    sess.undo();
    sess.undo();
    let tl = sess.active_timeline().expect("tl");
    assert!(!tl.is_master_volume_keyed() && tl.master_volume_db() == 0.0);
}

#[test]
fn tag_on_a_whole_track_sets_the_track_role() {
    // x is the only clip of its track: selecting it selects the whole track, so the Tag is the track's role (C18).
    let Rig { mut sess, x, .. } = rig();
    select(&mut sess, &[x.id]);
    let depth = sess.undo_step_depth();
    assert!(sess.toggle_audio_tag(AudioTag::Sfx));
    assert!(role(&sess, 4) == Some(AudioTag::Sfx) && get(&sess, x.id).audio_tag.is_none());
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!(sess.toggle_audio_tag(AudioTag::Sfx) && role(&sess, 4).is_none()); // the same tag again removes it
    assert!(sess.toggle_audio_tag(AudioTag::Music) && role(&sess, 4) == Some(AudioTag::Music));
    sess.undo();
    sess.undo();
    sess.undo();
    assert!(role(&sess, 4).is_none());
}

#[test]
fn locked_track_is_never_whole_so_its_clips_get_own_tags() {
    let Rig { mut sess, x, .. } = rig();
    assert!(sess.attempt_ids("lock", |t, _| {
        t.tracks[4].is_locked = true;
        Ok(())
    }));
    let whole = EditorSession::whole_tracks(&[x.id].into(), sess.active_timeline().expect("tl"));
    assert!(!whole.contains(&sess.active_timeline().expect("tl").tracks[4].id));
}

#[test]
fn tag_on_some_clips_of_a_track_tags_the_clips() {
    let Rig { mut sess, x, .. } = rig();
    let mut ids = SequentialIds::default();
    for _ in 0..500 {
        ids.next_id();
    }
    let x2 = clip(&mut ids, "x2", TrackKind::Audio, 5, 20);
    let x2id = x2.id;
    assert!(sess.attempt_ids("add", |t, i| {
        t.tracks[4].overwrite(x2, i)?;
        Ok(())
    }));
    select(&mut sess, &[x.id]); // x2 stays unselected
    assert!(
        sess.toggle_audio_tag(AudioTag::Sfx)
            && get(&sess, x.id).audio_tag == Some(AudioTag::Sfx)
            && role(&sess, 4).is_none()
    );
    assert!(sess.toggle_audio_tag(AudioTag::Sfx) && get(&sess, x.id).audio_tag.is_none());
    // Selecting both makes it the track's role again and drops the clip tag the first one had.
    assert!(sess.toggle_audio_tag(AudioTag::Music) && get(&sess, x.id).audio_tag == Some(AudioTag::Music));
    select(&mut sess, &[x.id, x2id]);
    assert!(sess.toggle_audio_tag(AudioTag::Dialogue) && role(&sess, 4) == Some(AudioTag::Dialogue));
    assert!(get(&sess, x.id).audio_tag.is_none() && get(&sess, x2id).audio_tag.is_none());
}

#[test]
fn tag_on_several_tracks_splits_by_coverage() {
    let Rig { mut sess, m, d, x, .. } = rig();
    select(&mut sess, &[m.id, d.id, x.id]);
    let depth = sess.undo_step_depth();
    assert!(sess.toggle_audio_tag(AudioTag::Sfx));
    assert!((2..=4).all(|i| role(&sess, i) == Some(AudioTag::Sfx)));
    assert!(get(&sess, m.id).audio_tag.is_none() && get(&sess, d.id).audio_tag.is_none());
    assert_eq!(sess.undo_step_depth(), depth + 1);
}

#[test]
fn tag_menu_shows_where_the_role_comes_from() {
    let Rig { mut sess, m, x, .. } = rig();
    select(&mut sess, &[x.id]);
    assert_eq!(sess.audio_tag_menu_state(AudioTag::Music), AudioTagMenuState::new(false, false, true));
    assert!(sess.toggle_audio_tag(AudioTag::Music)); // whole track: x inherits the track's role
    let inherited = sess.audio_tag_menu_state(AudioTag::Music);
    assert!(inherited.checked && inherited.inherited);
    assert_eq!(inherited.title(AudioTag::Music), "Music (inherits track role)");
    assert_eq!(sess.audio_tag_menu_state(AudioTag::Sfx).title(AudioTag::Sfx), "SFX");
    select(&mut sess, &[m.id]); // a clip with its own tag shows a plain check mark
    let own = sess.audio_tag_menu_state(AudioTag::Music);
    assert!(own.checked && !own.inherited && own.title(AudioTag::Music) == "Music");
    select(&mut sess, &[]);
    assert_eq!(sess.audio_tag_menu_state(AudioTag::Music), AudioTagMenuState::new(false, false, true));
}

#[test]
fn removing_a_tag_that_would_not_remove_the_role_is_disabled() {
    let Rig { mut sess, x, .. } = rig();
    let mut ids = SequentialIds::default();
    for _ in 0..500 {
        ids.next_id();
    }
    let x2 = clip(&mut ids, "x2", TrackKind::Audio, 5, 20);
    assert!(sess.attempt_ids("setup", |t, i| {
        t.tracks[4].overwrite(x2, i)?;
        t.tracks[4].audio_role = Some(AudioTag::Music);
        Ok(())
    }));
    // Partial selection, the clip inherits Music: there is no "no role" tag to give it, so the checked item is disabled.
    select(&mut sess, &[x.id]);
    let inherited = sess.audio_tag_menu_state(AudioTag::Music);
    assert!(inherited.checked && inherited.inherited && !inherited.enabled);
    let depth = sess.undo_step_depth();
    assert!(!sess.toggle_audio_tag(AudioTag::Music) && sess.undo_step_depth() == depth);
    // Its own tag equal to the track role: clearing it would leave Music in place, so also disabled.
    assert!(sess.attempt_ids("tag", |t, _| {
        let mut c = t.tracks[4].clips()[0].clone();
        c.audio_tag = Some(AudioTag::Music);
        t.replace_clip(c)
    }));
    assert!(!sess.audio_tag_menu_state(AudioTag::Music).enabled && !sess.toggle_audio_tag(AudioTag::Music));
    // A different role is still a normal, enabled choice.
    assert!(sess.audio_tag_menu_state(AudioTag::Sfx).enabled && !sess.audio_tag_menu_state(AudioTag::Sfx).checked);
    assert!(sess.toggle_audio_tag(AudioTag::Sfx) && get(&sess, x.id).audio_tag == Some(AudioTag::Sfx));
    // Removing it would hand the clip back to the track's Music: a re-role, so the item is disabled.
    assert!(!sess.audio_tag_menu_state(AudioTag::Sfx).enabled && !sess.toggle_audio_tag(AudioTag::Sfx));
    assert!(sess.toggle_audio_tag(AudioTag::Music) && get(&sess, x.id).audio_tag == Some(AudioTag::Music));
}

#[test]
fn removing_a_clip_tag_on_a_whole_track_never_re_roles_the_clips() {
    let Rig { mut sess, x, .. } = rig();
    assert!(sess.attempt_ids("setup", |t, _| {
        let mut c = t.tracks[4].clips()[0].clone();
        c.audio_tag = Some(AudioTag::Dialogue);
        t.replace_clip(c)?;
        t.tracks[4].audio_role = Some(AudioTag::Music);
        Ok(())
    }));
    select(&mut sess, &[x.id]); // the whole track
    let st = sess.audio_tag_menu_state(AudioTag::Dialogue);
    assert!(st.checked && !st.inherited && !st.enabled);
    let depth = sess.undo_step_depth();
    assert!(!sess.toggle_audio_tag(AudioTag::Dialogue) && sess.undo_step_depth() == depth);
    assert!(get(&sess, x.id).audio_tag == Some(AudioTag::Dialogue) && role(&sess, 4) == Some(AudioTag::Music));
}

#[test]
fn auto_duck_lowers_music_only_where_dialogue_is_and_rerun_replaces() {
    let Rig { mut sess, m, .. } = rig();
    select(&mut sess, &[]);
    let depth = sess.undo_step_depth();
    let off = Some(LiveDucking::new(0.0, FADE));
    // The dialogue clip is silent from 4 s on.
    let n = sess.bake_live_duck_to_keys(off.clone(), &NoDefaults, None, &quiet_from(4), 12.0, FADE);
    assert!(n > 0 && sess.undo_step_depth() == depth + 1);
    let c = get(&sess, m.id);
    assert!(c.animation.volume.value_at_local(s(2)) < 0.3 && c.animation.volume.value_at_local(s(8)) == 1.0);
    let n2 =
        sess.bake_live_duck_to_keys(off, &NoDefaults, None, &|_: &Clip| vec![TimeRange::new(s(0), s(6))], 12.0, FADE);
    let c2 = get(&sess, m.id);
    assert!(c2.animation.volume.value_at_local(s(2)) == 1.0 && c2.animation.volume.value_at_local(s(8)) < 0.3);
    assert_eq!(c2.animation.volume.track.keys.len(), n2);
}

#[test]
fn baked_duck_keys_are_current_until_dialogue_or_keys_change() {
    let Rig { mut sess, m, .. } = rig();
    select(&mut sess, &[]);
    let live = || Some(LiveDucking::new(0.0, FADE));
    let quiet = quiet_from(4);
    // Nothing baked yet: nothing to overwrite.
    assert!(sess.clips_with_changed_duck_keys(live(), &NoDefaults, None, &quiet, 12.0, FADE).is_empty());
    assert!(sess.bake_live_duck_to_keys(live(), &NoDefaults, None, &quiet, 12.0, FADE) > 0);
    // Same dialogue: current.
    assert!(sess.clips_with_changed_duck_keys(live(), &NoDefaults, None, &quiet, 12.0, FADE).is_empty());
    // Dialogue edited (the clip is now silent from 0 s): the keys are stale.
    let moved = |_: &Clip| vec![TimeRange::new(s(0), s(6))];
    assert_eq!(sess.clips_with_changed_duck_keys(live(), &NoDefaults, None, &moved, 12.0, FADE), vec![m.id]);
    // Asking does not change the sequence or the undo stack.
    let (depth, before) = (sess.undo_step_depth(), sess.active_timeline().cloned());
    let _ = sess.clips_with_changed_duck_keys(live(), &NoDefaults, None, &moved, 12.0, FADE);
    assert!(sess.undo_step_depth() == depth && sess.active_timeline().cloned() == before);
}

#[test]
fn hand_edited_duck_key_is_reported_before_bake_again() {
    let Rig { mut sess, m, .. } = rig();
    select(&mut sess, &[]);
    let live = || Some(LiveDucking::new(0.0, FADE));
    let quiet = quiet_from(4);
    assert!(sess.bake_live_duck_to_keys(live(), &NoDefaults, None, &quiet, 12.0, FADE) > 0);
    assert!(sess.attempt_ids("hand edit", |t, _| {
        let mut c = t.tracks.iter().find_map(|tr| tr.clip(m.id)).cloned().expect("clip");
        let key = c.duck_key_ids[0];
        for k in c.animation.volume.track.keys.iter_mut().filter(|k| k.id == key) {
            k.value = 0.9;
        }
        t.replace_clip(c)
    }));
    assert_eq!(sess.clips_with_changed_duck_keys(live(), &NoDefaults, None, &quiet, 12.0, FADE), vec![m.id]);
}

#[test]
fn no_dialogue_no_duck() {
    let Rig { mut sess, m, d, .. } = rig();
    select(&mut sess, &[d.id]);
    sess.toggle_audio_tag(AudioTag::Dialogue); // untag the only dialogue clip
    let depth = sess.undo_step_depth();
    assert_eq!(
        sess.bake_live_duck_to_keys(
            Some(LiveDucking::new(0.0, FADE)),
            &NoDefaults,
            None,
            &|_: &Clip| Vec::new(),
            12.0,
            FADE
        ),
        0
    );
    assert!(get(&sess, m.id).animation.volume.track.is_empty() && sess.undo_step_depth() == depth);
}

#[test]
fn removing_silences_is_one_undo_step_on_linked_tracks() {
    let Rig { mut sess, a, .. } = rig();
    select(&mut sess, &[a.id]);
    let pauses = |_: &Clip| vec![TimeRange::new(s(2), s(2)), TimeRange::new(s(6), s(3))];
    let cuts = sess.silence_cuts(std::slice::from_ref(&a), &pauses, Time::new(1, 10));
    assert_eq!(cuts.len(), 2);
    let depth = sess.undo_step_depth();
    assert!(sess.remove_silences(&cuts, std::slice::from_ref(&a), true));
    assert_eq!(sess.undo_step_depth(), depth + 1);
    let removed = cuts.iter().fold(Time::ZERO, |acc, c| acc + c.duration);
    let tl = sess.active_timeline().expect("tl");
    assert!(tl.tracks[0].end() == s(10) - removed && tl.tracks[1].end() == s(10) - removed); // the picture was cut as well
    sess.undo();
    assert_eq!(sess.active_timeline().expect("tl").tracks[0].end(), s(10));
}

#[test]
fn proposed_cuts_are_one_undo_step_and_rejecting_drops_them() {
    let Rig { mut sess, a, .. } = rig();
    select(&mut sess, &[a.id]);
    let depth = sess.undo_step_depth();
    assert!(sess.propose_cuts(&[TimeRange::new(s(2), s(2)), TimeRange::new(s(6), s(3))], ProposedCutKind::Silence));
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert_eq!(sess.active_timeline().expect("tl").proposed_cuts().len(), 2);
    sess.playhead = s(3);
    let under = sess.proposed_cut_at_playhead().expect("under the playhead");
    assert_eq!(sess.active_timeline().expect("tl").proposed_cuts()[0].id, under);
    sess.playhead = s(5);
    let next = sess.proposed_cut_at_playhead().expect("next");
    assert_eq!(sess.active_timeline().expect("tl").proposed_cuts()[1].id, next);
    assert!(sess.reject_proposed_cuts(Some(&[under].into())));
    assert_eq!(sess.active_timeline().expect("tl").proposed_cuts().len(), 1);
    assert!(sess.reject_proposed_cuts(None) && !sess.reject_proposed_cuts(None));
}

#[test]
fn accepting_proposed_silences_cuts_the_audio_and_the_linked_picture() {
    let Rig { mut sess, a, .. } = rig();
    select(&mut sess, &[a.id]);
    assert!(sess.propose_cuts(&[TimeRange::new(s(2), s(2))], ProposedCutKind::Silence));
    assert!(sess.accept_proposed_cuts(None, true));
    let tl = sess.active_timeline().expect("tl");
    assert!(tl.proposed_cuts().is_empty());
    assert_eq!((tl.tracks[0].end(), tl.tracks[1].end()), (s(8), s(8)));
    // A review that accepts nothing is the same as rejecting all.
    assert!(sess.propose_cuts(&[TimeRange::new(s(1), s(1))], ProposedCutKind::Silence));
    assert!(sess.review_proposed_cuts(&BTreeSet::new(), true));
    assert!(sess.active_timeline().expect("tl").proposed_cuts().is_empty());
}

#[test]
fn scene_changes_are_proposed_inside_the_clip_on_the_frame_grid() {
    let Rig { mut sess, v, .. } = rig();
    let vclip = get(&sess, v.id);
    let inside = EditorSession::scene_times(&vclip, &[s(0), Time::new(3, 1) + Time::new(1, 90), s(10), s(12)], FD);
    assert_eq!(inside, vec![s(3)]);
    select(&mut sess, &[v.id]);
    let n = sess.find_scene_changes(&[vclip], &mut |_| Ok(vec![s(2), s(2), s(5)]), &|| false);
    assert_eq!(n, Some(2));
    assert_eq!(sess.active_timeline().expect("tl").proposed_cuts().len(), 2);
    let gone = sess.find_scene_changes(&sess.scene_change_targets(), &mut |_| Err("unreadable".into()), &|| false);
    assert_eq!(gone, None);
    assert_eq!(sess.last_error(), Some("unreadable"));
}

#[test]
fn voice_chain_sets_the_dialogue_role_in_one_undo_step_and_toggles() {
    let mut ids = SequentialIds::default();
    let a = clip(&mut ids, "a", TrackKind::Audio, 4, 0);
    let b = clip(&mut ids, "b", TrackKind::Audio, 4, 0);
    let tracks =
        vec![track_of(&mut ids, TrackKind::Audio, vec![a.clone()]), track_of(&mut ids, TrackKind::Audio, vec![b])];
    let mut sess = session_with(tracks, &mut ids);
    select(&mut sess, &[a.id]);
    let depth = sess.undo_step_depth();
    assert!(sess.toggle_voice_chain());
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!(role(&sess, 0) == Some(AudioTag::Dialogue) && role(&sess, 1).is_none());
    assert!(sess.voice_chain_active());
    assert!(sess.toggle_voice_chain());
    assert!(role(&sess, 0).is_none());
    sess.undo();
    assert_eq!(role(&sess, 0), Some(AudioTag::Dialogue));
    // The readout is empty when nothing is measurable, and measuring changes nothing.
    let depth = sess.undo_step_depth();
    assert!(sess.voice_chain_readout(&mut |_, _| None).is_none());
    assert_eq!(sess.undo_step_depth(), depth);
    let readout = sess.voice_chain_readout(&mut |_, _| Some(-20.0)).expect("measurable");
    assert_eq!((readout.lufs, readout.target_lufs), (-20.0, -14.0));
}

#[test]
fn track_role_is_set_cleared_and_refused_on_video() {
    let Rig { mut sess, .. } = rig();
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Music)));
    assert!(!sess.set_track_audio_role(ids[1], Some(AudioTag::Music))); // unchanged
    assert!(!sess.set_track_audio_role(ids[0], Some(AudioTag::Music))); // video
    assert!(sess.set_track_audio_role(ids[1], None) && role(&sess, 1).is_none());
}

#[test]
fn track_audio_tweaks_are_saved_undone_and_coalesced() {
    use sq_audiofx::presets::TrackAudioPreset;
    let Rig { mut sess, .. } = rig();
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    let stored = |s: &EditorSession| s.active_timeline().expect("tl").tracks[1].audio_preset.clone();
    let mut p = TrackAudioPreset::voice();
    assert!(sess.set_track_audio_preset(ids[1], Some(&p), false) && stored(&sess).is_some());
    assert!(!sess.set_track_audio_preset(ids[1], Some(&p), false), "unchanged");
    assert!(!sess.set_track_audio_preset(ids[0], Some(&p), false), "video");
    // A drag is one undo step.
    for (i, g) in [-31.0, -29.0, -27.0].into_iter().enumerate() {
        p.compressor.bands[0].threshold_db = g;
        assert!(sess.set_track_audio_preset(ids[1], Some(&p), i > 0));
    }
    assert!(sess.undo());
    assert_eq!(stored(&sess), serde_json::to_value(TrackAudioPreset::voice()).ok(), "the drag undoes at once");
    assert!(sess.undo() && stored(&sess).is_none());
    assert!(sess.redo() && stored(&sess).is_some());
}

#[test]
fn a_new_role_keeps_the_typed_chain_and_replaces_an_untouched_one() {
    use sq_audiofx::presets::TrackAudioPreset;
    let Rig { mut sess, .. } = rig();
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    let stored = |s: &EditorSession| s.active_timeline().expect("tl").tracks[1].audio_preset.clone();
    // An EQ typed on top of the Dialogue chain: 200 Hz corner, +6 dB low shelf.
    let mut typed = TrackAudioPreset::for_role(AudioTag::Dialogue);
    typed.compressor.eq_on = true;
    typed.compressor.crossovers_hz[0] = 200.0;
    typed.compressor.bands[0].gain_db = 6.0;
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Dialogue)));
    assert!(sess.set_track_audio_preset(ids[1], Some(&typed), false));
    let before = stored(&sess);
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Music)));
    assert_eq!(role(&sess, 1), Some(AudioTag::Music));
    assert_eq!(stored(&sess), before, "the typed EQ survives the role change");
    // Picking the same role again is the way back to its voiced preset.
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Music)) && stored(&sess).is_none());
    // A chain equal to the old role's voiced preset was never touched: the new role replaces it.
    assert!(sess.set_track_audio_preset(ids[1], Some(&TrackAudioPreset::for_role(AudioTag::Music)), false));
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Sfx)) && stored(&sess).is_none());
    // The saved track carries the EQ through a save and reopen.
    assert!(sess.set_track_audio_preset(ids[1], Some(&typed), false));
    let track = sess.active_timeline().expect("tl").tracks[1].clone();
    let reopened: sq_core_model::Track =
        serde_json::from_value(serde_json::to_value(&track).expect("save")).expect("open");
    let back: TrackAudioPreset = serde_json::from_value(reopened.audio_preset.expect("preset")).expect("preset");
    assert!(back.compressor.eq_on);
    assert_eq!((back.compressor.crossovers_hz[0], back.compressor.bands[0].gain_db), (200.0, 6.0));
}

#[test]
fn the_same_role_again_takes_the_voiced_preset_back_from_a_picked_preset() {
    use sq_audiofx::presets::TrackAudioPreset;
    let Rig { mut sess, .. } = rig();
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    let stored = |s: &EditorSession| s.active_timeline().expect("tl").tracks[1].audio_preset.clone();
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Dialogue)));
    assert!(sess.set_track_audio_preset(ids[1], Some(&TrackAudioPreset::music()), false));
    assert!(sess.set_track_audio_role(ids[1], Some(AudioTag::Dialogue)) && stored(&sess).is_none());
    assert!(!sess.set_track_audio_role(ids[1], Some(AudioTag::Dialogue)), "nothing left to change");
    assert!(sess.undo() && stored(&sess).is_some(), "one undo step brings the picked preset back");
}

#[test]
fn a_track_loudness_target_is_set_cleared_undone_and_refused_on_video() {
    let Rig { mut sess, .. } = rig();
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    let target = |s: &EditorSession| s.active_timeline().expect("tl").tracks[1].loudness_target_lufs;
    assert!(sess.set_track_loudness_target(ids[1], Some(-23.0)) && target(&sess) == Some(-23.0));
    assert!(!sess.set_track_loudness_target(ids[1], Some(-23.0))); // unchanged
    assert!(!sess.set_track_loudness_target(ids[0], Some(-23.0))); // video
    assert!(sess.undo() && target(&sess).is_none(), "one undo step");
    assert!(sess.set_track_loudness_target(ids[1], Some(-16.0)) && sess.set_track_loudness_target(ids[1], None));
    assert!(target(&sess).is_none());
}

#[test]
fn match_loudness_sets_gain_so_each_run_reaches_its_target() {
    let Rig { mut sess, a, m, .. } = rig();
    select(&mut sess, &[a.id, m.id]);
    // Dialogue/untagged track measures -24 LUFS (target -14), music -20 (target -20).
    let mut measure = |t: &Timeline, _r: TimeRange| -> Option<f64> {
        let first = t.tracks[0].clips()[0].name.clone();
        Some(if first == "m" { -20.0 } else { -24.0 })
    };
    let depth = sess.undo_step_depth();
    assert_eq!(sess.match_loudness(&mut measure), 2);
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert_eq!(get(&sess, a.id).audio_gain_db, 10.0);
    assert_eq!(get(&sess, m.id).audio_gain_db, 0.0);
    // Silence stays as it is.
    select(&mut sess, &[a.id]);
    assert_eq!(sess.match_loudness(&mut |_, _| None), 0);
}

#[test]
fn nudge_report_names_step_and_new_gain() {
    let mut ids = SequentialIds::default();
    let mut c = clip(&mut ids, "a", TrackKind::Audio, 10, 0);
    c.audio_gain_db = 2.0;
    let tracks = vec![track_of(&mut ids, TrackKind::Audio, vec![c.clone()])];
    let mut sess = session_with(tracks, &mut ids);
    assert_eq!(sess.nudge_audio_gain_report(1.0), None); // nothing selected
    select(&mut sess, &[c.id]);
    assert_eq!(sess.nudge_audio_gain_report(1.0).as_deref(), Some("Gain +1 dB (now +3 dB)"));
    assert_eq!(sess.nudge_audio_gain_report(-6.0).as_deref(), Some("Gain -6 dB (now -3 dB)"));
    assert_eq!(sess.nudge_audio_gain_report(3.0).as_deref(), Some("Gain +3 dB (now 0 dB)"));
}

#[test]
fn nudge_report_counts_clips_with_different_gains_and_names_the_limit() {
    let mut ids = SequentialIds::default();
    let mut c1 = clip(&mut ids, "a", TrackKind::Audio, 10, 0);
    let mut c2 = clip(&mut ids, "b", TrackKind::Audio, 10, 0);
    (c1.audio_gain_db, c2.audio_gain_db) = (AudioGain::MIN_GAIN_DB + 2.0, 0.0);
    let tracks = vec![
        track_of(&mut ids, TrackKind::Audio, vec![c1.clone()]),
        track_of(&mut ids, TrackKind::Audio, vec![c2.clone()]),
    ];
    let mut sess = session_with(tracks, &mut ids);
    select(&mut sess, &[c1.id, c2.id]);
    // The first clip can only move 2 dB down, the second the full 6: the report names what happened to the second.
    assert!(sess.nudge_audio_gain_report(-6.0).is_some_and(|r| r.starts_with("Gain -6 dB")));
    assert!(sess.nudge_audio_gain_report(-6.0).is_some());
    for _ in 0..20 {
        sess.nudge_audio_gain_report(-6.0);
    }
    assert_eq!(sess.nudge_audio_gain_report(-6.0).as_deref(), Some("Gain at limit"));
}

#[test]
fn voiceover_lands_on_a_free_dialogue_track_and_is_selected() {
    let Rig { mut sess, .. } = rig();
    let mut ids = SequentialIds::default();
    for _ in 0..800 {
        ids.next_id();
    }
    let media = ids.next_id();
    let depth = sess.undo_step_depth();
    sess.playhead = s(2);
    let placed = sess.place_voiceover(media, "VO", s(3), None).expect("placed");
    assert_eq!(sess.undo_step_depth(), depth + 1);
    let c = get(&sess, placed.clip);
    assert_eq!((c.start, c.media), (s(2), media));
    assert!(sess.selection().contains(&placed.clip));
    assert_eq!(
        sess.active_timeline().expect("tl").track(placed.track).and_then(|t| t.audio_role),
        Some(AudioTag::Dialogue)
    );
    assert!(sess.place_voiceover(media, "VO", Time::ZERO, None).is_none()); // zero length is refused
}

#[test]
fn live_ducking_settings_are_undoable_and_project_choices_apply() {
    use sq_core_model::ProjectLiveDucking;
    let Rig { mut sess, .. } = rig();
    let depth = sess.undo_step_depth();
    let setting = ProjectLiveDucking { is_on: true, amount_db: 12.0, timing: None };
    sess.set_project_live_ducking(Some(setting.clone()));
    sess.set_project_live_ducking(Some(setting)); // unchanged: no second step
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert_eq!(sess.effective_live_ducking(&NoDefaults).map(|d| d.amount_db), Some(12.0));
    sess.undo();
    assert!(sess.effective_live_ducking(&NoDefaults).is_none());
    let ids: Vec<Id> = sess.active_timeline().expect("tl").tracks.iter().map(|t| t.id).collect();
    assert!(sess.set_track_excluded_from_live_ducking(ids[2], true));
    assert!(!sess.set_track_excluded_from_live_ducking(ids[2], true)); // already excluded
    assert!(!sess.set_track_excluded_from_live_ducking(ids[0], true)); // video
    assert!(sess.set_track_excluded_from_live_ducking(ids[2], false));
}

#[test]
fn add_subject_mask_needs_a_free_video_clip() {
    let Rig { mut sess, v, a, .. } = rig();
    select(&mut sess, &[a.id]);
    assert!(!sess.add_subject_mask_enabled() && !sess.add_subject_mask()); // audio: nothing to mask
    select(&mut sess, &[v.id]);
    assert!(sess.add_subject_mask_enabled());
    let depth = sess.undo_step_depth();
    assert!(sess.add_subject_mask());
    assert_eq!(sess.undo_step_depth(), depth + 1);
    assert!(!sess.add_subject_mask_enabled() && !sess.add_subject_mask()); // it has one now
}

#[test]
fn audio_shortform_helpers_join_split_and_subtract_ranges() {
    let r = |a: i64, d: i64| TimeRange::new(s(a), s(d));
    assert_eq!(AudioShortform::active_ranges(r(10, 10), &[r(12, 2), r(18, 5)]), vec![r(10, 2), r(14, 4)]);
    assert_eq!(AudioShortform::active_ranges(r(0, 4), &[]), vec![r(0, 4)]);
    assert_eq!(AudioShortform::merged(&[r(5, 2), r(1, 2), r(2, 2), r(7, 1)]), vec![r(1, 3), r(5, 3)]);
    assert_eq!(AudioShortform::subtract(&[r(2, 2)], &[r(0, 10)]), vec![r(0, 2), r(4, 6)]);
    // A range is silent only where every covering clip is silent; gaps between clips are not pauses.
    let both = AudioShortform::combined_silences(&[(r(0, 10), vec![r(2, 4)]), (r(0, 10), vec![r(4, 4)])]);
    assert_eq!(both, vec![r(4, 2)]);
    let apart = AudioShortform::combined_silences(&[(r(0, 4), vec![r(1, 1)]), (r(6, 4), vec![r(7, 1)])]);
    assert_eq!(apart, vec![r(1, 1), r(7, 1)]);
}

#[test]
fn silences_come_from_waveform_peaks() {
    // Mono, 1000 frames/s, 10 buckets of 1000 frames each = 1 s per bucket: loud, quiet x3, loud.
    let peaks = vec![-0.5, 0.5, -0.001, 0.001, -0.001, 0.001, -0.001, 0.001, -0.5, 0.5];
    let data = sq_media::waveform_data::WaveformData::new(1000, 1, 5000, 1000, vec![peaks]);
    let mut ids = SequentialIds::default();
    let c = clip(&mut ids, "c", TrackKind::Audio, 5, 20);
    let r = AudioShortform::silences_in(&c, &data, 0.0, -40.0, s(1));
    assert_eq!(r.len(), 1);
    assert_eq!((r[0].start, r[0].end()), (s(21), s(24)));
}

#[test]
fn audible_tracks_respect_mute_and_solo() {
    let Rig { mut sess, .. } = rig();
    assert_eq!(AudioShortform::audible_tracks(sess.active_timeline().expect("tl")).len(), 4);
    assert!(sess.attempt_ids("mix", |t, _| {
        t.tracks[1].is_muted = true;
        t.tracks[3].is_solo = true;
        Ok(())
    }));
    let heard = AudioShortform::audible_tracks(sess.active_timeline().expect("tl"));
    assert_eq!(heard.len(), 1);
    assert!(heard[0].is_solo);
}

/// Writes `on.sqproj` (compressor on) and `off.sqproj` (compressor bypassed) of one loud tone into `$SQ_FIXTURE_DIR`, for the
/// `--export` check of the track tweaks (the tone is `$SQ_FIXTURE_DIR/tone.wav`). Run it by hand: `--ignored`.
#[test]
#[ignore = "writes fixture projects for a manual export check"]
fn write_tone_projects_for_the_export_check() {
    use sq_audiofx::presets::{MultibandBand, MultibandCompressorSettings, TrackAudioPreset};

    use sq_core_model::{MediaFingerprint, MediaRef};
    let dir = std::path::PathBuf::from(std::env::var("SQ_FIXTURE_DIR").expect("SQ_FIXTURE_DIR"));
    let media = Id::from_u128(100);
    let tone = MediaRef::new(media, "tone", &dir.join("tone.wav").to_string_lossy(), MediaFingerprint::new(1));
    for (name, bypass) in [("on", false), ("off", true)] {
        let mut preset = TrackAudioPreset::new(
            "x",
            "x",
            MultibandCompressorSettings::new(
                vec![120.0, 900.0, 4500.0],
                vec![MultibandBand::new(-20.0, 4.0, 1.0, 50.0); 4],
            ),
        )
        .with_noise_reduction(0.0);
        preset.compressor.bypass = bypass;
        let mut track = Track::new(Id::from_u128(901), TrackKind::Audio);
        let source = TimeRange::new(Time::ZERO, Time::seconds(3));
        track.set_clips(vec![Clip::new(Id::from_u128(11), "a", media, TrackKind::Audio, source, Time::ZERO)]);
        track.set_audio_preset(Some(&preset));
        let tl = Timeline::new(Id::from_u128(1), "tone", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        let project = Project::new(Id::from_u128(5), name, vec![tone.clone()], vec![tl]);
        sq_core_project::project_file::project_file()
            .write(&project, &dir.join(format!("{name}.sqproj")))
            .expect("write");
    }
}
