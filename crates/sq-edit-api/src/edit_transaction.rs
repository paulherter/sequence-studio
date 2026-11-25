// Swift: EditTransaction.swift
//! An agent commit: a batch of operations applied all-or-nothing to one sequence.

use crate::edit_diff::EditDiff;
use crate::edit_operation::EditOperation;
use crate::param_ops::{self, OpFailure};
use crate::time_limits::TimeLimits;
use sq_core_edit::timeline_add_track::AddTrackExt;
use sq_core_edit::timeline_edits::{SlipKeyframes, TimelineEditsExt};
use sq_core_edit::timeline_clipboard::TimelineClipboardExt;
use sq_core_edit::timeline_enable::TimelineEnableExt;
use sq_core_edit::timeline_solo::SoloExt;
use sq_core_edit::timeline_markers::TimelineMarkersExt;
use sq_core_edit::timeline_range_edits::TimelineRangeEditsExt;
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_edit::timeline_three_point::TimelineThreePointExt;
use sq_core_model::{EditError, Project, Timeline};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};

/// Why a batch was refused. Nothing was applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransactionErrorKind {
    /// The model refused an edit.
    Edit(EditError),
    /// A media operation names an item the project does not have.
    MediaNotFound,
    /// A pixel aspect operation names media without a probed picture (audio, unprobed).
    NoPicture,
    /// An operation carries a time outside `TimeLimits`.
    InvalidTime,
    /// A track operation names a track the sequence does not have.
    TrackNotFound,
    /// A value the operation carries is out of range (size, frame rate, sample rate); the text says which.
    InvalidValue(&'static str),
    /// A session operation (`addClip`, `createSequence`, `setActiveSequence`) reached the plain transaction: only the app
    /// session runs those.
    NeedsSession,
    /// A timeline gesture is in progress; try again.
    Busy,
    /// The request does not fit the clip (unknown parameter, value out of range, ...); `detail` says what.
    Invalid,
    /// The sequence the agent read is no longer the active one.
    SequenceChanged,
    /// The request timed out or its connection went away before the commit.
    Cancelled,
}

/// A refused batch with the operation that failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransactionError {
    /// What went wrong.
    pub kind: TransactionErrorKind,
    /// The first operation that failed; None when the failure is not tied to one (e.g. the nesting check at the end).
    pub operation_index: Option<usize>,
    /// Wire name of that operation.
    pub operation: Option<String>,
    /// Why, for `Invalid`.
    pub detail: Option<String>,
}

impl TransactionError {
    /// An error not tied to an operation.
    pub fn new(kind: TransactionErrorKind) -> TransactionError {
        TransactionError { kind, operation_index: None, operation: None, detail: None }
    }

    /// A refusal with a reason, tied to no operation.
    pub fn invalid(why: &str) -> TransactionError {
        TransactionError { kind: TransactionErrorKind::Invalid, operation_index: None, operation: None, detail: Some(why.to_string()) }
    }

    fn at(kind: TransactionErrorKind, index: usize, operation: &str) -> TransactionError {
        TransactionError { kind, operation_index: Some(index), operation: Some(operation.to_string()), detail: None }
    }

    /// The model's error, when the model refused an edit.
    pub fn underlying(&self) -> Option<EditError> {
        match self.kind {
            TransactionErrorKind::Edit(e) => Some(e),
            _ => None,
        }
    }

    /// Text for the agent.
    pub fn message(&self) -> String {
        let at = self.operation_index.map_or(String::new(), |i| {
            format!("operation {i}{}: ", self.operation.as_ref().map_or(String::new(), |o| format!(" ({o})")))
        });
        let what = match self.kind {
            // Swift prints the case name (`clipNotFound`); Debug gives `ClipNotFound`.
            TransactionErrorKind::Edit(e) => {
                let name = format!("{e:?}");
                let mut chars = name.chars();
                chars.next().map_or(name.clone(), |c| c.to_lowercase().chain(chars).collect())
            }
            TransactionErrorKind::MediaNotFound => "media not found".to_string(),
            TransactionErrorKind::NoPicture => {
                "the media has no probed picture, its pixel aspect cannot be set".to_string()
            }
            TransactionErrorKind::InvalidTime => TimeLimits::message(),
            TransactionErrorKind::TrackNotFound => "track not found".to_string(),
            TransactionErrorKind::InvalidValue(what) => (*what).to_string(),
            TransactionErrorKind::NeedsSession => "this operation needs the app session".to_string(),
            TransactionErrorKind::Invalid => self.detail.clone().unwrap_or_else(|| "invalid request".to_string()),
            TransactionErrorKind::Busy => "a timeline edit is in progress, try again".to_string(),
            TransactionErrorKind::SequenceChanged => "the active sequence changed since it was read".to_string(),
            TransactionErrorKind::Cancelled => "request canceled".to_string(),
        };
        at + &what
    }
}

impl fmt::Display for TransactionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for TransactionError {}

/// An agent commit: a batch of operations applied all-or-nothing to one sequence. All times are validated first; then the
/// batch runs on a copy through `Project::edit` (nesting-cycle check, transition pruning) like every timeline edit; a
/// failure returns an error and leaves the project untouched. Wrap the call in one `History` commit for ONE undo step.
pub struct EditTransaction;

