// Swift: PanelID.swift
//! Identifiers of the dock panels.

use serde::{Deserialize, Serialize};

/// A dock panel. Coded as its camelCase name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PanelID {
    EffectControls,
    Text,
    ProgramMonitor,
    SourceMonitor,
    Library,
    Effects,
    Project,
    Timeline,
    /// The tool column left of the timeline (Select, Razor, Slip, Create, Mask, Type).
    Tools,
    /// Level meter right of the timeline (Premiere's audio meters).
    AudioMeter,
    /// Color page panels (also available from the Window menu on the Edit page).
    ColorInspector,
    Scopes,
    /// The Sources panel of the Color page (the id predates the rename): source tiles, grade state, copy/paste. A dock
    /// tab of the Color layouts only.
    ColorClips,
    /// The Steps graph (Pro grade) of the Color page. A dock tab of the Color layouts only.
    Steps,
    /// Layer list and properties of the selected graphics clip (design layer).
    Graphics,
    /// The marker list: every sequence and clip marker, filter, click to go there (Window > Marker List).
    MarkerList,
}

impl PanelID {
    /// Every panel, in declaration order.
    pub const ALL: [PanelID; 16] = [
        PanelID::EffectControls,
        PanelID::Text,
        PanelID::ProgramMonitor,
        PanelID::SourceMonitor,
        PanelID::Library,
        PanelID::Effects,
        PanelID::Project,
        PanelID::Timeline,
        PanelID::Tools,
        PanelID::AudioMeter,
        PanelID::ColorInspector,
        PanelID::Scopes,
        PanelID::ColorClips,
        PanelID::Steps,
        PanelID::Graphics,
        PanelID::MarkerList,
    ];

    /// The stored name (the camelCase case name).
    pub fn raw_value(self) -> &'static str {
        match self {
            PanelID::EffectControls => "effectControls",
            PanelID::Text => "text",
            PanelID::ProgramMonitor => "programMonitor",
            PanelID::SourceMonitor => "sourceMonitor",
            PanelID::Library => "library",
            PanelID::Effects => "effects",
            PanelID::Project => "project",
            PanelID::Timeline => "timeline",
            PanelID::Tools => "tools",
            PanelID::AudioMeter => "audioMeter",
            PanelID::ColorInspector => "colorInspector",
            PanelID::Scopes => "scopes",
            PanelID::ColorClips => "colorClips",
            PanelID::Steps => "steps",
            PanelID::Graphics => "graphics",
            PanelID::MarkerList => "markerList",
        }
    }

    /// Height of a tab strip above every group (DESIGN: panel header). Unscaled; the shared UI scales it with the theme.
    pub const HEADER_HEIGHT: f64 = 30.0;

    /// Smallest size the panel is laid out at (width, height in points), below the tab strip.
    /// Layouts never squeeze a panel under this; the window minimum is derived from it.
    pub fn min_size(self) -> (f64, f64) {
        match self {
            PanelID::Timeline => (320.0, 150.0),
            PanelID::Tools => (36.0, 150.0),
            PanelID::AudioMeter => (56.0, 100.0),
            PanelID::ProgramMonitor | PanelID::SourceMonitor => (380.0, 200.0),
            PanelID::EffectControls => (360.0, 120.0),
            PanelID::Text => (240.0, 140.0),
            PanelID::Library => (232.0, 120.0),
            PanelID::Effects => (180.0, 100.0),
            PanelID::Project => (200.0, 100.0),
            PanelID::ColorInspector => (260.0, 160.0),
            PanelID::ColorClips => (140.0, 100.0),
            PanelID::Steps => (240.0, 120.0),
            PanelID::Scopes => (200.0, 120.0),
            PanelID::Graphics => (240.0, 160.0),
            PanelID::MarkerList => (260.0, 120.0),
        }
    }

    /// The panels a layout tree can hold (everything but the Color page's Sources and Steps).
    pub fn dockable() -> Vec<PanelID> {
        Self::ALL.into_iter().filter(|p| *p != PanelID::ColorClips && *p != PanelID::Steps).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A Controls row with two value fields and key navigation (Position, Anchor) fits at the panel's minimum width.
    #[test]
    fn controls_min_width_holds_a_two_value_row_with_navigation() {
        let grid = crate::controls_grid::ControlsGrid::new(PanelID::EffectControls.min_size().0);
        let second_field_end =
            crate::controls_grid::ControlsGrid::value_column(1) + crate::controls_grid::ControlsGrid::VALUE_WIDTH;
        assert!(second_field_end <= grid.value_max_x(), "{second_field_end} > {}", grid.value_max_x());
    }

    #[test]
    fn dockable_leaves_out_the_color_page_tabs() {
        let d = PanelID::dockable();
        assert_eq!(d.len(), 14);
        assert!(!d.contains(&PanelID::Steps) && !d.contains(&PanelID::ColorClips));
    }

    #[test]
    fn coded_as_camel_case_names() {
        assert_eq!(serde_json::to_string(&PanelID::ProgramMonitor).ok().as_deref(), Some("\"programMonitor\""));
        assert_eq!(serde_json::from_str::<PanelID>("\"markerList\"").ok(), Some(PanelID::MarkerList));
        for p in PanelID::ALL {
            assert_eq!(serde_json::to_string(&p).ok(), Some(format!("\"{}\"", p.raw_value())));
        }
        assert_eq!(PanelID::Timeline.min_size(), (320.0, 150.0));
        assert_eq!((PanelID::Tools.min_size().0, PanelID::AudioMeter.min_size().0), (36.0, 56.0));
    }
}
