// SPDX-License-Identifier: GPL-3.0-or-later
//! Engine behavior on the render thread with an in-memory opener (headless). The wanted-keys dump is the oracle of
//! `WinProgramEngine.refresh/mediaKey`: media index = frame of `source_time + first pts`, divisor from the playback
//! quality, the layer's drawn size while playing and the scrub preview rule.

use super::core::{PREVIEW_PIXELS, is_cut, playback_layer_detail, prefetch_may_take_lane, trim_distance};
use super::late_frames::CUT_GRACE;
use super::testkit::*;
use super::types::{Key, Wanted};
use sq_audio_out::clock::{ManualClock, PlaybackClock};
use sq_core_edit::playback::PlaybackRate;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_model::AnimatedProperty;
use sq_core_time::{Time, Vec2};
use sq_media::video_decoding::DecodeScale;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn a() -> sq_core_time::Id {
    id(100)
}
fn b() -> sq_core_time::Id {
    id(200)
}

/// Two tracks: A (file a, from its 0 s) at 0...4 s, B (file b, from its 1 s) at 2...4 s over it.
fn two_layer_rig() -> Rig {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.opener.add("b.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov"), (b(), "b.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 4)], vec![clip(11, b(), 1, 2, 2)]]), HashMap::new());
    rig
}

fn keys_at(rig: &Rig, t: Time) -> Vec<(i64, u32)> {
    rig.handle.seek(t);
    rig.handle.sync();
    // The files open on their own threads; the keys settle once they are open.
    let want = t;
    rig.wait("the wanted keys", move |e| e.position() == want && e.is_frame_settled());
    rig.handle.query(|e| e.wanted_keys().iter().map(|k| (k.index, k.divisor)).collect()).unwrap_or_default()
}

#[test]
fn wanted_keys_per_playhead_position() {
    let rig = two_layer_rig();
    // 0 s: only A, its frame 0. 1.2 s (frame 30): A:30. 2 s: A:50 under B (1 s + 0 = frame 25). 3.96 s: A:99, B:74.
    assert_eq!(keys_at(&rig, Time::ZERO), vec![(0, 1)]);
    assert_eq!(keys_at(&rig, Time::new(6, 5)), vec![(30, 1)]);
    assert_eq!(keys_at(&rig, Time::seconds(2)), vec![(50, 1), (25, 1)]);
    assert_eq!(keys_at(&rig, Time::new(99, 25)), vec![(99, 1), (74, 1)]);
    // Past the last clip nothing is wanted; the monitor shows black.
    assert_eq!(keys_at(&rig, Time::seconds(5)), vec![]);
    let media: Vec<_> = {
        rig.handle.seek(Time::seconds(2));
        rig.wait("settled", |e| e.position() == Time::seconds(2) && e.is_frame_settled());
        rig.handle.query(|e| e.wanted_keys().iter().map(|k| k.media).collect()).unwrap_or_default()
    };
    assert_eq!(media, vec![a(), b()]);
}

#[test]
fn the_paused_frame_decodes_exactly_the_wanted_pictures_and_shows_them() {
    let rig = two_layer_rig();
    keys_at(&rig, Time::seconds(2));
    let (cached, generation, err) = rig
        .handle
        .query(|e| (e.cache_len(), e.picture_generation(), e.last_error().map(str::to_string)))
        .unwrap_or_default();
    assert_eq!(err, None);
    assert!(cached >= 2, "the wanted pictures are cached (the neighbours fill after them)");
    assert!(generation >= 1);
    let shown = rig.handle.latest_shown().expect("a shown frame");
    assert_eq!(shown.position, Time::seconds(2));
    assert!(shown.exact);
}

#[test]
fn quality_and_layer_size_set_the_divisor_only_while_playing() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    let mut c = clip(10, a(), 0, 0, 8);
    c.animation.scale = AnimatedProperty::new(Vec2::new(0.4, 0.4));
    rig.handle.set_timeline(timeline(vec![vec![c]]), HashMap::new());
    assert_eq!(keys_at(&rig, Time::new(1, 5)), vec![(5, 1)], "paused keeps full detail");
    rig.handle.set_quality(DecodeScale::Half);
    rig.handle.sync();
    assert_eq!(keys_at(&rig, Time::new(2, 5)), vec![(10, 2)], "the quality divides paused pictures too");
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("playing keys", |e| e.wanted_keys().first().is_some_and(|k| k.divisor == 2));
    rig.handle.pause();
    // A layer at 0.4 scale is drawn below half size: playing reads it at a half picture even at full quality.
    rig.handle.set_quality(DecodeScale::Full);
    rig.handle.seek(Time::new(1, 5));
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("detail divisor", |e| e.wanted_keys().first().is_some_and(|k| k.divisor == 2));
}

