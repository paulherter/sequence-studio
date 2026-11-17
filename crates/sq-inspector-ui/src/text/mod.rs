//! Text inspector: model, style library, animator choices and template tiles.

pub mod animator_choices;
pub mod block_draw;
pub mod inspector_model;
pub mod panel_draw;
pub mod style_library;
pub(crate) mod style_sample;
pub mod template_tile_atlas;
pub mod template_tiles;

#[cfg(test)]
mod inspector_model_tests;
