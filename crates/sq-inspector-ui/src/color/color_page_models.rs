// Swift: Color/ColorPageModels.swift
//! Portable value types of the Color page, shared by the Mac views and the shared draw-list Color page.

use super::color_inspector_model::ColorParam;
use sq_core_color::{ClipGradeExt, ClipGradeLinksExt};
use sq_core_edit::color_grade_targets::{ClipGradeTargetsExt, ProjectGradeTargetsExt};
use sq_core_effects::adjustment_clip::ClipAdjustmentExt;
use sq_core_model::{Clip, ColorEffect, ColorSectionKind, Project, SequenceFormat, Timeline, TrackKind};
use sq_core_time::{Id, Time};

/// What the Color panel grades, described (built by the panel from its target): its name, whether it shares its
/// source's grade, and what the monitor shows instead of it.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ColorTargetBarContent {
    pub title: String,
    /// nil = no Linked toggle (a source with one cut, adjustment layers, the whole sequence).
    pub linked: Option<bool>,
    /// "On screen: X" when the monitor shows another clip than the target.
    pub on_screen: Option<String>,
}

impl ColorTargetBarContent {
    pub fn new(title: &str) -> ColorTargetBarContent {
        ColorTargetBarContent { title: title.to_string(), linked: None, on_screen: None }
    }

    /// A clip: while Linked it stands for its source file (named by the file), else for itself. The Linked toggle shows
    /// only when the source has more than one cut in the project.
    pub fn clip(c: &Clip, project: &Project) -> ColorTargetBarContent {
        if !c.is_source_gradeable() {
            return ColorTargetBarContent::new(&c.name);
        }
        let mut cuts = 0;
        for t in project.timelines.iter() {
            for tr in t.tracks.iter() {
                cuts += tr.clips().iter().filter(|x| x.media == c.media && x.is_source_gradeable()).count();
            }
        }
        let linked = project.is_grade_linked_to_source(c.id);
        let file = project.media.iter().find(|m| m.id == c.media).map(|m| m.name.as_str());
        let title = if linked { file.unwrap_or(&c.name).to_string() } else { c.name.clone() };
        ColorTargetBarContent {
            title,
            linked: if cuts > 1 || c.grade_independent() { Some(linked) } else { None },
            on_screen: None,
        }
    }

    pub fn whole_sequence(_t: &Timeline) -> ColorTargetBarContent {
        ColorTargetBarContent::new("Whole sequence")
    }
}

/// The shape of the sequence the Color page lays itself out for (DECISIONS 2026-10-03 "Color grading UI").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorPageFormat {
    Landscape,
    Portrait,
    Square,
}

impl ColorPageFormat {
    /// Square when the sides differ by under 5 %, portrait when taller than wide, else landscape.
    pub fn from_size(width: i64, height: i64) -> ColorPageFormat {
        if width <= 0 || height <= 0 {
            return ColorPageFormat::Landscape;
        }
        let r = width as f64 / height as f64;
        if (0.95..=1.05).contains(&r) {
            ColorPageFormat::Square
        } else if height > width {
            ColorPageFormat::Portrait
        } else {
            ColorPageFormat::Landscape
        }
    }

    pub fn from_format(f: Option<&SequenceFormat>) -> ColorPageFormat {
        f.map_or(ColorPageFormat::Landscape, |f| Self::from_size(f.width, f.height))
    }

    /// Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ColorPageFormat::Landscape => "landscape",
            ColorPageFormat::Portrait => "portrait",
            ColorPageFormat::Square => "square",
        }
    }
}

/// How often a source is used in the sequence ("1 use", "3 uses"), as the Clips strip and the Color header show it.
pub struct ColorUses;

impl ColorUses {
    pub fn text(n: i64) -> String {
        if n == 1 { "1 use".to_string() } else { format!("{n} uses") }
    }

    /// The line under a tile's name: the uses, then the grade state ("2 uses \u{00B7} Pro", "1 use \u{00B7} No grade").
    pub fn tile_line(n: i64, grade: &str) -> String {
        format!("{} \u{00B7} {}", Self::text(n), grade)
    }
}

/// What the viewer of the Color page shows: the graded picture, the ungraded one, or both side by side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorCompareMode {
    Before,
    After,
    Split,
}

impl ColorCompareMode {
    /// Swift `allCases`.
    pub const ALL: [ColorCompareMode; 3] = [ColorCompareMode::Before, ColorCompareMode::After, ColorCompareMode::Split];

    pub fn title(self) -> &'static str {
        match self {
            ColorCompareMode::Before => "Before",
            ColorCompareMode::After => "After",
            ColorCompareMode::Split => "Split",
        }
    }

    /// The mode's name in the Color panel's Layout menu.
    pub fn layout_title(self) -> &'static str {
        match self {
            ColorCompareMode::After => "Single",
            ColorCompareMode::Before => "Before",
            ColorCompareMode::Split => "Before and after",
        }
    }
}

