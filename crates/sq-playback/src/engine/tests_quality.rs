// SPDX-License-Identifier: GPL-3.0-or-later
//! The automatic quality step must not leave a hole: decodes queued at the old quality stop between pictures, so the
//! first picture of the new quality arrives after about one decode, not after the whole old backlog.

use super::testkit::*;
use sq_core_edit::playback::PlaybackRate;
use sq_media::video_decoding::DecodeScale;
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

#[test]
fn a_quality_step_waits_for_at_most_one_old_decode() {
    const PER_PICTURE: Duration = Duration::from_millis(60);
    let rig = Rig::new(|_| {});
    let log = rig.opener.add_streaming("a.mov", 250, PER_PICTURE);
    rig.media(&[(id(100), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, id(100), 0, 0, 8)]]), HashMap::new());
    rig.handle.play(PlaybackRate::FORWARD);
    // The decoder is slower than the clock: a backlog of full-quality pictures builds up.
    rig.wait("full pictures", |e| e.cache_len_at(1) >= 3);
    std::thread::sleep(Duration::from_millis(600));
    let at = Instant::now();
    rig.handle.set_quality(DecodeScale::Half);
    rig.handle.sync();
    // The full pictures still stand in while the first half picture is on its way: no hole, nothing blanked.
    let (old, shown) = rig.handle.query(|e| (e.cache_len_at(1), e.has_shown())).unwrap_or_default();
    assert!(old >= 1, "the old pictures were dropped at the step");
    assert!(shown, "the shown frame was blanked at the step");
    rig.wait("a half picture", |e| e.cache_len_at(2) >= 1);
    let gap = at.elapsed();
    assert!(gap < PER_PICTURE * 4, "the first half picture came after {gap:?}; the old backlog was decoded first");
    assert!(log.streamed.load(Ordering::SeqCst) > 0);
}

#[test]
fn a_quality_step_during_play_does_not_decode_again_what_already_stands_in() {
    const PER_PICTURE: Duration = Duration::from_millis(5);
    let rig = Rig::new(|_| {});
    let log = rig.opener.add_streaming("a.mov", 250, PER_PICTURE);
    rig.media(&[(id(100), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, id(100), 0, 0, 8)]]), HashMap::new());
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("a read-ahead of full pictures", |e| e.cache_len_at(1) >= 8);
    rig.handle.set_quality(DecodeScale::Half);
    rig.handle.sync();
    let (last_full, shown) = rig.handle.query(|e| (e.cache_last_index_at(1), e.has_shown())).unwrap_or_default();
    let last_full = last_full.unwrap_or(0);
    assert!(shown, "the shown frame was blanked at the step: a frame without a picture");
    let ranges_before = log.ranges().len();
    rig.wait("a half picture", |e| e.cache_len_at(2) >= 1);
    // The new quality continues after the last full picture; nothing before it is decoded twice. One range may overlap the
    // frames that were still in flight at the step.
    for (lo, _) in log.ranges().into_iter().skip(ranges_before) {
        assert!(
            lo as i64 + 4 >= last_full,
            "frame {lo} was decoded again at Half, the full picture up to {last_full} stands in"
        );
    }
}

#[test]
fn an_up_step_during_play_decodes_full_pictures_again_for_the_frames_ahead() {
    const PER_PICTURE: Duration = Duration::from_millis(5);
    let rig = Rig::new(|_| {});
    rig.opener.add_streaming("a.mov", 250, PER_PICTURE);
    rig.media(&[(id(100), "a.mov")]);
    rig.handle.set_quality(DecodeScale::Half);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, id(100), 0, 0, 8)]]), HashMap::new());
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("a read-ahead of half pictures", |e| e.cache_len_at(2) >= 8);
    rig.handle.set_quality(DecodeScale::Full);
    rig.wait("full pictures after the up-step", |e| e.cache_len_at(1) >= 8);
}

#[test]
fn finer_pictures_left_by_the_paused_frame_satisfy_the_pre_roll_and_count_as_exact() {
    use sq_core_model::AnimatedProperty;
    use sq_core_time::Vec2;
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(id(100), "a.mov")]);
    // A layer drawn at 0.4 scale: playing reads half pictures, the paused frame and its fill are full pictures.
    let mut c = clip(10, id(100), 0, 0, 8);
    c.animation.scale = AnimatedProperty::new(Vec2::new(0.4, 0.4));
    rig.handle.set_timeline(timeline(vec![vec![c]]), HashMap::new());
    rig.wait("the paused fill", |e| e.cache_len_at(1) >= 12);
    let at = Instant::now();
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("the clock starts", |e| !e.clock_is_held());
    // The frames ahead are there as full pictures and are never decoded again at half while playing, so waiting for half
    // pictures would run out the whole pre-roll limit.
    assert!(at.elapsed() < Duration::from_millis(400), "the pre-roll waited {:?}", at.elapsed());
    let shown = rig.handle.latest_shown().expect("a shown frame");
    assert!(shown.exact, "a frame drawn from a finer picture is not a stand-in");
}