impl EditTransaction {
    /// Checks every time of every operation against `TimeLimits`.
    pub fn validate(ops: &[EditOperation]) -> Result<(), TransactionError> {
        for (i, op) in ops.iter().enumerate() {
            if !op.times().into_iter().all(TimeLimits::is_valid_time) {
                return Err(TransactionError::at(TransactionErrorKind::InvalidTime, i, op.name()));
            }
        }
        Ok(())
    }

    /// Applies `ops` to `sequence` all-or-nothing; new clips and links take their ids from `ids`.
    pub fn apply(
        ops: &[EditOperation],
        project: &mut Project,
        sequence: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(), TransactionError> {
        Self::validate(ops)?;
        if project.timeline(sequence).is_none() {
            return Err(TransactionError::new(TransactionErrorKind::Edit(EditError::TimelineNotFound)));
        }
        // Media settings first, on a copy: they do not touch the timeline, and a refusal leaves the project untouched.
        let mut work = project.clone();
        for (i, op) in ops.iter().enumerate() {
            let EditOperation::SetPixelAspect { media, aspect } = op else { continue };
            let Some(item) = work.media(*media) else {
                return Err(TransactionError::at(TransactionErrorKind::MediaNotFound, i, op.name()));
            };
            if item.info.as_ref().and_then(|info| info.video.as_ref()).is_none() {
                return Err(TransactionError::at(TransactionErrorKind::NoPicture, i, op.name()));
            }
            work.set_pixel_aspect(*aspect, *media);
        }
        // Sequence settings: a project-level edit like the Sequence Settings dialog (`Project::set_settings`).
        for (i, op) in ops.iter().enumerate() {
            let EditOperation::SetSequenceSettings { sequence: own, width, height, fps, sample_rate } = op else {
                continue;
            };
            let target = own.unwrap_or(sequence);
            let Some(t) = work.timeline(target) else {
                return Err(TransactionError::at(TransactionErrorKind::Edit(EditError::TimelineNotFound), i, op.name()));
            };
            let mut settings = t.settings();
            let f = &mut settings.format;
            f.width = width.unwrap_or(f.width);
            f.height = height.unwrap_or(f.height);
            if let Some(fps) = fps {
                f.frame_duration = fps.frame_duration();
            }
            f.audio_sample_rate = sample_rate.unwrap_or(f.audio_sample_rate);
            if !f.is_valid() {
                return Err(TransactionError::at(
                    TransactionErrorKind::InvalidValue(
                        "invalid sequence settings: size 1...16384, a positive frame rate and sample rate",
                    ),
                    i,
                    op.name(),
                ));
            }
            work.set_settings(&settings, target)
                .map_err(|e| TransactionError::at(TransactionErrorKind::Edit(e), i, op.name()))?;
        }
        if let Some(i) = ops.iter().position(EditOperation::is_session_operation) {
            return Err(TransactionError::at(TransactionErrorKind::NeedsSession, i, ops[i].name()));
        }
        for (i, op) in ops.iter().enumerate() {
            if let EditOperation::SetTrackState { track, .. } = op
                && work.timeline(sequence).is_some_and(|t| t.track(*track).is_none())
            {
                return Err(TransactionError::at(TransactionErrorKind::TrackNotFound, i, op.name()));
            }
        }
        let mut index: Option<usize> = None;
        let mut detail: Option<String> = None;
        let result = work.edit(sequence, |t| {
            for (i, op) in ops.iter().enumerate() {
                index = Some(i);
                match Self::apply_op(op, t, ids) {
                    Ok(()) => {}
                    Err(OpFailure::Edit(e)) => return Err(e),
                    Err(OpFailure::Invalid(why)) => {
                        detail = Some(why);
                        return Err(EditError::InvalidFormat);
                    }
                }
            }
            index = None; // errors after the loop (nesting check) belong to no single operation
            // As EditorSession.performTimeline does after every edit.
            t.normalize_audio_key_marks();
            Ok(())
        });
        if let Err(e) = result {
            let kind = if detail.is_some() { TransactionErrorKind::Invalid } else { TransactionErrorKind::Edit(e) };
            let mut err = match index {
                Some(i) => TransactionError::at(kind, i, ops[i].name()),
                None => TransactionError::new(kind),
            };
            err.detail = detail;
            return Err(err);
        }
        *project = work;
        Ok(())
    }

    /// `apply` on a copy, on a worker thread that the caller waits for (PALMIER-ISSUES #107: a read-only dry run must not
    /// hold the caller's UI thread). `cancel` is checked after the run, as Swift checks `Task.isCancelled`.
    pub fn apply_off_actor(
        ops: &[EditOperation],
        project: &Project,
        sequence: Id,
        ids: &mut (dyn IdSource + Send),
        cancel: &AtomicBool,
    ) -> Result<Project, TransactionError> {
        let joined = std::thread::scope(|s| {
            s.spawn(|| {
                let mut p = project.clone();
                Self::apply(ops, &mut p, sequence, ids).map(|()| p)
            })
            .join()
        });
        let result = joined.unwrap_or_else(|panic| std::panic::resume_unwind(panic))?;
        if cancel.load(Ordering::SeqCst) {
            return Err(TransactionError::new(TransactionErrorKind::Cancelled));
        }
        Ok(result)
    }

    /// The would-be result and its diff; `project` is not changed.
    pub fn preview(
        ops: &[EditOperation],
        project: &Project,
        sequence: Id,
        ids: &mut dyn IdSource,
    ) -> Result<(Project, EditDiff), TransactionError> {
        let mut p = project.clone();
        Self::apply(ops, &mut p, sequence, ids)?;
        let not_found = || TransactionError::new(TransactionErrorKind::Edit(EditError::TimelineNotFound));
        let diff = EditDiff::new(
            project.timeline(sequence).ok_or_else(not_found)?,
            p.timeline(sequence).ok_or_else(not_found)?,
        );
        Ok((p, diff))
    }

    /// Runs `body`; with `linked` false only `clip` changes and its linked partners stay (the UI's Alt-trim, `editing_only`).
    fn solo(
        t: &mut Timeline,
        clip: Id,
        linked: bool,
        ids: &mut dyn IdSource,
        body: impl FnOnce(&mut Timeline) -> Result<(), EditError>,
    ) -> Result<(), EditError> {
        if linked {
            return body(t);
        }
        t.editing_only(&BTreeSet::from([clip]), ids, |t, _| body(t))
    }

    fn apply_op(op: &EditOperation, t: &mut Timeline, ids: &mut dyn IdSource) -> Result<(), OpFailure> {
        let unlocked =
            |t: &Timeline| -> Vec<Id> { t.tracks.iter().filter(|tr| !tr.is_locked).map(|tr| tr.id).collect() };
        match op {
            EditOperation::Razor { at, tracks } => {
                t.add_edit(*at, tracks.as_deref(), ids)?;
            }
            EditOperation::RippleDelete { clips } => {
                t.ripple_delete(clips)?;
            }
            EditOperation::Lift { clips } => t.lift_clips(clips)?,
            EditOperation::Extract { range, tracks } => {
                let tracks = tracks.clone().unwrap_or_else(|| unlocked(t));
                t.extract(*range, &tracks, ids)?;
            }
            EditOperation::LiftRange { range, tracks } => {
                let tracks = tracks.clone().unwrap_or_else(|| unlocked(t));
                t.lift(*range, &tracks, ids)?;
            }
            EditOperation::Trim { clip, edge, by, linked } => {
                let mut moved = Time::ZERO;
                Self::solo(t, *clip, *linked, ids, |t| {
                    moved = t.trim(*clip, *edge, *by)?;
                    Ok(())
                })?;
                if moved == Time::ZERO && *by != Time::ZERO {
                    return Err(OpFailure::Invalid(
                        "trim moved nothing: the media, the neighbor clip or the clip's own length stops the edge there".into(),
                    ));
                }
            }
            EditOperation::RippleTrim { clip, edge, by, linked } => {
                let (mut moved, mut limited_by) = (Time::ZERO, None);
                Self::solo(t, *clip, *linked, ids, |t| {
                    let (m, l, _) = t.ripple_trim_many(&[(*clip, *by)], *edge)?;
                    (moved, limited_by) = (m, l);
                    Ok(())
                })?;
                if moved == Time::ZERO && *by != Time::ZERO {
                    let why = match limited_by {
                        Some(i) => format!(
                            "a clip on track {} right behind the edit leaves no room to close the gap (move or remove it first)",
                            i + 1
                        ),
                        None => "the media, a caption inside the closed span or the clip's own length stops the edge there".into(),
                    };
                    return Err(OpFailure::Invalid(format!("rippleTrim moved nothing: {why}")));
                }
            }
            EditOperation::Link { clips } => t.link(&clips.iter().copied().collect::<BTreeSet<Id>>(), ids)?,
            EditOperation::Unlink { clips } => t.unlink(&clips.iter().copied().collect::<BTreeSet<Id>>())?,
            EditOperation::Move { clip, to, track } => {
                t.move_clip(*clip, *to, *track, &BTreeMap::new(), None, ids)?;
            }
            EditOperation::Slip { clip, by } => {
                t.slip(*clip, *by, SlipKeyframes::FollowContent)?;
            }
            EditOperation::Slide { clip, by } => {
                t.slide(*clip, *by)?;
            }
            EditOperation::Roll { clip, by } => {
                t.roll(*clip, *by)?;
            }
            EditOperation::ToggleEnabled { clips } => {
                t.toggle_enabled(&clips.iter().copied().collect::<BTreeSet<Id>>())?;
            }
            EditOperation::AddMarker { at, name } => {
                t.add_marker(*at, name, ids);
            }
            // Media and sequence settings: applied by `apply` before the timeline edits.
            EditOperation::SetPixelAspect { .. } | EditOperation::SetSequenceSettings { .. } => {}
            EditOperation::RemoveClip { clips, ripple } => {
                if *ripple {
                    t.ripple_delete(clips)?;
                } else {
                    t.lift_clips(clips)?;
                }
            }
            EditOperation::AddTrack { kind } => {
                t.insert_track_after_last(*kind, ids);
            }
            EditOperation::SetClipSpeed { clip, speed } => {
                t.set_speed(*clip, *speed, None, None, false, false)?;
            }
            EditOperation::SetTrackState { track, mute, solo, lock, visible } => {
                let tr = t.tracks.iter_mut().find(|tr| tr.id == *track).ok_or(EditError::ClipNotFound)?;
                tr.is_muted = mute.unwrap_or(tr.is_muted);
                tr.is_solo = solo.unwrap_or(tr.is_solo);
                tr.is_locked = lock.unwrap_or(tr.is_locked);
                tr.is_visible = visible.unwrap_or(tr.is_visible);
            }
            // The session runs these; `apply` refused them before this point.
            EditOperation::AddClip { .. }
            | EditOperation::CreateSequence { .. }
            | EditOperation::SetActiveSequence { .. }
            | EditOperation::SyncAudio { .. } => return Err(EditError::NotConvertible.into()),
            EditOperation::SetParam { clip, param, value } => param_ops::set_param(t, *clip, param, value)?,
            EditOperation::AddEffect { clip, effect, index } => param_ops::add_effect(t, *clip, effect, *index, ids)?,
            EditOperation::RemoveEffect { clip, effect } => param_ops::remove_effect(t, *clip, *effect)?,
            EditOperation::AddTransition { place, kind, duration, alignment } => {
                crate::transition_ops::add_transition(t, *place, kind, *duration, alignment, ids)?;
            }
            EditOperation::RemoveTransition { transition } => crate::transition_ops::remove_transition(t, *transition)?,
            EditOperation::ApplyPreset { clip, preset, at, mode } => {
                crate::transition_ops::apply_preset(t, *clip, preset, *at, mode.as_deref(), ids)?;
            }
            EditOperation::ApplyUserPreset { clip, name, preset, at, mode } => {
                crate::transition_ops::apply_user_preset(t, *clip, name, preset, *at, mode.as_deref(), ids)?;
            }
            EditOperation::SetKeyframe { clip, param, at, value, interpolation, ease, in_handle, out_handle } => {
                let shape = crate::clip_params::KeyShape::parse(
                    interpolation.as_deref(),
                    ease.as_deref(),
                    in_handle.as_ref(),
                    out_handle.as_ref(),
                )?;
                param_ops::set_keyframe(t, *clip, param, *at, value, &shape, ids)?;
            }
            EditOperation::RemoveKeyframe { clip, param, at } => param_ops::remove_keyframe(t, *clip, param, *at)?,
            EditOperation::MoveKeyframe { clip, param, from, to } => param_ops::move_keyframe(t, *clip, param, *from, *to)?,
            EditOperation::ShiftKeyframes { clip, param, by, after } => {
                param_ops::shift_keyframes(t, *clip, param.as_deref(), *by, *after)?;
            }
            EditOperation::AddGraphic { track, at, duration, name, layers } => {
                param_ops::add_graphic(t, *track, *at, *duration, name.as_deref(), layers, ids)?;
            }
            EditOperation::SetTextLayer { clip, layer, fields } => param_ops::set_text_layer(t, *clip, *layer, fields)?,
            EditOperation::AddTextLayer { clip, index, fields } => {
                param_ops::add_text_layer(t, *clip, fields, *index, ids)?;
            }
            EditOperation::RemoveTextLayer { clip, layer } => param_ops::remove_text_layer(t, *clip, *layer)?,
            EditOperation::AddTextAnimator { clip, layer, fields } => {
                param_ops::text_animator(t, *clip, *layer, |l| crate::text_animators::apply(l, fields, true))?;
            }
            EditOperation::SetTextAnimator { clip, layer, fields } => {
                param_ops::text_animator(t, *clip, *layer, |l| crate::text_animators::apply(l, fields, false))?;
            }
            EditOperation::SetTextAccent { clip, layer, fields } => {
                param_ops::text_animator(t, *clip, *layer, |l| match fields {
                    serde_json::Value::Object(m) => crate::text_accent::apply(l, m),
                    _ => Err("setTextAccent: fields must be an object".into()),
                })?;
            }
            EditOperation::AddMask { clip, fields } => param_ops::add_mask(t, *clip, fields, ids)?,
            EditOperation::RemoveTextAnimator { clip, layer, side } => {
                let side = side.as_deref().map(serde_json::Value::from);
                param_ops::text_animator(t, *clip, *layer, |l| crate::text_animators::remove(l, side.as_ref()))?;
            }
        }
        Ok(())
    }
}

/// One request to the host: what to apply, where, and whether only to preview it.
#[derive(Clone, Debug)]
pub struct HostCommit {
    /// Undo name.
    pub name: String,
    /// The sequence the agent read.
    pub sequence: Id,
    /// The batch.
    pub operations: Vec<EditOperation>,
    /// Only preview the result.
    pub dry_run: bool,
}

impl HostCommit {
    /// `sequence` of a commit sent without one: allowed only while no sequence is open (the first `createSequence`).
    pub const NO_SEQUENCE: Id = Id::from_u128(0);