/// What the viewer header of the Color page names (pure, tested): the clip being graded and its place among the
/// picture clips of the sequence ("4 of 6", in timeline order: start, then the upper track first).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ColorViewerHeaderContent {
    pub name: String,
    /// "n of m"; nil for the sequence-wide grade, an adjustment layer or no target.
    pub position: Option<String>,
}

impl ColorViewerHeaderContent {
    /// The picture clips of `timeline` that take a grade of their own, in timeline order.
    pub fn clips(timeline: &Timeline) -> Vec<&Clip> {
        let mut cuts: Vec<(Time, i64, &Clip)> = Vec::new();
        for (k, tr) in timeline.tracks.iter().enumerate() {
            if tr.kind != TrackKind::Video {
                continue;
            }
            for c in tr.clips() {
                if c.accepts_color() && !c.is_sequence_grade() && !c.is_adjustment() {
                    cuts.push((c.start, -(k as i64), c));
                }
            }
        }
        cuts.sort_by(|a, b| if a.0 != b.0 { a.0.cmp(&b.0) } else { a.1.cmp(&b.1) });
        cuts.into_iter().map(|c| c.2).collect()
    }

    pub fn make(
        target: &super::color_grade_target::ColorTargetResolution,
        timeline: Option<&Timeline>,
    ) -> ColorViewerHeaderContent {
        use super::color_grade_target::ColorTargetResolution as R;
        let Some(timeline) = timeline else { return ColorViewerHeaderContent::default() };
        match target {
            R::Message(_) => ColorViewerHeaderContent { name: timeline.name.clone(), position: None },
            R::Sequence { .. } => ColorViewerHeaderContent { name: "Whole sequence".to_string(), position: None },
            R::Clip(id) => {
                let all = Self::clips(timeline);
                if let Some(i) = all.iter().position(|c| c.id == *id) {
                    return ColorViewerHeaderContent {
                        name: all[i].name.clone(),
                        position: Some(format!("{} of {}", i + 1, all.len())),
                    };
                }
                let c = timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == *id);
                ColorViewerHeaderContent { name: c.map_or(timeline.name.clone(), |c| c.name.clone()), position: None }
            }
        }
    }
}

/// Number texts of the Color rows (the Mac `ColorParamRow` and the draw-list Color page).
pub struct ColorValueText;

impl ColorValueText {
    /// How a value reads in the value column (version 9): the bare number, no plus sign and no unit ("8", "-18", "100").
    pub fn text(v: f64, decimals: i64) -> String {
        let d = decimals.max(0) as usize;
        let step = 10f64.powi(decimals as i32);
        let r = (v * step).round() / step;
        if r == 0.0 { format!("{:.d$}", 0.0) } else { format!("{r:.d$}") }
    }

    /// The text while typing: the value at the row's full precision, without trailing zeros ("8.4", "8").
    pub fn edit_text(v: f64, decimals: i64) -> String {
        let mut s = Self::text(v, decimals);
        if !s.contains('.') {
            return s;
        }
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
        if s == "-0" { "0".to_string() } else { s }
    }

    /// The summary of a folded section carries the sign ("+8", "-18", "0").
    pub fn signed_text(v: f64, decimals: i64) -> String {
        let s = Self::text(v, decimals);
        if v > 0.0 && s.parse::<f64>().ok() != Some(0.0) { format!("+{s}") } else { s }
    }

    /// Decimals the value column shows: whole numbers on the wide ranges (version 9), the row's own on the fine ones
    /// (Exposure in stops, the Step values). The slider, the scrub and typing keep the row's precision.
    pub fn shown_decimals(range: (f32, f32), decimals: i64) -> i64 {
        if range.1 - range.0 >= 100.0 { 0 } else { decimals }
    }

    /// Reads what `text` writes (and plain typed numbers).
    pub fn number(s: &str) -> Option<f64> {
        let t = s.replace('\u{2212}', "-").replace('%', "").replace(',', ".");
        let t = t.trim_matches(|c| c == ' ' || c == '\t');
        t.strip_prefix('+').unwrap_or(t).parse::<f64>().ok()
    }
}

/// Section order and folded-section texts of the Simple grade (the Mac `ColorInspectorView`, the draw-list page).
pub struct ColorSectionText;

impl ColorSectionText {
    /// Display order (design board Color): Basic, Look, Curves, Wheels & Match, Color Range, Vignette.
    pub const ORDER: [ColorSectionKind; 7] = [
        ColorSectionKind::BasicCorrection,
        ColorSectionKind::Creative,
        ColorSectionKind::Curves,
        ColorSectionKind::Wheels,
        ColorSectionKind::ZoneBoard,
        ColorSectionKind::HslSecondary,
        ColorSectionKind::Vignette,
    ];

