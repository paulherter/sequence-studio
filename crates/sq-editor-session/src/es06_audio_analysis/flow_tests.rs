//! Tests of the analysis flows on a session: Auto Reframe, Stabilize, Anonymize, Record Voice-Over and the
//! `AnalysisFlows` message loop (Swift: ReframeSessionTests, StabilizeSessionTests, AnalysisFlowsTests,
//! VoiceRecordingSessionTests).

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::{Arc, Mutex};

use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::reframe::{NormalizedRect, ReframeOptions, SubjectBox, SubjectDetecting, SubjectKind};
use sq_analysis::stabilization_analyzing::{Progress, StabilizationAnalyzing, StabilizationError};
use sq_core_edit::proposed_cuts::TimelineProposedCutsExt;
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_masks::stabilizer::{CameraMotion, StabilizationAnalysis};
use sq_core_model::{
    AnonymizeTarget, Clip, ClipEffect, MagicPoint, MagicSelection, MediaInfo, MediaRef, Project, SequenceFormat,
    Timeline, Track, TrackKind, VideoTrackInfo,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange, Vec2};

use super::tests::{FD, NoDefaults, s, track_of};
use super::*;
use crate::{AnalysisBackend, EditorSession, SessionDeps};

fn video_info(secs: i64) -> MediaInfo {
    MediaInfo {
        duration: s(secs),
        video: Some(VideoTrackInfo {
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
            pixel_aspect: sq_core_model::PixelAspect::square(),
            pixel_aspect_override: None,
            field_order: None,
            deinterlace_off: false,
        }),
        audio: None,
        detected_color_space: None,
        embedded_lut_name: None,
        is_still: false,
        sound_probed: None,
        created: None,
        camera_model: None,
        shoot_probed: None,
    }
}

/// A portrait 1080 x 1920 sequence with landscape 1920 x 1080 clips of `seconds` each, back to back on V1.
struct Fixture {
    sess: EditorSession,
    clips: Vec<Clip>,
    media: Vec<MediaRef>,
}

fn fixture(count: usize, seconds: i64) -> Fixture {
    fixture_shaped(count, seconds, |_| {})
}

fn fixture_shaped(count: usize, seconds: i64, shape: impl Fn(&mut VideoTrackInfo)) -> Fixture {
    let mut ids = SequentialIds::default();
    let (mut media, mut clips, mut track) = (Vec::new(), Vec::new(), Track::new(ids.next_id(), TrackKind::Video));
    for i in 0..count {
        let mut m = MediaRef::new(
            ids.next_id(),
            &format!("m{i}"),
            &format!("/nonexistent/m{i}.mov"),
            sq_core_model::MediaFingerprint::new(1),
        );
        m.duration = Some(s(seconds));
        let mut info = video_info(seconds);
        info.video.as_mut().map(&shape);
        m.info = Some(info);
        let c = Clip::new(
            ids.next_id(),
            &format!("c{i}"),
            m.id,
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(seconds)),
            s(seconds * i as i64),
        );
        track.overwrite(c.clone(), &mut ids).expect("fits");
        media.push(m);
        clips.push(c);
    }
    let mut format = SequenceFormat::new(FD);
    (format.width, format.height) = (1080, 1920);
    let tl = Timeline::new(ids.next_id(), "Vertical", format, vec![track]);
    let project = Project::new(ids.next_id(), "P", media.clone(), vec![tl]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join(format!("sq-es6f-{}", std::process::id())));
    deps.ids = Box::new(ids);
    Fixture { sess: EditorSession::new(project, deps), clips, media }
}

fn select(f: &mut Fixture, which: &[usize]) {
    f.sess.set_selection_raw(which.iter().map(|i| f.clips[*i].id).collect());
}

fn live(sess: &EditorSession, id: Id) -> Clip {
    sess.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip")
}

/// A face that walks from 30 % to 70 % of the width over `duration` seconds; or nothing at all; or an error.
#[derive(Clone, Copy)]
enum Mode {
    Walk(f64),
    Nothing,
    Fail,
    Stall,
}

struct Detector(Mode);

impl SubjectDetecting for Detector {
    type Error = String;
    fn subjects(&self, t: Time) -> Result<Vec<SubjectBox>, String> {
        match self.0 {
            Mode::Nothing => Ok(Vec::new()),
            Mode::Fail => Err("broken".into()),
            Mode::Stall => Err(DETECTOR_STALLED.into()),
            Mode::Walk(d) => {
                let f = (t.value() as f64 / t.timescale() as f64 / d).clamp(0.0, 1.0);
                let x = 0.3 + 0.4 * f;
                Ok(vec![SubjectBox {
                    kind: SubjectKind::Face,
                    rect: NormalizedRect { x: x - 0.05, y: 0.45, width: 0.1, height: 0.1 },
                    confidence: 0.9,
                }])
            }
        }
    }
}

fn detector(mode: Mode) -> impl Fn(&MediaRef) -> Option<BoxedSubjectDetector> {
    move |_| Some(Box::new(Detector(mode)))
}

fn reframe_effect_of(sess: &EditorSession, id: Id) -> Option<ClipEffect> {
    live(sess, id).effects.iter().find(|e| e.kind == ClipEffect::REFRAME_KIND).cloned()
}