    /// The checks every host runs on its own thread right before applying: not canceled (timed-out connection), no
    /// gesture in progress, and the sequence the agent read is still the active one.
    pub fn admit(&self, active: Option<Id>, busy: bool, cancel: &AtomicBool) -> Result<(), TransactionError> {
        if cancel.load(Ordering::SeqCst) {
            return Err(TransactionError::new(TransactionErrorKind::Cancelled));
        }
        if busy {
            return Err(TransactionError::new(TransactionErrorKind::Busy));
        }
        let first_sequence = self.sequence == Self::NO_SEQUENCE && active.is_none();
        if active != Some(self.sequence) && !first_sequence {
            return Err(TransactionError::new(TransactionErrorKind::SequenceChanged));
        }
        Ok(())
    }
}

/// Fixtures shared by the tests of this crate.
#[cfg(test)]
pub(crate) mod fixture {
    use super::*;
    use sq_core_model::{Clip, MediaFingerprint, MediaRef, SequenceFormat, Track, TrackKind};
    use sq_core_time::{Time, TimeRange};

    pub fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// One sequence: V1 = [a 0-4s][b 4-8s], A1 = [a' 0-4s] linked to a. 25 fps, media 20 s long.
    pub struct Fixture {
        pub project: Project,
        pub seq: Id,
        pub v1: Id,
        pub a1: Id,
        pub a: Id,
        pub b: Id,
        pub a_audio: Id,
    }

