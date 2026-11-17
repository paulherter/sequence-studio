// Swift: GraphicsEditor+Follow.swift, GraphicsEditor+EffectPresets.swift, GraphicsEditor.offeredEffects
//! The Graphics editor's Follow rows, the Add Effect list and the layer effect presets.

use sq_core_effects::effect_preset::{Anchor, EffectPreset};
use sq_core_graphics::graphics_editing::GraphicsDocumentEditingExt;
use sq_core_graphics::graphics_follow::{GraphicsFollowDocumentExt, GraphicsFollowExt};
use sq_core_model::{
    AnimatedProperty, ClipEffect, EffectCatalog, EffectSpec, FollowTarget, GraphicsEdges, GraphicsFollow, GraphicsLayer,
};
use sq_core_time::{Id, IdSource};
use sq_editor_session::EditorSession;

use crate::graphics::editor::{EffectDrop, GraphicsEditor};

impl GraphicsEditor {
    /// Every edge and this padding for a new Follow (a box around a title).
    pub const DEFAULT_FOLLOW_PADDING: f64 = 24.0;

    /// The single selected layer's Follow (`None` = follows nothing).
    pub fn follow<'a>(&self, session: &'a EditorSession) -> Option<&'a GraphicsFollow> {
        self.selected_layer(session)?.follow.as_ref()
    }

    /// Layers the selected layer may follow (no cycle), front first.
    pub fn follow_candidates(&self, session: &EditorSession) -> Vec<GraphicsLayer> {
        let (Some(l), Some(d)) = (self.selected_layer(session), self.document(session)) else { return Vec::new() };
        d.follow_candidates(l.id)
    }

    /// Sets what the selected layer follows (`None` = nothing). A new Follow takes every edge and the default padding; a
    /// change of target keeps the edges and padding. A target that would close a cycle is refused.
    pub fn set_follow_target(&mut self, session: &mut EditorSession, target: Option<FollowTarget>) {
        let Some(l) = self.selected_layer(session).cloned() else { return };
        if l.is_locked {
            return;
        }
        if let Some(FollowTarget::Layer(id)) = target
            && !self.follow_candidates(session).iter().any(|c| c.id == id)
        {
            return;
        }
        let next = target.map(|t| {
            let mut f = l.follow.clone().unwrap_or(GraphicsFollow {
                target: t,
                edges: GraphicsEdges::ALL,
                padding: Self::DEFAULT_FOLLOW_PADDING,
                edge_padding: None,
            });
            f.target = t;
            f
        });
        if next == l.follow {
            return;
        }
        let name = if next.is_none() { "Stop Following" } else { "Follow" };
        self.edit(session, name, None, |d| d.update(l.id, |x| x.follow = next));
    }

    /// Switches one edge of the selected layer's Follow on or off.
    pub fn toggle_follow_edge(&mut self, session: &mut EditorSession, edge: GraphicsEdges) {
        let Some(l) = self.selected_layer(session).cloned() else { return };
        let Some(mut f) = l.follow.clone().filter(|_| !l.is_locked) else { return };
        f.edges = GraphicsEdges(f.edges.0 ^ edge.0);
        self.edit(session, "Follow Edges", None, |d| d.update(l.id, |x| x.follow = Some(f)));
    }

    /// One edge's padding of the selected layer's Follow (a drag is one undo step). Four equal values collapse again.
    pub fn set_follow_padding(&mut self, session: &mut EditorSession, v: f64, edge: GraphicsEdges) {
        let Some(l) = self.selected_layer(session).cloned() else { return };
        let Some(mut f) = l.follow.clone().filter(|_| !l.is_locked) else { return };
        let before = f.clone();
        f.set_padding(v, edge);
        if f == before {
            return;
        }
        let merge = format!("props:followPadding:{}", l.id);
        self.edit(session, "Follow Padding", Some(&merge), |d| d.update(l.id, |x| x.follow = Some(f)));
    }

    /// "Follows" popup title of a target.
    pub fn follow_title(&self, session: &EditorSession, t: Option<FollowTarget>) -> String {
        match t {
            None => "None".to_string(),
            Some(FollowTarget::Frame) => "Frame".to_string(),
            Some(FollowTarget::Layer(id)) => {
                self.document(session).and_then(|d| d.layer(id)).map_or_else(|| "None".to_string(), |l| l.name.clone())
            }
        }
    }

    /// What the Add Effect menu lists: the visible catalog minus anything a layer refuses, sorted by title.
    pub fn offered_effects() -> Vec<EffectSpec> {
        let mut v: Vec<EffectSpec> = EffectCatalog::all()
            .into_iter()
            .filter(|s| !EffectCatalog::is_generator_owned(&s.kind) && Self::refusal_for_effect(&s.kind).is_none())
            .collect();
        v.sort_by_key(|s| s.title.to_lowercase());
        v
    }

    /// The effects a preset of the selected layer would hold (generator-owned looks stay out).
    pub fn preset_effects(&self, session: &EditorSession) -> Vec<ClipEffect> {
        self.selected_layer(session).map_or_else(Vec::new, |l| {
            l.effects.iter().filter(|e| !EffectCatalog::is_generator_owned(&e.kind) && !e.is_audio()).cloned().collect()
        })
    }

    /// A preset of the selected layer's effects; `None` when the layer has none.
    pub fn layer_effect_preset(&self, session: &EditorSession) -> Option<EffectPreset> {
        let fx = self.preset_effects(session);
        let c = self.clip(session)?;
        if fx.is_empty() {
            return None;
        }
        let mut p = EffectPreset::new(Anchor::Start, c.duration());
        p.effects = fx;
        p.frame_size = Some(self.canvas(session));
        Some(p)
    }

    /// Appends the preset's effects (fresh ids, also for every key) to `layer` (default the selected one) as one undo step.
    /// Kinds a layer refuses are skipped; the first refusal is returned when nothing was added. Motion values of the
    /// preset are ignored: layers keep their own transform.
    pub fn apply_effect_preset(
        &mut self,
        session: &mut EditorSession,
        preset: &EffectPreset,
        name: &str,
        layer: Option<Id>,
    ) -> EffectDrop {
        let none = || EffectDrop::Refused("Select a layer first.".to_string());
        let Some(id) = layer.or_else(|| self.selected_layer(session).map(|l| l.id)) else { return none() };
        let Some(locked) = self.document(session).and_then(|d| d.layer(id)).map(|l| l.is_locked) else { return none() };
        if locked {
            return EffectDrop::Refused("The layer is locked.".to_string());
        }
        let mut refusal: Option<String> = None;
        let eligible: Vec<&ClipEffect> = preset
            .effects
            .iter()
            .filter(|fx| match Self::refusal_for_effect(&fx.kind) {
                Some(why) => {
                    refusal.get_or_insert_with(|| why.to_string());
                    false
                }
                None => true,
            })
            .collect();
        if eligible.is_empty() {
            return EffectDrop::Refused(
                refusal.unwrap_or_else(|| format!("\u{201c}{name}\u{201d} has no layer effects.")),
            );
        }
        let title = format!("Apply Preset \u{201c}{name}\u{201d}");
        self.edit_with_ids(session, &title, None, |d, ids| {
            let added: Vec<ClipEffect> =
                eligible.iter().map(|fx| fresh_copy(&fx.upgrading_legacy_shadow_color(ids), ids)).collect();
            d.update(id, |l| l.effects.extend(added));
        });
        EffectDrop::Added
    }
}

fn fresh_copy(fx: &ClipEffect, ids: &mut dyn IdSource) -> ClipEffect {
    fn fresh<V: Clone>(p: &AnimatedProperty<V>, ids: &mut dyn IdSource) -> AnimatedProperty<V> {
        let mut c = p.clone();
        for k in &mut c.track.keys {
            k.id = ids.next_id();
        }
        c
    }
    let mut e = fx.clone();
    e.id = ids.next_id();
    e.parameters = fx.parameters.iter().map(|(k, p)| (k.clone(), fresh(p, ids))).collect();
    e.colors = fx.colors.iter().map(|(k, p)| (k.clone(), fresh(p, ids))).collect();
    e.points = fx.points.iter().map(|(k, p)| (k.clone(), fresh(p, ids))).collect();
    e
}
