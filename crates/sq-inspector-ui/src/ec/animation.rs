// Swift: EffectControlsModel+Animation.swift
//! What the Intro / Outro popups of a text or graphic item offer, and the keyframe rows of a Custom side.

use std::collections::BTreeMap;

use sq_core_effects::keystone::Keystone;
use sq_core_graphics::custom_animation::{
    AnimationParam, AnimationSetCustomExt, AnimationSide, KeyframeTemplateCustomExt, KeystoneAnimationExt,
};
use sq_core_model::anchored_animation::{AnimationAnchor, AnimationSet, KeyframeTemplate};
use sq_core_model::{AnimatedProperty, Clip, SequenceFormat};
use sq_core_time::{IdSource, Keyframe, Time, Vec2};
use sq_editor_session::EffectSection;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::caption_style_looks::CaptionStyleLooks;
use sq_text::text_generator::TextGenerator;

use crate::ec::effect_controls_model::core::{EffectControlsModel, ReservedIds, new_key};
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::inspector_text_formats::AnimationPresetName;

/// Where the saved Intro / Outro animations come from: the window's Library keystones.
pub trait AnimationKeystoneSource {
    fn offered_animations(&self, side: AnimationSide) -> Vec<Keystone>;
    /// The Library takes new keystones (a Custom side can be saved).
    fn can_save(&self) -> bool;
    /// Stores `keystone` in the Library (Swift `save(_:) async`; here the owner queues it and answers at once).
    /// False when it could not be stored.
    fn save(&self, keystone: Keystone) -> bool;
}

/// What the Intro / Outro popups of a text or graphic item offer, and when a side is Custom.
pub enum AnimationChoices {}

impl AnimationChoices {
    /// Popup entry that turns the side into a Custom animation (its keys are edited in Controls).
    pub const CUSTOM_ID: &'static str = "custom";
    /// Popup entry that saves the side's Custom animation under a name.
    pub const SAVE_ID: &'static str = "save";
    /// Prefix of a saved animation's id (a keystone of the Library).
    pub const SAVED_PREFIX: &'static str = "mine:";
    /// What the popup shows for a preset that is not in the list (its saved animation was deleted).
    pub const UNKNOWN_TITLE: &'static str = "Saved";

    /// The keystones a side offers: the built-in ones that start with the clip (Intro) or end with it (Outro), then the
    /// user's saved ones.
    pub fn saved(side: AnimationSide, store: Option<&dyn AnimationKeystoneSource>) -> Vec<Keystone> {
        store.map(|s| s.offered_animations(side)).unwrap_or_default()
    }

    pub fn frame_size(format: Option<&SequenceFormat>) -> Vec2 {
        format.map_or(Vec2::new(1080.0, 1920.0), |f| Vec2::new(f.width as f64, f.height as f64))
    }

    /// The preset ids of a side: Off, the neutral ones, the rest, then the saved ones.
    pub fn preset_ids(
        side: AnimationSide,
        library: &CaptionPresetLibrary,
        store: Option<&dyn AnimationKeystoneSource>,
    ) -> Vec<String> {
        let mut presets = Self::built_in_ids(side, library);
        let taken: std::collections::BTreeSet<String> =
            presets.iter().map(|id| AnimationPresetName::title(id).to_lowercase()).collect();
        // A built-in keystone with the name of a preset is that preset (listed once); a saved one always has its own entry.
        presets.extend(
            Self::saved(side, store)
                .iter()
                .filter(|k| !k.is_built_in() || !taken.contains(&k.name.to_lowercase()))
                .map(|k| format!("{}{}", Self::SAVED_PREFIX, k.id)),
        );
        presets
    }