    impl Fixture {
        pub fn new() -> Fixture {
            let mut media = MediaRef::new(Id::from_u128(900), "m.mov", "/x/m.mov", MediaFingerprint::new(1));
            media.duration = Some(s(20));
            let link = Id::from_u128(901);
            let clip = |n: u128, name: &str, kind, at: i64, src: i64, link: Option<Id>| {
                let mut c =
                    Clip::new(Id::from_u128(1000 + n), name, media.id, kind, TimeRange::new(s(src), s(4)), s(at));
                c.link = link;
                c.media_duration = Some(s(20));
                c
            };
            let ca = clip(1, "a", TrackKind::Video, 0, 2, Some(link));
            let cb = clip(2, "b", TrackKind::Video, 4, 10, None);
            let caa = clip(3, "a", TrackKind::Audio, 0, 2, Some(link));
            let mut v = Track::new(Id::from_u128(10), TrackKind::Video);
            v.set_clips(vec![ca.clone(), cb.clone()]);
            v.name = "V1".into();
            v.is_targeted = true;
            let mut au = Track::new(Id::from_u128(11), TrackKind::Audio);
            au.set_clips(vec![caa.clone()]);
            au.name = "A1".into();
            au.is_targeted = true;
            let t = Timeline::new(
                Id::from_u128(500),
                "Seq",
                SequenceFormat::new(Time::new(1, 25)),
                vec![v.clone(), au.clone()],
            );
            let project = Project::new(Id::from_u128(800), "P", vec![media], vec![t.clone()]);
            Fixture { project, seq: t.id, v1: v.id, a1: au.id, a: ca.id, b: cb.id, a_audio: caa.id }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::{Fixture, s};
    use super::*;
    use sq_core_edit::history::History;
    use sq_core_model::{Clip, MediaInfo, PixelAspect, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn ids() -> SequentialIds {
        SequentialIds::default()
    }

    #[test]
    fn building_operations_change_tracks_speed_settings_and_clips() {
        use crate::edit_operation::Fps;
        let f = Fixture::new();
        let mut p = f.project.clone();
        let tracks_before = p.timelines[0].tracks.len();
        let ops = [
            EditOperation::AddTrack { kind: TrackKind::Audio },
            EditOperation::SetTrackState { track: f.a1, mute: Some(true), solo: None, lock: None, visible: Some(false) },
            EditOperation::SetClipSpeed { clip: f.b, speed: sq_core_model::ClipSpeed::new(2, 1) },
            EditOperation::RemoveClip { clips: vec![f.a], ripple: false },
            EditOperation::SetSequenceSettings {
                sequence: None,
                width: Some(1080),
                height: Some(1920),
                fps: Some(Fps { num: 30, den: 1 }),
                sample_rate: None,
            },
        ];
        EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).expect("apply");
        let t = &p.timelines[0];
        assert_eq!(t.tracks.len(), tracks_before + 1);
        assert!(t.tracks.last().is_some_and(|x| x.kind == TrackKind::Audio));
        let a1 = t.track(f.a1).expect("a1");
        assert!(a1.is_muted && !a1.is_visible && !a1.is_solo);
        assert_eq!((t.format.width, t.format.height, t.format.frame_duration), (1080, 1920, Time::new(1, 30)));
        assert!(t.track(f.v1).is_some_and(|v| v.clips().iter().all(|c| c.id != f.a)), "a is lifted");
        // A refusal changes nothing.
        let mut q = f.project.clone();
        let bad = [EditOperation::SetTrackState { track: Id::from_u128(77), mute: Some(true), solo: None, lock: None, visible: None }];
        assert_eq!(EditTransaction::apply(&bad, &mut q, f.seq, &mut ids()).map_err(|e| e.kind), Err(TransactionErrorKind::TrackNotFound));
        let session_op = [EditOperation::SetActiveSequence { sequence: f.seq }];
        assert_eq!(EditTransaction::apply(&session_op, &mut q, f.seq, &mut ids()).map_err(|e| e.kind), Err(TransactionErrorKind::NeedsSession));
        assert_eq!(q, f.project);
    }

    #[test]
    fn out_of_range_time_in_code_is_refused_before_arithmetic() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        let huge = Time::new(i64::MAX / 2, 3);
        let ops = [
            EditOperation::AddMarker { at: s(1), name: String::new() },
            EditOperation::Trim { clip: f.a, edge: sq_core_model::ClipEdge::Tail, by: huge, linked: true },
        ];
        let e = EditTransaction::apply(&ops, &mut p, f.seq, &mut ids());
        assert_eq!(e, Err(TransactionError::at(TransactionErrorKind::InvalidTime, 1, "trim")));
        assert_eq!(p, f.project);
        let razor = [EditOperation::Razor { at: huge, tracks: None }];
        assert!(EditTransaction::preview(&razor, &p, f.seq, &mut ids()).is_err());
    }

