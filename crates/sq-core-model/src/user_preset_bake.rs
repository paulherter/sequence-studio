// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: UserPresetBake.swift (saved types, moved down; the bake logic lives in sq-core-edit)

use crate::{ClipAnimation, ClipEffect};
use serde::{Deserialize, Serialize};
use sq_core_time::Id;

/// What Convert to Keyframes baked into the clip's Motion (v29, `Clip.bakedEffects`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BakedEffect {
    /// Identity.
    pub id: Id,
    /// The recipe: the effect kind that was baked (`ClipEffect.transformKind`).
    #[serde(rename = "recipeID")]
    pub recipe_id: String,
    /// The effect as it was, every parameter and key (clip-local times, kept in step with the clip).
    pub effect: ClipEffect,
    /// Its place in `Clip.effects`.
    pub index: i64,
    /// The clip's Motion / Opacity before the bake (restored by Re-open).
    pub motion: ClipAnimation,
}
