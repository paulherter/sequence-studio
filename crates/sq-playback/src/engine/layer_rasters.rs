// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: WinTimelineFrameSource / WinCompositor (title, shape, Lottie and caption layers)
//! The drawn layers of the Program frame: titles and captions are drawn by `sq-text`, shapes by `PortableShapeRenderer` and
//! Lottie clips by a `sq-lottie` renderer, all on the CPU into premultiplied linear [`Raster`]s the compositor uploads once
//! per picture.
//! An unreadable Lottie file or Date Stamp shows the offline slate (`RasterProvider::is_offline`), as in Swift.

use super::caption_plan::CaptionLayerRequest;
use super::handle::RasterProvider;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_graphics::date_stamp::DATE_STAMP_KIND;
use sq_core_graphics::lottie_generator::LOTTIE_KIND;
use sq_core_model::{ClipTransform, GeneratorRef, SequenceFormat};
use sq_core_time::Time;
use sq_lottie::lottie_document::{LottieRenderer, PortableFrame};
use sq_render::compositor::FootageFill;
use sq_render::program::Raster;
use sq_text::date_stamp_text::DateStampText;
use sq_text::portable_shape_renderer::PortableShapeRenderer;
use sq_text::text_generator::TextGenerator;
use sq_text::text_generator_portable::PortableTextFrame;
use sq_text::text_style::TextFootageFill;
use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, PoisonError};

/// Most pictures kept between frames.
const KEPT: usize = 32;

/// A drawn picture with the size of the layer it covers.
struct Drawn {
    width: u32,
    height: u32,
    pixels: Arc<Vec<f32>>,
    layer_width: f64,
    layer_height: f64,
}

#[derive(Default)]
struct Kept {
    /// The last frame of each ref: an animated title that has not changed its glyph states keeps its picture.
    frames: HashMap<u64, (PortableTextFrame, Arc<Vec<f32>>)>,
    /// Shape pictures by style: a shape is drawn once until a keyframe changes it.
    shapes: HashMap<u64, Option<Drawn>>,
}

/// Draws the title, shape, Lottie and caption layers.
#[derive(Default)]
pub struct LayerRasters {
    kept: Mutex<Kept>,
    lottie: Option<LottieRenderer>,
}

fn hash_of(value: &impl Hash) -> u64 {
    let mut h = DefaultHasher::new();
    value.hash(&mut h);
    h.finish()
}

impl LayerRasters {
    pub fn new() -> LayerRasters {
        LayerRasters::default()
    }

    /// Also draws Lottie clips through `renderer`; without one they stay invisible.
    pub fn with_lottie(renderer: LottieRenderer) -> LayerRasters {
        LayerRasters { lottie: Some(renderer), ..LayerRasters::default() }
    }

    /// The text `reference` at `local_time` placed by `base`; `None` for empty text.
    fn text(
        &self,
        reference: &GeneratorRef,
        local_time: Time,
        duration: Time,
        canvas: &SequenceFormat,
        base: &ClipTransform,
        pivot_at_text: bool,
    ) -> Option<(Raster, PortableTextFrame)> {
        let slot = hash_of(reference);
        let mut kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        let previous = kept.frames.get(&slot).map(|(f, _)| f.clone());
        let frame =
            TextGenerator::portable_frame(reference, local_time, duration, canvas, 1.0, previous.as_ref()).ok()??;
        let pixels = match kept.frames.get(&slot).filter(|(old, _)| old.shares_picture(&frame)) {
            Some((_, pixels)) => Arc::clone(pixels),
            None => Arc::new(frame.picture.pixels.clone()),
        };
        // The picture's identity: the ref plus the glyph states it was drawn with.
        let mut k = DefaultHasher::new();
        slot.hash(&mut k);
        format!("{:?}", frame.character_states).hash(&mut k);
        let raster = Raster {
            key: k.finish(),
            width: u32::try_from(frame.picture.width).ok()?,
            height: u32::try_from(frame.picture.height).ok()?,
            pixels: Arc::clone(&pixels),
            layer_width: frame.width,
            layer_height: frame.height,
            transform: frame.layer_transform(base, canvas, pivot_at_text),
            corner_radius: 0.0,
            footage_fill: frame.footage_fill.map(|f| match f {
                TextFootageFill::Stencil => FootageFill::Stencil,
                TextFootageFill::Inverted => FootageFill::Inverted,
            }),
            sample_transforms: Vec::new(),
        };
        if kept.frames.len() >= KEPT {
            kept.frames.clear();
        }
        kept.frames.insert(slot, (frame.clone(), pixels));
        Some((raster, frame))
    }