    fn built_in_ids(side: AnimationSide, library: &CaptionPresetLibrary) -> Vec<String> {
        let anchor = if side == AnimationSide::Intro { AnimationAnchor::Start } else { AnimationAnchor::End };
        let all: Vec<String> = library
            .animation_ids()
            .into_iter()
            .filter(|id| {
                let a = library.animation(Some(id));
                a != KeyframeTemplate::none() && a.anchor == anchor
            })
            .collect();
        let neutral_source: &[&str] = if side == AnimationSide::Intro {
            &CaptionStyleLooks::NEUTRAL_INTRO_IDS
        } else {
            &CaptionStyleLooks::NEUTRAL_OUTRO_IDS
        };
        let neutral: Vec<String> = neutral_source.iter().map(|s| s.to_string()).filter(|id| all.contains(id)).collect();
        let mut out = vec!["none".to_string()];
        out.extend(neutral.iter().cloned());
        out.extend(all.into_iter().filter(|id| !neutral.contains(id)));
        out
    }

    /// The template behind a preset id; nil for an unknown one. "none" is the empty template.
    pub fn template(
        id: &str,
        side: AnimationSide,
        library: &CaptionPresetLibrary,
        frame_size: Vec2,
        store: Option<&dyn AnimationKeystoneSource>,
    ) -> Option<KeyframeTemplate> {
        if id.starts_with(Self::SAVED_PREFIX) {
            return Self::saved(side, store)
                .iter()
                .find(|k| format!("{}{}", Self::SAVED_PREFIX, k.id) == id)
                .and_then(|k| k.animation_template(frame_size));
        }
        library.has_animation(id).then(|| library.animation(Some(id)))
    }

    /// A side is Custom once its keys carry ids of their own (`KeyframeTemplate.withFreshKeyIDs`): a fact of the side
    /// alone, whatever the Library holds and whatever the sequence format is.
    pub fn is_custom(t: Option<&KeyframeTemplate>) -> bool {
        let Some(t) = t else { return false };
        if t.tracks.is_empty() {
            return false;
        }
        t.has_own_key_ids()
    }

    /// The preset a side plays; nil for a Custom side and for a preset nobody knows any more (a saved animation that
    /// was deleted from the Library: it keeps playing, the popup shows "Saved"). The text animator is not part of the
    /// preset (it is chosen on its own): an animator-only side is "none". A saved animation matches in every sequence
    /// format (`same_shape`: its Position is a fraction of the frame).
    pub fn preset_id(
        t: Option<&KeyframeTemplate>,
        side: AnimationSide,
        library: &CaptionPresetLibrary,
        frame_size: Vec2,
        store: Option<&dyn AnimationKeystoneSource>,
        preferred: Option<&str>,
    ) -> Option<String> {
        let Some(t) = t else { return Some("none".to_string()) };
        if t.tracks.is_empty() {
            return Some("none".to_string());
        }
        let mut preset = t.clone();
        if preset.has_own_key_ids() {
            return None;
        }
        preset.text_animator = None;
        let built_in_ids = Self::built_in_ids(side, library);
        let built_in = built_in_ids
            .iter()
            .find(|id| id.as_str() != "none" && library.animation(Some(id)).same_curves(&preset))
            .cloned();
        // A keystone stores no loop flag: the side keeps its own, so looping is not part of what makes a side a saved
        // animation.
        let templates: Vec<(String, KeyframeTemplate)> = Self::saved(side, store)
            .iter()
            .filter_map(|k| {
                let mut s = k.animation_template(frame_size)?;
                s.loops = preset.loops;
                Some((format!("{}{}", Self::SAVED_PREFIX, k.id), s))
            })
            .collect();
        let exact: Vec<&String> =
            templates.iter().filter(|(_, tp)| tp.same_curves(&preset)).map(|(id, _)| id).collect();
        let shaped: Vec<&String> =
            templates.iter().filter(|(_, tp)| tp.same_shape(&preset)).map(|(id, _)| id).collect();
        // Several animations can hold the same curves: the one the user picked or saved last is the one shown.
        if let Some(pref) = preferred
            && (Some(pref) == built_in.as_deref()
                || exact.iter().any(|e| e.as_str() == pref)
                || shaped.iter().any(|e| e.as_str() == pref))
        {
            return Some(pref.to_string());
        }
        if let Some(found) =
            built_in.or_else(|| exact.first().map(|s| (*s).clone())).or_else(|| shaped.first().map(|s| (*s).clone()))
        {
            return Some(found);
        }
        // A preset whose zone length was changed (`TextInspectorModel.setZoneLength`) is still that preset.
        if preset.duration <= Time::ZERO {
            return None;
        }
        let length_adjusted = |t: &KeyframeTemplate| t.retimed(preset.duration).same_curves(&preset);
        built_in_ids
            .iter()
            .find(|id| id.as_str() != "none" && length_adjusted(&library.animation(Some(id))))
            .cloned()
            .or_else(|| templates.iter().find(|(_, tp)| length_adjusted(tp)).map(|(id, _)| id.clone()))
    }

