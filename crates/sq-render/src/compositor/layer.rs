// Swift: RenderLayer.swift, FrameBlend.swift, MotionBlurNode.swift
//! The render model the compositor draws (layers, nodes, adjustment groups): portable, no GPU types.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use sq_core_effects::effect_transform_stage::MotionBlurSamples;
use sq_core_effects::effects_evaluation::{ClipEffects, ImageFilter};
use sq_core_effects::evaluation::LayerRequest;
use sq_core_effects::temporal_effects::TemporalFilter;
use sq_core_effects::transition::TransitionRender;
use sq_core_masks::SubjectMatte;
use sq_core_model::{BlendMode, ClipTransform, MaskSource, SequenceFormat, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::SQFrame;

use crate::color::ColorPipeline;
use crate::effects::motion_blur_node::sample_transform;

/// What a placeholder layer stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaceholderKind {
    Offline,
    Damaged,
    Loading,
}

/// How a text clip's glyphs use the picture below them (`RenderLayer::footage_fill`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FootageFill {
    /// The glyphs are a window onto what is below: it shows only inside them.
    Stencil,
    /// The glyphs invert what is below them.
    Inverted,
}

/// Which source frame pair a flow field belongs to: the cache key of the optical flow engine. `variant` separates pictures
/// of the same frames that differ before the flow sees them (a stabilized frame, a reduced decode).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FlowPairKey {
    pub media: Id,
    pub from: Time,
    pub to: Time,
    pub variant: i64,
}

/// Motion estimation effort. `Better` is what export and a settled playback frame use (the same pixels); `Faster` (half the
/// working size, fewer iterations) is only for frames while playing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FlowQuality {
    Faster,
    Better,
}

impl FlowQuality {
    /// Longest side of the image the motion is measured on (at most).
    pub fn working_long_side(self) -> i64 {
        if self == FlowQuality::Better { 960 } else { 480 }
    }

    /// Lucas-Kanade steps on the finest levels; the small coarse levels (cheap) get two more.
    pub fn iterations(self) -> i32 {
        if self == FlowQuality::Better { 3 } else { 2 }
    }

    pub fn radius(self) -> i32 {
        if self == FlowQuality::Better { 3 } else { 2 }
    }
}

/// Optical-flow interpolation of one layer: the frames' motion is measured and both frames are moved to the instant.
/// `key` `None` = no caching (the field is measured for this render only).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct OpticalFlowRequest {
    pub key: Option<FlowPairKey>,
    pub quality: FlowQuality,
}

impl OpticalFlowRequest {
    pub fn new(key: Option<FlowPairKey>) -> OpticalFlowRequest {
        OpticalFlowRequest { key, quality: FlowQuality::Better }
    }
}

/// Frame Blending (Time Interpolation): a layer shown at a source time between two decoded source frames is the mix of the
/// frame before and the frame after, weighted by the fractional position (`effects::frame_blend::weight`).
#[derive(Clone)]
pub struct FrameBlend {
    /// The later source frame.
    pub next: SQFrame,
    /// Share of `next` in the mix, 0 ..< 1.
    pub weight: f32,
    /// Optical flow instead of the plain mix; `None` = plain mix.
    pub flow: Option<OpticalFlowRequest>,
}

/// Video Denoise / Deflicker: the filter and the neighboring source frames it reads, nearest first on each side. Fewer
/// neighbors than the filter asks for is fine: the filter uses what it gets.
#[derive(Clone)]
pub struct TemporalFrames {
    pub filter: TemporalFilter,
    pub before: Vec<SQFrame>,
    pub after: Vec<SQFrame>,
}

/// Where a partial buffer lies in the whole picture: its top-left texel and the whole picture's size in texels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ContentPart {
    pub x: i64,
    pub y: i64,
    pub whole_width: i64,
    pub whole_height: i64,
}

impl ContentPart {
    /// A buffer of this size at `x`, `y` lies inside the whole picture.
    pub fn holds(&self, width: i64, height: i64) -> bool {
        self.x >= 0 && self.y >= 0 && self.x + width <= self.whole_width && self.y + height <= self.whole_height
    }
}

/// What a layer shows.
#[derive(Clone)]
pub enum Content {
    Frame {
        frame: SQFrame,
        color_hint: VideoTrackInfo,
    },
    Placeholder(PlaceholderKind),
    /// Linear-light premultiplied half-float raster (text), drawn at exactly `width` x `height` sequence px (no aspect
    /// fit); `transform` positions its center like any other layer.
    LinearPremultiplied {
        frame: SQFrame,
        width: f64,
        height: f64,
    },
    /// Flat color over the whole canvas (transition dips). Display-encoded (BT.709 OETF) 0...1; the compositor linearizes it.
    Solid {
        red: f32,
        green: f32,
        blue: f32,
    },
}

