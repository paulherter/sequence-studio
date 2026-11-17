use super::*;
use crate::analysis_links::magic_job::TrackOutcome;
use crate::analysis_links::mask_track::MaskFrameSource;
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_analysis::mask_point_tracker::Gray;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_model::{MediaFingerprint, MediaRef, TrackKind};
use sq_core_time::{SequentialIds, TimeRange};
use sq_editor_session::SessionDeps;
use std::collections::BTreeSet;
use std::sync::Mutex;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-magic"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        p.media.push(MediaRef::new(Id::from_u128(101), "m", "/tmp/m.mov", MediaFingerprint::new(1)));
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let c = sq_core_model::Clip::new(
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
    s.take_changes();
    s
}

struct Frames(usize);
impl TrackFrames for Frames {
    fn count(&self) -> usize {
        self.0
    }
    fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
        Some((i as f64 / 30.0, SubjectFrame::new(1, 1, vec![0; 4])))
    }
}

struct Always;
impl Tracker for Always {
    fn start(&mut self, _: &SubjectFrame, _: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
        Ok(SubjectMatte::new(1, 1, vec![1.0]))
    }
    fn next(&mut self, _: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
        Ok(Some(SubjectMatte::new(1, 1, vec![1.0])))
    }
}

/// Fake frames and tracker; remembers what range was asked for.
type Asked = Arc<Mutex<Vec<(String, Time, Time)>>>;

struct Fake {
    asked: Asked,
}
impl RunSources for Fake {
    fn frames(&self, path: &Path, from: Time, to: Time) -> Result<Box<dyn TrackFrames>, String> {
        self.asked.lock().map_err(|e| e.to_string())?.push((path.display().to_string(), from, to));
        Ok(Box::new(Frames(3)))
    }
    fn tracker(&self) -> Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send> {
        Box::new(|| Ok(Box::new(Always) as Box<dyn Tracker>))
    }
}

fn runner() -> (MagicRunner, Asked, Arc<FrameMatteStore>) {
    let asked = Arc::new(Mutex::new(Vec::new()));
    let store = Arc::new(FrameMatteStore::new(None));
    let r = MagicRunner::new(
        Arc::clone(&store),
        Box::new(Fake { asked: Arc::clone(&asked) }),
        Box::new(SequentialIds::default()),
    );
    (r, asked, store)
}

fn finish(r: &mut MagicRunner) -> Vec<String> {
    let mut all = Vec::new();
    for _ in 0..500 {
        all.extend(r.poll());
        if !r.is_running() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    all
}

fn tool_on() -> MagicFlow {
    let f = MagicFlow::default();
    f.arm(true);
    f
}

#[test]
fn clicks_and_a_box_collect_until_enter_confirms() {
    let f = tool_on();
    f.click(Vec2::new(0.25, 0.5), false);
    f.drag_box(Vec2::new(0.5, 0.5), Vec2::new(0.75, 0.25));
    f.click(Vec2::new(0.9, 0.9), true);
    assert_eq!(f.points().len(), 3);
    assert_eq!(f.points()[1], (Vec2::new(0.625, 0.375), false));
    f.confirm();
    assert!(f.points().is_empty());
    assert!(matches!(f.take_requests().as_slice(), [FlowRequest::Confirm(p)] if p.len() == 3));
    assert!(f.take_requests().is_empty());
}

#[test]
fn nothing_counts_while_the_tool_is_off_and_escape_forgets() {
    let f = MagicFlow::default();
    f.click(Vec2::new(0.5, 0.5), false);
    f.confirm();
    assert!(f.points().is_empty() && f.take_requests().is_empty());
    f.arm(true);
    f.click(Vec2::new(0.5, 0.5), false);
    f.cancel();
    f.confirm();
    assert!(f.take_requests().is_empty());
}

#[test]
fn confirming_adds_a_mask_and_tracks_to_the_clip_end() {
    let mut s = session();
    let (mut r, asked, store) = runner();
    let notes = r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.4, 0.6), false)])]);
    assert_eq!(notes, ["Tracking mask..."]);
    let notes = finish(&mut r);
    assert_eq!(notes.last().map(String::as_str), Some("Tracked the mask over 3 frames."), "{notes:?}");
    let asked = asked.lock().map(|a| a.clone()).unwrap_or_default();
    assert_eq!(asked, [("/tmp/m.mov".to_string(), Time::ZERO, Time::seconds(2))]);
    let clip = s.active_timeline().and_then(|t| find_clip(t, Id::from_u128(1))).expect("clip");
    let magic = clip.masks().first().and_then(|m| m.magic.clone()).expect("a Magic mask");
    assert_eq!(magic.points.len(), 1);
    assert_eq!(store.times(&magic.cache_key(clip.media)).len(), 3);
}

