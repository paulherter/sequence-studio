// Swift: Color/ColorInspectorModel+Graph.swift
//! Color Pro mode of the inspector model: the target's Color Graph, the Step the inspector shows, and the edit the host
//! writes to `Clip.colorGraph`.

use super::color_inspector_model::{ColorInspectorEvent, ColorInspectorModel, LUTChoice};
use super::steps_canvas::{StepsCanvas, StepsPort};
use sq_core_color::{
    ActiveGrade, ColorGraphExt, ColorGraphWiringExt, ColorStepExt, GraphPortExt, LinkRefusal, StepBlend,
    StepPrimariesExt,
};
use sq_core_model::{ColorGraph, ColorStep, ColorTriple, GraphLink, GraphPort, LUTRef, StepKind, StepPosition};
use sq_core_time::Id;
use std::collections::{BTreeMap, BTreeSet};

/// A value of a Step the step inspector edits. The four primaries set all three channels together (master).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StepParam {
    Lift,
    Gamma,
    Gain,
    Offset,
    Contrast,
    Pivot,
    Saturation,
    Mix,
    LutIntensity,
}

impl StepParam {
    /// Swift `allCases`.
    pub const ALL: [StepParam; 9] = [
        StepParam::Lift,
        StepParam::Gamma,
        StepParam::Gain,
        StepParam::Offset,
        StepParam::Contrast,
        StepParam::Pivot,
        StepParam::Saturation,
        StepParam::Mix,
        StepParam::LutIntensity,
    ];

    pub fn title(self) -> &'static str {
        match self {
            StepParam::Lift => "Lift",
            StepParam::Gamma => "Gamma",
            StepParam::Gain => "Gain",
            StepParam::Offset => "Offset",
            StepParam::Contrast => "Contrast",
            StepParam::Pivot => "Pivot",
            StepParam::Saturation => "Saturation",
            StepParam::Mix => "Mix",
            StepParam::LutIntensity => "Intensity",
        }
    }

    /// Lower and upper bound.
    pub fn range(self) -> (f32, f32) {
        match self {
            StepParam::Lift => ColorStepPrimaries::LIFT_RANGE,
            StepParam::Offset => ColorStepPrimaries::OFFSET_RANGE,
            StepParam::Gamma => ColorStepPrimaries::GAMMA_RANGE,
            StepParam::Gain => ColorStepPrimaries::GAIN_RANGE,
            StepParam::Saturation => ColorStepPrimaries::SATURATION_RANGE,
            StepParam::Contrast => ColorStepPrimaries::CONTRAST_RANGE,
            StepParam::Pivot => ColorStepPrimaries::PIVOT_RANGE,
            StepParam::Mix | StepParam::LutIntensity => (0.0, 100.0),
        }
    }

    pub fn neutral(self) -> f32 {
        match self {
            StepParam::Lift | StepParam::Offset => 0.0,
            StepParam::Gamma | StepParam::Gain | StepParam::Contrast | StepParam::Saturation => 1.0,
            StepParam::Pivot => 0.435,
            StepParam::Mix | StepParam::LutIntensity => 100.0,
        }
    }

    pub fn decimals(self) -> i64 {
        match self {
            StepParam::Mix => 0,
            StepParam::LutIntensity => 1,
            _ => 3,
        }
    }

    /// The master value: the channel mean of a triple.
    pub fn read(self, s: &ColorStep) -> f32 {
        fn mean(t: &ColorTriple) -> f32 {
            (t.r + t.g + t.b) / 3.0
        }
        match self {
            StepParam::Lift => mean(&s.primaries.lift),
            StepParam::Gamma => mean(&s.primaries.gamma),
            StepParam::Gain => mean(&s.primaries.gain),
            StepParam::Offset => mean(&s.primaries.offset),
            StepParam::Contrast => s.primaries.contrast,
            StepParam::Pivot => s.primaries.pivot,
            StepParam::Saturation => s.primaries.saturation,
            StepParam::Mix => s.mix,
            StepParam::LutIntensity => s.lut_intensity,
        }
    }

    /// Clamps to `range` and writes (a triple gets the value on every channel).
    pub fn write(self, value: f32, s: &mut ColorStep) {
        let (lo, hi) = self.range();
        let v = value.max(lo).min(hi);
        match self {
            StepParam::Lift => s.primaries.lift = ColorTriple::all(v),
            StepParam::Gamma => s.primaries.gamma = ColorTriple::all(v),
            StepParam::Gain => s.primaries.gain = ColorTriple::all(v),
            StepParam::Offset => s.primaries.offset = ColorTriple::all(v),
            StepParam::Contrast => s.primaries.contrast = v,
            StepParam::Pivot => s.primaries.pivot = v,
            StepParam::Saturation => s.primaries.saturation = v,
            StepParam::Mix => s.mix = v,
            StepParam::LutIntensity => s.lut_intensity = v,
        }
    }
}

