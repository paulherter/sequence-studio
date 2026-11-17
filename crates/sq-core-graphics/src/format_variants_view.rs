// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FormatVariants+View.swift, and the logic of FormatVariants.swift (the saved types `FormatVariant`, `VariantOverride`,
// `VariantOverrides`, `ConformMode` live in `sq-core-model`; no other module of the core split owned that logic).
//
// W5.1: working in a format variant. Edits made on a clip as the variant shows it land in that variant's override (motion,
// overridden effect parameters, an overridden generator) or in the shared base (everything else); playback and export
// evaluate a materialized copy of the sequence in the variant (`variant_view`), so no clip is resolved per frame.
//
// Wiring: `LayerHooks { variant_format: &variant_format, resolve_variant: &resolve_variant, .. }`.

use sq_core_effects::sequence_conform::{ConformMode as EffectsConformMode, SequenceConform};
use sq_core_model::ConformMode;
use sq_core_model::{
    AnimatedProperty, Clip, EditError, FormatVariant, Project, SequenceFormat, Timeline, TrackKind, VariantOverride,
    VariantOverrides,
};
use sq_core_time::{Id, IdSource, KeyframeValue, Time};
use std::collections::{BTreeMap, BTreeSet};

/// Largest frame side a variant may have (`SequenceFormatPresets.maxDimension`).
// shortcut: copy of the private limit in sq-core-model's format_variants.rs, upgrade when the model exports it.
const MAX_DIMENSION: i64 = 16_384;

/// Why a variant edit was refused. Swift throws `VariantError` or `EditError`; both are cases here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VariantError {
    /// No variant with that id.
    VariantNotFound,
    /// An edit error (`InvalidFormat`, `ClipNotFound`, `TimelineNotFound`, `TrackLocked`, `Collision`).
    Edit(EditError),
}

impl std::fmt::Display for VariantError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for VariantError {}

impl From<EditError> for VariantError {
    fn from(e: EditError) -> VariantError {
        VariantError::Edit(e)
    }
}

/// The transform properties a variant can override (Effect Controls > Motion, without Opacity: opacity is shared).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum VariantProperty {
    /// Position.
    Position,
    /// Scale.
    Scale,
    /// Rotation.
    Rotation,
    /// Anchor point.
    Anchor,
    /// Perspective tilt (both axes together).
    Tilt,
}

impl VariantProperty {
    /// Every property.
    pub const ALL: [VariantProperty; 5] = [
        VariantProperty::Position,
        VariantProperty::Scale,
        VariantProperty::Rotation,
        VariantProperty::Anchor,
        VariantProperty::Tilt,
    ];
}

/// The canvas of a variant for a sequence of format `base`. Has the signature of `LayerHooks::variant_format`.
pub fn variant_format(v: &FormatVariant, base: &SequenceFormat) -> SequenceFormat {
    let mut f = base.clone();
    f.width = v.width;
    f.height = v.height;
    f
}

/// The clip as `v` renders it. Has the signature of `LayerHooks::resolve_variant`.
pub fn resolve_variant(c: &Clip, v: &FormatVariant, base: &SequenceFormat, conforms_picture: bool) -> Clip {
    c.resolved(v, base, conforms_picture)
}

/// Variant size check.
pub trait FormatVariantExt {
    /// Both sides in 1...16384.
    fn valid_size(w: i64, h: i64) -> bool;
    /// The canvas of this variant for a sequence of format `base`.
    fn format(&self, base: &SequenceFormat) -> SequenceFormat;
}

impl FormatVariantExt for FormatVariant {
    fn valid_size(w: i64, h: i64) -> bool {
        (1..=MAX_DIMENSION).contains(&w) && (1..=MAX_DIMENSION).contains(&h)
    }

    fn format(&self, base: &SequenceFormat) -> SequenceFormat {
        variant_format(self, base)
    }
}

/// Queries and resets of one override.
pub trait VariantOverrideExt {
    /// The property is overridden.
    fn has(&self, p: VariantProperty) -> bool;
    /// Back to automatic.
    fn reset(&mut self, p: VariantProperty);
    /// Animated properties replaced by their value at clip-local `t` (an inserted frame hold is a pause in time).
    fn frozen(&self, t: Time) -> VariantOverride;
}

impl VariantOverrideExt for VariantOverride {
    fn has(&self, p: VariantProperty) -> bool {
        match p {
            VariantProperty::Position => self.position.is_some(),
            VariantProperty::Scale => self.scale.is_some(),
            VariantProperty::Rotation => self.rotation.is_some(),
            VariantProperty::Anchor => self.anchor.is_some(),
            VariantProperty::Tilt => self.tilt_x.is_some() || self.tilt_y.is_some(),
        }
    }

    fn reset(&mut self, p: VariantProperty) {
        match p {
            VariantProperty::Position => self.position = None,
            VariantProperty::Scale => self.scale = None,
            VariantProperty::Rotation => self.rotation = None,
            VariantProperty::Anchor => self.anchor = None,
            VariantProperty::Tilt => {
                self.tilt_x = None;
                self.tilt_y = None;
            }
        }
    }

    fn frozen(&self, t: Time) -> VariantOverride {
        fn fz<V: KeyframeValue>(p: &Option<AnimatedProperty<V>>, t: Time) -> Option<AnimatedProperty<V>> {
            p.as_ref().map(|p| AnimatedProperty::new(p.value_at_local(t)))
        }
        VariantOverride {
            position: fz(&self.position, t),
            scale: fz(&self.scale, t),
            rotation: fz(&self.rotation, t),
            anchor: fz(&self.anchor, t),
            tilt_x: fz(&self.tilt_x, t),
            tilt_y: fz(&self.tilt_y, t),
            effect_parameters: self
                .effect_parameters
                .iter()
                .map(|(id, ps)| {
                    (*id, ps.iter().map(|(k, p)| (k.clone(), AnimatedProperty::new(p.value_at_local(t)))).collect())
                })
                .collect(),
            ..self.clone()
        }
    }
}

/// A clip's per-variant overrides and its resolution.
pub trait ClipVariantExt {
    /// Sparse per-variant overrides.
    fn variant_overrides(&self) -> BTreeMap<Id, VariantOverride>;
    /// Sets the overrides. Drops empty overrides; an empty map stores nothing.
    fn set_variant_overrides(&mut self, overrides: BTreeMap<Id, VariantOverride>);
    /// This clip as it renders in `variant` of a sequence of format `base`: the base values conformed into the variant's size,
    /// then the clip's own override for that variant on top. Audio clips are returned unchanged. `conforms_picture: false`
    /// skips the automatic picture conform (a nested clip whose inner sequence is itself rendered in the same variant
    /// already has the variant's size).
    fn resolved(&self, variant: &FormatVariant, base: &SequenceFormat, conforms_picture: bool) -> Clip;
}

impl ClipVariantExt for Clip {
    fn variant_overrides(&self) -> BTreeMap<Id, VariantOverride> {
        self.variant_store.as_ref().map(|s| s.items.clone()).unwrap_or_default()
    }

