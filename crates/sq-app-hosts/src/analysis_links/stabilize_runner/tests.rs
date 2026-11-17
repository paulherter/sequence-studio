use super::*;
use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::stabilization_analyzing::{Progress, StabilizationError};
use sq_core_masks::stabilizer::{CameraMotion, StabilizationAnalysis};
use sq_core_model::{ClipEffect, MediaFingerprint, MediaInfo, MediaRef, TrackKind};
use sq_core_time::{SequentialIds, Time, TimeRange};
use sq_editor_session::SessionDeps;
use std::sync::Arc;

const CLIP: u128 = 1;

fn session(stabilizer: bool) -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-stabilize"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut media = MediaRef::new(Id::from_u128(101), "m", "/tmp/m.mov", MediaFingerprint::new(1));
        media.info = serde_json::from_value::<MediaInfo>(serde_json::json!({
            "duration": {"value": 2, "timescale": 1},
            "video": {"width": 640, "height": 360, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0}
        }))
        .ok();
        p.media.push(media);
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let mut c = sq_core_model::Clip::new(
            Id::from_u128(CLIP),
            "clip",
            Id::from_u128(101),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        if stabilizer {
            c.effects.extend(ClipEffect::make(Id::from_u128(77), ClipEffect::STABILIZE_KIND));
        }
        assert!(t.tracks[0].insert(c, &mut ids).is_ok());
    });
    s.select(std::collections::BTreeSet::from([Id::from_u128(CLIP)]), std::collections::BTreeSet::new());
    s
}

/// Answers with an identity path over the whole range, or fails.
struct Fake(bool);
impl StabilizationAnalyzing for Fake {
    fn analyze(
        &self,
        range: TimeRange,
        w: i64,
        h: i64,
        _: Progress<'_>,
        _: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        if self.0 {
            return Err(StabilizationError::Unreadable);
        }
        let times: Vec<Time> = (0..61).map(|i| range.start + Time::new(i, 30)).collect();
        let motions = vec![CameraMotion::IDENTITY; times.len()];
        Ok(StabilizationAnalysis::new(w, h, times, motions))
    }
}

fn runner(fail: bool) -> (StabilizeRunner, StabilizationStore) {
    let store = StabilizationStore::default();
    let r = StabilizeRunner::new(store.clone(), None, Box::new(move |_| Box::new(Fake(fail))), Arc::new(|| {}));
    (r, store)
}

fn poll_until(r: &mut StabilizeRunner, s: &mut EditorSession, done: impl Fn(&[String]) -> bool) -> Vec<String> {
    let mut all = Vec::new();
    for _ in 0..500 {
        all.extend(r.poll(s));
        if done(&all) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    all
}

#[test]
fn enabling_the_stabilizer_starts_the_analysis_and_the_result_is_kept() {
    let mut s = session(true);
    let (mut r, store) = runner(false);
    let first = r.poll(&mut s);
    assert_eq!(first, vec!["Analyzing the clip for the Stabilizer...".to_string()]);
    assert!(r.progress().is_some());
    let all = poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("done")));
    assert!(all.iter().any(|l| l == "Stabilizer analysis done."), "{all:?}");
    assert!(store.get("/tmp/m.mov", TimeRange::new(Time::ZERO, Time::seconds(2)), 640, 360).is_some());
    assert!(r.progress().is_none());
    assert!(r.poll(&mut s).is_empty(), "the clip is analyzed: nothing more starts");
}

#[test]
fn a_clip_without_a_stabilizer_starts_nothing() {
    let mut s = session(false);
    let (mut r, _) = runner(false);
    assert!(r.poll(&mut s).is_empty() && r.progress().is_none());
}

#[test]
fn a_failed_run_says_why_and_is_not_started_again() {
    let mut s = session(true);
    let (mut r, _) = runner(true);
    r.poll(&mut s);
    let all = poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("failed")));
    assert!(all.iter().any(|l| l.starts_with("Stabilizer analysis failed")), "{all:?}");
    assert!(r.poll(&mut s).is_empty(), "no retry loop");
}

#[test]
fn stop_ends_the_run_and_start_runs_it_again_even_when_analyzed() {
    let mut s = session(true);
    let (mut r, store) = runner(false);
    r.poll(&mut s);
    assert_eq!(r.running().map(|x| x.0), Some(Id::from_u128(CLIP)));
    r.cancel();
    assert!(r.running().is_none());
    assert!(r.poll(&mut s).is_empty(), "stopped: no restart by itself");
    r.start_for(Id::from_u128(CLIP));
    let all = poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("done")));
    assert!(all.iter().any(|l| l == "Stabilizer analysis done."), "{all:?}");
    assert!(store.get("/tmp/m.mov", TimeRange::new(Time::ZERO, Time::seconds(2)), 640, 360).is_some());
    // Start Again on an analyzed clip measures it once more.
    r.start_for(Id::from_u128(CLIP));
    assert_eq!(r.poll(&mut s), vec!["Analyzing the clip for the Stabilizer...".to_string()]);
}

#[test]
fn a_clip_is_requested_or_failed_never_both_and_a_start_during_a_failing_run_still_runs() {
    let mut s = session(true);
    let (mut r, _) = runner(true);
    r.poll(&mut s);
    r.start_for(Id::from_u128(CLIP));
    assert_eq!(r.clip_state(Id::from_u128(CLIP)), Some(ClipStab::Requested));
    let all = poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.starts_with("Analyzing")));
    assert!(all.iter().any(|l| l.starts_with("Stabilizer analysis failed")), "{all:?}");
    assert!(all.iter().any(|l| l.starts_with("Analyzing")), "the Start pressed during the run is honored: {all:?}");
    r.cancel();
    assert_eq!(r.clip_state(Id::from_u128(CLIP)), Some(ClipStab::Failed));
    r.start_for(Id::from_u128(CLIP));
    assert_eq!(r.clip_state(Id::from_u128(CLIP)), Some(ClipStab::Requested));
}

#[test]
fn several_started_clips_run_one_after_the_other_over_the_range_each_shows() {
    let mut s = session(true);
    s.perform("Second clip", None, |p| {
        let mut ids = SequentialIds::default();
        let mut c = sq_core_model::Clip::new(
            Id::from_u128(2),
            "two",
            Id::from_u128(101),
            TrackKind::Video,
            TimeRange::new(Time::seconds(2), Time::seconds(1)),
            Time::ZERO,
        );
        c.effects.extend(ClipEffect::make(Id::from_u128(78), ClipEffect::STABILIZE_KIND));
        assert!(p.timelines[0].tracks[0].insert(c, &mut ids).is_ok());
    });
    let (mut r, store) = runner(false);
    r.poll(&mut s);
    poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("done")));
    poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("done")));
    assert!(r.running().is_none());
    // Start Again on both (already analyzed): both run, the second after the first.
    r.start_for(Id::from_u128(CLIP));
    r.start_for(Id::from_u128(2));
    assert_eq!(r.poll(&mut s), vec!["Analyzing the clip for the Stabilizer...".to_string()]);
    assert_eq!(r.running().map(|x| x.0), Some(Id::from_u128(CLIP)));
    poll_until(&mut r, &mut s, |l| l.iter().any(|x| x.contains("Analyzing")));
    assert_eq!(r.running().map(|x| x.0), Some(Id::from_u128(2)), "the second request was kept");
    // Only the range the clip shows is measured.
    let shown = TimeRange::new(Time::ZERO, Time::seconds(1));
    assert!(store.get("/tmp/m.mov", shown, 640, 360).is_some());
}
