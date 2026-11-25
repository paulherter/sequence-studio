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
use sq_core_graphics::text_animator_model::TextCharacterState;
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
const KEPT: usize = 64;
/// Most pixel bytes the kept text pictures hold (a caption picture is a few MB).
const KEPT_BYTES: usize = 256 << 20;

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
    /// When each slot of `frames` was last stored: the oldest goes first when the count or the bytes are over the limit.
    used: HashMap<u64, u64>,
    clock: u64,
}

impl Kept {
    /// Keeps `frame` for `slot` and drops the least recently stored slots past `KEPT` / `KEPT_BYTES`. Clearing everything at
    /// the limit threw away the pictures the prefetch had drawn for titles seconds ahead (every caption cue is a slot of its
    /// own: 5 per second): the title's first frame was drawn again inside the composite (11-20 ms, a 50 ms gap).
    fn store(&mut self, slot: u64, frame: PortableTextFrame, pixels: Arc<Vec<f32>>) {
        self.clock += 1;
        self.used.insert(slot, self.clock);
        self.frames.insert(slot, (frame, pixels));
        let mut bytes: usize = self.frames.values().map(|(_, p)| p.len() * 4).sum();
        while self.frames.len() > KEPT || bytes > KEPT_BYTES {
            let Some(oldest) = self.used.iter().filter(|(k, _)| **k != slot).min_by_key(|(_, t)| **t).map(|(k, _)| *k)
            else {
                break;
            };
            self.used.remove(&oldest);
            if let Some((_, p)) = self.frames.remove(&oldest) {
                bytes -= p.len() * 4;
            }
        }
    }
}

/// Draws the title, shape, Lottie and caption layers.
#[derive(Default)]
pub struct LayerRasters {
    kept: Mutex<Kept>,
    /// One lock per text reference: the same title is drawn by one thread at a time (a warm-up thread and the composite, or a
    /// duplicated lower third), so `previous` below is still the entry it was read from when the draw is stored.
    slots: Mutex<HashMap<u64, Arc<Mutex<()>>>>,
    lottie: Option<LottieRenderer>,
}

fn hash_of(value: &impl Hash) -> u64 {
    let mut h = DefaultHasher::new();
    value.hash(&mut h);
    h.finish()
}

/// Feeds the glyph states into `h` without formatting them. Same identity as hashing their `Debug` text: every field
/// by its bits (so 0.0 and -0.0 differ, as in the text), `None` apart from an empty list.
fn hash_states(states: Option<&[TextCharacterState]>, h: &mut impl Hasher) {
    let Some(states) = states else { return 0u8.hash(h) };
    1u8.hash(h);
    states.len().hash(h);
    for s in states {
        for u in [&s.in_state, &s.out_state] {
            for v in [u.opacity, u.scale, u.offset_x, u.offset_y, u.blur] {
                v.to_bits().hash(h);
            }
        }
        s.in_unit.hash(h);
        s.out_unit.hash(h);
    }
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
        let slot_lock = Arc::clone(self.slots.lock().unwrap_or_else(PoisonError::into_inner).entry(slot).or_default());
        let _drawing = slot_lock.lock().unwrap_or_else(PoisonError::into_inner);
        // The lock is not held while drawing (16-22 ms for a title): a warm-up thread drawing the next title must not stall
        // the composite that reads another kept picture.
        let previous =
            self.kept.lock().unwrap_or_else(PoisonError::into_inner).frames.get(&slot).map(|(f, _)| f.clone());
        let mut frame =
            TextGenerator::portable_frame(reference, local_time, duration, canvas, 1.0, previous.as_ref()).ok()??;
        let mut kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        // A frame that shares the previous picture has no pixels of its own; if another slot's insert cleared `kept.frames`
        // (KEPT) in the gap, that picture is gone: draw again without `previous`.
        if previous.is_some() && !kept.frames.contains_key(&slot) && frame.picture.pixels.is_empty() {
            drop(kept);
            frame = TextGenerator::portable_frame(reference, local_time, duration, canvas, 1.0, None).ok()??;
            kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        }
        let pixels = match kept.frames.get(&slot).filter(|(old, _)| old.shares_picture(&frame)) {
            Some((_, pixels)) => Arc::clone(pixels),
            // The pixels move out of a freshly drawn picture (no copy of the whole raster); a picture another owner still
            // holds is copied by `make_mut` as before. The frame keeps only the size: everything after this reads the
            // pixels from `kept.frames` / the `Raster` (`shares_picture` compares sizes and states).
            None => Arc::new(std::mem::take(&mut Arc::make_mut(&mut frame.picture).pixels)),
        };
        // The picture's identity: the ref plus the glyph states it was drawn with.
        let mut k = DefaultHasher::new();
        slot.hash(&mut k);
        hash_states(frame.character_states.as_deref(), &mut k);
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
        kept.store(slot, frame.clone(), pixels);
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

    fn layer_drawn(&self, request: &LayerRequest, canvas: &SequenceFormat) -> Option<Raster> {
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
        if !super::core::play_trace() {
            return self.layer_drawn(request, canvas);
        }
        let started = std::time::Instant::now();
        let out = self.layer_drawn(request, canvas);
        let ms = started.elapsed().as_secs_f64() * 1e3;
        if ms > 1.0 {
            let thread = std::thread::current();
            eprintln!(
                "[play-trace] {:.3}s slow raster {} ms kind {} clip {:?} local {:?} on {}",
                super::core::trace_clock(),
                ms.round(),
                request.generator.as_ref().map_or("-", |g| g.kind.as_str()),
                request.clip,
                request.local_time,
                thread.name().unwrap_or("?")
            );
        }
        out
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
        self.caption_drawn(layer, canvas)
    }
}