#[test]
fn reframe_targets_skip_locked_tracks_and_unknown_pictures() {
    let mut f = fixture(2, 4);
    select(&mut f, &[0, 1]);
    assert_eq!(f.sess.reframe_targets().len(), 2);
    assert!(f.sess.attempt_ids("lock", |t, _| {
        t.tracks[0].is_locked = true;
        Ok(())
    }));
    assert!(f.sess.reframe_targets().is_empty());
}

#[test]
fn auto_reframe_writes_one_stage_in_one_undo_step_and_a_rerun_replaces_it() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let depth = f.sess.undo_step_depth();
    let out = f
        .sess
        .auto_reframe(&ReframeOptions::default(), None, &CancelToken::new(), &detector(Mode::Walk(4.0)))
        .expect("runs");
    assert_eq!((out.reframed, out.no_subject, out.failed), (1, 0, 0));
    assert_eq!(f.sess.undo_step_depth(), depth + 1);
    let first = reframe_effect_of(&f.sess, f.clips[0].id).expect("stage");
    f.sess
        .auto_reframe(&ReframeOptions::default(), None, &CancelToken::new(), &detector(Mode::Walk(4.0)))
        .expect("runs");
    let again = reframe_effect_of(&f.sess, f.clips[0].id).expect("stage");
    assert_eq!(first.id, again.id); // the second run keeps the stage's id
    assert_eq!(live(&f.sess, f.clips[0].id).effects.iter().filter(|e| e.kind == ClipEffect::REFRAME_KIND).count(), 1);
    f.sess.undo();
    f.sess.undo();
    assert!(reframe_effect_of(&f.sess, f.clips[0].id).is_none());
}

#[test]
fn auto_reframe_counts_clips_without_subject_unreadable_and_stalled() {
    let mut f = fixture(3, 4);
    select(&mut f, &[0, 1, 2]);
    let by_media: BTreeMap<Id, Mode> =
        [(f.media[0].id, Mode::Nothing), (f.media[1].id, Mode::Fail), (f.media[2].id, Mode::Stall)].into();
    let pick = move |m: &MediaRef| -> Option<BoxedSubjectDetector> { Some(Box::new(Detector(by_media[&m.id]))) };
    let out = f.sess.auto_reframe(&ReframeOptions::default(), None, &CancelToken::new(), &pick).expect("runs");
    assert_eq!((out.reframed, out.no_subject, out.failed, out.stalled), (0, 1, 1, 1));
    assert!(reframe_effect_of(&f.sess, f.clips[0].id).is_none());
    let none = |_: &MediaRef| -> Option<BoxedSubjectDetector> { None };
    let out = f.sess.auto_reframe(&ReframeOptions::default(), None, &CancelToken::new(), &none).expect("runs");
    assert_eq!(out.failed, 3);
}

#[test]
fn a_canceled_reframe_applies_nothing() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let cancel = CancelToken::new();
    cancel.cancel();
    let depth = f.sess.undo_step_depth();
    assert!(f.sess.auto_reframe(&ReframeOptions::default(), None, &cancel, &detector(Mode::Walk(4.0))).is_err());
    assert_eq!(f.sess.undo_step_depth(), depth);
}

#[test]
fn a_clip_edited_during_the_analysis_is_stale_and_counted_as_failed() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let run = f.sess.reframe_run(&ReframeOptions::default()).expect("run");
    let analysis = run
        .analyze(&detector(Mode::Walk(4.0)), None, &CancelToken::new(), &mut SequentialIds::default())
        .expect("analysis");
    // The user trims the clip while the analysis ran.
    let id = f.clips[0].id;
    assert!(f.sess.attempt_ids("slip", |t, _| {
        let mut c = t.tracks[0].clips()[0].clone();
        c.source = TimeRange::new(s(1), c.source.duration);
        t.tracks[0].replace(c);
        Ok(())
    }));
    let out = f.sess.finish_reframe(&run, analysis);
    assert_eq!((out.reframed, out.failed), (0, 1));
    assert!(reframe_effect_of(&f.sess, id).is_none());
}

#[test]
fn already_framed_clips_are_left_alone() {
    let mut f = fixture(1, 4);
    assert!(f.sess.attempt_ids("square", |t, _| {
        t.format = SequenceFormat { width: 1920, height: 1080, ..t.format.clone() };
        Ok(())
    }));
    select(&mut f, &[0]);
    let out = f
        .sess
        .auto_reframe(&ReframeOptions::default(), None, &CancelToken::new(), &detector(Mode::Walk(4.0)))
        .expect("runs");
    assert_eq!((out.reframed, out.already_framed), (0, 1));
    assert_eq!(AnalysisFlows::reframe_message(&out), "1 clip(s) already fill the frame.");
}

// MARK: Stabilize

/// Shake: alternating 3 px offsets for `secs` seconds at 30 fps.
struct Shaky;

