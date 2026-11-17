// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGraph+Wiring.swift
//! Explicit wiring of the Steps graph (v80). The Step kinds (serial, parallel, layer) describe the topology the
//! renderer understands: columns. The Steps canvas edits wires, which can say more (a Step with no input, one output
//! feeding two Steps, a Step in a branch). `ColorGraph::links` holds such custom wiring; it is `None` while the wiring
//! is exactly what the kinds say. Every wire edit is compiled back into kinds when it can be; when it cannot, the
//! wires are kept as drawn and `is_wiring_applied` is false (the renderer still follows the Step order).

use crate::color_graph::{ColorGraphExt, edit};
use sq_core_model::{ColorGraph, ColorStep, GraphLink, GraphPort, StepKind, StepPosition};
use sq_core_time::Id;
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Why a wire was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkRefusal {
    /// The start is the sink (it has no output).
    NotAnOutput,
    /// The end is the source (it has no input).
    NotAnInput,
    /// Start and end are the same box.
    SameBox,
    /// A box does not exist.
    UnknownBox,
    /// The wire would close a loop.
    Cycle,
    /// The wire exists already.
    Duplicate,
    /// A key wire must end at a Step or a mixer.
    NotAKeyEnd,
}

/// Queries on [`GraphPort`].
pub trait GraphPortExt {
    /// The Step this port names (`None` for source, sink and mixers).
    fn step_id(&self) -> Option<Id>;
    /// The port is a mixer box.
    fn is_mixer(&self) -> bool;
}

impl GraphPortExt for GraphPort {
    fn step_id(&self) -> Option<Id> {
        if let GraphPort::Step(i) = self { Some(*i) } else { None }
    }

    fn is_mixer(&self) -> bool {
        matches!(self, GraphPort::Mixer(_))
    }
}

/// Wire queries and edits of a [`ColorGraph`].
pub trait ColorGraphWiringExt {
    /// Heads (first Step) of the stacks with more than one Step: each owns a mixer box.
    fn mixer_heads(&self) -> Vec<Id>;
    /// The wires the Step kinds say: source -> column -> ... -> sink; a stack fans out and joins in its mixer.
    fn derived_links(columns: &[Vec<Id>]) -> Vec<GraphLink>;
    /// The image wires: the custom ones, else the derived ones.
    fn image_links(&self) -> Vec<GraphLink>;
    /// The wiring was edited by hand.
    fn has_custom_wiring(&self) -> bool;
    /// The picture follows the wiring exactly (no custom wiring that could not be compiled to kinds).
    fn is_wiring_applied(&self) -> bool;
    /// The enabled Steps whose key output feeds `port`.
    fn key_donors(&self, port: GraphPort) -> Vec<ColorStep>;
    /// A key wire starts or ends at this Step.
    fn uses_key_link(&self, id: Id) -> bool;
    /// Why `from -> to` cannot be wired as an image wire (`None` = it can).
    fn refusal(&self, from: GraphPort, to: GraphPort) -> Option<LinkRefusal>;
    /// Why the key of `from` cannot be wired to `to` (`None` = it can).
    fn key_refusal(&self, from: Id, to: GraphPort) -> Option<LinkRefusal>;
    /// Wires `from -> to`; an input that is not a mixer takes one wire, so an older one is replaced.
    fn connect(&mut self, from: GraphPort, to: GraphPort) -> Option<LinkRefusal>;
    /// Removes an image wire.
    fn disconnect(&mut self, link: GraphLink);
    /// Wires the key of Step `from` to `to`.
    fn connect_key(&mut self, from: Id, to: GraphPort) -> Option<LinkRefusal>;
    /// Removes a key wire.
    fn disconnect_key(&mut self, link: GraphLink);
    /// Puts Step `id` onto an existing wire (lifting it out of its place first).
    fn insert(&mut self, id: Id, onto: GraphLink) -> bool;
    /// Lifts a Step out of its place; its input goes to what it fed. The Step stays unwired.
    fn extract(&mut self, id: Id) -> bool;
}