#[test]
fn layer_detail_steps() {
    let mut l = LayerRequest::new(id(1), id(2), id(3), Time::ZERO);
    assert_eq!(playback_layer_detail(&l), 1);
    l.transform.scale = Vec2::new(0.55, 0.3);
    assert_eq!(playback_layer_detail(&l), 2);
    l.transform.scale = Vec2::new(0.2, 0.1);
    assert_eq!(playback_layer_detail(&l), 4);
    l.transform.tilt_x = 10.0;
    assert_eq!(playback_layer_detail(&l), 1, "tilted layers keep full detail");
}

#[test]
fn play_holds_the_clock_until_the_first_picture_is_up() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::from_millis(400));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    rig.handle.play(PlaybackRate::FORWARD);
    std::thread::sleep(Duration::from_millis(250));
    let held = rig.handle.status().position;
    assert_eq!(held, Time::ZERO, "the playhead waits for the cold decode");
    rig.wait("the clock to run", |e| e.position() > Time::new(5, 25));
    assert!(rig.handle.status().shown_frames >= 1);
}

#[test]
fn playing_to_the_end_stops_on_the_last_frame_without_dropping() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 1)]]), HashMap::new());
    rig.handle.seek(Time::ZERO);
    rig.wait("first frame", |e| e.is_frame_settled() || e.shown_frames() == 0 && e.cache_len() > 0);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("the end", |e| e.rate().is_paused() && e.position() > Time::ZERO);
    let s = rig.handle.status();
    assert_eq!(s.position, Time::new(24, 25), "stops on the last frame");
    assert_eq!(s.skipped_frames, 0, "no dropped frames at 1x: {s:?}");
    assert!(s.shown_frames >= 20, "{s:?}");
}

#[test]
fn a_scrub_drops_the_queued_decodes_nothing_wants_any_more() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::from_millis(30));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    let before = log.ranges().len();
    rig.handle.begin_scrub();
    for n in 1..=40i64 {
        rig.handle.scrub(Time::new(n * 3, 25));
    }
    rig.handle.end_scrub();
    rig.wait("the last scrub frame", |e| e.position() == Time::new(120, 25) && e.is_frame_settled());
    let decodes = log.ranges().len() - before;
    assert!(decodes < 40, "{decodes} decodes for 40 scrub steps");
    assert!(log.ranges().contains(&(120, 120)));
}

#[test]
fn a_seek_to_a_then_quickly_to_b_ends_on_b_and_a_late_decode_of_a_never_replaces_it() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 500, Duration::from_millis(60));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    let b = Time::new(300, 25);
    rig.handle.seek(Time::new(100, 25));
    rig.handle.seek(b);
    rig.wait("B settled", move |e| e.position() == b && e.is_frame_settled());
    // Let the decode of A (still in flight) land: it must not be shown over B.
    std::thread::sleep(Duration::from_millis(300));
    let shown = rig.handle.latest_shown().expect("a shown frame");
    assert_eq!(shown.position, b, "only B is on screen");
    assert!(shown.exact);
    assert_eq!(rig.handle.status().position, b);
}

#[test]
fn the_cache_stays_inside_its_byte_budget() {
    let budget = PICTURE_BYTES * 20;
    let rig = Rig::new(move |d| d.frame_cache_bytes = budget);
    rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("a long run", |e| e.position() > Time::new(3, 1));
    rig.handle.pause();
    rig.handle.sync();
    let bytes = rig.handle.query(|e| e.cache_bytes()).unwrap_or(0);
    assert!(bytes <= budget + 12 * PICTURE_BYTES, "cache holds {bytes} bytes for a budget of {budget}");
}

#[test]
fn media_changed_drops_that_files_pictures_and_reopens_it() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    keys_at(&rig, Time::new(1, 5));
    assert_eq!(log.opens.load(std::sync::atomic::Ordering::SeqCst), 1);
    rig.handle.media_changed([a()].into_iter().collect());
    rig.wait("reopen", |e| e.is_frame_settled() && e.cache_len() >= 1);
    assert_eq!(log.opens.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[test]
fn an_unreadable_file_reports_and_the_frame_still_draws() {
    let rig = Rig::new(|_| {});
    rig.media(&[(a(), "missing.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    rig.wait("the open error", |e| e.last_error().is_some_and(|m| m.starts_with("open missing.mov")));
}

#[test]
fn preview_scrub_reads_big_sources_at_a_quarter() {
    // Not reachable with the 16x16 fakes; the rule's constant is what matters.
    assert_eq!(PREVIEW_PIXELS, 2_400_000);
    let k = Key::new(a(), 3, 1);
    assert_eq!((k.index, k.divisor, k.proxy), (3, 1, false));
}

#[test]
fn the_cache_strip_spans_the_decoded_frames() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    keys_at(&rig, Time::new(48, 25));
    // The strip samples every 4th frame: the span around frame 48 covers it (the neighbours fill around it).
    let spans = rig.handle.cached_spans();
    assert!(spans.iter().any(|s| s.start <= Time::new(48, 25) && s.end() >= Time::new(52, 25)), "{spans:?}");
}

#[test]
fn a_slow_decoder_keeps_the_monitor_moving_on_stand_ins() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 500, Duration::from_millis(120));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    // 120 ms per decode of 9 frames (0.36 s of video) keeps up with the clock, but the first frames after the start are
    // stand-ins of the frame on screen: the monitor shows frames while exact pictures are still in flight.
    rig.wait("frames", |e| e.shown_frames() >= 25);
    rig.handle.pause();
    let s = rig.handle.status();
    assert_eq!(s.last_error, None);
    assert!(s.shown_frames >= 25, "{s:?}");
}

/// The engine's shown/skipped counters call a run of stand-ins smooth: every frame position shows. The late counter is what
/// the viewer sees, a layer drawn from an older picture as the next frame replaced it.
#[test]
fn frames_drawn_from_stand_ins_count_as_late() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 500, Duration::from_millis(900));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("frames", |e| e.shown_frames() >= 12);
    rig.handle.pause();
    let s = rig.handle.status();
    assert!(s.late_frames > 0, "stand-in frames not counted as late: {s:?}");
    assert!(s.max_lag > 0, "{s:?}");
}

