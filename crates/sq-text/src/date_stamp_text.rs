// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DateStampText.swift
//! Bridge from a Date Stamp layer (`GeneratorRef.dateStamp`, SQCore) to the one text renderer: the stamp is an ordinary text
//! generator (area text covering the canvas inside the margin, aligned to the chosen corner), so it rasterizes, caches and
//! composites exactly like a title, in playback and in export.

use crate::text_generator::TextGenerator;
use crate::text_style::{FontWeight, RGBAColor, TextAlignment, TextBox, TextShadow, TextStyle, TextVerticalAlignment};
use crate::text_template::TextTemplate;
use sq_core_graphics::date_stamp::{DateStamp, DateStampCorner, DateStampSpec};
use sq_core_model::GeneratorRef;

/// Namespace of the Date Stamp functions.
pub enum DateStampText {}

impl DateStampText {
    /// The stamp's font.
    pub const FONT_NAME: &'static str = "Menlo-Bold";

    /// The text template of a Date Stamp layer.
    pub fn template(spec: &DateStampSpec) -> TextTemplate {
        let margin = (spec.canvas_height as f64 * DateStamp::MARGIN_SHARE).round();
        let right = spec.corner == DateStampCorner::BottomRight || spec.corner == DateStampCorner::TopRight;
        let bottom = spec.corner == DateStampCorner::BottomRight || spec.corner == DateStampCorner::BottomLeft;
        let style = TextStyle {
            shadow: Some(TextShadow::new(
                RGBAColor::new(0.0, 0.0, 0.0, 0.6),
                spec.font_size * 0.05,
                spec.font_size * 0.05,
                spec.font_size * 0.04,
            )),
            alignment: if right { TextAlignment::Right } else { TextAlignment::Left },
            vertical_alignment: if bottom { TextVerticalAlignment::Bottom } else { TextVerticalAlignment::Top },
            ..TextStyle::new(
                Self::FONT_NAME,
                spec.font_size,
                FontWeight::Bold,
                RGBAColor::rgb(spec.red, spec.green, spec.blue),
            )
        };
        let mut t = TextTemplate::new("Date Stamp", &spec.text, style);
        t.box_ = Some(TextBox::new(spec.canvas_width as f64 - 2.0 * margin, spec.canvas_height as f64 - 2.0 * margin));
        t
    }

    /// The text generator reference for a Date Stamp layer, nil when `r` is not one (or cannot be encoded).
    pub fn text_ref(r: &GeneratorRef) -> Option<GeneratorRef> {
        let spec = DateStampSpec::decode(r)?;
        TextGenerator::make_ref(&Self::template(&spec), None).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(corner: DateStampCorner) -> DateStampSpec {
        DateStampSpec {
            text: "JUL 14 1998  10:32 PM".into(),
            corner,
            font_size: 48.0,
            red: 1.0,
            green: 0.55,
            blue: 0.1,
            canvas_width: 1920,
            canvas_height: 1080,
        }
    }

    #[test]
    fn becomes_an_area_text_generator_inside_the_margin() {
        let r = DateStampText::text_ref(&spec(DateStampCorner::BottomRight).generator()).unwrap();
        assert_eq!(r.kind, TextGenerator::KIND);
        let (t, _) = TextGenerator::decode(&r).unwrap();
        assert_eq!(t.text, "JUL 14 1998  10:32 PM");
        assert!(
            t.style.alignment == TextAlignment::Right && t.style.vertical_alignment == TextVerticalAlignment::Bottom
        );
        assert_eq!(t.box_, Some(TextBox::new(1920.0 - 130.0, 1080.0 - 130.0)));
        let tl = TextGenerator::decode(&DateStampText::text_ref(&spec(DateStampCorner::TopLeft).generator()).unwrap())
            .unwrap()
            .0;
        assert!(tl.style.alignment == TextAlignment::Left && tl.style.vertical_alignment == TextVerticalAlignment::Top);
    }

    #[test]
    fn other_kinds_are_not_a_stamp() {
        let solid = GeneratorRef { kind: "solid".into(), payload: b"{}".to_vec(), payload_version: 1 };
        assert!(DateStampText::text_ref(&solid).is_none());
    }
}
