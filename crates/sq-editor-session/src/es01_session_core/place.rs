//! Placing media and sequences on the timeline, the format question, and nesting.

use std::collections::BTreeSet;

use sq_core_edit::grouping::ProjectGroupingExt;
use sq_core_edit::source_edit_placement::SourceEditPlacementExt;
use sq_core_edit::timeline_add_track::AddTrackExt;
use sq_core_edit::timeline_drop_targets::TimelineDropTargetsExt;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_magnetic_verbs::MagneticNestExt;
use sq_core_edit::timeline_place_on_top::{PlaceOnTopTarget, TimelinePlaceOnTopExt};
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_edit::timeline_source_patch::TimelineSourcePatchExt as _;
use sq_core_model::{
    Clip, EditError, MediaRef, SequenceFormat, SourceMarks, SourcePlacement, ThreePointMode, Timeline, TrackKind,
};
use sq_core_time::{Id, Time, TimeRange};
use sq_runtime::UiRef;

use crate::{Change, EditorSession, SessionRoot};

/// The questions ES1 flows ask the user (implemented by the app root next to [`SessionRoot`]).
pub trait FormatAsks {
    /// "This clip does not match the sequence settings": `true` adopts `proposed`. Swift `askFormatChange`.
    // Swift: EditorSession.swift:185
    fn ask_format_change(&mut self, current: &SequenceFormat, proposed: &SequenceFormat) -> sq_runtime::ModalAsk<bool>;
}

/// Everything `place_media` takes besides the media ids (Swift's labeled defaults).
// Swift: EditorSession.swift:1465
#[derive(Clone, Debug, PartialEq)]
pub struct PlaceOptions {
    /// Where the first item starts (default: the playhead).
    pub at: Option<Time>,
    /// The video track the drop landed on.
    pub video_track: Option<Id>,
    pub mode: ThreePointMode,
    /// A mismatching first clip sets the format of an empty, never configured sequence.
    pub adopt_format: bool,
    pub streams: SourceStreams,
    /// A ghost track of this kind is created for the drop.
    pub new_track: Option<TrackKind>,
    /// Place on Top: the track above the topmost occupied one (Fast Cut).
    pub place_on_top: bool,
    /// Attach Backtimed: the run ends on the playhead.
    pub backtimed: bool,
    /// Source patch targets (`source_patch`) instead of the drop rule.
    pub patched: bool,
    /// The part of every placed media item to use instead of its Mark In / Mark Out (the edit API's `sourceIn` /
    /// `sourceOut`); `None` = the marks of the item.
    pub source: Option<(Option<Time>, Option<Time>)>,
}

impl Default for PlaceOptions {
    fn default() -> PlaceOptions {
        PlaceOptions {
            at: None,
            video_track: None,
            mode: ThreePointMode::Overwrite,
            adopt_format: true,
            streams: SourceStreams::Both,
            new_track: None,
            place_on_top: false,
            backtimed: false,
            patched: false,
            source: None,
        }
    }
}

fn duration_of(r: &MediaRef) -> Option<Time> {
    r.info.as_ref().map(|i| i.duration).or(r.duration)
}

fn usable_marks(marks: &std::collections::BTreeMap<Id, SourceMarks>, id: Id) -> SourceMarks {
    marks.get(&id).filter(|m| m.range().is_some()).cloned().unwrap_or_default()
}

impl EditorSession {
    /// The format a first clip would give an empty, never configured sequence; `None` when nothing would change.
    // Swift: EditorSession.swift:1625
    pub fn format_mismatch(&self, ids: &[Id]) -> Option<SequenceFormat> {
        let t = self.active_timeline()?;
        if t.format_locked || !t.tracks.iter().all(|tr| tr.clips().is_empty()) {
            return None;
        }
        let r = ids.iter().filter_map(|i| self.project().media(*i)).find(|r| duration_of(r).is_some())?;
        let v = r.info.as_ref()?.video.as_ref()?;
        let still = r.info.as_ref().is_some_and(|i| i.is_still);
        let mut f = t.format.clone();
        f.width = v.display_width();
        f.height = v.display_height();
        f.frame_duration = if still { t.format.frame_duration } else { v.nominal_frame_duration };
        let f = f.sanitized(&t.format);
        (f != t.format).then_some(f)
    }

