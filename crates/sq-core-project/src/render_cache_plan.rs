// Swift: RenderCachePlan.swift (the key salt is `sq-render-cache-2`: the Clip JSON the key hashes differs from Swift's)
//! Preview render cache, model part 1 (the design notes "Preview render cache"): splits the visible video of a sequence
//! into segments at every clip edge and gives each a content key. The key covers what the picture depends on (clips
//! with times relative to the segment, effects, speed, transitions, nested content, media stamps, sequence format,
//! renderer id, working space) and nothing about the segment's place on the timeline, so a ripple edit keeps the key of
//! every later segment. Nothing here is stored in the project file.

use std::collections::BTreeSet;

use serde::Serialize;
use sq_core_model::{Clip, Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// Finds the timeline a nested sequence id stands for.
pub type SequenceResolver<'a> = &'a dyn Fn(Id) -> Option<&'a Timeline>;

/// What the keys depend on besides the timeline.
pub struct RenderCacheContext<'a> {
    /// Changes whenever the renderer's output changes (shader or effect code revision).
    pub renderer_id: String,
    /// Working color space name.
    pub working_space: String,
    /// Changes when the media file changes (size + modification date); a missing stamp is the empty string.
    pub media_stamp: Box<dyn Fn(Id) -> String + 'a>,
}

impl RenderCacheContext<'_> {
    /// A context whose media stamp is always empty.
    pub fn new(renderer_id: &str, working_space: &str) -> RenderCacheContext<'static> {
        RenderCacheContext {
            renderer_id: renderer_id.to_string(),
            working_space: working_space.to_string(),
            media_stamp: Box::new(|_| String::new()),
        }
    }
}

/// Two-lane FNV-1a: stable across launches, 128 bits, no crypto needed (keys are not secrets).
struct StableHash {
    a: u64,
    b: u64,
}

impl StableHash {
    fn new() -> StableHash {
        StableHash { a: 0xcbf2_9ce4_8422_2325, b: 0x8422_2325_cbf2_9ce4 }
    }

    fn add_bytes(&mut self, bytes: &[u8]) {
        for &x in bytes {
            let x = u64::from(x);
            self.a = (self.a ^ x).wrapping_mul(0x1_0000_01b3);
            self.b = (self.b.wrapping_add(x).wrapping_add(1).wrapping_mul(0x1_0000_01b3)) ^ (self.a >> 7);
        }
    }

    fn add(&mut self, s: &str) {
        self.add_bytes(s.as_bytes());
        self.add_bytes(&[0xff]);
    }

    fn hex(&self) -> String {
        format!("{:016x}{:016x}", self.a, self.b)
    }
}

/// One stretch of video between two clip edges.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderCacheSegment {
    pub range: TimeRange,
    pub key: String,
    /// Worth caching: effects, speed change, transition, nested sequence, generator, or two or more layers.
    pub is_heavy: bool,
}

/// The segmenting and keying of a sequence.
pub struct RenderCachePlan;

impl RenderCachePlan {
    const MAX_NESTING: usize = 4;

    /// The segments of `timeline` in time order.
    pub fn segments(
        timeline: &Timeline,
        resolver: Option<SequenceResolver<'_>>,
        context: &RenderCacheContext<'_>,
    ) -> Vec<RenderCacheSegment> {
        Self::segments_at(timeline, resolver, context, 0)
    }

