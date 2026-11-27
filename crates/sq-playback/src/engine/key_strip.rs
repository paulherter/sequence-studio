// SPDX-License-Identifier: GPL-3.0-or-later
//! Key strip: one quarter-size picture per GOP of a software-decoded 4K clip, decoded in the background while the app is idle.
//! A scrub jump into a new GOP costs the I-frame (~100 ms) plus half a GOP of P/B frames; with the strip the monitor shows
//! the GOP's key picture at once as the stand-in and the exact frame replaces it as soon as it is decoded.
//!
//! The cache is keyed by media and GOP start frame, holds a hard byte cap (least recently used goes first) and drops a
//! media's pictures when the media changes (relink): every entry carries the media's generation, a picture decoded for an
//! older generation is refused. One explicit state per media (`StripState`), no flags.

use super::types::Picture;
use sq_core_time::Id;
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

/// The strip decodes at a quarter of the size.
pub const STRIP_DIVISOR: u32 = 4;
/// Smallest 4K picture the strip is made for (width in pixels): smaller clips decode a jump fast anyway.
pub const STRIP_MIN_WIDTH: i64 = 3000;
/// At most this many GOPs are planned per media (an hour of footage at one key frame per second).
pub const STRIP_MAX_GOPS: usize = 4000;

/// Where a media's strip stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StripState {
    /// Not looked at yet.
    Unchecked,
    /// `plan`: every GOP start the timeline uses of the media (the ones in the cache are done; an evicted one is decoded
    /// again when the playhead comes near). `ranges`: the used source frame ranges the plan was made for. `asked`: the GOP
    /// a job is decoding now.
    Filling { plan: Vec<i64>, ranges: Vec<(i64, i64)>, asked: Option<i64> },
    /// Not made for this media: hardware decoder, small picture, a decode failed.
    Skipped,
}

/// How a background decode of one key picture ended.
pub enum StripOutcome {
    Done(Picture),
    /// Playback or a scrub started first: nothing was decoded, the GOP stays to do.
    Busy,
    /// The decoder failed: no strip for this media.
    Failed,
}

impl PartialEq for StripOutcome {
    fn eq(&self, other: &Self) -> bool {
        matches!((self, other), (StripOutcome::Busy, StripOutcome::Busy))
    }
}

struct Entry {
    picture: Picture,
    used: u64,
}

#[derive(Default)]
struct Inner {
    entries: HashMap<(Id, i64), Entry>,
    bytes: usize,
    clock: u64,
    generations: HashMap<Id, u64>,
    /// The frame the playhead is at in each media: eviction drops the pictures farthest from it.
    focus: HashMap<Id, i64>,
    /// Size of the last picture stored (the fill stops when one more would not fit).
    last_bytes: usize,
    states: HashMap<Id, StripState>,
}

pub struct KeyStrip {
    cap: usize,
    inner: Mutex<Inner>,
}

