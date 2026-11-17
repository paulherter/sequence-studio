// Swift: GraphicsEditor.swift (Property, values, keys, colors, shape kind, shadow, layer effect edits)
//! The property half of the Graphics editor: every value, key and color operation acts on the selected layers at the
//! playhead (clip-local time). Reads show `None` when the layers differ ("mixed"); writes go to every selected layer as
//! one undo step per gesture. [`GraphicsItemHost`] lets the Controls > Graphic rows drive the editor.

use std::collections::BTreeSet;

use sq_core_graphics::graphics_editing::{GraphicsDocumentEditingExt, Vec2PropertyExt};
use sq_core_model::{
    AnimatedProperty, BlendMode, ClipEffect, EaseShape, EffectCatalog, EffectColor, EffectParamKind, GraphicsContent,
    GraphicsLayer, ShapeKind,
};

use sq_core_time::{EaseSide, EasingCurve, Id, IdSource, Keyframe, KeyframeValue, Time, Vec2};
use sq_editor_session::EditorSession;
use sq_text::text_generator::TextGenerator;
use sq_uikit::keyframe_control_state::KeyframeControlState;

use crate::graphics::editor::GraphicsEditor;
use crate::graphics::graphic_item_rows_draw::ItemRowsHost;

/// An animatable property of a layer (Swift `GraphicsEditor.Property`). `id`: the effect instance (`None` = the layer's
/// first effect of that kind).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Property {
    Position,
    Anchor,
    Scale,
    Rotation,
    Opacity,
    Effect { kind: String, key: String, id: Option<Id> },
    EffectPoint { kind: String, key: String, id: Option<Id> },
}

impl Property {
    /// A parameter of the layer's Shape look.
    pub fn shape(key: &str) -> Property {
        Property::Effect { kind: ClipEffect::SHAPE_EFFECT_KIND.to_string(), key: key.to_string(), id: None }
    }

    /// Merge key for gestures.
    pub fn id(&self) -> String {
        let fid = |i: &Option<Id>| i.map(|i| i.to_string().to_uppercase()).unwrap_or_default();
        match self {
            Property::Position => "position".into(),
            Property::Anchor => "anchor".into(),
            Property::Scale => "scale".into(),
            Property::Rotation => "rotation".into(),
            Property::Opacity => "opacity".into(),
            Property::Effect { kind, key, id } => format!("{kind}.{key}.{}", fid(id)),
            Property::EffectPoint { kind, key, id } => format!("{kind}.{key}.point.{}", fid(id)),
        }
    }

    /// Name used in tooltips and undo names ("Add Opacity Keyframe").
    pub fn title(&self) -> String {
        match self {
            Property::Effect { kind, key, .. } | Property::EffectPoint { kind, key, .. } => {
                EffectCatalog::param(kind, key).map(|p| p.title).unwrap_or_else(|| key.clone())
            }
            _ => {
                let id = self.id();
                let mut c = id.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            }
        }
    }
}

enum KeyOp<'a> {
    Start,
    Stop,
    Add,
    Remove,
    Ease(&'a EasingCurve),
}

fn fx_index(l: &GraphicsLayer, kind: &str, id: Option<Id>) -> Option<usize> {
    match id {
        Some(id) => l.effects.iter().position(|e| e.id == id),
        None => l.effects.iter().position(|e| e.kind == kind),
    }
}

fn axis_of(v: Vec2, axis: usize) -> f64 {
    if axis == 0 { v.x } else { v.y }
}

fn component(l: &GraphicsLayer, p: &Property, axis: usize, t: Time) -> Option<f64> {
    let a = &l.animation;
    match p {
        Property::Position => Some(axis_of(a.position.value_at_local(t), axis)),
        Property::Anchor => Some(axis_of(a.anchor.value_at_local(t), axis)),
        Property::Scale => Some(axis_of(a.scale.value_at_local(t), axis)),
        Property::Rotation => Some(a.rotation.value_at_local(t)),
        Property::Opacity => Some(a.opacity.value_at_local(t)),
        Property::Effect { kind, key, id } => fx_index(l, kind, *id).map(|i| l.effects[i].scalar(key, t)),
        Property::EffectPoint { kind, key, id } => {
            let e = &l.effects[fx_index(l, kind, *id)?];
            e.points.get(key).map(|v| axis_of(v.value_at_local(t), axis))
        }
    }
}