/// One layer of one display frame, built by the caller from a `LayerRequest` + frame cache. `transform` is the already
/// evaluated `LayerRequest::transform`: position = offset from the canvas center in sequence px (y down), scale linear
/// x/y, rotation in degrees (clockwise on screen), anchor = offset from the layer's center in sequence px, opacity 0...1.
/// The layer is drawn at its own (upright) pixel size, one source pixel per sequence pixel at scale 1, scaled/rotated about
/// the anchor; the anchor lands on `canvas center + position`.
#[derive(Clone)]
pub struct RenderLayer {
    pub content: Content,
    pub transform: ClipTransform,
    /// Per-layer color stage slot. `None` = Rec.709 source: the compositor applies only the inverse BT.709 OETF
    /// (source-encoded to working-linear). `Some` = YCbCr to RGB into an intermediate, the color chain (source-encoded to
    /// working-linear, includes the output of the chain), then composite with no further transfer.
    pub color_pipeline: Option<Arc<ColorPipeline>>,
    /// Rounded-corner radius in px of the layer as if it were aspect-fitted into the canvas, applied BEFORE the transform
    /// scale. Clamped to half the shorter side. 0 = square corners.
    pub corner_radius: f64,
    /// Pixel size of the picture before rotation (the track's native size). A decode at reduced quality hands over a
    /// smaller buffer that must still be drawn at the native size. `None` = the buffer's own size.
    pub native_size: Option<(i64, i64)>,
    /// Crop, Rounded Corners and Gaussian Blur of the clip. Identity = the plain path.
    pub effects: ClipEffects,
    /// Opacity > Blend Mode. Normal = plain alpha-over.
    pub blend_mode: BlendMode,
    /// Frame Blending: the second source frame and its weight. Only used with `Frame` content.
    pub blend: Option<FrameBlend>,
    /// Video Denoise / Deflicker: the filter and its neighboring frames. Only used with `Frame` content; takes precedence
    /// over `blend`.
    pub temporal: Option<TemporalFrames>,
    /// The (smoothed) person matte of this frame, covering the clip's own upright frame; read by subject masks.
    pub subject_matte: Option<Arc<SubjectMatte>>,
    /// Magic masks' tracked mattes of this frame, by mask id (`MaskShape::matte_key`).
    pub mattes: HashMap<Id, Arc<SubjectMatte>>,
    /// Only with `LinearPremultiplied` content: the buffer holds a part of the layer's picture, the rest is transparent.
    pub content_part: Option<ContentPart>,
    /// Footage fill (a text clip's glyphs as a stencil): the layer is a matte of what is below it.
    pub footage_fill: Option<FootageFill>,
    /// Motion-blur sub-frame transforms the layer's picture built itself (a text layer adds its own In/Out animation at
    /// each sample time, parallel to `MotionBlurSamples::transforms`, opacity of the whole layer); empty = derive them
    /// from the request's samples.
    pub sample_transforms: Vec<ClipTransform>,
}

impl RenderLayer {
    /// A layer with the Swift defaults.
    pub fn new(content: Content) -> RenderLayer {
        RenderLayer {
            content,
            transform: ClipTransform::IDENTITY,
            color_pipeline: None,
            corner_radius: 0.0,
            native_size: None,
            effects: ClipEffects::none(),
            blend_mode: BlendMode::Normal,
            blend: None,
            temporal: None,
            subject_matte: None,
            mattes: HashMap::new(),
            content_part: None,
            footage_fill: None,
            sample_transforms: Vec::new(),
        }
    }

    /// Footage fill as a stencil.
    pub fn stencil(&self) -> bool {
        self.footage_fill == Some(FootageFill::Stencil)
    }

    /// The stand-in layer of an Adjustment Layer request: draws nothing itself (`RenderNode::tree` turns the request into
    /// an `Adjustment` node over the layers below). `color_pipeline`: the clip's Lumetri grade, run on the picture below.
    pub fn adjustment(transform: ClipTransform, color_pipeline: Option<Arc<ColorPipeline>>) -> RenderLayer {
        RenderLayer { transform, color_pipeline, ..RenderLayer::new(Content::Placeholder(PlaceholderKind::Loading)) }
    }

    /// A solid layer from a solid generator payload (RGB bytes; missing bytes are 0).
    pub fn solid(
        payload: &[u8],
        transform: ClipTransform,
        color_pipeline: Option<Arc<ColorPipeline>>,
        corner_radius: f64,
    ) -> RenderLayer {
        let b = |i: usize| f32::from(payload.get(i).copied().unwrap_or(0)) / 255.0;
        RenderLayer {
            transform,
            color_pipeline,
            corner_radius,
            ..RenderLayer::new(Content::Solid { red: b(0), green: b(1), blue: b(2) })
        }
    }

    /// The same layer with the effects and blend mode of the request it was built from.
    pub fn applying(&self, request: &LayerRequest) -> RenderLayer {
        let mut l = self.clone();
        l.effects = request.effects.clone();
        l.blend_mode =
            if self.footage_fill == Some(FootageFill::Inverted) { BlendMode::Difference } else { request.blend_mode };
        l
    }
}

/// What an Adjustment Layer does to the picture below it (`RenderNode::Adjustment`).
#[derive(Clone)]
pub struct AdjustmentNode {
    /// Motion (opacity 1: see `opacity`).
    pub transform: ClipTransform,
    pub opacity: f64,
    pub corner_radius: f64,
    pub effects: ClipEffects,
    pub blend_mode: BlendMode,
    /// Lumetri: runs first, on the picture below (working-linear, handed to the chain as BT.709-encoded Rec.709).
    pub color_pipeline: Option<Arc<ColorPipeline>>,
    /// Sub-frame Motion of the Transform effect's shutter (opacity 1 each); empty = sharp `transform`.
    pub motion_samples: Vec<ClipTransform>,
    /// Draw the unadjusted picture first. Off when the adjusted draw covers it exactly, and on a transition side.
    pub draws_base: bool,
}

impl AdjustmentNode {
    /// The adjusted draw covers the unadjusted one: full opacity, Normal, no Motion, crop, corner, mask or key, and only
    /// effects that keep the picture's coverage (Sharpen, Noise, the grade). A blur, shadow or moving filter softens the
    /// coverage at the frame edge, where the unadjusted picture shows through.
    pub fn covers_base(&self) -> bool {
        if self.opacity < 1.0
            || self.blend_mode != BlendMode::Normal
            || !covers_canvas(&self.transform)
            || self.corner_radius != 0.0
            || !self.motion_samples.iter().all(covers_canvas)
            || !self.effects.masks.is_empty()
        {
            return false;
        }
        self.effects.segments.iter().all(|s| {
            s.masks.is_identity()
                && s.keys.is_empty()
                && s.blur_after == 0.0
                && s.shadow.is_none()
                && matches!(
                    s.filter,
                    None | Some(
                        ImageFilter::Sharpen { .. } | ImageFilter::UnsharpMask { .. } | ImageFilter::Noise { .. }
                    )
                )
        })
    }
}