type ColorStepPrimaries = sq_core_model::StepPrimaries;

/// The two LUT chips at the ends of the Color Graph.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphLUTSlot {
    Input,
    Output,
}

impl ColorInspectorModel {
    /// Simple | Pro of the shown clip.
    pub fn active_grade(&self) -> ActiveGrade {
        if self.graph.as_ref().is_some_and(|g| g.is_active) { ActiveGrade::Pro } else { ActiveGrade::Simple }
    }

    /// Shows the target's graph (no callbacks). The selection stays while its Step exists, else the first Step.
    pub fn load_graph(&mut self, g: Option<&ColorGraph>) {
        if self.graph.as_ref() != g {
            // Undo took the graph away while the Pro tab was up: the tab stays (the empty Pro page), not a jump to Simple.
            // The model belongs to one clip, so a graph that vanishes here is an edit of this clip, never another clip.
            if g.is_none() && self.shown_grade() == ActiveGrade::Pro {
                self.set_shows_empty_pro(true);
            }
            self.graph = g.cloned();
            self.touch();
        }
        let Some(g) = g else {
            if self.selected_step().is_some() {
                self.set_selected_step(None);
            }
            return;
        };
        if self.selected_step().and_then(|s| g.step(s)).is_none() {
            self.set_selected_step(g.steps().first().map(|s| s.id));
        }
    }

    /// One graph edit as one undo step (slider drags run inside the row's own gesture).
    pub(crate) fn edit_graph(&mut self, body: impl FnOnce(&mut ColorGraph)) {
        let Some(mut g) = self.graph.clone() else { return };
        body(&mut g);
        self.commit_graph(g);
    }

    /// One edit of one Step (an undo step; inside a slider or curve drag the host's gesture groups the changes).
    pub(crate) fn edit_step(&mut self, id: Id, body: impl FnOnce(&mut ColorStep)) {
        self.edit_graph(|g| g.update(id, body));
    }

    pub(crate) fn commit_graph(&mut self, g: ColorGraph) {
        if self.graph.as_ref() == Some(&g) {
            return;
        }
        self.gesture(|s| {
            s.graph = Some(g.clone());
            s.touch();
            if s.selected_step().and_then(|x| g.step(x)).is_none() {
                s.set_selected_step(g.steps().first().map(|x| x.id));
            }
            s.emit(ColorInspectorEvent::GraphChange(g));
        });
    }

    /// The page the panel shows: Pro while the Color Graph is the grade, and while the empty Pro page is open on a clip
    /// that has no graph yet (the Simple grade stays the clip's grade then).
    pub fn shown_grade(&self) -> ActiveGrade {
        if self.active_grade() == ActiveGrade::Pro || (self.shows_empty_pro() && self.graph.is_none()) {
            ActiveGrade::Pro
        } else {
            ActiveGrade::Simple
        }
    }

    /// Makes Simple or Pro the clip's grade; the other keeps its values. Pro on a clip without a graph only opens the
    /// empty Pro page: the graph is added by `start_empty_graph` or `start_from_simple`.
    pub fn set_active_grade(&mut self, m: ActiveGrade) {
        let Some(mut g) = self.graph.clone() else {
            self.set_shows_empty_pro(m == ActiveGrade::Pro);
            return;
        };
        self.set_shows_empty_pro(false);
        g.is_active = m == ActiveGrade::Pro;
        self.commit_graph(g);
    }

    fn new_graph(&mut self) -> ColorGraph {
        ColorGraph::new(Vec::new(), None, None, self.ids.next_id())
    }