    /// Places media at the edit point (Insert / Overwrite, drops, Place on Top, Attach Backtimed): one undo step.
    /// Returns whether something was placed.
    /// `patched`: without a track or ghost, the items land on the sequence's source patch (`source_patch`) instead of the
    /// drop rule; Place on Top then honors a disconnected video patch.
    // Swift: EditorSession.swift:1465
    pub fn place_media(&mut self, ids: &[Id], options: &PlaceOptions) -> bool {
        // No sequence yet (fresh project without one): the first media makes one, unconfigured so it adopts the size.
        if self.active_timeline().is_none() && ids.iter().any(|i| self.project().media(*i).is_some()) {
            let name = self.suggested_sequence_name();
            let mode = self.new_sequence_edit_mode;
            let mut empty = {
                let ids_src = self.ids.as_mut();
                let tracks = Timeline::default_tracks(4, 4, ids_src);
                Timeline::new(ids_src.next_id(), &name, SequenceFormat::new(Time::new(1001, 30000)), tracks)
            };
            empty.format_locked = false;
            empty.set_edit_mode(mode);
            let new_id = empty.id;
            self.perform("New Sequence", None, |p| {
                p.timelines.push(empty);
                p.normalize_bins();
            });
            self.set_active_timeline(new_id);
        }
        let Some(t) = self.active_timeline().cloned() else { return false };
        let fast = t.is_fast_cut();
        if options.backtimed && !(options.place_on_top && fast) {
            self.set_error("Attach Backtimed needs a Fast Cut sequence.");
            return false;
        }
        if options.backtimed && t.main_track_end() <= Time::ZERO {
            self.set_error("Attach Backtimed needs a clip on the main track.");
            return false;
        }
        let refs: Vec<MediaRef> =
            ids.iter().filter_map(|i| self.project().media(*i)).filter(|r| duration_of(r).is_some()).cloned().collect();
        if refs.is_empty() {
            return false;
        }
        let mut adopts = options.adopt_format && !t.format_locked && t.tracks.iter().all(|tr| tr.clips().is_empty());
        if adopts
            && let Some(proposed) = self.format_mismatch(ids)
            && let Some(ask) = self.confirm_format_change.as_mut()
        {
            adopts = ask(&t.format, &proposed);
        }
        // A ghost drop must put something on the new track: refuse when the chosen streams or the media offer nothing.
        if let Some(kind) = options.new_track {
            let usable = if kind == TrackKind::Video {
                options.streams.includes_video()
            } else {
                options.streams.includes_audio()
            };
            let offered = refs.iter().any(|r| {
                if kind == TrackKind::Video {
                    r.info.as_ref().is_none_or(|i| i.video.is_some())
                } else {
                    r.info.as_ref().is_some_and(|i| i.audio.is_some())
                }
            });
            if !(usable && offered) {
                return false;
            }
        }
        let requested = options.at.unwrap_or(self.playhead);
        let mut marks = self.project().source_marks.clone();
        if let Some((mark_in, mark_out)) = options.source {
            for r in &refs {
                marks.insert(r.id, SourceMarks { mark_in, mark_out, ..SourceMarks::default() });
            }
        }
        let patch = (options.patched && options.video_track.is_none() && options.new_track.is_none())
            .then(|| self.source_patch());
        let existing: BTreeSet<Id> = t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        let label = if options.backtimed {
            "Attach Backtimed"
        } else if options.mode == ThreePointMode::Insert {
            "Insert"
        } else {
            "Overwrite"
        };
        // Whole frames of the sequence, as placed (`source_edit_plan`): the run length of Place on Top / Backtimed.
        let run_lengths = |fd: Time| -> Vec<Time> {
            refs.iter()
                .filter_map(|r| {
                    let total = duration_of(r).unwrap_or(Time::ZERO);
                    if r.info.as_ref().is_some_and(|i| i.is_still) {
                        return Some(total.snapped(fd));
                    }
                    let m = usable_marks(&marks, r.id);
                    Timeline::source_edit_plan(&m, total, None, None, Time::ZERO, fd, false).map(|p| p.source.duration)
                })
                .collect()
        };
        let done = self.attempt_ids(label, |tl, ids| {
            let mut video_track = options.video_track;
            let mut streams = options.streams;
            if options.place_on_top && patch.as_ref().is_some_and(|p| !p.video.is_connected) {
                return Err(EditError::ClipNotFound);
            }
            // Attach Backtimed never lands on the main track: the run ends at the playhead, at most at the main
            // track's end. Nothing before the sequence start leaves nothing to attach to: no undo step.
            if options.backtimed && requested.snapped(tl.frame_duration()).min(tl.main_track_end()) <= Time::ZERO {
                return Err(EditError::EmptyClip);
            }
            // Dropped on a ghost track: the track is created inside this same undo step. Audio ghost: audio only.
            if let Some(kind) = options.new_track {
                video_track = Some(tl.add_track(kind, ids));
                if kind == TrackKind::Audio {
                    streams = SourceStreams::AudioOnly;
                }
            }
            if adopts && let Some(v) = refs[0].info.as_ref().and_then(|i| i.video.as_ref()) {
                // Upright (display) size: a portrait phone clip makes a portrait sequence. A still keeps the rate.
                let still = refs[0].info.as_ref().is_some_and(|i| i.is_still);
                let mut f = tl.format.clone();
                f.width = v.display_width();
                f.height = v.display_height();
                f.frame_duration = if still { tl.format.frame_duration } else { v.nominal_frame_duration };
                tl.format = f.sanitized(&tl.format);
            }
            let fd = tl.frame_duration();
            let mut at = requested.snapped(fd); // after a format change: the new frame grid
            // Place on Top: the track above the topmost occupied one over the whole run (video only).
            if options.place_on_top && options.new_track.is_none() {
                let length = run_lengths(fd).into_iter().fold(Time::ZERO, |a, b| a + b);
                let end = requested.snapped(fd);
                let range = if options.backtimed {
                    let hi = end.min(tl.main_track_end());
                    TimeRange::from_end((hi - length).max(Time::ZERO), hi)
                } else {
                    TimeRange::new(end, length)
                };
                video_track = Some(match tl.place_on_top_target(range) {
                    PlaceOnTopTarget::Existing(id) => id,
                    PlaceOnTopTarget::NewTrack => tl.add_track(TrackKind::Video, ids),
                });
                streams = SourceStreams::VideoOnly;
            }
            // Attach Backtimed: the items form one run that ends on the playhead, in selection order; each ends where
            // the next one starts. Items entirely before the sequence start drop out.
            let back_end = requested.snapped(fd).min(tl.main_track_end());
            let mut ends_at: Vec<Time> = Vec::new();
            if options.backtimed {
                let mut e = back_end;
                for len in run_lengths(fd).into_iter().rev() {
                    ends_at.insert(0, e);
                    e -= len;
                }
            }
            for (index, r) in refs.iter().enumerate() {
                // Scale is relative to source pixels: a new clip is placed at the fit value ("Set to Frame Size").
                let fit = r
                    .info
                    .as_ref()
                    .and_then(|i| i.video.as_ref())
                    .map_or(1.0, |v| tl.format.fit_scale(v.display_width(), v.display_height()));
                let total = duration_of(r).unwrap_or(Time::ZERO);
                let still = r.info.as_ref().is_some_and(|i| i.is_still);
                // Whole frames of the sequence: a 23.976 source in a 29.97 sequence must not leave off-grid ends.
                let m = if still { SourceMarks::default() } else { usable_marks(&marks, r.id) };
                let plan = Timeline::source_edit_plan(&m, total, None, None, at, tl.frame_duration(), still)
                    .ok_or(EditError::EmptyClip)?;
                // A still has no media length: its default is `total`; the edit API's `sourceOut` / `duration` sets its
                // length (the marks of a still stay ignored, as in the UI).
                let still_length = options.source.and_then(|(_, out)| out).unwrap_or(total).snapped(tl.frame_duration());
                if still && still_length <= Time::ZERO {
                    return Err(EditError::EmptyClip);
                }
                let source = if still { TimeRange::new(Time::ZERO, still_length) } else { plan.source };
                let has_video = r.info.as_ref().is_none_or(|i| i.video.is_some()) && streams.includes_video();
                let has_audio = r.info.as_ref().is_some_and(|i| i.audio.is_some()) && streams.includes_audio();
                let mut targets: Vec<Id> = Vec::new();
                if let Some(p) = patch.as_ref().filter(|_| !options.place_on_top) {
                    let mut ensure = |t: &mut Timeline| t.add_track(TrackKind::Audio, &mut *ids);
                    targets = tl
                        .source_patch_targets(p, has_video, has_audio, true, true, &mut ensure)
                        .ok_or(EditError::ClipNotFound)?;
                } else {
                    let d = tl.drop_targets(video_track, has_video, has_audio);
                    if let Some(v) = d.video {
                        targets.push(v);
                    }
                    if let Some(a) = d.audio {
                        targets.push(a);
                    } else if let Some(n) = d.new_audio_ordinal {
                        targets.push(tl.ensure_audio_track(n, ids));
                    }
                }
                if options.backtimed && (index >= ends_at.len() || ends_at[index] <= Time::ZERO) {
                    continue;
                }
                let mut src = SourcePlacement::new(source, r.id, &r.name);
                src.media_duration = (!still).then_some(total);
                src.is_still = still;
                src.initial_scale = fit;
                let when = if options.backtimed { ends_at[index] } else { at };
                tl.three_point_edit(&src, &targets, when, options.mode, ids)?;
                at = (at + source.duration).snapped(tl.frame_duration());
            }
            Ok(())
        });
        self.select_new_clips(&existing);
        done
    }

