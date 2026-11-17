//! Port of `Nesting+PlaceClips.swift`: placing a sequence as its individual clips instead of one nested clip (Premiere's
//! "Insert and overwrite sequences as nests or individual clips" switched to individual clips). Reuses the paste path:
//! copies get new ids, links and bundles survive between copies, missing tracks are created, transitions between copied
//! clips come along.

use crate::nesting_place::SequencePlacement;
use crate::timeline_add_track::AddTrackExt as _;
use crate::timeline_clipboard::{ClipboardEntry, TimelineClipboard, TimelineClipboardExt as _};
use crate::timeline_magnetic::{MagneticExt as _, MagneticScope, MagneticStay};
use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use sq_core_masks::PictureMaskTimelineExt as _;
use sq_core_model::{EditError, Project, ThreePointMode, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeSet, HashMap};

/// A sequence's clips ready to place: the clipboard plus the length the sequence occupies (its In/Out range, or the whole
/// sequence), both on the host's frame grid.
#[derive(Clone, Debug, PartialEq)]
pub struct SequenceClips {
    /// The clips with their lanes and offsets.
    pub clipboard: TimelineClipboard,
    /// Span a placement occupies (and an insert ripples by), from the range start; includes leading and trailing gaps.
    pub span: Time,
}

/// `extension Project` of `Nesting+PlaceClips.swift`.
pub trait NestingPlaceClipsExt {
    /// The clips of `sequence` cut to its In/Out when set (clips crossing a mark are cropped), positions relative to the
    /// range start, edges snapped to the host's frame duration `fd` (start up, end down; clips that vanish are dropped).
    /// Clips on hidden video tracks and muted audio tracks are left out. Transitions survive only between uncropped
    /// clips. `None` for an unknown sequence or when nothing lies in the range.
    fn sequence_clip_board(&self, sequence: Id, fd: Time) -> Option<SequenceClips>;

    /// Like `place_sequences`, but each sequence lands as its own clips, one after another from `time`, as an overwrite or
    /// an insert (ripples by the whole span). Without `video_track` the clips keep their lanes (V1 to V1, A2 to A2); with
    /// it the sequence's first video lane lands on that track (audio on the matching audio track) and the rest keep their
    /// offsets; `new_track` puts the first lane on a new track of that kind (audio: only the audio clips). In Fast Cut
    /// attached clips follow their hosts. Same refusals as `place_sequences`; one edit, a refusal changes nothing.
    /// Returns the end of the last sequence.
    fn place_sequence_clips(
        &mut self,
        sequences: &[Id],
        at: &SequencePlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
}

impl NestingPlaceClipsExt for Project {
    fn sequence_clip_board(&self, sequence: Id, fd: Time) -> Option<SequenceClips> {
        let t = self.timeline(sequence)?;
        let raw =
            t.in_out.filter(|r| r.duration > Time::ZERO).unwrap_or_else(|| TimeRange::new(Time::ZERO, t.duration()));
        // Every cut point snaps once, to the nearest host frame, so the end of a clip and the start of its neighbor stay
        // the same value (no gaps or overlaps at off-grid cuts) and transitions at the cut survive.
        let (rs, re) = (raw.start.snapped(fd), raw.end().snapped(fd));
        if re <= rs {
            return None;
        }
        let mut entries: Vec<ClipboardEntry> = Vec::new();
        let mut whole: BTreeSet<Id> = BTreeSet::new();
        for kind in [TrackKind::Video, TrackKind::Audio] {
            for (lane, track) in t.tracks.iter().filter(|x| x.kind == kind).enumerate() {
                if (kind == TrackKind::Video && !track.is_visible) || (kind == TrackKind::Audio && track.is_muted) {
                    continue;
                }
                for c in track.clips() {
                    if c.timeline().intersection(&raw).is_none() {
                        continue;
                    }
                    let inside = c.start >= raw.start && c.timeline().end() <= raw.end();
                    let cut = if inside { Some(c.clone()) } else { c.cropped(raw) };
                    let Some(cut) = cut else { continue };
                    let s = cut.start.snapped(fd).max(rs);
                    let e = cut.timeline().end().snapped(fd).min(re);
                    if e <= s {
                        continue; // only a clip that truly collapses to nothing is dropped
                    }
                    let mut kept = cut;
                    if kept.speed_keys.is_none() && (kept.start != s || kept.timeline().end() != e) {
                        let len = kept.speed.scale(e - s); // sub-frame stretch so the clip fills exactly [s, e)
                        if kept.reversed {
                            kept.source.start = kept.source.end() - len;
                        }
                        kept.source.duration = len;
                    }
                    kept.start = s;
                    if inside {
                        whole.insert(c.id);
                    }
                    entries.push(ClipboardEntry { clip: kept, offset: s - rs, lane });
                }
            }
        }
        if entries.is_empty() {
            return None;
        }
        let present: BTreeSet<Id> = entries.iter().map(|e| e.clip.id).collect();
        let transitions = t
            .tracks
            .iter()
            .flat_map(|x| x.transitions.iter())
            .filter(|tr| {
                [tr.outgoing, tr.incoming].into_iter().flatten().all(|c| whole.contains(&c) && present.contains(&c))
            })
            .cloned()
            .collect();
        let clips: Vec<_> = entries.iter().map(|e| e.clip.clone()).collect();
        let copied: BTreeSet<Id> =
            t.tracks.iter().filter(|x| x.kind == TrackKind::Video && x.is_visible).map(|x| x.id).collect();
        let picture_track_lanes = t.picture_track_lanes(&clips, Some(&copied));
        Some(SequenceClips {
            clipboard: TimelineClipboard { entries, transitions, picture_track_lanes },
            span: re - rs,
        })
    }

