// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextGenerator+Portable.swift
//! One text frame on the portable raster (`PortableTextRenderer`), the counterpart of `TextFrame` for Windows: the picture
//! (premultiplied linear-light RGBA floats, top row first) and its placement in sequence pixels (y down) for the
//! untransformed block centered on the canvas, plus the animation factors of the clip's `AnimationSet`.

use crate::caption_layout::CaptionLayout;
use crate::portable_text_renderer::{Picture, PortableTextRenderer};
use crate::text_generator::{TextGenerator, TextGeneratorError};
use crate::text_layout::TextLayout;
use crate::text_style::TextFootageFill;
use crate::text_units_layout::TextUnitsLayoutExt;
use sq_core_graphics::text_animator_model::{AnimationSetTextExt, TextCharacterState, TextUnits};
use sq_core_model::anchored_animation::{AnimationSample, AnimationSet};
use sq_core_model::{ClipTransform, GeneratorRef, SequenceFormat};
use sq_core_time::{Time, Vec2};

/// One text frame on the portable raster.
#[derive(Clone, Debug)]
pub struct PortableTextFrame {
    /// The picture.
    pub picture: Picture,
    /// Left of the block in sequence pixels.
    pub x: f64,
    /// Top of the block in sequence pixels.
    pub y: f64,
    /// Width in sequence pixels.
    pub width: f64,
    /// Height in sequence pixels.
    pub height: f64,
    /// Animation opacity.
    pub opacity: f64,
    /// Animation scale.
    pub scale: f64,
    /// Animation offset, x.
    pub offset_x: f64,
    /// Animation offset, y.
    pub offset_y: f64,
    /// Animation rotation, degrees.
    pub rotation: f64,
    /// Center of the text lines relative to the raster center (sequence px, y down): the caption pivot (`TextFrame.pivotX`).
    pub pivot_x: f64,
    /// See `pivot_x`.
    pub pivot_y: f64,
    /// The style's footage fill (nil = filled with its color): the compositor layer carries it.
    pub footage_fill: Option<TextFootageFill>,
    /// The text animators' per-character states the picture was drawn with; nil for the resting picture.
    pub character_states: Option<Vec<TextCharacterState>>,
    /// The animatable units of the layout (empty without a text animator).
    pub(crate) units: Option<TextUnits>,
}

impl PortableTextFrame {
    /// True when `other` carries the same picture (a caller keeps one upload per picture).
    pub fn shares_picture(&self, other: &PortableTextFrame) -> bool {
        self.character_states == other.character_states
            && self.picture.width == other.picture.width
            && self.picture.height == other.picture.height
    }

    /// `TextFrame.layerTransform` for a whole raster: the block's center relative to the canvas center, the animation
    /// factors folded into `base`; with `pivot_at_text` scale and rotation happen about the center of the text lines
    /// (captions).
    pub fn layer_transform(&self, base: &ClipTransform, canvas: &SequenceFormat, pivot_at_text: bool) -> ClipTransform {
        let mut tr = *base;
        let (px, py) = if pivot_at_text { (self.pivot_x, self.pivot_y) } else { (0.0, 0.0) };
        tr.position = Vec2::new(
            base.position.x + self.x + self.width / 2.0 - canvas.display_width() as f64 / 2.0 + self.offset_x + px,
            base.position.y + self.y + self.height / 2.0 - canvas.height as f64 / 2.0 + self.offset_y + py,
        );
        tr.anchor = Vec2::new(base.anchor.x + px, base.anchor.y + py);
        tr.scale = Vec2::new(base.scale.x * self.scale, base.scale.y * self.scale);
        tr.rotation += self.rotation;
        tr.opacity *= self.opacity;
        tr
    }

    fn with_sample(
        &self,
        a: &AnimationSample,
        states: Option<Vec<TextCharacterState>>,
        units: Option<TextUnits>,
    ) -> Self {
        PortableTextFrame {
            opacity: a.opacity,
            scale: a.scale,
            offset_x: a.offset.x,
            offset_y: a.offset.y,
            rotation: a.rotation,
            character_states: states,
            units,
            ..self.clone()
        }
    }
}