fn write(l: &mut GraphicsLayer, p: &Property, axis: usize, v: f64, t: Time, ids: &mut dyn IdSource) {
    fn vec(a: &mut AnimatedProperty<Vec2>, is_position: bool, axis: usize, v: f64, t: Time, ids: &mut dyn IdSource) {
        let mut x = a.value_at_local(t);
        if axis == 0 {
            x.x = v;
        } else {
            x.y = v;
        }
        // A layer's typed Position is the base of its animation: the keys move with it.
        if is_position {
            *a = a.moved_base(x, t);
        } else {
            a.set_at_local(x, t, ids);
        }
    }
    match p {
        Property::Position => vec(&mut l.animation.position, true, axis, v, t, ids),
        Property::Anchor => vec(&mut l.animation.anchor, false, axis, v, t, ids),
        Property::Scale => vec(&mut l.animation.scale, false, axis, v, t, ids),
        Property::Rotation => l.animation.rotation.set_at_local(v, t, ids),
        Property::Opacity => l.animation.opacity.set_at_local(v.clamp(0.0, 1.0), t, ids),
        Property::Effect { kind, key, id } => {
            let Some(i) = fx_index(l, kind, *id) else { return };
            let mut prop = l.effects[i]
                .parameters
                .get(key)
                .cloned()
                .unwrap_or_else(|| AnimatedProperty::new(l.effects[i].scalar(key, t)));
            prop.set_at_local(v, t, ids);
            l.effects[i].parameters.insert(key.clone(), prop);
        }
        Property::EffectPoint { kind, key, id } => {
            let Some(i) = fx_index(l, kind, *id) else { return };
            let mut prop = l.effects[i].points.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(Vec2::ZERO));
            vec(&mut prop, false, axis, v, t, ids);
            l.effects[i].points.insert(key.clone(), prop);
        }
    }
}

fn key_info_of<V: KeyframeValue>(a: &AnimatedProperty<V>) -> (bool, Vec<Time>, Vec<EaseShape>) {
    (
        a.is_animated(),
        a.track.keys.iter().map(|k| k.time).collect(),
        a.track.keys.iter().map(|k| EaseShape::new(k.interpolation, k.out_handle, k.in_handle)).collect(),
    )
}

fn key_info(l: &GraphicsLayer, p: &Property) -> (bool, Vec<Time>, Vec<EaseShape>) {
    let a = &l.animation;
    match p {
        Property::Position => key_info_of(&a.position),
        Property::Anchor => key_info_of(&a.anchor),
        Property::Scale => key_info_of(&a.scale),
        Property::Rotation => key_info_of(&a.rotation),
        Property::Opacity => key_info_of(&a.opacity),
        Property::Effect { kind, key, id } => {
            match fx_index(l, kind, *id).and_then(|i| l.effects[i].parameters.get(key)) {
                Some(prop) => key_info_of(prop),
                None => (false, Vec::new(), Vec::new()),
            }
        }
        Property::EffectPoint { kind, key, id } => {
            match fx_index(l, kind, *id).and_then(|i| l.effects[i].points.get(key)) {
                Some(prop) => key_info_of(prop),
                None => (false, Vec::new(), Vec::new()),
            }
        }
    }
}

fn run<V: KeyframeValue>(op: &KeyOp, a: &mut AnimatedProperty<V>, t: Time, ids: &mut dyn IdSource) {
    match op {
        KeyOp::Start => {
            if !a.is_animated() {
                a.toggle_keyframing_at_local(t, ids);
            }
        }
        KeyOp::Stop => {
            if a.is_animated() {
                a.toggle_keyframing_at_local(t, ids);
            }
        }
        KeyOp::Add => {
            if !a.is_animated() {
                a.toggle_keyframing_at_local(t, ids);
            } else if !a.track.keys.iter().any(|k| k.time == t) {
                let v = a.value_at_local(t);
                a.track.insert(Keyframe::new(ids.next_id(), t, v));
            }
        }
        KeyOp::Remove => {
            if let Some(id) = a.track.keys.iter().find(|k| k.time == t).map(|k| k.id)
                && a.track.keys.len() > 1
            {
                a.track.remove(id);
            }
        }
        KeyOp::Ease(curve) => {
            // Only the key at the playhead; between keys nothing is overwritten.
            let on: Vec<Id> = a.track.keys.iter().filter(|k| k.time == t).map(|k| k.id).collect();
            for id in on {
                a.track.update(id, |k| curve.apply(k, EaseSide::Both));
            }
        }
    }
}

fn apply(op: &KeyOp, p: &Property, l: &mut GraphicsLayer, t: Time, ids: &mut dyn IdSource) {
    match p {
        Property::Position => run(op, &mut l.animation.position, t, ids),
        Property::Anchor => run(op, &mut l.animation.anchor, t, ids),
        Property::Scale => run(op, &mut l.animation.scale, t, ids),
        Property::Rotation => run(op, &mut l.animation.rotation, t, ids),
        Property::Opacity => run(op, &mut l.animation.opacity, t, ids),
        Property::Effect { kind, key, id } => {
            let Some(i) = fx_index(l, kind, *id) else { return };
            let mut prop = l.effects[i]
                .parameters
                .get(key)
                .cloned()
                .unwrap_or_else(|| AnimatedProperty::new(l.effects[i].scalar(key, t)));
            run(op, &mut prop, t, ids);
            l.effects[i].parameters.insert(key.clone(), prop);
        }
        Property::EffectPoint { kind, key, id } => {
            let Some(i) = fx_index(l, kind, *id) else { return };
            let mut prop = l.effects[i].points.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(Vec2::ZERO));
            run(op, &mut prop, t, ids);
            l.effects[i].points.insert(key.clone(), prop);
        }
    }
}

