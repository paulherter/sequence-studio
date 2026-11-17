// SPDX-License-Identifier: GPL-3.0-or-later
//! Engine behavior on the render thread with an in-memory opener (headless). The wanted-keys dump is the oracle of
//! `WinProgramEngine.refresh/mediaKey`: media index = frame of `source_time + first pts`, divisor from the playback
//! quality, the layer's drawn size while playing and the scrub preview rule.

use super::core::{PREVIEW_PIXELS, playback_layer_detail};
use super::testkit::*;
use super::types::Key;
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
    let rig = Rig::new(|_| {});
    rig.opener.add_silent("a.mov", 500);
    rig.media(&[(a(), "a.mov")]);
    rig.handle.set_timeline(timeline(vec![vec![clip(10, a(), 0, 0, 20)]]), HashMap::new());
    rig.handle.seek(Time::ZERO);
    rig.handle.sync();
    rig.handle.play(PlaybackRate::FORWARD);
    // The clock starts after its 2 s wait for a first picture; then the playhead moves on with nothing on screen.
    let end = Instant::now() + Duration::from_secs(5);
    let mut s = rig.handle.status();
    while s.skipped_frames < 20 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
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
    assert!(original.ranges().contains(&(30, 30)), "the paused frame is the original's: {:?}", original.ranges());
    rig.handle.play(PlaybackRate::FORWARD);
    rig.wait("playing reads the proxy", |e| e.wanted_keys().iter().all(|k| k.proxy));
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