    fn set_variant_overrides(&mut self, overrides: BTreeMap<Id, VariantOverride>) {
        let kept: BTreeMap<Id, VariantOverride> = overrides.into_iter().filter(|(_, o)| !o.is_empty()).collect();
        self.variant_store = if kept.is_empty() { None } else { Some(VariantOverrides { items: kept }) };
    }

    fn resolved(&self, variant: &FormatVariant, base: &SequenceFormat, conforms_picture: bool) -> Clip {
        if self.kind != TrackKind::Video {
            return self.clone();
        }
        let target = variant.format(base);
        let o = self.variant_store.as_ref().and_then(|s| s.items.get(&variant.id));
        let mut n = self.clone();
        if let Some(g) = &self.generator {
            if g.kind == crate::graphics_make_graphic::TEXT_KIND {
                n = SequenceConform::conform_text(self, base, &target, None);
            }
        } else if conforms_picture {
            // shortcut: sq-core-effects has its own `ConformMode` next to the model's; mapped here until effects re-exports the
            // model's.
            let mode = match o.and_then(|o| o.conform).unwrap_or(variant.conform) {
                ConformMode::Fit => EffectsConformMode::Fit,
                ConformMode::Fill => EffectsConformMode::Fill,
            };
            n = SequenceConform::conform_picture(self, SequenceConform::frame_factor(base, &target, mode));
        }
        let Some(o) = o else { return n };
        if let Some(p) = &o.position {
            n.animation.position = p.clone();
        }
        if let Some(p) = &o.scale {
            n.animation.scale = p.clone();
        }
        if let Some(p) = &o.rotation {
            n.animation.rotation = p.clone();
        }
        if let Some(p) = &o.anchor {
            n.animation.anchor = p.clone();
        }
        if let Some(p) = &o.tilt_x {
            n.animation.tilt_x = p.clone();
        }
        if let Some(p) = &o.tilt_y {
            n.animation.tilt_y = p.clone();
        }
        if let Some(g) = o.generator.as_ref().filter(|g| Some(&g.kind) == self.generator.as_ref().map(|s| &s.kind)) {
            n.generator = Some(g.clone());
        }
        if !o.effect_parameters.is_empty() {
            for e in &mut n.effects {
                if let Some(ps) = o.effect_parameters.get(&e.id) {
                    for (k, v) in ps {
                        e.parameters.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        n
    }
}

/// Swift assigns an optional into a dictionary: `None` removes the key.
fn set_opt<V: Clone>(map: &mut BTreeMap<String, V>, key: &str, v: Option<&V>) {
    match v {
        Some(v) => map.insert(key.to_string(), v.clone()),
        None => map.remove(key),
    };
}

/// Replaces a clip of the timeline in place (Swift `Timeline.replaceClip`, Timeline+Replace.swift).
///
/// shortcut: private copy until the edit crate ports Timeline+Replace; then call its `replace_clip`.
fn replace_clip(tl: &mut Timeline, clip: Clip) -> Result<(), EditError> {
    let ti = tl.tracks.iter().position(|t| t.clip(clip.id).is_some()).ok_or(EditError::ClipNotFound)?;
    if tl.tracks[ti].is_locked {
        return Err(EditError::TrackLocked);
    }
    let old = tl.tracks[ti].clip(clip.id).ok_or(EditError::ClipNotFound)?;
    if old.start != clip.start || old.source != clip.source || old.speed != clip.speed || old.reversed != clip.reversed
    {
        return Err(EditError::Collision);
    }
    tl.tracks[ti].replace(clip);
    Ok(())
}

/// Format variants of a sequence (Swift `extension Timeline` in FormatVariants.swift and FormatVariants+View.swift).
pub trait TimelineVariantsExt {
    /// The variant with that id; `None` for no id or an unknown one.
    fn variant(&self, id: Option<Id>) -> Option<&FormatVariant>;
    /// The canvas for `variant`; the sequence's own format for `None` or an unknown id.
    fn format_for(&self, variant: Option<Id>) -> SequenceFormat;
    /// `clip` as it renders in `variant`; unchanged for `None` or an unknown id. Does not know nested sequences: for display
    /// and edits use `ProjectVariantsExt::displayed_clip`, which skips the conform where render does.
    fn resolved_clip(&self, clip: &Clip, variant: Option<Id>) -> Clip;
    /// The clip's override for `variant`.
    fn override_of(&self, clip: Id, variant: Id) -> Option<VariantOverride>;
    /// Adds a variant. `InvalidFormat` for a side outside 1...16384.
    fn add_variant(
        &mut self,
        name: &str,
        width: i64,
        height: i64,
        conform: ConformMode,
        ids: &mut dyn IdSource,
    ) -> Result<Id, VariantError>;
    /// Removes the variant and every clip's override for it.
    fn remove_variant(&mut self, id: Id) -> Result<(), VariantError>;
    /// Renames a variant.
    fn rename_variant(&mut self, id: Id, name: &str) -> Result<(), VariantError>;
    /// Overrides keep their values (they are in sequence pixels of the variant); the automatic part follows the new size.
    fn set_variant_size(&mut self, id: Id, width: i64, height: i64) -> Result<(), VariantError>;
    /// Sets the variant's conform mode.
    fn set_variant_conform(&mut self, id: Id, mode: ConformMode) -> Result<(), VariantError>;
    /// Replaces a clip's override for `variant` (`None` or empty = remove it).
    fn set_override(&mut self, o: Option<VariantOverride>, clip: Id, variant: Id) -> Result<(), VariantError>;
    /// Edits a clip's override for `variant` in place, starting from an empty one when there is none. An override left empty is
    /// removed (sparse storage). One call = one value change of the timeline (one undo step in a commit).
    fn edit_override(
        &mut self,
        clip: Id,
        variant: Id,
        body: impl FnOnce(&mut VariantOverride) -> Result<(), VariantError>,
    ) -> Result<(), VariantError>;
    /// Copies the current automatic values of `properties` into the clip's override (keys included), so the variant can be
    /// edited without anything moving. Properties already overridden keep their values.
    fn detach(&mut self, properties: &BTreeSet<VariantProperty>, clip: Id, variant: Id) -> Result<(), VariantError>;
    /// Back to automatic: one property, or the whole override (`None`).
    fn reset_override(&mut self, property: Option<VariantProperty>, clip: Id, variant: Id) -> Result<(), VariantError>;
    /// Drops overrides for variants this sequence does not have and effect overrides for effects a clip no longer has (e.g.
    /// after pasting from another sequence). True when anything changed.
    fn prune_variant_overrides(&mut self) -> bool;
    /// Applies `edited`, a clip as it is displayed in `variant` (`resolved_clip` plus the user's change), to the stored clip:
    /// Position / Scale / Rotation / Anchor Point that differ from the displayed values are written into the variant's
    /// override (only those, the rest stays automatic); effect parameters and the generator go to the override where it
    /// already overrides them, else to the base clip; every other change is shared. Overrides of effects the clip no longer
    /// has are dropped. `None`, an unknown variant or an audio clip: a plain `replace_clip`. `conforms_picture`:
    /// `ProjectVariantsExt::conforms_picture` for the clip (false for a nested clip whose inner sequence renders in the same
    /// variant), so the displayed values compared against are the ones render shows.
    fn apply_displayed_edit(
        &mut self,
        edited: &Clip,
        variant: Option<Id>,
        conforms_picture: bool,
    ) -> Result<(), VariantError>;
    /// This sequence evaluated in `v` (format, every video clip resolved, no variants left); `inner_has_variant` says whether
    /// a nested clip's inner sequence is rendered in the same variant (its clip is then not conformed).
    fn materialized(&self, v: &FormatVariant, inner_has_variant: &dyn Fn(Id) -> bool) -> Timeline;
}

impl TimelineVariantsExt for Timeline {
    fn variant(&self, id: Option<Id>) -> Option<&FormatVariant> {
        let id = id?;
        self.variants.iter().find(|v| v.id == id)
    }

    fn format_for(&self, variant: Option<Id>) -> SequenceFormat {
        self.variant(variant).map_or_else(|| self.format.clone(), |v| v.format(&self.format))
    }

    fn resolved_clip(&self, clip: &Clip, variant: Option<Id>) -> Clip {
        match self.variant(variant) {
            Some(v) => clip.resolved(v, &self.format, true),
            None => clip.clone(),
        }
    }

    fn override_of(&self, clip: Id, variant: Id) -> Option<VariantOverride> {
        self.find(clip)?.clip.variant_overrides().remove(&variant)
    }

    fn add_variant(
        &mut self,
        name: &str,
        width: i64,
        height: i64,
        conform: ConformMode,
        ids: &mut dyn IdSource,
    ) -> Result<Id, VariantError> {
        if !FormatVariant::valid_size(width, height) {
            return Err(EditError::InvalidFormat.into());
        }
        let v = FormatVariant { id: ids.next_id(), name: name.to_string(), width, height, conform };
        let id = v.id;
        self.variants.push(v);
        Ok(id)
    }

    fn remove_variant(&mut self, id: Id) -> Result<(), VariantError> {
        if !self.variants.iter().any(|v| v.id == id) {
            return Err(VariantError::VariantNotFound);
        }
        self.variants.retain(|v| v.id != id);
        for_each_clip(self, |c| {
            let mut all = c.variant_overrides();
            if all.remove(&id).is_none() {
                return false;
            }
            c.set_variant_overrides(all);
            true
        });
        Ok(())
    }

    fn rename_variant(&mut self, id: Id, name: &str) -> Result<(), VariantError> {
        with_variant(self, id, |v| v.name = name.to_string())
    }

    fn set_variant_size(&mut self, id: Id, width: i64, height: i64) -> Result<(), VariantError> {
        if !self.variants.iter().any(|v| v.id == id) {
            return Err(VariantError::VariantNotFound);
        }
        if !FormatVariant::valid_size(width, height) {
            return Err(EditError::InvalidFormat.into());
        }
        with_variant(self, id, |v| {
            v.width = width;
            v.height = height;
        })
    }

    fn set_variant_conform(&mut self, id: Id, mode: ConformMode) -> Result<(), VariantError> {
        with_variant(self, id, |v| v.conform = mode)
    }

    fn set_override(&mut self, o: Option<VariantOverride>, clip: Id, variant: Id) -> Result<(), VariantError> {
        self.edit_override(clip, variant, |x| {
            *x = o.unwrap_or_default();
            Ok(())
        })
    }

    fn edit_override(
        &mut self,
        clip: Id,
        variant: Id,
        body: impl FnOnce(&mut VariantOverride) -> Result<(), VariantError>,
    ) -> Result<(), VariantError> {
        if !self.variants.iter().any(|v| v.id == variant) {
            return Err(VariantError::VariantNotFound);
        }
        let m = self.find(clip).ok_or(EditError::ClipNotFound)?;
        let mut c = m.clip;
        let mut all = c.variant_overrides();
        let mut o = all.remove(&variant).unwrap_or_default();
        body(&mut o)?;
        all.insert(variant, o);
        c.set_variant_overrides(all);
        self.tracks[m.track].replace(c);
        Ok(())
    }

    fn detach(&mut self, properties: &BTreeSet<VariantProperty>, clip: Id, variant: Id) -> Result<(), VariantError> {
        let v = self.variant(Some(variant)).ok_or(VariantError::VariantNotFound)?.clone();
        let m = self.find(clip).ok_or(EditError::ClipNotFound)?;
        let r = m.clip.resolved(&v, &self.format, true);
        self.edit_override(clip, variant, |o| {
            let wanted: Vec<VariantProperty> = properties.iter().copied().filter(|p| !o.has(*p)).collect();
            for p in wanted {
                match p {
                    VariantProperty::Position => o.position = Some(r.animation.position.clone()),
                    VariantProperty::Scale => o.scale = Some(r.animation.scale.clone()),
                    VariantProperty::Rotation => o.rotation = Some(r.animation.rotation.clone()),
                    VariantProperty::Anchor => o.anchor = Some(r.animation.anchor.clone()),
                    VariantProperty::Tilt => {
                        o.tilt_x = Some(r.animation.tilt_x.clone());
                        o.tilt_y = Some(r.animation.tilt_y.clone());
                    }
                }
            }
            Ok(())
        })
    }

    fn reset_override(&mut self, property: Option<VariantProperty>, clip: Id, variant: Id) -> Result<(), VariantError> {
        self.edit_override(clip, variant, |o| {
            match property {
                Some(p) => o.reset(p),
                None => *o = VariantOverride::default(),
            }
            Ok(())
        })
    }

    fn prune_variant_overrides(&mut self) -> bool {
        let known: BTreeSet<Id> = self.variants.iter().map(|v| v.id).collect();
        let mut changed = false;
        for_each_clip(self, |c| {
            let before = c.variant_overrides();
            if before.is_empty() {
                return false;
            }
            let fx: BTreeSet<Id> = c.effects.iter().map(|e| e.id).collect();
            let mut out = BTreeMap::new();
            for (k, o) in &before {
                if !known.contains(k) {
                    continue;
                }
                let mut o = o.clone();
                o.effect_parameters.retain(|id, ps| fx.contains(id) && !ps.is_empty());
                out.insert(*k, o);
            }
            c.set_variant_overrides(out);
            if c.variant_overrides() != before {
                changed = true;
                return true;
            }
            false
        });
        changed
    }

    fn apply_displayed_edit(
        &mut self,
        edited: &Clip,
        variant: Option<Id>,
        conforms_picture: bool,
    ) -> Result<(), VariantError> {
        let found = self.variant(variant).cloned().filter(|_| edited.kind == TrackKind::Video);
        let (Some(v), Some(m)) = (found, self.find(edited.id)) else {
            return Ok(replace_clip(self, edited.clone())?);
        };
        let base = m.clip;
        let shown = base.resolved(&v, &self.format, conforms_picture);
        let mut o = base.variant_overrides().remove(&v.id).unwrap_or_default();
        let mut n = edited.clone();

        let (ea, sa, ba) = (&edited.animation, &shown.animation, &base.animation);
        if ea.position != sa.position {
            o.position = Some(ea.position.clone());
        }
        if ea.scale != sa.scale {
            o.scale = Some(ea.scale.clone());
        }
        if ea.rotation != sa.rotation {
            o.rotation = Some(ea.rotation.clone());
        }
        if ea.anchor != sa.anchor {
            o.anchor = Some(ea.anchor.clone());
        }
        if ea.tilt_x != sa.tilt_x {
            o.tilt_x = Some(ea.tilt_x.clone());
        }
        if ea.tilt_y != sa.tilt_y {
            o.tilt_y = Some(ea.tilt_y.clone());
        }
        n.animation.tilt_x = ba.tilt_x.clone();
        n.animation.tilt_y = ba.tilt_y.clone();
        n.animation.position = ba.position.clone();
        n.animation.scale = ba.scale.clone();
        n.animation.rotation = ba.rotation.clone();
        n.animation.anchor = ba.anchor.clone();

        if o.generator.as_ref().is_some_and(|g| Some(&g.kind) == base.generator.as_ref().map(|b| &b.kind)) {
            if let Some(eg) = edited.generator.as_ref().filter(|eg| Some(*eg) != shown.generator.as_ref()) {
                o.generator = Some(eg.clone());
            }
            n.generator = base.generator.clone();
        }

        for e in &mut n.effects {
            let Some(keys) = o.effect_parameters.get(&e.id).map(|ps| ps.keys().cloned().collect::<Vec<_>>()) else {
                continue;
            };
            let base_fx = base.effects.iter().find(|b| b.id == e.id);
            let shown_fx = shown.effects.iter().find(|s| s.id == e.id);
            for k in keys {
                if e.parameters.get(&k) != shown_fx.and_then(|s| s.parameters.get(&k))
                    && let Some(ps) = o.effect_parameters.get_mut(&e.id)
                {
                    set_opt(ps, &k, e.parameters.get(&k));
                }
                set_opt(&mut e.parameters, &k, base_fx.and_then(|b| b.parameters.get(&k)));
            }
        }
        let kept: BTreeSet<Id> = n.effects.iter().map(|e| e.id).collect();
        o.effect_parameters.retain(|id, ps| kept.contains(id) && !ps.is_empty());

        let mut all = base.variant_overrides();
        all.insert(v.id, o);
        n.set_variant_overrides(all);
        Ok(replace_clip(self, n)?)
    }

    fn materialized(&self, v: &FormatVariant, inner_has_variant: &dyn Fn(Id) -> bool) -> Timeline {
        let mut out = self.clone();
        out.format = v.format(&self.format);
        out.variants = Vec::new();
        for t in out.tracks.iter_mut().filter(|t| t.kind == TrackKind::Video) {
            t.map_clips_keeping_timing(|c| {
                let inner = c.sequence.is_some_and(inner_has_variant);
                let mut r = c.resolved(v, &self.format, !inner);
                r.set_variant_overrides(BTreeMap::new());
                r
            });
        }
        out
    }
}

fn with_variant(tl: &mut Timeline, id: Id, body: impl FnOnce(&mut FormatVariant)) -> Result<(), VariantError> {
    let v = tl.variants.iter_mut().find(|v| v.id == id).ok_or(VariantError::VariantNotFound)?;
    body(v);
    Ok(())
}

/// Runs `body` on every clip; replaces the clip when it returns true.
fn for_each_clip(tl: &mut Timeline, mut body: impl FnMut(&mut Clip) -> bool) {
    for track in &mut tl.tracks {
        for c in track.clips().to_vec() {
            let mut n = c;
            if body(&mut n) {
                track.replace(n);
            }
        }
    }
}

/// The materialized sequences of a variant: the top sequence and every sequence reachable from it.
#[derive(Clone, Debug, PartialEq)]
pub struct VariantView {
    /// The sequence in the variant.
    pub timeline: Timeline,
    /// Every sequence reachable by nesting, by id (the ones that share the variant materialized).
    pub sequences: BTreeMap<Id, Timeline>,
}

/// Format variants of a project.
pub trait ProjectVariantsExt {
    /// Runs `body` on one timeline in place (for value edits such as variants inside one `History.commit`).
    fn with_timeline<R>(&mut self, id: Id, body: impl FnOnce(&mut Timeline) -> R) -> Result<R, EditError>;
    /// `Timeline::prune_variant_overrides` on every timeline. True when anything changed.
    fn prune_variant_overrides(&mut self) -> bool;
    /// What the Program monitor and export evaluate for sequence `id` in `variant`: the sequence materialized in the variant
    /// and every sequence reachable from it by nesting. Inner sequences that have a variant with the same id are
    /// materialized in theirs (followed only through such sequences, like `video_layers` with a variant); the others stay
    /// as they are. `None` variant or an unknown id: the sequence itself. `None` for an unknown sequence. Edge case: a
    /// sequence reachable both through a chain that has the variant and one that has not is materialized.
    fn variant_view(&self, id: Id, variant: Option<Id>) -> Option<VariantView>;
    /// Whether `clip` gets the automatic picture conform in `variant`: not for a nested clip whose inner sequence has a
    /// variant with the same id (it is rendered in that variant, already at its size). The one rule evaluation,
    /// `variant_view`, the display and the edit path share.
    fn conforms_picture(&self, clip: &Clip, variant: Option<Id>) -> bool;
    /// `clip` (of `timeline`) as `variant` shows it, exactly as render resolves it; unchanged for `None` or an unknown id.
    fn displayed_clip(&self, clip: &Clip, timeline: &Timeline, variant: Option<Id>) -> Clip;
    /// Picture size of `clip` as rendered in `variant`: a nested clip whose inner sequence has that variant shows the inner
    /// variant's canvas; otherwise `Project::picture_size`.
    fn picture_size_in(&self, clip: &Clip, variant: Option<Id>) -> Option<(i64, i64)>;
    /// The variant the Program monitor shows for sequence `id`; `None` = the sequence's own format (also when the stored
    /// variant no longer exists).
    fn active_variant(&self, id: Id) -> Option<Id>;
}

impl ProjectVariantsExt for Project {
    fn with_timeline<R>(&mut self, id: Id, body: impl FnOnce(&mut Timeline) -> R) -> Result<R, EditError> {
        let t = self.timelines.iter_mut().find(|t| t.id == id).ok_or(EditError::TimelineNotFound)?;
        Ok(body(t))
    }

    fn prune_variant_overrides(&mut self) -> bool {
        let mut changed = false;
        for t in &mut self.timelines {
            if t.prune_variant_overrides() {
                changed = true;
            }
        }
        changed
    }

    fn variant_view(&self, id: Id, variant: Option<Id>) -> Option<VariantView> {
        let t = self.timeline(id)?;
        let mut sequences: BTreeMap<Id, Timeline> = BTreeMap::new();
        for s in self.reachable_sequences(id) {
            if let Some(x) = self.timeline(s) {
                sequences.insert(s, x.clone());
            }
        }
        let (Some(vid), Some(v)) = (variant, t.variant(variant)) else {
            return Some(VariantView { timeline: t.clone(), sequences });
        };
        // Asks the stored project, never the materialized copies (variants = []), so a sequence reachable two ways is not
        // conformed a second time.
        let has = |s: Id| self.timeline(s).is_some_and(|x| x.variant(Some(vid)).is_some());
        let top = t.materialized(v, &has);
        let mut done = BTreeSet::from([id]);
        let mut queue = vec![t.clone()];
        while let Some(s) = queue.pop() {
            let inners: BTreeSet<Id> = s
                .tracks
                .iter()
                .filter(|t| t.kind == TrackKind::Video)
                .flat_map(|t| t.clips())
                .filter_map(|c| c.sequence)
                .collect();
            for inner in inners {
                if done.contains(&inner) {
                    continue;
                }
                let Some(x) = sequences.get(&inner).cloned() else { continue };
                let Some(xv) = x.variant(Some(vid)).cloned() else { continue };
                done.insert(inner);
                sequences.insert(inner, x.materialized(&xv, &has));
                queue.push(x);
            }
        }
        Some(VariantView { timeline: top, sequences })
    }

    fn conforms_picture(&self, clip: &Clip, variant: Option<Id>) -> bool {
        let (Some(v), Some(s)) = (variant, clip.sequence) else { return true };
        self.timeline(s).is_none_or(|t| t.variant(Some(v)).is_none())
    }

    fn displayed_clip(&self, clip: &Clip, timeline: &Timeline, variant: Option<Id>) -> Clip {
        match timeline.variant(variant) {
            Some(v) => clip.resolved(v, &timeline.format, self.conforms_picture(clip, Some(v.id))),
            None => clip.clone(),
        }
    }

    fn picture_size_in(&self, clip: &Clip, variant: Option<Id>) -> Option<(i64, i64)> {
        if let (Some(s), Some(v)) = (clip.sequence, variant)
            && let Some((inner, iv)) = self.timeline(s).and_then(|t| t.variant(Some(v)).map(|iv| (t, iv)))
        {
            let f = iv.format(&inner.format);
            return Some((f.display_width(), f.height));
        }
        self.picture_size(clip)
    }

    fn active_variant(&self, id: Id) -> Option<Id> {
        let v = *self.active_variants.get(&id)?;
        self.timeline(id)?.variant(Some(v)).map(|_| v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::s;
    use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation as _};
    use sq_core_model::{GeneratorRef, Track};
    use sq_core_time::{Keyframe, SequentialIds, TimeRange, Vec2};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn base() -> SequenceFormat {
        SequenceFormat::new(fd())
    }

    fn v(x: f64, y: f64) -> Vec2 {
        Vec2::new(x, y)
    }

    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

    /// A body for `edit_override` that cannot fail.
    fn ok(f: impl FnOnce(&mut VariantOverride)) -> impl FnOnce(&mut VariantOverride) -> Result<(), VariantError> {
        move |o| {
            f(o);
            Ok(())
        }
    }

    fn fresh() -> Id {
        Id::from_u128(u128::from(NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)) + 1000)
    }

    fn picture(start: Time, len: Time, pos: Vec2, scale: Vec2) -> Clip {
        let mut c = Clip::new(fresh(), "v", fresh(), TrackKind::Video, TimeRange::new(Time::ZERO, len), start);
        c.media_duration = Some(s(10));
        c.animation.position.value = pos;
        c.animation.scale.value = scale;
        c
    }

    fn pic() -> Clip {
        picture(Time::ZERO, s(4), v(100.0, 50.0), v(1.0, 1.0))
    }

    fn text() -> Clip {
        let id = fresh();
        let mut c = Clip::new(id, "t", id, TrackKind::Video, TimeRange::new(Time::ZERO, s(2)), Time::ZERO);
        c.generator = Some(GeneratorRef { kind: "text".to_string(), payload: vec![1, 2, 3], payload_version: 1 });
        c.animation.position.value = v(0.0, 400.0);
        c
    }

    fn timeline(clips: Vec<Clip>) -> Timeline {
        let mut video = Track::new(fresh(), TrackKind::Video);
        video.set_clips(clips);
        Timeline::new(fresh(), "S", base(), vec![video, Track::new(fresh(), TrackKind::Audio)])
    }

    fn vertical(t: &mut Timeline, mode: ConformMode, ids: &mut SequentialIds) -> Id {
        t.add_variant("9:16", 1080, 1920, mode, ids).unwrap()
    }

    fn layers(t: &Timeline, at: Time, variant: Option<Id>) -> Vec<sq_core_effects::evaluation::LayerRequest> {
        fn none(_: Id) -> Option<&'static Timeline> {
            None
        }
        let hooks =
            LayerHooks { variant_format: &variant_format, resolve_variant: &resolve_variant, ..LayerHooks::plain() };
        t.video_layers(at, &none, &hooks, variant)
    }

    fn first_transform(t: &Timeline, at: Time, variant: Option<Id>) -> sq_core_model::ClipTransform {
        layers(t, at, variant).first().map(|l| l.transform).unwrap()
    }

    #[test]
    fn add_variant_stores_size_and_keeps_the_base_format() {
        let mut ids = SequentialIds::default();
        let mut t = timeline(vec![pic()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        assert_eq!(t.variants.len(), 1);
        assert_eq!(t.variant(Some(id)).map(|v| v.name.as_str()), Some("9:16"));
        assert_eq!(t.format, base());
        let f = t.format_for(Some(id));
        assert!(f.width == 1080 && f.height == 1920);
        assert!(f.frame_duration == fd() && f.audio_sample_rate == base().audio_sample_rate);
        assert_eq!(t.format_for(None), base());
        assert_eq!(t.format_for(Some(Id::from_u128(99))), base());
    }

    #[test]
    fn add_variant_refuses_an_invalid_size() {
        let mut ids = SequentialIds::default();
        let mut t = timeline(Vec::new());
        assert_eq!(t.add_variant("x", 0, 100, ConformMode::Fill, &mut ids), Err(EditError::InvalidFormat.into()));
        assert_eq!(t.add_variant("x", 100, -1, ConformMode::Fill, &mut ids), Err(EditError::InvalidFormat.into()));
        assert!(t.variants.is_empty());
    }

    #[test]
    fn rename_resize_and_conform_mode_of_a_variant() {
        let mut ids = SequentialIds::default();
        let mut t = timeline(Vec::new());
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.rename_variant(id, "Reels").unwrap();
        t.set_variant_size(id, 1080, 1350).unwrap();
        t.set_variant_conform(id, ConformMode::Fit).unwrap();
        let want =
            FormatVariant { id, name: "Reels".to_string(), width: 1080, height: 1350, conform: ConformMode::Fit };
        assert_eq!(t.variant(Some(id)), Some(&want));
        assert_eq!(t.set_variant_size(id, 0, 10), Err(EditError::InvalidFormat.into()));
        assert_eq!(t.rename_variant(Id::from_u128(99), "x"), Err(VariantError::VariantNotFound));
    }

    #[test]
    fn remove_variant_drops_its_overrides_from_every_clip() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let a = vertical(&mut t, ConformMode::Fill, &mut ids);
        let b = t.add_variant("1:1", 1080, 1080, ConformMode::Fill, &mut ids).unwrap();
        t.edit_override(c.id, a, ok(|o| o.position = Some(AnimatedProperty::new(v(1.0, 2.0))))).unwrap();
        t.edit_override(c.id, b, ok(|o| o.position = Some(AnimatedProperty::new(v(3.0, 4.0))))).unwrap();
        t.remove_variant(a).unwrap();
        assert_eq!(t.variants.iter().map(|x| x.id).collect::<Vec<_>>(), vec![b]);
        let after = t.find(c.id).unwrap().clip;
        assert_eq!(after.variant_overrides().keys().copied().collect::<Vec<_>>(), vec![b]);
        assert_eq!(t.remove_variant(a), Err(VariantError::VariantNotFound));
    }

    #[test]
    fn a_clip_without_overrides_stores_nothing_and_an_emptied_override_is_removed() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let text_of = |t: &Timeline| serde_json::to_string(&t.find(c.id).unwrap().clip).unwrap();
        assert!(!text_of(&t).contains("variantOverrides"));
        t.edit_override(c.id, id, ok(|o| o.scale = Some(AnimatedProperty::new(v(2.0, 2.0))))).unwrap();
        assert!(t.override_of(c.id, id).is_some_and(|o| o.scale.is_some()));
        t.edit_override(c.id, id, ok(|o| o.scale = None)).unwrap();
        assert!(t.override_of(c.id, id).is_none());
        assert!(t.find(c.id).unwrap().clip.variant_overrides().is_empty());
        assert!(!text_of(&t).contains("variantOverrides"));
        t.set_override(Some(VariantOverride::default()), c.id, id).unwrap();
        assert!(t.find(c.id).unwrap().clip.variant_overrides().is_empty());
        assert!(VariantOverride::default().is_empty());
    }

    #[test]
    fn override_on_an_unknown_clip_or_variant_fails() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let rot = || ok(|o| o.rotation = Some(AnimatedProperty::new(5.0)));
        assert_eq!(t.edit_override(Id::from_u128(99), id, rot()), Err(EditError::ClipNotFound.into()));
        assert_eq!(t.edit_override(c.id, Id::from_u128(99), rot()), Err(VariantError::VariantNotFound));
    }

    #[test]
    fn overrides_are_stored_only_for_the_variant_that_was_edited() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let a = vertical(&mut t, ConformMode::Fill, &mut ids);
        let b = t.add_variant("1:1", 1080, 1080, ConformMode::Fill, &mut ids).unwrap();
        t.edit_override(c.id, a, ok(|o| o.rotation = Some(AnimatedProperty::new(10.0)))).unwrap();
        assert_eq!(t.override_of(c.id, a).and_then(|o| o.rotation).map(|r| r.value), Some(10.0));
        assert!(t.override_of(c.id, b).is_none());
        assert_eq!(t.find(c.id).unwrap().clip.animation.rotation.value, 0.0);
    }

    #[test]
    fn base_evaluation_ignores_variants_and_a_missing_override_is_the_automatic_conform() {
        let mut ids = SequentialIds::default();
        // 1920x1080 -> 1080x1920 fill: factor max(1080/1920, 1920/1080) = 1920/1080.
        let c = picture(Time::ZERO, s(4), v(90.0, 54.0), v(1.0, 1.0));
        let mut t = timeline(vec![c]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let k = 1920.0 / 1080.0;
        let tr = first_transform(&t, s(1), Some(id));
        assert!((tr.position.x - 90.0 * k).abs() < 1e-9 && (tr.position.y - 54.0 * k).abs() < 1e-9);
        assert!((tr.scale.x - k).abs() < 1e-9 && (tr.scale.y - k).abs() < 1e-9);
        assert!(tr.rotation == 0.0 && tr.opacity == 1.0);
        assert_eq!(first_transform(&t, s(1), None).position, v(90.0, 54.0));
        assert_eq!(layers(&t, Time::ZERO, Some(Id::from_u128(99))), layers(&t, Time::ZERO, None));
    }

    #[test]
    fn fit_conform_uses_the_smaller_factor_and_a_clip_mode_wins() {
        let mut ids = SequentialIds::default();
        let c = picture(Time::ZERO, s(4), v(0.0, 0.0), v(2.0, 2.0));
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fit, &mut ids);
        assert!((first_transform(&t, Time::ZERO, Some(id)).scale.x - 2.0 * 1080.0 / 1920.0).abs() < 1e-9);
        let c2 = picture(Time::ZERO, s(4), v(0.0, 0.0), v(1.0, 1.0));
        let mut t2 = timeline(vec![c2.clone()]);
        let id2 = vertical(&mut t2, ConformMode::Fill, &mut ids);
        t2.edit_override(c2.id, id2, ok(|o| o.conform = Some(ConformMode::Fit))).unwrap();
        assert!((first_transform(&t2, Time::ZERO, Some(id2)).scale.x - 1080.0 / 1920.0).abs() < 1e-9);
    }

    #[test]
    fn overridden_property_is_used_as_is_and_the_others_stay_automatic() {
        let mut ids = SequentialIds::default();
        let c = picture(Time::ZERO, s(4), v(90.0, 54.0), v(1.0, 1.0));
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.edit_override(c.id, id, ok(|o| o.position = Some(AnimatedProperty::new(v(-200.0, 10.0))))).unwrap();
        let tr = first_transform(&t, s(1), Some(id));
        assert_eq!(tr.position, v(-200.0, 10.0)); // not conformed again
        assert!((tr.scale.x - 1920.0 / 1080.0).abs() < 1e-9); // still automatic
    }

    #[test]
    fn rotation_and_anchor_overrides() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        c.animation.rotation.value = 5.0;
        c.animation.anchor.value = v(1.0, 1.0);
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        assert_eq!(first_transform(&t, Time::ZERO, Some(id)).rotation, 5.0);
        t.edit_override(c.id, id, |o| {
            o.rotation = Some(AnimatedProperty::new(-90.0));
            o.anchor = Some(AnimatedProperty::new(v(7.0, 8.0)));
            Ok(())
        })
        .unwrap();
        let tr = first_transform(&t, Time::ZERO, Some(id));
        assert!(tr.rotation == -90.0 && tr.anchor == v(7.0, 8.0));
    }