impl StabilizationAnalyzing for Shaky {
    fn analyze(
        &self,
        range: TimeRange,
        w: i64,
        h: i64,
        progress: Progress<'_>,
        cancel: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        cancel.check().map_err(|_| StabilizationError::Cancelled)?;
        let n = (range.duration.value() as f64 / range.duration.timescale() as f64 * 30.0).ceil() as i64;
        let times: Vec<Time> = (0..n).map(|i| range.start + FD * i).collect();
        let motions: Vec<CameraMotion> =
            (0..n).map(|i| CameraMotion::new(if i % 2 == 0 { 3.0 } else { -3.0 }, 0.0, 0.0, 1.0)).collect();
        if let Some(p) = progress {
            p(1.0);
        }
        Ok(StabilizationAnalysis::new(w, h, times, motions))
    }
}

fn shaky() -> impl Fn(&MediaRef) -> Option<BoxedStabilizationAnalyzer> {
    |_| Some(Box::new(Shaky))
}

fn stabilizer_of(sess: &EditorSession, id: Id) -> Option<ClipEffect> {
    live(sess, id).effects.iter().find(|e| e.kind == ClipEffect::STABILIZE_KIND).cloned()
}

#[test]
fn stabilize_writes_a_stabilizer_in_one_undo_step_and_a_rerun_keeps_its_id() {
    let mut f = fixture(1, 3);
    select(&mut f, &[0]);
    let depth = f.sess.undo_step_depth();
    let out = f.sess.stabilize(None, None, None, None, &CancelToken::new(), &shaky()).expect("runs");
    assert_eq!((out.stabilized, out.failed), (1, 0));
    assert_eq!(f.sess.undo_step_depth(), depth + 1);
    let first = stabilizer_of(&f.sess, f.clips[0].id).expect("stabilizer");
    // The user switches it off; a re-run never switches it back on.
    let mut off = live(&f.sess, f.clips[0].id);
    off.effects.iter_mut().for_each(|e| e.enabled = false);
    assert!(f.sess.attempt_ids("off", |t, _| t.replace_clip(off)));
    f.sess.stabilize(None, None, None, None, &CancelToken::new(), &shaky()).expect("runs");
    let again = stabilizer_of(&f.sess, f.clips[0].id).expect("stabilizer");
    assert!(again.id == first.id && !again.enabled);
    assert!(AnalysisFlows::stabilize_message(&out).starts_with("Stabilized 1 clip(s), scaled up"));
}

#[test]
fn stabilize_skips_gyroflow_clips_and_unreadable_media() {
    let mut f = fixture(1, 3);
    select(&mut f, &[0]);
    let none = |_: &MediaRef| -> Option<BoxedStabilizationAnalyzer> { None };
    let out = f.sess.stabilize(None, None, None, None, &CancelToken::new(), &none).expect("runs");
    assert_eq!((out.stabilized, out.failed), (0, 1));
    assert!(f.sess.stale_stabilizer_clips().is_empty());
    assert_eq!(AnalysisFlows::stabilize_message(&StabilizeOutcome::default()), "Nothing to stabilize.");
    assert!(
        f.sess
            .stabilize(
                None,
                None,
                None,
                None,
                &{
                    let c = CancelToken::new();
                    c.cancel();
                    c
                },
                &shaky()
            )
            .is_err()
    );
}

#[test]
fn add_stabilizer_adds_one_idle_stabilizer_without_analysis() {
    let mut f = fixture(1, 3);
    let ids: BTreeSet<Id> = [f.clips[0].id].into();
    let depth = f.sess.undo_step_depth();
    assert!(f.sess.add_stabilizer(&ids));
    assert_eq!(f.sess.undo_step_depth(), depth + 1);
    assert!(stabilizer_of(&f.sess, f.clips[0].id).is_some());
    assert!(f.sess.add_stabilizer(&ids)); // already there: still a valid target, no second step
    assert_eq!(f.sess.undo_step_depth(), depth + 1);
    assert!(!f.sess.add_stabilizer(&BTreeSet::new()));
    // A running analysis has nothing left to write once the Stabilizer is gone.
    assert!(!f.sess.stabilize_run_is_obsolete(&ids, &ids));
    f.sess.undo();
    assert!(f.sess.stabilize_run_is_obsolete(&ids, &ids));
}

#[test]
fn replan_uses_the_cached_analysis_and_asks_for_rolling_shutter_analysis() {
    let mut f = fixture(1, 3);
    select(&mut f, &[0]);
    f.sess.stabilize(None, None, None, None, &CancelToken::new(), &shaky()).expect("runs");
    let id = f.clips[0].id;
    let cached: StabilizationLookup =
        Arc::new(|_, range, w, h| Shaky.analyze(range, w, h, None, &CancelToken::new()).ok());
    let none: StabilizationLookup = Arc::new(|_, _, _, _| None);
    assert!(!f.sess.replan_stabilizer(id, &none)); // not cached: nothing written
    // Changing Smoothness in Effect Controls re-plans from the cache at once.
    let mut e = live(&f.sess, id);
    for fx in e.effects.iter_mut().filter(|x| x.kind == ClipEffect::STABILIZE_KIND) {
        fx.parameters.insert(
            sq_core_masks::stabilizer::Stabilizer::SMOOTHNESS_KEY.into(),
            sq_core_model::AnimatedProperty::new(2.0),
        );
    }
    assert!(f.sess.attempt_ids("smooth", |t, _| t.replace_clip(e.clone())));
    assert!(f.sess.replan_stabilizer(id, &cached));
    // Rolling Shutter over an analysis without row motion: analyze again, queue, never left on without correction.
    e = live(&f.sess, id);
    for fx in e.effects.iter_mut().filter(|x| x.kind == ClipEffect::STABILIZE_KIND) {
        fx.parameters.insert(ClipEffect::ROLLING_SHUTTER_KEY.into(), sq_core_model::AnimatedProperty::new(1.0));
    }
    assert!(f.sess.attempt_ids("rolling", |t, _| t.replace_clip(e.clone())));
    f.sess.take_events();
    assert!(!f.sess.replan_stabilizer(id, &cached));
    assert!(matches!(f.sess.take_events().as_slice(), [crate::SessionEvent::StabilizerNeedsAnalysis { .. }]));
    f.sess.withdraw_rolling_shutter_requests(None);
    let off =
        stabilizer_of(&f.sess, id).and_then(|x| x.parameters.get(ClipEffect::ROLLING_SHUTTER_KEY).map(|p| p.value));
    assert_eq!(off, Some(0.0));
}