/// Motion that still fills the canvas: centered, scale 1 or more on both axes, no rotation, tilt or anchor shift, so the
/// scaled picture's edges lie outside the frame. Opacity is checked by the caller.
// shortcut: a moved or off-anchor zoom is not recognized (needs the canvas size), upgrade when a zoom layer pans.
fn covers_canvas(t: &ClipTransform) -> bool {
    t.position == sq_core_time::Vec2::ZERO
        && t.anchor == sq_core_time::Vec2::ZERO
        && t.rotation == 0.0
        && !t.is_tilted()
        && t.scale.x >= 1.0
        && t.scale.y >= 1.0
}

/// Tree form of a display frame: a leaf layer, or a nested-sequence group whose children are composited offscreen
/// (transparent background, `format` size, half-float premultiplied) and then drawn like a layer at its own size, with the
/// group's `transform`, `opacity` (applied once to the whole image) and `corner_radius` (in the group image's own px).
#[derive(Clone)]
// A layer is large and the other nodes are small; nodes are built once per frame and moved rarely, so no boxing.
#[allow(clippy::large_enum_variant)]
pub enum RenderNode {
    Layer(RenderLayer),
    Group {
        format: SequenceFormat,
        transform: ClipTransform,
        opacity: f64,
        corner_radius: f64,
        children: Vec<RenderNode>,
    },
    /// A group whose nested clip has Crop, Blur, Ultra Key or a blend mode (the plain `Group` is the common case).
    StyledGroup {
        format: SequenceFormat,
        transform: ClipTransform,
        opacity: f64,
        corner_radius: f64,
        children: Vec<RenderNode>,
        effects: ClipEffects,
        blend_mode: BlendMode,
    },
    /// Cross dissolve of two pictures: `first` and `second` (opacities already folded in) are summed as premultiplied
    /// color into one transparent canvas-sized image that is then composited over what is below.
    Pair {
        format: SequenceFormat,
        first: Vec<RenderNode>,
        second: Vec<RenderNode>,
    },
    /// Motion transition: `first` (outgoing) and `second` (incoming) are each composited into their own transparent
    /// canvas-sized image, then `render` moves, scales, smears and combines them into one image composited over what is below.
    Transition {
        format: SequenceFormat,
        render: TransitionRender,
        first: Vec<RenderNode>,
        second: Vec<RenderNode>,
    },
    /// Wraps one node (a pair or group result) that is composited with a blend mode against what is below it.
    Blended(Box<RenderNode>, BlendMode),
    /// Footage fill: `children` (a matte layer drawn with opacity 1) are composited into a transparent canvas-sized image,
    /// which then keeps what is below it only where it covers it, `opacity` mixing the two.
    Stencil {
        opacity: f64,
        children: Vec<RenderNode>,
    },
    /// Adjustment Layer: `below` is composited into one transparent canvas-sized image, drawn plainly (`draws_base`), and
    /// drawn again on top graded and with the effects, Motion, opacity and blend mode.
    Adjustment(AdjustmentNode, Vec<RenderNode>),
    /// Picture masks: the picture of `track` for the Picture masks of this level, rendered once into a transparent image
    /// of the level's canvas, never drawn into the picture.
    PictureMatte {
        track: Id,
        children: Vec<RenderNode>,
    },
    /// Heads the node list of a held transition side. Its Picture masks read only the `PictureMatte`s of that list.
    PictureScope,
}

type Item<'a> = (LayerRequest, &'a RenderLayer);

impl RenderNode {
    /// Builds the tree from flat `LayerRequest`s (bottom to top) and their prepared layers (`layers[i]` belongs to
    /// `requests[i]`). Consecutive layers sharing the same `groups` prefix (same nested clip) form one group, recursively.
    /// The group node's `opacity` is the nested clip's `transform.opacity`; its `transform.opacity` is 1. Unequal arrays pair
    /// up to the shorter one.
    pub fn tree(requests: &[LayerRequest], layers: &[RenderLayer]) -> Vec<RenderNode> {
        let items: Vec<Item> = requests.iter().cloned().zip(layers.iter()).collect();
        build(&items, 0, false, &[])
    }