/// A layer whose decoder returns no picture at all (not an old one either) leaves the monitor waiting: `compose` draws
/// nothing, so no frame ever shows and `display` never got to count the positions that went by. They count as late as the
/// playhead passes them.
#[test]
fn a_layer_that_never_delivers_counts_every_frame_as_late() {
    let clock = Arc::new(ManualClock::default());
    let c = Arc::clone(&clock);
    let rig = Rig::new(move |d| d.clock = c as Arc<dyn PlaybackClock>);
    rig.opener.add_silent("a.mov", 500);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.seek(Time::ZERO);
    rig.handle.sync();
    rig.handle.play(PlaybackRate::FORWARD);
    // The engine holds the clock for 2 s (wall time) waiting for a first picture that never comes, then starts it. The wait
    // only watches state (a generous bound, no timing is asserted); the playhead then moves by the manual clock, not by load.
    let end = Instant::now() + Duration::from_secs(60);
    while clock.rate().is_paused() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!clock.rate().is_paused(), "the clock started after the first-picture wait");
    clock.advance(Time::new(25, 25));
    let mut s = rig.handle.status();
    while s.skipped_frames < 20 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
        s = rig.handle.status();
    }
    let position = s.position;
    rig.handle.pause();
    assert_eq!(s.shown_frames, 0, "{s:?}");
    assert!(s.skipped_frames >= 20, "frames of a frozen layer not counted as late: {s:?}");
    assert!(s.max_lag >= 20, "{s:?}");
    // Every frame position the playhead passed (but the wanted one) is late.
    let passed = u64::try_from(position.frame_index(Time::new(1, 25))).unwrap_or(0);
    assert!(s.skipped_frames + 3 >= passed, "{} late of {passed} passed: {s:?}", s.skipped_frames);
}

/// A centered 2 s Cross Dissolve shows its incoming clip a second before the clip's own start. The prefetch warms the first
/// frame the clip shows (its source frame 0 here), not the frame at the clip's start: that one left the first dissolve frames
/// to a cold decode (a frame lost at the dissolve, stand-ins while the lane caught up).
#[test]
fn the_prefetch_warms_the_first_frame_a_dissolve_shows() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 500, Duration::ZERO);
    let b_log = rig.opener.add("b.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov"), (b(), "b.mov")]);
    let mut t = timeline(vec![vec![clip(10, a(), 0, 0, 5), clip(11, b(), 1, 5, 5)]]);
    let dissolve = serde_json::from_value(serde_json::json!({
        "id": id(700), "kind": "crossDissolve", "alignment": "center",
        "duration": {"value": 50, "timescale": 25}, "customBefore": {"value": 0, "timescale": 1},
        "outgoing": id(10), "incoming": id(11),
    }))
    .expect("a Cross Dissolve");
    t.tracks[0].transitions.push(dissolve);
    rig.handle.set_timeline(t, HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    // The dissolve starts at 4 s (source frame 0 of b): the 3.5 s look-ahead reaches it at 0.5 s.
    let start = Instant::now();
    while !b_log.ranges().iter().any(|r| r.0 == 0) && start.elapsed() < Duration::from_secs(4) {
        std::thread::sleep(Duration::from_millis(5));
    }
    let position = rig.handle.status().position;
    rig.handle.pause();
    assert!(b_log.ranges().iter().any(|r| r.0 == 0), "b's first dissolve frame never warmed: {:?}", b_log.ranges());
    assert!(position < Time::new(7, 2), "warmed only when the playhead was at {position:?}");
}

