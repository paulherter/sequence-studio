//! The extension traits of the core crates the Effect Controls code calls (Swift `extension Clip` etc. are traits here).

pub use sq_core_color::{ClipEffectColorExt, ClipGradeExt};
pub use sq_core_edit::multi_clip_edit::MatchingEffectExt;
pub use sq_core_effects::effects_editing::ClipEffectsEditingExt;
pub use sq_core_effects::transition::TransitionExt;
pub use sq_core_effects::user_preset_bake::ClipBakeExt;
pub use sq_core_graphics::custom_animation::{AnimationSetCustomExt, KeyframeTemplateCustomExt};
pub use sq_core_graphics::format_variants_view::ProjectVariantsExt;
pub use sq_core_graphics::graphics_editing::Vec2PropertyExt;
pub use sq_core_graphics::graphics_layer_projection::{GraphicsItemPickerExt, GraphicsItemProjectionExt};
pub use sq_core_masks::anonymize::MagicSelectionAnonymizeExt;
pub use sq_core_masks::magic_mask::MagicSelectionExt;
pub use sq_core_masks::mask_inputs::{ClipEffectMaskExt, MaskInputsExt};
pub use sq_core_masks::masks::{ClipMaskExt, ClipMasksExt};
pub use sq_core_model::keyframes_premiere::{KeyframeTrackPremiere, SpatialSmoothing};
pub use sq_core_model::{EasingCurveShape, KeyframeTrackEase};