    /// W7.1 motion blur of one leaf layer: one copy per sub-frame transform, each at 1/n of the layer's opacity, summed as
    /// premultiplied color in a transparent `format` image (a `Pair` whose second side holds all copies after the first:
    /// that side is drawn additively), then composited with the layer's blend mode.
    pub fn motion_blurred(layer: &RenderLayer, request: &LayerRequest, samples: &MotionBlurSamples) -> RenderNode {
        let n = samples.transforms.len();
        let copies: Vec<RenderNode> = samples
            .transforms
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let mut l = layer.clone();
                l.transform = match layer.sample_transforms.get(i) {
                    Some(own) if layer.sample_transforms.len() == n => {
                        let mut t = *own;
                        t.opacity = t.opacity.clamp(0.0, 1.0) / n as f64;
                        t
                    }
                    _ => sample_transform(s, &request.transform, &layer.transform, n),
                };
                l.blend_mode = BlendMode::Normal;
                RenderNode::Layer(l)
            })
            .collect();
        let mut rest = copies;
        let first = rest.remove(0);
        let node = RenderNode::Pair { format: samples.format.clone(), first: vec![first], second: rest };
        if layer.blend_mode == BlendMode::Normal { node } else { RenderNode::Blended(Box::new(node), layer.blend_mode) }
    }

    /// The node of an Adjustment Layer request over `below`; `None` when it cannot change anything (nothing below, fully
    /// transparent, or no effect, no grade, no Motion and blend mode Normal), so the plain layers are drawn as they are.
    fn adjustment(
        req: &LayerRequest,
        layer: &RenderLayer,
        below: Vec<RenderNode>,
        transition_side: bool,
    ) -> Option<RenderNode> {
        let mut t = req.transform;
        let opacity = t.opacity.clamp(0.0, 1.0);
        t.opacity = 1.0;
        let blend = req.blend_mode;
        if below.is_empty() || opacity <= 0.0 || req.effects.is_empty() {
            return None;
        }
        let mut samples = Vec::new();
        if let Some(mb) = req.motion_blur.as_ref().filter(|m| m.transforms.len() > 1) {
            samples = mb
                .transforms
                .iter()
                .map(|s| {
                    let mut s = *s;
                    s.opacity = 1.0;
                    s
                })
                .collect();
        }
        let color = layer.color_pipeline.clone();
        if req.effects.is_identity()
            && req.corner_radius == 0.0
            && blend == BlendMode::Normal
            && t == ClipTransform::IDENTITY
            && samples.is_empty()
            && color.is_none()
        {
            return None;
        }
        let mut a = AdjustmentNode {
            transform: t,
            opacity,
            corner_radius: req.corner_radius,
            effects: req.effects.clone(),
            blend_mode: blend,
            color_pipeline: color,
            motion_samples: samples,
            draws_base: false,
        };
        a.draws_base = !transition_side && !a.covers_base();
        Some(RenderNode::Adjustment(a, below))
    }
}

fn pair_role_is(r: &LayerRequest, role: sq_core_effects::evaluation::PairRole) -> bool {
    r.pair.as_ref().is_some_and(|p| p.role == role)
}

fn stack_role_is(r: &LayerRequest, role: sq_core_effects::evaluation::PairRole) -> bool {
    r.stack_transitions.first().is_some_and(|p| p.role == role)
}