    fn segments_at(
        timeline: &Timeline,
        resolver: Option<SequenceResolver<'_>>,
        context: &RenderCacheContext<'_>,
        depth: usize,
    ) -> Vec<RenderCacheSegment> {
        let tracks: Vec<_> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video && t.is_visible).collect();
        let mut points: BTreeSet<Time> = BTreeSet::new();
        for t in &tracks {
            for c in t.clips() {
                points.insert(c.timeline().start);
                points.insert(c.timeline().end());
            }
        }
        let sorted: Vec<Time> = points.into_iter().collect();
        let mut out = Vec::new();
        for pair in sorted.windows(2) {
            let (lo, hi) = (pair[0], pair[1]);
            let r = TimeRange::new(lo, hi - lo);
            let mut layers = 0usize;
            let mut heavy = false;
            let mut h = StableHash::new();
            h.add("sq-render-cache-2");
            h.add(&context.renderer_id);
            h.add(&context.working_space);
            h.add(&json(&timeline.format));
            h.add(&json(&r.duration));
            for t in &tracks {
                let clips: Vec<&Clip> = t.clips().iter().filter(|c| c.timeline().overlaps(&r)).collect();
                if clips.is_empty() {
                    h.add("-");
                    continue;
                }
                layers += clips.len();
                h.add("track");
                for c in &clips {
                    let mut n = Clip::clone(c);
                    anonymize(&mut n);
                    n.start = c.start - r.start;
                    h.add(&json(&n));
                    h.add(&(context.media_stamp)(c.media));
                    if !c.effects.is_empty()
                        || c.speed != sq_core_model::ClipSpeed::NORMAL
                        || c.sequence.is_some()
                        || c.generator.is_some()
                    {
                        heavy = true;
                    }
                    if let Some(s) = c.sequence
                        && depth < Self::MAX_NESTING
                        && let Some(inner) = resolver.and_then(|f| f(s))
                    {
                        h.add("nest");
                        for seg in Self::segments_at(inner, resolver, context, depth + 1) {
                            h.add(&seg.key);
                        }
                    }
                }
                for tr in &t.transitions {
                    let o = clips.iter().position(|c| Some(c.id) == tr.outgoing);
                    let i = clips.iter().position(|c| Some(c.id) == tr.incoming);
                    if o.is_none() && i.is_none() {
                        continue;
                    }
                    let mut n = tr.clone();
                    n.id = Id::NIL;
                    n.outgoing = None;
                    n.incoming = None;
                    let index = |p: Option<usize>| p.map_or(-1, |p| i64::try_from(p).unwrap_or(-1));
                    h.add(&format!("tr{},{}", index(o), index(i)));
                    h.add(&json(&n));
                    heavy = true;
                    // The other side of the cut is not in this segment, but its handle frames are part of the picture.
                    for other in [tr.outgoing, tr.incoming].into_iter().flatten() {
                        if clips.iter().any(|c| c.id == other) {
                            continue;
                        }
                        if let Some(oc) = t.clips().iter().find(|c| c.id == other) {
                            let mut oc = oc.clone();
                            anonymize(&mut oc);
                            oc.start -= r.start;
                            h.add("other");
                            h.add(&json(&oc));
                            h.add(&(context.media_stamp)(oc.media));
                        }
                    }
                }
            }
            out.push(RenderCacheSegment { range: r, key: h.hex(), is_heavy: heavy || layers >= 2 });
        }
        out
    }
}

/// Clears what must not change a key: identity, names, links and labels.
fn anonymize(c: &mut Clip) {
    c.id = Id::NIL;
    c.name = String::new();
    c.link = None;
    c.bundle = None;
    c.label = None;
}