    /// What a folded section reads at its right end (version 9: "Temp +8, Exposure 0", "Vibrance +10, Saturation 100",
    /// "Luma", "Shadows, Midtones, Highlights", "Off").
    pub fn summary(kind: ColorSectionKind, channel: i64, e: &ColorEffect) -> String {
        let n = |p: ColorParam| -> String {
            let v = f64::from(p.read(e));
            let d = ColorValueText::shown_decimals(p.range(), p.decimals());
            if p.neutral() == 0.0 { ColorValueText::signed_text(v, d) } else { ColorValueText::text(v, d) }
        };
        match kind {
            ColorSectionKind::BasicCorrection => {
                format!("Temp {}, Exposure {}", n(ColorParam::Temperature), n(ColorParam::Exposure))
            }
            ColorSectionKind::Creative => {
                format!(
                    "Vibrance {}, Saturation {}",
                    n(ColorParam::CreativeVibrance),
                    n(ColorParam::CreativeSaturation)
                )
            }
            ColorSectionKind::Vignette => {
                if ColorParam::VignetteAmount.read(e) == 0.0 {
                    "Off".to_string()
                } else {
                    format!("Amount {}", n(ColorParam::VignetteAmount))
                }
            }
            ColorSectionKind::Curves => ["Luma", "Red", "Green", "Blue"][channel.clamp(0, 3) as usize].to_string(),
            ColorSectionKind::Wheels => "Shadows, Midtones, Highlights".to_string(),
            ColorSectionKind::HslSecondary => (if e.hsl_secondary.is_none() { "Off" } else { "On" }).to_string(),
            ColorSectionKind::ZoneBoard => {
                (if e.zone_board.is_none_or(|b| b.is_neutral()) { "Off" } else { "On" }).to_string()
            }
        }
    }
}

/// Keeps the `Id` import used by callers that build target keys from here.
pub type ClipId = Id;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_format_follows_the_aspect() {
        assert_eq!(ColorPageFormat::from_size(1920, 1080), ColorPageFormat::Landscape);
        assert_eq!(ColorPageFormat::from_size(1080, 1920), ColorPageFormat::Portrait);
        assert_eq!(ColorPageFormat::from_size(1000, 1020), ColorPageFormat::Square);
        assert_eq!(ColorPageFormat::from_size(0, 10), ColorPageFormat::Landscape);
        assert_eq!(ColorPageFormat::from_format(None), ColorPageFormat::Landscape);
    }

    #[test]
    fn uses_text() {
        assert_eq!(ColorUses::text(1), "1 use");
        assert_eq!(ColorUses::text(3), "3 uses");
        assert_eq!(ColorUses::tile_line(2, "Pro"), "2 uses \u{00B7} Pro");
    }

    #[test]
    fn value_text_has_no_plus_and_no_negative_zero() {
        assert_eq!(ColorValueText::text(8.0, 0), "8");
        assert_eq!(ColorValueText::text(-0.04, 1), "0.0");
        assert_eq!(ColorValueText::text(-18.0, 0), "-18");
        assert_eq!(ColorValueText::signed_text(8.0, 0), "+8");
        assert_eq!(ColorValueText::signed_text(0.04, 1), "0.0");
        assert_eq!(ColorValueText::signed_text(-18.0, 0), "-18");
    }

    #[test]
    fn edit_text_drops_trailing_zeros() {
        assert_eq!(ColorValueText::edit_text(8.4, 2), "8.4");
        assert_eq!(ColorValueText::edit_text(8.0, 2), "8");
        assert_eq!(ColorValueText::edit_text(-0.001, 2), "0");
        assert_eq!(ColorValueText::edit_text(100.0, 0), "100");
    }

    #[test]
    fn typed_numbers_accept_the_display_forms() {
        assert_eq!(ColorValueText::number("+8"), Some(8.0));
        assert_eq!(ColorValueText::number("\u{2212}3,5"), Some(-3.5));
        assert_eq!(ColorValueText::number(" 12% "), Some(12.0));
        assert_eq!(ColorValueText::number("x"), None);
    }

    #[test]
    fn shown_decimals_are_whole_on_wide_ranges() {
        assert_eq!(ColorValueText::shown_decimals((-100.0, 100.0), 1), 0);
        assert_eq!(ColorValueText::shown_decimals((-5.0, 5.0), 2), 2);
    }

    #[test]
    fn section_summaries() {
        let mut e = ColorEffect::default();
        e.basic.temperature = 8.0;
        assert_eq!(ColorSectionText::summary(ColorSectionKind::BasicCorrection, 0, &e), "Temp +8, Exposure 0.00");
        assert_eq!(ColorSectionText::summary(ColorSectionKind::Creative, 0, &e), "Vibrance 0, Saturation 100");
        assert_eq!(ColorSectionText::summary(ColorSectionKind::Vignette, 0, &e), "Off");
        assert_eq!(ColorSectionText::summary(ColorSectionKind::Curves, 9, &e), "Blue");
        assert_eq!(ColorSectionText::summary(ColorSectionKind::HslSecondary, 0, &e), "Off");
        assert_eq!(ColorSectionText::summary(ColorSectionKind::ZoneBoard, 0, &e), "Off");
    }

    #[test]
    fn compare_titles() {
        assert_eq!(ColorCompareMode::Split.layout_title(), "Before and after");
        assert_eq!(ColorCompareMode::After.layout_title(), "Single");
    }
}
