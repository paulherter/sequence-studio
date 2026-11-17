//! Source monitor edits (Insert / Overwrite and the variants), play ranges, In/Out marks, source patch, Replace edits
//! and Reel Fill.

use sq_core_edit::four_point_fit::FourPointFit;
use sq_core_edit::playback_bounds::PlaybackBounds;
use sq_core_edit::source_edit_placement::MarkedRangeDragPart;
use sq_core_edit::timeline_magnetic_ops::Placement;
use sq_core_edit::timeline_place_on_top::PlaceOnTopTarget;
use sq_core_edit::timeline_reel_fill::ReelFillReport;
use sq_core_edit::timeline_replace_media::{ReplaceAlignment, ReplacementMedia};
use sq_core_edit::timeline_replace_modes::ReplaceMode;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_model::{
    AnimatedProperty, Clip, EditError, MediaRef, SequenceFormat, SourceMarks, SourcePlacement, ThreePointMode,
    Timeline, TrackKind,
};
use sq_core_project::project_template::ProjectTemplate;
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};

use super::prelude::*;
use crate::{Change, EditorSession};

/// How a Source edit places a clip: through the Fast Cut verbs in a Fast Cut sequence, else Insert / Overwrite.
// Swift: Timeline+ThreePoint.swift:51
fn three_point_edit(
    t: &mut Timeline,
    src: &SourcePlacement,
    targets: &[Id],
    at: Time,
    mode: ThreePointMode,
    backtimed: bool,
    ids: &mut dyn IdSource,
) -> Result<(), EditError> {
    if !t.is_fast_cut() {
        return t.three_point_edit(src, targets, at, mode, ids);
    }
    let SourcePlacement { source, media, name, media_duration, is_still, initial_scale, speed } = src;
    if source.is_empty() || source.start < Time::ZERO || media_duration.is_some_and(|md| source.end() > md) {
        return Err(EditError::EmptyClip);
    }
    if targets.is_empty() {
        return Err(EditError::ClipNotFound);
    }
    let kinds = targets
        .iter()
        .map(|id| t.track(*id).map(|tr| tr.kind))
        .collect::<Option<Vec<_>>>()
        .ok_or(EditError::ClipNotFound)?;
    let link = (kinds.contains(&TrackKind::Video) && kinds.contains(&TrackKind::Audio)).then(|| ids.next_id());
    let mut placements: Vec<Placement> = Vec::new();
    for (id, kind) in targets.iter().zip(kinds) {
        let mut clip = Clip::new(ids.next_id(), name, *media, kind, *source, Time::ZERO);
        clip.link = link;
        clip.media_duration = *media_duration;
        clip.is_still = *is_still;
        if !is_still && !speed.is_normal() {
            clip.speed = *speed;
        }
        if kind == TrackKind::Video && (initial_scale - 1.0).abs() > 1e-12 {
            clip.animation.scale = AnimatedProperty::new(Vec2::new(*initial_scale, *initial_scale));
        }
        placements.push((clip, *id));
    }
    t.fast_cut_source_edit(&placements, at, mode, backtimed, ids).map(|_| ())
}

fn media_total(r: &MediaRef) -> Option<Time> {
    r.info.as_ref().map(|i| i.duration).or(r.duration)
}

fn replacement_media(r: &MediaRef, total: Time) -> ReplacementMedia {
    ReplacementMedia {
        id: r.id,
        name: r.name.clone(),
        duration: total,
        has_video: r.info.as_ref().is_some_and(|i| i.video.is_some()) || r.info.is_none(),
        has_audio: r.info.as_ref().is_some_and(|i| i.audio.is_some()),
        is_still: r.info.as_ref().is_some_and(|i| i.is_still),
    }
}