/// The target layers in a merge key: edits on another selection never fold into the same undo step.
fn merge_ids(ids: &[Id]) -> String {
    let mut s: Vec<String> = ids.iter().map(|i| i.to_string().to_uppercase()).collect();
    s.sort();
    s.join(",")
}

/// All equal (within `eps`) or `None`; every layer must have the value.
fn common(vs: Vec<Option<f64>>, eps: f64) -> Option<f64> {
    let n = vs.len();
    let vs: Vec<f64> = vs.into_iter().flatten().collect();
    let first = *vs.first()?;
    (vs.len() == n && vs.iter().all(|v| (v - first).abs() <= eps)).then_some(first)
}

fn layer_color(l: &GraphicsLayer, kind: &str, key: &str, t: Time) -> Option<EffectColor> {
    let e = l.effects.iter().find(|e| e.kind == kind)?;
    if let Some(c) = e.colors.get(key) {
        return Some(c.value_at_local(t));
    }
    match EffectCatalog::param(&e.kind, key)?.kind {
        EffectParamKind::Color(c) => Some(c),
        _ => None,
    }
}

impl GraphicsEditor {
    fn target_ids(&self, session: &EditorSession) -> Vec<Id> {
        self.target_layers(session).iter().map(|l| l.id).collect()
    }

    /// The value shown for `p` (component `axis` of a Vec2): `None` when the selected layers differ or one lacks it.
    pub fn value(&self, session: &EditorSession, p: &Property, axis: usize) -> Option<f64> {
        let t = self.local_time(session);
        common(self.target_layers(session).iter().map(|l| component(l, p, axis, t)).collect(), 1e-9)
    }

    fn write_all(
        &mut self,
        session: &mut EditorSession,
        p: &Property,
        body: impl Fn(&mut GraphicsLayer, Time, &mut dyn IdSource),
    ) {
        let ids = self.target_ids(session);
        if ids.is_empty() {
            return;
        }
        let t = self.local_time(session);
        let merge = format!("props:{}:{}", p.id(), merge_ids(&ids));
        self.edit_with_ids(session, &p.title(), Some(&merge), |d, src| {
            for id in &ids {
                d.update(*id, |l| body(l, t, src));
            }
        });
    }

    /// Sets component `axis` of `p` on every selected layer (the other component stays per layer); keys where animated.
    pub fn set_value(&mut self, session: &mut EditorSession, p: &Property, axis: usize, v: f64) {
        self.write_all(session, p, |l, t, ids| write(l, p, axis, v, t, ids));
    }

    /// Linked scale: component `axis` becomes `v` on every selected layer, the other follows in that layer's own ratio.
    pub fn set_scale_linked(&mut self, session: &mut EditorSession, axis: usize, v: f64) {
        self.write_all(session, &Property::Scale, |l, t, ids| {
            let old = l.animation.scale.value_at_local(t);
            let (o, other) = if axis == 0 { (old.x, old.y) } else { (old.y, old.x) };
            let n = if o.abs() > 1e-9 { other * (v / o) } else { v };
            let new = if axis == 0 { Vec2::new(v, n) } else { Vec2::new(n, v) };
            l.animation.scale.set_at_local(new, t, ids);
        });
    }

    /// The blend mode shown (`None` when the selected layers differ).
    pub fn blend_mode(&self, session: &EditorSession) -> Option<BlendMode> {
        let ls = self.target_layers(session);
        let first = ls.first()?.blend_mode;
        ls.iter().all(|l| l.blend_mode == first).then_some(first)
    }

    pub fn set_blend_mode(&mut self, session: &mut EditorSession, m: BlendMode) {
        let ids = self.target_ids(session);
        if ids.is_empty() {
            return;
        }
        let merge = format!("props:blend:{}", merge_ids(&ids));
        self.edit(session, "Blend Mode", Some(&merge), |d| {
            for id in &ids {
                d.update(*id, |l| l.blend_mode = m);
            }
        });
    }

    pub fn set_position(&mut self, session: &mut EditorSession, v: Vec2) {
        self.set_value(session, &Property::Position, 0, v.x);
        self.set_value(session, &Property::Position, 1, v.y);
    }