#[test]
fn queued_analyses_follow_in_order_and_drop_clips_that_lost_their_stabilizer() {
    let mut f = fixture(2, 3);
    assert!(f.sess.add_stabilizer(&[f.clips[0].id].into()));
    let tid = f.sess.active_timeline_id().expect("timeline");
    f.sess.queue_stabilizer_analysis(&[f.clips[0].id, f.clips[1].id].into(), None);
    assert_eq!(f.sess.take_next_queued_stabilizer_analysis(), Some((tid, [f.clips[0].id].into()))); // clip 1 has none
    assert_eq!(f.sess.take_next_queued_stabilizer_analysis(), None);
    f.sess.queue_stabilizer_analysis(&[f.clips[0].id].into(), None);
    f.sess.drop_queued_stabilizer_analysis();
    assert!(f.sess.take_queued_stabilizer_analysis(None).is_empty());
}

// MARK: Anonymize

fn pick() -> MagicSelection {
    MagicSelection {
        points: vec![MagicPoint { position: Vec2::new(0.5, 0.5), subtract: false, source_time: Time::ZERO }],
        part: None,
    }
}

#[test]
fn anonymize_request_carries_the_media_pixel_aspect_and_deinterlace_order() {
    let mut f = fixture_shaped(1, 4, |v| {
        v.pixel_aspect = sq_core_model::PixelAspect::new(4, 3).expect("aspect");
        v.field_order = Some(sq_core_model::FieldOrder::TopFirst);
    });
    select(&mut f, &[0]);
    let r = f.sess.anonymize_request().expect("request");
    assert_eq!(r.pixel_aspect, sq_core_model::PixelAspect::new(4, 3).expect("aspect"));
    assert_eq!(r.deinterlace, Some(sq_core_model::FieldOrder::TopFirst));
    let mut plain = fixture(1, 4);
    select(&mut plain, &[0]);
    let r = plain.sess.anonymize_request().expect("request");
    assert!(r.pixel_aspect.is_square() && r.deinterlace.is_none());
}

#[test]
fn anonymize_request_captures_the_clip_and_apply_refuses_changed_clips() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    f.sess.playhead = s(1);
    let r = f.sess.anonymize_request().expect("request");
    assert_eq!(
        (r.picture_width, r.picture_height, r.first, r.last, r.anchor),
        (1920, 1080, 0.0, 4.0 - 1.0 / 30.0, 1.0)
    );
    assert!((r.frame_gap - 1.0 / 30.0).abs() < 1e-12);
    let cover = sq_core_masks::anonymize::AnonymizeCover::Mosaic;
    // Retimed during the run: nothing written.
    let mut slipped = live(&f.sess, f.clips[0].id);
    slipped.source = TimeRange::new(s(1), s(3));
    assert!(f.sess.attempt_ids("trim", |t, _| {
        t.tracks[0].replace(slipped);
        Ok(())
    }));
    let depth = f.sess.undo_step_depth();
    let res = f.sess.apply_anonymize(&[pick()], AnonymizeTarget::Face, cover, 200.0, &r);
    assert_eq!(res, AnonymizeApplyResult::ClipRetimed);
    assert_eq!(f.sess.undo_step_depth(), depth);
    f.sess.undo();
    // A run on the unchanged clip writes the masks and the cover as one step; no picks / gone clips write nothing.
    assert_eq!(f.sess.apply_anonymize(&[], AnonymizeTarget::Face, cover, 200.0, &r), AnonymizeApplyResult::ClipGone);
    let depth = f.sess.undo_step_depth();
    assert!(f.sess.apply_anonymize(&[pick()], AnonymizeTarget::Face, cover, 200.0, &r).applied());
    assert_eq!(f.sess.undo_step_depth(), depth + 1);
    assert!(!live(&f.sess, f.clips[0].id).effects.is_empty());
    let mut gone = r.clone();
    gone.clip = Id::NIL;
    assert_eq!(
        f.sess.apply_anonymize(&[pick()], AnonymizeTarget::Face, cover, 200.0, &gone),
        AnonymizeApplyResult::ClipGone
    );
}

