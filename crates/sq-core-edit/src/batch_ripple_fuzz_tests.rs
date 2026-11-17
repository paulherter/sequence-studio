// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BatchRippleTests.swift (`batchEqualsSequentialOnRandomTimelines`, `playheadFollowsTheClosedSpans`,
// `lockedTrackRefusesAndChangesNothing`)
//
// `remove_silences` removes every cut in one pass. The oracle is the old sequential path (one `extract` per cut, last cut
// first), kept below. On seeded random timelines (linked A/V with J/L cuts, gaps, B-roll with linked sound, music, tracks
// with and without sync lock, locked tracks, point and range markers, In/Out) both must give the same timeline up to the
// fresh ids of new pieces, the same removed time, the same playhead, or the same error.
// The generator also has transitions (cuts, head and tail fades), opacity / volume keys, clip markers and two caption tracks
// (one with word timings, one maybe locked or without sync lock).

use crate::playhead_after_ripple::PlayheadAfterRippleExt as _;
use crate::proposed_cuts::TimelineProposedCutsExt as _;
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use sq_core_audio::SilenceRemoval;
use sq_core_audio::timeline_caption_edits::TimelineCaptionEditsExt as _;
use sq_core_effects::transition::{NewTransition, TimelineTransitions as _};
use sq_core_model::{
    CaptionItem, CaptionWord, Clip, EditError, InOutKind, Marker, SequenceFormat, Timeline, Track, TrackKind,
    TransitionAlignment, TransitionKind,
};
use sq_core_time::{Id, IdSource, Keyframe, SequentialIds, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn int(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    fn chance(&mut self, n: usize) -> bool {
        self.int(n) == 0
    }
}

fn fd() -> Time {
    Time::new(1001, 30000)
}
fn frames(n: usize) -> Time {
    fd() * n as i64
}

fn sequential(
    tl: &mut Timeline,
    cuts: &[TimeRange],
    around: &BTreeSet<Id>,
    ids: &mut dyn IdSource,
) -> Result<Time, EditError> {
    let links: BTreeSet<Id> =
        tl.tracks.iter().flat_map(|t| t.clips()).filter(|c| around.contains(&c.id)).filter_map(|c| c.link).collect();
    let mut owned: BTreeSet<Id> = BTreeSet::new();
    for t in &tl.tracks {
        let owns = t.clips().iter().any(|c| around.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)));
        if owns || t.follows_ripple() {
            owned.insert(t.id);
        }
    }
    let normalized = SilenceRemoval::normalized(cuts);
    if let Some(first) = normalized.first().map(|c| c.start) {
        let mut grew = true;
        while grew {
            let moved: BTreeSet<Id> = tl
                .tracks
                .iter()
                .filter(|t| owned.contains(&t.id))
                .flat_map(|t| t.clips())
                .filter(|c| c.timeline().end() > first)
                .filter_map(|c| c.link)
                .collect();
            grew = false;
            for t in &tl.tracks {
                if !owned.contains(&t.id) && t.clips().iter().any(|c| c.link.is_some_and(|l| moved.contains(&l))) {
                    if t.is_locked {
                        return Err(EditError::TrackLocked);
                    }
                    owned.insert(t.id);
                    grew = true;
                }
            }
        }
    }
    let end = tl.tracks.iter().filter(|t| owned.contains(&t.id)).map(|t| t.end()).max().unwrap_or(Time::ZERO);
    let clamped: Vec<TimeRange> = normalized
        .iter()
        .filter_map(|c| {
            let b = c.end().min(end);
            (b > c.start).then(|| TimeRange::new(c.start, b - c.start))
        })
        .collect();
    let order: Vec<Id> = tl.tracks.iter().map(|t| t.id).filter(|id| owned.contains(id)).collect();
    let mut work = tl.clone();
    let mut removed = Time::ZERO;
    for c in clamped.iter().rev() {
        let d = work.extract(*c, &order, ids)?;
        if d != c.duration {
            return Err(EditError::Collision);
        }
        removed += d;
    }
    *tl = work;
    Ok(removed)
}

/// JSON with every id replaced by the order it first appears in: fresh ids of new pieces compare equal in the same places.
fn canonical(tl: &Timeline) -> String {
    fn walk(v: &mut serde_json::Value, names: &mut BTreeMap<String, usize>) {
        match v {
            serde_json::Value::String(s) if Id::parse(s).is_some() => {
                let n = names.len();
                let n = *names.entry(s.clone()).or_insert(n);
                *s = format!("#{n}");
            }
            serde_json::Value::Array(a) => a.iter_mut().for_each(|x| walk(x, names)),
            serde_json::Value::Object(o) => o.values_mut().for_each(|x| walk(x, names)),
            _ => {}
        }
    }
    let mut v = serde_json::to_value(tl).expect("serialize");
    walk(&mut v, &mut BTreeMap::new());
    v.to_string()
}