    /// Uniform scale on every selected layer.
    pub fn set_scale(&mut self, session: &mut EditorSession, v: f64) {
        self.write_all(session, &Property::Scale, |l, t, ids| {
            l.animation.scale.set_at_local(Vec2::new(v, v), t, ids);
        });
    }

    pub fn set_rotation(&mut self, session: &mut EditorSession, v: f64) {
        self.set_value(session, &Property::Rotation, 0, v);
    }

    pub fn set_opacity(&mut self, session: &mut EditorSession, v: f64) {
        self.set_value(session, &Property::Opacity, 0, v);
    }

    // MARK: Keys (state of the front-most selected layer; buttons act on every selected layer)

    fn apply_all(&mut self, session: &mut EditorSession, op: KeyOp, p: &Property, name: &str, merge: Option<&str>) {
        let ids: Vec<Id> = self.target_layers(session).iter().filter(|l| !l.is_locked).map(|l| l.id).collect();
        if ids.is_empty() {
            return;
        }
        let t = self.local_time(session);
        self.edit_with_ids(session, name, merge, |d, src| {
            for id in &ids {
                d.update(*id, |l| apply(&op, p, l, t, src));
            }
        });
    }

    /// Ease of the key at the playhead of `p`; `None` when the playhead is not on a key.
    pub fn key_ease_shape(&self, session: &EditorSession, p: &Property) -> Option<EaseShape> {
        let info = key_info(self.primary_layer(session)?, p);
        let t = self.local_time(session);
        info.1.iter().position(|k| *k == t).map(|i| info.2[i])
    }

    /// The name of that ease from the one vocabulary, "Custom" when no built-in matches.
    pub fn key_ease_name(&self, session: &EditorSession, p: &Property) -> Option<String> {
        let s = self.key_ease_shape(session, p)?;
        let found = EasingCurve::built_ins()
            .into_iter()
            .find(|c| EaseShape::new(c.interpolation(), c.out_handle, c.in_handle).is_approximately_equal(&s));
        Some(
            found
                .map(|c| c.display_name().to_string())
                .unwrap_or_else(|| sq_core_time::ease_names::ease_name::CUSTOM.into()),
        )
    }

    /// Ease of the layer key at the playhead (no-op between keys, so hand-set eases are never overwritten). `merge`
    /// joins a drag.
    pub fn set_key_ease(&mut self, session: &mut EditorSession, p: &Property, curve: &EasingCurve, merge: bool) {
        if !self.is_key_at_playhead(session, p) {
            return;
        }
        let m = format!("ease:{}", p.id());
        self.apply_all(session, KeyOp::Ease(curve), p, &format!("Set {} Ease", p.title()), merge.then_some(m.as_str()));
    }

    pub fn is_keyed(&self, session: &EditorSession, p: &Property) -> bool {
        self.primary_layer(session).is_some_and(|l| key_info(l, p).0)
    }

    /// Keys of every selected layer (navigation and the key button look at all of them).
    fn key_times(&self, session: &EditorSession, p: &Property) -> Vec<Time> {
        let set: BTreeSet<Time> = self.target_layers(session).iter().flat_map(|l| key_info(l, p).1).collect();
        set.into_iter().collect()
    }

    /// What the shared keyframe control shows for `p`.
    pub fn keyframe_state(&self, session: &EditorSession, p: &Property) -> KeyframeControlState {
        KeyframeControlState::resolve(
            self.is_keyed(session, p),
            self.is_key_at_playhead(session, p),
            self.previous_key_time(session, p).is_some(),
            self.next_key_time(session, p).is_some(),
            self.playhead_in_clip(session),
        )
    }

    pub fn key_count(&self, session: &EditorSession, p: &Property) -> usize {
        self.key_times(session, p).len()
    }

    pub fn is_key_at_playhead(&self, session: &EditorSession, p: &Property) -> bool {
        self.key_times(session, p).contains(&self.local_time(session))
    }

    /// Nearest key before the playhead in clip-local time.
    pub fn previous_key_time(&self, session: &EditorSession, p: &Property) -> Option<Time> {
        let now = self.local_time(session);
        self.key_times(session, p).into_iter().filter(|k| *k < now).max()
    }

    /// Nearest key after the playhead in clip-local time.
    pub fn next_key_time(&self, session: &EditorSession, p: &Property) -> Option<Time> {
        let now = self.local_time(session);
        self.key_times(session, p).into_iter().filter(|k| *k > now).min()
    }

    /// Key button: adds a key with the current value at the playhead on every selected layer, or removes the keys there.
    /// Needs an animated property (the stopwatch turns animation on).
    pub fn toggle_key_at_playhead(&mut self, session: &mut EditorSession, p: &Property) {
        if !self.is_keyed(session, p) {
            return;
        }
        let adding = !self.is_key_at_playhead(session, p);
        let (op, name) = if adding {
            (KeyOp::Add, format!("Add {} Keyframe", p.title()))
        } else {
            (KeyOp::Remove, format!("Remove {} Keyframe", p.title()))
        };
        self.apply_all(session, op, p, &name, None);
    }