#[test]
fn anonymize_check_lines_are_sequence_times_critical_first() {
    use sq_core_masks::anonymize::{AnonymizeCheck, AnonymizeReason};
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let r = f.sess.anonymize_request().expect("request");
    let reasons = [AnonymizeReason::NoFace, AnonymizeReason::Lost];
    let checks: Vec<AnonymizeCheck> = reasons
        .iter()
        .enumerate()
        .map(|(i, reason)| AnonymizeCheck { person: i, reason: *reason, from: 1.0 + i as f64, to: 1.5 + i as f64 })
        .chain([AnonymizeCheck { person: 0, reason: AnonymizeReason::NoFace, from: 90.0, to: 91.0 }])
        .collect();
    let lines = f.sess.anonymize_check_lines(&checks, &r);
    assert_eq!(lines.len(), 2); // the range outside the clip is left out
    assert!(lines[0].critical >= lines[1].critical);
    assert!(lines[0].text.contains("Person") && lines.iter().all(|l| l.text.contains("00:00:0")));
}

// MARK: Record Voice-Over

struct Mic {
    state: VoiceRecorderState,
    start: Result<(), VoiceRecorderError>,
    take: Option<VoiceRecordingTake>,
}

impl VoiceRecorder for Mic {
    fn state(&self) -> VoiceRecorderState {
        self.state
    }
    fn start(&mut self, url: &Path, anchor: Time) -> Result<(), VoiceRecorderError> {
        self.start.clone()?;
        self.state = VoiceRecorderState::Recording;
        self.take = Some(VoiceRecordingTake { url: url.to_path_buf(), duration: s(2), anchor });
        Ok(())
    }
    fn stop(&mut self) -> Result<VoiceRecordingTake, VoiceRecorderError> {
        self.state = VoiceRecorderState::Idle;
        self.take.take().ok_or(VoiceRecorderError::Failed("no take".into()))
    }
    fn cancel(&mut self) {
        self.state = VoiceRecorderState::Idle;
        self.take = None;
    }
}

#[test]
fn record_voice_over_starts_stops_imports_and_places() {
    let mut f = fixture(1, 4);
    let dir = std::env::temp_dir().join(format!("sq-es6-vo-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("dir");
    let mut mic = Mic { state: VoiceRecorderState::Idle, start: Ok(()), take: None };
    let mut import = |_: &Path| -> Option<Id> { Some(Id::from_u128(777)) };
    f.sess.playhead = s(1);
    assert_eq!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Started { play: true });
    assert_eq!(mic.take.as_ref().and_then(|t| t.url.file_name()).and_then(|n| n.to_str()), Some("Voice-Over.wav"));
    let VoiceRecordingStep::Placed(p) = f.sess.toggle_voice_recording(&mut mic, &dir, &mut import) else {
        panic!("placed");
    };
    let c = live(&f.sess, p.clip);
    assert_eq!((c.start, c.name.as_str()), (s(1), "Voice-Over"));
    // A taken name is skipped; the countdown can be canceled by the same command.
    std::fs::write(dir.join("Voice-Over.wav"), b"x").expect("write");
    mic.state = VoiceRecorderState::Countdown;
    assert_eq!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Canceled);
    assert_eq!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Started { play: true });
    assert_eq!(mic.take.as_ref().and_then(|t| t.url.file_name()).and_then(|n| n.to_str()), Some("Voice-Over 2.wav"));
    f.sess.cancel_voice_recording(&mut mic);
    assert_eq!(mic.state(), VoiceRecorderState::Idle);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_shell_can_stop_check_import_and_place_a_take_in_steps() {
    let mut f = fixture(1, 4);
    let mut mic = Mic { state: VoiceRecorderState::Recording, start: Ok(()), take: None };
    assert!(matches!(f.sess.stop_voice_take(&mut mic), Err(VoiceRecordingStep::Failed(m)) if m.contains("failed")));
    let take = VoiceRecordingTake {
        url: std::env::temp_dir().join("sq-es6-step.wav"),
        duration: Time::new(1, 100),
        anchor: s(1),
    };
    assert!(matches!(f.sess.reject_short_take(&take), Some(VoiceRecordingStep::Failed(m)) if m.contains("short")));
    let take = VoiceRecordingTake { duration: s(2), ..take };
    assert_eq!(f.sess.reject_short_take(&take), None);
    let VoiceRecordingStep::Placed(p) = f.sess.place_voice_take(&take, Id::from_u128(5)) else { panic!("placed") };
    assert_eq!((live(&f.sess, p.clip).start, live(&f.sess, p.clip).name.as_str()), (s(1), "sq-es6-step"));
}

#[test]
fn record_voice_over_reports_denied_failed_short_and_unimportable_takes() {
    let mut f = fixture(1, 4);
    let dir = std::env::temp_dir();
    let mut import = |_: &Path| -> Option<Id> { None };
    let mut mic = Mic { state: VoiceRecorderState::Idle, start: Err(VoiceRecorderError::AccessDenied), take: None };
    assert_eq!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Denied);
    mic.start = Err(VoiceRecorderError::Canceled);
    assert_eq!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Canceled);
    mic.start = Err(VoiceRecorderError::Failed("x".into()));
    assert!(
        matches!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Failed(m) if m.contains("microphone"))
    );
    // Recording, but the import fails.
    mic.state = VoiceRecorderState::Recording;
    mic.take = Some(VoiceRecordingTake { url: dir.join("sq-es6-none.wav"), duration: s(2), anchor: Time::ZERO });
    assert!(
        matches!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Failed(m) if m.contains("import"))
    );
    // Too short.
    mic.state = VoiceRecorderState::Recording;
    mic.take =
        Some(VoiceRecordingTake { url: dir.join("sq-es6-none.wav"), duration: Time::new(1, 100), anchor: Time::ZERO });
    assert!(
        matches!(f.sess.toggle_voice_recording(&mut mic, &dir, &mut import), VoiceRecordingStep::Failed(m) if m.contains("too short"))
    );
}

