// Swift: CaptionHandover.swift (the animation part waits for TextUnits, see NOTES.md), Captions.swift (`captions(at:)`, track names)
//! Hand-over between neighboring captions of one caption track: two captions that touch, or sit at most `GAP_FRAMES` frames
//! apart, never leave a frame without a caption. The Program monitor and the export burn-in both ask here, so they draw
//! the same picture.
//!
//! - The earlier caption holds through a small gap: its clip duration runs to the next caption's start (an out look ends there).
//! - While the later caption's in-animation shows nothing or is still fading in, the earlier one stays under it as a tail.
//! - A caption with nothing that close before or after it is untouched: full in, full out.

use crate::caption_item::CaptionItemExt;
use crate::caption_words::{CaptionTextMatch, CaptionWordEditExt};
use sq_core_model::{CaptionItem, CaptionTrack, EditError, KaraokeStyle, Timeline};
use sq_core_time::{Id, Time, TimeRange, text_search};

/// Namespace of the hand-over rule.
pub enum CaptionHandover {}

/// How a caption shows at one instant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Resolution {
    /// The caption's clip duration for its animation: its own, or up to the start of the caption it hands over to.
    pub duration: Time,
    /// The playhead is past the caption's own end, inside the small gap before the next caption.
    pub held: bool,
    /// The clip duration of the caption before it when that one hands over to this one (its start to this start); `None`
    /// when there is no such caption.
    pub tail_duration: Option<Time>,
}

impl CaptionHandover {
    /// Largest gap (in sequence frames) two captions still hand over across.
    pub const GAP_FRAMES: i64 = 2;

    /// True when `b` follows `a` closely enough to hand over (never for overlapping ranges).
    pub fn hands_over(a: &TimeRange, b: &TimeRange, frame_duration: Time) -> bool {
        let gap = b.start - a.end();
        gap >= Time::ZERO && gap <= frame_duration.max(Time::ZERO) * Self::GAP_FRAMES
    }

    /// How `current` shows at `t`, given its neighbors on the track (`previous` ends before it, `next` starts after it);
    /// `None` when it does not show at `t`.
    pub fn resolve(
        previous: Option<&TimeRange>,
        current: &TimeRange,
        next: Option<&TimeRange>,
        t: Time,
        frame_duration: Time,
    ) -> Option<Resolution> {
        if t < current.start {
            return None;
        }
        let mut end = current.end();
        if let Some(n) = next.filter(|n| Self::hands_over(current, n, frame_duration)) {
            end = n.start;
        }
        if t >= end {
            return None;
        }
        let tail = previous.filter(|p| Self::hands_over(p, current, frame_duration)).map(|p| current.start - p.start);
        Some(Resolution { duration: end - current.start, held: t >= current.end(), tail_duration: tail })
    }
}

/// What one caption track shows at one instant (`Timeline::caption_slots_at`).
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionSlot {
    /// The caption.
    pub item: CaptionItem,
    /// Its track.
    pub track: Id,
    /// Clip duration to animate `item` with.
    pub duration: Time,
    /// The playhead is past its own end (see `Resolution`).
    pub held: bool,
    /// The caption before `item` when it hands over to it: drawn under `item` at clip time `tail_duration`.
    pub tail: Option<CaptionItem>,
    /// Clip duration of the tail.
    pub tail_duration: Time,
}

/// A caption visible at one instant.
#[derive(Clone, Debug, PartialEq)]
pub struct ActiveCaption {
    /// The caption.
    pub item: CaptionItem,
    /// Its track.
    pub track: Id,
}

fn is_hidden(c: &CaptionItem) -> bool {
    c.range.is_empty() || c.is_blank()
}

/// Starts never go back and no caption starts before the one before it ends (zero-length ones only keep the order).
fn is_ordered(items: &[CaptionItem]) -> bool {
    let (mut start, mut end): (Option<Time>, Option<Time>) = (None, None);
    for c in items {
        if start.is_some_and(|s| c.range.start < s) {
            return false;
        }
        start = Some(c.range.start);
        if c.range.is_empty() {
            continue;
        }
        if end.is_some_and(|e| c.range.start < e) {
            return false;
        }
        end = Some(c.range.end());
    }
    true
}

/// `items` ordered (`is_ordered`): binary search for the last start at or before `t`.
fn slot_in(items: &[CaptionItem], track: Id, t: Time, frame_duration: Time) -> Option<CaptionSlot> {
    let lo = items.partition_point(|c| c.range.start <= t);
    let i = (0..lo).rev().find(|k| !is_hidden(&items[*k]))?;
    let n = (i + 1..items.len()).find(|k| !is_hidden(&items[*k]));
    let p = (0..i).rev().find(|k| !is_hidden(&items[*k]));
    let r = CaptionHandover::resolve(
        p.map(|k| &items[k].range),
        &items[i].range,
        n.map(|k| &items[k].range),
        t,
        frame_duration,
    )?;
    let tail = r.tail_duration.and(p).map(|k| items[k].clone());
    Some(CaptionSlot {
        item: items[i].clone(),
        track,
        duration: r.duration,
        held: r.held,
        tail,
        tail_duration: r.tail_duration.unwrap_or(Time::ZERO),
    })
}