fn random_cuts(rng: &mut Lcg, end: Time) -> Vec<TimeRange> {
    let n = (end.frame_index(fd()).max(10)) as usize;
    (0..1 + rng.int(25))
        .map(|_| {
            let long = rng.chance(4);
            TimeRange::new(frames(rng.int(n)), frames(1 + rng.int(if long { 90 } else { 15 })))
        })
        .collect()
}

/// V1/A1 talking head (linked, J/L offsets, gaps), V2 B-roll with linked sound on A3, A2 music, random sync lock and locks,
/// point and range markers, In/Out.
fn random_timeline(rng: &mut Lcg, ids: &mut SequentialIds) -> (Timeline, BTreeSet<Id>) {
    let mk = |ids: &mut SequentialIds, kind, sync: bool| {
        let mut t = Track::new(ids.next_id(), kind);
        t.sync_lock = sync;
        t
    };
    let mut v1 = mk(ids, TrackKind::Video, true);
    let mut a1 = mk(ids, TrackKind::Audio, true);
    let s = !rng.chance(3);
    let mut v2 = mk(ids, TrackKind::Video, s);
    let s = !rng.chance(3);
    let mut a2 = mk(ids, TrackKind::Audio, s);
    let s = !rng.chance(2);
    let mut a3 = mk(ids, TrackKind::Audio, s);
    let mut t = frames(rng.int(10));
    let (mut v_end, mut a_end) = (Time::ZERO, Time::ZERO);
    let mut around = BTreeSet::new();
    let handle = frames(60);
    for _ in 0..2 + rng.int(6) {
        let len = frames(20 + rng.int(120));
        let (m, link) = (ids.next_id(), ids.next_id());
        let vs = t.max(v_end);
        let ve = t + len;
        let jc = if rng.chance(3) { rng.int(12) } else { 0 };
        let as0 = a_end.max(t - frames(jc));
        let l = if rng.chance(3) { rng.int(12) } else { 0 };
        let short = if rng.chance(4) { rng.int(8) } else { 0 };
        let ae = ve + frames(l) - frames(short);
        if ve <= vs || ae <= as0 {
            t = ve;
            continue;
        }
        let mut vc = Clip::new(ids.next_id(), "v", m, TrackKind::Video, TimeRange::new(handle + (vs - t), ve - vs), vs);
        let mut ac =
            Clip::new(ids.next_id(), "a", m, TrackKind::Audio, TimeRange::new(handle + (as0 - t), ae - as0), as0);
        vc.link = Some(link);
        ac.link = Some(link);
        vc.media_duration = Some(handle * 3 + len);
        ac.media_duration = Some(handle * 3 + len);
        if rng.chance(3) {
            vc.animation.opacity.track.insert(Keyframe::new(ids.next_id(), frames(rng.int(10)), 0.3));
        }
        if rng.chance(3) {
            ac.animation.volume.track.insert(Keyframe::new(ids.next_id(), frames(rng.int(10)), 0.6));
        }
        if rng.chance(4) {
            vc.markers = Some(vec![Marker {
                id: ids.next_id(),
                time: frames(rng.int(10)),
                name: "clip".into(),
                color: Default::default(),
                comment: String::new(),
                duration: Time::ZERO,
            }]);
        }
        let (aid, mut a_ok) = (ac.id, true);
        let _ = v1.overwrite(vc, ids);
        a_ok &= a1.overwrite(ac, ids).is_ok();
        if (!rng.chance(4) || around.is_empty()) && a_ok {
            around.insert(aid);
        }
        v_end = ve;
        a_end = ae;
        t = ve + if rng.chance(3) { frames(rng.int(30)) } else { Time::ZERO };
    }
    let mut bt = frames(rng.int(40));
    for _ in 0..rng.int(5) {
        let len = frames(10 + rng.int(60));
        let m = ids.next_id();
        let mut c = Clip::new(ids.next_id(), "b", m, TrackKind::Video, TimeRange::new(Time::ZERO, len), bt);
        if rng.chance(2) {
            let link = ids.next_id();
            c.link = Some(link);
            let mut bs = Clip::new(ids.next_id(), "bs", m, TrackKind::Audio, TimeRange::new(Time::ZERO, len), bt);
            bs.link = Some(link);
            let _ = a3.overwrite(bs, ids);
        }
        let _ = v2.overwrite(c, ids);
        bt += len + frames(rng.int(40));
    }
    if !rng.chance(4) {
        let end = v_end.max(a_end) + frames(rng.int(30));
        let m = ids.next_id();
        let _ = a2.overwrite(
            Clip::new(ids.next_id(), "music", m, TrackKind::Audio, TimeRange::new(Time::ZERO, end), Time::ZERO),
            ids,
        );
    }
    let mut tl = Timeline::new(ids.next_id(), "r", SequenceFormat::new(fd()), vec![v1, v2, a1, a2, a3]);
    if rng.chance(8) {
        tl.tracks[1].is_locked = true;
    }
    if rng.chance(8) {
        tl.tracks[4].is_locked = true;
    }
    if rng.chance(12) {
        tl.tracks[0].is_locked = true;
    }
    // Transitions at touching cuts on V1/A1 and a head / tail fade.
    for ti in [0usize, 2] {
        let kind = if ti == 0 { TransitionKind::CrossDissolve } else { TransitionKind::ConstantPower };
        let (track, clips) = (tl.tracks[ti].id, tl.tracks[ti].clips().to_vec());
        let mk = |outgoing: Option<Id>, incoming: Option<Id>, n: usize| NewTransition {
            kind,
            track,
            outgoing,
            incoming,
            duration: frames(n),
            alignment: TransitionAlignment::Center,
            custom_before: Time::ZERO,
        };
        for w in clips.windows(2).filter(|w| w[0].timeline().end() == w[1].start) {
            if rng.chance(2) {
                let _ = tl.add_transition(&mk(Some(w[0].id), Some(w[1].id), 6), ids);
            }
        }
        if let Some(f) = clips.first().filter(|_| rng.chance(2)) {
            let _ = tl.add_transition(&mk(None, Some(f.id), 8), ids);
        }
        if let Some(l) = clips.last().filter(|_| rng.chance(2)) {
            let _ = tl.add_transition(&mk(Some(l.id), None, 8), ids);
        }
    }
    // Captions: one track with word timings, one maybe without sync lock or locked.
    let (end, mut items, mut plain, mut ct) = (tl.duration(), Vec::new(), Vec::new(), Time::ZERO);
    let caption = |ids: &mut SequentialIds, text: &str, range: TimeRange, words: Vec<CaptionWord>| CaptionItem {
        id: ids.next_id(),
        lines: vec![text.to_string()],
        range,
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words,
        position: None,
    };
    while ct < end {
        let len = frames(10 + rng.int(50));
        let half = frames(5);
        let word = |text: &str, range| CaptionWord { text: text.to_string(), range, confidence: None };
        let words = if rng.chance(2) {
            vec![word("w", TimeRange::new(ct, half)), word("x", TimeRange::from_end(ct + half, ct + len))]
        } else {
            Vec::new()
        };
        items.push(caption(ids, "w x", TimeRange::new(ct, len), words));
        if rng.chance(2) {
            plain.push(caption(ids, "p", TimeRange::new(ct, len), Vec::new()));
        }
        ct += len + frames(rng.int(8));
    }
    let (first, second) = (tl.add_caption_track(ids), tl.add_caption_track(ids));
    let _ = tl.replace_captions(items, Some(first), ids);
    let _ = tl.replace_captions(plain, Some(second), ids);
    tl.caption_tracks[1].is_locked = rng.chance(4);
    tl.caption_tracks[1].sync_lock = !rng.chance(3);
    let n = (tl.duration().frame_index(fd()).max(10)) as usize;
    let mut markers: Vec<Marker> = (0..rng.int(12))
        .map(|_| {
            let dur = if rng.chance(3) { frames(1 + rng.int(60)) } else { Time::ZERO };
            Marker {
                id: ids.next_id(),
                time: frames(rng.int(n + 20)),
                name: String::new(),
                color: Default::default(),
                comment: String::new(),
                duration: dur,
            }
        })
        .collect();
    markers.sort_by_key(|m| (m.time, m.id));
    tl.markers = markers;
    if rng.chance(2) {
        let a = frames(rng.int(n));
        let b = a + frames(1 + rng.int(n));
        let kind = [Some(InOutKind::Both), Some(InOutKind::InOnly), Some(InOutKind::OutOnly), None][rng.int(4)];
        tl.in_out = Some(TimeRange::from_end(if kind == Some(InOutKind::OutOnly) { Time::ZERO } else { a }, b));
        tl.in_out_kind = kind;
    }
    (tl, around)
}

