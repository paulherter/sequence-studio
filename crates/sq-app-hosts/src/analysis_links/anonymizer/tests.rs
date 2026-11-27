//! The Anonymize analysis over a fake detector and tracker: two moving people become two sightings, each followed both ways
//! from its frame into staged mattes.

use super::*;
use sq_core_masks::anonymize::AnonymizeFace;

/// A frame carries its time in tenths of a second in the first byte.
fn frame_at(t: f64) -> SubjectFrame {
    let mut rgba = vec![0u8; 4 * 4 * 4];
    rgba[0] = (t * 10.0).round() as u8;
    SubjectFrame::new(4, 4, rgba)
}

fn time_of(frame: &SubjectFrame) -> f64 {
    f64::from(frame.rgba[0]) / 10.0
}

struct Frames {
    times: Vec<f64>,
}

impl TrackFrames for Frames {
    fn count(&self) -> usize {
        self.times.len()
    }
    fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
        self.times.get(i).map(|t| (*t, frame_at(*t)))
    }
}

struct Follow {
    /// The person is gone after this time.
    gone_after: Option<f64>,
}

impl Tracker for Follow {
    fn start(&mut self, _: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
        assert_eq!(points.len(), 1, "the pick is one point");
        Ok(SubjectMatte::new(1, 1, vec![1.0]))
    }
    fn next(&mut self, f: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
        Ok(self.gone_after.is_none_or(|g| time_of(f) <= g + 1e-6).then(|| SubjectMatte::new(1, 1, vec![1.0])))
    }
}

/// Person A walks right over 4 s (a body and its face), person B stands at the right.
pub(crate) struct Fake {
    /// The person is gone after this time.
    pub gone_after: Option<f64>,
}

fn body(cx: f64) -> AnonymizeBox {
    AnonymizeBox { x: cx - 0.05, y: 0.3, width: 0.1, height: 0.4 }
}

impl AnonymizeSources for Fake {
    fn shown(&self, seconds: f64) -> Result<Option<(f64, SubjectFrame)>, String> {
        Ok((0.0..=4.0).contains(&seconds).then(|| (seconds, frame_at(seconds))))
    }
    fn frames(&self, from: f64, to: f64) -> Result<Box<dyn TrackFrames>, String> {
        let n = ((to - from).abs() * 10.0).round() as usize;
        let sign = if to < from { -1.0 } else { 1.0 };
        Ok(Box::new(Frames { times: (0..=n).map(|i| from + sign * i as f64 / 10.0).collect() }))
    }
    fn tracker(&self) -> Result<Box<dyn Tracker>, String> {
        Ok(Box::new(Follow { gone_after: self.gone_after }))
    }
    fn detect(&self, frame: &SubjectFrame, bodies: bool) -> Result<(Vec<AnonymizeBox>, Vec<AnonymizeFace>), String> {
        let t = time_of(frame);
        let a = 0.1 + 0.1 * t;
        let faces = vec![AnonymizeFace {
            box_: AnonymizeBox { x: a - 0.02, y: 0.32, width: 0.04, height: 0.06 },
            confidence: 0.9,
        }];
        Ok((if bodies { vec![body(a), body(0.8)] } else { Vec::new() }, faces))
    }
}

fn find(src: &Fake) -> Vec<AnonymizeSighting> {
    find_everyone(src, 0.0, 4.0, 2.0, &CancelToken::new(), &mut |_| {}, &mut |_| {}).expect("search").expect("frames")
}

#[test]
fn two_moving_people_are_two_sightings_picked_on_the_anchor_frame() {
    let s = find(&Fake { gone_after: None });
    assert_eq!(s.len(), 2, "{s:?}");
    assert!(s[0].person.box_.center().x < s[1].person.box_.center().x);
    assert!(s.iter().all(|x| (x.pts - 2.0).abs() < 1e-9), "both are on the anchor frame");
    assert!(s[0].person.face.is_some() && s[1].person.face.is_none());
    // The pick: one add point at the sighting's frame, narrowed to the target.
    let pick = selection(&s[0].person, s[0].pts, AnonymizeTarget::Face);
    assert_eq!(pick.part, Some(AnonymizeTarget::Face));
    assert_eq!(pick.anchor_time(), Some(Time::new(180_000, 90_000)));
}