    /// Stopwatch: animation on (a key at the playhead) or off for every selected layer.
    pub fn toggle_keyframing(&mut self, session: &mut EditorSession, p: &Property) {
        let on = self.is_keyed(session, p);
        let (op, name) = if on {
            (KeyOp::Stop, format!("Stop Animating {}", p.title()))
        } else {
            (KeyOp::Start, format!("Animate {}", p.title()))
        };
        self.apply_all(session, op, p, &name, None);
    }

    // MARK: Shape values and colors

    /// Shape effect value (Width, Height, Corner Radius, Outline Width, Fill/Outline on-off) at the playhead; `None` = mixed.
    pub fn shape_value(&self, session: &EditorSession, key: &str) -> Option<f64> {
        self.value(session, &Property::shape(key), 0)
    }

    pub fn set_shape_value(&mut self, session: &mut EditorSession, key: &str, v: f64) {
        self.set_value(session, &Property::shape(key), 0, v);
    }

    /// Color `key` of the first `kind` effect of every selected layer at the playhead; `None` when they differ.
    pub fn color(&self, session: &EditorSession, kind: &str, key: &str) -> Option<EffectColor> {
        let t = self.local_time(session);
        let ls = self.target_layers(session);
        let cs: Vec<EffectColor> = ls.iter().filter_map(|l| layer_color(l, kind, key, t)).collect();
        let first = *cs.first()?;
        (cs.len() == ls.len() && cs.iter().all(|c| *c == first)).then_some(first)
    }