    /// `place_media`, asking the format question first when the media would change an empty, never configured
    /// sequence. Returns once placed (or refused); the result says whether it was placed.
    // Swift: EditorSession+FormatAsk.swift:10
    #[allow(clippy::too_many_arguments)]
    pub async fn place_media_asking<R: SessionRoot + FormatAsks + ?Sized>(
        h: UiRef<R>,
        ids: Vec<Id>,
        at: Option<Time>,
        video_track: Option<Id>,
        mode: ThreePointMode,
        streams: SourceStreams,
        new_track: Option<TrackKind>,
    ) -> bool {
        let options = PlaceOptions { at, video_track, mode, streams, new_track, ..PlaceOptions::default() };
        Self::place_options_asking(h, ids, options).await
    }

    /// `place_media_asking` for a full set of options (Insert / Overwrite keys, drops on the timeline).
    pub async fn place_options_asking<R: SessionRoot + FormatAsks + ?Sized>(
        h: UiRef<R>,
        ids: Vec<Id>,
        options: PlaceOptions,
    ) -> bool {
        // The question, when the media would change an empty sequence's format.
        let ask = h.with(|r| {
            let s = r.session();
            let t = s.active_timeline()?;
            let proposed = s.format_mismatch(&ids)?;
            let current = t.format.clone();
            Some((current, proposed))
        });
        let Some(Some((current, proposed))) = ask else {
            return h.with(|r| r.session().place_media(&ids, &options)).unwrap_or(false);
        };
        let answer = h.with(|r| r.ask_format_change(&current, &proposed));
        let Some(answer) = answer else { return false };
        let adopt = answer.await;
        let options = PlaceOptions { adopt_format: adopt, ..options };
        h.with(|r| r.session().place_media(&ids, &options)).unwrap_or(false)
    }