#[test]
fn each_person_is_followed_both_ways_into_staged_mattes_that_commit_under_the_mask_keys() {
    let fake = Fake { gone_after: None };
    let sightings = find(&fake);
    let store = FrameMatteStore::new(None);
    let media = Id::from_u128(7);
    let picks: Vec<MagicSelection> =
        sightings.iter().map(|s| selection(&s.person, s.pts, AnonymizeTarget::Person)).collect();
    let mut seen = Vec::new();
    let out =
        run(&fake, &picks, media, 0.0, 4.0, 0.1, &store, "t1", &CancelToken::new(), &mut |p| seen.push(p), &mut |_| {})
            .expect("run");
    // 21 frames each way, the pick frame twice.
    assert_eq!(out.frames, 2 * 42);
    assert!(out.checks.is_empty(), "{:?}", out.checks);
    assert_eq!(out.staged.len(), 2);
    for s in &out.staged {
        assert!(s.temp.starts_with("staged-t1-") && s.temp.ends_with(&s.key));
        assert_eq!(store.times(&s.temp).len(), 41, "every frame once");
        assert!(store.times(&s.key).is_empty(), "nothing under the mask's key before the commit");
    }
    assert!(seen.windows(2).all(|w| w[0] <= w[1] + 1e-9) && (seen.last().unwrap() - 1.0).abs() < 1e-9, "{seen:?}");
    commit(&out.staged, &store);
    for s in &out.staged {
        assert_eq!(store.times(&s.key).len(), 41);
        assert!(store.times(&s.temp).is_empty());
    }
}

#[test]
fn a_face_run_stores_the_narrowed_matte_and_lists_a_lost_person() {
    let fake = Fake { gone_after: Some(3.0) };
    let sightings = find(&fake);
    let store = FrameMatteStore::new(None);
    let picks = vec![selection(&sightings[0].person, sightings[0].pts, AnonymizeTarget::Face)];
    let out = run(
        &fake,
        &picks,
        Id::from_u128(7),
        0.0,
        4.0,
        0.1,
        &store,
        "t2",
        &CancelToken::new(),
        &mut |_| {},
        &mut |_| {},
    )
    .expect("run");
    assert_eq!(out.staged.len(), 2, "the person and the face");
    assert!(out.staged.iter().all(|s| !store.times(&s.temp).is_empty()), "both are stored");
    let lost: Vec<&AnonymizeCheck> = out.checks.iter().filter(|c| c.reason == AnonymizeReason::Lost).collect();
    assert_eq!(lost.len(), 1, "{:?}", out.checks);
    assert!((lost[0].from - 3.1).abs() < 1e-6 && (lost[0].to - 4.0).abs() < 1e-6, "{:?}", lost[0]);
}

#[test]
fn a_canceled_run_leaves_no_staged_mattes() {
    let fake = Fake { gone_after: None };
    let sightings = find(&fake);
    let store = FrameMatteStore::new(None);
    let picks = vec![selection(&sightings[0].person, sightings[0].pts, AnonymizeTarget::Person)];
    let cancel = CancelToken::new();
    let c = cancel.clone();
    let err = run(
        &fake,
        &picks,
        Id::from_u128(7),
        0.0,
        4.0,
        0.1,
        &store,
        "t3",
        &cancel,
        &mut |p| {
            if p > 0.2 {
                c.cancel();
            }
        },
        &mut |_| {},
    )
    .expect_err("canceled");
    assert_eq!(err, AnonymizeError::Canceled);
    let key = format!("staged-t3-{}", picks[0].cache_key(Id::from_u128(7)));
    assert!(store.times(&key).is_empty());
}

#[test]
fn a_body_with_two_faces_is_two_people_and_a_face_alone_gets_an_estimated_body() {
    let face =
        |x: f64, c: f64| AnonymizeFace { box_: AnonymizeBox { x, y: 0.32, width: 0.05, height: 0.07 }, confidence: c };
    let p = people_in(&[body(0.5)], &[face(0.48, 0.9), face(0.9, 0.8)]);
    assert_eq!(p.len(), 2);
    assert!(p[0].face.is_some_and(|f| f.confidence == 0.9) && p[0].box_.height == 0.4);
    assert!(p[1].box_.width > 0.1 && p[1].box_.x + p[1].box_.width <= 1.0 + 1e-9);
    assert!(people_in(&[], &[]).is_empty());
}

#[test]
fn a_box_inside_another_is_the_same_person_but_a_neighbor_is_not() {
    let whole = AnonymizeBox { x: 0.5, y: 0.1, width: 0.3, height: 0.8 };
    let upper = AnonymizeBox { x: 0.52, y: 0.15, width: 0.28, height: 0.5 };
    let next = AnonymizeBox { x: 0.1, y: 0.2, width: 0.2, height: 0.6 };
    let p = people_in(&[upper, whole, next], &[]);
    assert_eq!(p.len(), 2, "{p:?}");
    assert!(p[0].box_ == next && p[1].box_ == whole);
}