fn exists(g: &ColorGraph, p: GraphPort) -> bool {
    match p {
        GraphPort::Source | GraphPort::Sink => true,
        GraphPort::Step(i) => g.step(i).is_some(),
        GraphPort::Mixer(h) => g.mixer_heads().contains(&h),
    }
}

fn reaches(g: &ColorGraph, a: GraphPort, b: GraphPort) -> bool {
    let mut all = g.image_links();
    all.extend(g.key_links.iter().copied());
    let mut seen: HashSet<GraphPort> = HashSet::new();
    seen.insert(a);
    let mut todo = vec![a];
    while let Some(p) = todo.pop() {
        if p == b {
            return true;
        }
        for l in all.iter().filter(|l| l.from == p) {
            if seen.insert(l.to) {
                todo.push(l.to);
            }
        }
    }
    false
}

impl ColorGraphWiringExt for ColorGraph {
    fn mixer_heads(&self) -> Vec<Id> {
        self.columns().iter().filter(|c| c.len() > 1).map(|c| c[0].id).collect()
    }

    fn derived_links(columns: &[Vec<Id>]) -> Vec<GraphLink> {
        let mut out = Vec::new();
        let mut src = GraphPort::Source;
        for col in columns.iter().filter(|c| !c.is_empty()) {
            if col.len() > 1 {
                for id in col {
                    out.push(GraphLink { from: src, to: GraphPort::Step(*id) });
                    out.push(GraphLink { from: GraphPort::Step(*id), to: GraphPort::Mixer(col[0]) });
                }
                src = GraphPort::Mixer(col[0]);
            } else {
                out.push(GraphLink { from: src, to: GraphPort::Step(col[0]) });
                src = GraphPort::Step(col[0]);
            }
        }
        out.push(GraphLink { from: src, to: GraphPort::Sink });
        out
    }

    fn image_links(&self) -> Vec<GraphLink> {
        self.links.clone().unwrap_or_else(|| derived(self))
    }

    fn has_custom_wiring(&self) -> bool {
        self.links.is_some()
    }

    fn is_wiring_applied(&self) -> bool {
        self.links.is_none()
    }

    fn key_donors(&self, port: GraphPort) -> Vec<ColorStep> {
        let mut donors = Vec::new();
        for link in self.key_links.iter().filter(|l| l.to == port) {
            let Some(id) = link.from.step_id() else { continue };
            let Some(donor) = self.step(id) else { continue };
            if !donor.enabled {
                continue;
            }
            donors.push(donor.clone());
        }
        donors
    }

    fn uses_key_link(&self, id: Id) -> bool {
        self.key_links.iter().any(|l| l.from == GraphPort::Step(id) || l.to == GraphPort::Step(id))
    }

    fn refusal(&self, from: GraphPort, to: GraphPort) -> Option<LinkRefusal> {
        if from == GraphPort::Sink {
            return Some(LinkRefusal::NotAnOutput);
        }
        if to == GraphPort::Source {
            return Some(LinkRefusal::NotAnInput);
        }
        if !(exists(self, from) && exists(self, to)) {
            return Some(LinkRefusal::UnknownBox);
        }
        if from == to {
            return Some(LinkRefusal::SameBox);
        }
        if self.image_links().contains(&GraphLink { from, to }) {
            return Some(LinkRefusal::Duplicate);
        }
        if reaches(self, to, from) {
            return Some(LinkRefusal::Cycle);
        }
        None
    }

    fn key_refusal(&self, from: Id, to: GraphPort) -> Option<LinkRefusal> {
        if self.step(from).is_none() {
            return Some(LinkRefusal::UnknownBox);
        }
        if matches!(to, GraphPort::Source | GraphPort::Sink) {
            return Some(LinkRefusal::NotAKeyEnd);
        }
        if !exists(self, to) {
            return Some(LinkRefusal::UnknownBox);
        }
        if to == GraphPort::Step(from) {
            return Some(LinkRefusal::SameBox);
        }
        if self.key_links.contains(&GraphLink { from: GraphPort::Step(from), to }) {
            return Some(LinkRefusal::Duplicate);
        }
        if reaches(self, to, GraphPort::Step(from)) {
            return Some(LinkRefusal::Cycle);
        }
        None
    }