    /// The largest allowed times against project times on an awkward timescale must fail cleanly or apply, never panic.
    #[test]
    fn extreme_allowed_times_do_not_trap() {
        use sq_core_model::ClipEdge::{Head, Tail};
        let mut f = Fixture::new();
        assert!(
            f.project
                .edit(f.seq, |t| {
                    t.set_frame_duration(Time::new(1001, 90000));
                    Ok(())
                })
                .is_ok()
        );
        let ts = TimeLimits::MAX_TIMESCALE - 1; // odd, coprime with 90000
        let far = Time::new(ts * TimeLimits::MAX_SECONDS, ts);
        let back = Time::new(-ts * TimeLimits::MAX_SECONDS, ts);
        let ops = [
            EditOperation::Razor { at: far, tracks: None },
            EditOperation::Razor { at: back, tracks: None },
            EditOperation::Trim { clip: f.a, edge: Tail, by: far, linked: true },
            EditOperation::Trim { clip: f.a, edge: Head, by: back, linked: true },
            EditOperation::Move { clip: f.b, to: far, track: None },
            EditOperation::Slip { clip: f.a, by: far },
            EditOperation::Slide { clip: f.b, by: back },
            EditOperation::Roll { clip: f.a, by: far },
            EditOperation::RippleTrim { clip: f.b, edge: Tail, by: back, linked: true },
            EditOperation::AddMarker { at: far, name: String::new() },
            EditOperation::Extract { range: TimeRange::new(Time::ZERO, far), tracks: None },
        ];
        for op in ops {
            let mut p = f.project.clone();
            let _ = EditTransaction::apply(&[op], &mut p, f.seq, &mut ids());
        }
    }

