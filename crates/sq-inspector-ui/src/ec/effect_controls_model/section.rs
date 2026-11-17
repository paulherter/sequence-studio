// Swift: EffectControlsModel.swift (Sections and properties), EffectControlsModel+MaskPathKeys.swift (keyProperties)
//! `EffectSection` rows: the properties of a section and the ones whose keys it shows.

use sq_core_graphics::custom_animation::AnimationParam;
use sq_core_model::{ClipEffect, EffectCatalog};
use sq_editor_session::EffectSection;

use super::property::{EffectProperty, MaskParam};

/// The animatable properties of a section.
pub fn section_properties(s: &EffectSection) -> Vec<EffectProperty> {
    match s {
        // Opacity sits inside Motion, under Anchor Point; FB-G: Motion's own Shutter Angle closes the group (Transform's place).
        EffectSection::Motion => vec![
            EffectProperty::Position,
            EffectProperty::Scale,
            EffectProperty::Rotation,
            EffectProperty::TiltX,
            EffectProperty::TiltY,
            EffectProperty::Anchor,
            EffectProperty::Opacity,
            EffectProperty::ShutterAngle,
            EffectProperty::AntiFlicker,
        ],
        EffectSection::Opacity => vec![EffectProperty::Opacity],
        EffectSection::Volume => vec![EffectProperty::Volume],
        EffectSection::Speed => Vec::new(),
        EffectSection::Effect { id, kind } => {
            // P4: an X/Y pair (Transform Position / Anchor) is one row, carried by its X member.
            // Multiband band solo / bypass and "Link band controls" live in the custom setup popup only (no rows, no keys).
            let Some(spec) = EffectCatalog::spec_for(kind) else { return Vec::new() };
            spec.params
                .iter()
                .filter(|p| spec.pair_containing(&p.key).map(|pr| pr.y.as_str()) != Some(p.key.as_str()))
                .filter(|p| {
                    kind != ClipEffect::AUDIO_MULTIBAND_KIND
                        || !sq_core_audio::audio_effects::mb_setup_only_keys().contains(&p.key)
                })
                .map(|p| EffectProperty::Fx { id: *id, kind: kind.clone(), key: p.key.clone() })
                .collect()
        }
        EffectSection::Mask(id) => MaskParam::ALL.into_iter().map(|m| EffectProperty::Mask(*id, m)).collect(),
        EffectSection::Animation(side) => {
            AnimationParam::ALL.into_iter().map(|p| EffectProperty::Anim(*side, p)).collect()
        }
    }
}

/// `EffectSection` rows as methods.
pub trait EffectSectionExt {
    /// Animatable properties.
    fn properties(&self) -> Vec<EffectProperty>;
    /// The properties whose keys the section's summary and the timeline clip lane show: `properties`, plus a mask's Path.
    fn key_properties(&self) -> Vec<EffectProperty>;
}

impl EffectSectionExt for EffectSection {
    fn properties(&self) -> Vec<EffectProperty> {
        section_properties(self)
    }

    fn key_properties(&self) -> Vec<EffectProperty> {
        let mut p = section_properties(self);
        if let EffectSection::Mask(id) = self {
            p.push(EffectProperty::MaskPath(*id));
        }
        p
    }
}