/// One track prepared for lookups: checking that its captions are in order is one pass over them, done once here instead of
/// on every lookup.
#[derive(Clone, Debug)]
struct Lookup {
    id: Id,
    /// The captions to search, and whether they are in order (binary search, hand-over) or overlap (linear, none).
    items: Vec<CaptionItem>,
    ordered: bool,
}

impl Lookup {
    fn new(track: &CaptionTrack) -> Lookup {
        if is_ordered(track.items()) {
            return Lookup { id: track.id, items: track.items().to_vec(), ordered: true };
        }
        // Not sorted or overlapping as stored: what the burn-in is given (shown captions, by start).
        let mut items: Vec<CaptionItem> = track.items().iter().filter(|c| !is_hidden(c)).cloned().collect();
        items.sort_by_key(|c| c.range.start);
        let ordered = is_ordered(&items);
        Lookup { id: track.id, items, ordered }
    }

    fn slot(&self, t: Time, frame_duration: Time) -> Option<CaptionSlot> {
        if self.ordered {
            return slot_in(&self.items, self.id, t, frame_duration);
        }
        self.items.iter().find(|c| c.range.contains(t)).map(|c| CaptionSlot {
            item: c.clone(),
            track: self.id,
            duration: c.range.duration,
            held: false,
            tail: None,
            tail_duration: Time::ZERO,
        })
    }
}

/// `CaptionTrack.slot(at:frameDuration:)`.
pub trait CaptionTrackSlotExt {
    /// The caption this track shows at `t` with its hand-over. Blank and zero-length captions do not exist here (the
    /// export burn-in leaves them out the same way). A track whose captions overlap (only a decoded file can hold one)
    /// shows the first caption containing `t` and hands nothing over, exactly like `CaptionBurnIn`.
    fn slot(&self, t: Time, frame_duration: Time) -> Option<CaptionSlot>;
}

impl CaptionTrackSlotExt for CaptionTrack {
    fn slot(&self, t: Time, frame_duration: Time) -> Option<CaptionSlot> {
        Lookup::new(self).slot(t, frame_duration)
    }
}

/// `Timeline.captionSlots(at:)` for many times on one timeline (playback makes one per timeline change, not per tick): the
/// tracks are checked once, every lookup after that is a binary search.
#[derive(Clone, Debug)]
pub struct CaptionSlotLookup {
    tracks: Vec<Lookup>,
    frame_duration: Time,
    /// The timeline this was made from.
    pub timeline: Id,
}

impl CaptionSlotLookup {
    /// Prepares the visible caption tracks of `timeline`.
    pub fn new(timeline: &Timeline) -> CaptionSlotLookup {
        CaptionSlotLookup {
            timeline: timeline.id,
            tracks: timeline.caption_tracks.iter().filter(|t| t.is_visible).map(Lookup::new).collect(),
            frame_duration: timeline.format.frame_duration,
        }
    }

    /// No caption on any visible track.
    pub fn is_empty(&self) -> bool {
        self.tracks.iter().all(|t| t.items.is_empty())
    }

    /// What every visible track shows at `t`, bottom track first.
    pub fn slots(&self, t: Time) -> Vec<CaptionSlot> {
        self.tracks.iter().filter_map(|k| k.slot(t, self.frame_duration)).collect()
    }
}

/// The read side of the Swift `Timeline` caption extension, plus the verbs that touch no item list.
pub trait TimelineCaptionsExt {
    /// The caption track with `id`.
    fn caption_track(&self, id: Id) -> Option<&CaptionTrack>;
    /// "Captions 1", "Captions 2", ...: the lowest number no caption track of the sequence carries yet.
    fn next_caption_track_name(&self) -> String;
    /// The caption track that holds caption `id`.
    fn caption_track_id_containing(&self, id: Id) -> Option<Id>;
    /// Captions visible at `t`, bottom track first. Captions of nested sequences are not evaluated.
    fn captions_at(&self, t: Time) -> Vec<ActiveCaption>;
    /// What every visible caption track shows at `t`, bottom track first, with the hand-over between neighboring captions.
    /// Unlike `captions_at` a caption also shows in a small gap before its neighbor, and blank captions are left out.
    fn caption_slots_at(&self, t: Time) -> Vec<CaptionSlot>;
    /// IDs of the captions whose text contains `find`, in time order.
    fn caption_matches(&self, find: &str, case_sensitive: bool) -> Vec<Id>;
    /// Every match of `find` on the caption tracks (one track with `track`), in time order. Locked tracks are searched too.
    fn caption_text_matches(&self, find: &str, case_sensitive: bool, track: Option<Id>) -> Vec<CaptionTextMatch>;
    /// Records the Look the track was given (`CaptionTrack::look_id`); `None` forgets it.
    fn set_caption_look(&mut self, look_id: Option<String>, track: Id) -> Result<(), EditError>;
    /// Turns the karaoke word highlight of a track on (a style) or off (`None`).
    fn set_caption_karaoke(&mut self, karaoke: Option<KaraokeStyle>, track: Id) -> Result<(), EditError>;
}

