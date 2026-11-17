//! Color: clipboard and memories, paste/reset, grade links, range grades, the Color page edits, Interpret As, matte view.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_color::{ClipEffectColorExt, ClipGradeExt, MediaInfoColorExt, ProjectGradeLinksExt};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_model::{Clip, ClipColor, ClipEffect, EditError, Project, Timeline, TrackKind};
use sq_core_model::{ColorGraph, ColorSpaceID, ColorTriple, StepPrimaries};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};

use crate::{Change, EditorSession};
use sq_core_edit::color_grade_targets::ProjectGradeTargetsExt as _;

/// Color page, Pro grade: the monitor shows where one Step works as a white overlay on the picture. A viewing aid
/// only: the project, the undo history and the export never see it.
// Swift: ColorMattePreview.swift:7
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ColorMattePreview {
    // Swift: ColorMattePreview.swift:8
    pub clip: Id,
    // Swift: ColorMattePreview.swift:9
    pub step: Id,
}

impl ColorMattePreview {
    // Swift: ColorMattePreview.swift:10
    pub fn new(clip: Id, step: Id) -> ColorMattePreview {
        ColorMattePreview { clip, step }
    }
}

/// Primaries that send every pixel to white: gain 0 and offset 1.
// Swift: ColorMattePreview.swift:16
pub fn matte_white() -> StepPrimaries {
    StepPrimaries { gain: ColorTriple::all(0.0), offset: ColorTriple::all(1.0), ..StepPrimaries::default() }
}

/// The graph the monitor renders to show the matte of one Step (Swift `ColorGraph.matteView(of:)`).
pub trait ColorGraphMatteView {
    // Swift: ColorMattePreview.swift:28
    fn matte_view(&self, id: Id) -> Option<ColorGraph>;
}

impl ColorGraphMatteView for ColorGraph {
    fn matte_view(&self, id: Id) -> Option<ColorGraph> {
        let i = self.steps().iter().position(|s| s.id == id)?;
        let mut shown: Vec<_> = self.steps()[..i].to_vec();
        let mut s = self.steps()[i].clone();
        s.enabled = true;
        s.primaries = matte_white();
        s.curves = Default::default();
        s.hue_curves = Default::default();
        s.lut = None;
        shown.push(s);
        let mut g = ColorGraph::new(shown, self.input_lut.clone(), None, id);
        g.is_active = true;
        Some(g)
    }
}

/// This sequence with the matte view of `preview` on its clip (unchanged when the clip is not here or has no such Step).
pub(crate) fn showing_matte(t: &Timeline, preview: &ColorMattePreview) -> Timeline {
    let mut out = t.clone();
    let mut ids = SequentialIds::default();
    for ti in 0..out.tracks.len() {
        let Some(mut clip) = out.tracks[ti].clip(preview.clip).cloned() else { continue };
        let Some(g) = clip.color_graph().and_then(|g| g.matte_view(preview.step)) else { return t.clone() };
        clip.set_color_graph(Some(g), &mut ids);
        out.tracks[ti].replace(clip);
        return out;
    }
    out
}

/// The copied grade and the eight grade memories (Swift `ColorClipboard`; the app owns the one instance).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ColorClipboard {
    pub(crate) effects: Option<Vec<ClipEffect>>,
    pub(crate) graph: Option<ColorGraph>,
    pub(crate) memories: BTreeMap<i64, (Vec<ClipEffect>, Option<ColorGraph>)>,
}

impl ColorClipboard {
    /// Number of grade memories.
    // Swift: EditorSession+Color.swift:17
    pub const MEMORY_SLOTS: i64 = 8;

    // Swift: EditorSession+Color.swift:8
    pub fn new() -> ColorClipboard {
        ColorClipboard::default()
    }
    /// The copied color effects.
    pub fn effects(&self) -> Option<&[ClipEffect]> {
        self.effects.as_deref()
    }
    /// The copied Pro graph.
    pub fn graph(&self) -> Option<&ColorGraph> {
        self.graph.as_ref()
    }
    // Swift: EditorSession+Color.swift:12
    pub fn has_color(&self) -> bool {
        self.effects.is_some()
    }
    // Swift: EditorSession+Color.swift:13
    pub fn copy(&mut self, fx: Vec<ClipEffect>, graph: Option<ColorGraph>) {
        self.effects = Some(fx);
        self.graph = graph;
    }
    // Swift: EditorSession+Color.swift:19
    pub fn has_memory(&self, slot: i64) -> bool {
        self.memories.contains_key(&slot)
    }
    /// Stores the copied grade in `slot` (1...8); false when nothing is copied or the slot is out of range.
    // Swift: EditorSession+Color.swift:21
    pub fn save_memory(&mut self, slot: i64) -> bool {
        let (true, Some(e)) = ((1..=Self::MEMORY_SLOTS).contains(&slot), self.effects.clone()) else { return false };
        self.memories.insert(slot, (e, self.graph.clone()));
        true
    }
    /// Makes memory `slot` the copied grade; false when the slot is empty.
    // Swift: EditorSession+Color.swift:27
    pub fn load_memory(&mut self, slot: i64) -> bool {
        let Some((fx, graph)) = self.memories.get(&slot).cloned() else { return false };
        self.copy(fx, graph);
        true
    }
}

