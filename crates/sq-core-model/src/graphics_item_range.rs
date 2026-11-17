// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+ItemRange.swift

use crate::{Clip, ClipEdge, FollowTarget, GraphicsDocument, GraphicsLayer};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

// Item lanes: every item (layer) of a Graphic can show for only a part of the clip. `GraphicsLayer::range` is in the clip's
// local time, end exclusive, `None` = the whole clip. Rules:
// - Render, export and the monitor hit test skip an item outside its range (one gate: `is_shown`).
// - Trimming the clip keeps every range on its frames and clamps it to the clip. A range that falls wholly outside stays
//   as an empty range at that edge: the item is never drawn but stays in the Graphic (its lane can be trimmed out again).
// - Cutting the clip (split, razor, overwrite and lift pieces: `Clip::cropped`) gives each piece the part of the range
//   inside it and drops an item with nothing left to show in that piece. That is the only place an item is dropped. A
//   piece never loses its last items: if nothing would be left, they all stay as empty-range stubs.
// - A retime scales ranges like keys. `None` stays `None` everywhere.
// - A text item's In and Out animation runs on its range (In when the item appears, Out when it disappears): evaluation
//   hands the text generator range-local time and the range's length. Keyframes stay on clip time.
// - Item keyframes follow the clip's own keys on every edit (`remap_item_keys`): they stay on their frames through a head
//   trim and a cut, scale with a retime and mirror with a reverse.
// - The halves of a cut keep the same item ids. Ids are only ever resolved inside one clip.

impl GraphicsLayer {
    /// The layer shows at clip-local `t`. Evaluation runs this per layer and frame: no allocation.
    #[inline]
    pub fn is_shown(&self, t: Time) -> bool {
        self.range.is_none_or(|r| t >= r.start && t < r.end())
    }

    /// The time base of the item's text generator at clip-local `t`: THE one place that decides it. Render, Follow's
    /// measure and the monitor's measure (outline, handles, hit test, align) all take it from here, so the picture and its
    /// box cannot run on different clocks.
    #[inline]
    pub fn text_time(&self, t: Time) -> GraphicsTextTime {
        match self.range {
            None => GraphicsTextTime { local: t, duration: None },
            Some(r) => GraphicsTextTime { local: t - r.start, duration: Some(r.duration) },
        }
    }
}

/// When a text item's generator runs: `local` since the item appeared, `duration` how long it shows (`None` = the clip's
/// length: the item has no range). In and Out animations are anchored to these.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GraphicsTextTime {
    /// Time since the item appeared.
    pub local: Time,
    /// How long the item shows.
    pub duration: Option<Time>,
}

/// `r` limited to 0..<`d`; a range wholly outside becomes an empty one at the nearer edge.
fn clamped(r: TimeRange, d: Time) -> TimeRange {
    let a = r.start.max(Time::ZERO).min(d);
    let b = r.end().max(Time::ZERO).min(d);
    TimeRange::from_end(a, a.max(b))
}

/// A range filling the clip is stored as `None`, so the item keeps following the clip's trims.
fn normalized(r: TimeRange, d: Time) -> Option<TimeRange> {
    if r.start <= Time::ZERO && r.end() >= d { None } else { Some(r) }
}

impl GraphicsDocument {
    /// Some layer has a range (gates ProjectFile v74 and the work in the clip hooks).
    pub fn has_item_ranges(&self) -> bool {
        self.layers.iter().any(|l| l.range.is_some())
    }

    /// The part of a clip of `clip_duration` the layer shows in.
    pub fn shown_range(&self, layer: &GraphicsLayer, clip_duration: Time) -> TimeRange {
        layer.range.unwrap_or_else(|| TimeRange::new(Time::ZERO, clip_duration))
    }

    /// Clip trim: ranges move by `g` (the head grew by it) and are clamped to the new clip duration `d`.
    pub(crate) fn rebase_item_ranges(&mut self, g: Time, d: Time) {
        for l in &mut self.layers {
            if let Some(r) = l.range {
                l.range = Some(clamped(TimeRange::new(r.start + g, r.duration), d));
            }
        }
    }