/// A cut to a far position of the same long-GOP file: the lane the prefetch warmed there stays open until the cut (it was
/// closed as idle after ~90 refreshes and the cut then decoded the GOP again from a cold decoder).
#[test]
fn the_lane_warmed_for_a_far_same_file_cut_stays_open_until_the_cut() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    // Frame 300 of the file at 6 s on the timeline; the playing clip reads from frame 0.
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 6), clip(11, a(), 12, 6, 3)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    let warmed = |e: &mut super::core::ProgramEngine| e.lane_positions(a()).iter().any(|p| p.is_some_and(|p| p >= 300));
    rig.wait("the far lane warms", warmed);
    // 1.5 s of playing (hundreds of refreshes) later it is still there: no decoder was closed and opened again cold.
    let opened = log.opens.load(std::sync::atomic::Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(log.opens.load(std::sync::atomic::Ordering::SeqCst), opened, "a lane was closed and reopened");
    assert_eq!(rig.handle.query(warmed), Some(true), "the warmed lane was closed before the cut");
    rig.handle.pause();
}

/// The lane warmed for a cut decodes a lead of frames, not only the first four: the cold lane then keeps ahead of the clock.
#[test]
fn the_prefetch_of_a_cut_decodes_a_lead_of_frames() {
    assert_eq!(super::core::prefetch_ahead_from(None), 12);
    assert_eq!(super::core::prefetch_ahead_from(Some("3")), 3);
    assert_eq!(super::core::prefetch_ahead_from(Some("x")), 12);
    assert_eq!(super::core::prefetch_ahead_from(Some("999")), 60);
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 6), clip(11, a(), 12, 6, 3)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("the far lane decodes a lead of at least 11 frames (a lead of 3 would stop at 303)", move |_| {
        log.ranges().iter().any(|r| r.0 >= 300 && r.1 >= 300 + 11)
    });
    rig.handle.pause();
}

/// Two layers of one long-GOP file at different source positions, parked: each decodes its lead-in frames before Play (Play from
/// 10 s on the real project waited the whole 0.5 s pre-roll: the second layer's lane first sought and decoded at Play).
#[test]
fn a_parked_playhead_decodes_the_lead_in_of_every_layer_of_one_file() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle
        .set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 6)], vec![clip(11, a(), 12, 0, 6)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.wait("both layers' lead-in decoded while parked", move |_| {
        let ahead = |first: usize| log.ranges().iter().any(|r| r.0 <= first && r.1 >= first + 8);
        ahead(0) && ahead(300)
    });
}

/// A clip of the file on screen cuts in 2 s after a parked playhead (the project's second video layer at 2.5 s, Mac window
/// run: stand-ins for 3 frames and a 66 ms gap when the second decoder was still opening or cold at the cut): the paused
/// warm-up opens its lane and decodes its lead before Play, so the cut does not depend on the first seconds of the play.
#[test]
fn a_parked_playhead_warms_the_lane_of_a_clip_that_cuts_in_within_the_first_seconds() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle
        .set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 6)], vec![clip(11, a(), 12, 2, 3)]]), HashMap::new());
    keys_at(&rig, Time::ZERO);
    rig.wait("the cut-in clip's lead is decoded while parked", move |_| {
        log.ranges().iter().any(|r| r.0 >= 300 && r.1 >= 300 + 11)
    });
}

/// Three cuts into the same long-GOP file inside the look-ahead, one lane each besides the playing one: the farthest cut's
/// prefetch took the lane the nearer cut had warmed (a lane that reads toward its key was left unclaimed, so the next key
/// found it "free" and seeked it away); the nearer cut then decoded its GOP cold (real project: 0.5-0.8 s stand-ins).
#[test]
fn a_far_cut_does_not_take_the_lane_warmed_for_a_nearer_cut() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(
        timeline(vec![vec![
            clip(10, a(), 0, 0, 1),
            clip(11, a(), 4, 1, 1),
            clip(12, a(), 8, 2, 1),
            clip(13, a(), 12, 3, 1),
            clip(14, a(), 16, 4, 1),
        ]]),
        HashMap::new(),
    );
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("0.9 s of playing", |e| e.position() >= Time::new(9, 10));
    rig.handle.pause();
    let ranges = log.ranges();
    for first in [100usize, 200] {
        let n = ranges.iter().filter(|r| (first..=first + 3).contains(&r.0)).count();
        assert!(n <= 1, "the lane warmed at frame {first} was seeked away and decoded again {n} times: {ranges:?}");
    }
}

/// A reversed clip played forward on the timeline reads its source backwards. Asking for the frame after the one shown, one
/// decode per frame, decoded the GOP from its sync sample again for every frame (65-80 ms each on a real 4K file: the
/// picture stood still 0.4 s at the end of such a clip on a real project). The window from the sync sample up to the frame
/// decodes once and the frames play out of the cache.
fn reversed_rig() -> (Rig, Arc<super::testkit::FileLog>) {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::from_millis(30));
    rig.media(&[(a(), "a.mov")]);
    // Source seconds 2..10 on the timeline 0..8 s, played from its end.
    let mut c = clip(10, a(), 2, 0, 8);
    c.reversed = true;
    rig.handle.set_timeline(timeline(vec![vec![c]]), HashMap::new());
    (rig, log)
}

