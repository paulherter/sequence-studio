//! Auto Reframe through the shell's analysis services: the flows, the thread launcher and the message pump, over a fake
//! detector (the real models run in `subject_detection`'s ignored-by-env test).

use super::*;
use sq_analysis::reframe::{NormalizedRect, ReframeOptions, SubjectBox, SubjectDetecting, SubjectKind};
use sq_core_model::{
    Clip, ClipEffect, MediaFingerprint, MediaInfo, MediaRef, PixelAspect, Project, SequenceFormat, Timeline, Track,
    TrackKind, VideoTrackInfo,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use sq_editor_session::{AnalysisFlowsEvent, SessionDeps};
use std::future::Future;
use std::path::Path;
use std::time::{Duration, Instant};

const FD: Time = Time::new(1, 30);

struct Walk;
impl SubjectDetecting for Walk {
    type Error = String;
    fn subjects(&self, t: Time) -> Result<Vec<SubjectBox>, String> {
        let f = (t.value() as f64 / t.timescale() as f64 / 4.0).clamp(0.0, 1.0);
        let x = 0.3 + 0.4 * f;
        Ok(vec![SubjectBox {
            kind: SubjectKind::Face,
            rect: NormalizedRect { x: x - 0.05, y: 0.45, width: 0.1, height: 0.1 },
            confidence: 0.9,
        }])
    }
}

struct FakeBackend;
impl AnalysisBackend for FakeBackend {
    fn scene_changes(
        &self,
        _: &Path,
        _: TimeRange,
        _: &(dyn Fn(f64) + Send + Sync),
    ) -> Result<Option<Vec<Time>>, String> {
        Ok(None)
    }
    fn offers_reframe(&self) -> bool {
        true
    }
    fn offers_stabilize(&self) -> bool {
        false
    }
    fn subject_detector(&self, _: &MediaRef) -> Option<Box<dyn SubjectDetecting<Error = String> + Send>> {
        Some(Box::new(Walk))
    }
    fn stabilization_analyzer(&self, _: &MediaRef) -> Option<sq_editor_session::BoxedStabilizationAnalyzer> {
        None
    }
}

/// A portrait sequence with one landscape 4 s clip, selected.
fn session() -> (EditorSession, Id) {
    session_of("/nonexistent/m.mov")
}

pub(crate) fn session_of(path: &str) -> (EditorSession, Id) {
    let mut ids = SequentialIds::default();
    let video = VideoTrackInfo {
        width: 1920,
        height: 1080,
        codec: "avc1".into(),
        bit_depth: 8,
        chroma: "4:2:0".into(),
        nominal_frame_duration: FD,
        is_variable_frame_rate: false,
        color_primaries: None,
        transfer: None,
        matrix: None,
        rotation: 0,
        pixel_aspect: PixelAspect::square(),
        pixel_aspect_override: None,
        field_order: None,
        deinterlace_off: false,
    };
    let info = MediaInfo {
        duration: Time::seconds(4),
        video: Some(video),
        audio: None,
        detected_color_space: None,
        embedded_lut_name: None,
        is_still: false,
        sound_probed: None,
        created: None,
        camera_model: None,
        shoot_probed: None,
    };
    let mut media = MediaRef::new(ids.next_id(), "m", path, MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    media.info = Some(info);
    let clip = Clip::new(
        ids.next_id(),
        "c",
        media.id,
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::seconds(4)),
        Time::ZERO,
    );
    let clip_id = clip.id;
    let mut track = Track::new(ids.next_id(), TrackKind::Video);
    assert!(track.overwrite(clip, &mut ids).is_ok());
    let mut format = SequenceFormat::new(FD);
    (format.width, format.height) = (1080, 1920);
    let timeline = Timeline::new(ids.next_id(), "Vertical", format, vec![track]);
    let project = Project::new(ids.next_id(), "P", vec![media], vec![timeline]);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-analysis-services"));
    deps.ids = Box::new(ids);
    let mut s = EditorSession::new(project, deps);
    s.select(std::collections::BTreeSet::from([clip_id]), std::collections::BTreeSet::new());
    (s, clip_id)
}

fn pump_until(services: &mut AnalysisServices, session: &mut EditorSession, done: impl Fn(&AnalysisServices) -> bool) {
    let end = Instant::now() + Duration::from_secs(20);
    while !done(services) {
        assert!(Instant::now() < end, "the worker did not answer");
        services.pump(session);
        std::thread::sleep(Duration::from_millis(5));
    }
    services.pump(session);
}

fn events(services: &mut AnalysisServices) -> Vec<AnalysisFlowsEvent> {
    services.analysis().map(|(f, _)| f.take_events()).unwrap_or_default()
}

#[test]
fn auto_reframe_runs_on_a_worker_and_writes_the_stage_as_one_undo_step() {
    let (mut s, id) = session();
    let mut services = AnalysisServices::new(Box::new(FakeBackend));
    let woke = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let w = Arc::clone(&woke);
    services.set_wake(Arc::new(move || {
        w.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }));
    let (flows, launcher) = services.analysis().expect("analysis");
    let what = flows.reframe_subject(&mut s).expect("a clip to reframe");
    flows.run_auto_reframe(&mut s, launcher, ReframeOptions::default(), &what);
    assert!(flows.is_reframing());
    pump_until(&mut services, &mut s, |sv| !sv.analysis_flows().is_some_and(AnalysisFlows::is_reframing));
    let clip = s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip");
    assert!(clip.effects.iter().any(|e| e.kind == ClipEffect::REFRAME_KIND), "the Reframe stage is on the clip");
    assert!(woke.load(std::sync::atomic::Ordering::SeqCst) >= 1, "the worker woke the app");
    let flashes: Vec<String> = events(&mut services)
        .into_iter()
        .filter_map(|e| if let AnalysisFlowsEvent::Flash { message, .. } = e { Some(message) } else { None })
        .collect();
    assert!(flashes.iter().any(|m| m.starts_with("Reframed 1 clip(s)")), "{flashes:?}");
    assert!(s.undo(), "one undo step takes it away");
    let clip = s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip");
    assert!(!clip.effects.iter().any(|e| e.kind == ClipEffect::REFRAME_KIND));
}

#[test]
fn a_second_request_cancels_a_running_reframe_and_changes_nothing() {
    let (mut s, id) = session();
    let mut services = AnalysisServices::new(Box::new(FakeBackend));
    let (flows, launcher) = services.analysis().expect("analysis");
    flows.run_auto_reframe(&mut s, launcher, ReframeOptions::default(), "c");
    assert_eq!(flows.reframe_subject(&mut s), None, "asking again cancels the run");
    pump_until(&mut services, &mut s, |sv| !sv.analysis_flows().is_some_and(AnalysisFlows::is_reframing));
    let clip = s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip");
    assert!(!clip.effects.iter().any(|e| e.kind == ClipEffect::REFRAME_KIND));
}

/// The real face / body models over a real clip with a person (`SQ_REAL_PERSON_CLIP`; models in `SQ_PERSON_MODELS`, ONNX
/// Runtime on PATH): Auto Reframe through the portable backend writes the Reframe stage. Skips without the clip or the runtime.
#[test]
fn a_real_clip_with_a_person_is_reframed_through_the_real_models() {
    let Ok(path) = std::env::var("SQ_REAL_PERSON_CLIP") else {
        eprintln!("skipped: SQ_REAL_PERSON_CLIP is not set");
        return;
    };
    if !sq_translate::translator::runtime_available() {
        eprintln!("skipped: no ONNX Runtime (put it on PATH or set SQ_ONNXRUNTIME to its folder)");
        return;
    }
    let (mut s, id) = session_of(&path);
    let mut services = AnalysisServices::new(Box::new(crate::PortableAnalysisBackend));
    let (flows, launcher) = services.analysis().expect("analysis");
    let what = flows.reframe_subject(&mut s).expect("a clip to reframe");
    flows.run_auto_reframe(&mut s, launcher, ReframeOptions::default(), &what);
    pump_until(&mut services, &mut s, |sv| !sv.analysis_flows().is_some_and(AnalysisFlows::is_reframing));
    let lines: Vec<String> = events(&mut services)
        .into_iter()
        .filter_map(|e| if let AnalysisFlowsEvent::Flash { message, .. } = e { Some(message) } else { None })
        .collect();
    eprintln!("real run: {lines:?}");
    let clip = s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip");
    assert!(clip.effects.iter().any(|e| e.kind == ClipEffect::REFRAME_KIND), "{lines:?}");
}

/// The app gives the flows a real frame sampler (it was only ever set in tests); a run that never gets its picture ends
/// at the deadline instead of leaving the monitor on the solo view.
#[test]
fn the_standard_services_have_a_frame_sampler_and_a_silent_run_expires() {
    let picture = crate::MonitorPicture::default();
    let mut services = AnalysisServices::new(Box::new(crate::PortableAnalysisBackend))
        .with_frame_sampler(crate::analysis_links::picture_sampler::PictureSampler::new(picture));
    assert!(services.flows.frame_sampler.is_some());
    let (mut s, _) = session();
    services.color_match = Some((7, Instant::now()));
    services.pump(&mut s);
    assert!(services.color_match.is_none(), "an idle run is dropped at its deadline");
}

/// Polls a modal ask once; it resolves when the pump has answered it.
fn answered<T>(ask: &mut ModalAsk<T>) -> Option<T> {
    let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
    match std::pin::Pin::new(ask).poll(&mut cx) {
        std::task::Poll::Ready(v) => Some(v),
        std::task::Poll::Pending => None,
    }
}

fn speak(services: &mut AnalysisServices, voice: &str, url: &Path) -> Option<Result<Time, ShellVoiceoverError>> {
    let (mut s, _) = session();
    let mut ask = services.render_voiceover("Hello   there", voice, 0.5, url)?;
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        services.pump(&mut s);
        if let Some(r) = answered(&mut ask) {
            return Some(r);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    None
}

#[test]
fn voiceover_without_an_engine_is_not_available() {
    let mut services = AnalysisServices::new(Box::new(FakeBackend));
    assert!(services.voices().is_none());
    assert!(services.render_voiceover("hi", "tone", 0.5, Path::new("/nonexistent/v.wav")).is_none());
}

#[test]
fn voiceover_lists_voices_and_renders_text_into_a_file() {
    let mut services =
        AnalysisServices::new(Box::new(FakeBackend)).with_speech(Some(Arc::new(sq_platform_tts::ToneSpeech)));
    assert_eq!(services.voices(), Some(vec![("tone".to_string(), "Tone (en-US)".to_string())]));
    let url = std::env::temp_dir().join(format!("sq-vo-{}/Hello there.wav", std::process::id()));
    // "Hello there" cleaned is 11 characters at 50 ms each, 48 kHz.
    assert_eq!(speak(&mut services, "tone", &url), Some(Ok(Time::new(11 * 2400, 48_000))));
    assert_eq!(sq_platform_tts::wav_frames(&url).ok(), Some((48_000, 11 * 2400)));
    let _ = std::fs::remove_dir_all(url.parent().unwrap_or(&url));
}

#[test]
fn voiceover_failures_reach_the_flow_as_its_two_errors() {
    let mut services =
        AnalysisServices::new(Box::new(FakeBackend)).with_speech(Some(Arc::new(sq_platform_tts::ToneSpeech)));
    let url = std::env::temp_dir().join(format!("sq-vo-fail-{}.wav", std::process::id()));
    assert_eq!(speak(&mut services, "none", &url), Some(Err(ShellVoiceoverError::NoAudio)));
    assert_eq!(speak(&mut services, "broken", &url), Some(Err(ShellVoiceoverError::Failed)));
    assert!(!url.exists());
    assert!(services.speech_jobs.is_empty(), "answered jobs are dropped");
}

#[test]
fn the_services_hand_the_shell_the_apps_worker_pool() {
    let bare = AnalysisServices::new(Box::new(FakeBackend));
    assert!(bare.worker_pool().is_none());
    let pool = Arc::new(sq_runtime::WorkerPool::manual());
    let services = AnalysisServices::new(Box::new(FakeBackend)).with_worker_pool(Arc::clone(&pool));
    assert!(services.worker_pool().is_some_and(|p| Arc::ptr_eq(&p, &pool)));
}

/// The standard (non-Mac) backend runs Stabilize and Find Scene Changes: neither ends in "is not available on this
/// computer yet" (the clip's file does not exist, so the run fails for another reason).
#[test]
fn the_standard_backend_offers_stabilize_and_scene_changes() {
    use sq_editor_session::AnalysisBackend;
    let backend = crate::PortableAnalysisBackend;
    assert!(backend.offers_stabilize());
    let media = MediaRef::new(Id::from_u128(1), "m", "/nonexistent/m.mov", MediaFingerprint::new(1));
    assert!(backend.stabilization_analyzer(&media).is_some());
    let none = |_: f64| {};
    let found =
        backend.scene_changes(Path::new("/nonexistent/m.mov"), TimeRange::new(Time::ZERO, Time::seconds(1)), &none);
    assert!(found.is_err(), "a missing file is an error, not 'unsupported' (Ok(None))");

    let (mut s, _) = session();
    let mut services = AnalysisServices::new(Box::new(crate::PortableAnalysisBackend));
    let (flows, launcher) = services.analysis().expect("analysis");
    flows.request_stabilize(&mut s, launcher);
    pump_until(&mut services, &mut s, |sv| !sv.analysis_flows().is_some_and(AnalysisFlows::is_stabilizing));
    let lines: Vec<String> = events(&mut services)
        .into_iter()
        .filter_map(|e| if let AnalysisFlowsEvent::Flash { message, .. } = e { Some(message) } else { None })
        .collect();
    assert!(!lines.iter().any(|l| l.contains("not available")), "{lines:?}");
}
