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
use std::sync::Arc;

/// One text frame on the portable raster.
#[derive(Clone, Debug)]
pub struct PortableTextFrame {
    /// The picture (shared: a kept frame is cloned every frame, its pixels are not).
    pub picture: Arc<Picture>,
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
    /// Index (`TextUnitCharacter::index`) of the character the typewriter cursor is drawn after; `None` without a cursor
    /// (not configured, in the off half of a blink, or past its hold).
    pub cursor: Option<usize>,
    /// The tracking (points) the picture was drawn with.
    pub tracking: f64,
    /// The animatable units of the layout (empty without a text animator).
    pub(crate) units: Option<TextUnits>,
}

impl PortableTextFrame {
    /// True when `other` carries the same picture (a caller keeps one upload per picture).
    pub fn shares_picture(&self, other: &PortableTextFrame) -> bool {
        self.character_states == other.character_states
            && self.cursor == other.cursor
            && self.tracking.to_bits() == other.tracking.to_bits()
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
        cursor: Option<usize>,
    ) -> Self {
        PortableTextFrame {
            opacity: a.opacity,
            scale: a.scale,
            offset_x: a.offset.x,
            offset_y: a.offset.y,
            rotation: a.rotation,
            character_states: states,
            units,
            cursor,
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
        let (mut template, set) = Self::decode(r)?;
        // Keyed tracking replaces the style's value at this time.
        if let Some(k) = &template.tracking_keys {
            template.style.tracking = k.value_at_local(local_time);
        }
        let tracking = template.style.tracking;
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
        // The typewriter cursor: on while typing, then blinking until its hold ends (in-animator only).
        let cursor = anims
            .as_ref()
            .and_then(|s| s.animation_in.as_ref())
            .and_then(|t| t.text_animator.as_ref())
            .zip(units.as_ref())
            .and_then(|(a, u)| {
                u.typewriter_cursor(a, local_time).filter(|c| c.visible).map(|c| (c.after_character, a))
            });
        let cursor_glyph = cursor.map(|(i, a)| (i, a.cursor.clone()));
        let cursor = cursor.map(|(i, _)| i);
        if let Some(p) = previous.filter(|p| {
            p.character_states == states && p.cursor == cursor && p.tracking.to_bits() == tracking.to_bits()
        }) {
            return Ok(Some(p.with_sample(&a, states, units, cursor)));
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
        let Some(mut raster) = raster else { return Ok(None) };
        if let (Some((i, Some(spec))), Some(u)) = (&cursor_glyph, &units) {
            raster = crate::typewriter_cursor::with_cursor(raster, &template, u, *i, spec);
        }
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
            cursor,
            tracking,
            units,
            picture: Arc::new(raster.picture),
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

#[cfg(test)]
mod tracking_tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;
    use crate::text_style::TextStyle;
    use crate::text_template::TextTemplate;
    use sq_core_model::AnimatedProperty;
    use sq_core_time::{Id, Keyframe};

    #[test]
    fn keyed_tracking_widens_the_text_early_and_tightens_it_later() {
        set_fonts_root(&test_fonts_root());
        let canvas = SequenceFormat { width: 1920, height: 1080, ..SequenceFormat::new(Time::new(1, 30)) };
        let mut template =
            TextTemplate::new("t", "TRACKING", TextStyle { size: 90.0, tracking: 2.0, ..TextStyle::default() });
        let mut keys = AnimatedProperty::new(2.0);
        keys.track.insert(Keyframe::new(Id::from_u128(1), Time::ZERO, 40.0));
        keys.track.insert(Keyframe::new(Id::from_u128(2), Time::new(8, 30), 2.0));
        template.tracking_keys = Some(keys);
        let r = TextGenerator::make_ref(&template, None).unwrap_or_else(|e| panic!("{e}"));
        let at = |t: Time, prev: Option<&PortableTextFrame>| {
            TextGenerator::portable_frame(&r, t, Time::new(3, 1), &canvas, 1.0, prev)
                .ok()
                .flatten()
                .unwrap_or_else(|| panic!("frame"))
        };
        let (w0, w4, w8) = (at(Time::ZERO, None), at(Time::new(4, 30), None), at(Time::new(8, 30), None));
        assert!(w0.width > w4.width && w4.width > w8.width, "{} {} {}", w0.width, w4.width, w8.width);
        // 7 gaps between the 8 letters (plus the trailing one): about 38 pt wider at the first key than at the last.
        assert!(w0.width - w8.width > 7.0 * 38.0 * 0.9, "{}", w0.width - w8.width);
        // Reusing the previous frame never keeps a picture drawn with another tracking.
        let again = at(Time::new(8, 30), Some(&w0));
        assert!((again.width - w8.width).abs() < 1e-9 && !again.shares_picture(&w0));
        // Without keys the style's value is drawn, as before.
        template.tracking_keys = None;
        let plain = TextGenerator::make_ref(&template, None).unwrap_or_else(|e| panic!("{e}"));
        let p = TextGenerator::portable_frame(&plain, Time::ZERO, Time::new(3, 1), &canvas, 1.0, None).ok().flatten();
        assert!(p.is_some_and(|p| (p.width - w8.width).abs() < 1e-9));
    }
}

#[cfg(test)]
mod pill_tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;
    use crate::text_style::{BoxPadding, RGBAColor, TextBackground, TextStyle};
    use crate::text_template::TextTemplate;
    use sq_core_model::anchored_animation::{SegmentShape, TextAnimator, TextAnimatorEffect, TextAnimatorUnit};

    /// Width in pixels of the area with any alpha (the pill; the words sit inside it).
    fn ink_width(f: &PortableTextFrame) -> usize {
        let (w, h) = (f.picture.width, f.picture.height);
        let cols: Vec<usize> =
            (0..w).filter(|&x| (0..h).any(|y| f.picture.pixels[(y * w + x) * 4 + 3] > 0.01)).collect();
        cols.last().zip(cols.first()).map_or(0, |(b, a)| b - a + 1)
    }

    fn pill_ref(follow: bool, out: bool) -> GeneratorRef {
        let mut style = TextStyle { size: 80.0, color: RGBAColor::WHITE, ..TextStyle::default() };
        let mut bg = TextBackground::new(RGBAColor::new(1.0, 0.0, 0.0, 1.0), BoxPadding::new(30.0, 14.0), 35.0);
        bg.follow_reveal = follow;
        style.background = Some(bg);
        let template = TextTemplate::new("t", "AAAA BBBB CCCC", style);
        let mut a =
            TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, Time::new(1, 1), Time::new(1, 1));
        a.easing = SegmentShape::Linear;
        let set = sq_core_model::anchored_animation::AnimationSet::new(None, None);
        let mut set = set;
        set.set_text_animator(!out, Some(a));
        TextGenerator::make_ref(&template, Some(&set)).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn a_following_pill_grows_word_by_word_and_shrinks_with_the_out_animator() {
        set_fonts_root(&test_fonts_root());
        let canvas = SequenceFormat { width: 1920, height: 1080, ..SequenceFormat::new(Time::new(1, 30)) };
        let dur = Time::new(10, 1);
        let r = pill_ref(true, false);
        let w_at = |r: &GeneratorRef, t: Time| {
            ink_width(
                &TextGenerator::portable_frame(r, t, dur, &canvas, 1.0, None)
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| panic!("frame")),
            )
        };
        let (empty, mid, late, full) =
            (w_at(&r, Time::ZERO), w_at(&r, Time::new(3, 2)), w_at(&r, Time::new(5, 2)), w_at(&r, Time::new(5, 1)));
        // Empty pill first (round end, still visible), then wider with every word, full when all words are in.
        assert!(empty > 0 && empty < mid && mid < late && late <= full, "{empty} {mid} {late} {full}");
        assert!(mid < full && mid > 0);
        // Without the flag the box is the whole block from the first frame.
        let fixed = pill_ref(false, false);
        assert!(w_at(&fixed, Time::ZERO) >= full - 1);
        // The out animator takes the words away again: the box shrinks back toward the empty pill.
        let o = pill_ref(true, true);
        let (before, going, gone) = (w_at(&o, Time::new(1, 1)), w_at(&o, Time::new(17, 2)), w_at(&o, Time::new(10, 1)));
        assert!(gone < going && going < before, "{before} {going} {gone}");
    }
}
