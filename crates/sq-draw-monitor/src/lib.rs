//! The Program and Source monitors on the shared draw UI (Swift `SQDrawMonitor`): the panel model, the panel itself
//! (an `AppHost`), the on-picture overlays, the Source monitor core, scopes and meters. See `README.md`.

pub mod angle_tile;
pub mod cg;
pub mod color_loupe;
pub mod create_tool_drag;
pub mod graphics_layer_overlay;
pub mod mask_handle_edit;
pub mod memory_defaults;
pub mod meter_panel;
pub mod monitor_drop_indicator;
pub mod monitor_drop_zone;
pub mod monitor_menus;
pub mod monitor_panel;
pub mod monitor_panel_model;
pub mod monitor_panel_overlays;
pub mod monitor_panel_picture_tools;
pub mod monitor_panel_source;
pub mod monitor_panel_source_drag;
pub mod monitor_panel_text;
pub mod monitor_text_field;
pub mod monitor_view_mapping;
pub mod monitor_zoom_step;
pub mod point_param_handles;
pub mod program_context_menu;
pub mod safe_zone_choice;
pub mod scope_image;
pub mod scope_trace_settings;
pub mod scopes_panel;
pub mod shortcut_tips;
pub mod slip_two_up;
pub mod source_monitor_core;
pub mod source_timeline_builder;
pub mod step_window_overlay;
pub mod text_hit_test;
pub mod transform_overlay;
pub mod transform_overlay_masks;
pub mod zoom_edit_overlay;

#[cfg(test)]
mod graphics_layer_tests;
#[cfg(test)]
mod meter_scopes_tests;
#[cfg(test)]
mod monitor_panel_tests;
#[cfg(test)]
mod picture_tools_tests;
#[cfg(test)]
mod source_monitor_core_tests;
#[cfg(test)]
mod test_support;

pub use graphics_layer_overlay::{GraphicsLayerOverlay, GraphicsLayerSource};
pub use meter_panel::MeterPanel;
pub use monitor_menus::MonitorMenus;
pub use monitor_panel::{HeaderControl, MonitorPanel, PanelEvent, PanelWiring, PictureToolsHost};
pub use monitor_panel_model::{MonitorEvent, MonitorPanelModel, MonitorWiring};
pub use safe_zone_choice::SafeZoneChoice;
pub use scope_image::ScopeImage;
pub use scope_trace_settings::ScopeTraceSettings;
pub use scopes_panel::{ScopeCountsSource, ScopeDrawer, ScopesPanel, install_gpu_drawer};
pub use source_monitor_core::{SourceCoreEvent, SourceMonitorCore};
pub use source_timeline_builder::SourceTimelineBuilder;
pub use transform_overlay::{OverlayEvent, TransformOverlay};