// MARK: AnalysisFlows

/// Runs launched work at once on the calling thread and keeps the posted messages.
struct Inline {
    posted: Arc<Mutex<Vec<AnalysisFlowsMessage>>>,
}

impl AnalysisLauncher for Inline {
    fn poster(&self) -> AnalysisPoster {
        let sink = Arc::clone(&self.posted);
        Arc::new(move |m| sink.lock().expect("lock").push(m))
    }
    fn launch(&mut self, work: AnalysisWork) {
        work(&mut SequentialIds::default());
    }
}

/// Holds launched work back until the test runs it (a hanging analysis).
#[derive(Default)]
struct Held {
    posted: Arc<Mutex<Vec<AnalysisFlowsMessage>>>,
    work: Vec<AnalysisWork>,
}

impl AnalysisLauncher for Held {
    fn poster(&self) -> AnalysisPoster {
        let sink = Arc::clone(&self.posted);
        Arc::new(move |m| sink.lock().expect("lock").push(m))
    }
    fn launch(&mut self, work: AnalysisWork) {
        self.work.push(work);
    }
}

struct Backend {
    mode: Mode,
    scenes: bool,
}

impl AnalysisBackend for Backend {
    fn scene_changes(
        &self,
        _: &Path,
        range: TimeRange,
        progress: &(dyn Fn(f64) + Send + Sync),
    ) -> Result<Option<Vec<Time>>, String> {
        progress(0.5);
        Ok(self.scenes.then(|| vec![range.start + s(1), range.start + s(2)]))
    }
    fn offers_reframe(&self) -> bool {
        true
    }
    fn offers_stabilize(&self) -> bool {
        true
    }
    fn subject_detector(&self, _: &MediaRef) -> Option<Box<dyn SubjectDetecting<Error = String> + Send>> {
        Some(Box::new(Detector(self.mode)))
    }
    fn stabilization_analyzer(&self, _: &MediaRef) -> Option<Box<dyn StabilizationAnalyzing + Send>> {
        Some(Box::new(Shaky))
    }
}

fn flows(mode: Mode, scenes: bool) -> AnalysisFlows {
    AnalysisFlows::new(Some(Box::new(Backend { mode, scenes })))
}

fn drain(fl: &mut AnalysisFlows, sess: &mut EditorSession, l: &mut Inline) {
    let msgs: Vec<_> = std::mem::take(&mut *l.posted.lock().expect("lock"));
    for m in msgs {
        fl.handle_message(sess, l, m);
    }
}

fn flashes(fl: &mut AnalysisFlows) -> Vec<String> {
    fl.take_events()
        .into_iter()
        .filter_map(|e| if let AnalysisFlowsEvent::Flash { message, .. } = e { Some(message) } else { None })
        .collect()
}

#[test]
fn nothing_selected_or_no_backend_says_so() {
    let mut f = fixture(1, 3);
    let mut l = Inline { posted: Arc::default() };
    let mut fl = flows(Mode::Nothing, true);
    f.sess.playhead = s(30); // no selection and nothing under the playhead
    fl.request_find_scene_changes(&mut f.sess, &mut l);
    assert_eq!(flashes(&mut fl), vec!["Select a video clip to look through.".to_string()]);
    assert_eq!(fl.reframe_subject(&mut f.sess), None);
    select(&mut f, &[0]);
    let mut bare = AnalysisFlows::new(None);
    bare.request_find_scene_changes(&mut f.sess, &mut l);
    bare.request_stabilize(&mut f.sess, &mut l);
    assert_eq!(
        flashes(&mut bare),
        vec![AnalysisFlows::unavailable("Find Scene Changes"), AnalysisFlows::unavailable("Stabilize")]
    );
    assert_eq!(bare.reframe_subject(&mut f.sess), None);
    assert_eq!(flashes(&mut bare), vec![AnalysisFlows::unavailable("Auto Reframe")]);
    assert!(
        !bare.is_finding_scene_changes() && !bare.is_reframing() && !bare.is_stabilizing() && !bare.is_matching_color()
    );
}

#[test]
fn find_scene_changes_proposes_cuts_and_reports_the_count() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let (mut l, mut fl) = (Inline { posted: Arc::default() }, flows(Mode::Nothing, true));
    fl.request_find_scene_changes(&mut f.sess, &mut l);
    assert!(fl.is_finding_scene_changes());
    assert!(
        matches!(fl.take_events().first(), Some(AnalysisFlowsEvent::SetJob(Some(t))) if t == "Find Scene Changes: reading \u{201C}c0\u{201D}\u{2026}")
    );
    drain(&mut fl, &mut f.sess, &mut l);
    assert!(!fl.is_finding_scene_changes());
    assert_eq!(f.sess.active_timeline().expect("tl").proposed_cuts().len(), 2);
    let ev = fl.take_events();
    assert!(ev.iter().any(|e| matches!(e, AnalysisFlowsEvent::SetJob(None))));
    assert!(ev.iter().any(
        |e| matches!(e, AnalysisFlowsEvent::Flash { message, .. } if message.starts_with("2 scene changes marked."))
    ));
}

