// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGradeLinks.swift (Clip and Project parts) and the Clip accessors of ColorGradeTargets.swift
//! Linked grades (`Clip::grade_link`): clips that share one base grade, copied to every member after each edit. Also the
//! per-clip "Linked" switch (`grade_independent`) and the project-wide LUT path helpers.

use crate::{ClipEffectColorExt, ClipGradeExt};
use sq_core_model::{AnimatedProperty, COLOR_KIND, Clip, ClipEffect, LUTRef, Project};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeValue};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// `fx` without effect ids, to compare grades.
pub fn comparable_grade(fx: &[ClipEffect]) -> Vec<ClipEffect> {
    fx.iter().map(|e| ClipEffect { id: Id::NIL, ..e.clone() }).collect()
}

/// `comparable_grade` without key times (keys in id order): what is left of a grade when a trim, retime or crop moved its
/// keys. Those moves are no grade edit.
pub(crate) fn timing_free_grade(fx: &[ClipEffect]) -> Vec<ClipEffect> {
    fn strip<V: KeyframeValue + Clone>(p: &AnimatedProperty<V>) -> AnimatedProperty<V> {
        let mut keys: Vec<Keyframe<V>> =
            p.track.keys.iter().cloned().map(|k| Keyframe { time: sq_core_time::Time::ZERO, ..k }).collect();
        keys.sort_by_key(|k| k.id);
        let mut c = p.clone();
        c.track = sq_core_time::KeyframeTrack::with_keys(keys);
        c
    }
    comparable_grade(fx)
        .into_iter()
        .map(|mut e| {
            e.parameters = e.parameters.iter().map(|(k, p)| (k.clone(), strip(p))).collect();
            e.colors = e.colors.iter().map(|(k, p)| (k.clone(), strip(p))).collect();
            e.points = e.points.iter().map(|(k, p)| (k.clone(), strip(p))).collect();
            e
        })
        .collect()
}

fn is_embedded(l: &Option<LUTRef>) -> bool {
    matches!(l, Some(LUTRef::Embedded { .. }))
}

fn is_own_embedded(l: &Option<LUTRef>, media: Id) -> bool {
    matches!(l, Some(LUTRef::Embedded { media: m }) if *m == media)
}

/// Grade links and the "Linked" switch on a clip.
pub trait ClipGradeLinksExt {
    /// "Linked" switched off in the Color target bar: this clip keeps its own grade, source linking skips it.
    fn grade_independent(&self) -> bool;
    /// Sets or clears `grade_independent` (stored as present-or-absent).
    fn set_grade_independent(&mut self, on: bool);
    /// Takes part in source grade linking: a picture clip of media (no generator, adjustment layer or nested sequence).
    fn is_source_gradeable(&self) -> bool;
    /// Same place, length, speed and direction: an edit that changes none of these cannot have moved keys.
    fn has_same_timing(&self, other: &Clip) -> bool;
    /// Replaces the base grade with copies of `fx`, keeping this clip's own effect ids and the place of its range grades
    /// (base slot n takes `fx[n]`; extra effects go after the last base slot, missing ones are removed). The conversion
    /// LUT and the look are media-specific: an embedded LUT of other media falls back (`adapting_luts`), a clip's own
    /// embedded LUT stays, and when `previous` (the source's base grade before the edit) shows the slot did not change,
    /// this clip keeps whatever it had there, so an adapted copy never travels back. Keys are moved from `src`'s
    /// clip-local time to this clip's through the source time both play. Ignored on clips that take no color.
    fn replace_base_grade(
        &mut self,
        fx: &[ClipEffect],
        previous: Option<&[ClipEffect]>,
        src: Option<&Clip>,
        ids: &mut dyn IdSource,
    );
    /// `e` (a Color effect of `src`) with its key times moved from `src`'s clip-local time to this clip's, through the
    /// source time both play: linked cuts of one source take a key on the same frame of the footage. Other media,
    /// generators, nested clips and freeze frames keep the times as they are.
    fn mapping_key_times(&self, e: &ClipEffect, src: &Clip) -> ClipEffect;
}

impl ClipGradeLinksExt for Clip {
    fn grade_independent(&self) -> bool {
        self.grade_independent_store == Some(true)
    }

    fn set_grade_independent(&mut self, on: bool) {
        self.grade_independent_store = on.then_some(true);
    }

    fn is_source_gradeable(&self) -> bool {
        self.accepts_color() && !self.is_generator() && !self.is_nested()
    }

