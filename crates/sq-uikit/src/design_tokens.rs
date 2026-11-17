// Swift: DesignTokens.swift
//! The one place for the design values both UIs share (the shared draw-list UI on Mac and Windows). Portable: no AppKit.
//! Lengths are points, unscaled. Nothing else may repeat these numbers; the `golden_matches_swift_dump` test fails when a
//! value differs from the golden. The golden began as the Swift dump; the bar, header, ruler and track-head metrics now follow
//! the redesign tokens (`redesign_tokens::size`) and the golden carries those values.

/// Design tokens, grouped like Swift's `SQTokens` (`Metrics`, `Spacing`, ...).
pub mod sq_tokens {
    /// Control, bar and track sizes.
    pub mod metrics {
        pub const TOP_BAR: f32 = crate::redesign_tokens::size::TOP_BAR;
        pub const STATUS_BAR: f32 = crate::redesign_tokens::size::STATUS_BAR;
        pub const PANEL_HEADER: f32 = crate::redesign_tokens::size::PANEL_HEADER;
        pub const TRACK_V1: f32 = crate::redesign_tokens::size::TRACK_VIDEO;
        pub const TRACK_A1: f32 = crate::redesign_tokens::size::TRACK_AUDIO;
        pub const TRACK_OTHER: f32 = 20.0;
        pub const TRACK_HEADER: f32 = crate::redesign_tokens::size::TRACK_HEADER;
        pub const CAPSULE: f32 = 22.0;
        pub const MONITOR_HEADER: f32 = 32.0;
        pub const MONITOR_FOOTER: f32 = 66.0;
        pub const MONITOR_STRIP: f32 = 44.0;
        pub const MONITOR_SLIDER_MAX_WIDTH: f32 = 80.0;
        pub const MONITOR_SLIDER_HEIGHT: f32 = 14.0;
        pub const MONITOR_DIM_WIDTH: f32 = 22.0;
        pub const MONITOR_DIM_HEIGHT: f32 = 18.0;
        pub const SCRUB_BAR: f32 = 16.0;
        pub const SEQUENCE_TABS: f32 = 24.0;
        pub const RULER: f32 = crate::redesign_tokens::size::RULER;
        pub const CLIP_NAME_BAND: f32 = crate::redesign_tokens::size::CLIP_BAND;
        pub const PANE_DIVIDER: f32 = crate::redesign_tokens::size::SEAM;
        pub const PUSH_BUTTON: f32 = 22.0;
        pub const QUIET_BUTTON: f32 = 22.0;
        pub const QUIET_FIELD: f32 = 22.0;
        pub const BAR_CONTROL: f32 = 22.0;
    }

    pub mod spacing {
        pub const XXS: f32 = 2.0;
        pub const XS: f32 = 4.0;
        pub const SNUG: f32 = 6.0;
        pub const SM: f32 = 8.0;
        pub const MD: f32 = 12.0;
        pub const LG: f32 = 16.0;
        pub const WIDE: f32 = 20.0;
        pub const XL: f32 = 24.0;
        pub const XXL: f32 = 32.0;
    }

    /// Radii 4/6/8/10/12 (G4).
    pub mod radius {
        pub const NONE: f32 = 0.0;
        pub const PANEL: f32 = 4.0;
        pub const SMALL: f32 = 4.0;
        pub const CONTROL: f32 = 6.0;
        pub const OVERLAY: f32 = 8.0;
        pub const MENU: f32 = 10.0;
        pub const CARD: f32 = 12.0;
    }

    /// Control and list-row heights (G6).
    pub mod height {
        pub const COMPACT: f32 = 22.0;
        pub const NORMAL: f32 = 24.0;
        pub const LARGE: f32 = 28.0;
        pub const PANEL_LIST: f32 = 24.0;
    }

    /// Type ladder 10/11/12/13/15/18 (G3); clip names use the caption size.
    pub mod type_size {
        pub const CAPTION: f32 = 10.0;
        pub const BODY: f32 = 11.0;
        pub const LIST: f32 = 12.0;
        pub const TITLE: f32 = 13.0;
        pub const HEADING: f32 = 15.0;
        pub const DISPLAY: f32 = 18.0;
        pub const CLIP_NAME: f32 = CAPTION;
    }