    /// "Start empty": an active Color Graph with one neutral Step (one undo step). A clip that has a graph keeps it.
    pub fn start_empty_graph(&mut self) {
        let mut g = match self.graph.clone() {
            Some(g) => g,
            None => self.new_graph(),
        };
        g.is_active = true;
        self.set_shows_empty_pro(false);
        self.commit_graph(g);
    }

    /// "Start from Simple grade": an active Color Graph whose Steps reproduce the Simple grade (one undo step). The
    /// Color effects keep their values. A clip that has a graph keeps it.
    pub fn start_from_simple(&mut self) {
        if self.graph.is_some() {
            self.start_empty_graph();
            return;
        }
        let mut g = ColorGraph::from_simple(&self.color, &mut *self.ids);
        let ids: Vec<Id> = g.steps().iter().map(|s| s.id).collect();
        for (n, id) in ids.iter().enumerate() {
            let label = if ids.len() == 1 { "From Simple".to_string() } else { format!("From Simple {}", n + 1) };
            g.update(*id, |s| s.label = label);
        }
        self.set_shows_empty_pro(false);
        self.commit_graph(g);
    }

    /// Send to Pro is offered while the Simple grade is on and the clip has no Pro values worth keeping.
    pub fn can_send_to_pro(&self) -> bool {
        self.active_grade() == ActiveGrade::Simple && self.graph.as_ref().is_none_or(|g| g.is_neutral())
    }

    /// Makes the Simple grade's values Step 1 of an active Color Graph (one undo step). The Color effects keep all their
    /// values, dimmed by the exclusive rule (`Clip.renderColor` skips them while Pro is active).
    pub fn send_to_pro(&mut self) {
        if !self.can_send_to_pro() {
            return;
        }
        let mut g = ColorGraph::from_simple(&self.color, &mut *self.ids);
        if let Some(old) = &self.graph {
            g.output_lut = old.output_lut.clone();
            g.output_lut_intensity = old.output_lut_intensity;
        }
        self.commit_graph(g);
    }

    pub fn step(&self, id: Id) -> Option<&ColorStep> {
        self.graph.as_ref().and_then(|g| g.step(id))
    }

    /// Places `new` where the layout would put it, clear of every other box (Swift's `freeSpot` block of `addStep`).
    fn place_new_step(g: &mut ColorGraph, new: Id) {
        let cols: Vec<Vec<Id>> = g.columns().iter().map(|c| c.iter().map(|s| s.id).collect()).collect();
        let pos: BTreeMap<Id, StepPosition> = g.steps().iter().filter_map(|s| s.position.map(|p| (s.id, p))).collect();
        let mix: BTreeMap<Id, StepPosition> =
            g.steps().iter().filter_map(|s| s.mixer_position.map(|p| (s.id, p))).collect();
        if let Some(p) = StepsCanvas::free_spot(new, &cols, &pos, &mix) {
            g.set_position(new, Some(p));
        }
    }

    /// Adds a neutral Step of `kind` behind `id` (nil: at the end) and selects it (one undo step). A Parallel or Layer
    /// Step needs a Step before it: at the front it becomes a serial Step.
    pub fn add_step(&mut self, after: Option<Id>, kind: StepKind) {
        let Some(mut g) = self.graph.clone() else { return };
        let new = g.add_step(after, kind, &mut *self.ids);
        // The new Step gets its own place on the canvas: where the layout would put it, clear of every other box.
        Self::place_new_step(&mut g, new);
        self.set_selected_step(Some(new));
        self.selected_mixer = None;
        self.commit_graph(g);
    }

    /// Adds a Step of `kind` at the end of the graph.
    pub fn add_step_at_end(&mut self, kind: StepKind) {
        let last = self.graph.as_ref().and_then(|g| g.steps().last().map(|s| s.id));
        self.add_step(last, kind);
    }

    /// Layer list: how the Step joins the rows below (Series, Parallel or a Layer mix). The base row and custom wiring refuse.
    pub fn set_step_blend(&mut self, id: Id, blend: StepBlend) {
        let Some(g) = &self.graph else { return };
        if !g.allows_list_edit() {
            return;
        }
        self.edit_graph(|g| {
            g.set_blend(id, blend);
        });
    }