/// JSON with sorted keys (serde_json's map is a `BTreeMap`), empty when encoding fails.
fn json(v: &impl Serialize) -> String {
    serde_json::to_value(v).map(|v| v.to_string()).unwrap_or_default()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use sq_core_model::{ClipEffect, SequenceFormat, Track};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    pub(crate) fn clip(start: i64, len: i64, media: u128, effects: Vec<ClipEffect>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1000 + u128::try_from(start).unwrap_or(0) * 10 + u128::try_from(len).unwrap_or(0)),
            "c",
            Id::from_u128(media),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(len)),
            s(start),
        );
        c.effects = effects;
        c
    }

    pub(crate) fn timeline(tracks: Vec<Vec<Clip>>) -> Timeline {
        let tracks = tracks
            .into_iter()
            .enumerate()
            .map(|(n, clips)| {
                let mut t = Track::new(Id::from_u128(50 + n as u128), TrackKind::Video);
                t.set_clips(clips);
                t
            })
            .collect();
        Timeline::new(Id::from_u128(60), "T", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    pub(crate) fn blur() -> ClipEffect {
        ClipEffect::new(Id::from_u128(900), ClipEffect::GAUSSIAN_BLUR_KIND)
    }

    #[test]
    fn splits_at_every_clip_edge_and_marks_heavy() {
        let ctx = RenderCacheContext::new("r1", "rec709");
        let t = timeline(vec![vec![clip(0, 4, 1, vec![])], vec![clip(2, 4, 1, vec![blur()])]]);
        let segs = RenderCachePlan::segments(&t, None, &ctx);
        assert_eq!(segs.iter().map(|g| g.range.start).collect::<Vec<_>>(), [s(0), s(2), s(4)]);
        assert_eq!(segs.iter().map(|g| g.is_heavy).collect::<Vec<_>>(), [false, true, true]);
    }

    #[test]
    fn ripple_keeps_later_keys_and_edit_changes_only_its_own() {
        let ctx = RenderCacheContext::new("r1", "rec709");
        let (c0, c1) = (clip(0, 3, 1, vec![]), clip(3, 4, 2, vec![blur()]));
        let t1 = timeline(vec![vec![c0.clone(), c1.clone()]]);
        let mut moved = c1.clone();
        moved.start = s(5);
        let t2 = timeline(vec![vec![c0.clone(), moved]]);
        let last = |t: &Timeline| RenderCachePlan::segments(t, None, &ctx).last().map(|g| g.key.clone());
        let first = |t: &Timeline| RenderCachePlan::segments(t, None, &ctx).first().map(|g| g.key.clone());
        let k1 = last(&t1);
        assert_eq!(last(&t2), k1);
        let mut edited = c1;
        edited.effects = vec![];
        let t3 = timeline(vec![vec![c0, edited]]);
        assert_ne!(last(&t3), k1);
        assert_eq!(first(&t3), first(&t1));
    }

    #[test]
    fn renderer_working_space_and_media_stamp_change_the_key() {
        let ctx = RenderCacheContext::new("r1", "rec709");
        let t = timeline(vec![vec![clip(0, 3, 1, vec![blur()])]]);
        let key = |c: &RenderCacheContext| RenderCachePlan::segments(&t, None, c)[0].key.clone();
        let base = key(&ctx);
        assert_ne!(key(&RenderCacheContext::new("r2", "rec709")), base);
        assert_ne!(key(&RenderCacheContext::new("r1", "p3")), base);
        let mut stamped = RenderCacheContext::new("r1", "rec709");
        stamped.media_stamp = Box::new(|_| "v2".to_string());
        assert_ne!(key(&stamped), base);
        assert_eq!(key(&ctx), base);
    }
    fn adjustment(start: i64, len: i64, effects: Vec<ClipEffect>) -> Clip {
        let mut c = clip(start, len, 7, effects);
        c.generator = Some(sq_core_model::GeneratorRef {
            kind: "adjustment".to_string(),
            payload: Vec::new(),
            payload_version: 1,
        });
        c
    }

    /// A8: a cached segment is a render of the whole stack, adjustment layer included, so the key follows the layer and
    /// whatever lies below it; segments the layer does not reach keep their key.
    #[test]
    fn an_adjustment_layer_is_part_of_the_key_of_every_segment_it_covers() {
        let ctx = RenderCacheContext::new("r1", "rec709");
        let below = || vec![clip(0, 6, 1, vec![])];
        let keys =
            |adj: Clip, lower: Vec<Clip>| RenderCachePlan::segments(&timeline(vec![lower, vec![adj]]), None, &ctx);
        let plain = keys(adjustment(2, 2, vec![]), below());
        // Segments: [0,2) alone, [2,4) under the layer, [4,6) alone.
        assert_eq!(plain.iter().map(|g| g.is_heavy).collect::<Vec<_>>(), [false, true, false]);
        let blurred = keys(adjustment(2, 2, vec![blur()]), below());
        assert_eq!(blurred[0].key, plain[0].key);
        assert_ne!(blurred[1].key, plain[1].key, "the layer's effect changes its own segment");
        assert_eq!(blurred[2].key, plain[2].key);
        // A change of the picture below, inside the layer's span, changes the key; outside it does not.
        let mut lower = below();
        lower[0].effects = vec![blur()];
        let relooked = keys(adjustment(2, 2, vec![]), lower);
        assert_ne!(relooked[1].key, plain[1].key);
    }
}