    fn has_same_timing(&self, o: &Clip) -> bool {
        self.start == o.start
            && self.source == o.source
            && self.speed == o.speed
            && self.reversed == o.reversed
            && self.speed_keys == o.speed_keys
            && self.hold_frame == o.hold_frame
    }

    fn replace_base_grade(
        &mut self,
        fx: &[ClipEffect],
        previous: Option<&[ClipEffect]>,
        src: Option<&Clip>,
        ids: &mut dyn IdSource,
    ) {
        if !self.accepts_color() {
            return;
        }
        // The source's Pro grade (and Simple | Pro) goes along, same rule as a paste.
        if let Some(s) = src {
            self.apply_copied_graph(s.color_graph(), ids);
        }
        let incoming: Vec<&ClipEffect> = fx.iter().filter(|e| e.is_color()).collect();
        let media = self.media;
        let next = |me: &Clip, n: usize, own: Option<&ClipEffect>, ids: &mut dyn IdSource| -> ClipEffect {
            let e = incoming[n];
            let moved = src.map_or_else(|| e.clone(), |s| me.mapping_key_times(e, s));
            let mut c = moved.adapting_luts(media, n == 0);
            c.id = own.map_or_else(|| ids.next_id(), |o| o.id);
            c.color_range = None;
            if let Some(own) = own {
                let mut d = c.color_data();
                let mine = own.color_data();
                let theirs = e.color_data();
                let prev = previous.and_then(|p| p.get(n)).map(|p| p.color_data());
                // `prev?.inputLUT == theirs.inputLUT` in Swift: an absent previous reads as "no LUT".
                if prev.as_ref().and_then(|p| p.input_lut.clone()) == theirs.input_lut
                    || is_own_embedded(&mine.input_lut, media) && is_embedded(&theirs.input_lut)
                {
                    d.input_lut =
                        if n == 0 || mine.input_lut != Some(LUTRef::Automatic) { mine.input_lut.clone() } else { None };
                }
                if prev.as_ref().and_then(|p| p.look.clone()) == theirs.look
                    || is_own_embedded(&mine.look, media) && is_embedded(&theirs.look)
                {
                    d.look = mine.look.clone();
                }
                c.grade = Some(d);
            }
            c
        };
        let mut n = 0usize;
        let colour: Vec<ClipEffect> = self.effects.iter().filter(|e| e.is_color()).cloned().collect();
        let mut out: Vec<ClipEffect> = Vec::new();
        let mut last_base: Option<usize> = None;
        for e in &colour {
            if e.is_range_grade() {
                out.push(e.clone());
                continue;
            }
            if n >= incoming.len() {
                continue;
            }
            out.push(next(self, n, Some(e), ids));
            n += 1;
            last_base = Some(out.len() - 1);
        }
        let mut extra: Vec<ClipEffect> = Vec::new();
        while n < incoming.len() {
            extra.push(next(self, n, None, ids));
            n += 1;
        }
        let at = last_base.map_or(0, |i| i + 1);
        out.splice(at..at, extra);
        if out.first().is_some_and(|f| f.is_range_grade()) {
            out.insert(0, crate::clip_grade::neutral_base_grade(ids));
        }
        self.effects.retain(|e| !e.is_color());
        self.effects.splice(0..0, out);
    }

    fn mapping_key_times(&self, e: &ClipEffect, src: &Clip) -> ClipEffect {
        if src.id == self.id
            || src.media != self.media
            || src.is_generator()
            || self.is_generator()
            || src.is_nested()
            || self.is_nested()
            || src.hold_frame.is_some()
            || self.hold_frame.is_some()
        {
            return e.clone();
        }
        fn map<V: KeyframeValue + Clone>(
            p: &AnimatedProperty<V>,
            to_local: &dyn Fn(sq_core_time::Time) -> sq_core_time::Time,
        ) -> AnimatedProperty<V> {
            if p.track.keys.is_empty() {
                return p.clone();
            }
            let mut keys: Vec<Keyframe<V>> =
                p.track.keys.iter().map(|k| Keyframe { time: to_local(k.time), ..k.clone() }).collect();
            keys.sort_by_key(|k| k.time);
            let mut c = p.clone();
            c.track = sq_core_time::KeyframeTrack::with_keys(keys);
            c
        }
        let to_local = |t| self.local_time_for_instant(src.source_instant(t));
        let mut c = e.clone();
        c.parameters = e.parameters.iter().map(|(k, p)| (k.clone(), map(p, &to_local))).collect();
        c.colors = e.colors.iter().map(|(k, p)| (k.clone(), map(p, &to_local))).collect();
        c.points = e.points.iter().map(|(k, p)| (k.clone(), map(p, &to_local))).collect();
        c
    }
}