    /// Layer list: moves the Step to list row `row` (0 = top) and keeps it selected.
    pub fn move_step_to_list_row(&mut self, id: Id, row: i64) {
        let Some(g) = &self.graph else { return };
        if !g.allows_list_edit() {
            return;
        }
        self.edit_graph(|g| g.move_step_to_list_row(id, row));
        self.set_selected_step(Some(id));
    }

    /// Layer list "+": a new Step in series right after the selected Step (at the end when none is selected). A Parallel
    /// or Layer Step is a choice from the "+" menu of the Steps panel, never the default.
    pub fn add_layer_on_top(&mut self) {
        let after = self.selected_step().or_else(|| self.graph.as_ref().and_then(|g| g.steps().last().map(|s| s.id)));
        self.add_step(after, StepKind::Serial);
    }

    /// Changes how the Step joins the one before it (serial, parallel, layer).
    pub fn set_step_kind(&mut self, id: Id, kind: StepKind) {
        self.edit_graph(|g| g.set_kind(id, kind));
    }

    /// Renames a Step (blank names are ignored).
    pub fn rename_step(&mut self, id: Id, name: &str) {
        self.edit_graph(|g| g.rename(id, name));
    }

    /// Copies a Step right behind itself (kind, values, name + " copy") and selects the copy (one undo step).
    pub fn duplicate_step(&mut self, id: Id) {
        let Some(mut g) = self.graph.clone() else { return };
        let Some(s) = g.step(id).cloned() else { return };
        let new = g.add_step(Some(id), s.kind, &mut *self.ids);
        g.update(new, |c| {
            let keep = c.id;
            *c = s.clone();
            c.id = keep;
            c.label = format!("{} copy", s.label);
        });
        self.set_selected_step(Some(new));
        self.commit_graph(g);
    }

    /// Asks the Steps graph to edit the Step's name in place (the Step menu's Rename).
    pub fn begin_rename(&mut self, id: Id) {
        if self.step(id).is_none() {
            return;
        }
        self.set_selected_step(Some(id));
        self.renaming_step = Some(id);
        self.touch();
    }

    pub fn remove_step(&mut self, id: Id) {
        self.edit_graph(|g| g.remove_step(id));
    }

    /// Moves a Step `delta` places (clamped to the graph).
    pub fn move_step_by(&mut self, id: Id, delta: i64) {
        self.edit_graph(|g| {
            let Some(i) = g.steps().iter().position(|s| s.id == id) else { return };
            g.move_step(id, i as i64 + delta);
        });
    }

    /// Drops the Step on a wire of the Steps canvas: its own column between the columns around `gap`.
    pub fn move_step_to_gap(&mut self, id: Id, gap: i64) {
        self.edit_graph(|g| g.move_to_gap(id, gap));
        self.set_selected_step(Some(id));
    }

    // MARK: Mixer boxes and wires

    /// Deletes a mixer box: the Steps in its stack become serial Steps (one undo step).
    pub fn remove_mixer(&mut self, head: Id) {
        self.edit_graph(|g| {
            g.dissolve_mixer(head);
        });
        if self.selected_mixer == Some(head) {
            self.selected_mixer = None;
        }
    }

    /// Stores where a mixer box sits (one undo step); nil = automatic.
    pub fn set_mixer_position(&mut self, head: Id, p: Option<StepPosition>) {
        self.edit_graph(|g| g.set_mixer_position(head, p));
    }

    /// Wires the output of `from` into the input of `to` (one undo step). Nil when done, else why it was refused (nothing
    /// changed). A Step's input holds one wire (the new one replaces it), a mixer box takes several, an output feeds any number.
    pub fn connect(&mut self, from: StepsPort, to: StepsPort) -> Option<LinkRefusal> {
        let Some(mut g) = self.graph.clone() else { return Some(LinkRefusal::UnknownBox) };
        if let Some(r) = g.connect(from, to) {
            return Some(r);
        }
        if let GraphPort::Step(b) = to {
            self.set_selected_step(Some(b));
        } else if let GraphPort::Step(x) = from {
            self.set_selected_step(Some(x));
        }
        self.selected_mixer = None;
        self.commit_graph(g);
        None
    }