fn unlocked_index(t: &Timeline, id: Id) -> Result<usize, EditError> {
    let i = t.caption_tracks.iter().position(|c| c.id == id).ok_or(EditError::ClipNotFound)?;
    if t.caption_tracks[i].is_locked { Err(EditError::TrackLocked) } else { Ok(i) }
}

impl TimelineCaptionsExt for Timeline {
    fn caption_track(&self, id: Id) -> Option<&CaptionTrack> {
        self.caption_tracks.iter().find(|c| c.id == id)
    }

    fn next_caption_track_name(&self) -> String {
        let mut n = 1;
        while self.caption_tracks.iter().any(|c| c.name == format!("Captions {n}")) {
            n += 1;
        }
        format!("Captions {n}")
    }

    fn caption_track_id_containing(&self, id: Id) -> Option<Id> {
        self.caption_tracks.iter().find(|t| t.items().iter().any(|i| i.id == id)).map(|t| t.id)
    }

    fn captions_at(&self, t: Time) -> Vec<ActiveCaption> {
        self.caption_tracks
            .iter()
            .filter(|c| c.is_visible)
            .filter_map(|track| {
                track
                    .items()
                    .iter()
                    .find(|i| i.range.contains(t))
                    .map(|i| ActiveCaption { item: i.clone(), track: track.id })
            })
            .collect()
    }

    fn caption_slots_at(&self, t: Time) -> Vec<CaptionSlot> {
        CaptionSlotLookup::new(self).slots(t)
    }

    fn caption_matches(&self, find: &str, case_sensitive: bool) -> Vec<Id> {
        if find.is_empty() {
            return Vec::new();
        }
        // Swift: `[.caseInsensitive, .diacriticInsensitive]` unless case sensitive ("cafe" finds "Café").
        let hit = |l: &String| {
            if case_sensitive { l.contains(find) } else { !text_search::matches(l, find, false, false).is_empty() }
        };
        let mut items: Vec<&CaptionItem> = self.caption_tracks.iter().flat_map(|t| t.items()).collect();
        items.sort_by_key(|i| i.range.start);
        items.into_iter().filter(|i| i.lines.iter().any(hit)).map(|i| i.id).collect()
    }

    fn caption_text_matches(&self, find: &str, case_sensitive: bool, track: Option<Id>) -> Vec<CaptionTextMatch> {
        if find.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for t in self.caption_tracks.iter().filter(|t| track.is_none_or(|id| t.id == id)) {
            for item in t.items() {
                for m in item.text_matches(find, case_sensitive) {
                    out.push(CaptionTextMatch {
                        track: t.id,
                        caption: item.id,
                        line: m.line,
                        range: m.range,
                        words: m.words,
                        time: item.range.start,
                    });
                }
            }
        }
        // Stable by time: matches of one caption keep their reading order.
        out.sort_by_key(|m| m.time);
        out
    }

    fn set_caption_look(&mut self, look_id: Option<String>, track: Id) -> Result<(), EditError> {
        let i = unlocked_index(self, track)?;
        self.caption_tracks[i].look_id = look_id;
        Ok(())
    }