    /// The motion-blur sample transforms of a text layer: the request's sample k (Motion at its time) placed by the text
    /// animation (Scale, Offset, Rotation, Opacity) evaluated at the same sub-frame time, so a title's In/Out motion blurs
    /// like the clip's own. Empty when the request has no samples.
    /// shortcut: a sample whose per-character states differ from the frame's is drawn again (only its placement is used);
    /// upgrade by sampling the animation without drawing.
    fn text_samples(
        reference: &GeneratorRef,
        request: &LayerRequest,
        duration: Time,
        canvas: &SequenceFormat,
        frame: &PortableTextFrame,
    ) -> Vec<ClipTransform> {
        let Some(mb) = request.motion_blur.as_ref().filter(|m| m.local_times.len() == m.transforms.len()) else {
            return Vec::new();
        };
        mb.transforms
            .iter()
            .zip(&mb.local_times)
            .map(|(base, local)| {
                match TextGenerator::portable_frame(reference, *local, duration, canvas, 1.0, Some(frame)) {
                    Ok(Some(f)) => f.layer_transform(base, canvas, false),
                    _ => frame.layer_transform(base, canvas, false),
                }
            })
            .collect()
    }

    fn shape(&self, request: &LayerRequest) -> Option<Raster> {
        let style = request.shape.as_ref()?;
        let key = hash_of(&format!("{style:?}"));
        let mut kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        if kept.shapes.len() >= KEPT {
            kept.shapes.clear();
        }
        let drawn = kept
            .shapes
            .entry(key)
            .or_insert_with(|| {
                let shape = PortableShapeRenderer::render(style)?;
                Some(Drawn {
                    width: u32::try_from(shape.picture.width).ok()?,
                    height: u32::try_from(shape.picture.height).ok()?,
                    pixels: Arc::new(shape.picture.pixels),
                    layer_width: shape.width,
                    layer_height: shape.height,
                })
            })
            .as_ref()?;
        Some(Raster {
            key,
            width: drawn.width,
            height: drawn.height,
            pixels: Arc::clone(&drawn.pixels),
            layer_width: drawn.layer_width,
            layer_height: drawn.layer_height,
            transform: request.transform,
            corner_radius: request.corner_radius,
            footage_fill: None,
            sample_transforms: Vec::new(),
        })
    }

    fn lottie(&self, request: &LayerRequest, canvas: &SequenceFormat) -> Option<Raster> {
        let PortableFrame::Picture { key, width, height, pixels } =
            self.lottie.as_ref()?.portable_frame(request, canvas)
        else {
            return None;
        };
        Some(Raster {
            key: hash_of(&key),
            width: u32::try_from(width).ok()?,
            height: u32::try_from(height).ok()?,
            pixels: Arc::new(pixels),
            layer_width: width as f64,
            layer_height: height as f64,
            transform: request.transform,
            corner_radius: request.corner_radius,
            footage_fill: None,
            sample_transforms: Vec::new(),
        })
    }
}