    /// Clip cut: the piece from clip-local `a` lasting `d`. Ranges move into the piece; an item with nothing left to show
    /// there is removed (with its group and Follow links). A piece never ends up without items: when nothing would be
    /// left, every item stays with an empty range at its edge (the stub rule of a trim).
    pub(crate) fn cropping_item_ranges(&self, a: Time, d: Time) -> GraphicsDocument {
        if !self.has_item_ranges() {
            return self.clone();
        }
        let mut out = self.clone();
        let mut dropped = BTreeSet::new();
        for l in &mut out.layers {
            let Some(r) = l.range else { continue };
            let c = clamped(TimeRange::new(r.start - a, r.duration), d);
            l.range = Some(c);
            if c.is_empty() {
                dropped.insert(l.id);
            }
        }
        if !dropped.is_empty() && dropped.len() < out.layers.len() {
            out.remove_layers(&dropped);
        }
        out
    }

    /// Removes layers; a group left with fewer than two members dissolves, and a layer that followed a removed one is
    /// unpinned.
    // shortcut: private copy of the Graphics `remove` rule, because that edit belongs to the Graphics module; point this at
    // it when both are merged.
    fn remove_layers(&mut self, ids: &BTreeSet<Id>) {
        self.layers.retain(|l| !ids.contains(&l.id));
        for l in &mut self.layers {
            if matches!(l.follow.as_ref().map(|f| f.target), Some(FollowTarget::Layer(t)) if ids.contains(&t)) {
                l.follow = None;
            }
        }
        let count = |g: Id| self.layers.iter().filter(|l| l.group == Some(g)).count();
        let dead: BTreeSet<Id> = self.groups.iter().map(|g| g.id).filter(|g| count(*g) < 2).collect();
        if dead.is_empty() {
            return;
        }
        self.groups.retain(|g| !dead.contains(&g.id));
        for l in &mut self.layers {
            if l.group.is_some_and(|g| dead.contains(&g)) {
                l.group = None;
            }
        }
    }

    /// Every item's key times (Motion, Opacity, effects) through `f`. Item keys are in the clip's local time like the
    /// clip's own keys, so every edit that moves the clip's keys moves them the same way (`Clip::remap_variant_keys`): a
    /// head trim and a cut keep them on their frames, a retime scales and a reverse mirrors them.
    pub(crate) fn remap_item_keys(&mut self, f: &impl Fn(Time) -> Time) {
        for l in &mut self.layers {
            l.animation = l.animation.remapped(f);
            l.effects = l.effects.iter().map(|e| e.remapped(f)).collect();
        }
    }

    /// Retime: ranges scale with the clip from `old` to `new` duration; `mirror` flips them inside the clip.
    pub(crate) fn rescale_item_ranges(&mut self, old: Time, new: Time, mirror: bool) {
        for l in &mut self.layers {
            let Some(r) = l.range else { continue };
            let (mut a, mut b) = (Time::scaled(r.start, new, old), Time::scaled(r.end(), new, old));
            if mirror {
                (a, b) = (new - b, new - a);
            }
            l.range = Some(clamped(TimeRange::from_end(a, a.max(b)), new));
        }
    }

    // Editing (item lanes in the timeline)

    /// Moves the item's range so it starts at clip-local `start`, keeping its length and staying inside the clip.
    pub fn move_item_range(&mut self, id: Id, start: Time, d: Time) {
        let Some(l) = self.layers.iter_mut().find(|l| l.id == id) else { return };
        let Some(r) = l.range else { return };
        if r.duration >= d {
            return;
        }
        let a = start.max(Time::ZERO).min(d - r.duration);
        l.range = normalized(TimeRange::new(a, r.duration), d);
    }

    /// Moves one edge of the item's range to clip-local `t`, inside the clip and never shorter than `minimum`.
    pub fn trim_item_range(&mut self, id: Id, edge: ClipEdge, t: Time, d: Time, minimum: Time) {
        if d <= Time::ZERO {
            return;
        }
        let Some(i) = self.layers.iter().position(|l| l.id == id) else { return };
        let r = self.shown_range(&self.layers[i], d);
        let least = minimum.min(d);
        let out = match edge {
            ClipEdge::Head => {
                let end = r.end().max(least);
                TimeRange::from_end(t.max(Time::ZERO).min(end - least), end)
            }
            ClipEdge::Tail => {
                let start = r.start.min(d - least);
                TimeRange::from_end(start, t.min(d).max(start + least))
            }
        };
        self.layers[i].range = normalized(out, d);
    }