/// Grade links and LUT paths across a whole project.
pub trait ProjectGradeLinksExt {
    /// Runs `body` on every clip of every sequence (nested sequences are timelines of their own, so they are included).
    fn for_each_clip_in_place(&mut self, body: impl FnMut(&mut Clip));
    /// Every clip of every sequence, in project order.
    fn all_clips(&self) -> Vec<&Clip>;
    /// The clip with this id in any sequence.
    fn any_clip(&self, id: Id) -> Option<&Clip>;
    /// Every LUT file path a grade of any clip refers to (Input LUT and Creative look), each once, in first-seen order.
    fn referenced_lut_files(&self) -> Vec<String>;
    /// Rewrites LUT file paths in every grade through `map` (`None` keeps the path). Not an edit: callers use it on the
    /// history-neutral amend path.
    fn replace_lut_paths(&mut self, map: impl FnMut(&str) -> Option<String>);
    /// The clips sharing `id`'s grade, in project order (empty when it is not linked).
    fn grade_link_members(&self, id: Id) -> Vec<Id>;
    /// Links the picture clips of `ids` (plus `source`) so they share one grade: they take `source`'s base grade and its
    /// link (a new one when it has none). Clips leaving another group dissolve it when one member is left. `None`
    /// (nothing changes) when fewer than two clips can take color.
    fn link_grades(&mut self, ids: &BTreeSet<Id>, source: Id, new_ids: &mut dyn IdSource) -> Option<Id>;
    /// Links every picture clip of `id`'s media in the project to `id`'s grade.
    fn link_all_clips_of_source(&mut self, id: Id, new_ids: &mut dyn IdSource) -> Option<Id>;
    /// Takes `ids` out of their grade links (each keeps its grade). A clip taken out has "Linked" off from then on
    /// (`grade_independent`), so its next Color edit does not pull it back into its source's grade. True when a link
    /// changed.
    fn unlink_grades(&mut self, ids: &BTreeSet<Id>) -> bool;
    /// A link with a single member is no link.
    fn dissolve_lonely_grade_links(&mut self);
    /// Runs after every edit (`old` = the project before it): the first member of each grade link (project order) whose
    /// base grade changed in the edit becomes the grade of the others; links left with one member dissolve; a range grade
    /// that became a clip's first Color effect gets a neutral base under it.
    fn propagate_grade_links(&mut self, old: &Project, new_ids: &mut dyn IdSource);
    /// A Color effect holds a Color Range (HSL secondary): the file needs v48.
    fn contains_color_range_qualifiers(&self) -> bool;
    /// A grade link or a range grade exists: the file needs v45.
    fn contains_grade_links_or_ranges(&self) -> bool;
}

impl ProjectGradeLinksExt for Project {
    fn for_each_clip_in_place(&mut self, mut body: impl FnMut(&mut Clip)) {
        for t in &mut self.timelines {
            for tr in &mut t.tracks {
                tr.map_clips_keeping_timing(|c| {
                    let mut c = c.clone();
                    body(&mut c);
                    c
                });
            }
        }
    }