    /// Sets color `key` of the first `kind` effect on every selected layer (one step per picker session).
    pub fn set_color(&mut self, session: &mut EditorSession, kind: &str, key: &str, c: EffectColor) {
        let ids = self.target_ids(session);
        if ids.is_empty() {
            return;
        }
        let t = self.local_time(session);
        let name = EffectCatalog::param(kind, key).map(|p| p.title).unwrap_or_else(|| "Color".into());
        let merge = format!("props:color:{kind}.{key}:{}", merge_ids(&ids));
        self.edit_with_ids(session, &name, Some(&merge), |d, src| {
            for id in &ids {
                d.update(*id, |l| {
                    let Some(i) = l.effects.iter().position(|e| e.kind == kind) else { return };
                    let mut prop = l.effects[i].colors.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(c));
                    prop.set_at_local(c, t, src);
                    l.effects[i].colors.insert(key.to_string(), prop);
                });
            }
        });
    }

    /// Opacity (0...1) of color `key` on every selected layer at the playhead; `None` when it differs. The colors may differ.
    pub fn color_alpha(&self, session: &EditorSession, kind: &str, key: &str) -> Option<f64> {
        let t = self.local_time(session);
        common(self.target_layers(session).iter().map(|l| layer_color(l, kind, key, t).map(|c| c.alpha)).collect(), 0.0)
    }

    /// Sets the opacity of color `key` on every selected layer; each layer keeps its own color.
    pub fn set_color_alpha(&mut self, session: &mut EditorSession, kind: &str, key: &str, alpha: f64) {
        let ids = self.target_ids(session);
        if ids.is_empty() {
            return;
        }
        let t = self.local_time(session);
        let a = alpha.clamp(0.0, 1.0);
        let merge = format!("props:alpha:{kind}.{key}:{}", merge_ids(&ids));
        self.edit_with_ids(session, "Opacity", Some(&merge), |d, src| {
            for id in &ids {
                d.update(*id, |l| {
                    let Some(i) = l.effects.iter().position(|e| e.kind == kind) else { return };
                    let Some(mut c) = layer_color(l, kind, key, t) else { return };
                    c.alpha = a;
                    let mut prop = l.effects[i].colors.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(c));
                    prop.set_at_local(c, t, src);
                    l.effects[i].colors.insert(key.to_string(), prop);
                });
            }
        });
    }

    // MARK: Shape kind and Shadow

    /// Kind of the selected shape layers; `None` when they differ or one is not a shape.
    pub fn shape_kind(&self, session: &EditorSession) -> Option<ShapeKind> {
        let ks: Vec<Option<ShapeKind>> = self
            .target_layers(session)
            .iter()
            .map(|l| match &l.content {
                GraphicsContent::Shape { kind } => Some(*kind),
                _ => None,
            })
            .collect();
        let first = (*ks.first()?)?;
        ks.iter().all(|k| *k == Some(first)).then_some(first)
    }

    /// Changes every selected shape layer to `k` (size and look stay); a line gets its outline switched on.
    pub fn set_shape_kind(&mut self, session: &mut EditorSession, k: ShapeKind) {
        let ids: Vec<Id> = self
            .target_layers(session)
            .iter()
            .filter(|l| matches!(l.content, GraphicsContent::Shape { .. }))
            .map(|l| l.id)
            .collect();
        if ids.is_empty() {
            return;
        }
        let t = self.local_time(session);
        self.edit_with_ids(session, "Shape Kind", None, |d, src| {
            for id in &ids {
                d.update(*id, |l| {
                    l.content = GraphicsContent::Shape { kind: k };
                    let Some(i) = l.effects.iter().position(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND) else {
                        return;
                    };
                    if k != ShapeKind::Line || l.effects[i].scalar(ClipEffect::SHAPE_STROKE_KEY, t) >= 0.5 {
                        return;
                    }
                    let mut on = l.effects[i]
                        .parameters
                        .get(ClipEffect::SHAPE_STROKE_KEY)
                        .cloned()
                        .unwrap_or_else(|| AnimatedProperty::new(1.0));
                    on.set_at_local(1.0, t, src);
                    l.effects[i].parameters.insert(ClipEffect::SHAPE_STROKE_KEY.to_string(), on);
                });
            }
        });
    }

    /// Shadow row: the first drop shadow of each selected layer. `Some(true)` = on in every layer, `Some(false)` = in none,
    /// `None` = mixed.
    pub fn shadow_state(&self, session: &EditorSession) -> Option<bool> {
        let on: Vec<bool> = self
            .target_layers(session)
            .iter()
            .map(|l| l.effects.iter().find(|e| e.kind == ClipEffect::DROP_SHADOW_KIND).is_some_and(|e| e.enabled))
            .collect();
        let Some(first) = on.first().copied() else { return Some(false) };
        on.iter().all(|o| *o == first).then_some(first)
    }

    /// Shadow on: the first drop shadow is switched on, a layer without one gets one. Off: switched off, keeping settings
    /// and keys. Further drop shadows are never touched.
    pub fn set_shadow(&mut self, session: &mut EditorSession, on: bool) {
        let ids = self.target_ids(session);
        if ids.is_empty() {
            return;
        }
        self.edit_with_ids(session, if on { "Shadow On" } else { "Shadow Off" }, None, |d, src| {
            for id in &ids {
                d.update(*id, |l| {
                    if let Some(i) = l.effects.iter().position(|e| e.kind == ClipEffect::DROP_SHADOW_KIND) {
                        l.effects[i].enabled = on;
                    } else if on && let Some(e) = ClipEffect::make(src.next_id(), ClipEffect::DROP_SHADOW_KIND) {
                        l.effects.push(e);
                    }
                });
            }
        });
    }

    // MARK: Layer effects (of the single selected layer)

    pub fn remove_effect(&mut self, session: &mut EditorSession, effect: Id) {
        let Some(id) = self.selected_layer(session).map(|l| l.id) else { return };
        self.edit(session, "Remove Effect", None, |d| {
            d.update(id, |l| l.effects.retain(|e| !(e.id == effect && !EffectCatalog::is_generator_owned(&e.kind))));
        });
    }

    pub fn set_effect_enabled(&mut self, session: &mut EditorSession, effect: Id, on: bool) {
        let Some(id) = self.selected_layer(session).map(|l| l.id) else { return };
        self.edit(session, if on { "Enable Effect" } else { "Disable Effect" }, None, |d| {
            d.update(id, |l| {
                if let Some(e) = l.effects.iter_mut().find(|e| e.id == effect) {
                    e.enabled = on;
                }
            });
        });
    }

    pub fn set_effect_value(&mut self, session: &mut EditorSession, effect: Id, key: &str, v: f64) {
        self.set_effect(session, "Effect", key, effect, |e, t, src| {
            let mut prop = e.parameters.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(v));
            prop.set_at_local(v, t, src);
            e.parameters.insert(key.to_string(), prop);
        });
    }

    pub fn set_effect_color(&mut self, session: &mut EditorSession, effect: Id, key: &str, c: EffectColor) {
        self.set_effect(session, "Effect Color", key, effect, |e, t, src| {
            let mut prop = e.colors.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(c));
            prop.set_at_local(c, t, src);
            e.colors.insert(key.to_string(), prop);
        });
    }

    fn set_effect(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        key: &str,
        effect: Id,
        body: impl FnOnce(&mut ClipEffect, Time, &mut dyn IdSource),
    ) {
        let Some(id) = self.selected_layer(session).map(|l| l.id) else { return };
        let t = self.local_time(session);
        let merge = format!("{id}:{effect}:{key}");
        self.edit_with_ids(session, name, Some(&merge), |d, src| {
            d.update(id, |l| {
                if let Some(e) = l.effects.iter_mut().find(|e| e.id == effect) {
                    body(e, t, src);
                }
            });
        });
    }

    /// The selected text item's string.
    pub fn text_string(&self, session: &EditorSession) -> Option<String> {
        let l = self.selected_layer(session)?;
        let GraphicsContent::Text { generator } = &l.content else { return None };
        TextGenerator::decode(generator).ok().map(|d| d.0.text)
    }
}