    /// Nest (Combine) of the selected clips into a new sequence; the nested clips become the selection.
    // Swift: EditorSession.swift:530
    pub fn nest_selection(&mut self, name: &str) -> Option<Id> {
        let id = self.active_timeline_id?;
        if self.selection.is_empty() {
            return None;
        }
        let clips: Vec<Id> = self.selection.iter().copied().collect();
        let trimmed = name.trim();
        // Fast Cut: the attached clips inside the span go into the nest too; Normal: `nest`.
        let mut seq = None;
        let lease = self.lend_ids();
        let ids = &mut lease.source();
        let result = self.try_perform("Combine", None, |p| {
            seq = Some(p.magnetic_nest(&clips, id, (!trimmed.is_empty()).then_some(trimmed), &mut *ids)?);
            Ok::<(), EditError>(())
        });
        self.return_ids(lease);
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return None;
        }
        let seq = seq?;
        if let Some(t) = self.active_timeline() {
            let nested: BTreeSet<Id> = t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter())
                .filter(|c: &&Clip| c.sequence == Some(seq))
                .map(|c| c.id)
                .collect();
            self.set_selection(nested, BTreeSet::new());
        }
        Some(seq)
    }

    /// Group of the selected clips.
    // Swift: EditorSession.swift:547
    pub fn group_selection(&mut self) -> Option<Id> {
        let id = self.active_timeline_id?;
        if self.selection.is_empty() {
            return None;
        }
        let clips: Vec<Id> = self.selection.iter().copied().collect();
        let mut seq = None;
        let result = self.with_ids(|s, ids| {
            s.try_perform("Group", None, |p| {
                seq = Some(p.group(&clips, id, ids)?);
                Ok::<(), EditError>(())
            })
        });
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return None;
        }
        let seq = seq?;
        if let Some(t) = self.active_timeline() {
            let grouped: BTreeSet<Id> = t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter())
                .filter(|c: &&Clip| c.sequence == Some(seq))
                .map(|c| c.id)
                .collect();
            self.set_selection(grouped, BTreeSet::new());
        }
        Some(seq)
    }

    /// The selected clips that are groups.
    // Swift: EditorSession.swift:561
    pub fn selected_group_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| {
                self.selection.contains(&c.id)
                    && c.sequence.and_then(|s| self.project().timeline(s)).is_some_and(|s| s.is_group())
            })
            .cloned()
            .collect()
    }

    /// Ungroup of the selected groups.
    // Swift: EditorSession.swift:568
    pub fn ungroup_selection(&mut self) -> bool {
        let Some(id) = self.active_timeline_id else { return false };
        let groups = self.selected_group_clips();
        if groups.is_empty() {
            self.set_error(Self::message_for(&EditError::NotAGroup));
            return false;
        }
        self.restore_selection_content("Ungroup", id, &groups, |p, clip, tl, ids| p.ungroup(clip, tl, ids))
    }

    /// The selected nested-sequence clips (groups and angle clips excluded).
    // Swift: EditorSession.swift:593
    pub fn selected_nested_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| {
                self.selection.contains(&c.id)
                    && c.angle.is_none()
                    && c.sequence.and_then(|s| self.project().timeline(s)).is_some_and(|s| !s.is_group())
            })
            .cloned()
            .collect()
    }

    /// Unnest of the selected nested sequences.
    // Swift: EditorSession.swift:602
    pub fn unnest_selection(&mut self) -> bool {
        let Some(id) = self.active_timeline_id else { return false };
        let nested = self.selected_nested_clips();
        if nested.is_empty() {
            self.set_error(Self::message_for(&EditError::NotNested));
            return false;
        }
        self.restore_selection_content("Unnest", id, &nested, |p, clip, tl, ids| p.unnest(clip, tl, ids))
    }

    /// The shared body of Ungroup and Unnest: every clip of `clips` (and its linked partner of the same sequence) comes
    /// apart in one undo step; the restored clips become the selection.
    fn restore_selection_content(
        &mut self,
        name: &str,
        timeline: Id,
        clips: &[Clip],
        mut restore: impl FnMut(
            &mut sq_core_model::Project,
            Id,
            Id,
            &mut dyn sq_core_time::IdSource,
        ) -> Result<Vec<Id>, EditError>,
    ) -> bool {
        let mut restored: Vec<Id> = Vec::new();
        let result = self.with_ids(|s, ids| {
            s.try_perform(name, None, |p| {
                let mut done: BTreeSet<Id> = BTreeSet::new();
                for g in clips {
                    if done.contains(&g.id) {
                        continue;
                    }
                    // The linked partner of the same group comes apart with it.
                    if let Some(t) = p.timeline(timeline) {
                        for c in t.tracks.iter().flat_map(|tr| tr.clips().iter()) {
                            if c.id == g.id || (g.link.is_some() && c.link == g.link && c.sequence == g.sequence) {
                                done.insert(c.id);
                            }
                        }
                    }
                    restored.extend(restore(p, g.id, timeline, ids)?);
                }
                Ok::<(), EditError>(())
            })
        });
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return false;
        }
        self.set_selection(restored.into_iter().collect(), BTreeSet::new());
        true
    }

    /// Marks the placement changed (for callers that edit the media list directly).
    #[allow(dead_code)] // shortcut: first caller is the media drop flow of ES8
    pub(crate) fn notify_media(&mut self) {
        self.notify(Change::MEDIA);
    }
}