#[test]
fn a_backend_without_a_scene_detector_reads_as_unavailable() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let (mut l, mut fl) = (Inline { posted: Arc::default() }, flows(Mode::Nothing, false));
    fl.request_find_scene_changes(&mut f.sess, &mut l);
    drain(&mut fl, &mut f.sess, &mut l);
    assert_eq!(
        flashes(&mut fl).last().map(String::as_str),
        Some("Find Scene Changes is not available on this computer yet.")
    );
}

#[test]
fn the_second_request_cancels_a_running_job_and_its_late_result_is_ignored() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let mut held = Held::default();
    let mut fl = flows(Mode::Walk(4.0), true);
    fl.run_auto_reframe(&mut f.sess, &mut held, ReframeOptions::default(), "c0");
    assert!(fl.is_reframing() && held.work.len() == 1);
    fl.take_events();
    assert_eq!(fl.reframe_subject(&mut f.sess), None); // cancels
    assert!(!fl.is_reframing());
    assert_eq!(flashes(&mut fl), vec!["Auto Reframe canceled.".to_string()]);
    // The hung work finishes later: its answer changes nothing.
    held.work.remove(0)(&mut SequentialIds::default());
    let mut inline = Inline { posted: Arc::clone(&held.posted) };
    drain(&mut fl, &mut f.sess, &mut inline);
    assert!(reframe_effect_of(&f.sess, f.clips[0].id).is_none() && flashes(&mut fl).is_empty());
}

#[test]
fn auto_reframe_runs_through_the_message_loop() {
    let mut f = fixture(1, 4);
    select(&mut f, &[0]);
    let (mut l, mut fl) = (Inline { posted: Arc::default() }, flows(Mode::Walk(4.0), true));
    let what = fl.reframe_subject(&mut f.sess).expect("subject");
    assert_eq!(what, "\u{201C}c0\u{201D}");
    fl.run_auto_reframe(&mut f.sess, &mut l, ReframeOptions::default(), &what);
    drain(&mut fl, &mut f.sess, &mut l);
    assert!(reframe_effect_of(&f.sess, f.clips[0].id).is_some());
    assert!(flashes(&mut fl).iter().any(|m| m.starts_with("Reframed 1 clip(s)")));
}

#[test]
fn stabilize_runs_through_the_message_loop_and_rows_report_progress_and_queue() {
    let mut f = fixture(2, 3);
    select(&mut f, &[0]);
    let (mut l, mut fl) = (Inline { posted: Arc::default() }, flows(Mode::Nothing, true));
    fl.request_stabilize(&mut f.sess, &mut l);
    drain(&mut fl, &mut f.sess, &mut l);
    assert!(stabilizer_of(&f.sess, f.clips[0].id).is_some() && !fl.is_stabilizing());
    assert!(flashes(&mut fl).iter().any(|m| m.starts_with("Stabilized 1 clip(s)")));
    // An Analyze row: progress shows on its clips, a second request waits in the queue and follows.
    let first: BTreeSet<Id> = [f.clips[0].id].into();
    let second: BTreeSet<Id> = [f.clips[1].id].into();
    assert!(f.sess.add_stabilizer(&second));
    let mut held = Held::default();
    fl.analyze_stabilizers(&mut f.sess, &mut held, &first, None);
    assert!(matches!(fl.take_events().as_slice(), [
        AnalysisFlowsEvent::SetJob(Some(_)),
        AnalysisFlowsEvent::StabilizeProgress { progress: Some(p), .. },
    ] if *p == 0.0));
    fl.analyze_stabilizers(&mut f.sess, &mut held, &second, None); // queued behind the running one
    assert_eq!(held.work.len(), 1);
    held.work.remove(0)(&mut SequentialIds::default());
    let msgs: Vec<_> = std::mem::take(&mut *held.posted.lock().expect("lock"));
    for m in msgs {
        // The queued clip is started by the end of the first run (into a new Held launcher we do not run here).
        fl.handle_message(&mut f.sess, &mut held, m);
    }
    let ev = fl.take_events();
    assert!(ev.iter().any(|e| matches!(e, AnalysisFlowsEvent::StabilizeProgress { progress: None, .. })));
    assert_eq!(held.work.len(), 1); // the second analysis was launched
    assert!(fl.is_stabilizing());
    fl.cancel_stabilizer_run(&mut f.sess, &mut held);
    assert!(!fl.is_stabilizing());
    assert!(f.sess.take_queued_stabilizer_analysis(None).is_empty());
}

#[test]
fn reframe_sheet_picks_are_remembered_and_clamped() {
    use sq_library::library_folder_store::MemorySettings;
    let mut d = MemorySettings::default();
    assert_eq!(AnalysisFlows::remembered_reframe_pick(&d), (1, 0));
    let o = AnalysisFlows::reframe_options(9, -3, &mut d);
    assert_eq!(AnalysisFlows::remembered_reframe_pick(&d), (2, 0));
    assert!(o.smoothing_window > 0.0);
    assert_eq!(AnalysisFlows::reframe_motion_titles().len(), 3);
    assert_eq!(AnalysisFlows::reframe_framing_titles().len(), 3);
    let _ = NoDefaults;
    let _ = track_of;
}