/// The context of the Controls > Graphic rows: the editor and the session it edits.
pub struct GraphicsItemHost {
    pub editor: GraphicsEditor,
    /// The host's session while a call runs inside [`GraphicsItemHost::with_session`]; a stand-in otherwise.
    pub session: EditorSession,
}

impl GraphicsItemHost {
    /// Runs `f` with the host's `session` as this context's session (the rows read and write through it).
    pub fn with_session<R>(&mut self, session: &mut EditorSession, f: impl FnOnce(&mut GraphicsItemHost) -> R) -> R {
        std::mem::swap(&mut self.session, session);
        let r = f(self);
        std::mem::swap(&mut self.session, session);
        r
    }

    fn shape_color_key(key: &str) -> (&'static str, &str) {
        (ClipEffect::SHAPE_EFFECT_KIND, key)
    }
}

impl ItemRowsHost for GraphicsItemHost {
    fn target_layers(&self) -> Vec<GraphicsLayer> {
        let s = &self.session;
        self.editor.target_layers(s).into_iter().cloned().collect()
    }
    fn text(&self) -> Option<String> {
        self.editor.text_string(&self.session)
    }
    fn begin_gesture(&mut self) {
        self.editor.begin_gesture(&mut self.session);
    }
    fn update_text(&mut self, text: &str) {
        let t = text.to_string();
        self.editor.update_text(&mut self.session, "Edit Text", None, move |tpl| tpl.text = t);
    }
    fn is_keyed(&self, key: &str) -> bool {
        self.editor.is_keyed(&self.session, &Property::shape(key))
    }
    fn value(&self, key: &str) -> Option<f64> {
        self.editor.shape_value(&self.session, key)
    }
    fn set_value(&mut self, key: &str, v: f64) {
        self.editor.set_shape_value(&mut self.session, key, v);
    }
    fn shape_value(&self, key: &str) -> Option<f64> {
        self.editor.shape_value(&self.session, key)
    }
    fn set_shape_value(&mut self, key: &str, v: f64) {
        self.editor.set_shape_value(&mut self.session, key, v);
    }
    fn color(&self, key: &str) -> Option<EffectColor> {
        let (kind, key) = Self::shape_color_key(key);
        self.editor.color(&self.session, kind, key)
    }
    fn set_color(&mut self, key: &str, c: EffectColor) {
        let (kind, key) = Self::shape_color_key(key);
        self.editor.set_color(&mut self.session, kind, key, c);
    }
    fn color_alpha(&self, key: &str) -> Option<f64> {
        let (kind, key) = Self::shape_color_key(key);
        self.editor.color_alpha(&self.session, kind, key)
    }
    fn set_color_alpha(&mut self, key: &str, a: f64) {
        let (kind, key) = Self::shape_color_key(key);
        self.editor.set_color_alpha(&mut self.session, kind, key, a);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics::editor_tests::with_three_shapes;

    fn width() -> Property {
        Property::shape("shapeWidth")
    }

    #[test]
    fn mixed_values_read_none_and_a_write_reaches_every_layer() {
        let (mut s, mut e) = with_three_shapes();
        e.select_all_layers(&mut s);
        e.set_value(&mut s, &Property::Rotation, 0, 15.0);
        assert_eq!(e.value(&s, &Property::Rotation, 0), Some(15.0));
        let first = e.target_layers(&s)[0].id;
        e.select(&mut s, BTreeSet::from([first]));
        e.set_value(&mut s, &Property::Rotation, 0, 30.0);
        e.select_all_layers(&mut s);
        assert_eq!(e.value(&s, &Property::Rotation, 0), None);
    }

    #[test]
    fn opacity_is_clamped_and_a_gesture_is_one_undo_step() {
        let (mut s, mut e) = with_three_shapes();
        e.begin_gesture(&mut s);
        e.set_opacity(&mut s, 2.0);
        e.set_opacity(&mut s, 0.5);
        assert_eq!(e.value(&s, &Property::Opacity, 0), Some(0.5));
        s.undo();
        assert_eq!(e.value(&s, &Property::Opacity, 0), Some(1.0));
    }

    #[test]
    fn stopwatch_adds_keys_and_the_key_button_toggles_one_at_the_playhead() {
        let (mut s, mut e) = with_three_shapes();
        let p = Property::Opacity;
        assert!(!e.is_keyed(&s, &p));
        e.toggle_keyframing(&mut s, &p);
        assert!(e.is_keyed(&s, &p));
        assert_eq!(e.key_count(&s, &p), 1);
        assert!(e.is_key_at_playhead(&s, &p));
        // Removing the only key is refused; the stopwatch turns animation off.
        e.toggle_key_at_playhead(&mut s, &p);
        assert_eq!(e.key_count(&s, &p), 1);
        e.toggle_keyframing(&mut s, &p);
        assert!(!e.is_keyed(&s, &p));
        assert_eq!(e.key_count(&s, &p), 0);
    }

    #[test]
    fn key_navigation_and_ease_names_follow_the_playhead() {
        let (mut s, mut e) = with_three_shapes();
        let p = Property::Rotation;
        e.toggle_keyframing(&mut s, &p);
        let start = e.local_time(&s);
        e.seek_local(&mut s, start + Time::new(1, 1));
        assert!(!e.is_key_at_playhead(&s, &p));
        assert_eq!(e.previous_key_time(&s, &p), Some(start));
        e.toggle_key_at_playhead(&mut s, &p);
        assert_eq!(e.key_count(&s, &p), 2);
        assert!(e.key_ease_name(&s, &p).is_some());
        e.set_key_ease(&mut s, &p, &EasingCurve::hold(), false);
        assert_eq!(e.key_ease_name(&s, &p).as_deref(), Some(EasingCurve::hold().display_name()));
        let st = e.keyframe_state(&s, &p);
        assert!(st.shows_navigation && st.key_is_on && st.can_go_previous);
    }

    #[test]
    fn shape_values_colors_and_alpha_round_trip() {
        let (mut s, mut e) = with_three_shapes();
        let kind = ClipEffect::SHAPE_EFFECT_KIND;
        assert!(e.shape_value(&s, "shapeWidth").is_some());
        e.set_shape_value(&mut s, "shapeWidth", 321.0);
        assert_eq!(e.shape_value(&s, "shapeWidth"), Some(321.0));
        let red = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
        e.set_color(&mut s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY, red);
        assert_eq!(e.color(&s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY), Some(red));
        e.set_color_alpha(&mut s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY, 4.0);
        assert_eq!(e.color_alpha(&s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY), Some(1.0));
        e.set_color_alpha(&mut s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY, 0.25);
        assert_eq!(e.color(&s, kind, ClipEffect::SHAPE_FILL_COLOR_KEY).map(|c| (c.red, c.alpha)), Some((1.0, 0.25)));
        assert!(width().title().len() > 1);
    }

    #[test]
    fn shape_kind_changes_and_a_line_gets_its_outline() {
        let (mut s, mut e) = with_three_shapes();
        assert_eq!(e.shape_kind(&s), Some(ShapeKind::Line));
        e.set_shape_kind(&mut s, ShapeKind::Ellipse);
        assert_eq!(e.shape_kind(&s), Some(ShapeKind::Ellipse));
        e.set_shape_value(&mut s, ClipEffect::SHAPE_STROKE_KEY, 0.0);
        e.set_shape_kind(&mut s, ShapeKind::Line);
        assert_eq!(e.shape_value(&s, ClipEffect::SHAPE_STROKE_KEY), Some(1.0));
    }

    #[test]
    fn shadow_is_added_and_switched() {
        let (mut s, mut e) = with_three_shapes();
        assert_eq!(e.shadow_state(&s), Some(false));
        e.set_shadow(&mut s, true);
        assert_eq!(e.shadow_state(&s), Some(true));
        e.set_shadow(&mut s, false);
        assert_eq!(e.shadow_state(&s), Some(false));
        assert_eq!(
            e.primary_layer(&s).map(|l| l.effects.iter().filter(|x| x.kind == ClipEffect::DROP_SHADOW_KIND).count()),
            Some(1)
        );
    }

    #[test]
    fn the_host_drives_the_rows_through_the_trait() {
        let (s, e) = with_three_shapes();
        let mut h = GraphicsItemHost { editor: e, session: s };
        assert_eq!(ItemRowsHost::target_layers(&h).len(), 1);
        h.begin_gesture();
        ItemRowsHost::set_value(&mut h, "shapeWidth", 77.0);
        assert_eq!(ItemRowsHost::value(&h, "shapeWidth"), Some(77.0));
        assert!(!ItemRowsHost::is_keyed(&h, "shapeWidth"));
        ItemRowsHost::set_color_alpha(&mut h, ClipEffect::SHAPE_FILL_COLOR_KEY, 0.5);
        assert_eq!(ItemRowsHost::color_alpha(&h, ClipEffect::SHAPE_FILL_COLOR_KEY), Some(0.5));
        assert_eq!(ItemRowsHost::text(&h), None);
    }
}