    /// Takes one image wire away (one undo step).
    pub fn disconnect(&mut self, link: GraphLink) {
        self.edit_graph(|g| g.disconnect(link));
    }

    /// Moves the end of a wire: `link` is taken off and `from` is wired to `to` in one undo step. Nothing changes when the
    /// new wire is refused (the refusal is returned).
    pub fn rewire(&mut self, link: GraphLink, from: StepsPort, to: StepsPort) -> Option<LinkRefusal> {
        let Some(mut g) = self.graph.clone() else { return Some(LinkRefusal::UnknownBox) };
        g.disconnect(link);
        if let Some(r) = g.connect(from, to) {
            return Some(r);
        }
        self.commit_graph(g);
        None
    }

    /// Wires the key output of Step `from` into the key input of a Step or mixer box (one undo step).
    pub fn connect_key(&mut self, from: Id, to: StepsPort) -> Option<LinkRefusal> {
        let Some(mut g) = self.graph.clone() else { return Some(LinkRefusal::UnknownBox) };
        if let Some(r) = g.connect_key(from, to) {
            return Some(r);
        }
        self.commit_graph(g);
        None
    }

    /// Moves the end of a key wire (one undo step); nothing changes when the new wire is refused.
    pub fn rewire_key(&mut self, link: GraphLink, from: StepsPort, to: StepsPort) -> Option<LinkRefusal> {
        let (Some(mut g), Some(id)) = (self.graph.clone(), from.step_id()) else {
            return Some(LinkRefusal::UnknownBox);
        };
        g.disconnect_key(link);
        if let Some(r) = g.connect_key(id, to) {
            return Some(r);
        }
        self.commit_graph(g);
        None
    }

    pub fn disconnect_key(&mut self, link: GraphLink) {
        self.edit_graph(|g| g.disconnect_key(link));
    }

    /// Drops the Step on a wire: it goes between the wire's ends and the gap it left closes (one undo step).
    pub fn insert_step(&mut self, id: Id, onto: GraphLink) -> bool {
        let Some(mut g) = self.graph.clone() else { return false };
        if !g.insert(id, onto) {
            return false;
        }
        g.set_position(id, None);
        self.set_selected_step(Some(id));
        self.selected_steps = BTreeSet::from([id]);
        self.commit_graph(g);
        true
    }

    /// Shift-drag: the Step leaves its wires (they close up around it) and stays at `p` (one undo step).
    pub fn extract_step(&mut self, id: Id, p: StepPosition) {
        self.edit_graph(|g| {
            g.extract(id);
            g.set_position(id, Some(p));
        });
    }

    /// Freezes a stack's mixer box where it sits, so moving a Step of the stack does not move the box (one undo step with
    /// the positions).
    pub fn place_steps(&mut self, positions: &BTreeMap<Id, StepPosition>, frozen: &BTreeMap<Id, StepPosition>) {
        self.edit_graph(|g| {
            for (head, p) in frozen {
                if g.step(*head).is_some_and(|s| s.mixer_position.is_none()) {
                    g.set_mixer_position(*head, Some(*p));
                }
            }
            for (id, p) in positions {
                g.set_position(*id, Some(*p));
            }
        });
    }

    // MARK: Selection

    /// Selects one Step (the inspector shows it) or, with `extend`, adds it to / takes it from the selection.
    pub fn select_step(&mut self, id: Id, extend: bool) {
        self.selected_mixer = None;
        if extend {
            if self.selected_steps.contains(&id) {
                self.selected_steps.remove(&id);
                if self.selected_step() == Some(id) {
                    let first = self.selected_steps.iter().next().copied();
                    self.set_selected_step(first);
                }
            } else {
                self.selected_steps.insert(id);
                self.set_selected_step(Some(id));
            }
        } else {
            self.selected_steps = BTreeSet::from([id]);
            self.set_selected_step(Some(id));
        }
        self.touch();
    }

    /// Replaces the selection (the rectangle); the inspector shows the first of them.
    pub fn select_steps(&mut self, ids: &BTreeSet<Id>, extend: bool) {
        self.selected_mixer = None;
        let all: BTreeSet<Id> = if extend { self.selected_steps.union(ids).copied().collect() } else { ids.clone() };
        self.selected_steps = all.clone();
        self.touch();
        if self.selected_step().is_some_and(|s| all.contains(&s)) {
            return;
        }
        let first = self.graph.as_ref().and_then(|g| g.steps().iter().find(|s| all.contains(&s.id)).map(|s| s.id));
        if let Some(first) = first {
            self.set_selected_step(Some(first));
        }
    }