    #[test]
    fn keyframed_override_is_evaluated_in_clip_local_time() {
        let mut ids = SequentialIds::default();
        let c = picture(s(10), s(4), v(100.0, 50.0), v(1.0, 1.0));
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let mut p = AnimatedProperty::new(v(0.0, 0.0));
        p.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, v(0.0, 0.0)));
        p.track.insert(Keyframe::new(ids.next_id(), s(2), v(200.0, 0.0)));
        t.edit_override(c.id, id, ok(|o| o.position = Some(p))).unwrap();
        assert!((first_transform(&t, s(11), Some(id)).position.x - 100.0).abs() < 1e-9);
    }

    #[test]
    fn detach_copies_the_automatic_value_into_the_override() {
        let mut ids = SequentialIds::default();
        let mut c = picture(Time::ZERO, s(4), v(54.0, 0.0), v(1.0, 1.0));
        c.animation.scale.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, v(1.0, 1.0)));
        c.animation.scale.track.insert(Keyframe::new(ids.next_id(), s(1), v(2.0, 2.0)));
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let before = layers(&t, Time::new(1, 2), Some(id));
        t.detach(&[VariantProperty::Position, VariantProperty::Scale].into_iter().collect(), c.id, id).unwrap();
        let o = t.override_of(c.id, id).unwrap();
        assert!(o.position.is_some() && o.scale.is_some() && o.rotation.is_none());
        assert_eq!(o.scale.as_ref().map(|s| s.track.keys.len()), Some(2));
        assert_eq!(layers(&t, Time::new(1, 2), Some(id)), before); // nothing moves on screen
        // Detaching again keeps the edited override.
        t.edit_override(c.id, id, ok(|o| o.position.iter_mut().for_each(|p| p.value = v(1.0, 1.0)))).unwrap();
        t.detach(&[VariantProperty::Position].into_iter().collect(), c.id, id).unwrap();
        assert_eq!(t.override_of(c.id, id).and_then(|o| o.position).map(|p| p.value), Some(v(1.0, 1.0)));
    }

    #[test]
    fn reset_removes_one_or_all_properties() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.detach(&VariantProperty::ALL.into_iter().collect(), c.id, id).unwrap();
        t.reset_override(Some(VariantProperty::Position), c.id, id).unwrap();
        assert!(t.override_of(c.id, id).is_some_and(|o| o.position.is_none() && o.scale.is_some()));
        t.reset_override(None, c.id, id).unwrap();
        assert!(t.override_of(c.id, id).is_none());
    }

    #[test]
    fn prune_drops_overrides_of_unknown_variants() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        c.set_variant_overrides(BTreeMap::from([(
            Id::from_u128(99),
            VariantOverride { rotation: Some(AnimatedProperty::new(1.0)), ..VariantOverride::default() },
        )]));
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.edit_override(c.id, id, ok(|o| o.rotation = Some(AnimatedProperty::new(2.0)))).unwrap();
        assert!(t.prune_variant_overrides());
        assert_eq!(t.find(c.id).unwrap().clip.variant_overrides().keys().copied().collect::<Vec<_>>(), vec![id]);
        assert!(!t.prune_variant_overrides());
    }

    #[test]
    fn with_timeline_fails_for_an_unknown_timeline() {
        let mut p = Project::new(Id::from_u128(1), "P", Vec::new(), Vec::new());
        assert_eq!(p.with_timeline(Id::from_u128(9), |_| ()), Err(EditError::TimelineNotFound));
    }

    // W5.1

    #[test]
    fn motion_edit_in_a_variant_writes_the_override_not_the_base() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let mut shown = t.resolved_clip(&t.find(c.id).unwrap().clip, Some(id));
        shown.animation.position.value = v(7.0, 8.0);
        t.apply_displayed_edit(&shown, Some(id), true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        let o = after.variant_overrides().remove(&id).unwrap();
        assert_eq!(after.animation.position.value, v(100.0, 50.0));
        assert_eq!(o.position.map(|p| p.value), Some(v(7.0, 8.0)));
        assert!(o.scale.is_none()); // only what changed is detached
        assert_eq!(t.resolved_clip(&after, Some(id)).animation.position.value, v(7.0, 8.0));
    }

    #[test]
    fn tilt_edit_in_a_variant_writes_the_override_not_the_base() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        c.animation.tilt_x.value = 10.0;
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let mut shown = t.resolved_clip(&t.find(c.id).unwrap().clip, Some(id));
        assert_eq!(shown.animation.tilt_x.value, 10.0); // inherited until overridden
        shown.animation.tilt_y.value = 30.0;
        t.apply_displayed_edit(&shown, Some(id), true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        assert!(after.animation.tilt_y.value == 0.0 && after.animation.tilt_x.value == 10.0);
        let o = after.variant_overrides().remove(&id).unwrap();
        assert_eq!(o.tilt_y.map(|p| p.value), Some(30.0));
        assert!(o.tilt_x.is_none());
        assert_eq!(first_transform(&t, Time::ZERO, Some(id)).tilt_y, 30.0);
        assert_eq!(first_transform(&t, Time::ZERO, None).tilt_y, 0.0);
    }

    #[test]
    fn tilt_detach_and_reset_follow_the_property() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        c.animation.tilt_x.value = 12.0;
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.detach(&[VariantProperty::Tilt].into_iter().collect(), c.id, id).unwrap();
        let o = t.override_of(c.id, id).unwrap();
        assert!(o.has(VariantProperty::Tilt) && o.tilt_x.as_ref().map(|p| p.value) == Some(12.0));
        t.reset_override(Some(VariantProperty::Tilt), c.id, id).unwrap();
        assert!(t.override_of(c.id, id).is_none());
    }

    #[test]
    fn shared_properties_edited_in_a_variant_go_to_the_base() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let mut shown = t.resolved_clip(&t.find(c.id).unwrap().clip, Some(id));
        shown.animation.opacity.value = 0.25;
        t.apply_displayed_edit(&shown, Some(id), true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        assert_eq!(after.animation.opacity.value, 0.25);
        assert_eq!(after.animation.scale.value, v(1.0, 1.0)); // the auto-conformed scale is not written back
        assert!(after.variant_overrides().is_empty());
    }

    fn crop(ids: &mut SequentialIds, params: &[(&str, f64)]) -> ClipEffectAlias {
        let mut e = ClipEffectAlias::new(ids.next_id(), ClipEffectAlias::CROP_KIND);
        for (k, val) in params {
            e.parameters.insert((*k).to_string(), AnimatedProperty::new(*val));
        }
        e
    }
    type ClipEffectAlias = sq_core_model::ClipEffect;

    #[test]
    fn overridden_effect_parameter_stays_per_variant_others_are_shared() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        let fx = crop(&mut ids, &[(ClipEffectAlias::CROP_LEFT_KEY, 10.0), (ClipEffectAlias::CROP_RIGHT_KEY, 5.0)]);
        c.effects = vec![fx.clone()];
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.edit_override(c.id, id, |o| {
            let ps = BTreeMap::from([(ClipEffectAlias::CROP_LEFT_KEY.to_string(), AnimatedProperty::new(30.0))]);
            o.effect_parameters.insert(fx.id, ps);
            Ok(())
        })
        .unwrap();
        let mut shown = t.resolved_clip(&t.find(c.id).unwrap().clip, Some(id));
        shown.effects[0].parameters.insert(ClipEffectAlias::CROP_LEFT_KEY.to_string(), AnimatedProperty::new(40.0));
        shown.effects[0].parameters.insert(ClipEffectAlias::CROP_RIGHT_KEY.to_string(), AnimatedProperty::new(6.0));
        t.apply_displayed_edit(&shown, Some(id), true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        assert_eq!(after.effects[0].parameters[ClipEffectAlias::CROP_LEFT_KEY].value, 10.0);
        assert_eq!(after.effects[0].parameters[ClipEffectAlias::CROP_RIGHT_KEY].value, 6.0);
        let o = after.variant_overrides().remove(&id).unwrap();
        assert_eq!(o.effect_parameters[&fx.id][ClipEffectAlias::CROP_LEFT_KEY].value, 40.0);
    }

    #[test]
    fn removing_an_effect_in_a_variant_drops_its_overrides() {
        let mut ids = SequentialIds::default();
        let mut c = pic();
        let fx = crop(&mut ids, &[(ClipEffectAlias::CROP_LEFT_KEY, 10.0)]);
        c.effects = vec![fx.clone()];
        let mut t = timeline(vec![c.clone()]);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.edit_override(c.id, id, |o| {
            let ps = BTreeMap::from([(ClipEffectAlias::CROP_LEFT_KEY.to_string(), AnimatedProperty::new(30.0))]);
            o.effect_parameters.insert(fx.id, ps);
            o.rotation = Some(AnimatedProperty::new(5.0));
            Ok(())
        })
        .unwrap();
        let mut shown = t.resolved_clip(&t.find(c.id).unwrap().clip, Some(id));
        shown.effects.retain(|e| e.id != fx.id);
        t.apply_displayed_edit(&shown, Some(id), true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        assert!(after.effects.is_empty());
        let o = after.variant_overrides().remove(&id).unwrap();
        assert!(o.effect_parameters.is_empty());
        assert_eq!(o.rotation.map(|r| r.value), Some(5.0));
    }

    #[test]
    fn displayed_edit_without_a_variant_replaces_the_clip() {
        let mut ids = SequentialIds::default();
        let c = pic();
        let mut t = timeline(vec![c.clone()]);
        vertical(&mut t, ConformMode::Fill, &mut ids);
        let mut n = c.clone();
        n.animation.position.value = v(1.0, 1.0);
        t.apply_displayed_edit(&n, None, true).unwrap();
        let after = t.find(c.id).unwrap().clip;
        assert_eq!(after.animation.position.value, v(1.0, 1.0));
        assert!(after.variant_overrides().is_empty());
    }

    fn nested(inner: &Timeline) -> Clip {
        let mut c = picture(Time::ZERO, s(4), v(100.0, 50.0), v(1.0, 1.0));
        c.sequence = Some(inner.id);
        c
    }

    #[test]
    fn nested_clip_is_displayed_and_edited_unconformed_when_its_sequence_has_the_variant() {
        let mut ids = SequentialIds::default();
        let mut inner = timeline(vec![pic()]);
        let id = vertical(&mut inner, ConformMode::Fill, &mut ids);
        let n = nested(&inner);
        let plain = pic();
        let mut t = timeline(vec![n.clone()]);
        let mut plain_track = Track::new(fresh(), TrackKind::Video);
        plain_track.set_clips(vec![plain.clone()]);
        t.tracks.push(plain_track);
        t.variants = inner.variants.clone(); // same id
        let p0 = Project::new(Id::from_u128(1), "p", Vec::new(), vec![t.clone(), inner.clone()]);
        assert!(!p0.conforms_picture(&n, Some(id)));
        assert!(p0.conforms_picture(&plain, Some(id)));
        let shown = p0.displayed_clip(&n, &t, Some(id));
        assert_eq!(shown.animation.scale.value, v(1.0, 1.0));
        assert_ne!(p0.displayed_clip(&plain, &t, Some(id)).animation.scale.value, v(1.0, 1.0));
        assert_eq!(p0.picture_size_in(&n, Some(id)), Some((1080, 1920)));

        let mut edited = shown;
        edited.animation.rotation.value = 10.0;
        let mut t2 = t.clone();
        t2.apply_displayed_edit(&edited, Some(id), p0.conforms_picture(&n, Some(id))).unwrap();
        let o = t2.override_of(n.id, id).unwrap();
        assert_eq!(o.rotation.map(|r| r.value), Some(10.0));
        assert!(o.scale.is_none() && o.position.is_none()); // nothing conformed written into the override
        let p = Project::new(Id::from_u128(1), "p", Vec::new(), vec![t2.clone(), inner]);
        let view = p.variant_view(t.id, Some(id)).unwrap();
        assert_eq!(view.timeline.find(n.id).unwrap().clip.animation.scale.value, v(1.0, 1.0));
        let want = p.displayed_clip(&t2.find(n.id).unwrap().clip, &t2, Some(id)).animation;
        assert_eq!(want, view.timeline.find(n.id).unwrap().clip.animation);
    }

    /// A sequence reachable two ways (directly and through a chain) is materialized once, never conformed twice.
    #[test]
    fn variant_view_does_not_conform_a_sequence_reached_two_ways() {
        let mut ids = SequentialIds::default();
        let mut x = timeline(vec![pic()]);
        let id = vertical(&mut x, ConformMode::Fill, &mut ids);
        let mut z = timeline(vec![nested(&x)]);
        z.variants = x.variants.clone();
        let mut y = timeline(vec![nested(&z)]);
        y.variants = x.variants.clone();
        let (nx, ny) = (nested(&x), nested(&y));
        let mut t = timeline(vec![nx]);
        let mut second = Track::new(fresh(), TrackKind::Video);
        second.set_clips(vec![ny]);
        t.tracks.push(second);
        t.variants = x.variants.clone();
        let tid = t.id;
        let p = Project::new(Id::from_u128(1), "p", Vec::new(), vec![t, x, y.clone(), z.clone()]);
        let view = p.variant_view(tid, Some(id)).unwrap();
        let scale_of = |t: &Timeline| t.tracks[0].clips().first().map(|c| c.animation.scale.value);
        assert_eq!(scale_of(&view.sequences[&z.id]), Some(v(1.0, 1.0)));
        assert_eq!(scale_of(&view.sequences[&y.id]), Some(v(1.0, 1.0)));
        assert_eq!(scale_of(&view.timeline), Some(v(1.0, 1.0)));
    }

    #[test]
    fn variant_view_matches_per_frame_resolution() {
        let mut ids = SequentialIds::default();
        let mut a = picture(Time::ZERO, s(2), v(30.0, 40.0), v(1.0, 1.0));
        a.animation.position.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, v(0.0, 0.0)));
        a.animation.position.track.insert(Keyframe::new(ids.next_id(), s(1), v(200.0, 0.0)));
        let b = text();
        let mut t = timeline(vec![a]);
        let mut second = Track::new(fresh(), TrackKind::Video);
        second.set_clips(vec![b.clone()]);
        t.tracks.push(second);
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        t.edit_override(b.id, id, ok(|o| o.scale = Some(AnimatedProperty::new(v(2.0, 2.0))))).unwrap();
        let tid = t.id;
        let p = Project::new(Id::from_u128(1), "p", Vec::new(), vec![t.clone()]);
        let view = p.variant_view(tid, Some(id)).unwrap();
        assert_eq!(view.timeline.format, t.format_for(Some(id)));
        assert!(view.timeline.variants.is_empty());
        for f in 0..60 {
            let at = Time::new(f, 30);
            assert_eq!(layers(&view.timeline, at, None), layers(&t, at, Some(id)), "frame {f}");
        }
        // No variant: the timeline as it is.
        assert_eq!(p.variant_view(tid, None).map(|v| v.timeline), Some(t));
        assert!(p.variant_view(Id::from_u128(99), None).is_none());
    }

    #[test]
    fn active_variant_needs_an_existing_variant() {
        let mut ids = SequentialIds::default();
        let mut t = timeline(Vec::new());
        let id = vertical(&mut t, ConformMode::Fill, &mut ids);
        let tid = t.id;
        let mut p = Project::new(Id::from_u128(1), "p", Vec::new(), vec![t]);
        assert_eq!(p.active_variant(tid), None);
        p.active_variants.insert(tid, id);
        assert_eq!(p.active_variant(tid), Some(id));
        p.active_variants.insert(tid, Id::from_u128(99));
        assert_eq!(p.active_variant(tid), None);
    }
}