    pub fn title(id: &str, side: AnimationSide, store: Option<&dyn AnimationKeystoneSource>) -> String {
        match id {
            "none" => "Off".to_string(),
            Self::CUSTOM_ID => "Custom".to_string(),
            Self::SAVE_ID => "Save Custom\u{2026}".to_string(),
            _ => {
                if id.starts_with(Self::SAVED_PREFIX) {
                    return Self::saved(side, store)
                        .iter()
                        .find(|k| format!("{}{}", Self::SAVED_PREFIX, k.id) == id)
                        .map_or_else(|| Self::UNKNOWN_TITLE.to_string(), |k| k.name.clone());
                }
                AnimationPresetName::title(id)
            }
        }
    }
}

/// A text clip's animations as the Controls rows read them: the Custom sides' tracks already in clip time.
struct AnimationRows {
    set: AnimationSet,
    custom: Vec<AnimationSide>,
    /// Per Custom side: Scale, Rotation, Opacity.
    scalars: BTreeMap<u8, BTreeMap<u8, AnimatedProperty<f64>>>,
    positions: BTreeMap<u8, AnimatedProperty<Vec2>>,
}

fn side_key(s: AnimationSide) -> u8 {
    if s == AnimationSide::Intro { 0 } else { 1 }
}

fn param_key(p: AnimationParam) -> u8 {
    AnimationParam::ALL.iter().position(|x| *x == p).map_or(0, |i| i as u8)
}

impl EffectControlsModel {
    // shortcut: no per-clip rows memo (Swift keeps 16 decoded clips); `TextGenerator::decode` memoizes the payload.
    // Add the memo if a profile of the lanes shows the rebuild.
    fn animation_rows(c: Option<&Clip>) -> Option<AnimationRows> {
        let c = c?;
        let r = c.generator.as_ref()?;
        if r.kind != TextGenerator::KIND {
            return None;
        }
        let (_, a) = TextGenerator::decode(r).ok()?;
        let set = a.unwrap_or_else(|| AnimationSet::new(None, None));
        let custom: Vec<AnimationSide> =
            AnimationSide::ALL.into_iter().filter(|s| AnimationChoices::is_custom(set.template(*s))).collect();
        let mut rows = AnimationRows { set, custom, scalars: BTreeMap::new(), positions: BTreeMap::new() };
        // Reads need no stable ids: a throwaway source serves `position`.
        let mut ids = sq_core_time::SequentialIds::default();
        for side in rows.custom.clone() {
            let mut scalars = BTreeMap::new();
            for p in AnimationParam::ALL {
                if p != AnimationParam::Position {
                    scalars.insert(param_key(p), rows.set.scalar(p, side, c.duration()));
                }
            }
            rows.scalars.insert(side_key(side), scalars);
            rows.positions.insert(side_key(side), rows.set.position(side, c.duration(), &mut ids));
        }
        Some(rows)
    }

    /// The animations of a text clip (an empty set when it has none); nil for every other clip.
    pub fn animations_of(c: Option<&Clip>) -> Option<AnimationSet> {
        Self::animation_rows(c).map(|r| r.set)
    }