impl LayerRasters {
    fn caption_drawn(&self, layer: &CaptionLayerRequest, canvas: &SequenceFormat) -> Option<Raster> {
        let canvas = canvas.layout_format();
        let base = ClipTransform { position: layer.position, ..ClipTransform::IDENTITY };
        let (mut raster, _) = self.text(&layer.reference, layer.local_time, layer.duration, &canvas, &base, true)?;
        raster.transform.opacity *= layer.opacity;
        Some(raster)
    }
}

#[cfg(test)]
mod tests {
    use sq_core_graphics::text_animator_model::TextUnitState;

    fn old_key(states: &Option<Vec<TextCharacterState>>) -> u64 {
        let mut k = DefaultHasher::new();
        format!("{states:?}").hash(&mut k);
        k.finish()
    }

    fn new_key(states: &Option<Vec<TextCharacterState>>) -> u64 {
        let mut k = DefaultHasher::new();
        hash_states(states.as_deref(), &mut k);
        k.finish()
    }

    /// Differential: the cheap key and the old `Debug` text key hit the cache for exactly the same pairs of inputs.
    #[test]
    fn the_glyph_state_key_decides_cache_hits_like_the_debug_text_key() {
        use sq_core_model::anchored_animation::TextAnimatorUnit as U;
        let values = [0.0, -0.0, 1.0, 0.5, 1.0 / 3.0, 1e-9, 640.25];
        let units = [None, Some(U::Character), Some(U::Word), Some(U::Line)];
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut next = move |n: usize| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed % n as u64) as usize
        };
        let mut all: Vec<Option<Vec<TextCharacterState>>> = vec![None, Some(Vec::new())];
        for _ in 0..400 {
            let len = next(3) + 1;
            let mut states = Vec::new();
            for _ in 0..len {
                let mut unit = || TextUnitState {
                    opacity: values[next(values.len())],
                    scale: values[next(values.len())],
                    offset_x: values[next(values.len())],
                    offset_y: values[next(values.len())],
                    blur: values[next(values.len())],
                };
                let (in_state, out_state) = (unit(), unit());
                states.push(TextCharacterState {
                    in_state,
                    out_state,
                    in_unit: units[next(4)],
                    out_unit: units[next(4)],
                });
            }
            all.push(Some(states));
        }
        let copy = all.clone();
        all.extend(copy);
        let mut equal_pairs = 0;
        for a in &all {
            for b in all.iter().step_by(7) {
                let (o, n) = (old_key(a) == old_key(b), new_key(a) == new_key(b));
                assert_eq!(o, n, "{a:?} vs {b:?}");
                equal_pairs += usize::from(o);
            }
        }
        assert!(equal_pairs > 100);
    }

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

    fn shadowed_ref(text: &str, size: f64) -> GeneratorRef {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let style = TextStyle {
            size,
            shadow: Some(sq_text::text_style::TextShadow::new(sq_text::text_style::RGBAColor::BLACK, 2.0, 3.0, 8.0)),
            ..TextStyle::default()
        };
        TextGenerator::make_ref(&TextTemplate::new("t", text, style), None).expect("ref")
    }

    fn drawn(rasters: &LayerRasters, r: &GeneratorRef, t: Time) -> (Raster, PortableTextFrame) {
        rasters.text(r, t, Time::new(4, 1), &canvas(), &ClipTransform::IDENTITY, false).expect("text")
    }

    // A still title with a blurred shadow is drawn once: later frames share the picture (no CPU blur per frame).
    #[test]
    fn a_still_title_is_drawn_once_and_later_frames_share_its_picture() {
        let rasters = LayerRasters::new();
        let r = shadowed_ref("Hello", 60.0);
        let (a, _) = drawn(&rasters, &r, Time::new(1, 25));
        let (b, _) = drawn(&rasters, &r, Time::new(2, 25));
        assert!(Arc::ptr_eq(&a.pixels, &b.pixels), "second frame reuses the drawn picture");
        assert_eq!(a.key, b.key);
        assert_eq!(*a.pixels, *b.pixels);
    }

    // Changing the text or the style draws a new picture.
    #[test]
    fn changing_text_or_style_draws_a_new_picture() {
        let rasters = LayerRasters::new();
        let (a, _) = drawn(&rasters, &shadowed_ref("Hello", 60.0), Time::ZERO);
        let (b, _) = drawn(&rasters, &shadowed_ref("Hello!", 60.0), Time::ZERO);
        let (c, _) = drawn(&rasters, &shadowed_ref("Hello", 61.0), Time::ZERO);
        assert!(a.key != b.key && a.key != c.key);
        assert!(!Arc::ptr_eq(&a.pixels, &b.pixels) && !Arc::ptr_eq(&a.pixels, &c.pixels));
    }

    /// Two threads draw the same title while a third fills the kept pictures past `KEPT` (which evicts the oldest): every raster
    /// has pixels (a drawer once took the cleared, empty picture of a frame that shared its predecessor's).
    #[test]
    fn concurrent_draws_of_one_title_never_give_an_empty_picture() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let make = |text: &str| {
            let style = TextStyle { size: 20.0, ..TextStyle::default() };
            TextGenerator::make_ref(&TextTemplate::new("Title", text, style), None).expect("ref")
        };
        let rasters = Arc::new(LayerRasters::new());
        let canvas = canvas();
        let base = ClipTransform::IDENTITY;
        let shared = make("LOWER THIRD");
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let filler = {
            let (r, c, b, stop) = (Arc::clone(&rasters), canvas.clone(), base, Arc::clone(&stop));
            let refs: Vec<_> = (0..(KEPT + 20)).map(|i| make(&format!("FILL {i}"))).collect();
            std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    for x in &refs {
                        let _ = r.text(x, Time::ZERO, Time::seconds(3), &c, &b, false);
                    }
                }
            })
        };
        let drawers: Vec<_> = (0..2)
            .map(|_| {
                let (r, c, b, g) = (Arc::clone(&rasters), canvas.clone(), base, shared.clone());
                std::thread::spawn(move || {
                    for _ in 0..150 {
                        let (raster, _) = r.text(&g, Time::ZERO, Time::seconds(3), &c, &b, false).expect("drawn");
                        assert!(!raster.pixels.is_empty(), "an empty picture was returned");
                    }
                })
            })
            .collect();
        for d in drawers {
            d.join().expect("drawer");
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        filler.join().expect("filler");
    }

    fn animated_ref(text: &str) -> GeneratorRef {
        use sq_core_model::anchored_animation::TextAnimator;
        let animator: TextAnimator = serde_json::from_str(
            r#"{"effect":"fade","unit":"character","duration":{"value":1,"timescale":2},"stagger":{"value":1,"timescale":10}}"#,
        )
        .expect("animator");
        let mut anim = KeyframeTemplate::none();
        anim.duration = Time::new(2, 1);
        anim.text_animator = Some(animator);
        let set = AnimationSet::single(Some(&anim));
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let template = TextTemplate::new("t", text, TextStyle { size: 20.0, ..TextStyle::default() });
        TextGenerator::make_ref(&template, set.as_ref()).expect("ref")
    }

    /// The same race with a character-animated title: its frames carry glyph states, drawn at changing times while the
    /// kept pictures are evicted by other slots.
    #[test]
    fn concurrent_draws_of_one_animated_title_never_give_an_empty_picture() {
        let rasters = Arc::new(LayerRasters::new());
        let canvas = canvas();
        let base = ClipTransform::IDENTITY;
        let shared = animated_ref("LOWER THIRD");
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let filler = {
            let (r, c, b, stop) = (Arc::clone(&rasters), canvas.clone(), base, Arc::clone(&stop));
            let refs: Vec<_> = (0..(KEPT + 20)).map(|i| animated_ref(&format!("FILL {i}"))).collect();
            std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    for x in &refs {
                        let _ = r.text(x, Time::new(1, 4), Time::seconds(3), &c, &b, false);
                    }
                }
            })
        };
        let drawers: Vec<_> = (0..2)
            .map(|d| {
                let (r, c, b, g) = (Arc::clone(&rasters), canvas.clone(), base, shared.clone());
                std::thread::spawn(move || {
                    for i in 0..100 {
                        let at = Time::new((i + d * 7) % 40, 25);
                        let (raster, _) = r.text(&g, at, Time::seconds(3), &c, &b, false).expect("drawn");
                        assert!(!raster.pixels.is_empty(), "an empty picture was returned");
                    }
                })
            })
            .collect();
        for d in drawers {
            d.join().expect("drawer");
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        filler.join().expect("filler");
    }

    /// A title drawn ahead survives the caption cues (one slot each) drawn after it: the least recently stored slot goes
    /// first, never everything at once (the real project redrew its warmed titles inside the composite).
    #[test]
    fn a_picture_drawn_ahead_survives_other_titles_drawn_after_it() {
        let rasters = LayerRasters::new();
        let first = shadowed_ref("AHEAD", 60.0);
        let (a, _) = drawn(&rasters, &first, Time::ZERO);
        for i in 0..40 {
            drawn(&rasters, &shadowed_ref(&format!("CUE {i}"), 20.0), Time::ZERO);
        }
        let (b, _) = drawn(&rasters, &first, Time::ZERO);
        assert!(Arc::ptr_eq(&a.pixels, &b.pixels), "the picture drawn ahead was thrown away");
    }

    /// The kept pictures stay within the count limit however many slots are drawn.
    #[test]
    fn the_kept_pictures_stay_within_the_limit() {
        let rasters = LayerRasters::new();
        for i in 0..(KEPT * 3) {
            drawn(&rasters, &shadowed_ref(&format!("N {i}"), 20.0), Time::ZERO);
        }
        let kept = rasters.kept.lock().unwrap();
        assert!(kept.frames.len() <= KEPT && kept.used.len() == kept.frames.len());
    }

    /// A picture drawn again after it was evicted is the same picture (the cache changes timing, never pixels).
    #[test]
    fn an_evicted_picture_is_drawn_again_with_the_same_pixels() {
        let rasters = LayerRasters::new();
        let first = shadowed_ref("AGAIN", 40.0);
        let (a, _) = drawn(&rasters, &first, Time::ZERO);
        for i in 0..(KEPT * 2) {
            drawn(&rasters, &shadowed_ref(&format!("F {i}"), 20.0), Time::ZERO);
        }
        let (b, _) = drawn(&rasters, &first, Time::ZERO);
        assert!(!Arc::ptr_eq(&a.pixels, &b.pixels), "it was evicted");
        assert_eq!(*a.pixels, *b.pixels);
        assert_eq!(a.key, b.key);
    }
}