    /// Item lane paste: gives every item in `ids` the range `r` (clamped to the clip; `None` = whole clip).
    pub fn set_range(&mut self, r: Option<TimeRange>, ids: &BTreeSet<Id>, d: Time) {
        let value = r.map(|r| clamped(r, d));
        for l in self.layers.iter_mut().filter(|l| ids.contains(&l.id)) {
            l.range = value;
        }
    }
}

impl Clip {
    /// After a trim that grew the head by `g` (0 for the tail): item ranges follow (no work without ranges).
    pub(crate) fn rebase_item_ranges(&mut self, g: Time) {
        let d = self.duration();
        if let Some(doc) = self.graphics_store.as_mut().filter(|doc| doc.has_item_ranges()) {
            doc.rebase_item_ranges(g, d);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BlendMode, ClipAnimation, GraphicsContent, GraphicsGroup};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn r(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(s(a), s(b))
    }

    fn layer(n: u128, range: Option<TimeRange>) -> GraphicsLayer {
        GraphicsLayer {
            id: Id::from_u128(n),
            name: format!("l{n}"),
            content: GraphicsContent::Shape { kind: crate::ShapeKind::Rectangle },
            animation: ClipAnimation::default(),
            effects: Vec::new(),
            blend_mode: BlendMode::Normal,
            is_visible: true,
            is_locked: false,
            group: None,
            follow: None,
            range,
            label: None,
        }
    }

    fn doc(ranges: &[Option<TimeRange>]) -> GraphicsDocument {
        let layers = ranges.iter().enumerate().map(|(i, r)| layer(i as u128 + 1, *r)).collect();
        GraphicsDocument { layers, groups: Vec::new() }
    }

    fn ranges(d: &GraphicsDocument) -> Vec<Option<TimeRange>> {
        d.layers.iter().map(|l| l.range).collect()
    }

    #[test]
    fn a_layer_shows_inside_its_range_only() {
        let l = layer(1, Some(r(2, 4)));
        assert!(!l.is_shown(s(1)) && l.is_shown(s(2)) && l.is_shown(s(3)) && !l.is_shown(s(4)));
        assert!(layer(2, None).is_shown(s(100)));
        assert_eq!(l.text_time(s(3)), GraphicsTextTime { local: s(1), duration: Some(s(2)) });
        assert_eq!(layer(2, None).text_time(s(3)), GraphicsTextTime { local: s(3), duration: None });
    }

    #[test]
    fn a_head_trim_moves_ranges_and_clamps_them_to_the_clip() {
        let mut d = doc(&[Some(r(1, 4)), None, Some(r(8, 9))]);
        d.rebase_item_ranges(s(2), s(6));
        assert_eq!(ranges(&d), vec![Some(r(3, 6)), None, Some(r(6, 6))]);
        let mut shrink = doc(&[Some(r(1, 4))]);
        shrink.rebase_item_ranges(s(-3), s(5));
        assert_eq!(ranges(&shrink), vec![Some(r(0, 1))]);
    }

    #[test]
    fn a_cut_drops_items_without_a_part_in_the_piece() {
        let d = doc(&[Some(r(1, 3)), Some(r(6, 8)), None]);
        let piece = d.cropping_item_ranges(s(5), s(5));
        assert_eq!(piece.layers.iter().map(|l| l.id).collect::<Vec<_>>(), vec![Id::from_u128(2), Id::from_u128(3)]);
        assert_eq!(piece.layers[0].range, Some(r(1, 3)));
        // Nothing left to show: every item stays as an empty stub.
        let stubs = doc(&[Some(r(1, 2)), Some(r(2, 3))]).cropping_item_ranges(s(5), s(5));
        assert_eq!(ranges(&stubs), vec![Some(r(0, 0)), Some(r(0, 0))]);
        // No ranges: untouched.
        assert_eq!(doc(&[None]).cropping_item_ranges(s(5), s(5)), doc(&[None]));
    }

    #[test]
    fn dropping_a_member_dissolves_a_pair_group_and_unpins_followers() {
        let mut d = doc(&[Some(r(0, 1)), Some(r(5, 8)), None]);
        d.groups = vec![GraphicsGroup { id: Id::from_u128(50), name: "G".into() }];
        d.layers[0].group = Some(Id::from_u128(50));
        d.layers[1].group = Some(Id::from_u128(50));
        d.layers[2].follow = Some(crate::GraphicsFollow {
            target: FollowTarget::Layer(Id::from_u128(1)),
            edges: crate::GraphicsEdges(15),
            padding: 0.0,
            edge_padding: None,
        });
        let piece = d.cropping_item_ranges(s(5), s(5));
        assert!(piece.groups.is_empty());
        assert!(piece.layers.iter().all(|l| l.group.is_none()));
        assert!(piece.layers[1].follow.is_none());
    }

    #[test]
    fn a_retime_scales_and_a_reverse_mirrors() {
        let mut d = doc(&[Some(r(1, 3)), None]);
        d.rescale_item_ranges(s(10), s(5), false);
        assert_eq!(ranges(&d), vec![Some(TimeRange::from_end(Time::new(1, 2), Time::new(3, 2))), None]);
        let mut m = doc(&[Some(r(1, 3))]);
        m.rescale_item_ranges(s(10), s(10), true);
        assert_eq!(ranges(&m), vec![Some(r(7, 9))]);
    }

    #[test]
    fn moving_a_range_keeps_its_length_inside_the_clip() {
        let mut d = doc(&[Some(r(1, 3))]);
        let id = Id::from_u128(1);
        d.move_item_range(id, s(20), s(10));
        assert_eq!(ranges(&d), vec![Some(r(8, 10))]);
        d.move_item_range(id, s(-5), s(10));
        assert_eq!(ranges(&d), vec![Some(r(0, 2))]);
        // A range that now fills the clip start would still be a range; one as long as the clip is dropped.
        let mut full = doc(&[Some(r(0, 10))]);
        full.move_item_range(id, s(3), s(10));
        assert_eq!(ranges(&full), vec![Some(r(0, 10))]);
    }

    #[test]
    fn trimming_an_edge_never_goes_below_the_minimum_and_a_full_range_becomes_none() {
        let id = Id::from_u128(1);
        let mut d = doc(&[Some(r(2, 6))]);
        d.trim_item_range(id, ClipEdge::Head, s(9), s(10), s(1));
        assert_eq!(ranges(&d), vec![Some(r(5, 6))]);
        d.trim_item_range(id, ClipEdge::Tail, s(0), s(10), s(1));
        assert_eq!(ranges(&d), vec![Some(r(5, 6))]);
        d.trim_item_range(id, ClipEdge::Head, s(-4), s(10), s(1));
        d.trim_item_range(id, ClipEdge::Tail, s(40), s(10), s(1));
        assert_eq!(ranges(&d), vec![None]);
    }

    #[test]
    fn set_range_clamps_and_clears() {
        let mut d = doc(&[None, None]);
        let ids = BTreeSet::from([Id::from_u128(2)]);
        d.set_range(Some(r(-2, 20)), &ids, s(10));
        assert_eq!(ranges(&d), vec![None, Some(r(0, 10))]);
        d.set_range(None, &ids, s(10));
        assert_eq!(ranges(&d), vec![None, None]);
    }

    // MARK: Clip edits on a Graphic placed with `add_generator_clip`

    fn named(name: &str, range: Option<TimeRange>) -> GraphicsLayer {
        let mut l = layer(name.bytes().map(u128::from).sum(), range);
        l.name = name.to_string();
        l
    }

    /// A 10 s Graphic at 2 s holding `items`, placed the way the app does.
    fn graphic(items: Vec<GraphicsLayer>) -> Clip {
        use crate::nesting::test_util::*;
        use crate::project_media_ops::GeneratorPlacement;
        let mut p = project_json(vec![], vec![timeline_json(1, vec![track_json(11, "video", vec![])])]);
        let at = GeneratorPlacement { timeline: id(1), track: id(11), start: s(2), duration: s(10) };
        let id = p
            .add_generator_clip(crate::GeneratorRef::graphics_clip(), Some("Graphic"), at, &mut TestIds(700))
            .unwrap_or(Id::NIL);
        let mut c = p.timelines[0].tracks[0].clip(id).cloned().unwrap_or_else(|| panic!("no graphic"));
        c.graphics_store = Some(GraphicsDocument { layers: items, groups: Vec::new() });
        c
    }

    fn by_name(c: &Clip) -> Vec<(String, Option<TimeRange>)> {
        c.graphics_store.iter().flat_map(|d| d.layers.iter().map(|l| (l.name.clone(), l.range))).collect()
    }

    fn expect(list: &[(&str, Option<TimeRange>)]) -> Vec<(String, Option<TimeRange>)> {
        list.iter().map(|(n, r)| (n.to_string(), *r)).collect()
    }

    #[test]
    fn a_head_trim_keeps_items_on_their_frames_and_clamps() {
        let mut c = graphic(vec![
            named("in", Some(r(4, 6))),
            named("cut", Some(r(1, 5))),
            named("gone", Some(r(0, 2))),
            named("whole", None),
        ]);
        c.extend_head(-s(3)); // 3 s shorter at the head
        assert_eq!(c.duration(), s(7));
        assert_eq!(
            by_name(&c),
            expect(&[("in", Some(r(1, 3))), ("cut", Some(r(0, 2))), ("gone", Some(r(0, 0))), ("whole", None)])
        );
        c.extend_head(s(2)); // longer again: ranges move with their frames
        assert_eq!(
            by_name(&c),
            expect(&[("in", Some(r(3, 5))), ("cut", Some(r(2, 4))), ("gone", Some(r(2, 2))), ("whole", None)])
        );
    }

    #[test]
    fn a_tail_trim_clamps_and_does_not_grow_back() {
        let mut c = graphic(vec![
            named("in", Some(r(1, 3))),
            named("cut", Some(r(5, 9))),
            named("gone", Some(r(8, 10))),
            named("whole", None),
        ]);
        c.extend_tail(-s(4));
        assert_eq!(c.duration(), s(6));
        let clamped =
            expect(&[("in", Some(r(1, 3))), ("cut", Some(r(5, 6))), ("gone", Some(r(6, 6))), ("whole", None)]);
        assert_eq!(by_name(&c), clamped);
        c.extend_tail(s(4)); // a clamped range does not grow back by itself
        assert_eq!(by_name(&c), clamped);
    }

    #[test]
    fn a_split_divides_ranges_across_the_halves_and_drops_stubs() {
        let c = graphic(vec![
            named("left", Some(r(1, 3))),
            named("right", Some(r(6, 9))),
            named("both", Some(r(2, 7))),
            named("whole", None),
        ]);
        let (a, b) = (c.cropped(TimeRange::from_end(s(2), s(6))), c.cropped(TimeRange::from_end(s(6), s(12))));
        let (a, b) = (a.unwrap_or_else(|| c.clone()), b.unwrap_or_else(|| c.clone())); // local 4 is the cut
        assert_eq!(by_name(&a), expect(&[("left", Some(r(1, 3))), ("both", Some(r(2, 4))), ("whole", None)]));
        assert_eq!(by_name(&b), expect(&[("right", Some(r(2, 5))), ("both", Some(r(0, 3))), ("whole", None)]));
        let stubs = graphic(vec![named("stub", Some(r(4, 4))), named("whole", None)]);
        let left = stubs.cropped(TimeRange::from_end(s(2), s(6))).unwrap_or_else(|| stubs.clone());
        assert_eq!(by_name(&left), expect(&[("whole", None)]));
    }

    #[test]
    fn a_dropped_item_takes_its_follow_link_along() {
        let a = named("a", Some(r(0, 2)));
        let mut b = named("b", None);
        b.follow = Some(crate::GraphicsFollow {
            target: FollowTarget::Layer(a.id),
            edges: crate::GraphicsEdges(15),
            padding: 0.0,
            edge_padding: None,
        });
        let c = graphic(vec![a, b]);
        let right = c.cropped(TimeRange::from_end(s(7), s(12))).unwrap_or_else(|| c.clone());
        let layers = right.graphics_store.map(|d| d.layers).unwrap_or_default();
        assert_eq!(layers.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), ["b"]);
        assert!(layers[0].follow.is_none());
    }

    #[test]
    fn a_retime_scales_ranges_and_a_reverse_mirrors_them() {
        let mut c = graphic(vec![named("a", Some(r(2, 6))), named("whole", None)]);
        c.rescale_keys(s(10), s(5), false);
        assert_eq!(by_name(&c), expect(&[("a", Some(r(1, 3))), ("whole", None)]));
        c.rescale_keys(s(5), s(5), true); // reversed: mirrored inside the clip
        assert_eq!(by_name(&c), expect(&[("a", Some(r(2, 4))), ("whole", None)]));
    }
}