fn expect_same(tl: &Timeline, cuts: &[TimeRange], around: &BTreeSet<Id>, playhead: Time, seed: u64) {
    let (mut a, mut b) = (tl.clone(), tl.clone());
    let (mut ia, mut ib) = (SequentialIds::default(), SequentialIds::default());
    for _ in 0..100_000 {
        ia.next_id();
        ib.next_id();
    }
    let (mut ra, mut rb) = (Time::ZERO, Time::ZERO);
    let (mut pa, mut pb) = (SequentialIds::default(), SequentialIds::default());
    let ea = a.following_ripple(playhead, &mut pa, |t| {
        ra = t.remove_silences(cuts, around, Time::ZERO, &mut ia)?;
        Ok::<(), EditError>(())
    });
    let eb = b.following_ripple(playhead, &mut pb, |t| {
        rb = sequential(t, cuts, around, &mut ib)?;
        Ok::<(), EditError>(())
    });
    match (ea, eb) {
        (Ok(x), Ok(y)) => {
            assert_eq!(x, y, "seed {seed}: playhead differs");
            assert_eq!(ra, rb, "seed {seed}: removed time differs");
            assert_eq!(canonical(&a), canonical(&b), "seed {seed}: timelines differ");
        }
        (Err(x), Err(y)) => assert_eq!(x, y, "seed {seed}: different errors"),
        (x, y) => panic!("seed {seed}: batch {x:?} vs sequential {y:?}"),
    }
}

