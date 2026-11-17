use super::*;
use crate::analysis_links::magic_flow::{FlowRequest, RunSources};
use crate::analysis_links::magic_job::{TrackFrames, Tracker};
use crate::analysis_links::stabilization_store::StabilizationStore;
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_model::{Clip, MediaFingerprint, MediaRef, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange, Vec2};
use sq_editor_session::SessionDeps;
use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-analysis"));
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

struct Fake;
impl RunSources for Fake {
    fn frames(&self, _: &Path, _: Time, _: Time) -> Result<Box<dyn TrackFrames>, String> {
        Ok(Box::new(Frames(3)))
    }
    fn tracker(&self) -> Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send> {
        Box::new(|| Ok(Box::new(Always) as Box<dyn Tracker>))
    }
}

fn links() -> (AnalysisLinks, MagicFlow, Arc<FrameMatteStore>) {
    let flow = MagicFlow::default();
    let store = Arc::new(FrameMatteStore::new(None));
    let magic = MagicRunner::new(Arc::clone(&store), Box::new(Fake), Box::new(SequentialIds::default()));
    let stabilize = StabilizeRunner::new(
        StabilizationStore::default(),
        None,
        Box::new(|_| unreachable!("no Stabilizer on the clip")),
        Arc::new(|| {}),
    );
    (AnalysisLinks::new(flow.clone(), magic, stabilize), flow, store)
}

#[test]
fn a_confirmed_prompt_runs_with_progress_and_wakes_the_window() {
    let mut s = session();
    let (mut links, flow, store) = links();
    let wakes = Arc::new(AtomicUsize::new(0));
    let w = Arc::clone(&wakes);
    links.set_wake(Arc::new(move || {
        w.fetch_add(1, Ordering::SeqCst);
    }));
    assert_eq!(links.pump(&mut s), AnalysisTurn::default(), "idle: nothing to say");
    flow.request(FlowRequest::Confirm(vec![(Vec2::new(0.5, 0.5), false)]));
    let first = links.pump(&mut s);
    assert!(first.lines.iter().any(|l| l.starts_with("Tracking mask")), "{first:?}");
    // The three-frame job can finish on its thread before this first pump looks: then the bar is already gone and the
    // result line is there instead. Either is a correct first turn (a plain is_some() flaked on that race).
    assert!(first.progress.is_some() || first.lines.iter().any(|l| l.contains("Tracked")), "{first:?}");
    let mut lines = first.lines;
    // The job thread sends a message first and wakes after it, so the test waits for both (generous bound for a loaded machine).
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::time::Instant::now() < deadline {
        let turn = links.pump(&mut s);
        lines.extend(turn.lines);
        if turn.progress.is_none() && wakes.load(Ordering::SeqCst) >= 1 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(lines.iter().any(|l| l.contains("3 frames") || l.contains("Tracked")), "{lines:?}");
    assert!(wakes.load(Ordering::SeqCst) >= 1, "the job woke the loop");
    assert!(!store.times(&store_key(&s)).is_empty(), "mattes are in the store");
}

fn store_key(s: &EditorSession) -> String {
    use sq_core_masks::magic_mask::MagicSelectionExt;
    use sq_core_masks::masks::ClipMasksExt;
    let t = s.display_timeline().expect("timeline");
    let clip = t.tracks[0].clip(Id::from_u128(1)).expect("clip");
    clip.masks().iter().find_map(|m| m.magic.as_ref().map(|g| g.cache_key(clip.media))).expect("magic mask")
}
