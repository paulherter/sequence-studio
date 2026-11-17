//! The head of an opened curve (redesign frame: Value / Speed toggle, the ease chip row, the drag hint) drawn in the
//! left pane of the Graph row, next to the curve the lanes draw.

use std::collections::HashMap;

use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_core_model::{EaseReading, EasingCurveShape};
use sq_draw::Canvas;
use sq_draw::TextAlign;
use sq_draw::theme::{radius, type_size};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::keyframe_graph_geometry::GraphMode;
use sq_uikit::localization::SQL10n;

use super::effect_controls_draw_panel::{EffectControlsDrawPanel, Target};
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;

/// One control of the curve head.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphHead {
    Mode(GraphMode),
    Ease(KeyInterpolationChoice),
}

/// Left edge, rows (top of the toggle, top of the chips, top of the hint) and sizes of the head, in the row's points.
pub struct GraphHeadLayout;

impl GraphHeadLayout {
    pub const LEFT: f64 = 44.0;
    pub const MODE_TOP: f64 = 10.0;
    pub const CHIP_TOP: f64 = 40.0;
    pub const HINT_TOP: f64 = 66.0;
    pub const HEIGHT: f64 = 20.0;
    pub const GAP: f64 = 4.0;
    const MODE_WIDTH: f64 = 52.0;

    pub const CHIPS: [(KeyInterpolationChoice, &'static str); 4] = [
        (KeyInterpolationChoice::Linear, "Linear"),
        (KeyInterpolationChoice::EaseIn, "Ease In"),
        (KeyInterpolationChoice::EaseOut, "Ease Out"),
        (KeyInterpolationChoice::EasyEase, "Ease In & Out"),
    ];

    /// Text plus 7 pt on each side.
    const CHIP_PAD: f64 = 14.0;

    /// The key of a chip's measured text width in `EffectControlsDrawPanel::widths`.
    fn width_key(title: &str) -> String {
        format!("chip:{title}")
    }

    /// The chip's width: the text measured at the caption size by the last draw, the per-letter estimate before the
    /// first one (a hit test needs no canvas).
    fn chip_width(measured: Option<f64>, title: &str) -> f64 {
        measured.map_or_else(|| title.chars().count() as f64 * 5.8, f64::ceil).round() + Self::CHIP_PAD
    }

    /// The chip that matches the selected keys' common easing (none when they differ or fit no chip).
    pub fn active_chip(reading: Option<EaseReading>) -> Option<KeyInterpolationChoice> {
        let Some(EaseReading::Common(shape)) = reading else { return None };
        Self::CHIPS
            .iter()
            .map(|(choice, _)| *choice)
            .find(|choice| shape.is_approximately_equal(&choice.curve().shape()))
    }

    /// The Value and Speed segments.
    pub fn mode_frames() -> [(GraphMode, CGRect); 2] {
        [
            (GraphMode::Value, CGRect::new(Self::LEFT, Self::MODE_TOP, Self::MODE_WIDTH, Self::HEIGHT)),
            (
                GraphMode::Speed,
                CGRect::new(Self::LEFT + Self::MODE_WIDTH, Self::MODE_TOP, Self::MODE_WIDTH, Self::HEIGHT),
            ),
        ]
    }

    /// The four ease chips in a row.
    pub fn chip_frames(widths: &HashMap<String, f64>) -> Vec<(KeyInterpolationChoice, &'static str, CGRect)> {
        let mut x = Self::LEFT;
        Self::CHIPS
            .iter()
            .map(|(c, title)| {
                let shown = SQL10n::string(title);
                let w = Self::chip_width(widths.get(&Self::width_key(&shown)).copied(), &shown);
                let f = CGRect::new(x, Self::CHIP_TOP, w, Self::HEIGHT);
                x += w + Self::GAP;
                (*c, *title, f)
            })
            .collect()
    }

    /// The control under `l` (the row's points).
    pub fn hit(widths: &HashMap<String, f64>, l: CGPoint) -> Option<GraphHead> {
        if let Some((m, _)) = Self::mode_frames().into_iter().find(|(_, f)| f.contains(l)) {
            return Some(GraphHead::Mode(m));
        }
        Self::chip_frames(widths).into_iter().find(|(_, _, f)| f.contains(l)).map(|(c, _, _)| GraphHead::Ease(c))
    }
}

impl EffectControlsDrawPanel {
    pub(super) fn graph_head_target(&self, prop: &EffectProperty, l: CGPoint) -> Target {
        GraphHeadLayout::hit(&self.widths.borrow(), l).map_or(Target::None, |h| Target::GraphHead(prop.clone(), h))
    }