    /// A ripple trim that shortens but cannot (a clip right behind the edit on another track leaves no room) says why.
    #[test]
    fn a_trim_that_moves_nothing_is_refused_with_the_reason() {
        use sq_core_model::{Clip, TrackKind};
        let f = Fixture::new();
        let mut p = f.project.clone();
        // An unlinked audio clip [4 s, 8 s) and one right behind it [8 s, 12 s): nothing can close under b's tail at 8 s.
        let media = p.media[0].id;
        let mk = |n: u128, at: i64| {
            let mut c = Clip::new(Id::from_u128(2000 + n), "x", media, TrackKind::Audio, TimeRange::new(s(0), s(4)), s(at));
            c.media_duration = Some(s(20));
            c
        };
        let t = p.timelines.iter_mut().find(|t| t.id == f.seq).expect("timeline");
        let a1 = t.tracks.iter_mut().find(|x| x.id == f.a1).expect("a1");
        let mut clips = a1.clips().to_vec();
        clips.extend([mk(1, 4), mk(2, 8)]);
        a1.set_clips(clips);
        let half = Time::new(-1, 2);
        let op = EditOperation::RippleTrim { clip: f.b, edge: sq_core_model::ClipEdge::Tail, by: half, linked: true };
        let err = EditTransaction::apply(&[op], &mut p, f.seq, &mut ids()).expect_err("blocked");
        assert_eq!(err.kind, TransactionErrorKind::Invalid);
        assert!(err.message().contains("rippleTrim moved nothing"), "{}", err.message());
        // A plain shortening on a free track moves as asked.
        let mut free = f.project.clone();
        let op = EditOperation::RippleTrim { clip: f.b, edge: sq_core_model::ClipEdge::Tail, by: half, linked: true };
        EditTransaction::apply(&[op], &mut free, f.seq, &mut ids()).expect("shortens");
        let len = free.timeline(f.seq).and_then(|t| t.find(f.b)).map(|m| m.clip.timeline().duration);
        assert_eq!(len, Some(Time::new(7, 2)));
    }

    #[test]
    fn error_after_the_last_operation_has_no_index() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        // A sequence that already contains itself: the nesting check at the end of Project::edit refuses any batch.
        let mut self_clip =
            Clip::new(Id::from_u128(77), "self", f.seq, TrackKind::Video, TimeRange::new(Time::ZERO, s(1)), s(10));
        self_clip.sequence = Some(f.seq);
        let mut clips = p.timelines[0].tracks[0].clips().to_vec();
        clips.push(self_clip);
        let mut v = Track::new(f.v1, TrackKind::Video);
        v.name = "V1".into();
        v.set_clips(clips);
        p.timelines[0].tracks[0] = v;
        let snapshot = p.clone();
        let ops = [EditOperation::AddMarker { at: s(1), name: String::new() }];
        let e = EditTransaction::apply(&ops, &mut p, f.seq, &mut ids());
        assert_eq!(e, Err(TransactionError::new(TransactionErrorKind::Edit(EditError::NestingCycle))));
        assert_eq!(p, snapshot);
    }