    fn place_sequence_clips(
        &mut self,
        sequences: &[Id],
        at: &SequencePlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let SequencePlacement { host, time, video_track, new_track, mode } = *at;
        let fd = self.timeline(host).ok_or(EditError::TimelineNotFound)?.frame_duration();
        if sequences.is_empty() {
            return Err(EditError::EmptyClip);
        }
        for id in sequences {
            if self.timeline(*id).is_none() {
                return Err(EditError::EmptyClip);
            }
            if self.would_create_cycle(*id, host) {
                return Err(EditError::NestingCycle);
            }
        }
        let mut boards: Vec<SequenceClips> = Vec::new();
        for id in sequences {
            let mut sc = self.sequence_clip_board(*id, fd).ok_or(EditError::EmptyClip)?;
            if new_track == Some(TrackKind::Audio) {
                sc.clipboard.entries.retain(|e| e.clip.kind == TrackKind::Audio);
                let kept: BTreeSet<Id> = sc.clipboard.entries.iter().map(|e| e.clip.id).collect();
                sc.clipboard
                    .transitions
                    .retain(|t| [t.outgoing, t.incoming].into_iter().flatten().all(|c| kept.contains(&c)));
                if sc.clipboard.is_empty() {
                    return Err(EditError::EmptyClip);
                }
            }
            boards.push(sc);
        }
        let mut end = time;
        self.edit(host, |tl| {
            let mut at = time.snapped(fd);
            let mut lanes: Option<HashMap<TrackKind, usize>> = None;
            if let Some(kind) = new_track {
                let id = tl.add_track(kind, ids);
                lanes = lane_lanes(tl, id, &boards[0].clipboard);
            } else if let Some(v) = video_track {
                lanes = lane_lanes(tl, v, &boards[0].clipboard);
            }
            for sc in &boards {
                let place = at;
                place_one(tl, sc, place, lanes.as_ref(), mode == ThreePointMode::Insert, ids)?;
                at = (place + sc.span).ceiled(fd);
            }
            end = at;
            Ok(())
        })?;
        Ok(end)
    }
}

/// The lane (per kind) the lowest used lane of the sequence lands on when it is dropped on `track`. A video track also
/// decides the audio lane (same ordinal); an audio track only the audio one.
fn lane_lanes(tl: &Timeline, track: Id, cb: &TimelineClipboard) -> Option<HashMap<TrackKind, usize>> {
    let kind = tl.track(track)?.kind;
    let index = tl.tracks.iter().filter(|t| t.kind == kind).position(|t| t.id == track)?;
    let mut out = HashMap::new();
    if cb.lowest_lane(kind).is_some() {
        out.insert(kind, index); // the first used lane lands on the track, offsets stay
    }
    if kind == TrackKind::Video && cb.lowest_lane(TrackKind::Audio).is_some() {
        out.insert(TrackKind::Audio, index);
    }
    Some(out)
}

/// One sequence placed at `place`: overwrite, or insert that opens a gap of the whole `span` first (so leading and trailing
/// gaps of the sequence ripple too) and then fills it. Fast Cut: runs in `magnetic_edit`; an insert landing on the main
/// track opens it (at most at its end, no hole), attached clips follow their hosts; anything else is an overwrite there and
/// the attached clips stay on their frame (the new clips yield to them off the main track).
fn place_one(
    tl: &mut Timeline,
    sc: &SequenceClips,
    place: Time,
    lanes: Option<&HashMap<TrackKind, usize>>,
    insert: bool,
    ids: &mut dyn IdSource,
) -> Result<(), EditError> {
    let cb = &sc.clipboard;
    let (true, Some(mi)) = (tl.is_fast_cut(), tl.main_track_index()) else {
        if insert {
            open_span(tl, sc.span, place, cb, lanes, ids)?;
        }
        tl.paste(cb, place, lanes, false, ids)?;
        return Ok(());
    };
    let on_main = landing_tracks(tl, cb, lanes).contains(&mi);
    let at = if on_main { place.min(tl.main_track_end()) } else { place };
    if insert && on_main {
        tl.magnetic_edit(MagneticScope::default(), ids, |t, ids| {
            open_span(t, sc.span, at, cb, lanes, ids)?;
            t.paste(cb, at, lanes, false, ids).map(|_| ())
        })
    } else {
        let scope = MagneticScope { stay: MagneticStay::All, ..MagneticScope::default() };
        tl.magnetic_edit(scope, ids, |t, ids| t.paste(cb, at, lanes, false, ids).map(|_| ()))
    }
}

/// Pushes everything at or after `t` later by `length` on the tracks the clipboard lands on and on every ripple track
/// (clips crossing `t` are split), like `insert`. Refuses locked target tracks.
fn open_span(
    tl: &mut Timeline,
    length: Time,
    t: Time,
    cb: &TimelineClipboard,
    lanes: Option<&HashMap<TrackKind, usize>>,
    ids: &mut dyn IdSource,
) -> Result<(), EditError> {
    let t = t.ceiled(tl.frame_duration()).max(Time::ZERO);
    let targets = landing_tracks(tl, cb, lanes);
    if targets.iter().any(|i| tl.tracks[*i].is_locked) {
        return Err(EditError::TrackLocked);
    }
    let mut work = tl.tracks.clone();
    let mut relinks = std::collections::BTreeMap::new();
    for (i, track) in work.iter_mut().enumerate() {
        if targets.contains(&i) || track.follows_ripple() {
            track.split_relinking(t, &mut relinks, ids)?;
            track.shift(t, length, &BTreeSet::new());
        }
    }
    tl.tracks = work;
    tl.open_caption_gap(t, length);
    Ok(())
}

/// Indices of the tracks the clipboard's clips land on (lanes beyond the existing tracks are not there yet).
fn landing_tracks(tl: &Timeline, cb: &TimelineClipboard, lanes: Option<&HashMap<TrackKind, usize>>) -> BTreeSet<usize> {
    let mut targets = BTreeSet::new();
    for k in [TrackKind::Video, TrackKind::Audio] {
        let Some(low) = cb.lowest_lane(k) else { continue };
        let shift = lanes.and_then(|l| l.get(&k)).map_or(low, |l| *l) as i64 - low as i64;
        let same: Vec<usize> = (0..tl.tracks.len()).filter(|i| tl.tracks[*i].kind == k).collect();
        for e in cb.entries.iter().filter(|e| e.clip.kind == k) {
            let lane = (e.lane as i64 + shift).max(0) as usize;
            if let Some(i) = same.get(lane) {
                targets.insert(*i);
            }
        }
    }
    targets
}