#[test]
fn a_step_tracks_from_the_pick_frame_to_the_next_frame() {
    let mut s = session();
    let (mut r, asked, _) = runner();
    r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.5, 0.5), false)])]);
    finish(&mut r);
    let mask =
        s.active_timeline().and_then(|t| find_clip(t, Id::from_u128(1)).and_then(|c| c.masks().first().map(|m| m.id)));
    s.seek(Time::new(10, 30));
    r.handle(&mut s, vec![FlowRequest::TrackMagic { mask: mask.expect("mask"), step: Some(true) }]);
    finish(&mut r);
    let last = asked.lock().map(|a| a.last().cloned()).unwrap_or(None).expect("second run");
    assert_eq!((last.1, last.2), (Time::ZERO, Time::new(11, 30)));
}

#[test]
fn a_second_confirm_adds_to_the_mask_and_a_later_frame_is_a_correction() {
    let mut s = session();
    let (mut r, asked, store) = runner();
    r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.4, 0.6), false)])]);
    finish(&mut r);
    let clip_of = |s: &EditorSession| s.active_timeline().and_then(|t| find_clip(t, Id::from_u128(1))).expect("clip");
    // Same frame: removes an area, no second mask.
    r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.9, 0.9), true)])]);
    finish(&mut r);
    assert_eq!(clip_of(&s).masks().len(), 1);
    assert_eq!(clip_of(&s).masks()[0].magic.as_ref().map(|m| m.points.len()), Some(2));
    // Another frame: a correction point with its own source time, tracked again from the pick's frame.
    s.seek(Time::new(10, 30));
    r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.2, 0.2), false)])]);
    finish(&mut r);
    let clip = clip_of(&s);
    let magic = clip.masks()[0].magic.clone().expect("magic");
    assert_eq!(magic.points.len(), 3);
    assert_eq!(magic.points[2].source_time, Time::new(10, 30));
    let last = asked.lock().map(|a| a.last().cloned()).unwrap_or(None).expect("run");
    assert_eq!((last.1, last.2), (Time::ZERO, Time::seconds(2)));
    assert_eq!(store.times(&magic.cache_key(clip.media)).len(), 3);
    // Shift-Enter makes a second mask.
    r.handle(&mut s, vec![FlowRequest::ConfirmNew(vec![(Vec2::new(0.7, 0.7), false)])]);
    finish(&mut r);
    assert_eq!(clip_of(&s).masks().len(), 2);
}

#[test]
fn a_shift_click_makes_the_prompt_a_new_mask() {
    let f = tool_on();
    f.click_with(Vec2::new(0.5, 0.5), false, true);
    f.confirm();
    assert!(matches!(f.take_requests().as_slice(), [FlowRequest::ConfirmNew(_)]));
}