    /// The Steps a command works on: the selection, else the shown Step.
    pub fn command_steps(&self) -> Vec<Id> {
        let Some(g) = &self.graph else { return Vec::new() };
        let ids: Vec<Id> = g.steps().iter().map(|s| s.id).filter(|id| self.selected_steps.contains(id)).collect();
        if !ids.is_empty() {
            return ids;
        }
        self.selected_step().map_or(Vec::new(), |s| vec![s])
    }

    /// Deletes the selected Steps; the wires close up around them (one undo step). The last Step only resets.
    pub fn remove_selected_steps(&mut self) {
        let ids = self.command_steps();
        if ids.is_empty() {
            return;
        }
        self.edit_graph(|g| {
            for id in &ids {
                g.remove_step(*id);
            }
        });
        self.selected_steps = self.selected_step().map_or_else(BTreeSet::new, |s| BTreeSet::from([s]));
        self.touch();
    }

    /// Turns the selected Steps off, or on when all of them are off (one undo step).
    pub fn toggle_selected_steps(&mut self) {
        let ids = self.command_steps();
        let Some(g) = &self.graph else { return };
        if ids.is_empty() {
            return;
        }
        let target = !ids.iter().all(|id| g.step(*id).is_some_and(|s| s.enabled));
        self.edit_graph(|g| {
            for id in &ids {
                g.set_step_enabled(*id, target);
            }
        });
    }

    /// Adds a Step in front of `id` (serial; before the first Step it becomes the new first Step).
    pub fn add_step_before(&mut self, id: Id) {
        let Some(mut g) = self.graph.clone() else { return };
        let Some(i) = g.steps().iter().position(|s| s.id == id) else { return };
        let new = if i == 0 {
            g.add_step(None, StepKind::Serial, &mut *self.ids)
        } else {
            let prev = g.steps()[i - 1].id;
            g.add_step(Some(prev), StepKind::Serial, &mut *self.ids)
        };
        if i == 0 {
            g.move_step(new, 0);
        }
        Self::place_new_step(&mut g, new);
        self.set_selected_step(Some(new));
        self.commit_graph(g);
    }

    /// Tidy up: every Step goes back to the automatic layout.
    pub fn tidy_up_steps(&mut self) {
        self.edit_graph(|g| g.tidy_up());
    }

    pub fn set_step_enabled(&mut self, id: Id, on: bool) {
        self.edit_graph(|g| g.set_step_enabled(id, on));
    }

    pub fn reset_step(&mut self, id: Id) {
        self.edit_graph(|g| g.update(id, |s| s.reset()));
    }

    pub fn step_value(&self, id: Id, p: StepParam) -> f32 {
        self.step(id).map_or(p.neutral(), |s| p.read(s))
    }

    pub fn set_step(&mut self, id: Id, p: StepParam, v: f32) {
        self.edit_graph(|g| g.update(id, |s| p.write(v, s)));
    }

    pub fn reset_step_value(&mut self, id: Id, p: StepParam) {
        self.set_step(id, p, p.neutral());
    }

    // MARK: LUTs

    pub fn graph_lut_choice(&self, slot: GraphLUTSlot) -> Option<LUTChoice> {
        let g = self.graph.as_ref()?;
        let r = if slot == GraphLUTSlot::Input { g.input_lut.as_ref() } else { g.output_lut.as_ref() };
        r.map(|r| self.choice(r))
    }

    /// In LUT: nil = none (built-in conversion), `.automatic` = the Simple rules. Out LUT: nil = none.
    pub fn set_graph_lut(&mut self, slot: GraphLUTSlot, c: Option<&LUTChoice>) {
        let r = c.and_then(|c| self.lut_ref(c));
        self.note_recent(c);
        self.edit_graph(|g| match slot {
            GraphLUTSlot::Input => g.input_lut = r,
            GraphLUTSlot::Output => g.output_lut = if r == Some(LUTRef::Automatic) { None } else { r },
        });
    }