impl TextGenerator {
    /// `frame(ref:…)` on the portable raster: nil for empty text. Date Stamp refs go through `DateStampText.textRef` first.
    /// Text animators draw their per-character states (`PortableTextRenderer::render_with_states`).
    /// `previous`: a frame this ref gave before (same canvas and scale): when the character states are the same its picture
    /// and placement are kept and only the animation is sampled again (the caller keeps the uploaded picture,
    /// `shares_picture`).
    /// shortcut: in-between frames of a text animator are drawn on the caller's thread every frame, no look-ahead lane
    /// or cache (the Mac's `animatedCache`); add one when animated captions drop frames on Windows.
    pub fn portable_frame(
        r: &GeneratorRef,
        local_time: Time,
        clip_duration: Time,
        canvas: &SequenceFormat,
        scale: f64,
        previous: Option<&PortableTextFrame>,
    ) -> Result<Option<PortableTextFrame>, TextGeneratorError> {
        let (template, set) = Self::decode(r)?;
        let anims = set.or_else(|| AnimationSet::single(template.animation.as_ref()));
        let a = anims.as_ref().map_or(AnimationSample::REST, |s| s.sample(local_time, clip_duration));
        let mut units = previous.and_then(|p| p.units.clone());
        let mut states: Option<Vec<TextCharacterState>> = None;
        if let Some(anims) = anims.as_ref().filter(|s| s.has_text_animator()) {
            if units.is_none() {
                let layout = TextLayout::layout(
                    &template.text,
                    &template.style.drawn(),
                    template.box_.map(|b| b.width),
                    template.box_.map(|b| b.height),
                );
                units = Some(TextUnits::segment_layout(&layout));
            }
            if let Some(st) = units.as_ref().and_then(|u| anims.character_states(u, local_time, clip_duration))
                && !st.iter().all(TextCharacterState::is_rest)
            {
                states = Some(st);
            }
        }
        if let Some(p) = previous.filter(|p| p.character_states == states) {
            return Ok(Some(p.with_sample(&a, states, units)));
        }
        let raster = match &states {
            Some(st) => PortableTextRenderer::render_with_states(
                &template.text,
                &template.style,
                template.box_.map(|b| b.width),
                template.box_.map(|b| b.height),
                scale,
                template.highlight.as_ref(),
                st,
            ),
            None => PortableTextRenderer::render(
                &template.text,
                &template.style,
                template.box_.map(|b| b.width),
                template.box_.map(|b| b.height),
                scale,
                template.highlight.as_ref(),
            ),
        };
        let Some(raster) = raster else { return Ok(None) };
        let s = raster.scale;
        let b = raster.layout.bounds;
        let w = raster.picture.width as f64 / s;
        let h = raster.picture.height as f64 / s;
        let c = CaptionLayout::text_centre(&raster.layout);
        Ok(Some(PortableTextFrame {
            x: (canvas.display_width() as f64 - b.width) / 2.0 + (raster.origin_x - b.x),
            y: (canvas.height as f64 - b.height) / 2.0 + (raster.origin_y - b.y),
            width: w,
            height: h,
            opacity: a.opacity,
            scale: a.scale,
            offset_x: a.offset.x,
            offset_y: a.offset.y,
            rotation: a.rotation,
            pivot_x: c.map_or(0.0, |c| c.0 - (raster.origin_x + w / 2.0)),
            pivot_y: c.map_or(0.0, |c| c.1 - (raster.origin_y + h / 2.0)),
            footage_fill: template.style.footage_fill,
            character_states: states,
            units,
            picture: raster.picture,
        }))
    }

    /// The animatable units of a ref's text (`units(ref:)` without the Core Text raster cache): the caption hand-over
    /// asks for them; nil when the ref does not decode.
    pub fn portable_units(r: &GeneratorRef) -> Option<TextUnits> {
        let (template, _) = Self::decode(r).ok()?;
        Some(TextUnits::segment_layout(&TextLayout::layout(
            &template.text,
            &template.style.drawn(),
            template.box_.map(|b| b.width),
            template.box_.map(|b| b.height),
        )))
    }
}