    pub(super) fn draw_graph_head(
        &self,
        model: &EffectControlsModel,
        prop: &EffectProperty,
        c: &mut Canvas,
        hover: &Target,
    ) {
        let t = self.theme;
        let fs = type_size::CAPTION as f64;
        let mode = model.graph_mode_for(prop);
        let track = CGRect::new(
            GraphHeadLayout::LEFT,
            GraphHeadLayout::MODE_TOP,
            GraphHeadLayout::MODE_WIDTH * 2.0,
            GraphHeadLayout::HEIGHT,
        );
        c.fill_rounded(track, radius::SMALL as f64, t.fill_hover());
        for (m, f) in GraphHeadLayout::mode_frames() {
            let on = m == mode;
            if on {
                c.fill_rounded(f.inset_by(1.0, 1.0), radius::SMALL as f64, t.fill_pressed());
            }
            let hot = *hover == Target::GraphHead(prop.clone(), GraphHead::Mode(m));
            let title = SQL10n::string(if m == GraphMode::Value { "Value" } else { "Speed" });
            let col = if on || hot { t.label() } else { t.label3() };
            c.draw_text_in(&title, f, fs, col, TextAlign::Center, 0.0, 0);
        }
        let enabled = !model.selection.is_empty();
        // Measure the chip titles at the caption size, so the frames and the hits follow the text.
        for (_, title) in GraphHeadLayout::CHIPS {
            let shown = SQL10n::string(title);
            let w = c.size_of(&shown, fs, 0).width;
            // No atlas (a canvas without fonts) measures 0: keep the estimate then.
            if w > 0.0 {
                self.widths.borrow_mut().insert(GraphHeadLayout::width_key(&shown), w);
            }
        }
        // The chip of the selected keys' common easing stays lit.
        let active = GraphHeadLayout::active_chip(model.ease_reading());
        let frames = GraphHeadLayout::chip_frames(&self.widths.borrow());
        for (choice, title, f) in frames {
            let hot = enabled && *hover == Target::GraphHead(prop.clone(), GraphHead::Ease(choice));
            let on = enabled && active == Some(choice);
            if on {
                c.fill_rounded(f, radius::SMALL as f64, t.fill_pressed());
            } else if hot {
                c.fill_rounded(f, radius::SMALL as f64, t.fill_hover());
            }
            let col = if hot || on { t.label() } else { t.label3() };
            let col = col.with_alpha(col.a * if enabled { 1.0 } else { 0.5 });
            c.draw_text_in(&SQL10n::string(title), f, fs, col, TextAlign::Center, 0.0, 0);
        }
        c.draw_text_in(
            &SQL10n::string("Or drag the handles for your own curve."),
            CGRect::new(
                GraphHeadLayout::LEFT,
                GraphHeadLayout::HINT_TOP,
                (self.size.width - GraphHeadLayout::LEFT - 8.0).max(0.0),
                14.0,
            ),
            fs,
            t.label4(),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    pub(super) fn click_graph_head(&mut self, model: &mut EffectControlsModel, prop: &EffectProperty, h: GraphHead) {
        match h {
            GraphHead::Mode(m) => model.set_graph_mode_for(m, prop),
            GraphHead::Ease(c) => model.apply_graph_ease(c),
        }
    }
}