    /// Alphas of the ink fills and lines, and of the timeline paints.
    pub mod alpha {
        pub const FILL_PRESSED: f64 = 0.22;
        pub const FILL2: f64 = 0.06;
        pub const SEPARATOR_STRONG: f64 = 0.11;
        pub const OVERLAY_EDGE: f64 = 0.12;
        pub const SWATCH_EDGE: f64 = 0.18;
        pub const RULER_MINOR: f64 = 0.16;
        pub const GUIDE: f64 = 0.55;
        pub const VIEWER_HUD: f64 = 0.55;
        pub const PLATFORM_MOCK: f64 = 0.62;
        pub const ON_PICTURE_SHADOW: f64 = 0.5;
        pub const CLIP_SHADE: f64 = 0.22;
        pub const CLIP_EDGE: f64 = 0.22;
        pub const THUMB_RULE: f64 = 0.35;
        pub const IN_OUT_BAND: f64 = 0.13;
        pub const IN_OUT_BAND_EDGE: f64 = 0.38;
        pub const CACHE_STRIP: f64 = 0.6;
        pub const TRANSITION_ISSUE: f64 = 0.55;
        pub const BADGE_FILL: f64 = 0.95;
        pub const BADGE_EDGE: f64 = 0.6;
        pub const HEAD_OUTLINE_LIGHT: f64 = 0.75;
        pub const FIELD_EDGE_HOVER: f64 = 0.18;
        pub const OVERLAY_EDGE_WIDTH: f64 = 0.5;
    }

    /// Artifact ink alphas (dark / light): current.
    pub mod line {
        pub const CURRENT_DARK: f64 = 0.08;
        pub const CURRENT_LIGHT: f64 = 0.07;
    }

    /// Fixed colors, 0xRRGGBB.
    pub mod hex {
        pub const THUMB_WELL: u32 = 0x2A2A2A;
        pub const OFFLINE_CLIP: u32 = 0x5A1F1C;
        pub const OFFLINE_TEXT: u32 = 0xFF8A80;
        pub const GREEN: u32 = 0x30D158;
        pub const GUIDE_SNAP: u32 = 0xFF4099;
        pub const HEAD_TOP: u32 = 0xFFFFFF;
        pub const HEAD_BOTTOM: u32 = 0xC3C9D9;
    }

    pub mod timeline {
        pub const SELECTION_OUTLINE_WIDTH: f64 = 1.5;
        pub const HEAD_SIZE: f64 = 12.0;
    }
}

#[cfg(test)]
mod tests {
    use super::sq_tokens::*;