// MARK: Match Color to Clip

struct FakeSampler(Arc<Mutex<Vec<String>>>);

impl crate::ProgramFrameSampling for FakeSampler {
    fn sample_linear(&mut self, width: i64, key: &str) {
        self.0.lock().expect("log").push(format!("linear {width} {key}"));
    }
    fn sample_patch(&mut self, position: [f64; 2], radius: i64, key: &str) {
        self.0.lock().expect("log").push(format!("patch {position:?} {radius} {key}"));
    }
}

fn gray(v: f32) -> Option<Vec<[f32; 3]>> {
    Some((0..400).map(|i| [v * (0.9 + 0.2 * (i % 20) as f32 / 20.0); 3]).collect())
}

fn match_fixture() -> (Fixture, AnalysisFlows, Arc<Mutex<Vec<String>>>) {
    let mut f = fixture(2, 4);
    select(&mut f, &[1]);
    f.sess.playhead = s(5);
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut flows = AnalysisFlows::new(None);
    flows.frame_sampler = Some(Box::new(FakeSampler(Arc::clone(&log))));
    (f, flows, log)
}

fn last_flash(flows: &mut AnalysisFlows) -> String {
    flows
        .take_events()
        .into_iter()
        .filter_map(|e| if let AnalysisFlowsEvent::Flash { message, .. } = e { Some(message) } else { None })
        .next_back()
        .unwrap_or_default()
}

#[test]
fn match_color_takes_two_captures_per_clip_then_applies() {
    let (mut f, mut flows, log) = match_fixture();
    let run = flows.request_color_match_to_clip(&mut f.sess).expect("started");
    assert!(flows.is_matching_color());
    for samples in [gray(0.3), gray(0.3), gray(0.1)] {
        flows.handle_color_samples(&mut f.sess, samples);
        assert!(flows.is_matching_color());
    }
    flows.handle_color_samples(&mut f.sess, gray(0.1));
    assert!(!flows.is_matching_color());
    assert_eq!(log.lock().expect("log").len(), 4);
    assert!(log.lock().expect("log").iter().all(|l| l == "linear 96 color.match.clip"));
    assert!(last_flash(&mut flows).starts_with("Matched"));
    // A late timeout of the finished run does nothing.
    flows.expire_color_match(&mut f.sess, run);
    assert!(flows.take_events().is_empty());
}

#[test]
fn match_color_changes_the_target_grade_in_one_undo_step() {
    let (mut f, mut flows, _) = match_fixture();
    let before = f.sess.single_selected_clip().expect("target").clone();
    flows.request_color_match_to_clip(&mut f.sess).expect("started");
    for samples in [gray(0.3), gray(0.3), gray(0.1), gray(0.1)] {
        flows.handle_color_samples(&mut f.sess, samples);
    }
    let after = f.sess.single_selected_clip().expect("target").clone();
    assert!(after.effects != before.effects, "the grade moved toward the reference");
    f.sess.undo();
    assert!(f.sess.single_selected_clip().expect("target").effects == before.effects);
}

#[test]
fn match_color_without_a_picture_or_after_the_timeout_says_it_could_not_read() {
    let (mut f, mut flows, _) = match_fixture();
    flows.request_color_match_to_clip(&mut f.sess).expect("started");
    flows.handle_color_samples(&mut f.sess, None);
    assert!(!flows.is_matching_color());
    assert!(last_flash(&mut flows).starts_with("Could not read"));
    let run = flows.request_color_match_to_clip(&mut f.sess).expect("started");
    flows.expire_color_match(&mut f.sess, run);
    assert!(!flows.is_matching_color());
    assert!(last_flash(&mut flows).starts_with("Could not read"));
    // The answer of the expired run is dropped.
    flows.handle_color_samples(&mut f.sess, gray(0.2));
    assert!(!flows.is_matching_color());
}

#[test]
fn match_color_is_blocked_without_a_sampler_or_a_target() {
    let (mut f, mut flows, _) = match_fixture();
    flows.frame_sampler = None;
    assert!(flows.request_color_match_to_clip(&mut f.sess).is_none());
    assert_eq!(last_flash(&mut flows), AnalysisFlows::unavailable("Match Color to Clip"));
    f.sess.set_selection_raw(Default::default());
    f.sess.playhead = s(100);
    flows.frame_sampler = Some(Box::new(FakeSampler(Default::default())));
    assert!(flows.request_color_match_to_clip(&mut f.sess).is_none());
    assert!(last_flash(&mut flows).starts_with("Select a video clip") || !flows.is_matching_color());
}

#[test]
fn sample_color_asks_the_sampler_for_a_patch() {
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut sampler = FakeSampler(Arc::clone(&log));
    super::frame_sampler::FrameSampler::sample_color(&mut sampler, [0.25, 0.5], 2);
    assert_eq!(log.lock().expect("log")[0], "patch [0.25, 0.5] 2 color.pick");
}