    /// The Custom sides of a text clip: only they have rows (a preset is never edited through Controls).
    pub(crate) fn custom_sides(c: Option<&Clip>) -> Vec<AnimationSide> {
        Self::animation_rows(c).map(|r| r.custom).unwrap_or_default()
    }

    /// The keyframe sections of a text clip's Custom sides (none while a side is Off or plays a preset).
    pub(crate) fn custom_animation_sections(&self, c: &Clip) -> Vec<EffectSection> {
        Self::custom_sides(Some(c)).into_iter().map(EffectSection::Animation).collect()
    }

    /// A scalar row of a Custom side in clip time; nil for Position, other properties, other clips and a side that is
    /// not Custom.
    pub(crate) fn anim_scalar(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<f64>> {
        let EffectProperty::Anim(side, param) = p else { return None };
        if *param == AnimationParam::Position {
            return None;
        }
        Self::animation_rows(c)?.scalars.get(&side_key(*side))?.get(&param_key(*param)).cloned()
    }

    /// The Position row of a Custom side in clip time.
    pub(crate) fn anim_vector(p: &EffectProperty, c: Option<&Clip>) -> Option<AnimatedProperty<Vec2>> {
        let EffectProperty::Anim(side, AnimationParam::Position) = p else { return None };
        Self::animation_rows(c)?.positions.get(&side_key(*side)).cloned()
    }

    /// Edits one Custom side. A side that is Off or plays a preset is left alone: its keys are not the user's.
    fn with_animations(c: &mut Clip, side: AnimationSide, body: impl FnOnce(&mut AnimationSet, Time)) {
        let Some(r) = c.generator.clone() else { return };
        if r.kind != TextGenerator::KIND {
            return;
        }
        let Ok((t, a)) = TextGenerator::decode(&r) else { return };
        let mut set = a.clone().unwrap_or_else(|| AnimationSet::new(None, None));
        if !AnimationChoices::is_custom(set.template(side)) {
            return;
        }
        body(&mut set, c.duration());
        if Some(&set) == a.as_ref() {
            return;
        }
        if let Ok(next) = TextGenerator::make_ref(&t, Some(&set)) {
            c.generator = Some(next);
        }
    }

    fn animation_key_time(local: Time, duration: Time) -> Time {
        local.max(Time::ZERO).min(duration)
    }

    /// Edits a scalar row. A row only exists through its keys: a value typed into a row without keys becomes a key at
    /// the playhead.
    pub(crate) fn with_anim_scalar(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        local: Time,
        body: impl FnOnce(&mut AnimatedProperty<f64>, &mut dyn IdSource),
    ) {
        let EffectProperty::Anim(side, param) = p else { return };
        if *param == AnimationParam::Position {
            return;
        }
        let param = *param;
        Self::with_animations(c, *side, |set, duration| {
            set.edit(param, *side, duration, |v| {
                body(v, ids);
                if v.track.is_empty() && v.value != param.rest() {
                    let k = new_key(ids, Self::animation_key_time(local, duration), v.value);
                    v.track.insert(k);
                }
            });
        });
    }

    pub(crate) fn with_anim_vector(
        ids: &mut dyn IdSource,
        c: &mut Clip,
        p: &EffectProperty,
        local: Time,
        body: impl FnOnce(&mut AnimatedProperty<Vec2>, &mut dyn IdSource),
    ) {
        let EffectProperty::Anim(side, AnimationParam::Position) = p else { return };
        Self::with_animations(c, *side, |set, duration| {
            // `edit_position` hands the closure no id source: reserve the few ids a body can need.
            let mut reserved = ReservedIds::take(ids, 8);
            let mut spare = ReservedIds::take(ids, 8);
            set.edit_position(*side, duration, ids, |v| {
                body(v, &mut reserved);
                if v.track.is_empty() && v.value != Vec2::ZERO {
                    let t = Self::animation_key_time(local, duration);
                    v.track.insert(Keyframe::new(spare.next_id(), t, v.value));
                }
            });
        });
    }
}