/// `force_normal`: inside a transition pair every picture is plain "over" in the pair's own transparent image; the blend
/// mode belongs to the pair as a whole (see `Blended`). `under`: inside a pair, what is below the pair (an adjustment layer
/// that is one side of the transition adjusts it).
fn build(all: &[Item], depth: usize, force_normal: bool, under: &[RenderNode]) -> Vec<RenderNode> {
    use sq_core_effects::evaluation::PairRole::{First, Second};
    // This level's matte layers come out first (a held transition side's and a pair side's own are built inside that side);
    // a matte no drawn layer of the level reads is left out (no pass).
    let (mattes, items) = picture_mattes(all, depth);
    let mut out: Vec<RenderNode> = Vec::new();
    let mut i = 0;
    while i < items.len() {
        let (req, layer) = (&items[i].0, items[i].1);
        // Transition layer: everything below it at this level forms its two sides, each composited whole, then combined like
        // a motion transition. Outermost first.
        if let Some(st) = req.stack_transitions.first().filter(|st| st.depth == depth) {
            let mut j = i + 1;
            while j < items.len() && items[j].0.stack_transitions.first().map(|s| s.id) == Some(st.id) {
                j += 1;
            }
            let side = |role| -> Vec<RenderNode> {
                let mine: Vec<Item> = items[i..j]
                    .iter()
                    .filter(|it| stack_role_is(&it.0, role))
                    .map(|it| {
                        let mut r = it.0.clone();
                        r.stack_transitions.remove(0);
                        (r, it.1)
                    })
                    .collect();
                let nodes = build(&mine, depth, false, &[]);
                // A held side never inherits the level's live-time mattes; the live side does.
                let held = items[i..j]
                    .iter()
                    .find(|it| stack_role_is(&it.0, role))
                    .is_some_and(|it| it.0.stack_transitions.first().is_some_and(|s| s.held));
                if held && !nodes.is_empty() { [vec![RenderNode::PictureScope], nodes].concat() } else { nodes }
            };
            out.push(RenderNode::Transition {
                format: st.format.clone(),
                render: st.render,
                first: side(First),
                second: side(Second),
            });
            i = j;
            continue;
        }
        if let Some(p) = req.pair.as_ref().filter(|p| p.depth == depth) {
            let mut j = i + 1;
            while j < items.len() && items[j].0.pair.as_ref().map(|q| q.id) == Some(p.id) {
                j += 1;
            }
            let side = |role| -> Vec<RenderNode> {
                let mine: Vec<Item> = items[i..j]
                    .iter()
                    .filter(|it| pair_role_is(&it.0, role))
                    .map(|it| {
                        let mut r = it.0.clone();
                        r.pair = None;
                        (r, it.1)
                    })
                    .collect();
                build(&mine, depth, true, &out)
            };
            // The pair's blend mode is the incoming clip's (second side); when that is Normal the outgoing clip's counts. A
            // nested clip contributes its group's mode.
            let mode = |role| -> BlendMode {
                match items[i..j].iter().find(|it| pair_role_is(&it.0, role)) {
                    None => BlendMode::Normal,
                    Some(it) if it.0.groups.len() > depth => it.0.groups[depth].blend_mode,
                    Some(it) => it.0.blend_mode,
                }
            };
            let incoming = mode(Second);
            let blend = if incoming != BlendMode::Normal { incoming } else { mode(First) };
            let node = match &p.render {
                Some(r) => RenderNode::Transition {
                    format: p.format.clone(),
                    render: *r,
                    first: side(First),
                    second: side(Second),
                },
                None => RenderNode::Pair { format: p.format.clone(), first: side(First), second: side(Second) },
            };
            out.push(if blend == BlendMode::Normal { node } else { RenderNode::Blended(Box::new(node), blend) });
            i = j;
            continue;
        }
        if req.groups.len() <= depth {
            if req.is_adjustment() {
                // One side of a transition: the side is the adjusted picture alone (opacity = the transition weight), over
                // what is under the pair. A dissolve then gives (1 - w) * adjusted + w * other, so the adjustment fades.
                let below = if force_normal { [under.to_vec(), out.clone()].concat() } else { out.clone() };
                if let Some(node) = RenderNode::adjustment(req, layer, below, force_normal) {
                    out = vec![node];
                }
                i += 1;
                continue;
            }
            // Safety: a matte layer that reached here (no level reads it) is never drawn.
            if req.matte_for.is_some() {
                i += 1;
                continue;
            }
            let mut l = layer.clone();
            if force_normal {
                l.blend_mode = BlendMode::Normal;
                l.footage_fill = None;
            }
            // Same as Swift (RenderLayer.swift:234): a stencil layer has no motion blur (one sample; the blur copies are transparent intermediates the
            // stencil cannot read); upgrade by stenciling the summed copies when asked for.
            if let Some(mb) = req.motion_blur.as_ref().filter(|m| m.transforms.len() > 1 && !l.stencil()) {
                out.push(RenderNode::motion_blurred(&l, req, mb));
            } else {
                out.push(RenderNode::Layer(l));
            }
            i += 1;
            continue;
        }
        let g = &req.groups[depth];
        let mut j = i + 1;
        while j < items.len() && items[j].0.groups.len() > depth && items[j].0.groups[depth].clip == g.clip {
            j += 1;
        }
        let mut t = g.transform;
        let opacity = t.opacity;
        t.opacity = 1.0;
        let kids = build(&items[i..j], depth + 1, false, &[]);
        let group_blend = if force_normal { BlendMode::Normal } else { g.blend_mode };
        let pre = g.effects.pre();
        let plain = group_blend == BlendMode::Normal
            && g.effects.segments.len() <= 1
            && pre.crop.is_identity()
            && pre.feather == 0.0
            && g.effects.keys().is_empty()
            && !pre.round_first
            && g.effects.masks.is_empty();
        let group_node = |t: ClipTransform, opacity: f64, children: Vec<RenderNode>, blend_mode: BlendMode| {
            if plain {
                RenderNode::Group {
                    format: g.format.clone(),
                    transform: t,
                    opacity,
                    corner_radius: g.corner_radius,
                    children,
                }
            } else {
                RenderNode::StyledGroup {
                    format: g.format.clone(),
                    transform: t,
                    opacity,
                    corner_radius: g.corner_radius,
                    children,
                    effects: g.effects.clone(),
                    blend_mode,
                }
            }
        };
        // Motion blur of the nested clip: one copy of the group image per sub-frame transform at 1/n of the opacity, summed
        // in the parent's canvas (as for a leaf layer), then blended as a whole.
        match g.motion_blur.as_ref().filter(|m| m.transforms.len() > 1) {
            Some(mb) => {
                let n = mb.transforms.len();
                let mut copies: Vec<RenderNode> = mb
                    .transforms
                    .iter()
                    .map(|s| {
                        let mut st = sample_transform(s, &g.transform, &g.transform, n);
                        let o = st.opacity;
                        st.opacity = 1.0;
                        group_node(st, o, kids.clone(), BlendMode::Normal)
                    })
                    .collect();
                let first = copies.remove(0);
                let node = RenderNode::Pair { format: mb.format.clone(), first: vec![first], second: copies };
                out.push(if group_blend == BlendMode::Normal {
                    node
                } else {
                    RenderNode::Blended(Box::new(node), group_blend)
                });
            }
            None => out.push(group_node(t, opacity, kids, group_blend)),
        }
        i = j;
    }
    [mattes, out].concat()
}

/// Splits off the matte layers of level `depth` (not inside a transition side or pair of this level): one `PictureMatte`
/// per track that a drawn layer of this level reads, in first-seen order. Returns the remaining items.
fn picture_mattes<'a>(items: &[Item<'a>], depth: usize) -> (Vec<RenderNode>, Vec<Item<'a>>) {
    let is_matte = |r: &LayerRequest| {
        r.matte_for.is_some()
            && r.matte_depth == depth
            && r.stack_transitions.first().is_none_or(|s| s.depth != depth)
            && r.pair.as_ref().is_none_or(|p| p.depth != depth)
    };
    if !items.iter().any(|i| is_matte(&i.0)) {
        return (Vec::new(), items.to_vec());
    }
    let mut rest: Vec<Item<'a>> = Vec::new();
    let mut order: Vec<Id> = Vec::new();
    let mut by_track: HashMap<Id, Vec<Item<'a>>> = HashMap::new();
    for item in items {
        let Some(t) = item.0.matte_for.filter(|_| is_matte(&item.0)) else {
            rest.push(item.clone());
            continue;
        };
        let mut r = item.0.clone();
        r.matte_for = None;
        if !by_track.contains_key(&t) {
            order.push(t);
        }
        by_track.entry(t).or_default().push((r, item.1));
    }
    let read = read_tracks(&rest, depth);
    let mut nodes = Vec::new();
    for t in order.into_iter().filter(|t| read.contains(t)) {
        let kids = build(by_track.get(&t).map_or(&[], Vec::as_slice), depth, false, &[]);
        if !kids.is_empty() {
            nodes.push(RenderNode::PictureMatte { track: t, children: kids });
        }
    }
    (nodes, rest)
}

