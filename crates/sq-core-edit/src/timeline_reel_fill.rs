// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+ReelFill.swift (Reel to fillable template)

use crate::timeline_edits::TimelineEditsExt as _;
use crate::timeline_replace_media::{ReplaceAlignment, ReplacementMedia, TimelineReplaceMediaExt as _};
use sq_core_model::{Clip, ClipEdge, ClipFootageColor, ClipSpeed, EditError, Timeline, TrackKind, floored_to_frame};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeMap;

/// What a reel fill did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReelFillReport {
    /// Slots that now play new media.
    pub filled: Vec<Id>,
    /// Filled slots whose new media was shorter than the slot: the clip was cut short (a gap follows it).
    pub shortened: Vec<Id>,
    /// Slots that could not take their media (generator, nest, held frame, locked track, wrong stream).
    pub skipped: Vec<Id>,
    /// Slots left with their old media because the list had fewer items.
    pub unfilled: Vec<Id>,
    /// Media items beyond the last slot.
    pub unused_media: usize,
}

/// Reel slots.
pub trait TimelineReelFillExt {
    /// The slots of a reel: the fillable clips of the base video track (the first video track with such clips) in time
    /// order. A reel is a plain sequence; every clip on its base track is a slot that keeps position, length, speed,
    /// effects, keys and transitions when new media is poured in.
    fn reel_slots(&self) -> Vec<Id>;

    /// Fills the slots in order with `media` (media i into slot i, each from its first frame). Media shorter than the slot
    /// shortens the slot (tail trim, at normal speed only) instead of failing; slots that cannot take their media are
    /// skipped and left as they were. Nothing is added or removed, so the template stays reusable.
    fn fill_reel(&mut self, slots: &[Id], media: &[ReplacementMedia]) -> ReelFillReport;

    /// An independent copy for a new sequence: fresh ids for the sequence, tracks, clips, links, bundles and transitions
    /// (the remap a title template gets when it is applied). A grade link must not reach back into the template: members
    /// keep their grouping under new link ids.
    fn copy_with_fresh_ids(&self, name: &str, ids: &mut dyn IdSource) -> Timeline;

    /// A copy with fresh ids for the timeline, every track, clip, transition, link and bundle. Returns the old to new clip
    /// id map so callers can repoint what refers to clips of the copy.
    fn copy_with_fresh_ids_mapped(&self, ids: &mut dyn IdSource) -> (Timeline, BTreeMap<Id, Id>);
}

/// A still in a slot: the slot keeps position, timeline length, effects and keys but becomes a still clip (no source range
/// to speak of, normal speed). Linked partners that played the old media (its audio) are removed, a still is silent; the
/// slot and any remaining partner lose the link. False (nothing changed) for a locked track, a locked partner track, a
/// nest/generator slot or a slot without a video stream.
fn pour_still(tl: &mut Timeline, m: &ReplacementMedia, id: Id) -> bool {
    let Some(ti) = tl.tracks.iter().position(|t| t.clip(id).is_some()) else { return false };
    let Some(old) = tl.tracks[ti].clip(id).cloned() else { return false };
    if !m.has_video
        || tl.tracks[ti].is_locked
        || old.kind != TrackKind::Video
        || old.is_nested()
        || old.is_generator()
        || old.hold_frame.is_some()
    {
        return false;
    }
    let mut work = tl.clone();
    if let Some(link) = old.link {
        for pi in (0..work.tracks.len()).filter(|pi| *pi != ti) {
            for p in work.tracks[pi].clips().to_vec().into_iter().filter(|p| p.link == Some(link)) {
                if p.media == old.media && p.kind != old.kind {
                    if work.tracks[pi].is_locked {
                        return false;
                    }
                    work.tracks[pi].remove(p.id);
                } else if !work.tracks[pi].is_locked {
                    // a locked track's clip stays exactly as it was
                    work.tracks[pi].replace(Clip { link: None, ..p });
                }
            }
        }
    }
    let n = Clip {
        media: m.id,
        name: m.name.clone(),
        is_still: true,
        media_duration: None,
        source: TimeRange::new(Time::ZERO, old.duration()),
        speed: ClipSpeed::NORMAL,
        speed_keys: None,
        reversed: false,
        link: None,
        footage_color: ClipFootageColor::default(),
        markers: None,
        ..old
    };
    work.tracks[ti].replace(n);
    *tl = work;
    true
}

