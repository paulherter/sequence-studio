// Swift: ControlsMetrics.swift
//! Controls panel geometry, from the design source (`.grp`, `.fx`, `.kp`, `.kr`, `.epane`, `.eg`).

/// One place for the property column and the keyframe lanes, so a row on the left is exactly as tall as its lane on the
/// right. The row heights are portable (the layout of `EffectControlsModel` reads them on Windows too).
pub enum ControlsMetrics {}

impl ControlsMetrics {
    /// Space between two sections: none, v9 stacks the section rows on the row pitch (`.ksec`).
    pub const SECTION_GAP: f64 = 0.0;
    /// The crossover strip of the multiband compressor in the Audio section (`MultibandEditor.rowHeight`).
    pub const MULTIBAND_ROW: f64 = 32.0;
    pub const CLIP_LINE: f64 = Portable::CLIP_LINE;
    pub const HEADER: f64 = Portable::HEADER;
    pub const GROUP: f64 = Portable::GROUP;
    pub const SECTION: f64 = Portable::SECTION;
    pub const PARAMETER: f64 = Portable::PARAMETER;
    pub const TALL_PARAMETER: f64 = Portable::PARAMETER;
    pub const GRAPH: f64 = Portable::GRAPH;

    /// Key glyphs in the lanes (v9 `.dm`): a 9 pt square with 1.5 pt corners turned 45 degrees (linear), a 10 pt
    /// circle (eased), a 9 pt square (hold); each with a 1.5 pt ring in the lane color.
    pub const KEY_SIDE: f64 = 9.0;
    pub const KEY_RING: f64 = 1.5;
    /// The animate toggle of a parameter row (v9 `.kfb`): a smaller diamond than the lane keys.
    pub const TOGGLE_SIDE: f64 = 7.0;
    /// A Magic mask's tracked frame in the lanes: this share of `KEY_SIDE` (`Theme.Colors.keyframeTracked`).
    pub const TRACKED_KEY_SCALE: f64 = 0.6;
}

/// The Mac `Theme` values at UI scale 1.
// shortcut: fixed values mirror the Mac Theme; upgrade when the draw theme owns the Inspector row heights.
pub enum Portable {}

impl Portable {
    pub const CLIP_LINE: f64 = 30.0;
    pub const HEADER: f64 = 24.0;
    pub const GROUP: f64 = 24.0;
    pub const SECTION: f64 = 24.0;
    pub const PARAMETER: f64 = 24.0;
    pub const GRAPH: f64 = 120.0;
    /// `Theme.Inspector.popupWidth`: Blend Mode and choice popups.
    pub const POPUP_WIDTH: f64 = 120.0;
}

/// The Parametric EQ's "Curve" group key and the height of its open curve (EffectControlsEQ.swift).
pub const EQ_CURVE_KEY: &str = "eq-curve";
pub const EQ_CURVE_HEIGHT: f64 = 170.0;
