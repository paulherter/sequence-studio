// Swift: EffectSearchTerms.swift
//! Other names an effect is searched by in the Effects panel (lowercase). The shown title stays the one name; these only
//! widen the search, so someone who types what the effect does ("steady", "shake") or the other spelling finds it.

use sq_core_model::ClipEffect;
use sq_core_model::TransitionKind;
use sq_editor_session::EffectDragPayload;

/// The extra search names of effect kinds.
pub enum EffectSearchTerms {}

impl EffectSearchTerms {
    /// The other names of `kind` (empty for most).
    pub fn terms(kind: &str) -> Vec<&'static str> {
        if kind == ClipEffect::STABILIZE_KIND {
            return vec![
                "stabilize",
                "stabilise",
                "stabilization",
                "stabiliser",
                "steady",
                "steadicam",
                "shake",
                "shaky",
                "gyroflow",
                "warp stabilizer",
            ];
        }
        // Film Dissolve (Premiere) and Cross Dissolve / Video style (Resolve) are this Dissolve: the compositor mixes in
        // linear light.
        if kind == EffectDragPayload::transition_id(TransitionKind::CrossDissolve) {
            return vec!["film dissolve", "cross dissolve", "non-additive dissolve"];
        }
        // Premiere's names for the effects that carry another name here.
        let premiere: &[(&str, &[&str])] = &[
            (ClipEffect::GAUSSIAN_BLUR_KIND, &["gaussian blur", "fast blur", "box blur"]),
            (ClipEffect::SHARPEN_KIND, &["sharpen edges"]),
            (ClipEffect::ULTRA_KEY_KIND, &["ultra key", "chroma key", "green screen"]),
            (ClipEffect::ALPHA_ADJUST_KIND, &["alpha adjust", "opacity"]),
            (ClipEffect::MOSAIC_KIND, &["pixelate"]),
            (ClipEffect::CORNER_PIN_KIND, &["corner pin"]),
            (ClipEffect::TINT_KIND, &["tint"]),
            (ClipEffect::GRAIN_KIND, &["grain"]),
            (ClipEffect::VIDEO_DENOISE_KIND, &["denoise"]),
            (ClipEffect::EDGE_FEATHER_KIND, &["feather edges"]),
        ];
        if let Some((_, t)) = premiere.iter().find(|(k, _)| *k == kind) {
            return t.to_vec();
        }
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn premiere_names_find_our_effects() {
        assert!(EffectSearchTerms::terms(ClipEffect::GAUSSIAN_BLUR_KIND).contains(&"gaussian blur"));
        assert!(EffectSearchTerms::terms(ClipEffect::STABILIZE_KIND).contains(&"warp stabilizer"));
    }
}