/// Pours one non-still medium into slot `id` on `tl`; the caller keeps `tl` unchanged on error.
fn pour_media(tl: &mut Timeline, m: &ReplacementMedia, id: Id) -> Result<bool, EditError> {
    let mut old = tl.find(id).map(|f| f.clip).ok_or(EditError::ClipNotFound)?;
    if old.is_still {
        // A slot that holds a still takes video again: it becomes a normal clip of the slot length, then `replace_media`
        // below swaps in the new media (`replace_media` itself still refuses stills).
        let ti = tl.tracks.iter().position(|t| t.clip(id).is_some()).filter(|ti| !tl.tracks[*ti].is_locked);
        let ti = ti.ok_or(EditError::TrackLocked)?;
        let c = Clip {
            is_still: false,
            media_duration: Some(m.duration),
            source: TimeRange::new(Time::ZERO, old.duration()),
            speed: ClipSpeed::NORMAL,
            ..old
        };
        tl.tracks[ti].replace(c.clone());
        old = c;
    }
    // Link partners that `replace_media` will not swap (other media, no matching stream) stay exactly as they were.
    let untouched: Vec<Clip> = tl
        .tracks
        .iter()
        .flat_map(|t| t.clips())
        .filter(|p| {
            if old.link.is_none() || p.link != old.link || p.id == id {
                return false;
            }
            let takes = p.media == old.media
                && p.kind != old.kind
                && if p.kind == TrackKind::Video { m.has_video } else { m.has_audio };
            !takes
        })
        .cloned()
        .collect();
    let mut short = false;
    let usable = floored_to_frame(m.duration, tl.frame_duration());
    if usable < old.source.duration {
        if old.speed != ClipSpeed::NORMAL {
            return Err(EditError::InsufficientMedia);
        }
        tl.trim(id, ClipEdge::Tail, usable - old.source.duration)?;
        short = true;
    }
    tl.replace_media(id, m, ReplaceAlignment::ClipStart { source_in: Time::ZERO })?;
    for p in untouched {
        if let Some(ti) = tl.tracks.iter().position(|t| t.clip(p.id).is_some()) {
            tl.tracks[ti].replace(p);
        }
    }
    Ok(short)
}

impl TimelineReelFillExt for Timeline {
    fn reel_slots(&self) -> Vec<Id> {
        for t in self.tracks.iter().filter(|t| t.kind == sq_core_model::TrackKind::Video) {
            let mut slots: Vec<&sq_core_model::Clip> =
                t.clips().iter().filter(|c| !c.is_nested() && !c.is_generator() && c.hold_frame.is_none()).collect();
            if !slots.is_empty() {
                slots.sort_by_key(|c| c.start);
                return slots.into_iter().map(|c| c.id).collect();
            }
        }
        Vec::new()
    }

    fn fill_reel(&mut self, slots: &[Id], media: &[ReplacementMedia]) -> ReelFillReport {
        let mut report = ReelFillReport::default();
        for (i, id) in slots.iter().enumerate() {
            let Some(m) = media.get(i) else {
                report.unfilled.push(*id);
                continue;
            };
            if m.is_still {
                // `replace_media` refuses stills (different clip model), so a still gets its own path here.
                if pour_still(self, m, *id) {
                    report.filled.push(*id);
                } else {
                    report.skipped.push(*id);
                }
                continue;
            }
            let mut work = self.clone();
            match pour_media(&mut work, m, *id) {
                Ok(short) => {
                    *self = work;
                    report.filled.push(*id);
                    if short {
                        report.shortened.push(*id);
                    }
                }
                Err(_) => report.skipped.push(*id),
            }
        }
        report.unused_media = media.len().saturating_sub(slots.len());
        report
    }

    fn copy_with_fresh_ids(&self, name: &str, ids: &mut dyn IdSource) -> Timeline {
        let mut t = self.copy_with_fresh_ids_mapped(ids).0;
        t.name = name.to_string();
        let mut link_map: BTreeMap<Id, Id> = BTreeMap::new();
        for track in &mut t.tracks {
            track.map_clips_keeping_timing(|c| {
                let mut c = c.clone();
                if let Some(l) = c.grade_link {
                    c.grade_link = Some(*link_map.entry(l).or_insert_with(|| ids.next_id()));
                }
                c
            });
        }
        t
    }

    fn copy_with_fresh_ids_mapped(&self, ids: &mut dyn IdSource) -> (Timeline, BTreeMap<Id, Id>) {
        let mut inner = self.clone();
        inner.id = ids.next_id();
        let mut clip_map: BTreeMap<Id, Id> = BTreeMap::new();
        let mut group_map: BTreeMap<Id, Id> = BTreeMap::new();
        let mut track_ids: BTreeMap<Id, Id> = BTreeMap::new();
        for track in &mut inner.tracks {
            let old = track.id;
            track.id = ids.next_id();
            track_ids.insert(old, track.id);
            track.map_clips_keeping_timing(|c| {
                let mut c = c.clone();
                let n = *clip_map.entry(c.id).or_insert_with(|| ids.next_id());
                if c.media == c.id {
                    c.media = n; // generators use their own id as media
                }
                c.id = n;
                c.link = c.link.map(|l| *group_map.entry(l).or_insert_with(|| ids.next_id()));
                c.bundle = c.bundle.map(|b| *group_map.entry(b).or_insert_with(|| ids.next_id()));
                c
            });
            for tr in &mut track.transitions {
                tr.id = ids.next_id();
                tr.outgoing = tr.outgoing.map(|c| clip_map.get(&c).copied().unwrap_or(c));
                tr.incoming = tr.incoming.map(|c| clip_map.get(&c).copied().unwrap_or(c));
            }
        }
        inner.remap_picture_masks(&track_ids);
        inner.remap_attachments(&clip_map, None, false);
        (inner, clip_map)
    }
}
