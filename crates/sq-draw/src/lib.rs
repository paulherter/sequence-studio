//! Foundation of the shared draw UI (Swift SQDrawKit): draw list, canvas, theme, glyph atlas, input, scroll physics,
//! the `Panel` trait and both renderers. Widgets live in the widget task.

pub mod canvas;
pub mod canvas_shapes;
pub mod close_x;
pub mod cursor_glyph;
pub mod display_gamma;
pub mod empty_pane;
pub mod draw_list;
pub mod experimental;
pub mod glyph_atlas;
pub mod hdr_present;
pub mod image_fit;
pub mod input;
pub mod inspector;
pub mod middle_fit;
pub mod monitor;
pub mod motion;
pub mod panel;
pub mod pointer;
pub mod scroll;
pub mod software;
pub mod spring;
pub mod stone;
pub mod stone_controls;
pub mod stone_rows;
pub mod text_log;
pub mod text_measure;
pub mod theme;
pub mod ui_cx;
pub mod wgpu_renderer;
pub mod zoom_scroll_bar_control;

pub use canvas::{Canvas, Probe};
pub use canvas_shapes::{IconOutline, PolygonSpanCache};
pub use draw_list::{Color, DrawList, DrawQuad, QuadKind, Rect};
pub use glyph_atlas::{GlyphAtlas, TextAlign};
pub use image_fit::{fill_source, fit_rect};
pub use input::{InputEvent, InputKey, InputModifiers};
pub use inspector::{
    Alignment, CheckState, ClickCounter, ColorPickerControl, Direction, InspectorColorRamp, InspectorDraw,
    InspectorTokens, ScreenColorSampler, ScrubFieldControl, TextEditState, TextFieldControl,
};
pub use panel::{A11y, Panel};
pub use software::{RgbaImage, SoftwareRenderer, Sources};
pub use text_measure::TextMeasure;
pub use theme::DrawTheme;
pub use ui_cx::UiCx;
pub use wgpu_renderer::WgpuRenderer;
pub use zoom_scroll_bar_control::ZoomScrollBarControl;