impl KeyStrip {
    pub fn new(cap: usize) -> KeyStrip {
        KeyStrip { cap, inner: Mutex::new(Inner::default()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The media's generation: pictures decoded for another one never enter.
    pub fn generation(&self, media: Id) -> u64 {
        self.lock().generations.get(&media).copied().unwrap_or(0)
    }

    /// The media changed (relinked): its pictures go and its strip starts over.
    pub fn invalidate(&self, media: Id) {
        let mut s = self.lock();
        *s.generations.entry(media).or_default() += 1;
        let gone: Vec<(Id, i64)> = s.entries.keys().filter(|k| k.0 == media).copied().collect();
        for k in gone {
            if let Some(e) = s.entries.remove(&k) {
                s.bytes -= e.picture.bytes;
            }
        }
        s.states.insert(media, StripState::Unchecked);
    }

    pub fn state(&self, media: Id) -> StripState {
        self.lock().states.get(&media).cloned().unwrap_or(StripState::Unchecked)
    }

    /// Whether `media` needs a (new) plan for these used source ranges: not looked at yet, or the ranges changed (a clip
    /// was added, a trim reached further). A skipped media stays skipped.
    pub fn needs_plan(&self, media: Id, ranges: &[(i64, i64)]) -> bool {
        match self.lock().states.get(&media) {
            None | Some(StripState::Unchecked) => true,
            Some(StripState::Filling { ranges: r, .. }) => r != ranges,
            Some(StripState::Skipped) => false,
        }
    }

    /// Starts (or restarts, keeping the cached pictures) filling `media` with `gops` (ascending GOP start frames) for the
    /// used source `ranges`.
    pub fn plan(&self, media: Id, ranges: Vec<(i64, i64)>, gops: Vec<i64>) {
        let mut s = self.lock();
        let asked = match s.states.get(&media) {
            Some(StripState::Filling { asked, .. }) => *asked,
            _ => None,
        };
        s.states.insert(media, StripState::Filling { plan: gops, ranges, asked });
    }

    /// The media gets no strip.
    pub fn skip(&self, media: Id) {
        self.lock().states.insert(media, StripState::Skipped);
    }

    /// The playhead of `media` is at source frame `frame`.
    pub fn set_focus(&self, media: Id, frame: i64) {
        self.lock().focus.insert(media, frame);
    }

    /// The next GOP to decode: the uncached one nearest the media's playhead, marked as asked. `None`: nothing to do (a job
    /// is decoding, everything is cached, or the cache is full of pictures nearer the playhead than this one).
    pub fn next_to_decode(&self, media: Id) -> Option<(i64, u64)> {
        let mut s = self.lock();
        let generation = s.generations.get(&media).copied().unwrap_or(0);
        let near = s.focus.get(&media).copied().unwrap_or(0);
        let cached: HashSet<i64> = s.entries.keys().filter(|k| k.0 == media).map(|k| k.1).collect();
        let farthest = cached.iter().map(|g| (g - near).abs()).max();
        let full = s.bytes + s.last_bytes > self.cap;
        let Some(StripState::Filling { plan, asked, .. }) = s.states.get_mut(&media) else { return None };
        if asked.is_some() {
            return None;
        }
        let Some(gop) = plan.iter().copied().filter(|g| !cached.contains(g)).min_by_key(|g| (g - near).abs()) else {
            return None; // everything is cached; the plan stays so a changed range or an eviction is seen
        };
        if full && farthest.is_some_and(|f| (gop - near).abs() >= f) {
            return None; // at the cap: stop filling; it continues when the playhead moves nearer
        }
        *asked = Some(gop);
        Some((gop, generation))
    }

    /// A job ended for `gop` of `generation`.
    pub fn finished(&self, media: Id, gop: i64, generation: u64, outcome: StripOutcome) {
        let mut s = self.lock();
        if s.generations.get(&media).copied().unwrap_or(0) != generation {
            return; // the media changed while it decoded; `invalidate` reset the state
        }
        if let Some(StripState::Filling { asked, .. }) = s.states.get_mut(&media) {
            *asked = None;
        }
        let picture = match outcome {
            StripOutcome::Done(p) if p.bytes <= self.cap => p,
            StripOutcome::Busy => return, // playback came first: it is asked again when idle
            _ => {
                s.states.insert(media, StripState::Skipped);
                return;
            }
        };
        s.clock += 1;
        let used = s.clock;
        s.bytes += picture.bytes;
        s.last_bytes = picture.bytes;
        if let Some(old) = s.entries.insert((media, gop), Entry { picture, used }) {
            s.bytes -= old.picture.bytes;
        }
        while s.bytes > self.cap {
            // The picture farthest from its media's playhead goes (an unwatched media counts from frame 0).
            let far = s.entries.keys().max_by_key(|(m, g)| (g - s.focus.get(m).copied().unwrap_or(0)).abs()).copied();
            let Some(far) = far else { break };
            if let Some(e) = s.entries.remove(&far) {
                s.bytes -= e.picture.bytes;
            }
        }
    }

    /// The key picture of the GOP that starts at `gop`, marked as used.
    pub fn get(&self, media: Id, gop: i64) -> Option<Picture> {
        let mut s = self.lock();
        s.clock += 1;
        let used = s.clock;
        let e = s.entries.get_mut(&(media, gop))?;
        e.used = used;
        Some(e.picture.clone())
    }

    pub fn bytes(&self) -> usize {
        self.lock().bytes
    }

    pub fn len(&self) -> usize {
        self.lock().entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// The GOP start frames in `from..=to`: `start_of(i)` is the first frame of the GOP that frame `i` belongs to. Ascending, no
/// duplicates, at most `STRIP_MAX_GOPS`.
pub fn gop_starts(from: i64, to: i64, start_of: impl Fn(i64) -> i64) -> Vec<i64> {
    let mut out = Vec::new();
    let mut i = from.max(0);
    while i <= to && out.len() < STRIP_MAX_GOPS {
        let g = start_of(i);
        if out.last() != Some(&g) {
            out.push(g);
        }
        i += 1;
        while i <= to && start_of(i) == g {
            i += 1;
        }
    }
    out
}

/// The strip's byte cap for a frame cache of `frame_cache_bytes`: a sixteenth, between 32 and 256 MiB.
pub fn strip_cap(frame_cache_bytes: usize) -> usize {
    (frame_cache_bytes / 16).clamp(32 << 20, 256 << 20)
}

/// Whether the key picture stands in for frame `wanted`: no decoded picture nearer than the GOP start `gop` (scrubbing:
/// `nearest` is the nearest cached frame); a paused jump (click on the ruler) only when nothing of the GOP is decoded, so
/// a single step inside a decoded GOP never flashes the small picture.
pub fn strip_applies(scrubbing: bool, nearest: Option<i64>, wanted: i64, gop: i64, gop_has_pictures: bool) -> bool {
    if scrubbing { nearest.is_none_or(|i| (i - wanted).abs() > (wanted - gop).abs()) } else { !gop_has_pictures }
}

/// Whether a clip gets a strip: software decoder, 4K-class picture.
pub fn wants_strip(is_hardware: bool, width: i64) -> bool {
    !is_hardware && width >= STRIP_MIN_WIDTH
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;
    use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
    use std::sync::Arc;

    struct Nothing;
    impl SQFrameStorage for Nothing {}

    fn pic(bytes: usize) -> Picture {
        let frame =
            SQFrame::new(4, 4, SQFramePixelFormat::Nv12, SQFrameColorSpace::Unspecified, Time::ZERO, Arc::new(Nothing));
        Picture { frame, bytes }
    }

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn fill(strip: &KeyStrip, m: Id, bytes: usize) -> Option<i64> {
        let (g, generation) = strip.next_to_decode(m)?;
        strip.finished(m, g, generation, StripOutcome::Done(pic(bytes)));
        Some(g)
    }

    #[test]
    fn at_the_cap_the_pictures_nearest_the_playhead_stay_and_evicted_gops_are_planned_again() {
        let strip = KeyStrip::new(250);
        let m = id(1);
        strip.plan(m, vec![(0, 120)], vec![0, 29, 58, 87]);
        strip.set_focus(m, 0);
        assert_eq!((fill(&strip, m, 100), fill(&strip, m, 100)), (Some(0), Some(29)));
        assert_eq!(fill(&strip, m, 100), None, "full: the next one is farther than everything cached");
        assert_eq!(strip.len(), 2);
        // The playhead moves to the end: the far GOPs are decoded, the old ones go, nearest-first.
        strip.set_focus(m, 90);
        assert_eq!(fill(&strip, m, 100), Some(87));
        assert!(strip.get(m, 0).is_none() && strip.get(m, 29).is_some(), "farthest from the playhead was evicted");
        assert_eq!(fill(&strip, m, 100), Some(58));
        assert!(strip.get(m, 29).is_none() && strip.get(m, 58).is_some() && strip.get(m, 87).is_some());
        // Back to the start: the evicted GOPs are still in the plan.
        strip.set_focus(m, 0);
        assert_eq!(fill(&strip, m, 100), Some(0));
        assert!(strip.bytes() <= 250);
    }

    #[test]
    fn a_get_marks_use_but_does_not_change_which_picture_is_farthest() {
        let strip = KeyStrip::new(250);
        let m = id(1);
        strip.plan(m, vec![(0, 90)], vec![0, 29, 58]);
        strip.set_focus(m, 0);
        fill(&strip, m, 100);
        fill(&strip, m, 100);
        strip.get(m, 29);
        strip.set_focus(m, 58);
        assert_eq!(fill(&strip, m, 100), Some(58));
        assert!(strip.get(m, 0).is_none());
    }

    #[test]
    fn a_changed_media_drops_its_pictures_and_refuses_late_ones() {
        let strip = KeyStrip::new(1000);
        let (a, b) = (id(1), id(2));
        for m in [a, b] {
            strip.plan(m, vec![(0, 10)], vec![0]);
            fill(&strip, m, 10);
        }
        strip.plan(a, vec![(0, 40)], vec![0, 29]);
        let (g, old) = strip.next_to_decode(a).unwrap();
        strip.invalidate(a);
        strip.finished(a, g, old, StripOutcome::Done(pic(10))); // decoded for the old file
        assert!(strip.get(a, 0).is_none() && strip.get(a, g).is_none());
        assert!(strip.get(b, 0).is_some(), "another media is untouched");
        assert_eq!(strip.state(a), StripState::Unchecked);
        assert_eq!(strip.bytes(), 10);
    }

    #[test]
    fn the_fill_takes_the_gop_nearest_the_playhead_one_at_a_time() {
        let strip = KeyStrip::new(1000);
        let m = id(1);
        strip.plan(m, vec![(0, 90)], vec![0, 29, 58, 87]);
        strip.set_focus(m, 60);
        let (g, generation) = strip.next_to_decode(m).unwrap();
        assert_eq!(g, 58);
        assert!(strip.next_to_decode(m).is_none(), "one job at a time per media");
        strip.finished(m, g, generation, StripOutcome::Done(pic(10)));
        assert_eq!(strip.next_to_decode(m).unwrap().0, 87);
        // A failed decode ends the strip of that media.
        strip.finished(m, 87, strip.generation(m), StripOutcome::Failed);
        assert_eq!(strip.state(m), StripState::Skipped);
        assert!(strip.next_to_decode(m).is_none());
    }

    #[test]
    fn a_busy_job_leaves_the_gop_to_do() {
        let strip = KeyStrip::new(1000);
        let m = id(1);
        strip.plan(m, vec![(0, 10)], vec![0]);
        let (g, generation) = strip.next_to_decode(m).unwrap();
        strip.finished(m, g, generation, StripOutcome::Busy);
        assert_eq!(strip.next_to_decode(m).map(|x| x.0), Some(0));
    }

    #[test]
    fn a_skipped_media_is_never_asked_and_does_not_need_a_plan() {
        let strip = KeyStrip::new(1000);
        let m = id(1);
        assert!(strip.needs_plan(m, &[(0, 10)]));
        strip.skip(m);
        assert!(!strip.needs_plan(m, &[(0, 10)]) && strip.next_to_decode(m).is_none());
    }

    #[test]
    fn a_changed_used_range_asks_for_a_new_plan_and_keeps_the_pictures() {
        let strip = KeyStrip::new(1000);
        let m = id(1);
        strip.plan(m, vec![(0, 40)], vec![0, 29]);
        assert!(!strip.needs_plan(m, &[(0, 40)]));
        fill(&strip, m, 10);
        assert!(strip.needs_plan(m, &[(0, 90)]), "a trim reached further");
        strip.plan(m, vec![(0, 90)], vec![0, 29, 58, 87]);
        assert!(strip.get(m, 0).is_some());
        assert_eq!(strip.next_to_decode(m).map(|x| x.0), Some(29));
    }

    #[test]
    fn the_key_picture_stands_in_for_a_scrub_and_a_paused_jump_but_not_a_step() {
        // scrub: a decoded picture nearer than the GOP start wins
        assert!(strip_applies(true, None, 40, 29, false));
        assert!(strip_applies(true, Some(80), 40, 29, false));
        assert!(!strip_applies(true, Some(38), 40, 29, true));
        // paused: only when nothing of the GOP is decoded
        assert!(strip_applies(false, None, 40, 29, false));
        assert!(!strip_applies(false, Some(39), 40, 29, true));
    }

    #[test]
    fn only_software_4k_clips_get_a_strip_and_the_cap_scales() {
        assert!(wants_strip(false, 3840) && !wants_strip(true, 3840) && !wants_strip(false, 1920));
        assert_eq!(strip_cap(4 << 30), 256 << 20);
        assert_eq!(strip_cap(100 << 20), 32 << 20);
    }

    #[test]
    fn gop_starts_are_ascending_and_distinct() {
        let start_of = |i: i64| i / 29 * 29;
        assert_eq!(gop_starts(10, 90, start_of), vec![0, 29, 58, 87]);
        assert_eq!(gop_starts(29, 29, start_of), vec![29]);
        assert!(gop_starts(5, 4, start_of).is_empty());
    }
}