#[test]
fn batch_equals_sequential_on_random_timelines() {
    for seed in 1..=160u64 {
        let mut rng = Lcg(seed.wrapping_mul(7919).wrapping_add(3));
        let mut ids = SequentialIds::default();
        let (tl, around) = random_timeline(&mut rng, &mut ids);
        let cuts = random_cuts(&mut rng, tl.duration() + frames(40));
        let n = tl.duration().frame_index(fd()) as usize + 40;
        let playhead = frames(rng.int(n));
        expect_same(&tl, &cuts, &around, playhead, seed);
    }
}

#[test]
fn the_playhead_follows_the_closed_spans() {
    let s = |n: i64| Time::new(n, 1);
    let mut ids = SequentialIds::default();
    let (m, link) = (ids.next_id(), ids.next_id());
    let mut v = Clip::new(ids.next_id(), "v", m, TrackKind::Video, TimeRange::new(Time::ZERO, s(20)), Time::ZERO);
    let mut a = Clip::new(ids.next_id(), "a", m, TrackKind::Audio, TimeRange::new(Time::ZERO, s(20)), Time::ZERO);
    v.link = Some(link);
    a.link = Some(link);
    let aid = a.id;
    let mut tv = Track::new(ids.next_id(), TrackKind::Video);
    let mut ta = Track::new(ids.next_id(), TrackKind::Audio);
    tv.overwrite(v, &mut ids).expect("v");
    ta.overwrite(a, &mut ids).expect("a");
    let mut tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![tv, ta]);
    let around = BTreeSet::from([aid]);
    let cuts = [TimeRange::new(s(2), s(1)), TimeRange::new(s(6), s(2)), TimeRange::new(s(15), s(1))];
    let mut probe = SequentialIds::default();
    let mut work = SequentialIds::default();
    let landed = tl
        .following_ripple(s(10), &mut probe, |t| t.remove_silences(&cuts, &around, Time::ZERO, &mut work).map(drop))
        .expect("ripple");
    assert_eq!(landed, s(7)); // 3 s closed before it, the cut at 15 s after it
    let rev: Vec<TimeRange> = cuts.iter().rev().copied().collect();
    assert_eq!(landed, Timeline::playhead_after_ripple(s(10), &rev));
    let mut tl2 = tl.clone();
    let inside = tl2.following_ripple(s(6), &mut probe, |t| {
        t.remove_silences(&[TimeRange::new(s(5), s(2))], &around, Time::ZERO, &mut work).map(drop)
    });
    assert!(inside.is_ok());
}

#[test]
fn a_locked_track_refuses_and_changes_nothing() {
    let s = |n: i64| Time::new(n, 1);
    let mut ids = SequentialIds::default();
    let (m, link) = (ids.next_id(), ids.next_id());
    let mut v = Clip::new(ids.next_id(), "v", m, TrackKind::Video, TimeRange::new(Time::ZERO, s(10)), Time::ZERO);
    let mut a = Clip::new(ids.next_id(), "a", m, TrackKind::Audio, TimeRange::new(Time::ZERO, s(10)), Time::ZERO);
    v.link = Some(link);
    a.link = Some(link);
    let aid = a.id;
    let mut tv = Track::new(ids.next_id(), TrackKind::Video);
    let mut ta = Track::new(ids.next_id(), TrackKind::Audio);
    tv.overwrite(v, &mut ids).expect("v");
    ta.overwrite(a, &mut ids).expect("a");
    tv.is_locked = true;
    let mut tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![tv, ta]);
    let before = tl.clone();
    let r = tl.remove_silences(&[TimeRange::new(s(2), s(1))], &BTreeSet::from([aid]), Time::ZERO, &mut ids);
    assert_eq!(r, Err(EditError::TrackLocked));
    assert!(tl == before);
}