impl RasterProvider for LayerRasters {
    fn layer(&self, request: &LayerRequest, canvas: &SequenceFormat) -> Option<Raster> {
        let reference = request.generator.as_ref()?;
        match reference.kind.as_str() {
            TextGenerator::KIND => {
                let duration = request.clip_duration.unwrap_or(Time::ZERO);
                let (mut raster, frame) =
                    self.text(reference, request.local_time, duration, canvas, &request.transform, false)?;
                raster.corner_radius = request.corner_radius;
                raster.sample_transforms = Self::text_samples(reference, request, duration, canvas, &frame);
                Some(raster)
            }
            GeneratorRef::SHAPE => self.shape(request),
            LOTTIE_KIND => self.lottie(request, canvas),
            DATE_STAMP_KIND => {
                // Date Stamp: the same text layer as a title, built from its spec.
                let text = DateStampText::text_ref(reference)?;
                let duration = request.clip_duration.unwrap_or(Time::ZERO);
                let (mut raster, frame) =
                    self.text(&text, request.local_time, duration, canvas, &request.transform, false)?;
                raster.corner_radius = request.corner_radius;
                raster.sample_transforms = Self::text_samples(&text, request, duration, canvas, &frame);
                Some(raster)
            }
            _ => None,
        }
    }

    fn is_offline(&self, request: &LayerRequest, canvas: &SequenceFormat) -> bool {
        let Some(reference) = request.generator.as_ref() else { return false };
        match reference.kind.as_str() {
            LOTTIE_KIND => self
                .lottie
                .as_ref()
                .is_some_and(|l| matches!(l.portable_frame(request, canvas), PortableFrame::Offline)),
            DATE_STAMP_KIND => DateStampText::text_ref(reference).is_none(),
            _ => false,
        }
    }

    /// The caption raster about its text center, at the caption box's position.
    fn caption(&self, layer: &CaptionLayerRequest, canvas: &SequenceFormat) -> Option<Raster> {
        let canvas = canvas.layout_format();
        let base = ClipTransform { position: layer.position, ..ClipTransform::IDENTITY };
        let (mut raster, _) = self.text(&layer.reference, layer.local_time, layer.duration, &canvas, &base, true)?;
        raster.transform.opacity *= layer.opacity;
        Some(raster)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::effect_transform_stage::MotionBlurSamples;
    use sq_core_model::anchored_animation::{AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate};
    use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, SequentialIds};
    use sq_text::text_style::TextStyle;
    use sq_text::text_template::TextTemplate;

    fn canvas() -> SequenceFormat {
        SequenceFormat {
            width: 640,
            height: 360,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        }
    }

    // A title whose In animation scales 3 -> 1 over two seconds blurs through that motion: the Motion samples are all
    // identical (Motion is still), the text animation at each sample time is what differs.
    #[test]
    fn a_text_layers_in_animation_moves_between_its_motion_blur_samples() {
        let mut ids = SequentialIds::default();
        let keys = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, 3.0),
            Keyframe::new(ids.next_id(), Time::new(2, 1), 1.0),
        ]);
        let mut anim = KeyframeTemplate::none();
        anim.tracks = vec![AnimationTrack::new("scale".into(), keys)];
        anim.duration = Time::new(2, 1);
        anim.anchor = AnimationAnchor::Start;
        let template = TextTemplate::new("t", "Hello", TextStyle::default());
        let set = AnimationSet::single(Some(&anim));
        let reference = TextGenerator::make_ref(&template, set.as_ref()).expect("ref");
        let mut r = LayerRequest::new(Id::from_u128(1), Id::from_u128(1), Id::from_u128(2), Time::ZERO);
        r.generator = Some(reference);
        r.local_time = Time::new(1, 1);
        r.clip_duration = Some(Time::new(4, 1));
        r.motion_blur = Some(MotionBlurSamples {
            format: canvas(),
            transforms: vec![ClipTransform::IDENTITY; 2],
            local_times: vec![Time::new(1, 1) - Time::new(1, 50), Time::new(1, 1) + Time::new(1, 50)],
        });
        let raster = LayerRasters::new().layer(&r, &canvas()).expect("raster");
        assert_eq!(raster.sample_transforms.len(), 2);
        assert!(raster.sample_transforms[0].scale.x > raster.sample_transforms[1].scale.x);
    }
}