impl EditorSession {
    /// Pastes a copied grade onto `ids` (default: the selection); returns the number of clips changed.
    // Swift: EditorSession+Color.swift:44
    pub fn paste_color(
        &mut self,
        effects: Vec<ClipEffect>,
        graph: Option<Option<ColorGraph>>,
        ids: Option<&BTreeSet<Id>>,
        on_top: bool,
    ) -> i64 {
        let targets = ids.cloned().unwrap_or_else(|| self.selection.clone());
        let neutral = |e: &[ClipEffect]| -> Vec<ClipEffect> {
            e.iter()
                .cloned()
                .map(|mut c| {
                    c.id = Id::NIL;
                    c
                })
                .collect()
        };
        self.source_linked_color_edit("Paste Color", &targets, |clip, ids| {
            let before = clip.clone();
            if on_top {
                // Add on top: the target's graph stays as it is.
                clip.add_color_grade_on_top(&effects, ids);
            } else {
                if neutral(&clip.color_grade_effects()) != neutral(&effects) {
                    clip.replace_color_grade(&effects, ids);
                }
                if let Some(g) = &graph {
                    clip.apply_copied_graph(g.clone(), ids);
                }
            }
            *clip != before
        })
    }

    /// Runs a color edit on the clips of `ids` that take color; formats one undo step, returns how many changed.
    fn source_linked_color_edit(
        &mut self,
        name: &str,
        ids: &BTreeSet<Id>,
        mut body: impl FnMut(&mut Clip, &mut dyn IdSource) -> bool,
    ) -> i64 {
        let (Some(tl), Some(t)) = (self.active_timeline_id, self.active_timeline()) else { return 0 };
        let order: Vec<Id> = t
            .tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Video)
            .flat_map(|tr| tr.clips())
            .filter(|c| ids.contains(&c.id) && c.accepts_color())
            .map(|c| c.id)
            .collect();
        // Dry run: nothing to commit when no clip changes.
        let mut dry = SequentialIds::default();
        let any = order.iter().any(|id| match t.find(*id) {
            Some(mut m) => body(&mut m.clip, &mut dry),
            None => false,
        });
        if !any {
            return 0;
        }
        let mut changed = 0;
        let lease = self.lend_ids();
        let src = &mut lease.source();
        let result = self.try_perform(name, None, |p| {
            for id in &order {
                p.prepare_source_grade_edit(*id, &mut *src);
            }
            let mid = p.clone();
            changed = 0;
            p.edit(tl, |t| {
                for id in &order {
                    let Some(mut c) = t.find(*id).map(|m| m.clip) else { continue };
                    if body(&mut c, &mut *src) {
                        t.replace_clip(c)?;
                        changed += 1;
                    }
                }
                Ok(())
            })?;
            // The edited clips are the sources of their links (the clips that joined above changed too).
            p.propagate_grade_links(&mid, &mut *src);
            Ok::<(), EditError>(())
        });
        self.return_ids(lease);
        match result {
            Ok(()) => changed,
            Err(e) => {
                self.set_error(e.to_string());
                0
            }
        }
    }
    // Swift: EditorSession+Color.swift:95
    pub fn paste_color_of(&mut self, other: &ClipColor, ids: Option<&BTreeSet<Id>>) -> i64 {
        let targets = ids.cloned().unwrap_or_else(|| self.selection.clone());
        let fx: Vec<ClipEffect> = if other.effects() == ClipColor::default_effects() {
            Vec::new()
        } else {
            {
                let mut out = Vec::new();
                for e in other.effects() {
                    let id = self.ids.next_id();
                    out.push(ClipEffect::color_grade(id, e, self.ids.as_mut()));
                }
                out
            }
        };
        self.paste_color(fx, None, Some(&targets), false)
    }
    // Swift: EditorSession+Color.swift:104
    pub fn reset_color(&mut self, id: Id) -> bool {
        self.source_linked_color_edit("Reset Color", &BTreeSet::from([id]), |clip, ids| {
            let before = clip.clone();
            clip.replace_color_grade(&[], ids);
            clip.set_color_graph(None, ids);
            clip.footage_color.use_embedded_lut = true;
            *clip != before
        }) > 0
    }
    // Swift: EditorSession+Color.swift:121
    pub fn link_grades(&mut self, source: Id, ids: Option<&BTreeSet<Id>>) -> Option<Id> {
        let targets = ids.cloned().unwrap_or_else(|| self.selection.clone());
        let mut link = None;
        self.perform_with_ids("Link Grades", |p, ids| link = p.link_grades(&targets, source, ids));
        link
    }
    // Swift: EditorSession+Color.swift:130
    pub fn link_all_clips_of_source(&mut self, id: Id) -> Option<Id> {
        let mut link = None;
        self.perform_with_ids("Link Grades", |p, ids| link = p.link_all_clips_of_source(id, ids));
        link
    }
    // Swift: EditorSession+Color.swift:138
    pub fn unlink_grades(&mut self, ids: Option<&BTreeSet<Id>>) -> bool {
        let targets = ids.cloned().unwrap_or_else(|| self.selection.clone());
        let linked = self.project().timelines.iter().any(|t| {
            t.tracks.iter().any(|tr| tr.clips().iter().any(|c| targets.contains(&c.id) && c.grade_link.is_some()))
        });
        if !linked {
            return false;
        }
        self.perform("Unlink Grades", None, |p| {
            p.unlink_grades(&targets);
        });
        true
    }
    // Swift: EditorSession+Color.swift:148
    pub fn grade_link_members(&self, id: Id) -> Vec<Id> {
        self.project().grade_link_members(id)
    }
    pub(crate) fn range_grade_span(&self, clip: &Clip) -> TimeRange {
        if let Some(x) = self.active_timeline().and_then(|t| t.in_out).and_then(|io| io.intersection(&clip.timeline()))
            && x.duration > Time::ZERO
        {
            return TimeRange::new(x.start - clip.start, x.duration);
        }
        let from = if clip.timeline().contains(self.playhead) { self.playhead - clip.start } else { Time::ZERO };
        TimeRange::from_end(from, clip.duration())
    }
    // Swift: EditorSession+Color.swift:161
    pub fn add_range_grade(&mut self, id: Id) -> Option<Id> {
        let mut clip = self.clip_in_active(id)?;
        let span = self.range_grade_span(&clip);
        let fx = clip.add_range_grade(span, self.ids.as_mut())?;
        self.attempt_keyed_ids("Add Range Grade", None, |t, _| t.replace_clip(clip)).then_some(fx)
    }
    // Swift: EditorSession+Color.swift:169
    pub fn set_color_range(&mut self, effect: Id, id: Id, whole_clip: bool) -> bool {
        let Some(mut clip) = self.clip_in_active(id) else { return false };
        let span = if whole_clip { None } else { Some(self.range_grade_span(&clip)) };
        if !clip.set_color_range(effect, span) {
            return false;
        }
        self.attempt_keyed_ids(if whole_clip { "Grade Whole Clip" } else { "Set Grade Range" }, None, |t, _| {
            t.replace_clip(clip)
        })
    }
    /// Color target bar edit of one clip; `body` returns false to refuse (nothing changes).
    // Swift: EditorSession+Color.swift:185
    pub fn edit_clip_color(
        &mut self,
        id: Id,
        name: &str,
        continues_gesture: bool,
        body: impl FnOnce(&mut Clip) -> bool,
    ) -> bool {
        let Some(tl) = self.active_timeline_id else { return false };
        let key = self.gesture_key("clip", id, continues_gesture);
        self.commit_color_edit(
            name,
            &key,
            |c, _| body(c),
            move |p, ids| {
                p.prepare_source_grade_edit(id, ids);
                Ok((tl, id))
            },
        )
    }
    // Swift: EditorSession+Color.swift:198
    pub fn edit_sequence_grade(
        &mut self,
        name: &str,
        continues_gesture: bool,
        body: impl FnOnce(&mut Clip) -> bool,
    ) -> bool {
        self.edit_sequence_grade_with_ids(name, continues_gesture, |c, _| body(c))
    }

    /// `edit_sequence_grade` for a body that adds effects and so needs ids from the session's stream.
    fn edit_sequence_grade_with_ids(
        &mut self,
        name: &str,
        continues_gesture: bool,
        body: impl FnOnce(&mut Clip, &mut dyn IdSource) -> bool,
    ) -> bool {
        let Some(tl) = self.active_timeline_id else { return false };
        let key = self.gesture_key("sequenceGrade", tl, continues_gesture);
        self.commit_color_edit(name, &key, body, move |p, ids| Ok((tl, p.ensure_sequence_grade(tl, ids)?)))
    }

    /// One undo step: `prepare` picks (and may create) the clip, `body` changes it; false from `body` refuses quietly.
    fn commit_color_edit(
        &mut self,
        name: &str,
        key: &str,
        body: impl FnOnce(&mut Clip, &mut dyn IdSource) -> bool,
        prepare: impl FnOnce(&mut Project, &mut dyn IdSource) -> Result<(Id, Id), EditError>,
    ) -> bool {
        enum Failure {
            Refused,
            Edit(EditError),
        }
        impl From<EditError> for Failure {
            fn from(e: EditError) -> Self {
                Failure::Edit(e)
            }
        }
        let before = self.history.current().clone();
        let lease = self.lend_ids();
        let src = &mut lease.source();
        let result = self.try_perform(name, Some(key), |p| {
            let (tl, id) = prepare(p, &mut *src)?;
            let mid = p.clone();
            p.edit(tl, |t| {
                let mut c = t.find(id).map(|m| m.clip).ok_or(EditError::ClipNotFound)?;
                if !body(&mut c, &mut *src) {
                    return Err(EditError::EmptyClip);
                }
                t.replace_clip(c)
            })
            .map_err(|e| if e == EditError::EmptyClip { Failure::Refused } else { Failure::Edit(e) })?;
            // The edited clip is the source of its link (the clips that joined in `prepare` changed too).
            p.propagate_grade_links(&mid, &mut *src);
            Ok::<(), Failure>(())
        });
        self.return_ids(lease);
        match result {
            Ok(()) => *self.history.current() != before,
            Err(Failure::Refused) => false,
            Err(Failure::Edit(e)) => {
                self.set_error(e.to_string());
                false
            }
        }
    }
    // Swift: EditorSession+Color.swift:236
    pub fn set_grade_linked_to_source(&mut self, id: Id, on: bool) -> bool {
        if !self.project().timelines.iter().any(|t| t.find(id).is_some()) {
            return false;
        }
        let mut p = self.project().clone();
        if !p.set_grade_linked_to_source(id, on, &mut SequentialIds::default()) {
            return false;
        }
        self.perform_with_ids(if on { "Link Grade to Source" } else { "Unlink Grade" }, |p, ids| {
            p.set_grade_linked_to_source(id, on, ids);
        });
        true
    }
    // Swift: EditorSession+Color.swift:246
    pub fn paste_sequence_grade(
        &mut self,
        effects: Vec<ClipEffect>,
        graph: Option<Option<ColorGraph>>,
        on_top: bool,
    ) -> bool {
        self.edit_sequence_grade_with_ids("Paste Color", false, |c, ids| {
            let before = c.clone();
            if on_top {
                c.add_color_grade_on_top(&effects, ids);
            } else {
                c.replace_color_grade(&effects, ids);
                if let Some(g) = &graph {
                    c.apply_copied_graph(g.clone(), ids);
                }
            }
            *c != before
        })
    }
    /// Sets (or clears) the source color space of several clips; returns how many changed.
    // Swift: EditorSession+Color.swift:264
    pub fn set_interpretation(&mut self, space: Option<ColorSpaceID>, ids: &[Id]) -> i64 {
        let Some(t) = self.active_timeline() else { return 0 };
        let wanted: BTreeSet<Id> = ids.iter().copied().collect();
        let targets: Vec<Id> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| wanted.contains(&c.id) && c.footage_color.source != space)
            .map(|c| c.id)
            .collect();
        if targets.is_empty() {
            return 0;
        }
        let done = self.attempt_keyed_ids("Interpret As", None, |t, _| {
            for id in &targets {
                let Some(mut c) = t.find(*id).map(|m| m.clip) else { continue };
                c.footage_color.source = space;
                t.replace_clip(c)?;
            }
            Ok(())
        });
        if done { targets.len() as i64 } else { 0 }
    }
    /// The source color space a clip renders with.
    // Swift: EditorSession+ColorSource.swift:6
    pub fn color_source(&self, clip: &Clip) -> ColorSpaceID {
        clip.footage_color.source.unwrap_or_else(|| {
            self.media
                .info(clip.media)
                .map(|i| i.applying_project_input(self.project().input_color_space))
                .map_or(ColorSpaceID::Rec709, |i| i.color_space())
        })
    }
    /// The Color page's Before | After: hands the bypass to the engine (Swift `engine.setColorBypass`).
    pub fn set_color_bypass(&mut self, bypass: Option<sq_core_color::ColorBypass>) {
        self.engine.set_color_bypass(bypass);
    }
    /// The Color page's "Show matte" overlay; changing it pushes the timeline and re-measures the scopes
    /// (Swift `colorMattePreview.didSet`).
    pub fn set_color_matte_preview(&mut self, preview: Option<ColorMattePreview>) {
        if self.color_matte_preview == preview {
            return;
        }
        self.color_matte_preview = preview;
        self.push_timeline(false);
        self.notify(Change::MONITOR_PICTURE);
    }
}