    /// One `group.NAME=value` line per token, the format of `oracle/sq-uikit/golden/design-tokens.txt`.
    fn dump() -> String {
        let mut s = String::new();
        s.push_str(&format!("metrics.TOP_BAR={:?}\n", metrics::TOP_BAR));
        s.push_str(&format!("metrics.STATUS_BAR={:?}\n", metrics::STATUS_BAR));
        s.push_str(&format!("metrics.PANEL_HEADER={:?}\n", metrics::PANEL_HEADER));
        s.push_str(&format!("metrics.TRACK_V1={:?}\n", metrics::TRACK_V1));
        s.push_str(&format!("metrics.TRACK_A1={:?}\n", metrics::TRACK_A1));
        s.push_str(&format!("metrics.TRACK_OTHER={:?}\n", metrics::TRACK_OTHER));
        s.push_str(&format!("metrics.TRACK_HEADER={:?}\n", metrics::TRACK_HEADER));
        s.push_str(&format!("metrics.CAPSULE={:?}\n", metrics::CAPSULE));
        s.push_str(&format!("metrics.MONITOR_HEADER={:?}\n", metrics::MONITOR_HEADER));
        s.push_str(&format!("metrics.MONITOR_FOOTER={:?}\n", metrics::MONITOR_FOOTER));
        s.push_str(&format!("metrics.MONITOR_STRIP={:?}\n", metrics::MONITOR_STRIP));
        s.push_str(&format!("metrics.MONITOR_SLIDER_MAX_WIDTH={:?}\n", metrics::MONITOR_SLIDER_MAX_WIDTH));
        s.push_str(&format!("metrics.MONITOR_SLIDER_HEIGHT={:?}\n", metrics::MONITOR_SLIDER_HEIGHT));
        s.push_str(&format!("metrics.MONITOR_DIM_WIDTH={:?}\n", metrics::MONITOR_DIM_WIDTH));
        s.push_str(&format!("metrics.MONITOR_DIM_HEIGHT={:?}\n", metrics::MONITOR_DIM_HEIGHT));
        s.push_str(&format!("metrics.SCRUB_BAR={:?}\n", metrics::SCRUB_BAR));
        s.push_str(&format!("metrics.SEQUENCE_TABS={:?}\n", metrics::SEQUENCE_TABS));
        s.push_str(&format!("metrics.RULER={:?}\n", metrics::RULER));
        s.push_str(&format!("metrics.CLIP_NAME_BAND={:?}\n", metrics::CLIP_NAME_BAND));
        s.push_str(&format!("metrics.PANE_DIVIDER={:?}\n", metrics::PANE_DIVIDER));
        s.push_str(&format!("metrics.PUSH_BUTTON={:?}\n", metrics::PUSH_BUTTON));
        s.push_str(&format!("metrics.QUIET_BUTTON={:?}\n", metrics::QUIET_BUTTON));
        s.push_str(&format!("metrics.QUIET_FIELD={:?}\n", metrics::QUIET_FIELD));
        s.push_str(&format!("metrics.BAR_CONTROL={:?}\n", metrics::BAR_CONTROL));
        s.push_str(&format!("spacing.XXS={:?}\n", spacing::XXS));
        s.push_str(&format!("spacing.XS={:?}\n", spacing::XS));
        s.push_str(&format!("spacing.SNUG={:?}\n", spacing::SNUG));
        s.push_str(&format!("spacing.SM={:?}\n", spacing::SM));
        s.push_str(&format!("spacing.MD={:?}\n", spacing::MD));
        s.push_str(&format!("spacing.LG={:?}\n", spacing::LG));
        s.push_str(&format!("spacing.WIDE={:?}\n", spacing::WIDE));
        s.push_str(&format!("spacing.XL={:?}\n", spacing::XL));
        s.push_str(&format!("spacing.XXL={:?}\n", spacing::XXL));
        s.push_str(&format!("radius.NONE={:?}\n", radius::NONE));
        s.push_str(&format!("radius.PANEL={:?}\n", radius::PANEL));
        s.push_str(&format!("radius.SMALL={:?}\n", radius::SMALL));
        s.push_str(&format!("radius.CONTROL={:?}\n", radius::CONTROL));
        s.push_str(&format!("radius.OVERLAY={:?}\n", radius::OVERLAY));
        s.push_str(&format!("radius.MENU={:?}\n", radius::MENU));
        s.push_str(&format!("radius.CARD={:?}\n", radius::CARD));
        s.push_str(&format!("height.COMPACT={:?}\n", height::COMPACT));
        s.push_str(&format!("height.NORMAL={:?}\n", height::NORMAL));
        s.push_str(&format!("height.LARGE={:?}\n", height::LARGE));
        s.push_str(&format!("height.PANEL_LIST={:?}\n", height::PANEL_LIST));
        s.push_str(&format!("type_size.CAPTION={:?}\n", type_size::CAPTION));
        s.push_str(&format!("type_size.BODY={:?}\n", type_size::BODY));
        s.push_str(&format!("type_size.LIST={:?}\n", type_size::LIST));
        s.push_str(&format!("type_size.TITLE={:?}\n", type_size::TITLE));
        s.push_str(&format!("type_size.HEADING={:?}\n", type_size::HEADING));
        s.push_str(&format!("type_size.DISPLAY={:?}\n", type_size::DISPLAY));
        s.push_str(&format!("type_size.CLIP_NAME={:?}\n", type_size::CLIP_NAME));
        s.push_str(&format!("alpha.FILL_PRESSED={:?}\n", alpha::FILL_PRESSED));
        s.push_str(&format!("alpha.FILL2={:?}\n", alpha::FILL2));
        s.push_str(&format!("alpha.SEPARATOR_STRONG={:?}\n", alpha::SEPARATOR_STRONG));
        s.push_str(&format!("alpha.OVERLAY_EDGE={:?}\n", alpha::OVERLAY_EDGE));
        s.push_str(&format!("alpha.SWATCH_EDGE={:?}\n", alpha::SWATCH_EDGE));
        s.push_str(&format!("alpha.RULER_MINOR={:?}\n", alpha::RULER_MINOR));
        s.push_str(&format!("alpha.GUIDE={:?}\n", alpha::GUIDE));
        s.push_str(&format!("alpha.VIEWER_HUD={:?}\n", alpha::VIEWER_HUD));
        s.push_str(&format!("alpha.PLATFORM_MOCK={:?}\n", alpha::PLATFORM_MOCK));
        s.push_str(&format!("alpha.ON_PICTURE_SHADOW={:?}\n", alpha::ON_PICTURE_SHADOW));
        s.push_str(&format!("alpha.CLIP_SHADE={:?}\n", alpha::CLIP_SHADE));
        s.push_str(&format!("alpha.CLIP_EDGE={:?}\n", alpha::CLIP_EDGE));
        s.push_str(&format!("alpha.THUMB_RULE={:?}\n", alpha::THUMB_RULE));
        s.push_str(&format!("alpha.IN_OUT_BAND={:?}\n", alpha::IN_OUT_BAND));
        s.push_str(&format!("alpha.IN_OUT_BAND_EDGE={:?}\n", alpha::IN_OUT_BAND_EDGE));
        s.push_str(&format!("alpha.CACHE_STRIP={:?}\n", alpha::CACHE_STRIP));
        s.push_str(&format!("alpha.TRANSITION_ISSUE={:?}\n", alpha::TRANSITION_ISSUE));
        s.push_str(&format!("alpha.BADGE_FILL={:?}\n", alpha::BADGE_FILL));
        s.push_str(&format!("alpha.BADGE_EDGE={:?}\n", alpha::BADGE_EDGE));
        s.push_str(&format!("alpha.HEAD_OUTLINE_LIGHT={:?}\n", alpha::HEAD_OUTLINE_LIGHT));
        s.push_str(&format!("alpha.FIELD_EDGE_HOVER={:?}\n", alpha::FIELD_EDGE_HOVER));
        s.push_str(&format!("alpha.OVERLAY_EDGE_WIDTH={:?}\n", alpha::OVERLAY_EDGE_WIDTH));
        s.push_str(&format!("line.CURRENT_DARK={:?}\n", line::CURRENT_DARK));
        s.push_str(&format!("line.CURRENT_LIGHT={:?}\n", line::CURRENT_LIGHT));
        s.push_str(&format!("hex.THUMB_WELL={:?}\n", hex::THUMB_WELL));
        s.push_str(&format!("hex.OFFLINE_CLIP={:?}\n", hex::OFFLINE_CLIP));
        s.push_str(&format!("hex.OFFLINE_TEXT={:?}\n", hex::OFFLINE_TEXT));
        s.push_str(&format!("hex.GREEN={:?}\n", hex::GREEN));
        s.push_str(&format!("hex.GUIDE_SNAP={:?}\n", hex::GUIDE_SNAP));
        s.push_str(&format!("hex.HEAD_TOP={:?}\n", hex::HEAD_TOP));
        s.push_str(&format!("hex.HEAD_BOTTOM={:?}\n", hex::HEAD_BOTTOM));
        s.push_str(&format!("timeline.SELECTION_OUTLINE_WIDTH={:?}\n", timeline::SELECTION_OUTLINE_WIDTH));
        s.push_str(&format!("timeline.HEAD_SIZE={:?}\n", timeline::HEAD_SIZE));
        s
    }

    #[test]
    fn golden_matches_swift_dump() {
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/sq-uikit/golden/design-tokens.txt");
        let golden = std::fs::read_to_string(path).unwrap_or_default();
        assert_eq!(dump(), golden);
    }

    #[test]
    fn current_line_alphas_match_the_artifact() {
        assert_eq!((line::CURRENT_DARK, line::CURRENT_LIGHT), (0.08, 0.07));
    }
}