impl EditorSession {
    /// Source Monitor Insert (`,`) / Overwrite (`.`): the source's In..Out (whole media when unmarked) lands at the
    /// sequence In point, else at the playhead, on the patched tracks (`source_patch`; track targeting does not decide
    /// this). Place on Top picks its own video track but honors a disconnected video patch. Afterwards the playhead sits
    /// at the end of the new clip. One undo step. Returns false when nothing was placed.
    // Swift: EditorSession+SourceEdit.swift:9
    #[allow(clippy::too_many_arguments)]
    pub fn source_edit(
        &mut self,
        media: Id,
        marks: Option<&SourceMarks>,
        streams: SourceStreams,
        mode: ThreePointMode,
        place_on_top: bool,
        backtimed: bool,
        fit_to_fill: bool,
        four_point_fit: FourPointFit,
    ) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let Some(r) = self.project().media(media) else { return false };
        if backtimed && !(place_on_top && t.is_fast_cut()) {
            self.set_error("Attach Backtimed needs a Fast Cut sequence.");
            return false;
        }
        if backtimed && t.main_track_end() <= Time::ZERO {
            self.set_error("Attach Backtimed needs a clip on the main track.");
            return false;
        }
        let still = r.info.as_ref().is_some_and(|i| i.is_still);
        let Some(total) = (if still { Some(Time::new(5, 1)) } else { media_total(r) }) else { return false };
        let m = marks.cloned().unwrap_or_else(|| self.project().source_marks_for(media));
        let source =
            if still { Some(TimeRange::new(Time::ZERO, total)) } else { Timeline::source_edit_range(&m, total) };
        let Some(_source) = source else {
            self.set_error("Nothing to edit: the In and Out points leave no range.");
            return false;
        };
        let adopts = !t.format_locked && t.tracks.iter().all(|tr| tr.clips().is_empty());
        let has_video = r.info.as_ref().is_some_and(|i| i.video.is_some()) || r.info.is_none();
        let has_audio = r.info.as_ref().is_some_and(|i| i.audio.is_some());
        let video_info = r.info.as_ref().and_then(|i| i.video.clone());
        let name = r.name.clone();
        let patch = t.source_patch();
        let playhead = self.playhead;
        let mut end_time = Time::ZERO;
        let mut no_target = false;
        let mut four_point = false;
        let mut needs_sequence_range = false;
        let undo = if backtimed {
            "Attach Backtimed"
        } else if fit_to_fill {
            "Fit to Fill"
        } else if mode == ThreePointMode::Insert {
            "Insert"
        } else {
            "Overwrite"
        };
        let done = self.with_ids(|s, ids| {
            s.attempt(undo, None, |tl| {
                if adopts && let Some(v) = &video_info {
                    let fd = if still { tl.format.frame_duration } else { v.nominal_frame_duration };
                    let mut f = SequenceFormat::new(fd);
                    f.width = v.display_width();
                    f.height = v.display_height();
                    f.audio_sample_rate = tl.format.audio_sample_rate;
                    tl.format = f.sanitized(&tl.format);
                }
                // Place on Top ignores the patched track: video only, picked below once the length is known.
                let mut targets: Vec<Id> = Vec::new();
                if !place_on_top {
                    let found = {
                        let mut ensure = |t: &mut Timeline| t.add_track(TrackKind::Audio, &mut *ids);
                        tl.source_patch_targets(
                            &patch,
                            has_video,
                            has_audio,
                            streams.includes_video(),
                            streams.includes_audio(),
                            &mut ensure,
                        )
                    };
                    match found {
                        Some(f) => targets = f,
                        None => {
                            no_target = true;
                            return Err(EditError::ClipNotFound);
                        }
                    }
                } else if !has_video || !streams.includes_video() {
                    return Err(EditError::ClipNotFound);
                } else if !patch.video.is_connected {
                    no_target = true;
                    return Err(EditError::ClipNotFound);
                }
                let fit =
                    video_info.as_ref().map_or(1.0, |v| tl.format.fit_scale(v.display_width(), v.display_height()));
                let mut place = SourcePlacement::new(TimeRange::new(Time::ZERO, total), media, &name);
                place.media_duration = (!still).then_some(total);
                place.is_still = still;
                place.initial_scale = fit;
                let fd = tl.frame_duration();
                let new_track =
                    |tl: &mut Timeline, ids: &mut dyn IdSource, range: TimeRange| match tl.place_on_top_target(range) {
                        PlaceOnTopTarget::Existing(id) => id,
                        PlaceOnTopTarget::NewTrack => tl.add_track(TrackKind::Video, ids),
                    };
                // Attach Backtimed: the sequence In/Out play no part. The length is the source In..Out (or the whole
                // clip), whole frames; the clip ends at the playhead, its head is cut when there is no room before it.
                if backtimed {
                    let plan = Timeline::source_edit_plan(&m, total, None, None, playhead, fd, still)
                        .ok_or(EditError::EmptyClip)?;
                    // Never on the main track: the clip ends at the playhead, at most at the main track's end.
                    let end = playhead.snapped(fd).min(tl.main_track_end());
                    let d = plan.source.duration;
                    if end <= Time::ZERO {
                        return Err(EditError::EmptyClip);
                    }
                    targets = vec![new_track(tl, ids, TimeRange::new((end - d).max(Time::ZERO), d.min(end)))];
                    place.source = plan.source;
                    three_point_edit(tl, &place, &targets, end, mode, true, ids)?;
                    end_time = end;
                    return Ok(());
                }
                // Split In points (Mark Audio In / Mark Video In): picture and sound start apart, end together, linked.
                let (seq_in, seq_out) = tl.explicit_marks();
                if !still
                    && !place_on_top
                    && !fit_to_fill
                    && streams == SourceStreams::Both
                    && has_video
                    && has_audio
                    && !tl.is_fast_cut()
                    && let Some((split_video, split_audio, split_out)) = m.split_ins(total)
                {
                    let video_marks =
                        SourceMarks { mark_in: Some(split_video), mark_out: Some(split_out), ..SourceMarks::default() };
                    let vt = tl.source_patch_targets(&patch, true, false, true, false, &mut |t: &mut Timeline| {
                        t.add_track(TrackKind::Audio, &mut *ids)
                    });
                    let at_ = tl.source_patch_targets(&patch, false, true, false, true, &mut |t: &mut Timeline| {
                        t.add_track(TrackKind::Audio, &mut *ids)
                    });
                    if let (Some(vt), Some(audio_targets)) = (vt, at_)
                        && let Some(plan) =
                            Timeline::source_edit_plan(&video_marks, total, seq_in, seq_out, playhead, fd, false)
                    {
                        let shift = plan.source.start - split_video;
                        tl.split_source_edit(
                            &SplitSourceEdit {
                                media,
                                name: name.clone(),
                                video_in: plan.source.start,
                                audio_in: (split_audio + shift).max(Time::ZERO),
                                out: plan.source.end(),
                                media_duration: Some(total),
                                initial_scale: fit,
                                video_tracks: vt,
                                audio_tracks: audio_targets,
                                at: plan.at,
                                mode,
                            },
                            ids,
                        )?;
                        end_time = plan.at + plan.source.duration;
                        return Ok(());
                    }
                }
                // Fit to Fill: the whole source In..Out (or clip) retimed into the sequence In..Out.
                if fit_to_fill && !still {
                    let Some(f) = Timeline::fit_to_fill_plan(&m, total, seq_in, seq_out, fd) else {
                        needs_sequence_range = true;
                        return Err(EditError::EmptyClip);
                    };
                    if place_on_top {
                        targets = vec![new_track(tl, ids, TimeRange::new(f.at, f.length))];
                    }
                    place.source = f.source;
                    place.speed = f.speed;
                    three_point_edit(tl, &place, &targets, f.at, mode, false, ids)?;
                    end_time = f.at + f.length;
                    return Ok(());
                }
                let used = four_point_fit.apply(&m, seq_in, seq_out);
                let plan = Timeline::source_edit_plan(
                    &used.source,
                    total,
                    used.sequence_in,
                    used.sequence_out,
                    playhead,
                    fd,
                    still,
                )
                .ok_or(EditError::EmptyClip)?;
                four_point = plan.used_four_point_default;
                let d = plan.source.duration;
                if place_on_top {
                    targets = vec![new_track(tl, ids, TimeRange::new(plan.at, d))];
                }
                place.source = plan.source;
                three_point_edit(tl, &place, &targets, plan.at, mode, false, ids)?;
                end_time = plan.at + d;
                Ok(())
            })
        });
        if needs_sequence_range {
            self.set_error("Fit to Fill needs a sequence In and Out; set both, then try again.");
        }
        if no_target {
            self.set_error("Nothing is patched: click the source chips left of the track headers to connect them.");
        }
        if done {
            self.seek_sequence(end_time);
        }
        if done && four_point {
            self.set_error("Four marks set: used the sequence In/Out and the source In (Fit to Fill in the Source menu retimes the source into the range instead).");
        }
        done
    }

    /// Play In to Out (Option+K): plays the sequence In..Out range (the whole sequence without marks), stops at Out, or
    /// loops. With `preroll` / `postroll` it starts that long before In and ends that long after Out, clamped to the sequence.
    // Swift: EditorSession+SourceEdit.swift:131
    pub fn play_in_to_out(&mut self, preroll: Time, postroll: Time) {
        let Some(t) = self.active_timeline() else { return };
        let mut range = t.in_out.filter(|r| !r.is_empty());
        if let Some(r) = range
            && (preroll > Time::ZERO || postroll > Time::ZERO)
        {
            range = Some(PlaybackBounds::extended(r, preroll, postroll, t.duration()).unwrap_or(r));
        }
        self.start_range(range, range.map_or(Time::ZERO, |r| r.start), None);
    }

    /// Play to Out: from the playhead to Out (the sequence end when only In is set); nothing when the playhead is already past it.
    // Swift: EditorSession+SourceEdit.swift:141
    pub fn play_to_out(&mut self) -> bool {
        let Some(io) = self.active_timeline().and_then(|t| t.export_range()) else { return false };
        if self.playhead >= io.end() {
            return false;
        }
        let here = self.playhead;
        self.start_range(Some(TimeRange::from_end(here, io.end())), here, None);
        true
    }

    /// Shift+K, Play Around: from `preroll` before the playhead to `postroll` after it; at the end the playhead goes
    /// back to where it was.
    // Swift: EditorSession+SourceEdit.swift:150
    pub fn play_around(&mut self, preroll: Time, postroll: Time) {
        let Some(t) = self.active_timeline() else { return };
        let here = self.playhead;
        let Some(range) = PlaybackBounds::play_around(here, preroll, postroll, t.duration()) else { return };
        self.start_range(Some(range), range.start, Some(here));
    }

    fn start_range(&mut self, range: Option<TimeRange>, from: Time, return_to: Option<Time>) {
        if self.is_playing {
            self.stop_playback();
        }
        self.seek(from);
        self.apply_shuttle(sq_core_edit::playback::ShuttleAction::SetRate(
            sq_core_edit::playback::PlaybackRate::whole(1),
        ));
        // After starting playback, which clears the range.
        let mut b = self.bounds;
        b.set_range(range);
        b.return_to = if range.is_none() { None } else { return_to };
        self.set_bounds(b);
    }

    /// Loop toggle of the transport.
    // Swift: EditorSession+SourceEdit.swift:164
    pub fn toggle_loop(&mut self) {
        let mut b = self.bounds;
        b.loop_playback = !b.loop_playback;
        self.set_bounds(b);
    }

    /// Option+I: the sequence In goes away (Out stays). Both cleared: no range at all.
    // Swift: EditorSession+SourceEdit.swift:170
    pub fn clear_in(&mut self) {
        if self.active_timeline().is_none_or(|t| t.explicit_marks().0.is_none()) {
            return;
        }
        self.attempt("Clear In", None, |t| {
            t.clear_in();
            Ok(())
        });
    }

    /// Option+O: the sequence Out goes away (In stays, the range then runs to the end of the sequence).
    // Swift: EditorSession+SourceEdit.swift:176
    pub fn clear_out(&mut self) {
        if self.active_timeline().is_none_or(|t| t.explicit_marks().1.is_none()) {
            return;
        }
        self.attempt("Clear Out", None, |t| {
            t.clear_out();
            Ok(())
        });
    }

    /// New Sequence From Clip: a sequence in the clip's own format holding the clip; it becomes the active one.
    // Swift: EditorSession+SourceEdit.swift:184
    pub fn new_sequence_from_media(&mut self, media: Id) -> Option<Id> {
        let made = self.with_ids(|s, ids| s.project().sequence_from_media(media, None, ids));
        let Some(mut t) = made else {
            self.set_error("That clip cannot become a sequence yet.");
            return None;
        };
        t.set_edit_mode(self.new_sequence_edit_mode);
        let id = t.id;
        self.perform("New Sequence From Clip", None, |p| {
            p.timelines.push(t);
            p.normalize_bins();
        });
        self.set_active_timeline(id);
        Some(id)
    }

    /// Replace Footage / Link Media: `new_ref` (probed from the new file) takes over the item `id`. One undo step.
    // Swift: EditorSession+SourceEdit.swift:197
    pub fn replace_footage(&mut self, id: Id, new_ref: &MediaRef) {
        self.requested_media.remove(&id); // so `sync_media` opens the new file now, not on the first decode
        self.perform("Replace Media", None, |p| {
            p.replace_media(id, new_ref);
        });
    }

    /// Dragging the In grip on the Program monitor strip: sets that mark at the frame `t`. One undo step per drag.
    // Swift: EditorSession+SourceEdit.swift:206
    pub fn set_in_point(&mut self, t: Time) {
        if self.active_timeline().is_none() {
            return;
        }
        self.attempt("Mark In", None, |tl| {
            tl.mark_in_at(t.max(Time::ZERO));
            Ok(())
        });
    }

    /// Dragging the Out grip: the frame is the last one inside. One undo step per drag.
    // Swift: EditorSession+SourceEdit.swift:210
    pub fn set_out_point(&mut self, t: Time) {
        if self.active_timeline().is_none() {
            return;
        }
        self.attempt("Mark Out", None, |tl| {
            tl.mark_out_at(t.max(Time::ZERO));
            Ok(())
        });
    }

    /// Drop of a drag on the In/Out band (ruler or Program strip): one undo step. With `part` (Program strip) a newly
    /// dragged range sets both marks and an edge or body drag keeps an In-only or Out-only mark; without it (ruler)
    /// the part is read from the range.
    // Swift: EditorSession+SourceEdit.swift:219
    pub fn move_in_out(&mut self, r: TimeRange, part: Option<MarkedRangeDragPart>) {
        if self.active_timeline().is_none() {
            return;
        }
        self.attempt("Move In and Out", None, |t| {
            match part {
                Some(p) => t.drag_marked_range_part(r, p),
                None => t.drag_marked_range(r),
            }
            Ok(())
        });
    }

    // MARK: Source patch

    /// The active sequence's patch (default: video to V1, audio to A1, both connected).
    // Swift: EditorSession+SourcePatch.swift:9
    pub fn source_patch(&self) -> sq_core_model::SourcePatch {
        self.active_timeline().map(|t| t.source_patch()).unwrap_or_default()
    }

    /// Click on a patch chip: disconnects that stream, or connects it again to the same track.
    // Swift: EditorSession+SourcePatch.swift:12
    pub fn toggle_source_patch(&mut self, kind: TrackKind) {
        if self.active_timeline_id.is_none() {
            return;
        }
        let mut p = self.source_patch();
        p.toggle_connection(kind);
        let stream = if kind == TrackKind::Video { "Video" } else { "Audio" };
        let slot = if kind == TrackKind::Video { &p.video } else { &p.audio };
        let name = format!("{} Source {stream}", if slot.is_connected { "Connect" } else { "Disconnect" });
        self.set_source_patch(p, &name);
    }

    /// Chip dragged onto track `track`: that stream is patched there (and connected). Another kind changes nothing.
    // Swift: EditorSession+SourcePatch.swift:21
    pub fn patch_source(&mut self, kind: TrackKind, track: Id) {
        let Some(t) = self.active_timeline() else { return };
        let old = self.source_patch();
        let mut p = old.clone();
        p.patch(kind, track, t);
        if p != old {
            self.set_source_patch(p, "Patch Source");
        }
    }

    /// Option+click on a chip: only that stream stays connected (again: both).
    // Swift: EditorSession+SourcePatch.swift:30
    pub fn solo_source_patch(&mut self, kind: TrackKind) {
        if self.active_timeline_id.is_none() {
            return;
        }
        let old = self.source_patch();
        let mut p = old.clone();
        p.solo(kind);
        if p != old {
            let name = format!("Solo Source {}", if kind == TrackKind::Video { "Video" } else { "Audio" });
            self.set_source_patch(p, &name);
        }
    }

    /// Shift+drag of a chip: this stream goes to `track`, the other one moves by the same number of tracks.
    // Swift: EditorSession+SourcePatch.swift:39
    pub fn patch_source_both(&mut self, kind: TrackKind, track: Id) {
        let Some(t) = self.active_timeline() else { return };
        let old = self.source_patch();
        let mut p = old.clone();
        p.patch_both(kind, track, t);
        if p != old {
            self.set_source_patch(p, "Patch Source");
        }
    }

    fn set_source_patch(&mut self, p: sq_core_model::SourcePatch, name: &str) {
        let ok = self.attempt(name, None, |t| {
            t.set_source_patch(p);
            Ok(())
        });
        if ok {
            self.notify(Change::SOURCE_PATCH);
        }
    }

    // MARK: Replace edits

    /// Replace edit (Option-drop of a Project item onto a clip): the clip keeps position, length, effects and keys and
    /// plays the dropped media. The new media starts at its In mark (or its start); with `match_source_time`
    /// (Shift+Option) the frame the Source monitor shows lines up with the sequence playhead instead. One undo step;
    /// false = refused (reported).
    // Swift: EditorSession+ReplaceMedia.swift:7
    pub fn replace_media(&mut self, clip: Id, media: Id, match_source_time: Option<Time>) -> bool {
        let Some(r) = self.project().media(media).cloned() else {
            self.set_error("That item is not in the project.");
            return false;
        };
        let Some(total) = media_total(&r) else {
            self.set_error("That item has no known length yet.");
            return false;
        };
        let m = replacement_media(&r, total);
        let alignment = match match_source_time {
            Some(t) => ReplaceAlignment::MatchFrame { media_time: t, timeline_time: self.playhead },
            None => ReplaceAlignment::ClipStart {
                source_in: Timeline::source_edit_range(&self.project().source_marks_for(r.id), total)
                    .map_or(Time::ZERO, |x| x.start),
            },
        };
        self.attempt("Replace Clip", None, |tl| tl.replace_media(clip, &m, alignment))
    }

    /// Replace edit with several selected items: Premiere uses the first one; we also say so in the status line instead
    /// of dropping the rest silently. Empty = refused.
    // Swift: EditorSession+ReplaceMedia.swift:22
    pub fn replace_media_with_first_of(&mut self, clip: Id, ids: &[Id], match_source_time: Option<Time>) -> bool {
        let Some(&first) = ids.first() else { return false };
        if !self.replace_media(clip, first, match_source_time) {
            return false;
        }
        if ids.len() > 1 {
            self.set_error(format!("Replaced with the first of {} items.", ids.len()));
        }
        true
    }

    /// Replace edit with a sequence (Option-drop of a sequence): the clip plays it as a nested clip from its start,
    /// keeping position, length and effects. One undo step; false = refused (reported).
    // Swift: EditorSession+ReplaceMedia.swift:32
    pub fn replace_with_sequence(&mut self, clip: Id, sequence: Id) -> bool {
        let Some(host) = self.active_timeline_id else { return false };
        let r = self.with_ids(|s, ids| {
            s.try_perform("Replace Clip", None, |p| p.replace_with_sequence(clip, sequence, host, ids))
        });
        match r {
            Ok(()) => true,
            Err(e) => {
                self.set_error(match e {
                    EditError::InsufficientMedia => "That sequence is shorter than the clip it replaces.".to_string(),
                    EditError::EmptyClip => "That sequence is empty.".to_string(),
                    e => Self::message_for(&e),
                });
                false
            }
        }
    }

    /// True when a four-mark Source edit needs the Fit Clip choice: both Source marks, both sequence marks, and the two
    /// ranges differ in length (equal lengths fit exactly whatever is ignored).
    // Swift: EditorSession+ReplaceMedia.swift:47
    pub fn four_point_needs_choice(&self, media: Id, marks: Option<&SourceMarks>) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let Some(src) = marks.cloned().unwrap_or_else(|| self.project().source_marks_for(media)).range() else {
            return false;
        };
        let (Some(i), Some(o)) = t.explicit_marks() else { return false };
        o > i && (o - i) != src.duration
    }

    /// Fast Cut replace (Clip > Replace at Playhead / from Start / from End / with Retime): the main-track clip `clip`
    /// plays `media` (its In..Out marks, whole media when unmarked) in one of the four `ReplaceMode`s. The clip keeps
    /// its id, place and length, so nothing ripples. `source_anchor` is the media time that sits on the playhead
    /// (`AtPlayhead` only, the In mark when `None`). Media shorter than the clip is not refused: the clip gets shorter
    /// and the status line says so. One undo step; false = refused (reported).
    // Swift: EditorSession+ReplaceModes.swift:10
    pub fn replace_on_main_track(
        &mut self,
        clip: Id,
        media: Id,
        mode: ReplaceMode,
        source_anchor: Option<Time>,
    ) -> bool {
        let Some(t) = self.active_timeline().filter(|t| t.is_fast_cut()) else {
            self.set_error("Replace modes work in a Fast Cut sequence.");
            return false;
        };
        let Some(r) = self.project().media(media).cloned() else {
            self.set_error("That item is not in the project.");
            return false;
        };
        if r.info.as_ref().is_some_and(|i| i.is_still) {
            self.set_error("A still image has no length to fit: use Replace Clip from Project.");
            return false;
        }
        let Some(total) = media_total(&r) else {
            self.set_error("That item has no known length yet.");
            return false;
        };
        let Some(range) = Timeline::source_edit_range(&self.project().source_marks_for(r.id), total) else {
            self.set_error("Nothing to edit: the In and Out points leave no range.");
            return false;
        };
        let fit = r
            .info
            .as_ref()
            .and_then(|i| i.video.as_ref())
            .map_or(1.0, |v| t.format.fit_scale(v.display_width(), v.display_height()));
        let has_video = r.info.as_ref().is_some_and(|i| i.video.is_some()) || r.info.is_none();
        let at = self.playhead;
        let anchor = source_anchor.unwrap_or(range.start);
        let mut outcome = None;
        let ok = self.with_ids(|s, ids| {
            let mut clips: Vec<Clip> = Vec::new();
            if has_video {
                let mut v = Clip::new(ids.next_id(), &r.name, r.id, TrackKind::Video, range, Time::ZERO);
                v.media_duration = Some(total);
                if (fit - 1.0).abs() > 1e-12 {
                    v.animation.scale = AnimatedProperty::new(Vec2::new(fit, fit));
                }
                clips.push(v);
            }
            if r.info.as_ref().is_some_and(|i| i.audio.is_some()) {
                let mut a = Clip::new(ids.next_id(), &r.name, r.id, TrackKind::Audio, range, Time::ZERO);
                a.media_duration = Some(total);
                clips.push(a);
            }
            s.attempt(mode.title(), None, |tl| {
                outcome = Some(tl.replace_on_main_track_mode(clip, &clips, mode, at, anchor, ids)?);
                Ok(())
            })
        });
        if !ok {
            return false;
        }
        if let Some(w) = outcome.and_then(|o| o.warning()) {
            self.set_error(w);
        }
        true
    }

    // MARK: Reel Fill

    /// Slots of the active sequence's reel (base video track clips in time order).
    // Swift: EditorSession+ReelFill.swift:5
    pub fn reel_slot_count(&self) -> usize {
        self.active_timeline().map_or(0, |t| t.reel_slots().len())
    }

    /// Reel to fillable template: the active sequence is the template. Its base-track clips are slots; `media_ids`
    /// pour into them in order, each from its first frame, keeping the slot's position, length, effects, keys and
    /// transitions. With `into_copy` the template stays untouched and a new sequence "<name> Fill" holds the result and
    /// becomes active. One undo step. `None` = refused (reported); otherwise what was filled.
    // Swift: EditorSession+ReelFill.swift:11
    pub fn fill_reel(&mut self, media_ids: &[Id], into_copy: bool) -> Option<ReelFillReport> {
        let src = self.active_timeline()?.clone();
        if src.reel_slots().is_empty() {
            self.set_error("This sequence has no clips to use as slots.");
            return None;
        }
        let mut media: Vec<ReplacementMedia> = Vec::new();
        for id in media_ids {
            let Some(r) = self.project().media(*id) else {
                self.set_error("An item has no known length yet.");
                return None;
            };
            let still = r.info.as_ref().is_some_and(|i| i.is_still);
            // A still has no length of its own: it takes the slot's.
            let total = if still { Some(media_total(r).unwrap_or(Time::ZERO)) } else { media_total(r) };
            let Some(total) = total else {
                self.set_error("An item has no known length yet.");
                return None;
            };
            media.push(replacement_media(r, total));
        }
        let mut work = src.clone();
        if into_copy {
            let taken: Vec<String> = self.project().timelines.iter().map(|t| t.name.clone()).collect();
            let name = ProjectTemplate::free_name(&format!("{} Fill", src.name), &taken);
            work = self.with_ids(|_, ids| src.copy_with_fresh_ids(&name, ids));
        }
        let slots = work.reel_slots();
        let report = work.fill_reel(&slots, &media);
        if report.filled.is_empty() {
            self.set_error("No slot could take that media.");
            return None;
        }
        if into_copy {
            let id = work.id;
            self.perform("Fill Reel", None, |p| {
                p.timelines.push(work);
                p.normalize_bins();
            });
            self.set_active_timeline(id);
        } else if !self.attempt("Fill Reel", None, |tl| {
            *tl = work;
            Ok(())
        }) {
            return None;
        }
        Some(report)
    }
}

use sq_core_edit::timeline_split_source::SplitSourceEdit;
