//! Graphics panel: the editor of the selected Graphic, its canvas mapping and the panel rules.

pub mod canvas_mapping;
pub mod editor;
pub mod editor_follow;
pub mod editor_props;
pub mod editor_text;
pub mod form_draw;
pub mod graphic_item_rows_draw;
pub mod key_tick_math;
pub mod layer_list_draw;
pub mod layer_list_logic;
pub mod monitor_logic;
pub mod panel_draw;
pub mod panel_logic;
pub mod template_fields;
pub mod template_slots_draw;

#[cfg(test)]
mod editor_tests;
