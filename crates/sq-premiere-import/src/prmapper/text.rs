// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift (text and graphics). Essential Graphics clips: text layers and, for templates, shape layers.

use super::shapes::SHAPE_MATCH_NAME;
use super::{ClipContext, Mapping};
use crate::prdocument::{PRComponent, PRItem, PRParamValue, PRSequence};
use crate::primport_report::Status;
use crate::prtext_blob::{PRText, PRTextBlob};
use sq_core_model::{AnimatedProperty, Clip, GeneratorRef, GraphicsDocument, GraphicsLayer, TrackKind};
use sq_core_time::{Time, TimeRange, Vec2};
use sq_text::text_generator::TextGenerator;
use sq_text::text_layout::TextLayout;
use sq_text::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextLineStyle, TextShadow,
    TextStroke, TextStyle,
};
use sq_text::text_template::TextTemplate;

/// Text placement calibration against Premiere renders (vertical offset of the glyph center from the Geometry2 point, px).
pub const TEXT_CENTRE_OFFSET_Y: f64 = 29.0;
/// Premiere's glyphs are 2 % larger than the decoded size (fidelity sweep, Swift `Mapping.textSizeScale`).
pub const TEXT_SIZE_SCALE: f64 = 1.02;
/// Premiere's tracking spaces glyphs 60 % of the decoded value (Swift `Mapping.textTrackingScale`).
pub const TEXT_TRACKING_SCALE: f64 = 0.6;
/// Premiere's shadow Blur to SQ's blur radius (Swift `Mapping.shadowBlurScale`).
pub const SHADOW_BLUR_SCALE: f64 = 0.26;
/// Premiere's shadow Size to SQ's spread (Swift `Mapping.shadowSizeScale`).
pub const SHADOW_SIZE_SCALE: f64 = 0.28;

/// The weight a font's PostScript name ends in (Swift `Mapping.weight`).
pub fn weight(font_name: &str) -> FontWeight {
    let lower = font_name.to_lowercase();
    [
        ("black", FontWeight::Black),
        ("heavy", FontWeight::Heavy),
        ("extrabold", FontWeight::Heavy),
        ("semibold", FontWeight::Semibold),
        ("bold", FontWeight::Bold),
        ("medium", FontWeight::Medium),
        ("light", FontWeight::Light),
        ("thin", FontWeight::Thin),
    ]
    .iter()
    .find(|(suffix, _)| lower.ends_with(suffix))
    .map_or(FontWeight::Regular, |(_, w)| *w)
}

/// The decoded text layer of an `AE.ADBE Text` component, `None` when it holds no text.
pub(crate) fn text_layer(t: &PRComponent) -> Option<(PRText, &PRComponent)> {
    let text = PRTextBlob::decode_base64(t.param(1)?.blob.as_deref()?).filter(|t| !t.text.is_empty())?;
    Some((text, t))
}