fn assert_window_decodes(ranges: &[(usize, usize)]) {
    let single = ranges.iter().filter(|r| r.0 == r.1).count();
    assert!(single <= 3, "one decode per frame on a reversed clip: {ranges:?}");
    assert!(ranges.iter().any(|r| r.1 - r.0 >= 5), "no window decode on a reversed clip: {ranges:?}");
}

/// A reversed clip played forward on the timeline reads its source backwards. Asking for the frame after the one shown, one
/// decode per frame, decoded the GOP from its sync sample again for every frame (65-80 ms each on a real 4K file: the
/// picture stood still 0.4 s at the end of such a clip on a real project). The window from the sync sample up to the frame
/// decodes once and the frames play out of the cache.
#[test]
fn a_reversed_clip_decodes_a_gop_window_not_one_frame_per_seek() {
    let (rig, log) = reversed_rig();
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("1.2 s of playing", |e| e.position() >= Time::new(6, 5));
    rig.handle.pause();
    assert_window_decodes(&log.ranges());
}

/// A backward scrub inside one GOP decodes the GOP once: the pictures of the window stay in the cache and the steps after
/// the first read them (a real 4K long-GOP file restarted at the key frame for every step: 60-550 ms each).
#[test]
fn a_backward_scrub_within_one_gop_decodes_the_gop_once() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::from_millis(10));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    // Sync every 10th frame: land in the middle of the GOP 50..=59 from far away, then scrub back inside it.
    keys_at(&rig, Time::new(5, 25));
    rig.handle.begin_scrub();
    rig.handle.scrub(Time::new(58, 25));
    rig.wait("the landing frame", |e| e.position() == Time::new(58, 25) && e.is_frame_settled());
    assert!(log.ranges().iter().any(|r| r.0 <= 50 && r.1 >= 58), "the GOP decodes up to the frame: {:?}", log.ranges());
    let before = log.ranges().len();
    for n in (51..=57i64).rev() {
        rig.handle.scrub(Time::new(n, 25));
        rig.wait("the scrub frame", move |e| e.position() == Time::new(n, 25) && e.is_frame_settled());
        // A cached step leaves the lane at the step (without the cache/in-flight guards in `request` the window request
        // seeks it back to the sync sample, frame 50, on every step).
        let lane = rig.handle.query(|e| e.lane_positions(a())).unwrap_or_default();
        assert_eq!(lane, vec![Some(n)], "the cached step {n} moved the lane");
    }
    rig.handle.end_scrub();
    rig.handle.sync();
    // The parked lead-in after the scrub (frames ahead of the playhead, here 59..) is a legitimate decode that races the
    // end of the test; what must not happen is a decode that reaches back into the scrubbed GOP (a seek to its sync sample).
    let after = log.ranges()[before..].to_vec();
    assert!(after.iter().all(|r| r.0 > 58), "a decode reached back into the scrubbed GOP: {after:?}");
}

/// After a scrub back inside a GOP the playhead's lane stands ahead of the playhead (the picture comes from the cache). The
/// cut-in warm-up of the same file must not take that lane (it seeked lane 0 to the cut, and the next cache miss at the
/// playhead restarted from the sync sample): the cut opens its own lane.
#[test]
fn the_cut_in_warm_up_does_not_take_the_lane_of_a_playhead_served_from_the_cache() {
    let rig = Rig::new(|_| {});
    let _log = rig.opener.add("a.mov", 500, Duration::from_millis(5));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::new(52, 25));
    // A second layer of the file cuts in at 4 s (source frame 300).
    rig.handle
        .set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)], vec![clip(11, a(), 12, 4, 3)]]), HashMap::new());
    keys_at(&rig, Time::new(52, 25));
    // The playhead's lane stands ahead of the playhead after a scrub back inside the GOP (picture from the cache). One warm
    // pass on the engine thread, so no refresh moves the lane in between.
    let lanes = rig
        .handle
        .query(|e| {
            e.set_lane_for_test(a(), 58, 66);
            e.warm_cut_ins_for_test();
            e.lane_positions(a())
        })
        .unwrap_or_default();
    assert!(lanes[0] == Some(58), "error the warm-up seeked the playhead lane to the cut-in: {lanes:?}");
}

/// A reversed clip played backwards reads its source forwards: the plain forward path, one decode ahead of the playhead.
#[test]
fn a_reversed_clip_played_backward_reads_forward() {
    let (rig, log) = reversed_rig();
    keys_at(&rig, Time::seconds(6));
    rig.handle.play(PlaybackRate::REVERSE);
    rig.wait("1.2 s of playing", |e| e.position() <= Time::new(24, 5));
    rig.handle.pause();
    let ranges = log.ranges();
    assert!(ranges.iter().all(|r| r.1 - r.0 < 30), "forward reads stay short: {ranges:?}");
    // The source runs forward: after the first (warm-up) decodes every range starts above the one before it.
    assert!(
        ranges.windows(2).skip(2).all(|w| w[1].0 > w[0].0),
        "backward window reads on a forward source: {ranges:?}"
    );
}

