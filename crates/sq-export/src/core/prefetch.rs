// Swift: ClipPrefetchScanner.swift

use sq_core_time::{Id, Time};
use std::collections::HashSet;

/// A layer drawn at one output time, as far as the prefetch scan needs to know it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PrefetchLayer {
    /// The clip.
    pub clip: Id,
    /// Its media.
    pub media: Id,
    /// Source time of the layer at this output time.
    pub source_time: Time,
    /// A generator layer (title, color matte) has no media to decode.
    pub is_generator: bool,
}

/// A media layer that appears ahead, with the source time of its first frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PrefetchHint {
    /// The media.
    pub media: Id,
    /// Source time of its first frame.
    pub source_time: Time,
}

/// Export decode-ahead across cuts: walks the output timeline `lead_frames` ahead of the render position, one frame at a
/// time, and reports every media layer that appears there (a clip start, a transition's incoming clip, a nested clip),
/// with the source time of its first frame. Layers already drawn at the first scanned frame are not reported (the render
/// asks for them itself). Export moves forward; after a jump the scan restarts at the new position.
#[derive(Clone, Debug)]
pub struct ClipPrefetchScanner {
    start: Time,
    frame_duration: Time,
    frame_count: usize,
    lead_frames: usize,
    /// Last scanned time and the media layers drawn there.
    scanned: Option<Time>,
    previous: HashSet<(Id, Id)>,
}

impl ClipPrefetchScanner {
    /// A scanner over `frame_count` frames from `start`.
    pub fn new(start: Time, frame_duration: Time, frame_count: usize, lead_frames: usize) -> ClipPrefetchScanner {
        ClipPrefetchScanner { start, frame_duration, frame_count, lead_frames, scanned: None, previous: HashSet::new() }
    }

    /// The layers that first appear in the frames after the last scanned one, up to `t + lead_frames` (never past the
    /// last frame). `layers` evaluates the timeline at a time.
    pub fn advance(&mut self, t: Time, layers: &mut dyn FnMut(Time) -> Vec<PrefetchLayer>) -> Vec<PrefetchHint> {
        if self.frame_count == 0 || self.frame_duration <= Time::ZERO {
            return Vec::new();
        }
        let fd = self.frame_duration;
        let last = self.start + fd * (self.frame_count as i64 - 1);
        let keys = |ls: &[PrefetchLayer]| -> HashSet<(Id, Id)> {
            ls.iter().filter(|l| !l.is_generator).map(|l| (l.clip, l.media)).collect()
        };
        if self.scanned.is_none_or(|s| t >= s) {
            self.scanned = Some(t);
            self.previous = keys(&layers(t));
        }
        let horizon = (t + fd * self.lead_frames as i64).min(last);
        let (mut out, mut seen) = (Vec::new(), HashSet::new());
        while let Some(s) = self.scanned.filter(|s| *s + fd <= horizon) {
            let at = s + fd;
            self.scanned = Some(at);
            let ls: Vec<PrefetchLayer> = layers(at).into_iter().filter(|l| !l.is_generator).collect();
            for l in ls.iter().filter(|l| !self.previous.contains(&(l.clip, l.media))) {
                let h = PrefetchHint { media: l.media, source_time: l.source_time };
                if seen.insert(h) {
                    out.push(h);
                }
            }
            self.previous = keys(&ls);
        }
        out
    }
}