    fn connect(&mut self, from: GraphPort, to: GraphPort) -> Option<LinkRefusal> {
        if let Some(r) = self.refusal(from, to) {
            return Some(r);
        }
        let mut l = self.image_links();
        if !to.is_mixer() {
            l.retain(|x| x.to != to);
        }
        l.push(GraphLink { from, to });
        set_image_links(self, l);
        None
    }

    fn disconnect(&mut self, link: GraphLink) {
        let mut l = self.image_links();
        if !l.contains(&link) {
            return;
        }
        l.retain(|x| *x != link);
        set_image_links(self, l);
    }

    fn connect_key(&mut self, from: Id, to: GraphPort) -> Option<LinkRefusal> {
        if let Some(r) = self.key_refusal(from, to) {
            return Some(r);
        }
        if !to.is_mixer() {
            self.key_links.retain(|x| x.to != to);
        }
        self.key_links.push(GraphLink { from: GraphPort::Step(from), to });
        None
    }

    fn disconnect_key(&mut self, link: GraphLink) {
        self.key_links.retain(|x| *x != link);
    }

    fn insert(&mut self, id: Id, onto: GraphLink) -> bool {
        if self.step(id).is_none()
            || !self.image_links().contains(&onto)
            || onto.from == GraphPort::Step(id)
            || onto.to == GraphPort::Step(id)
        {
            return false;
        }
        let current = self.image_links();
        let mut l = detach(self, id, &current);
        if !l.contains(&onto) {
            return false;
        }
        l.retain(|x| *x != onto);
        if !onto.to.is_mixer() {
            l.retain(|x| x.to != onto.to);
        }
        l.push(GraphLink { from: onto.from, to: GraphPort::Step(id) });
        l.push(GraphLink { from: GraphPort::Step(id), to: onto.to });
        set_image_links(self, l);
        true
    }

    fn extract(&mut self, id: Id) -> bool {
        if self.steps().len() <= 1 || self.step(id).is_none() {
            return false;
        }
        let current = self.image_links();
        let l = detach(self, id, &current);
        set_image_links(self, l);
        true
    }
}

fn derived(g: &ColorGraph) -> Vec<GraphLink> {
    let cols: Vec<Vec<Id>> = g.columns().iter().map(|c| c.iter().map(|s| s.id).collect()).collect();
    ColorGraph::derived_links(&cols)
}

/// Lifts Step `id` out of `links`: its input goes to what it fed; a serial head that leaves hands its mixer to the
/// first follower. Changes the Step kinds like Swift's `detach` does.
pub(crate) fn detach(g: &mut ColorGraph, id: Id, links: &[GraphLink]) -> Vec<GraphLink> {
    let mut l = links.to_vec();
    let n = GraphPort::Step(id);
    let ins: Vec<GraphPort> = l.iter().filter(|x| x.to == n).map(|x| x.from).collect();
    let outs: Vec<GraphPort> = l.iter().filter(|x| x.from == n).map(|x| x.to).collect();
    l.retain(|x| x.from != n && x.to != n);
    if let Some(s) = ins.first() {
        for o in outs.iter().filter(|o| !o.is_mixer()) {
            l.retain(|x| x.to != *o);
            l.push(GraphLink { from: *s, to: *o });
        }
    }
    if let Some(i) = g.steps().iter().position(|s| s.id == id) {
        if g.steps()[i].kind == StepKind::Serial && i + 1 < g.steps().len() && g.steps()[i + 1].kind != StepKind::Serial
        {
            let new = g.steps()[i + 1].id;
            let swap = |p: GraphPort| if p == GraphPort::Mixer(id) { GraphPort::Mixer(new) } else { p };
            l = l.into_iter().map(|x| GraphLink { from: swap(x.from), to: swap(x.to) }).collect();
            let pos = g.steps()[i].mixer_position;
            edit(g, |steps| {
                steps[i + 1].kind = StepKind::Serial;
                steps[i + 1].mixer_position = pos;
            });
        }
        edit(g, |steps| {
            steps[i].kind = StepKind::Serial;
            steps[i].mixer_position = None;
        });
    }
    pruned(g, l)
}