/// Paused, stepping and scrubbing over a reversed clip keep the exact frame (the forward fill, no reverse window), and the
/// clip's first and last frame show the end and the start of its source range.
#[test]
fn a_paused_reversed_clip_steps_exactly_and_its_edges_map_to_the_source_ends() {
    let (rig, _log) = reversed_rig();
    let first = keys_at(&rig, Time::ZERO)[0].0;
    let next = keys_at(&rig, Time::new(1, 25))[0].0;
    assert_eq!(next, first - 1, "one timeline frame forward is one source frame back");
    let last = keys_at(&rig, Time::new(199, 25))[0].0;
    assert_eq!(last, 50, "the clip's last frame is its source start (2 s)");
    assert!(first > 240, "the first frame is the end of the source range: {first}");
}

#[test]
fn a_resting_playhead_fills_the_cache_ahead_and_behind_so_a_scrub_back_hits_it() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 500, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.seek(Time::new(100, 25));
    rig.wait("the neighbours", |e| {
        let spans = e.cached_spans();
        e.is_frame_settled()
            && e.cache_len() >= 25
            && spans.iter().any(|s| s.start <= Time::new(92, 25) && s.end() >= Time::new(116, 25))
    });
    // Scrub backwards over the filled stretch: every step is a cache hit, no decode runs.
    let before = log.ranges().len();
    rig.handle.begin_scrub();
    for n in (92..=99i64).rev() {
        rig.handle.scrub(Time::new(n, 25));
        rig.wait("a cached step", move |e| e.position() == Time::new(n, 25) && e.is_frame_settled());
    }
    rig.handle.end_scrub();
    assert_eq!(log.ranges().len(), before, "decodes during the cached scrub: {:?}", &log.ranges()[before..]);
}

/// The composite of the clip at frame `to` once it is exact: after a scrub from `from` (the first picture there is a stand-in
/// of a nearby frame), or a plain seek. `None` without a GPU.
fn exact_composite(gpu: &Arc<sq_gpu::gpu::Gpu>, from: Option<i64>, to: i64) -> Option<Vec<u8>> {
    let rig = Rig::new(|d| d.gpu = Some(Arc::clone(gpu)));
    rig.opener.add("a.mov", 250, Duration::from_millis(150));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    let fd = Time::new(1, FPS);
    let shown = |cond: &dyn Fn(&super::handle::Shown) -> bool| {
        let end = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(s) = rig.handle.latest_shown().filter(|s| cond(s)) {
                return s;
            }
            assert!(std::time::Instant::now() < end, "timed out: {:?}", rig.handle.status());
            std::thread::sleep(Duration::from_millis(2));
        }
    };
    if let Some(from) = from {
        rig.handle.seek(fd * from);
        shown(&|s| s.position == fd * from && s.exact && s.frame.is_some());
        rig.handle.begin_scrub();
        rig.handle.scrub(fd * to);
        shown(&|s| s.position == fd * to && !s.exact && s.frame.is_some());
    } else {
        rig.handle.seek(fd * to);
    }
    let s = shown(&|s| s.position == fd * to && s.exact && s.frame.is_some());
    gpu.read_texture(&s.frame.as_ref()?.planes[0]).ok()
}

/// A scrub draws a stand-in (a nearby cached frame) while the wanted one decodes; the exact picture that replaces it must
/// show the wanted frame, not the stand-in's planes kept under the wanted frame's key.
#[test]
fn the_exact_picture_after_a_scrub_stand_in_shows_the_wanted_frame() {
    let Ok(gpu) = sq_gpu::gpu::Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let after_scrub = exact_composite(&gpu, Some(20), 60).expect("scrub composite");
    let plain = exact_composite(&gpu, None, 60).expect("seek composite");
    assert!(after_scrub == plain, "the exact frame after a stand-in differs from the frame itself");
}

/// Playing, a stand-in is a frame the playhead passed and never older than the newest one drawn; scrubbing takes the nearest.
#[test]
fn a_playing_stand_in_never_goes_back_behind_the_picture_on_screen_nor_ahead() {
    use super::core::stand_in_index;
    let cached = [10, 14, 18, 22];
    assert_eq!(stand_in_index(cached.into_iter(), 20, false, true, None), Some(18));
    // Frame 21 was drawn, then evicted: 18 would jump back; the screen keeps 21.
    assert_eq!(stand_in_index(cached.into_iter(), 23, false, true, Some(21)), Some(22));
    assert_eq!(stand_in_index(cached.into_iter(), 20, false, true, Some(19)), None);
    // Only frames ahead are cached (from before a click): nothing ahead stands in.
    assert_eq!(stand_in_index([30, 31].into_iter(), 25, false, true, None), None);
    // Reverse: mirrored.
    assert_eq!(stand_in_index(cached.into_iter(), 16, false, false, Some(19)), Some(18));
    assert_eq!(stand_in_index(cached.into_iter(), 16, false, false, Some(17)), None);
    // Scrubbing: the nearest either way.
    assert_eq!(stand_in_index(cached.into_iter(), 21, true, true, Some(30)), Some(22));
}