    fn set_caption_karaoke(&mut self, karaoke: Option<KaraokeStyle>, track: Id) -> Result<(), EditError> {
        let i = unlocked_index(self, track)?;
        self.caption_tracks[i].karaoke = karaoke;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::timeline;
    use crate::caption_item::tests::{item, range, t};
    use crate::filler_words::tests::track_with;

    const FD: Time = Time::new(1, 30);
    fn tl(items: &[CaptionItem]) -> Timeline {
        let mut tl = timeline(vec![]);
        tl.set_frame_duration(FD);
        tl.caption_tracks = vec![track_with(items, true)];
        tl
    }

    #[test]
    fn hands_over_within_two_frames_and_never_across_overlaps() {
        let a = TimeRange::new(Time::ZERO, Time::new(1, 1));
        let near = TimeRange::new(Time::new(1, 1) + FD * 2, Time::new(1, 1));
        let far = TimeRange::new(Time::new(1, 1) + FD * 3, Time::new(1, 1));
        let overlap = TimeRange::new(Time::new(1, 2), Time::new(1, 1));
        assert!(CaptionHandover::hands_over(&a, &near, FD));
        assert!(!CaptionHandover::hands_over(&a, &far, FD));
        assert!(!CaptionHandover::hands_over(&a, &overlap, FD));
    }

    #[test]
    fn the_earlier_caption_holds_through_the_gap_and_the_later_has_a_tail() {
        let items = [item(&["a"], range(0, 1000)), item(&["b"], range(1040, 2000))];
        let tl = tl(&items);
        let in_gap = tl.caption_slots_at(t(1020));
        assert_eq!(in_gap.len(), 1);
        assert_eq!((in_gap[0].item.text(), in_gap[0].held, in_gap[0].duration), ("a".to_string(), true, t(1040)));
        let later = tl.caption_slots_at(t(1500));
        assert_eq!(later[0].item.text(), "b");
        assert_eq!(
            (later[0].tail_duration, later[0].tail.as_ref().map(|c| c.text())),
            (t(1040), Some("a".to_string()))
        );
        // Far apart or alone: untouched.
        let far = tl_far();
        let s = far.caption_slots_at(t(500));
        assert_eq!((s[0].duration, s[0].held, s[0].tail.is_none()), (t(1000), false, true));
        assert!(far.caption_slots_at(t(2000)).is_empty());
    }

    fn tl_far() -> Timeline {
        tl(&[item(&["a"], range(0, 1000)), item(&["b"], range(5000, 6000))])
    }

    #[test]
    fn blank_captions_are_left_out_and_overlapping_tracks_show_the_first() {
        let tl1 = tl(&[item(&[" "], range(0, 1000)), item(&["b"], range(1000, 2000))]);
        assert!(tl1.caption_slots_at(t(500)).is_empty());
        let overlapping = tl(&[item(&["a"], range(0, 1500)), item(&["b"], range(1000, 2000))]);
        let s = overlapping.caption_slots_at(t(1200));
        assert_eq!((s[0].item.text(), s[0].tail.is_none(), s[0].duration), ("a".to_string(), true, t(1500)));
    }

    #[test]
    fn captions_at_lists_visible_tracks_only() {
        let mut tl = tl(&[item(&["a"], range(0, 1000))]);
        assert_eq!(tl.captions_at(t(500)).len(), 1);
        assert!(tl.captions_at(t(1000)).is_empty()); // half-open
        tl.caption_tracks[0].is_visible = false;
        assert!(tl.captions_at(t(500)).is_empty());
        assert!(CaptionSlotLookup::new(&tl).is_empty());
    }

    #[test]
    fn track_names_matches_and_settings() {
        let mut tl = tl(&[item(&["Hello world"], range(0, 1000)), item(&["hello again"], range(2000, 3000))]);
        assert_eq!(tl.next_caption_track_name(), "Captions 1");
        tl.caption_tracks[0].name = "Captions 1".to_string();
        assert_eq!(tl.next_caption_track_name(), "Captions 2");
        assert_eq!(tl.caption_matches("hello", false).len(), 2);
        assert_eq!(tl.caption_matches("hello", true).len(), 1);
        let accented = {
            let mut t2 = timeline(vec![]);
            t2.caption_tracks = vec![track_with(&[item(&["Ein Café am Fluss"], range(0, 1000))], true)];
            t2
        };
        assert_eq!(accented.caption_matches("cafe", false).len(), 1, "diacritics are folded");
        assert_eq!(accented.caption_matches("CAFÉ", false).len(), 1);
        assert!(accented.caption_matches("cafe", true).is_empty(), "a case sensitive search is exact");
        let m = tl.caption_text_matches("hello", false, None);
        assert_eq!(m.iter().map(|x| x.time).collect::<Vec<_>>(), vec![t(0), t(2000)]);
        let id = tl.caption_tracks[0].id;
        assert_eq!(tl.caption_track_id_containing(tl.caption_tracks[0].items()[1].id), Some(id));
        assert_eq!(tl.set_caption_look(Some("look".to_string()), id), Ok(()));
        assert_eq!(tl.caption_track(id).and_then(|c| c.look_id.clone()), Some("look".to_string()));
        tl.caption_tracks[0].is_locked = true;
        assert_eq!(tl.set_caption_karaoke(None, id), Err(EditError::TrackLocked));
        assert_eq!(tl.set_caption_karaoke(None, Id::NIL), Err(EditError::ClipNotFound));
    }
}