    fn all_clips(&self) -> Vec<&Clip> {
        self.timelines.iter().flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips())).collect()
    }

    fn any_clip(&self, id: Id) -> Option<&Clip> {
        self.all_clips().into_iter().find(|c| c.id == id)
    }

    fn referenced_lut_files(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        for c in self.all_clips() {
            for fx in c.effects.iter().filter(|e| e.is_color()) {
                let d = fx.color_data();
                for l in [d.input_lut, d.look] {
                    if let Some(LUTRef::File { path }) = l
                        && seen.insert(path.clone())
                    {
                        out.push(path);
                    }
                }
            }
        }
        out
    }

    fn replace_lut_paths(&mut self, mut map: impl FnMut(&str) -> Option<String>) {
        let mut swap = |r: Option<LUTRef>| match r {
            Some(LUTRef::File { path }) => match map(&path) {
                Some(n) if n != path => Some(LUTRef::File { path: n }),
                _ => Some(LUTRef::File { path }),
            },
            other => other,
        };
        self.for_each_clip_in_place(|c| {
            for e in c.effects.iter_mut().filter(|e| e.is_color()) {
                let mut d = e.color_data();
                d.input_lut = swap(d.input_lut.take());
                d.look = swap(d.look.take());
                e.grade = Some(d);
            }
        });
    }

    fn grade_link_members(&self, id: Id) -> Vec<Id> {
        let Some(l) = self.any_clip(id).and_then(|c| c.grade_link) else { return Vec::new() };
        self.all_clips().into_iter().filter(|c| c.grade_link == Some(l)).map(|c| c.id).collect()
    }

    fn link_grades(&mut self, ids: &BTreeSet<Id>, source: Id, new_ids: &mut dyn IdSource) -> Option<Id> {
        let src = self.any_clip(source).filter(|c| c.accepts_color())?.clone();
        let members: BTreeSet<Id> = self
            .all_clips()
            .into_iter()
            .filter(|c| (ids.contains(&c.id) || c.id == source) && c.accepts_color())
            .map(|c| c.id)
            .collect();
        if members.len() < 2 {
            return None;
        }
        let link = src.grade_link.unwrap_or_else(|| new_ids.next_id());
        let base = src.base_grade_effects();
        self.for_each_clip_in_place(|c| {
            if !members.contains(&c.id) {
                return;
            }
            c.grade_link = Some(link);
            c.set_grade_independent(false);
            if c.id != source {
                c.replace_base_grade(&base, None, Some(&src), new_ids);
            }
        });
        self.dissolve_lonely_grade_links();
        Some(link)
    }

    fn link_all_clips_of_source(&mut self, id: Id, new_ids: &mut dyn IdSource) -> Option<Id> {
        let src = self.any_clip(id).filter(|c| c.accepts_color() && !c.is_generator() && !c.is_nested())?;
        let media = src.media;
        let same: BTreeSet<Id> = self
            .all_clips()
            .into_iter()
            .filter(|c| c.media == media && c.accepts_color() && !c.is_generator() && !c.is_nested())
            .map(|c| c.id)
            .collect();
        self.link_grades(&same, id, new_ids)
    }

    fn unlink_grades(&mut self, ids: &BTreeSet<Id>) -> bool {
        let mut changed = false;
        self.for_each_clip_in_place(|c| {
            if !ids.contains(&c.id) || c.grade_link.is_none() {
                return;
            }
            c.grade_link = None;
            if c.is_source_gradeable() {
                c.set_grade_independent(true);
            }
            changed = true;
        });
        if changed {
            self.dissolve_lonely_grade_links();
        }
        changed
    }

    fn dissolve_lonely_grade_links(&mut self) {
        let mut count: BTreeMap<Id, usize> = BTreeMap::new();
        for c in self.all_clips() {
            if let Some(l) = c.grade_link {
                *count.entry(l).or_insert(0) += 1;
            }
        }
        let lonely: BTreeSet<Id> = count.into_iter().filter(|&(_, n)| n < 2).map(|(l, _)| l).collect();
        if lonely.is_empty() {
            return;
        }
        self.for_each_clip_in_place(|c| {
            if c.grade_link.is_some_and(|l| lonely.contains(&l)) {
                c.grade_link = None;
            }
        });
    }

    fn propagate_grade_links(&mut self, old: &Project, new_ids: &mut dyn IdSource) {
        let linked = self.all_clips().iter().any(|c| c.grade_link.is_some());
        let range_fix = self
            .all_clips()
            .iter()
            .any(|c| c.effects.iter().find(|e| e.is_color()).is_some_and(|f| f.color_range.is_some()));
        if range_fix {
            self.for_each_clip_in_place(|c| {
                c.ensure_base_under_range_grades(new_ids);
            });
        }
        if !linked && !old.all_clips().iter().any(|c| c.grade_link.is_some()) {
            return;
        }
        let before: HashMap<Id, &Clip> =
            old.all_clips().into_iter().filter(|c| c.grade_link.is_some()).map(|c| (c.id, c)).collect();
        // A member whose grade changed only because its keys moved with a trim, retime or crop is no source.
        struct Source {
            clip: Clip,
            fx: Vec<ClipEffect>,
            previous: Vec<ClipEffect>,
        }
        let mut source: HashMap<Id, Source> = HashMap::new();
        for c in self.all_clips() {
            let Some(l) = c.grade_link else { continue };
            let Some(b) = before.get(&c.id) else { continue };
            if source.contains_key(&l) {
                continue;
            }
            let (now, was) = (c.base_grade_effects(), b.base_grade_effects());
            let edited = if c.has_same_timing(b) {
                comparable_grade(&now) != comparable_grade(&was)
            } else {
                timing_free_grade(&now) != timing_free_grade(&was)
            };
            // The Pro grade has no keys: any change of it, or of Simple | Pro, is an edit.
            if edited || c.color_graph() != b.color_graph() {
                source.insert(l, Source { clip: c.clone(), fx: now, previous: was });
            }
        }
        if !source.is_empty() {
            self.for_each_clip_in_place(|c| {
                let Some(l) = c.grade_link else { return };
                let Some(s) = source.get(&l) else { return };
                if s.clip.id != c.id {
                    c.replace_base_grade(&s.fx, Some(&s.previous), Some(&s.clip), new_ids);
                }
            });
        }
        self.dissolve_lonely_grade_links();
    }

    fn contains_color_range_qualifiers(&self) -> bool {
        self.all_clips().iter().any(|c| {
            c.effects
                .iter()
                .any(|e| e.kind == COLOR_KIND && e.grade.as_ref().is_some_and(|g| g.hsl_secondary.is_some()))
        })
    }

    fn contains_grade_links_or_ranges(&self) -> bool {
        self.all_clips().iter().any(|c| c.grade_link.is_some() || c.effects.iter().any(|e| e.is_range_grade()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{ColorEffect, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn clip(ids: &mut SequentialIds, start: i64, media: Option<Id>) -> Clip {
        let source = TimeRange::new(Time::ZERO, Time::new(4, 1));
        let m = media.unwrap_or_else(|| ids.next_id());
        let mut c = Clip::new(ids.next_id(), "c", m, TrackKind::Video, source, Time::new(start, 1));
        c.media_duration = Some(Time::new(20, 1));
        c
    }

    fn warm(t: f32, ids: &mut SequentialIds) -> ClipEffect {
        let mut e = ColorEffect::new(1, None);
        e.basic.temperature = t;
        ClipEffect::color_grade(ids.next_id(), &e, ids)
    }

    fn project(clips: Vec<Clip>, ids: &mut SequentialIds) -> Project {
        let mut track = Track::new(ids.next_id(), TrackKind::Video);
        track.set_clips(clips);
        let tl = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        Project::new(ids.next_id(), "P", Vec::new(), vec![tl])
    }

    fn find(p: &Project, id: Id) -> Clip {
        p.any_clip(id).cloned().expect("clip")
    }

    fn temperature(c: &Clip) -> f32 {
        c.color().effects().first().map_or(0.0, |e| e.basic.temperature)
    }

    /// One panel edit on `id`, then the session's propagation step.
    fn edit(p: &mut Project, id: Id, t: f32, ids: &mut SequentialIds) {
        let old = p.clone();
        p.for_each_clip_in_place(|c| {
            if c.id != id {
                return;
            }
            let mut e = c.effects[0].color_effect(None, 1);
            e.basic.temperature = t;
            c.effects[0].set_color_effect(&e, None, &mut SequentialIds::default());
        });
        p.propagate_grade_links(&old, ids);
    }

    #[test]
    fn linking_copies_the_source_grade_and_shares_one_id() {
        let mut ids = SequentialIds::default();
        let mut a = clip(&mut ids, 0, None);
        a.effects = vec![warm(30.0, &mut ids)];
        let (b, c) = (clip(&mut ids, 4, None), clip(&mut ids, 8, None));
        let all: BTreeSet<Id> = [a.id, b.id, c.id].into();
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b, c], &mut ids);
        let link = p.link_grades(&all, aid, &mut ids).expect("linked");
        for id in &all {
            assert_eq!(find(&p, *id).grade_link, Some(link));
            assert_eq!(temperature(&find(&p, *id)), 30.0);
        }
        assert_eq!(p.grade_link_members(bid).into_iter().collect::<BTreeSet<_>>(), all);
    }

    #[test]
    fn linking_needs_two_picture_clips() {
        let mut ids = SequentialIds::default();
        let a = clip(&mut ids, 0, None);
        let mut sound = clip(&mut ids, 0, None);
        sound.kind = TrackKind::Audio;
        let set: BTreeSet<Id> = [a.id, sound.id].into();
        let aid = a.id;
        let mut p = project(vec![a, sound], &mut ids);
        assert!(p.link_grades(&set, aid, &mut ids).is_none());
        assert!(p.all_clips().iter().all(|c| c.grade_link.is_none()));
    }

    #[test]
    fn editing_one_member_updates_all_and_leaves_others() {
        let mut ids = SequentialIds::default();
        let (mut a, mut b, mut l) = (clip(&mut ids, 0, None), clip(&mut ids, 4, None), clip(&mut ids, 8, None));
        for c in [&mut a, &mut b, &mut l] {
            c.effects = vec![warm(0.0, &mut ids)];
        }
        let (aid, bid, lid) = (a.id, b.id, l.id);
        let mut p = project(vec![a, b, l], &mut ids);
        assert!(p.link_grades(&[aid, bid].into(), aid, &mut ids).is_some());
        edit(&mut p, bid, -25.0, &mut ids);
        assert_eq!(temperature(&find(&p, aid)), -25.0);
        assert_eq!(temperature(&find(&p, bid)), -25.0);
        assert_eq!(temperature(&find(&p, lid)), 0.0);
    }

    #[test]
    fn propagation_keeps_the_targets_effect_ids() {
        let mut ids = SequentialIds::default();
        let mut a = clip(&mut ids, 0, None);
        a.effects = vec![warm(10.0, &mut ids)];
        let b = clip(&mut ids, 4, None);
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        assert!(p.link_grades(&[aid, bid].into(), aid, &mut ids).is_some());
        let before = find(&p, bid).color_grade_effects()[0].id;
        edit(&mut p, aid, 40.0, &mut ids);
        let nb = find(&p, bid);
        assert_eq!(nb.color_grade_effects()[0].id, before);
        assert_eq!(temperature(&nb), 40.0);
    }

    #[test]
    fn embedded_luts_are_adapted_to_each_members_media() {
        let mut ids = SequentialIds::default();
        let (ma, mb) = (ids.next_id(), ids.next_id());
        let mut a = clip(&mut ids, 0, Some(ma));
        let mut e = ColorEffect::new(1, Some(LUTRef::Embedded { media: ma }));
        e.basic.temperature = 1.0;
        a.effects = vec![ClipEffect::color_grade(ids.next_id(), &e, &mut ids)];
        let b = clip(&mut ids, 4, Some(mb));
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        assert!(p.link_grades(&[aid, bid].into(), aid, &mut ids).is_some());
        let lut = |p: &Project, id| find(p, id).color().effects()[0].input_lut.clone();
        assert_eq!(lut(&p, bid), Some(LUTRef::Automatic));
        // An edit on the target does not push its adapted LUT back over the source's embedded one.
        edit(&mut p, bid, 5.0, &mut ids);
        assert_eq!(lut(&p, aid), Some(LUTRef::Embedded { media: ma }));
        assert_eq!(lut(&p, bid), Some(LUTRef::Automatic));
        assert_eq!(temperature(&find(&p, aid)), 5.0);
        edit(&mut p, aid, 7.0, &mut ids);
        assert_eq!(lut(&p, bid), Some(LUTRef::Automatic));
        assert_eq!(temperature(&find(&p, bid)), 7.0);
    }

    #[test]
    fn unlinking_leaves_the_grade_and_dissolves_a_one_member_group() {
        let mut ids = SequentialIds::default();
        let (mut a, b) = (clip(&mut ids, 0, None), clip(&mut ids, 4, None));
        a.effects = vec![warm(30.0, &mut ids)];
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        assert!(p.link_grades(&[aid, bid].into(), aid, &mut ids).is_some());
        assert!(p.contains_grade_links_or_ranges());
        assert!(p.unlink_grades(&[bid].into()));
        assert!(p.all_clips().iter().all(|c| c.grade_link.is_none()));
        assert_eq!(temperature(&find(&p, bid)), 30.0);
        assert!(find(&p, bid).grade_independent());
        assert!(!p.contains_grade_links_or_ranges());
    }

    #[test]
    fn lut_paths_are_listed_once_and_rewritten() {
        let mut ids = SequentialIds::default();
        let mut a = clip(&mut ids, 0, None);
        let mut e = ColorEffect::new(1, Some(LUTRef::File { path: "/l/a.cube".into() }));
        e.creative.look = Some(LUTRef::File { path: "/l/a.cube".into() });
        a.effects = vec![ClipEffect::color_grade(ids.next_id(), &e, &mut ids)];
        let aid = a.id;
        let mut p = project(vec![a], &mut ids);
        assert_eq!(p.referenced_lut_files(), vec!["/l/a.cube".to_string()]);
        p.replace_lut_paths(|s| s.strip_prefix("/l/").map(|r| format!("/m/{r}")));
        assert_eq!(p.referenced_lut_files(), vec!["/m/a.cube".to_string()]);
        assert!(find(&p, aid).color().effects()[0].creative.look.is_some());
    }
}