/// A textured 80 x 60 patch on a 160 x 120 picture that moves 2 px right per source frame.
struct Square;
impl MaskFrameSource for Square {
    fn gray_at(&mut self, source: Time) -> Option<Gray> {
        let frame = (source.value() as f64 / source.timescale() as f64 * 30.0).round();
        let (w, h) = (160usize, 120usize);
        let ox = 40.0 + 2.0 * frame;
        let mut px = vec![0.3f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let (u, v) = (x as f64 - ox, y as f64 - 30.0);
                if (0.0..80.0).contains(&u) && (0.0..60.0).contains(&v) {
                    px[y * w + x] = 0.5 + 0.4 * ((u * 0.55).sin() * (v * 0.45).cos()) as f32;
                }
            }
        }
        Some(Gray { w, h, px })
    }
}

struct MaskFake;
impl RunSources for MaskFake {
    fn frames(&self, _: &Path, _: Time, _: Time) -> Result<Box<dyn TrackFrames>, String> {
        Err("no matte frames".to_string())
    }
    fn tracker(&self) -> Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send> {
        Box::new(|| Err("no model".to_string()))
    }
    fn mask_frames(&self, _: &Path) -> Box<dyn FnOnce() -> Result<Box<dyn MaskFrameSource>, String> + Send> {
        Box::new(|| Ok(Box::new(Square) as Box<dyn MaskFrameSource>))
    }
}

#[test]
fn a_drawn_mask_follows_a_moving_square_and_gets_path_keys() {
    use sq_core_masks::masks::ClipMasksExt;
    use sq_core_model::{ClipMask, MaskPath, MaskShapeKind};
    let mut s = session();
    let id = Id::from_u128(77);
    let mut clip = selected_clip(&s).expect("clip").0;
    let rect = MaskPath::rectangle(Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.75));
    clip.set_masks(vec![ClipMask::new(id, "Mask 1", MaskShapeKind::Rectangle, rect)]);
    s.replace_displayed_clip(clip, "Add Mask", false);
    let mut r =
        MagicRunner::new(Arc::new(FrameMatteStore::new(None)), Box::new(MaskFake), Box::new(SequentialIds::default()));
    let notes =
        r.handle(&mut s, vec![FlowRequest::TrackMask { mask: id, forward: true, mode: MaskTrackMode::Position }]);
    assert_eq!(notes, ["Tracking mask forward..."]);
    let mut lines = Vec::new();
    // The run is CPU work on its own thread, so how long it takes depends on machine load (a fixed 15 s loop failed under a
    // full workspace run). Wait for the job to say it is done; the guard only catches a hung job.
    let started = std::time::Instant::now();
    loop {
        lines.extend(r.poll_masks(&mut s));
        if !r.is_running() {
            break;
        }
        assert!(started.elapsed() < std::time::Duration::from_secs(600), "the mask run hung: {lines:?}");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(lines.iter().any(|l| l.starts_with("Tracked the mask over")), "{lines:?}");
    let clip = selected_clip(&s).expect("clip").0;
    let track = &clip.mask(id).expect("mask").path.track;
    assert!(track.keys.len() >= 20, "{} keys", track.keys.len());
    // Frame 10 (a third of a second in): the square moved 20 px of 160.
    let at = Time::new(10, 30);
    let center = {
        let poly = clip.mask(id).expect("mask").path.value_at_local(at).polygon();
        poly.iter().fold(Vec2::ZERO, |a, p| a + *p) * (1.0 / poly.len() as f64)
    };
    assert!((center.x - (0.5 + 20.0 / 160.0)).abs() < 0.01, "center {center:?}");
    assert!((center.y - 0.5).abs() < 0.01, "center {center:?}");
}

#[test]
fn without_a_selected_clip_nothing_starts() {
    let mut s = session();
    s.select(BTreeSet::new(), BTreeSet::new());
    let (mut r, asked, _) = runner();
    assert!(r.handle(&mut s, vec![FlowRequest::Confirm(vec![(Vec2::new(0.5, 0.5), false)])]).is_empty());
    assert!(asked.lock().map(|a| a.is_empty()).unwrap_or(false));
    let _ = TrackOutcome { frames: 0, stopped: false, error: None };
}