impl Mapping<'_> {
    /// The text generator of one text layer with its raster offset from the canvas center (Motion anchor) and the offset the
    /// Transform stage uses. Swift: PRMapper.textGenerator.
    fn text_generator(
        &mut self,
        item: &PRItem,
        seq: &PRSequence,
        layer: &(PRText, &PRComponent),
    ) -> Option<(GeneratorRef, Vec2, Vec2)> {
        let (text, comp) = layer;
        let layer_pos = PRParamValue::point(comp.param(3).and_then(|p| p.static_value.as_deref()));
        let centre_pos = Vec2::new(0.5, 0.5);
        // Point text placed by its layer (titles): the layer's Scale multiplies the font size.
        let point_text = text.box_size.is_none() && layer_pos.is_some_and(|p| p != centre_pos);
        let layer_scale = if point_text {
            PRParamValue::double(comp.param(4).and_then(|p| p.static_value.as_deref())).unwrap_or(100.0) / 100.0
        } else {
            1.0
        };
        let size = text.size.unwrap_or(48.0) * layer_scale * TEXT_SIZE_SCALE;
        let font = text.font_name.clone().unwrap_or_else(|| "Helvetica".to_string());
        // Point text keeps the paragraph alignment (the layer position is its aligned edge); area text stays centered.
        let align = if !point_text {
            TextAlignment::Center
        } else {
            match text.alignment {
                Some(1) => TextAlignment::Right,
                Some(2) => TextAlignment::Center,
                _ => TextAlignment::Left,
            }
        };
        let mut style = TextStyle::new(&font, size, weight(&font), RGBAColor::WHITE);
        style.alignment = align;
        style.tracking = text.tracking.unwrap_or(0.0) / 1000.0 * size * TEXT_TRACKING_SCALE;
        if let Some(f) = &text.fill {
            style.color = RGBAColor::new(f.red, f.green, f.blue, 1.0);
        }
        // Lines 2+ in another font / size: SQ's second-line style.
        if let Some(l) = &text.second_line {
            let name = l.font_name.clone().unwrap_or_else(|| font.clone());
            let second_size = l.size.or(text.size).unwrap_or(48.0) * layer_scale * TEXT_SIZE_SCALE;
            style.second_line = Some(TextLineStyle::new(&name, second_size, weight(&name), style.color, false));
            self.report.note("Text second line style", Status::Mapped, "lines 2+ in their own font and size");
        } else if text.mixed_styles {
            self.report.note(
                "Text with mixed styles",
                Status::Approximated,
                "font / size changes inside a line: the first run's style for all",
            );
        }
        if let Some(s) = &text.stroke {
            style.stroke = Some(TextStroke::new(
                RGBAColor::new(s.color.red, s.color.green, s.color.blue, 1.0),
                s.width * layer_scale,
                StrokePosition::default(),
            ));
        }
        if let Some(b) = &text.background {
            let pad = b.size * layer_scale;
            style.background = Some(TextBackground::new(
                RGBAColor::new(b.color.red, b.color.green, b.color.blue, b.opacity),
                BoxPadding { horizontal: pad, vertical: pad },
                b.corner_radius * layer_scale,
            ));
            self.report.note("Text background", Status::Approximated, "color, opacity, size as padding, corner radius");
        }
        if let Some(s) = &text.shadow {
            let mut shadow = TextShadow::from_angle(
                RGBAColor::new(s.red, s.green, s.blue, s.opacity),
                s.angle,
                s.distance * layer_scale,
                s.blur * layer_scale * SHADOW_BLUR_SCALE,
            );
            shadow.set_spread(s.size * layer_scale * SHADOW_SIZE_SCALE);
            style.shadow = Some(shadow);
        }
        let template = TextTemplate::new(&text.text, &text.text, style.clone());
        let reference = TextGenerator::make_ref(&template, None).ok()?;
        self.report.note(
            "Text",
            Status::Approximated,
            "string, font, size, tracking, fill color, alignment (point text; area text centered), shadow (size as spread), background",
        );
        let canvas = Vec2::new(seq.width as f64, seq.height as f64);
        if let (true, Some(p)) = (point_text, layer_pos)
            && let Some(line) = TextLayout::layout(&text.text, &style, None, None).lines.first()
        {
            // Point text: the layer position is the first line's baseline at its aligned edge (left / right / center),
            // moved by the Graphic Group (Vector Motion) position relative to its anchor. A Transform effect keeps
            // pivoting at its own point, so the stage offset is the text center itself.
            let mut origin = Vec2::new(p.x * canvas.x, p.y * canvas.y);
            if let Some(g) = item.components_named("AE.ADBE Graphic Group").first()
                && let Some(gp) = PRParamValue::point(g.param(1).and_then(|p| p.static_value.as_deref()))
            {
                let ga = PRParamValue::point(g.param(6).and_then(|p| p.static_value.as_deref())).unwrap_or(centre_pos);
                origin = Vec2::new(origin.x + (gp.x - ga.x) * canvas.x, origin.y + (gp.y - ga.y) * canvas.y);
                let scale = PRParamValue::double(g.param(2).and_then(|p| p.static_value.as_deref())).unwrap_or(100.0);
                if scale != 100.0 || g.params.iter().any(PRParamValue::is_animated) {
                    self.report.note("Graphic Group", Status::Approximated, "position only (scale / keys ignored)");
                }
            }
            let dx = match text.alignment.unwrap_or(0) {
                1 => -line.width / 2.0,
                2 => 0.0,
                _ => line.width / 2.0,
            };
            let centre = Vec2::new(
                origin.x + dx - canvas.x / 2.0,
                origin.y - line.baseline + line.height / 2.0 - canvas.y / 2.0,
            );
            self.report.note(
                "Point text",
                Status::Approximated,
                "placed by layer position (baseline, aligned edge) and scale",
            );
            return Some((reference, centre, centre));
        }
        // Area text (captions): at the Transform (Geometry2) point when there is one, else at the Text layer's own position.
        let mut centre = Vec2::ZERO;
        let geo_point = item
            .components_named("AE.ADBE Geometry2")
            .first()
            .and_then(|g| PRParamValue::point(g.param(2).and_then(|p| p.static_value.as_deref())));
        if let Some(p) = geo_point {
            centre = Vec2::new((p.x - 0.5) * canvas.x, (p.y - 0.5) * canvas.y + TEXT_CENTRE_OFFSET_Y);
        } else if let Some(p) = layer_pos.filter(|p| *p != centre_pos) {
            centre = Vec2::new((p.x - 0.5) * canvas.x, (p.y - 0.5) * canvas.y);
            self.report.note("Text position", Status::Approximated, "Text layer position taken as the text center");
        }
        // The stage pivots at the Transform point itself: only the raster (anchor) carries the glyph-center calibration.
        let stage =
            if centre == Vec2::ZERO { Vec2::ZERO } else { Vec2::new(centre.x, centre.y - TEXT_CENTRE_OFFSET_Y) };
        Some((reference, centre, stage))
    }

    /// A graphic (Essential Graphics) as a clip: one text becomes a text generator clip, several layers one Graphics clip.
    /// Returns the clip with its text raster offset and stage offset; `None` when the graphic has nothing the model can draw.
    pub(super) fn graphic_clip(
        &mut self,
        item: &PRItem,
        seq: &PRSequence,
        ctx: &ClipContext,
        frame: Vec2,
        title: &str,
        at: TimeRange,
    ) -> Option<(Clip, Vec2, Vec2)> {
        // Text and (templates only) Shape layers in component order, which lists the top layer first.
        let mut texts: Vec<(GeneratorRef, Vec2, Vec2)> = Vec::new();
        let mut layers: Vec<GraphicsLayer> = Vec::new();
        let map_shapes = self.map_shapes;
        for comp in item
            .components
            .iter()
            .filter(|c| c.match_name == "AE.ADBE Text" || (map_shapes && c.match_name == SHAPE_MATCH_NAME))
        {
            if comp.match_name == "AE.ADBE Text" {
                let Some(layer) = text_layer(comp) else { continue };
                let Some(t) = self.text_generator(item, seq, &layer) else { continue };
                let mut l = GraphicsLayer::text(self.ids.next_id(), t.0.clone(), &format!("Text {}", texts.len() + 1));
                l.animation.position = AnimatedProperty::new(t.1);
                texts.push(t);
                layers.push(l);
            } else {
                let name = format!("Shape {}", layers.len() + 1);
                if let Some(l) = self.shape_layer(comp, ctx, frame, &name) {
                    layers.push(l);
                }
            }
        }
        let has_shape = layers.len() > texts.len();
        if layers.is_empty() {
            self.report.note(
                "Graphic without text",
                Status::Dropped,
                &format!("{title}: shapes / graphic groups have no model yet"),
            );
            return None;
        }
        let id = self.ids.next_id();
        let name = if item.name.is_empty() { title } else { &item.name };
        let (start, source) = (at.start, TimeRange::new(Time::ZERO, at.duration));
        let (mut text_offset, mut stage_offset) = (Vec2::ZERO, Vec2::ZERO);
        let c = if texts.len() == 1 && !has_shape {
            let (reference, offset, stage) = texts.remove(0);
            text_offset = offset;
            stage_offset = stage;
            let mut clip = Clip::new(id, name, id, TrackKind::Video, source, start);
            clip.generator = Some(reference);
            clip
        } else {
            // Several layers: one Graphics clip. Premiere draws the graphic's effects (Drop Shadow, Transform, blur) on all
            // layers together, so the shadow lies under every text; split into clips, an upper text's shadow darkened the
            // lower text. Each layer sits at its own raster offset in the graphic's canvas; the Motion anchor then needs no
            // text offset, and the effects keep the first layer's stage pivot (offset vs raster).
            if let Some(first) = texts.first() {
                stage_offset = Vec2::new(first.2.x - first.1.x, first.2.y - first.1.y);
            }
            let mut clip = Clip::new(id, name, id, TrackKind::Video, source, start);
            clip.generator = Some(GeneratorRef::graphics_clip());
            // Graphics layers are listed bottom first, Premiere's components top first.
            layers.reverse();
            clip.set_graphics(Some(GraphicsDocument { layers, groups: Vec::new() }));
            if texts.len() > 1 {
                self.report.note(
                    "Second text layer in a graphic",
                    Status::Mapped,
                    "one Graphics clip, a layer per text; effects act on the whole graphic",
                );
            }
            clip
        };
        Some((c, text_offset, stage_offset))
    }
}
