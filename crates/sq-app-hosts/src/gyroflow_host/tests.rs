//! The Inspector's Gyroflow link: hooks, Analyze, Cancel and the revision bump, against a real session and model.

use super::*;
use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{SequentialIds, Time, TimeRange};
use sq_editor_session::{Change, EditorSession, SessionDeps};
use sq_inspector_ui::ec::stabilize::StabilizeRowStatus;
use std::time::{Duration, Instant};

const EFFECT: u128 = 90;

fn model_with_gyro_clip() -> (EffectControlsModel, Id, Clip) {
    let (clip_id, track_id, tl_id) = (Id::from_u128(11), Id::from_u128(12), Id::from_u128(13));
    let mut track = Track::new(track_id, TrackKind::Video);
    let source = TimeRange::new(Time::seconds(0), Time::seconds(4));
    let mut clip = Clip::new(clip_id, "Cam", Id::from_u128(14), TrackKind::Video, source, Time::seconds(2));
    let mut e = ClipEffect::make(Id::from_u128(EFFECT), ClipEffect::STABILIZE_KIND).expect("stabilize");
    e.parameters.insert(
        ClipEffect::STABILIZE_METHOD_KEY.to_string(),
        sq_core_model::AnimatedProperty::new(StabilizerMethod::Gyroflow as i64 as f64),
    );
    clip.effects.push(e);
    assert!(track.insert(clip, &mut SequentialIds::default()).is_ok());
    let tl = Timeline::new(tl_id, "Main", SequenceFormat::new(Time::new(1, 25)), vec![track]);
    let project = Project::new(Id::from_u128(2), "p", Vec::new(), vec![tl]);
    let mut s = EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-gyroflow-host")));
    s.set_active_timeline(tl_id);
    s.set_selection([clip_id].into(), Default::default());
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.sync(&s, Change::SELECTION | Change::PROJECT);
    let clip = m.clip().cloned().expect("the clip is shown");
    (m, Id::from_u128(EFFECT), clip)
}

fn paths(path: Option<&'static str>) -> PathOf {
    Arc::new(move |_| path.map(str::to_string))
}

#[test]
fn the_engine_state_maps_to_the_rows_state() {
    assert_eq!(analysis_state(GyroState::Idle), GyroAnalysisState::Idle);
    assert_eq!(analysis_state(GyroState::Analysing(0.6)), GyroAnalysisState::Analysing(0.6));
    assert_eq!(analysis_state(GyroState::Ready), GyroAnalysisState::Ready);
    assert_eq!(analysis_state(GyroState::Failed("x".into())), GyroAnalysisState::Failed("x".into()));
}

#[test]
fn a_clip_without_a_file_is_blocked_with_a_reason() {
    let (mut m, effect, _) = model_with_gyro_clip();
    let mut link = GyroflowLink::new(Arc::new(GyroEngine::new()));
    link.sync(&mut m, &paths(None));
    assert_eq!(
        m.stabilize_status(effect),
        StabilizeRowStatus::Blocked("The clip's file is not available.".to_string())
    );
}

#[test]
fn analyze_runs_the_engine_the_row_shows_the_failure_and_the_revision_moves() {
    let (mut m, effect, clip) = model_with_gyro_clip();
    let mut link = GyroflowLink::new(Arc::new(GyroEngine::new()));
    let p = paths(Some("/no/such/clip.mp4"));
    link.sync(&mut m, &p);
    assert_eq!(m.stabilize_status(effect), StabilizeRowStatus::NotAnalysed);
    let before = m.gyroflow_revision();
    assert!(link.analyze(&clip, &p));
    let t = Instant::now();
    loop {
        link.sync(&mut m, &p);
        if matches!(m.stabilize_status(effect), StabilizeRowStatus::Failed(_)) {
            break;
        }
        assert!(t.elapsed() < Duration::from_secs(20), "the analysis of a missing file must fail");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(m.gyroflow_revision() > before, "the engine's observer moved the row");
}

/// A real clip (ffmpeg testsrc) with a `.gcsv` sidecar through the Inspector's Analyze: the row goes from Not analysed to
/// Analysed. Skips without ffmpeg.
#[test]
fn analyze_of_a_clip_with_a_gcsv_sidecar_becomes_ready() {
    let dir = crate::test_rig::test_dir("sq-gyroflow-real");
    assert!(std::fs::create_dir_all(&dir).is_ok());
    let clip_file = dir.join("shaky.mp4");
    let made = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=2:s=320x180:r=30", "-c:v", "mpeg4"])
        .arg(&clip_file)
        .stdin(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !made {
        return;
    }
    let mut csv = String::from(
        "GYROFLOW IMU LOG\nversion,1.1\nid,sqtest\ntscale,0.001\ngscale,0.001\nascale,0.001\nt,gx,gy,gz,ax,ay,az\n",
    );
    for t in 0..2000 {
        let gz = (500.0 * (f64::from(t) * 0.02).sin()).round();
        csv.push_str(&format!("{t},0,0,{gz},0,0,1000\n"));
    }
    assert!(std::fs::write(dir.join("shaky.gcsv"), csv).is_ok());
    let path = clip_file.to_string_lossy().into_owned();
    let p: PathOf = Arc::new(move |_| Some(path.clone()));
    let (mut m, effect, clip) = model_with_gyro_clip();
    let mut link = GyroflowLink::new(Arc::new(GyroEngine::new()));
    link.sync(&mut m, &p);
    assert!(link.analyze(&clip, &p));
    let t = Instant::now();
    loop {
        link.sync(&mut m, &p);
        match m.stabilize_status(effect) {
            StabilizeRowStatus::Analysed => break,
            StabilizeRowStatus::Failed(e) => panic!("analysis failed: {e}"),
            _ => {}
        }
        assert!(t.elapsed() < Duration::from_secs(60), "the analysis must finish");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn cancel_and_analyze_of_a_clip_without_gyroflow_do_nothing() {
    let (_, _, mut clip) = model_with_gyro_clip();
    let link = GyroflowLink::new(Arc::new(GyroEngine::new()));
    let p = paths(Some("/no/such/clip.mp4"));
    link.cancel(&clip, &GyroflowOptions::from_effect(gyro_effect(&clip).expect("gyro")), &p);
    clip.effects.clear();
    assert!(!link.analyze(&clip, &p));
}

#[test]
fn the_shared_engine_is_one_for_every_caller() {
    assert!(Arc::ptr_eq(&shared_engine(), &shared_engine()));
    assert!(hook(true).wait && !hook(false).wait);
}