/// The tracks the Picture masks (clip masks and effect mask inputs) of level `depth` read: each drawn layer's own masks when
/// it lives at that level, else those of its nested clip there.
fn read_tracks(items: &[Item], depth: usize) -> Vec<Id> {
    let mut out = Vec::new();
    let mut add = |m: &sq_core_masks::MaskShape| {
        if m.source == MaskSource::Picture
            && let Some(t) = m.picture_track
            && !out.contains(&t)
        {
            out.push(t);
        }
    };
    for (r, _) in items.iter().filter(|(r, _)| r.matte_for.is_none()) {
        let fx = if r.groups.len() > depth { &r.groups[depth].effects } else { &r.effects };
        fx.masks.iter().for_each(&mut add);
        fx.segments.iter().for_each(|s| s.scope.iter().for_each(&mut add));
    }
    out
}

/// Errors of the compositor.
#[derive(Debug)]
pub enum CompositorError {
    ShaderCompilation(String),
    MissingFunction(String),
    ResourceAllocation,
    InvalidTarget(String),
    Gpu(sq_gpu::gpu::GpuError),
}

impl fmt::Display for CompositorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ShaderCompilation(s) => write!(f, "shader compilation: {s}"),
            Self::MissingFunction(s) => write!(f, "missing function: {s}"),
            Self::ResourceAllocation => write!(f, "resource allocation failed"),
            Self::InvalidTarget(s) => write!(f, "invalid target: {s}"),
            Self::Gpu(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for CompositorError {}

impl From<sq_gpu::gpu::GpuError> for CompositorError {
    fn from(e: sq_gpu::gpu::GpuError) -> CompositorError {
        CompositorError::Gpu(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::effects_evaluation::{EffectMasks, EffectSegment};
    use sq_core_effects::evaluation::{LayerGroup, PairInfo, PairRole};
    use sq_core_model::GeneratorRef;
    use sq_core_time::Vec2;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn request(n: u128) -> LayerRequest {
        LayerRequest::new(id(n), id(100 + n), id(200), Time::ZERO)
    }

    fn layer() -> RenderLayer {
        RenderLayer::new(Content::Solid { red: 0.5, green: 0.5, blue: 0.5 })
    }

    fn format(w: i64, h: i64) -> SequenceFormat {
        SequenceFormat {
            width: w,
            height: h,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        }
    }

    fn group(clip: u128) -> LayerGroup {
        LayerGroup::new(id(clip), id(200), id(300), format(64, 48))
    }

    fn adjustment_request(n: u128, effects: ClipEffects) -> LayerRequest {
        let mut r = request(n);
        r.generator = Some(GeneratorRef { kind: "adjustment".into(), payload: Vec::new(), payload_version: 1 });
        r.effects = effects;
        r
    }

    fn blur() -> ClipEffects {
        ClipEffects::new(
            vec![EffectSegment { blur_after: 2.0, ..EffectSegment::default() }, EffectSegment::default()],
            Vec::new(),
            Default::default(),
        )
    }

    fn kinds(nodes: &[RenderNode]) -> Vec<&'static str> {
        nodes
            .iter()
            .map(|n| match n {
                RenderNode::Layer(_) => "layer",
                RenderNode::Group { .. } => "group",
                RenderNode::StyledGroup { .. } => "styled",
                RenderNode::Pair { .. } => "pair",
                RenderNode::Transition { .. } => "transition",
                RenderNode::Blended(..) => "blended",
                RenderNode::Stencil { .. } => "stencil",
                RenderNode::Adjustment(..) => "adjustment",
                RenderNode::PictureMatte { .. } => "matte",
                RenderNode::PictureScope => "scope",
            })
            .collect()
    }

    #[test]
    fn flat_requests_become_layers_in_order() {
        let tree = RenderNode::tree(&[request(1), request(2)], &[layer(), layer()]);
        assert_eq!(kinds(&tree), ["layer", "layer"]);
        // Unequal arrays pair up to the shorter one.
        assert_eq!(RenderNode::tree(&[request(1), request(2)], &[layer()]).len(), 1);
    }

    #[test]
    fn a_nested_clip_with_motion_blur_draws_one_group_copy_per_sample() {
        let mut a = request(1);
        let mut g = group(50);
        g.transform.opacity = 1.0;
        let mut moved = g.transform;
        moved.position = Vec2::new(10.0, 0.0);
        g.motion_blur = Some(MotionBlurSamples {
            format: format(64, 48),
            transforms: vec![g.transform, moved],
            local_times: vec![],
        });
        a.groups = vec![g];
        let tree = RenderNode::tree(&[a], &[layer()]);
        assert_eq!(kinds(&tree), ["pair"]);
        let RenderNode::Pair { first, second, .. } = &tree[0] else { panic!("pair expected") };
        let (RenderNode::Group { opacity: o1, .. }, RenderNode::Group { transform, opacity: o2, .. }) =
            (&first[0], &second[0])
        else {
            panic!("groups expected")
        };
        assert_eq!((*o1, *o2), (0.5, 0.5));
        assert_eq!(transform.position, Vec2::new(10.0, 0.0));
    }

    #[test]
    fn layers_of_one_nested_clip_form_one_group_with_the_clips_opacity() {
        let mut a = request(1);
        let mut g = group(50);
        g.transform.opacity = 0.4;
        g.transform.position = Vec2::new(5.0, 0.0);
        a.groups = vec![g.clone()];
        let mut b = request(2);
        b.groups = vec![g];
        let tree = RenderNode::tree(&[request(0), a, b, request(3)], &[layer(), layer(), layer(), layer()]);
        assert_eq!(kinds(&tree), ["layer", "group", "layer"]);
        let RenderNode::Group { transform, opacity, children, .. } = &tree[1] else { panic!("group expected") };
        assert_eq!((children.len(), *opacity, transform.opacity, transform.position.x), (2, 0.4, 1.0, 5.0));
    }

    #[test]
    fn a_group_with_a_blend_mode_or_effects_is_styled() {
        let mut g = group(50);
        g.blend_mode = BlendMode::Screen;
        let mut a = request(1);
        a.groups = vec![g];
        let mut blurred = group(51);
        blurred.effects = blur();
        let mut b = request(2);
        b.groups = vec![blurred];
        let tree = RenderNode::tree(&[a, b], &[layer(), layer()]);
        assert_eq!(kinds(&tree), ["styled", "styled"]);
        // A single segment without crop is still plain.
        let mut plain = group(52);
        plain.effects = ClipEffects::new(vec![EffectSegment::default()], Vec::new(), Default::default());
        let mut c = request(3);
        c.groups = vec![plain];
        assert_eq!(kinds(&RenderNode::tree(&[c], &[layer()])), ["group"]);
        let mut cropped = group(53);
        cropped.effects = ClipEffects::new(
            vec![EffectSegment {
                masks: EffectMasks { round_first: true, ..EffectMasks::NONE },
                ..EffectSegment::default()
            }],
            Vec::new(),
            Default::default(),
        );
        let mut d = request(4);
        d.groups = vec![cropped];
        assert_eq!(kinds(&RenderNode::tree(&[d], &[layer()])), ["styled"]);
    }

    #[test]
    fn the_two_layers_of_a_dissolve_form_a_pair_with_the_incoming_blend_mode() {
        let pair = |n: u128, role| {
            let mut r = request(n);
            r.pair = Some(PairInfo::new(id(9), role, format(64, 48), 0));
            r
        };
        let mut incoming = pair(2, PairRole::Second);
        incoming.blend_mode = BlendMode::Multiply;
        let mut outgoing_layer = layer();
        outgoing_layer.blend_mode = BlendMode::Screen;
        let tree = RenderNode::tree(&[pair(1, PairRole::First), incoming], &[outgoing_layer, layer()]);
        assert_eq!(kinds(&tree), ["blended"]);
        let RenderNode::Blended(inner, mode) = &tree[0] else { panic!("blended expected") };
        assert_eq!(*mode, BlendMode::Multiply);
        let RenderNode::Pair { first, second, .. } = &**inner else { panic!("pair expected") };
        // Inside a pair every picture is plain "over".
        let RenderNode::Layer(l) = &first[0] else { panic!("layer expected") };
        assert_eq!((first.len(), second.len(), l.blend_mode), (1, 1, BlendMode::Normal));
    }

    #[test]
    fn an_adjustment_layer_adjusts_what_is_below_and_is_dropped_when_it_changes_nothing() {
        let below = request(1);
        let nothing = adjustment_request(2, ClipEffects::none());
        assert_eq!(
            kinds(&RenderNode::tree(
                &[below.clone(), nothing],
                &[layer(), RenderLayer::adjustment(ClipTransform::IDENTITY, None)]
            )),
            ["layer"]
        );
        let blurred = adjustment_request(3, blur());
        let tree = RenderNode::tree(
            &[below.clone(), blurred],
            &[layer(), RenderLayer::adjustment(ClipTransform::IDENTITY, None)],
        );
        assert_eq!(kinds(&tree), ["adjustment"]);
        let RenderNode::Adjustment(a, under) = &tree[0] else { panic!("adjustment expected") };
        assert_eq!(under.len(), 1);
        assert!(a.draws_base, "a blur softens the edge, the unadjusted picture shows through");
        // Nothing below: nothing to adjust.
        assert!(
            RenderNode::tree(
                &[adjustment_request(4, blur())],
                &[RenderLayer::adjustment(ClipTransform::IDENTITY, None)]
            )
            .is_empty()
        );
    }

    #[test]
    fn an_adjustment_covers_its_base_only_with_coverage_keeping_effects() {
        let node = |effects: ClipEffects| AdjustmentNode {
            transform: ClipTransform::IDENTITY,
            opacity: 1.0,
            corner_radius: 0.0,
            effects,
            blend_mode: BlendMode::Normal,
            color_pipeline: None,
            motion_samples: Vec::new(),
            draws_base: false,
        };
        assert!(node(ClipEffects::none()).covers_base());
        assert!(!node(blur()).covers_base());
        let mut half = node(ClipEffects::none());
        half.opacity = 0.5;
        assert!(!half.covers_base());
        let mut moved = node(ClipEffects::none());
        moved.transform.position = Vec2::new(1.0, 0.0);
        assert!(!moved.covers_base());
    }

    fn zoom(scale: f64) -> ClipTransform {
        let mut t = ClipTransform::IDENTITY;
        t.scale = Vec2::new(scale, scale);
        t
    }

    fn zoom_request(n: u128, scale: f64) -> LayerRequest {
        let mut r = adjustment_request(n, ClipEffects::none());
        r.transform = zoom(scale);
        r
    }

    fn adj_layer() -> RenderLayer {
        RenderLayer::adjustment(ClipTransform::IDENTITY, None)
    }

    #[test]
    fn a_motion_only_adjustment_over_broll_and_text_is_one_node_with_both_below() {
        let tree = RenderNode::tree(&[request(1), request(2), zoom_request(3, 1.1)], &[layer(), layer(), adj_layer()]);
        assert_eq!(kinds(&tree), ["adjustment"]);
        let RenderNode::Adjustment(a, under) = &tree[0] else { panic!("adjustment expected") };
        assert_eq!(under.len(), 2);
        assert!(!a.draws_base, "a 110 % zoom covers the canvas: one draw");
        let tree = RenderNode::tree(&[request(1), zoom_request(3, 0.9)], &[layer(), adj_layer()]);
        let RenderNode::Adjustment(a, _) = &tree[0] else { panic!("adjustment expected") };
        assert!(a.draws_base, "90 % leaves the edges open: the base shows through");
    }

    /// A7: an Adjustment Layer inside a nested clip adjusts only the layers of that nested sequence; the outer layer
    /// below the nested clip stays outside of its `below`. An outer layer above a nested one never reaches into it.
    #[test]
    fn an_adjustment_inside_a_nested_clip_reaches_only_the_inner_layers() {
        let outer = request(1);
        let mut inner = request(2);
        inner.groups = vec![group(50)];
        let mut adj = adjustment_request(3, blur());
        adj.groups = vec![group(50)];
        let tree = RenderNode::tree(&[outer, inner, adj], &[layer(), layer(), adj_layer()]);
        assert_eq!(kinds(&tree), ["layer", "group"]);
        let RenderNode::Group { children, .. } = &tree[1] else { panic!("group expected") };
        assert_eq!(kinds(children), ["adjustment"]);
        let RenderNode::Adjustment(_, under) = &children[0] else { panic!("adjustment expected") };
        assert_eq!(under.len(), 1, "only the inner layer");
        // The same layer on the outer level adjusts the nested clip and the outer layer together.
        let mut inner = request(2);
        inner.groups = vec![group(50)];
        let flat =
            RenderNode::tree(&[request(1), inner, adjustment_request(3, blur())], &[layer(), layer(), adj_layer()]);
        assert_eq!(kinds(&flat), ["adjustment"]);
        let RenderNode::Adjustment(_, under) = &flat[0] else { panic!("adjustment expected") };
        assert_eq!(kinds(under), ["layer", "group"]);
    }

    #[test]
    fn a_motion_adjustment_at_rest_is_no_node_and_samples_must_all_cover() {
        let tree = RenderNode::tree(&[request(1), zoom_request(3, 1.0)], &[layer(), adj_layer()]);
        assert_eq!(kinds(&tree), ["layer"]);
        let mut a = AdjustmentNode {
            transform: zoom(1.1),
            opacity: 1.0,
            corner_radius: 0.0,
            effects: ClipEffects::none(),
            blend_mode: BlendMode::Normal,
            color_pipeline: None,
            motion_samples: vec![zoom(1.0), zoom(1.2)],
            draws_base: false,
        };
        assert!(a.covers_base());
        a.motion_samples.push(zoom(0.95));
        assert!(!a.covers_base());
        let mut rotated = zoom(1.5);
        rotated.rotation = 5.0;
        a.motion_samples.clear();
        a.transform = rotated;
        assert!(!a.covers_base());
    }

    #[test]
    fn motion_blur_sums_the_copies_in_a_pair_at_equal_opacity() {
        let mut l = layer();
        l.blend_mode = BlendMode::Overlay;
        l.transform.opacity = 0.8;
        let req = request(1);
        let mut moved = ClipTransform::IDENTITY;
        moved.position = Vec2::new(4.0, 0.0);
        let samples = MotionBlurSamples {
            format: format(64, 48),
            transforms: vec![ClipTransform::IDENTITY, moved],
            local_times: vec![],
        };
        let RenderNode::Blended(inner, mode) = RenderNode::motion_blurred(&l, &req, &samples) else {
            panic!("blended expected")
        };
        assert_eq!(mode, BlendMode::Overlay);
        let RenderNode::Pair { first, second, .. } = *inner else { panic!("pair expected") };
        let (RenderNode::Layer(a), RenderNode::Layer(b)) = (&first[0], &second[0]) else { panic!("layers expected") };
        assert_eq!((a.transform.opacity, b.transform.opacity, b.transform.position.x), (0.4, 0.4, 4.0));
        assert_eq!((a.blend_mode, b.blend_mode), (BlendMode::Normal, BlendMode::Normal));
    }

    #[test]
    fn a_matte_layer_is_rendered_once_and_only_when_a_layer_reads_it() {
        let track = id(777);
        let mut m = request(1);
        m.matte_for = Some(track);
        let matte_layer = layer();
        // Nothing reads the matte: it is left out and never drawn.
        assert_eq!(kinds(&RenderNode::tree(&[m.clone(), request(2)], &[matte_layer.clone(), layer()])), ["layer"]);
        let mut reader = request(2);
        let mut mask = sq_core_masks::MaskShape::new(Vec::new());
        mask.source = MaskSource::Picture;
        mask.picture_track = Some(track);
        reader.effects = ClipEffects::new(vec![EffectSegment::default()], vec![mask], Default::default());
        let tree = RenderNode::tree(&[m, reader], &[matte_layer, layer()]);
        assert_eq!(kinds(&tree), ["matte", "layer"]);
    }

    #[test]
    fn solid_payload_bytes_and_part_bounds() {
        let RenderLayer { content: Content::Solid { red, green, blue }, .. } =
            RenderLayer::solid(&[255, 0], ClipTransform::IDENTITY, None, 0.0)
        else {
            panic!("solid expected")
        };
        assert_eq!((red, green, blue), (1.0, 0.0, 0.0));
        let part = ContentPart { x: 4, y: 2, whole_width: 16, whole_height: 8 };
        assert!(part.holds(12, 6));
        assert!(!part.holds(13, 6));
        assert!(!ContentPart { x: -1, ..part }.holds(1, 1));
    }
}