    pub fn step_lut_choice(&self, id: Id) -> Option<LUTChoice> {
        self.step(id).and_then(|s| s.lut.as_ref()).map(|r| self.choice(r))
    }

    pub fn set_step_lut(&mut self, id: Id, c: Option<&LUTChoice>) {
        let r = c.and_then(|c| self.lut_ref(c));
        self.note_recent(c);
        self.edit_graph(|g| g.update(id, |s| s.lut = if r == Some(LUTRef::Automatic) { None } else { r }));
    }

    fn note_recent(&mut self, c: Option<&LUTChoice>) {
        let Some(path) = c.and_then(|c| c.file_path()).map(str::to_string) else { return };
        self.recents.add(&path);
        self.recent_luts = self.recents.paths.clone();
        self.emit(ColorInspectorEvent::RecentLut(path));
    }

    // MARK: Color decisions (ASC CDL, CMX EDL)

    /// Sets the Step's primaries from the first decision of an imported file (clamped to the Step ranges by the caller's
    /// parser). One undo step. The file parser (`ColorDecisionImport`) is not ported yet, see PORTING-NOTES.
    pub fn apply_color_decision(&mut self, id: Id, primaries: ColorStepPrimaries) {
        self.edit_graph(|g| g.update(id, |s| s.primaries = primaries));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn model() -> ColorInspectorModel {
        ColorInspectorModel::new(Box::new(SequentialIds::default()))
    }

    fn pro() -> ColorInspectorModel {
        let mut m = model();
        m.start_empty_graph();
        m.take_events();
        m
    }

    #[test]
    fn start_empty_makes_an_active_graph_with_one_step_and_one_undo_step() {
        let mut m = model();
        m.set_active_grade(ActiveGrade::Pro);
        assert!(m.shows_empty_pro());
        assert_eq!(m.shown_grade(), ActiveGrade::Pro);
        assert_eq!(m.active_grade(), ActiveGrade::Simple);
        m.take_events();
        m.start_empty_graph();
        let ev = m.take_events();
        assert_eq!(ev.iter().filter(|e| matches!(e, ColorInspectorEvent::GestureBegan)).count(), 1);
        assert!(
            ev.iter().any(|e| matches!(e, ColorInspectorEvent::GraphChange(g) if g.is_active && g.steps().len() == 1))
        );
        assert_eq!(m.active_grade(), ActiveGrade::Pro);
        assert!(!m.shows_empty_pro());
        assert!(m.selected_step().is_some());
    }

    #[test]
    fn undo_of_start_empty_keeps_the_pro_tab() {
        let mut m = model();
        m.set_active_grade(ActiveGrade::Pro);
        m.start_empty_graph();
        assert_eq!(m.shown_grade(), ActiveGrade::Pro);
        // Undo: the session puts the clip without a graph back.
        m.load_graph(None);
        assert_eq!(m.shown_grade(), ActiveGrade::Pro, "Ctrl+Z must not jump to the Simple tab");
        assert!(m.shows_empty_pro());
        // A Simple clip stays Simple.
        let mut s = model();
        s.load_graph(None);
        assert_eq!(s.shown_grade(), ActiveGrade::Simple);
    }

    #[test]
    fn steps_can_be_added_selected_and_removed() {
        let mut m = pro();
        let first = m.selected_step();
        m.add_step_at_end(StepKind::Serial);
        assert_eq!(m.graph().map(|g| g.steps().len()), Some(2));
        assert_ne!(m.selected_step(), first);
        let second = m.selected_step();
        assert!(second.is_some_and(|s| m.step(s).is_some_and(|st| st.position.is_some())));
        m.remove_selected_steps();
        assert_eq!(m.graph().map(|g| g.steps().len()), Some(1));
        assert_eq!(m.selected_step(), first);
    }

    #[test]
    fn the_list_plus_adds_a_serial_step_after_the_selected_one() {
        let mut m = pro();
        let first = m.selected_step().expect("selected");
        m.add_layer_on_top();
        let second = m.selected_step().expect("selected");
        m.set_selected_step(Some(first));
        m.add_layer_on_top();
        let steps: Vec<_> = m.graph().expect("graph").steps().iter().map(|s| (s.id, s.kind)).collect();
        assert_eq!(steps.len(), 3);
        assert_eq!(steps[0].0, first);
        assert_ne!(steps[1].0, second, "the new step sits right after the selected first step");
        assert_eq!(steps[2].0, second);
        assert!(steps.iter().all(|s| s.1 == StepKind::Serial), "all in series: {steps:?}");
    }

    #[test]
    fn duplicate_copies_values_and_names_the_copy() {
        let mut m = pro();
        let id = m.selected_step();
        let Some(id) = id else { return };
        m.set_step(id, StepParam::Contrast, 1.5);
        m.duplicate_step(id);
        let copy = m.selected_step();
        let Some(copy) = copy else { return };
        assert_ne!(copy, id);
        assert_eq!(m.step_value(copy, StepParam::Contrast), 1.5);
        assert!(m.step(copy).is_some_and(|s| s.label.ends_with(" copy")));
    }

    #[test]
    fn step_params_clamp_and_the_primaries_write_every_channel() {
        let mut m = pro();
        let Some(id) = m.selected_step() else { return };
        m.set_step(id, StepParam::Gain, 9.0);
        assert_eq!(m.step_value(id, StepParam::Gain), 4.0);
        m.set_step(id, StepParam::Lift, 0.25);
        assert_eq!(m.step(id).map(|s| s.primaries.lift), Some(ColorTriple::all(0.25)));
        m.reset_step_value(id, StepParam::Lift);
        assert_eq!(m.step_value(id, StepParam::Lift), 0.0);
    }

    #[test]
    fn selection_extends_and_shrinks() {
        let mut m = pro();
        let Some(a) = m.selected_step() else { return };
        m.add_step_at_end(StepKind::Serial);
        let Some(b) = m.selected_step() else { return };
        m.select_step(a, true);
        assert_eq!(m.selected_steps, BTreeSet::from([a, b]));
        assert_eq!(m.command_steps().len(), 2);
        m.select_step(a, true);
        assert_eq!(m.selected_steps, BTreeSet::from([b]));
        m.select_step(a, false);
        assert_eq!(m.selected_steps, BTreeSet::from([a]));
        assert_eq!(m.selected_step(), Some(a));
    }

    #[test]
    fn toggle_turns_all_off_then_on() {
        let mut m = pro();
        let Some(a) = m.selected_step() else { return };
        m.toggle_selected_steps();
        assert!(m.step(a).is_some_and(|s| !s.enabled));
        m.toggle_selected_steps();
        assert!(m.step(a).is_some_and(|s| s.enabled));
    }

    #[test]
    fn send_to_pro_needs_the_simple_grade_and_no_pro_values() {
        let mut m = model();
        assert!(m.can_send_to_pro());
        m.send_to_pro();
        assert!(m.graph().is_some());
        // The new graph is the clip's grade now.
        assert_eq!(m.active_grade(), ActiveGrade::Pro);
        assert!(!m.can_send_to_pro());
    }

    #[test]
    fn connect_without_a_graph_is_refused() {
        let mut m = model();
        assert_eq!(m.connect(GraphPort::Source, GraphPort::Sink), Some(LinkRefusal::UnknownBox));
    }

    #[test]
    fn load_graph_keeps_a_selection_that_still_exists() {
        let mut m = pro();
        let Some(g) = m.graph().cloned() else { return };
        let keep = m.selected_step();
        m.load_graph(Some(&g));
        assert_eq!(m.selected_step(), keep);
        m.load_graph(None);
        assert_eq!(m.selected_step(), None);
        assert!(m.take_events().iter().any(|e| matches!(e, ColorInspectorEvent::ViewerAidChange)));
    }

    #[test]
    fn graph_luts_note_recents() {
        let mut m = pro();
        m.set_graph_lut(GraphLUTSlot::Output, Some(&LUTChoice::file("/l/a.cube")));
        assert_eq!(m.graph_lut_choice(GraphLUTSlot::Output), Some(LUTChoice::file("/l/a.cube")));
        assert_eq!(m.recent_luts, vec!["/l/a.cube".to_string()]);
        m.set_graph_lut(GraphLUTSlot::Output, None);
        assert_eq!(m.graph_lut_choice(GraphLUTSlot::Output), None);
    }
}