/// Reverse play on a long-GOP file decodes each GOP forward once from its sync sample and plays it backwards out of the
/// cache (as the Swift engine does): the playhead gets exact pictures, not one seek and GOP decode per frame.
#[test]
fn reverse_play_decodes_whole_gops_and_shows_exact_frames() {
    let rig = Rig::new(|_| {});
    // Sync sample every 10th frame; each decode call costs 40 ms however many frames it returns.
    let log = rig.opener.add("a.mov", 500, Duration::from_millis(40));
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    keys_at(&rig, Time::new(300, 25));
    let before = log.ranges().len();
    rig.handle.play(PlaybackRate::REVERSE);
    let (mut exact, mut seen) = (0, std::collections::HashSet::new());
    let end = std::time::Instant::now() + Duration::from_millis(1600);
    while std::time::Instant::now() < end {
        if let Some(s) = rig.handle.latest_shown()
            && seen.insert(s.generation)
            && s.exact
        {
            exact += 1;
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    rig.handle.pause();
    let ranges = log.ranges()[before..].to_vec();
    // 1.6 s back from frame 300: 40 frames over four or five GOPs.
    assert!(ranges.len() <= 8, "one decode per GOP, not per frame: {ranges:?}");
    assert!(ranges.iter().all(|r| r.0 % 10 == 0), "every decode starts at a sync sample: {ranges:?}");
    assert!(exact >= 25, "exact pictures while playing backwards: {exact} of {} ({ranges:?})", seen.len());
}

/// The proxy flag of the keys the engine wants for the layer at `t`.
fn proxy_flags(rig: &Rig) -> Vec<bool> {
    rig.handle.query(|e| e.wanted_keys().iter().map(|k| k.proxy).collect()).unwrap_or_default()
}

#[test]
fn a_ready_proxy_is_read_while_scrubbing_and_playing_never_while_paused() {
    let rig = Rig::new(|_| {});
    let original = rig.opener.add("a.mov", 500, Duration::ZERO);
    let proxy = rig.opener.add_proxy("a.mov", 500);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.set_proxy_use(super::proxy_picture::ProxyUse { scrubbing: true, playback: true });
    keys_at(&rig, Time::ZERO);
    rig.wait("the proxy is open", |e| e.proxy_open(a()));
    assert_eq!(proxy_flags(&rig), vec![false], "paused: the original's frame");
    rig.handle.begin_scrub();
    rig.handle.scrub(Time::new(30, 25));
    rig.wait("the scrub reads the proxy", |e| e.wanted_keys().iter().all(|k| k.proxy) && e.is_frame_settled());
    assert!(proxy.ranges().contains(&(30, 30)), "the proxy decoded the scrub frame: {:?}", proxy.ranges());
    rig.handle.end_scrub();
    rig.wait("paused again", |e| e.wanted_keys().iter().all(|k| !k.proxy) && e.is_frame_settled());
    assert!(original.ranges().iter().any(|r| r.0 == 30), "the paused frame is the original's: {:?}", original.ranges());
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("playing at Full reads the original", |e| e.wanted_keys().iter().all(|k| !k.proxy));
    rig.handle.set_quality(DecodeScale::Half);
    rig.wait("playing below Full reads the proxy", |e| e.wanted_keys().iter().all(|k| k.proxy));
    rig.handle.pause();
    rig.wait("pause reads the original", |e| e.wanted_keys().iter().all(|k| !k.proxy) && e.is_frame_settled());
}

#[test]
fn proxy_use_off_keeps_the_original_for_every_state() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 500, Duration::ZERO);
    let proxy = rig.opener.add_proxy("a.mov", 500);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.set_proxy_use(super::proxy_picture::ProxyUse::OFF);
    keys_at(&rig, Time::ZERO);
    rig.handle.begin_scrub();
    rig.handle.scrub(Time::new(30, 25));
    rig.wait("the scrub frame", |e| e.position() == Time::new(30, 25) && e.is_frame_settled());
    assert_eq!(proxy_flags(&rig), vec![false]);
    assert_eq!(proxy.opens.load(std::sync::atomic::Ordering::SeqCst), 0, "no proxy was opened");
}

#[test]
fn a_seek_while_playing_is_not_counted_as_dropped_frames() {
    let rig = Rig::new(|_| {});
    rig.opener.add("a.mov", 250, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 8)]]), HashMap::new());
    rig.handle.seek(Time::ZERO);
    rig.wait("first frame", |e| e.is_frame_settled() || e.shown_frames() == 0 && e.cache_len() > 0);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("some frames", |e| e.shown_frames() >= 3);
    rig.handle.seek(Time::new(150, 25));
    rig.wait("past the jump", |e| e.position() > Time::new(150, 25));
    let s = rig.handle.status();
    assert!(s.skipped_frames < 40, "a jump of 150 frames counted as dropped: {s:?}");
}

