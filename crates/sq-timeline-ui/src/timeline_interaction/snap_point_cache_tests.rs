//! Port of SnapPointCacheTests.swift: the per-gesture snap point cache must give exactly what recomputing
//! `Timeline::snap_points` on every event gives: two interactions run in lockstep (cache on / off) over random
//! timelines, tools, drags, ripple and magnetic.

use crate::test_support::*;
use crate::timeline_geometry::TimelineGeometry;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_edit::snapping::SnappingTimelineExt;
use sq_core_model::{Clip, Timeline, TimelineEditMode, TrackKind};
use sq_core_time::{Id, Keyframe, Time, TimeRange};
use sq_editor_session::{GestureModifiers as M, TimelineTool, ToolState};
use sq_uikit::keyframe_graph_geometry::Point;
use std::collections::BTreeSet;

struct Rng {
    s: u64,
}

impl Rng {
    fn next(&mut self) -> u64 {
        self.s = self.s.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn int(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn chance(&mut self, n: usize) -> bool {
        self.int(n) == 0
    }
}

fn random_timeline(rng: &mut Rng) -> Timeline {
    let mut tracks = Vec::new();
    let mut links: Vec<Id> = Vec::new();
    for kind in [TrackKind::Video, TrackKind::Video, TrackKind::Audio, TrackKind::Audio] {
        let mut clips: Vec<Clip> = Vec::new();
        let mut at = rng.int(6) as i64;
        for _ in 0..(3 + rng.int(6)) {
            let len = 4 + rng.int(30) as i64;
            let mut link = None;
            if kind == TrackKind::Video && rng.chance(3) {
                let l = uid();
                links.push(l);
                link = Some(l);
            }
            if kind == TrackKind::Audio && !links.is_empty() && rng.chance(2) {
                link = Some(links.remove(0));
            }
            let mut c = Clip::new(uid(), "c", uid(), kind, TimeRange::new(FD * 40, FD * len), FD * at);
            c.link = link;
            c.media_duration = Some(FD * 200);
            if rng.chance(2) {
                c.animation.opacity.track.insert(Keyframe::new(uid(), FD * rng.int(len as usize) as i64, 0.3));
            }
            if rng.chance(3) {
                c.animation.volume.track.insert(Keyframe::new(uid(), FD * rng.int(len as usize) as i64, 0.5));
            }
            clips.push(c);
            at += len + if rng.chance(3) { 0 } else { 1 + rng.int(12) as i64 };
        }
        tracks.push(track(kind, clips));
    }
    timeline(tracks)
}

fn random_modifiers(rng: &mut Rng) -> M {
    let mut m = M::default();
    if rng.chance(4) {
        m = m | M::COMMAND;
    }
    if rng.chance(4) {
        m = m | M::OPTION;
    }
    if rng.chance(5) {
        m = m | M::SHIFT;
    }
    m
}

/// A point on a random clip: middle, near the head or near the tail (edge handles).
fn random_point(rng: &mut Rng, i: &TimelineInteraction) -> Point {
    let rows = i.geometry.rows(i.timeline());
    let clips: Vec<(Id, &Clip)> =
        i.timeline().tracks.iter().flat_map(|t| t.clips().iter().map(move |c| (t.id, c))).collect();
    if clips.is_empty() || rng.chance(8) {
        return pt((130 + rng.int(500)) as f64, (20 + rng.int(140)) as f64);
    }
    let (tid, c) = clips[rng.int(clips.len())];
    let row = rows.iter().find(|r| r.track == tid).unwrap();
    let x0 = i.geometry.x(c.timeline().start);
    let x1 = i.geometry.x(c.timeline().end());
    let px = match rng.int(3) {
        0 => x0 + 1.0,
        1 => x1 - 1.0,
        _ => (x0 + x1) / 2.0,
    };
    pt(px, row.y + row.height / 2.0)
}

/// Timeline without identities: splits, copies and new tracks mint fresh ids in each interaction.
fn shape(tl: &Timeline) -> Vec<String> {
    tl.tracks
        .iter()
        .map(|t| {
            let clips: Vec<String> = t
                .clips()
                .iter()
                .map(|c| {
                    format!(
                        "{:?} {:?} {:?} {:?} {}",
                        c.kind,
                        c.timeline().start,
                        c.timeline().duration,
                        c.source.start,
                        c.link.is_some()
                    )
                })
                .collect();
            format!("{:?}:{}", t.kind, clips.join(","))
        })
        .collect()
}

fn expect_same(a: &TimelineInteraction, b: &TimelineInteraction) {
    assert_eq!(shape(a.preview()), shape(b.preview()));
    assert_eq!(a.snap_time(), b.snap_time());
    assert_eq!(a.pending_edits().len(), b.pending_edits().len());
    assert_eq!(a.selection().len(), b.selection().len());
    assert_eq!(a.is_rejected(), b.is_rejected());
}

#[test]
fn cached_snapping_equals_recomputed_over_random_gestures() {
    let tools = [
        TimelineTool::Selection,
        TimelineTool::Selection,
        TimelineTool::RippleEdit,
        TimelineTool::RollEdit,
        TimelineTool::Slip,
        TimelineTool::Slide,
        TimelineTool::Razor,
    ];
    let mut snaps_seen = 0;
    for seed in 0..60_u64 {
        let mut rng = Rng { s: seed.wrapping_mul(7919) };
        let mut tl = random_timeline(&mut rng);
        if seed % 2 == 1 {
            tl.set_edit_mode(TimelineEditMode::Magnetic); // Fast Cut: magnetic verbs, attachments, keepAttached
        }
        let geo = TimelineGeometry::with_points_per_frame(FD, (2 + rng.int(6)) as f64);
        let mut cached = TimelineInteraction::new(tl.clone(), geo.clone(), ID_SEED);
        let mut plain = TimelineInteraction::new(tl, geo, ID_SEED);
        plain.snap_cache_enabled = false;
        for _ in 0..6 {
            let mut ts = ToolState::new(tools[rng.int(tools.len())], !rng.chance(6), !rng.chance(4));
            ts.keep_attached = rng.chance(3);
            let playhead: Option<Time> = if rng.chance(4) { None } else { Some(FD * rng.int(120) as i64) };
            let markers: Vec<Time> = (0..rng.int(3)).map(|_| FD * rng.int(120) as i64).collect();
            for i in [&mut cached, &mut plain] {
                i.tool_state = ts;
                i.playhead = playhead;
                i.markers = markers.clone();
            }
            // Optional pre-selection click so multi-clip moves happen.
            if rng.chance(2) {
                let p = random_point(&mut rng, &cached);
                let m = if rng.chance(2) { M::SHIFT } else { M::default() };
                cached.mouse_down(p, m);
                cached.mouse_up(p, m);
                plain.mouse_down(p, m);
                plain.mouse_up(p, m);
            }
            let down = random_point(&mut rng, &cached);
            let mut m = random_modifiers(&mut rng);
            cached.mouse_down(down, m);
            plain.mouse_down(down, m);
            assert_eq!(cached.razor_cut_time(down.x), plain.razor_cut_time(down.x));
            let mut p = down;
            for _ in 0..(2 + rng.int(10)) {
                p.x += rng.int(41) as f64 - 20.0;
                if rng.chance(3) {
                    p.y += rng.int(41) as f64 - 20.0;
                }
                if rng.chance(4) {
                    m = random_modifiers(&mut rng);
                }
                if rng.chance(6) {
                    // the playhead or markers move mid-gesture
                    let ph = FD * rng.int(120) as i64;
                    cached.playhead = Some(ph);
                    plain.playhead = Some(ph);
                    if rng.chance(2) {
                        cached.markers.push(ph + FD);
                        plain.markers.push(ph + FD);
                    }
                }
                if rng.chance(5) {
                    cached.snap_inverted = !cached.snap_inverted;
                    plain.snap_inverted = !plain.snap_inverted;
                }
                cached.mouse_dragged(p, m);
                plain.mouse_dragged(p, m);
                if cached.snap_time().is_some() {
                    snaps_seen += 1;
                }
                expect_same(&cached, &plain);
            }
            let a = cached.mouse_up(p, m);
            let b = plain.mouse_up(p, m);
            assert_eq!(
                shape(a.as_ref().map_or(cached.timeline(), |c| &c.timeline)),
                shape(b.as_ref().map_or(plain.timeline(), |c| &c.timeline))
            );
            assert_eq!(a.as_ref().map(|c| c.undo_name.clone()), b.as_ref().map(|c| c.undo_name.clone()));
            assert_eq!(shape(cached.timeline()), shape(plain.timeline()));
            plain.reset(cached.timeline().clone()); // same identities again for the next gesture
            plain.set_selection(cached.selection().clone());
            plain.snap_inverted = cached.snap_inverted; // reset() cleared it; a press without a gesture keeps it
            // The razor guide reads the cache too: sweep it across the committed timeline.
            for k in 0..1200 {
                let px = TimelineGeometry::CONTENT_ORIGIN_X + f64::from(k);
                assert_eq!(cached.razor_cut_time(px), plain.razor_cut_time(px));
            }
            if rng.chance(5) {
                // undo / external edit swaps the timeline
                let other = random_timeline(&mut rng);
                cached.reset(other.clone());
                plain.reset(other);
            }
        }
    }
    assert!(snaps_seen > 100);
}

#[test]
fn external_timeline_change_invalidates_the_cache() {
    let mut rng = Rng { s: 42 };
    let tl = random_timeline(&mut rng);
    let mut i = interaction_of(tl.clone());
    i.tool_state = ToolState::new(TimelineTool::Razor, true, true);
    let p = pt(i.geometry.x(FD * 2000) + 3.0, 40.0);
    i.mouse_down(p, M::SHIFT);
    i.cancel(); // razor press fills the cache, no cut
    assert_ne!(i.razor_cut_time(p.x), FD * 2000);
    let far = {
        let mut c = Clip::new(uid(), "far", uid(), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 10), FD * 2000);
        c.media_duration = Some(FD * 100);
        c
    };
    let mut tracks: Vec<_> = tl.tracks.iter().cloned().collect();
    tracks.push(track(TrackKind::Video, vec![far]));
    let moved = timeline(tracks);
    i.reset(moved.clone());
    i.mouse_down(p, M::SHIFT);
    i.cancel(); // razor press fills the cache, no cut
    let none_excluded = BTreeSet::new();
    assert!(moved.snap_points(&none_excluded, None, &[], false).iter().any(|s| s.time == FD * 2000));
    assert!(i.timeline().snap_points(&none_excluded, None, &[], false).iter().any(|s| s.time == FD * 2000));
    assert_eq!(i.razor_cut_time(p.x), FD * 2000);
}