/// Drops wires to Steps that are gone and folds away mixer boxes whose stack no longer exists.
fn pruned(g: &ColorGraph, links: Vec<GraphLink>) -> Vec<GraphLink> {
    let alive = |p: GraphPort| p.step_id().is_none_or(|i| g.step(i).is_some());
    let mut l: Vec<GraphLink> = links.into_iter().filter(|x| alive(x.from) && alive(x.to)).collect();
    let heads = g.mixer_heads();
    let mut gone: Vec<GraphPort> = Vec::new();
    for p in l.iter().flat_map(|x| [x.from, x.to]) {
        if let GraphPort::Mixer(h) = p
            && !heads.contains(&h)
            && !gone.contains(&p)
        {
            gone.push(p);
        }
    }
    for m in gone {
        let ins: Vec<GraphPort> = l.iter().filter(|x| x.to == m).map(|x| x.from).collect();
        let outs: Vec<GraphPort> = l.iter().filter(|x| x.from == m).map(|x| x.to).collect();
        l.retain(|x| x.from != m && x.to != m);
        if ins.len() == 1 {
            for o in outs {
                if !o.is_mixer() {
                    l.retain(|x| x.to != o);
                }
                l.push(GraphLink { from: ins[0], to: o });
            }
        }
    }
    l
}

/// Stores image wires: compiled back into Step kinds when possible, else kept as custom wiring (unless they equal
/// the derived ones).
pub(crate) fn set_image_links(g: &mut ColorGraph, links: Vec<GraphLink>) {
    let l = pruned(g, links);
    if let Some(c) = compile(g, &l) {
        apply_compiled(g, c);
        g.links = None;
    } else {
        g.links = if l == derived(g) { None } else { Some(l) };
    }
}

/// Re-compiles the custom wiring and drops key wires that point at nothing.
pub(crate) fn sanitize_wiring(g: &mut ColorGraph) {
    if let Some(l) = g.links.clone() {
        set_image_links(g, l);
    }
    let snapshot = g.clone();
    g.key_links.retain(|l| {
        let Some(from) = l.from.step_id() else { return false };
        snapshot.step(from).is_some() && exists(&snapshot, l.to)
    });
}

/// The Step order and kinds a wiring says.
struct Compiled {
    order: Vec<Id>,
    kinds: BTreeMap<Id, StepKind>,
    /// (old mixer head, new head) pairs.
    mixers: Vec<(Id, Id)>,
}