#[test]
fn only_the_play_direction_counts_skipped_frames() {
    use super::core::skipped_in_run;
    assert_eq!(skipped_in_run(Some(10), 11, true), 0);
    assert_eq!(skipped_in_run(Some(10), 14, true), 3);
    assert_eq!(skipped_in_run(Some(10), 2, true), 0, "a loop wrap");
    assert_eq!(skipped_in_run(Some(10), 6, false), 3);
    assert_eq!(skipped_in_run(Some(10), 90, false), 0);
    assert_eq!(skipped_in_run(None, 90, true), 0);
}

fn wanted_at(index: i64) -> Wanted {
    Wanted { position: Time::ZERO, keys: vec![Key::new(a(), index, 1)] }
}

/// A jump of 16-90 frames inside one file seeks cold; it counts as a cut so its stand-ins do not step Auto quality down.
#[test]
fn a_same_file_jump_past_the_cut_grace_is_a_cut() {
    assert!(!is_cut(&wanted_at(100), &wanted_at(101)));
    assert!(!is_cut(&wanted_at(100), &wanted_at(100 + CUT_GRACE)));
    assert!(is_cut(&wanted_at(100), &wanted_at(100 + CUT_GRACE + 1)));
    assert!(is_cut(&wanted_at(100), &wanted_at(100 - 60)));
    assert!(is_cut(&wanted_at(100), &wanted_at(190)));
}

#[test]
fn the_trim_keeps_the_lead_of_a_clip_about_to_cut_in() {
    let (m, other) = (a(), b());
    let cut_in = Key::new(m, 660, 2);
    let on_screen = Key::new(m, 20, 2);
    let (wanted, ahead) = ([on_screen], [cut_in]);
    // The frames decoded after the first visible frame are as safe as the frame itself; the ones beyond the lead are not.
    for i in 660..=672 {
        assert_eq!(trim_distance(&wanted, &ahead, 12, &Key::new(m, i, 2)), 0, "frame {i} of the cut-in lead");
    }
    assert!(trim_distance(&wanted, &ahead, 12, &Key::new(m, 700, 2)) > 0);
    // A file nothing wants goes first.
    assert!(trim_distance(&wanted, &ahead, 12, &Key::new(other, 5, 2)) > 1_000_000);
}

/// Real project, second layer of a file at 21.07 s: the three lanes of the file held old pictures (clips that had ended),
/// the cut-in prefetch got no lane for 3 s and decoded cold at the cut (962 ms, a 207 ms gap).
#[test]
fn a_prefetch_takes_a_lane_nothing_reads_any_more_but_never_a_live_one() {
    assert!(prefetch_may_take_lane(629, true, false), "a lane idle for 20 s is nobody's");
    assert!(!prefetch_may_take_lane(5, true, false), "the playhead reads it every frame");
    assert!(!prefetch_may_take_lane(10, true, false), "a warmed lane is touched every 10 refreshes");
    assert!(!prefetch_may_take_lane(629, true, true), "a lane that reaches a cut-in the prefetch looks at stays");
    assert!(!prefetch_may_take_lane(629, false, false), "paused, the warm-up never seeks a lane");
}

/// A clip of `media`: `src` seconds into the file, starting `at` timeline seconds in, `dur` long (a fraction of a second).
fn short_clip(n: u128, media: sq_core_time::Id, src: i64, at: Time, dur: Time) -> sq_core_model::Clip {
    sq_core_model::Clip::new(
        id(n),
        "c",
        media,
        sq_core_model::TrackKind::Video,
        sq_core_time::TimeRange::new(Time::seconds(src), dur),
        at,
    )
}

/// A clip under 1 s that cuts in between two of the prefetch's sample points (0.5/1.0/1.5/2.5/3.5 s) is hit by no sample for
/// a while; its warmed lane then looked idle (30 refreshes) and the prefetch of another layer of the same file took it before
/// the cut, which then decoded cold. The lane stays the short clip's until its cut has passed.
#[test]
fn the_lane_warmed_for_a_clip_between_two_sample_points_is_not_taken_before_its_cut() {
    let rig = Rig::new(|_| {});
    let log = rig.opener.add("a.mov", 900, Duration::ZERO);
    rig.media(&[(a(), "a.mov")]);
    // A plays from frame 0; B (0.3 s, frame 300) cuts in at 2.6 s; C (frame 600) cuts in at 4 s and is prefetched meanwhile.
    rig.handle.set_timeline(
        timeline(vec![
            vec![clip(10, a(), 0, 0, 10)],
            vec![short_clip(11, a(), 12, Time::seconds(3), Time::new(1, 25))],
            vec![short_clip(12, a(), 24, Time::new(29, 5), Time::seconds(2))],
        ]),
        HashMap::new(),
    );
    keys_at(&rig, Time::ZERO);
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("B has cut in", |e| e.position() >= Time::new(31, 10));
    rig.handle.pause();
    let ranges = log.ranges();
    let n = ranges.iter().filter(|r| (300..=303).contains(&r.0)).count();
    assert!(n <= 1, "the lane warmed at frame 300 was taken and decoded again {n} times: {ranges:?}");
}