    #[test]
    fn applies_batch_in_order() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        let ops = [EditOperation::Razor { at: s(2), tracks: None }, EditOperation::RippleDelete { clips: vec![f.b] }];
        assert!(EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).is_ok());
        let t = p.timeline(f.seq).map(|t| t.tracks.clone()).unwrap_or_default();
        assert_eq!(t[0].clips().len(), 2); // a split in two, b gone
        assert_eq!(t[1].clips().len(), 2); // a' split with it
        assert_eq!(t[0].clips().iter().map(|c| c.start).collect::<Vec<_>>(), vec![Time::ZERO, s(2)]);
    }

    #[test]
    fn failing_operation_rolls_back_everything() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        let ghost = Id::from_u128(9999);
        let ops = [EditOperation::RippleDelete { clips: vec![f.b] }, EditOperation::Lift { clips: vec![ghost] }];
        let e = EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).err();
        assert!(
            e.as_ref().is_some_and(|e| e.operation_index == Some(1) && e.underlying() == Some(EditError::ClipNotFound))
        );
        assert_eq!(e.map(|e| e.message()), Some("operation 1 (lift): clipNotFound".to_string()));
        assert_eq!(p, f.project);
    }

    #[test]
    fn unknown_sequence_fails() {
        let mut p = Fixture::new().project;
        assert!(EditTransaction::apply(&[], &mut p, Id::from_u128(4242), &mut ids()).is_err());
    }

    /// `liftRange` on V1 only: the linked sound on the untargeted A1 is cut with its picture, nothing ripples.
    #[test]
    fn lift_range_with_explicit_tracks_cuts_the_linked_partner() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        let ops = [EditOperation::LiftRange { range: TimeRange::new(s(1), s(1)), tracks: Some(vec![f.v1]) }];
        assert!(EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).is_ok());
        let t = p.timeline(f.seq).cloned().unwrap_or_else(|| f.project.timelines[0].clone());
        let v = t.track(f.v1).map(|t| t.clips().to_vec()).unwrap_or_default();
        let a = t.track(f.a1).map(|t| t.clips().to_vec()).unwrap_or_default();
        assert_eq!(v.iter().map(|c| c.start).collect::<Vec<_>>(), vec![s(0), s(2), s(4)]);
        assert_eq!(a.iter().map(|c| c.start).collect::<Vec<_>>(), vec![s(0), s(2)]);
        assert_eq!(a.iter().map(Clip::duration).collect::<Vec<_>>(), vec![s(1), s(2)]);
        assert!(a[0].id == f.a_audio && a[0].link == v[0].link);
        assert!(a[1].link.is_some() && a[1].link == v[1].link && a[1].link != a[0].link);
    }

    #[test]
    fn empty_range_tracks_means_unlocked_tracks() {
        let f = Fixture::new();
        let mut p = f.project.clone();
        let ops = [EditOperation::Extract { range: TimeRange::new(s(1), s(1)), tracks: None }];
        assert!(EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).is_ok());
        assert_eq!(p.timeline(f.seq).map(Timeline::duration), Some(s(7)));
    }

    #[test]
    fn one_undo_step_through_history() {
        let f = Fixture::new();
        let mut h = History::with_default_limit(f.project.clone());
        let mut source = ids();
        let r = h.try_commit("Agent: tighten", |p| {
            let ops = [
                EditOperation::Razor { at: s(1), tracks: None },
                EditOperation::Razor { at: s(3), tracks: None },
                EditOperation::RippleDelete { clips: vec![f.b] },
            ];
            EditTransaction::apply(&ops, p, f.seq, &mut source)
        });
        assert!(r.is_ok());
        assert_eq!(h.undo_names().len(), 1);
        assert_eq!(h.undo_name(), Some("Agent: tighten"));
        h.undo();
        assert_eq!(h.current(), &f.project);
    }

    #[test]
    fn diff_reports_added_removed_changed_and_duration() {
        let f = Fixture::new();
        let ops = [
            EditOperation::Razor { at: s(2), tracks: Some(vec![f.v1]) },
            EditOperation::RippleDelete { clips: vec![f.b] },
        ];
        let Ok((_, d)) = EditTransaction::preview(&ops, &f.project, f.seq, &mut ids()) else {
            panic!("preview failed")
        };
        assert_eq!(d.removed.iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.b]);
        assert_eq!(d.added.len(), 1); // right half of a
        assert!(d.added[0].start == s(2) && d.added[0].duration == s(2));
        assert_eq!(d.changed.iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.a]); // a got shorter
        assert!(d.changed[0].before.duration == s(4) && d.changed[0].after.duration == s(2));
        assert!(d.duration_before == s(8) && d.duration_after == s(4));
        assert!(!d.is_empty());
    }

    #[test]
    fn no_change_is_empty_and_markers_count() {
        let f = Fixture::new();
        let t = &f.project.timelines[0];
        assert!(EditDiff::new(t, t).is_empty());
        let ops = [EditOperation::AddMarker { at: s(1), name: "x".into() }];
        let Ok((_, d)) = EditTransaction::preview(&ops, &f.project, f.seq, &mut ids()) else {
            panic!("preview failed")
        };
        assert!(d.markers_added == 1 && d.added.is_empty() && d.removed.is_empty());
    }

    #[test]
    fn apply_off_actor_matches_apply_and_honors_cancel() {
        let f = Fixture::new();
        let ops = [EditOperation::Razor { at: s(2), tracks: None }];
        let cancel = AtomicBool::new(false);
        let off = EditTransaction::apply_off_actor(&ops, &f.project, f.seq, &mut ids(), &cancel);
        let mut inline = f.project.clone();
        assert!(EditTransaction::apply(&ops, &mut inline, f.seq, &mut ids()).is_ok());
        assert_eq!(off, Ok(inline));
        assert_ne!(f.project, off.unwrap_or_else(|_| f.project.clone()));
        cancel.store(true, Ordering::SeqCst);
        let late = EditTransaction::apply_off_actor(&ops, &f.project, f.seq, &mut ids(), &cancel);
        assert_eq!(late, Err(TransactionError::new(TransactionErrorKind::Cancelled)));
    }

    fn fixture_with_picture() -> (Fixture, Id) {
        let mut f = Fixture::new();
        let id = f.project.media[0].id;
        let info = serde_json::from_value::<MediaInfo>(serde_json::json!({
            "duration": {"value": 20, "timescale": 1},
            "video": {"width": 1440, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                      "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false}
        }));
        f.project.media[0].info = info.ok();
        (f, id)
    }

    #[test]
    fn set_pixel_aspect_sets_and_clears_the_choice() {
        let (f, id) = fixture_with_picture();
        let mut p = f.project.clone();
        let four_three = PixelAspect::new(4, 3);
        let ops = [EditOperation::SetPixelAspect { media: id, aspect: four_three }];
        assert!(EditTransaction::apply(&ops, &mut p, f.seq, &mut ids()).is_ok());
        assert_eq!(p.pixel_aspect_of(id), four_three);
        let mut diff = EditDiff::new(&f.project.timelines[0], &p.timelines[0]);
        assert!(diff.is_empty());
        diff.note_media(&f.project, &p);
        assert!(diff.pixel_aspect_changes == Some(1) && !diff.is_empty());
        let clear = [EditOperation::SetPixelAspect { media: id, aspect: None }];
        assert!(EditTransaction::apply(&clear, &mut p, f.seq, &mut ids()).is_ok());
        assert_eq!(p.pixel_aspect_of(id), Some(PixelAspect::square()));
    }

    #[test]
    fn set_pixel_aspect_refusal_leaves_the_project_untouched() {
        let (f, id) = fixture_with_picture();
        let mut p = f.project.clone();
        let two = PixelAspect::new(2, 1);
        let ghost_media = [
            EditOperation::SetPixelAspect { media: id, aspect: two },
            EditOperation::SetPixelAspect { media: Id::from_u128(31337), aspect: None },
        ];
        assert!(EditTransaction::apply(&ghost_media, &mut p, f.seq, &mut ids()).is_err());
        assert_eq!(p.media, f.project.media);
        // A timeline failure after the media setting rolls it back too.
        let late = [
            EditOperation::SetPixelAspect { media: id, aspect: two },
            EditOperation::RippleDelete { clips: vec![Id::from_u128(31338)] },
        ];
        assert!(EditTransaction::apply(&late, &mut p, f.seq, &mut ids()).is_err());
        assert_eq!(p.media, f.project.media);
        // Media without a probed picture.
        let mut q = f.project.clone();
        q.media[0].info = None;
        let ops = [EditOperation::SetPixelAspect { media: id, aspect: None }];
        let e = EditTransaction::apply(&ops, &mut q, f.seq, &mut ids()).err();
        assert!(e.is_some_and(|e| e.kind == TransactionErrorKind::NoPicture && e.operation_index == Some(0)));
    }

    /// An L-cut: clip A's sound runs 8 frames under B's picture; the picture cut stays. `linked: false` is the Alt-trim.
    #[test]
    fn an_unlinked_trim_cuts_sound_and_picture_at_different_times() {
        use sq_core_model::ClipEdge::Tail;
        let f = Fixture::new();
        let by = Time::new(8, 25);
        let clip_end = |p: &Project, id: Id| p.timeline(f.seq).and_then(|t| t.find(id)).map(|m| m.clip.timeline().end());
        let mut p = f.project.clone();
        let op = EditOperation::Trim { clip: f.a_audio, edge: Tail, by, linked: false };
        assert!(EditTransaction::apply(&[op], &mut p, f.seq, &mut ids()).is_ok());
        assert_eq!(clip_end(&p, f.a_audio), Some(s(4) + by), "the sound runs on");
        assert_eq!(clip_end(&p, f.a), Some(s(4)), "the picture cut stays");
        assert!(p.timeline(f.seq).and_then(|t| t.find(f.a)).is_some_and(|m| m.clip.link.is_some()), "still linked");
        // The linked default moves both.
        let mut q = f.project.clone();
        let op = EditOperation::Trim { clip: f.a_audio, edge: Tail, by: Time::new(-8, 25), linked: true };
        assert!(EditTransaction::apply(&[op], &mut q, f.seq, &mut ids()).is_ok());
        assert_eq!(clip_end(&q, f.a), Some(s(4) - Time::new(8, 25)));
    }

    #[test]
    fn unlink_and_link_change_who_follows_a_trim() {
        use sq_core_model::ClipEdge::Tail;
        let f = Fixture::new();
        let mut p = f.project.clone();
        let both = vec![f.a, f.a_audio];
        assert!(EditTransaction::apply(&[EditOperation::Unlink { clips: both.clone() }], &mut p, f.seq, &mut ids()).is_ok());
        let link = |p: &Project, id: Id| p.timeline(f.seq).and_then(|t| t.find(id)).and_then(|m| m.clip.link);
        assert_eq!((link(&p, f.a), link(&p, f.a_audio)), (None, None));
        let by = Time::new(-8, 25);
        let op = EditOperation::Trim { clip: f.a_audio, edge: Tail, by, linked: true };
        assert!(EditTransaction::apply(&[op], &mut p, f.seq, &mut ids()).is_ok());
        let end = |p: &Project, id: Id| p.timeline(f.seq).and_then(|t| t.find(id)).map(|m| m.clip.timeline().end());
        assert_eq!(end(&p, f.a), Some(s(4)), "unlinked: the picture stays");
        assert!(EditTransaction::apply(&[EditOperation::Link { clips: both }], &mut p, f.seq, &mut ids()).is_ok());
        assert!(link(&p, f.a).is_some() && link(&p, f.a) == link(&p, f.a_audio));
    }
}