fn compile(g: &ColorGraph, l: &[GraphLink]) -> Option<Compiled> {
    let into = |p: GraphPort| -> Vec<GraphLink> { l.iter().filter(|x| x.to == p).copied().collect() };
    let mut cur = GraphPort::Source;
    let mut order: Vec<Id> = Vec::new();
    let mut kinds: BTreeMap<Id, StepKind> = BTreeMap::new();
    let mut mixers: Vec<(Id, Id)> = Vec::new();
    let mut used = 0usize;
    loop {
        let outs: Vec<GraphLink> = l.iter().filter(|x| x.from == cur).copied().collect();
        if outs.len() == 1 && outs[0].to == GraphPort::Sink {
            used += 1;
            if into(GraphPort::Sink).len() != 1 {
                return None;
            }
            break;
        }
        let targets: Vec<GraphPort> = outs.iter().map(|x| x.to).collect();
        if targets.len() == 1
            && let GraphPort::Step(s) = targets[0]
        {
            if g.step(s).is_none()
                || order.contains(&s)
                || into(GraphPort::Step(s)).len() != 1
                || l.iter().any(|x| x.from == GraphPort::Step(s) && x.to.is_mixer())
            {
                return None;
            }
            order.push(s);
            kinds.insert(s, StepKind::Serial);
            used += 1;
            cur = GraphPort::Step(s);
        } else if targets.len() >= 2 {
            let ids: Vec<Id> = targets.iter().filter_map(GraphPort::step_id).collect();
            let distinct: BTreeSet<Id> = ids.iter().copied().collect();
            if ids.len() != targets.len()
                || distinct.len() != ids.len()
                || !ids.iter().all(|i| g.step(*i).is_some() && !order.contains(i))
            {
                return None;
            }
            let mut mixer: Option<GraphPort> = None;
            for id in &ids {
                let o: Vec<&GraphLink> = l.iter().filter(|x| x.from == GraphPort::Step(*id)).collect();
                if into(GraphPort::Step(*id)).len() != 1
                    || o.len() != 1
                    || !o[0].to.is_mixer()
                    || !(mixer.is_none() || mixer == Some(o[0].to))
                {
                    return None;
                }
                mixer = Some(o[0].to);
            }
            let Some(GraphPort::Mixer(m)) = mixer else { return None };
            if into(GraphPort::Mixer(m)).len() != ids.len() {
                return None;
            }
            let members: Vec<Id> = into(GraphPort::Mixer(m)).iter().filter_map(|x| x.from.step_id()).collect();
            let member_set: BTreeSet<Id> = members.iter().copied().collect();
            if member_set != distinct {
                return None;
            }
            for (i, id) in members.iter().enumerate() {
                let old = g.step(*id).map_or(StepKind::Serial, |s| s.kind);
                let kind = if i == 0 {
                    StepKind::Serial
                } else if old == StepKind::Layer {
                    StepKind::Layer
                } else {
                    StepKind::Parallel
                };
                kinds.insert(*id, kind);
            }
            order.extend(members.iter().copied());
            mixers.push((m, members[0]));
            used += 2 * ids.len();
            cur = GraphPort::Mixer(m);
        } else {
            return None;
        }
    }
    if used != l.len() || order.len() != g.steps().len() {
        return None;
    }
    Some(Compiled { order, kinds, mixers })
}

fn apply_compiled(g: &mut ColorGraph, c: Compiled) {
    let old_pos: BTreeMap<Id, StepPosition> =
        g.steps().iter().filter_map(|s| s.mixer_position.map(|p| (s.id, p))).collect();
    let mut by_id: BTreeMap<Id, ColorStep> = g.steps().iter().map(|s| (s.id, s.clone())).collect();
    let mut out: Vec<ColorStep> = Vec::new();
    for id in &c.order {
        if let Some(mut s) = by_id.remove(id) {
            s.kind = c.kinds.get(id).copied().unwrap_or(StepKind::Serial);
            s.mixer_position = None;
            out.push(s);
        }
    }
    edit(g, |steps| *steps = out);
    for (old, head) in c.mixers {
        if let Some(p) = old_pos.get(&old).or_else(|| old_pos.get(&head)).copied() {
            g.set_mixer_position(head, Some(p));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use GraphPort::{Mixer, Sink, Source, Step};
    use sq_core_model::LUTRef;
    use sq_core_time::{IdSource, SequentialIds};

    fn link(from: GraphPort, to: GraphPort) -> GraphLink {
        GraphLink { from, to }
    }

    /// Three serial Steps a -> b -> c.
    fn chain() -> (ColorGraph, Id, Id, Id) {
        let mut ids = SequentialIds::default();
        let mut g = ColorGraph::new(Vec::new(), Some(LUTRef::Automatic), None, ids.next_id());
        let a = g.steps()[0].id;
        let b = g.add_step(Some(a), StepKind::Serial, &mut ids);
        let c = g.add_step(Some(b), StepKind::Serial, &mut ids);
        (g, a, b, c)
    }

    fn order(g: &ColorGraph) -> Vec<Id> {
        g.steps().iter().map(|s| s.id).collect()
    }

    #[test]
    fn derived_links_of_a_chain() {
        let (g, a, b, c) = chain();
        assert_eq!(
            g.image_links(),
            [link(Source, Step(a)), link(Step(a), Step(b)), link(Step(b), Step(c)), link(Step(c), Sink)]
        );
        assert!(!g.has_custom_wiring() && g.is_wiring_applied());
    }

    #[test]
    fn reconnecting_the_same_chain_stays_derived() {
        let (mut g, a, b, c) = chain();
        g.disconnect(link(Step(b), Step(c)));
        assert!(g.has_custom_wiring(), "a Step without input is not a column graph");
        assert_eq!(g.connect(Step(b), Step(c)), None);
        assert!(!g.has_custom_wiring());
        assert_eq!(order(&g), [a, b, c]);
    }

    #[test]
    fn cycle_is_refused() {
        let (mut g, a, _, c) = chain();
        assert_eq!(g.refusal(Step(c), Step(a)), Some(LinkRefusal::Cycle));
        assert_eq!(g.connect(Step(c), Step(a)), Some(LinkRefusal::Cycle));
        assert!(!g.has_custom_wiring());
    }

    #[test]
    fn output_to_output_and_input_to_input_are_refused() {
        let (mut g, a, _, _) = chain();
        assert_eq!(g.connect(Sink, Step(a)), Some(LinkRefusal::NotAnOutput));
        assert_eq!(g.connect(Step(a), Source), Some(LinkRefusal::NotAnInput));
        assert_eq!(g.connect(Step(a), Step(a)), Some(LinkRefusal::SameBox));
    }

    #[test]
    fn a_second_wire_into_a_step_replaces_the_first() {
        let (mut g, a, b, c) = chain();
        assert_eq!(g.connect(Step(a), Step(c)), None);
        let into: Vec<GraphLink> = g.image_links().into_iter().filter(|l| l.to == Step(c)).collect();
        assert_eq!(into, [link(Step(a), Step(c))]);
        assert!(g.step(b).is_some());
    }

    #[test]
    fn a_step_fans_out_to_two_steps_and_keeps_custom_wiring() {
        let (mut g, a, b, c) = chain();
        g.connect(Step(a), Step(c)); // a feeds b and c; c's input from b is replaced
        assert_eq!(g.image_links().iter().filter(|l| l.from == Step(a)).count(), 2);
        assert!(g.step(b).is_some());
    }

    #[test]
    fn parallel_branches_join_in_a_mixer() {
        let mut ids = SequentialIds::default();
        let mut g = ColorGraph::new(Vec::new(), Some(LUTRef::Automatic), None, ids.next_id());
        let a = g.steps()[0].id;
        let p = g.add_step(Some(a), StepKind::Parallel, &mut ids);
        assert_eq!(g.mixer_heads(), [a]);
        // A third branch wired into the mixer is accepted.
        let q = g.add_step(Some(p), StepKind::Serial, &mut ids);
        g.connect(Source, Step(q));
        assert_eq!(g.connect(Step(q), Mixer(a)), None);
        assert!(g.image_links().contains(&link(Step(q), Mixer(a))));
    }

    #[test]
    fn removing_a_step_heals_the_wires() {
        let (mut g, a, b, c) = chain();
        g.remove_step(b);
        assert_eq!(order(&g), [a, c]);
        assert!(g.image_links().contains(&link(Step(a), Step(c))));
    }

    #[test]
    fn removing_a_step_in_custom_wiring_heals_too() {
        let (mut g, a, b, c) = chain();
        g.connect(Source, Step(c)); // custom: c's input from b is replaced by the source
        g.disconnect(link(Step(a), Step(b)));
        g.remove_step(b);
        assert!(g.step(b).is_none());
        assert!(g.image_links().iter().all(|l| exists(&g, l.from) && exists(&g, l.to)));
    }

    #[test]
    fn inserting_onto_a_wire_puts_the_step_between() {
        let (mut g, a, b, c) = chain();
        assert!(g.insert(a, link(Step(b), Step(c))));
        assert_eq!(order(&g), [b, a, c]);
        assert!(!g.has_custom_wiring());
    }

    #[test]
    fn inserting_onto_its_own_wire_is_refused() {
        let (mut g, a, b, _) = chain();
        assert!(!g.insert(b, link(Step(a), Step(b))));
    }

    #[test]
    fn detaching_closes_the_gap() {
        let (mut g, a, b, c) = chain();
        let links = g.image_links();
        let healed = detach(&mut g, b, &links);
        assert!(healed.contains(&link(Step(a), Step(c))));
        assert!(!healed.iter().any(|l| l.from == Step(b) || l.to == Step(b)));
    }

    #[test]
    fn extracting_leaves_the_step_unwired_and_closes_the_chain() {
        let (mut g, a, b, c) = chain();
        assert!(g.extract(b));
        assert!(g.has_custom_wiring());
        assert!(g.image_links().contains(&link(Step(a), Step(c))));
        assert!(!g.image_links().iter().any(|l| l.from == Step(b) || l.to == Step(b)));
        assert!(g.insert(b, link(Step(a), Step(c))) && !g.has_custom_wiring() && order(&g) == [a, b, c]);
    }

    #[test]
    fn extracting_the_only_step_does_nothing() {
        let mut g = ColorGraph::new(Vec::new(), None, None, Id::from_u128(1));
        let id = g.steps()[0].id;
        assert!(!g.extract(id));
    }

    #[test]
    fn key_wires_are_stored_refused_on_cycle_and_dropped_with_the_step() {
        let (mut g, a, b, c) = chain();
        assert_eq!(g.connect_key(a, Step(c)), None);
        assert_eq!(g.key_links, [link(Step(a), Step(c))]);
        assert!(g.uses_key_link(a) && g.uses_key_link(c) && !g.uses_key_link(b));
        assert!(g.is_wiring_applied(), "key wires are applied by the renderer");
        assert_eq!(g.connect_key(a, Step(c)), Some(LinkRefusal::Duplicate));
        assert_eq!(g.connect_key(c, Step(a)), Some(LinkRefusal::Cycle));
        assert_eq!(g.connect_key(a, Sink), Some(LinkRefusal::NotAKeyEnd));
        g.remove_step(c);
        assert!(g.key_links.is_empty() && g.is_wiring_applied());
    }

    #[test]
    fn a_key_input_holds_one_wire() {
        let (mut g, a, b, c) = chain();
        g.connect_key(a, Step(c));
        g.connect_key(b, Step(c));
        assert_eq!(g.key_links, [link(Step(b), Step(c))]);
    }

    #[test]
    fn key_donors_are_the_enabled_steps_wired_to_a_port() {
        let (mut g, a, b, c) = chain();
        g.connect_key(a, Step(c));
        assert_eq!(g.key_donors(Step(c)).len(), 1);
        g.set_step_enabled(a, false);
        assert!(g.key_donors(Step(c)).is_empty());
        assert!(g.key_donors(Step(b)).is_empty());
    }

    #[test]
    fn setting_a_kind_drops_custom_wiring() {
        let (mut g, a, b, c) = chain();
        g.disconnect(link(Step(a), Step(b)));
        assert!(g.has_custom_wiring());
        g.set_kind(c, StepKind::Parallel);
        assert!(!g.has_custom_wiring());
    }

    #[test]
    fn custom_wiring_and_key_wires_survive_a_save_and_load() {
        let (mut g, a, b, c) = chain();
        g.connect_key(a, Step(c));
        g.disconnect(link(Step(a), Step(b)));
        assert!(g.uses_v80_fields());
        let json = serde_json::to_string(&g).unwrap_or_default();
        let mut back: ColorGraph = serde_json::from_str(&json).expect("decodes");
        back.sanitize_wiring();
        assert_eq!(back, g);
        assert_eq!(back.links, g.links);
        assert!(chain().0.image_links().len() == 4 && !chain().0.uses_v80_fields());
    }
}
