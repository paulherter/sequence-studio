// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Evaluation.swift, PictureMask.swift (`LayerRequest` helpers), PosterizeTime.swift (`posterizedTime`),
// LayerOcclusion.swift (`evaluation/layer_occlusion.rs`)
//! What is visible and audible at one instant. Nested sequences are flattened into the layer list, bottom to top, each
//! layer tagged with the nested clips (`groups`, outermost first) it lives in.
//!
//! Composition order for the compositor, per group:
//! 1. composite the group's inner layers (in order) into a transparent offscreen image of `group.format` size, each inner
//!    layer with its own transform, opacity and corner radius (recursively for deeper groups);
//! 2. treat that image as a layer of the nested clip: apply the group's corner radius (in the image's own pixels), then
//!    its `transform` (anchor, scale, rotation, position, in the parent sequence's pixels), then its opacity as one factor
//!    for the whole image (not per inner layer).
//!
//! A layer with empty `groups` belongs to the top sequence. Transforms are deliberately not multiplied into the inner
//! layers' transforms: rotation after non-uniform scale is not a scale+rotate of the parts, and group opacity is not the
//! product of the inner opacities.

pub mod layer_occlusion;

use crate::effect_transform_stage::{ClipStageEval, MotionBlurSamples};
use crate::effects_evaluation::{ClipEffects, ClipEffectsEval};
use crate::transition::{TrackTransitions, TransitionEnvelope, TransitionKindExt, TransitionMix, TransitionRender};
use crate::transition_layer::{ClipTransitionLayer, TrackTransitionLayer, stack_render};
use sq_core_audio::ToneClipExt;
use sq_core_color::ClipGradeExt;
use sq_core_masks::{ClipStabilizeExt, GyroflowOptions, MaskInputsExt, PictureMaskTimelineExt};
use sq_core_model::{
    BlendMode, Clip, ClipColor, ClipSpeed, ClipTransform, FormatVariant, GeneratorRef, GraphicsDocument, GraphicsLayer,
    SequenceFormat, ShapeStyle, TimeInterpolation, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, Time, TimeRange, Vec2};
use std::collections::BTreeSet;

/// A nested-sequence clip that a layer sits inside. The layer's own coordinates are in the inner sequence; the group
/// describes how that inner picture is placed into the parent.
#[derive(Clone, Debug, PartialEq)]
pub struct LayerGroup {
    /// The nested clip in the parent sequence.
    pub clip: Id,
    /// The track the nested clip sits on.
    pub track: Id,
    /// The inner sequence.
    pub sequence: Id,
    /// The inner sequence's format (size of the offscreen image the inner layers are composited into).
    pub format: SequenceFormat,
    /// Evaluated transform (incl. opacity) of the nested clip at this instant.
    pub transform: ClipTransform,
    /// Corner radius of the nested clip at this instant.
    pub corner_radius: f64,
    /// Crop, Rounded Corners, Gaussian Blur and Ultra Key of the nested clip, applied to the group image as a whole.
    pub effects: ClipEffects,
    /// How the group image meets the layers below.
    pub blend_mode: BlendMode,
    /// Sub-frame transforms of the nested clip when its Shutter Angle blurs its motion (`None` = sharp): the whole group
    /// image is drawn once per sample.
    pub motion_blur: Option<MotionBlurSamples>,
}

impl LayerGroup {
    /// A group with an identity transform, no effects and Normal blending.
    pub fn new(clip: Id, track: Id, sequence: Id, format: SequenceFormat) -> LayerGroup {
        LayerGroup {
            clip,
            track,
            sequence,
            format,
            transform: ClipTransform::IDENTITY,
            corner_radius: 0.0,
            effects: ClipEffects::none(),
            blend_mode: BlendMode::Normal,
            motion_blur: None,
        }
    }
}

/// Which side of a pair a layer is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PairRole {
    /// The outgoing clip.
    First,
    /// The incoming clip.
    Second,
}

/// Set on the two layers of a cross dissolve (opacities already 1-w and w): the compositor sums them as premultiplied
/// color instead of compositing B over A.
#[derive(Clone, Debug, PartialEq)]
pub struct PairInfo {
    /// The transition.
    pub id: Id,
    /// Which side this layer is.
    pub role: PairRole,
    /// The canvas the pair is summed in.
    pub format: SequenceFormat,
    /// Nesting depth (`groups.count`) of the sequence the pair lives in.
    pub depth: usize,
    /// Set for a motion transition: the two sides are composited apart and combined by this (not summed). A side may be
    /// missing (single-sided transition, disabled clip): `First` is always the outgoing clip, `Second` the incoming.
    pub render: Option<TransitionRender>,
}

impl PairInfo {
    /// A plain dissolve pair.
    pub fn new(id: Id, role: PairRole, format: SequenceFormat, depth: usize) -> PairInfo {
        PairInfo { id, role, format, depth, render: None }
    }
}

/// One transition layer a `LayerRequest` takes part in (`LayerRequest::stack_transitions`, outermost first).
#[derive(Clone, Debug, PartialEq)]
pub struct StackTransition {
    /// The transition layer clip.
    pub id: Id,
    /// `First`: the request belongs to the outgoing stack (before the cut), `Second` to the incoming one.
    pub role: PairRole,
    /// Canvas the two sides are composited in.
    pub format: SequenceFormat,
    /// Nesting depth (`groups.count`) of the sequence the layer lives in.
    pub depth: usize,
    /// How the two side images are combined (a dissolve or dip is `Sum` with the side opacities).
    pub render: TransitionRender,
    /// C6: this side is held at another time than the level (its edge frame), so its Picture masks read only the mattes
    /// evaluated with it (possibly none), never the level's live ones.
    pub held: bool,
}

/// What is visible at one instant for one track.
#[derive(Clone, Debug, PartialEq)]
pub struct LayerRequest {
    /// The clip (or graphics layer) drawn.
    pub clip: Id,
    /// The media to decode.
    pub media: Id,
    /// The track the clip sits on.
    pub track: Id,
    /// `Clip::source_time`: the source frame time shown at this instant (through speed and reverse), in the clip's own
    /// (inner) timeline.
    pub source_time: Time,
    /// Evaluated (clamped) transform of the clip at this instant.
    pub transform: ClipTransform,
    /// Rounded Corners radius in canvas pixels of the clip's own frame, >= 0.
    pub corner_radius: f64,
    /// Enclosing nested clips, outermost first. Empty for layers of the top sequence.
    pub groups: Vec<LayerGroup>,
    /// Set for a generator clip (text layer): there is no media to decode, render this instead.
    pub generator: Option<GeneratorRef>,
    /// Set for a shape generator: the shape evaluated at this instant. `None` with a shape generator = its Shape effect is
    /// switched off (draw nothing).
    pub shape: Option<ShapeStyle>,
    /// `t - clip.start`: time since the clip's first frame (drives animations such as text in/out). For a generator,
    /// `source_time` equals this.
    pub local_time: Time,
    /// The clip's static color settings (resolved against the media by the renderer).
    pub color: ClipColor,
    /// How a source time between two frames is shown (Time Interpolation of the clip). Never for a held clip.
    pub interpolation: TimeInterpolation,
    /// End of the clip's source range: a blend never reads a frame that starts at or after it. `None` = unbounded.
    pub source_end: Option<Time>,
    /// Start of the clip's source range: a temporal filter never reads a frame that ends at or before it. `None` =
    /// unbounded.
    pub source_start: Option<Time>,
    /// Evaluated Crop, Rounded Corners and Gaussian Blur of the clip (`corner_radius` above is its first pass's radius).
    pub effects: ClipEffects,
    /// How this layer is combined with the ones below it.
    pub blend_mode: BlendMode,
    /// Set on the two layers of a cross dissolve.
    pub pair: Option<PairInfo>,
    /// The layer belongs to a transition in progress (either side of a dissolve or dip, or a fade): the engine holds the
    /// last frame rather than draw a half-decoded transition.
    pub in_transition: bool,
    /// W7.1: sub-frame transforms when a Transform effect's Shutter Angle blurs the motion; `None` = sharp.
    pub motion_blur: Option<MotionBlurSamples>,
    /// GFX: set on a layer of a graphics clip (the clip is its last group): that clip's length, which text animations
    /// anchor their out phase on (the layer's own id is not a timeline clip).
    pub clip_duration: Option<Time>,
    /// The clip's enabled Stabilizer uses Gyroflow: the decoded source frame is warped by the gyro engine with these
    /// options before anything else. `None` = no gyro warp.
    pub gyro: Option<GyroflowOptions>,
    /// The clip is reversed: its source frames fall while the timeline plays on (the engine decodes a GOP window).
    pub reversed: bool,
    /// Transition layers this layer is part of (it lies on a track below them), outermost (highest) first.
    pub stack_transitions: Vec<StackTransition>,
    /// C6 Picture masks: set on the layers of a matte track (evaluated alone at the same time, eye ignored, transition
    /// layers dropped) that the Picture masks naming this track read. `None` for every drawn layer.
    pub matte_for: Option<Id>,
    /// Nesting level (`groups.count` of the consumers) whose Picture masks read this matte layer. Only meaningful with
    /// `matte_for`.
    pub matte_depth: usize,
}

impl LayerRequest {
    /// A request with the Swift defaults: identity transform, no group, no effects, Normal blending.
    pub fn new(clip: Id, media: Id, track: Id, source_time: Time) -> LayerRequest {
        LayerRequest {
            clip,
            media,
            track,
            source_time,
            transform: ClipTransform::IDENTITY,
            corner_radius: 0.0,
            groups: Vec::new(),
            generator: None,
            shape: None,
            local_time: source_time,
            color: ClipColor::default(),
            interpolation: TimeInterpolation::FrameSampling,
            source_end: None,
            source_start: None,
            effects: ClipEffects::none(),
            blend_mode: BlendMode::Normal,
            pair: None,
            in_transition: false,
            motion_blur: None,
            clip_duration: None,
            gyro: None,
            reversed: false,
            stack_transitions: Vec::new(),
            matte_for: None,
            matte_depth: 0,
        }
    }

    /// The Picture masks this request reads at nesting level `level` (its own masks when it lives at that level, else the
    /// masks of its enclosing clip there), with the track of the clip that owns them.
    pub(crate) fn picture_tracks_at_level(&self, level: usize) -> Option<(Id, Vec<Id>)> {
        let (fx, owner) = if self.groups.len() == level {
            (&self.effects, self.track)
        } else if self.groups.len() > level {
            (&self.groups[level].effects, self.groups[level].track)
        } else {
            return None;
        };
        let picture = |m: &&sq_core_masks::MaskShape| m.source == sq_core_model::MaskSource::Picture;
        let mut ids: Vec<Id> = fx.masks.iter().filter(picture).filter_map(|m| m.picture_track).collect();
        for s in &fx.segments {
            ids.extend(s.scope.iter().filter(picture).filter_map(|m| m.picture_track));
        }
        if ids.is_empty() { None } else { Some((owner, ids)) }
    }

    /// No chains: a matte layer's own Picture masks (and those of the clips it sits in from `level` on) read nothing.
    fn dropping_picture_links(&self, level: usize) -> LayerRequest {
        fn drop_links(fx: &mut ClipEffects) {
            use sq_core_model::MaskSource::Picture;
            let has = fx.masks.iter().any(|m| m.source == Picture)
                || fx.segments.iter().any(|s| s.scope.iter().any(|m| m.source == Picture));
            if !has {
                return;
            }
            for m in fx.masks.iter_mut().filter(|m| m.source == Picture) {
                m.picture_track = None;
            }
            for s in &mut fx.segments {
                for m in s.scope.iter_mut().filter(|m| m.source == Picture) {
                    m.picture_track = None;
                }
            }
        }
        let mut r = self.clone();
        drop_links(&mut r.effects);
        for (g, group) in r.groups.iter_mut().enumerate() {
            if g >= level {
                drop_links(&mut group.effects);
            }
        }
        r
    }

    /// The layer is an Adjustment Layer.
    pub fn is_adjustment(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == "adjustment")
    }
}

/// The matte layers of `track`, evaluated alone (`layers`): adjustment layers of that track dropped (no picture of their
/// own), Picture links on them cleared (no chains), each tagged `matte_for`.
pub fn matte_layers(layers: &[LayerRequest], track: Id, level: usize) -> Vec<LayerRequest> {
    layers
        .iter()
        .filter_map(|l| {
            if l.groups.len() == level && l.is_adjustment() {
                return None;
            }
            let mut r = l.dropping_picture_links(level);
            r.matte_for = Some(track);
            r.matte_depth = level;
            // Never grouped with drawn layers into a pair (the compositor groups neighboring requests by pair id) and never
            // a held transition frame. A dissolve on the matte track is drawn as plain "over" in the matte.
            if r.pair.as_ref().is_some_and(|p| p.depth <= level) {
                r.pair = None;
            }
            r.in_transition = false;
            Some(r)
        })
        .collect()
}

/// A nested audio clip an `AudioSegment` sits inside.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioNest {
    /// The nested clip.
    pub clip: Clip,
    /// The track it sits on.
    pub track: Id,
    /// Audio transitions of the nested clip (gain curves in the nest's own outer time).
    pub envelopes: Vec<TransitionEnvelope>,
}

/// One clip's contribution to a timeline range.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioSegment {
    /// The clip.
    pub clip: Id,
    /// The media to read.
    pub media: Id,
    /// The track.
    pub track: Id,
    /// In top-sequence time, also for segments inside nested sequences.
    pub timeline: TimeRange,
    /// Media time at `timeline.start`.
    pub source_start: Time,
    /// Enclosing nested audio clips, outermost first. Empty for segments of the top sequence.
    pub nests: Vec<AudioNest>,
    /// Clip speed. Source position advances `speed` source seconds per timeline second.
    pub speed: ClipSpeed,
    /// Reversed: audio reads the source backwards from `source_start` (the source time at `timeline.start`).
    pub reversed: bool,
    /// Time-stretch (pitch kept) when speed is not 100 %; false = resample.
    pub keeps_pitch: bool,
    /// Start of the whole clip in top-sequence time (anchor of the time-stretch grain grid, so any split of a range into
    /// render blocks gives identical samples).
    pub clip_start: Time,
    /// The clip's used media range (what retimed audio may read; nothing outside it is played).
    pub source: TimeRange,
    /// Audio transition gain curves of the clip (outgoing / incoming / fade), applied per sample on top of the volume. An
    /// outgoing or incoming segment is extended into its handle: `timeline` and `source` cover it.
    pub envelopes: Vec<TransitionEnvelope>,
    /// The whole audible span of the clip in top-sequence time (handles included, cut by enclosing nested clips),
    /// independent of the queried range: `timeline` is only the queried piece. A through edit is no edge.
    pub extent: TimeRange,
}

impl AudioSegment {
    /// Product of this segment's own transition curves at top-sequence time `t` (1 without transitions).
    pub fn envelope_gain(&self, t: Time) -> f64 {
        let mut g = 1.0;
        for e in &self.envelopes {
            g *= e.gain(t);
        }
        g
    }

    /// Product of the enclosing nested clips' volume at top-sequence time `t` (1 when not nested). The segment's own clip
    /// volume is separate (evaluate it in inner time).
    pub fn nest_gain(&self, t: Time) -> f64 {
        let mut t = t;
        let mut gain = 1.0;
        for n in &self.nests {
            for e in &n.envelopes {
                gain *= e.gain(t);
            }
            gain *= n.clip.volume(t);
            t = n.clip.source_instant(t - n.clip.start);
        }
        gain
    }
}

/// Resolves a nested clip's sequence. `None` = unknown sequence (the clip contributes nothing).
pub type SequenceResolver<'a> = &'a dyn Fn(Id) -> Option<&'a Timeline>;

/// The pieces of the evaluation that live in crates above this one (Angles in the edit crate, format variants, Date Stamp
/// and Follow in the graphics crate). The caller wires them in; `LayerHooks::plain` is what a project without those
/// features needs.
pub struct LayerHooks<'a> {
    /// `Clip.angleView(of:)`: the nested clip's sequence as the clip's chosen Angle plays it.
    pub angle_view: &'a dyn Fn(&Clip, &Timeline) -> Timeline,
    /// `FormatVariant.format(base:)`: the canvas of a variant over the sequence's own format.
    pub variant_format: &'a dyn Fn(&FormatVariant, &SequenceFormat) -> SequenceFormat,
    /// `Clip.resolved(for:base:conformsPicture:)`: the clip as that variant plays it.
    pub resolve_variant: &'a dyn Fn(&Clip, &FormatVariant, &SequenceFormat, bool) -> Clip,
    /// `Clip.dateStampRequest`: the Date Stamp layer of a clip at `t` (canvas, transform, groups, track, in transition).
    #[allow(clippy::type_complexity)]
    pub date_stamp:
        &'a dyn Fn(&Clip, Time, &SequenceFormat, &ClipTransform, &[LayerGroup], Id, bool) -> Option<LayerRequest>,
    /// G11 Follow: the graphics layers of a clip with the pinned ones at their resolved place (clip, document, clip-local
    /// time, canvas frame in px, layout format); `None` when nothing follows.
    #[allow(clippy::type_complexity)]
    pub resolve_follow: &'a dyn Fn(&Clip, &GraphicsDocument, Time, Vec2, &SequenceFormat) -> Option<Vec<GraphicsLayer>>,
}

fn no_angle(_: &Clip, inner: &Timeline) -> Timeline {
    inner.clone()
}
fn no_variant_format(_: &FormatVariant, base: &SequenceFormat) -> SequenceFormat {
    base.clone()
}
fn no_variant_clip(c: &Clip, _: &FormatVariant, _: &SequenceFormat, _: bool) -> Clip {
    c.clone()
}
fn no_stamp(
    _: &Clip,
    _: Time,
    _: &SequenceFormat,
    _: &ClipTransform,
    _: &[LayerGroup],
    _: Id,
    _: bool,
) -> Option<LayerRequest> {
    None
}
fn no_follow(_: &Clip, _: &GraphicsDocument, _: Time, _: Vec2, _: &SequenceFormat) -> Option<Vec<GraphicsLayer>> {
    None
}

impl LayerHooks<'static> {
    /// No Angles, no variants, no Date Stamp, no Follow.
    pub fn plain() -> LayerHooks<'static> {
        LayerHooks {
            angle_view: &no_angle,
            variant_format: &no_variant_format,
            resolve_variant: &no_variant_clip,
            date_stamp: &no_stamp,
            resolve_follow: &no_follow,
        }
    }
}

/// The start of the hold interval (clip-local, rational) that contains `local`, for `rate` frames per second (Posterize
/// Time). The rate is taken in hundredths so a non-integer rate stays exact. A `local` before the clip start is returned
/// unchanged.
pub fn posterize_held_local(local: Time, rate: f64) -> Time {
    if local.is_negative() || !rate.is_finite() {
        return local;
    }
    // shortcut: PosterizeTime.rateRange (1...60) is a literal here, move it next to the catalog row when that is ported
    let n = (rate.clamp(1.0, 60.0) * 100.0).round() as i128;
    // index = floor(local * rate); held = index / rate
    let index = (i128::from(local.value()) * n) / (100 * i128::from(local.timescale()));
    Time::reducing(index * 100, n)
}

/// Posterize Time of a clip.
pub trait ClipPosterize {
    /// `t` moved back to the start of its hold interval; `t` itself without Posterize Time or outside the clip. With
    /// `fd`, a held half of a transition (outside the clip, no media beyond that edge) posterizes the clip's edge frame it
    /// reads: the result is the start of that frame's interval, inside the clip.
    fn posterized_time(&self, t: Time, fd: Option<Time>) -> Time;
}

impl ClipPosterize for Clip {
    fn posterized_time(&self, t: Time, fd: Option<Time>) -> Time {
        use sq_core_model::ClipEffect;
        let read = fd.map_or(t, |fd| self.held_read_time(t, fd));
        if !self.timeline().contains(read) {
            return t;
        }
        let Some(e) = self.effects.iter().rev().find(|e| e.kind == ClipEffect::POSTERIZE_TIME_KIND && e.enabled) else {
            return t;
        };
        let rate = e.scalar(ClipEffect::POSTERIZE_RATE_KEY, read - self.start);
        self.start + posterize_held_local(read - self.start, rate)
    }
}

/// Evaluation of a sequence (Swift `extension Timeline`).
pub trait TimelineEvaluation {
    /// Visible layers at `t`, bottom to top (first video track first). Hidden tracks and gaps are omitted. Nested clips are
    /// resolved through `sequences` (recursively, with the source-time mapping); without a resolver they contribute
    /// nothing. A sequence that (corruptly) contains itself is skipped, not followed.
    /// `variant`: evaluate for that format variant (its canvas, each clip resolved through the hook); `None` or an unknown
    /// id = the sequence's own format. The inner sequence of a nested clip is evaluated in its variant with the same id
    /// when it has one and the nested clip is then not conformed again; otherwise it is evaluated at its own format and
    /// only the nested clip itself is conformed / overridden.
    fn video_layers(
        &self,
        t: Time,
        sequences: SequenceResolver,
        hooks: &LayerHooks,
        variant: Option<Id>,
    ) -> Vec<LayerRequest>;

    /// The distinct tracks (first use first) that Picture masks of `layers` read at nesting level `level`: video tracks of
    /// this timeline, never the owner's own track. Matte layers themselves ask for nothing.
    fn picture_matte_tracks(&self, layers: &[LayerRequest], level: usize) -> Vec<Id>;

    /// Audible clip pieces inside `range`. If any audio track is solo only solo tracks sound; muted tracks never. Nested
    /// audio clips are resolved through `sequences`; inner segments come back in top-sequence time.
    fn audio_segments(&self, range: TimeRange, sequences: SequenceResolver) -> Vec<AudioSegment>;

    /// Sorted, unique clip starts and ends over all tracks.
    fn edit_points(&self) -> Vec<Time>;
}

struct Ctx<'a, 'b> {
    sequences: SequenceResolver<'a>,
    hooks: &'b LayerHooks<'b>,
}

/// `b` continues `a` seamlessly: butted, same media (or same nested sequence), source continuous, normal forward speed on
/// both (the pitch-keeping stretch restarts its grains at every clip, so a retimed cut is never seamless), and the clip
/// volume (line, fades, Audio Gain) the same on both sides of the cut.
fn is_through_edit(a: &Clip, b: &Clip) -> bool {
    if !(a.is_enabled
        && b.is_enabled
        && a.sequence == b.sequence
        && (a.sequence.is_some() || a.media == b.media)
        && a.angle == b.angle
        && a.timeline().end() == b.start
        && a.source.end() == b.source.start
        && !a.is_retimed()
        && !b.is_retimed()
        && a.hold_frame.is_none()
        && b.hold_frame.is_none())
    {
        return false;
    }
    a.volume(a.timeline().end()) == b.volume(b.start)
}

fn variant_of(tl: &Timeline, id: Option<Id>) -> Option<FormatVariant> {
    let id = id?;
    tl.variants.iter().find(|v| v.id == id).cloned()
}

#[allow(clippy::too_many_arguments)]
fn layers_at(
    tl: &Timeline,
    t: Time,
    cx: &Ctx,
    groups: &[LayerGroup],
    visiting: &BTreeSet<Id>,
    variant: Option<&FormatVariant>,
    below: Option<usize>,
    only_track: Option<Id>,
    matte: bool,
) -> Vec<LayerRequest> {
    let mut out: Vec<LayerRequest> = Vec::new();
    // C6: the side of each transition layer of this level that plays live at `t` (the other is held at another time and
    // brings its own mattes, evaluated at that time).
    let mut live_role: std::collections::BTreeMap<Id, PairRole> = std::collections::BTreeMap::new();
    let fd = tl.format.frame_duration;
    let canvas = variant.map_or_else(|| tl.format.clone(), |v| (cx.hooks.variant_format)(v, &tl.format));
    for (track_index, track) in tl.tracks.iter().enumerate() {
        let wanted = match only_track {
            Some(id) => id == track.id,
            None => track.is_visible,
        };
        if !(track.kind == TrackKind::Video && wanted) {
            continue;
        }
        if below.is_some_and(|b| track_index >= b) {
            break;
        }
        // A transition layer on this track: everything below it so far becomes its two sides.
        if only_track.is_none()
            && let Some(layer) = track.active_transition_layer(t)
            && let Some(r) = layer.resolved_transition_layer(fd)
            && let Some(i) = r.frame_index_at(t)
        {
            let stack = |u: Time, out: &Vec<LayerRequest>| -> Vec<LayerRequest> {
                if u == t {
                    out.clone()
                } else {
                    layers_at(tl, u, cx, groups, visiting, variant, Some(track_index), None, matte)
                }
            };
            // Before the cut: outgoing live, incoming held at the cut. From the cut: outgoing held on its last frame.
            let first = if t < r.cut {
                out.clone()
            } else if r.cut - fd >= Time::ZERO {
                stack(r.cut - fd, &out)
            } else {
                Vec::new()
            };
            let second = if t < r.cut { stack(r.cut, &out) } else { out.clone() };
            live_role.insert(layer.id, if t < r.cut { PairRole::First } else { PairRole::Second });
            let render = stack_render(&r, i);
            let tagged = |ls: Vec<LayerRequest>, role: PairRole| -> Vec<LayerRequest> {
                let tag = StackTransition {
                    id: layer.id,
                    role,
                    format: canvas.clone(),
                    depth: groups.len(),
                    render,
                    held: Some(role) != live_role.get(&layer.id).copied(),
                };
                ls.into_iter()
                    .map(|mut l| {
                        l.stack_transitions.insert(0, tag.clone());
                        l.in_transition = true;
                        l
                    })
                    .collect()
            };
            out = Vec::new();
            if r.kind.is_dip() {
                let mut dip = LayerRequest::new(layer.id, layer.id, track.id, Time::ZERO);
                dip.groups = groups.to_vec();
                dip.generator = Some(solid(&TransitionMix::dip_color(r.kind, r.color.as_deref())));
                dip.local_time = Time::ZERO;
                dip.in_transition = true;
                out.push(dip);
            }
            out.extend(tagged(first, PairRole::First));
            out.extend(tagged(second, PairRole::Second));
            continue;
        }
        let state = track.video_entries(t, fd);
        if let Some((dip_id, dip_color)) = state.dip {
            let mut dip = LayerRequest::new(dip_id, dip_id, track.id, Time::ZERO);
            dip.groups = groups.to_vec();
            dip.generator = Some(solid(&dip_color));
            dip.local_time = Time::ZERO;
            out.push(dip);
        }
        // Two clips of a dissolve pair are summed first; each keeps its own effects, and the pair as a whole gets one blend
        // mode (the incoming clip's, else the outgoing one's).
        for (n, (c0, factor)) in state.items.iter().enumerate() {
            if c0.is_transition_layer() {
                continue; // no picture of its own (an unknown kind does nothing)
            }
            // A nested sequence that has the same variant is rendered in it; its clip is then not conformed a second time.
            let inner_variant: Option<FormatVariant> = variant.and_then(|v| {
                let seq = c0.sequence.and_then(cx.sequences)?;
                variant_of(seq, Some(v.id))
            });
            let c: Clip = match variant {
                Some(v) => (cx.hooks.resolve_variant)(c0, v, &tl.format, inner_variant.is_none()),
                None => c0.clone(),
            };
            let mut tr = c.render_transform(t, Vec2::new(canvas.display_width() as f64, canvas.height as f64));
            tr.opacity *= factor;
            let in_transition = state.pair.is_some()
                || state.motion.is_some()
                || state.dip.is_some()
                || state.stinger.is_some()
                || *factor != 1.0;
            let mut pair = state.pair.map(|id| {
                PairInfo::new(id, if n == 0 { PairRole::First } else { PairRole::Second }, canvas.clone(), groups.len())
            });
            if let Some(m) = &state.motion {
                pair = Some(PairInfo {
                    id: m.id,
                    role: if Some(c.id) == m.incoming { PairRole::Second } else { PairRole::First },
                    format: canvas.clone(),
                    depth: groups.len(),
                    render: Some(m.render),
                });
            }
            let fx = c.effects_at(t);
            // Posterize Time: this clip reads the source frame of the start of its hold interval.
            let tq = c.posterized_time(t, Some(fd));
            // A total crop leaves nothing of this clip; its partner in a pair still shows.
            if fx.is_empty() {
                continue;
            }
            let blend = if c.opacity_enabled { c.blend_mode } else { BlendMode::Normal };
            if let Some(seq_id) = c.sequence {
                // An Angles clip plays only its active angle: the other angles are never requested (or decoded).
                if visiting.contains(&seq_id) {
                    continue;
                }
                let Some(seq) = (cx.sequences)(seq_id) else { continue };
                let inner = (cx.hooks.angle_view)(&c, seq);
                let g = LayerGroup {
                    clip: c.id,
                    track: track.id,
                    sequence: seq_id,
                    format: inner_variant
                        .as_ref()
                        .map_or_else(|| inner.format.clone(), |iv| (cx.hooks.variant_format)(iv, &inner.format)),
                    transform: tr,
                    corner_radius: fx.corner_radius(),
                    effects: fx.clone(),
                    blend_mode: blend,
                    motion_blur: c.motion_blur(t, fd, &canvas, *factor),
                };
                // A held nested clip shows one instant of the inner sequence. A held half of a transition (no inner time
                // beyond the edge) shows the clip's edge frame.
                let inner_time = c
                    .hold_frame
                    .unwrap_or_else(|| c.inner_time(c.held_read_time(tq, fd) - c.start, inner.format.frame_duration));
                let mut next_groups = groups.to_vec();
                next_groups.push(g);
                let mut next_visiting = visiting.clone();
                next_visiting.insert(seq_id);
                let mut inners = layers_at(
                    &inner,
                    inner_time,
                    cx,
                    &next_groups,
                    &next_visiting,
                    inner_variant.as_ref(),
                    None,
                    None,
                    matte,
                );
                for l in &mut inners {
                    if l.pair.is_none() {
                        l.pair.clone_from(&pair);
                    }
                    if in_transition {
                        l.in_transition = true;
                    }
                }
                out.extend(inners);
            } else if c.is_graphics() {
                // GFX: the layers composite inside a group of the clip (nested-group path), so the clip's own Motion,
                // opacity, effects and blend mode apply to the graphic as a whole.
                let Some(doc) = c.graphics() else { continue };
                if !doc.layers.iter().any(|l| l.is_visible) {
                    continue;
                }
                let g = LayerGroup {
                    clip: c.id,
                    track: track.id,
                    sequence: c.id,
                    format: canvas.clone(),
                    transform: tr,
                    corner_radius: fx.corner_radius(),
                    effects: fx.clone(),
                    blend_mode: blend,
                    motion_blur: c.motion_blur(t, fd, &canvas, *factor),
                };
                let local = t - c.start;
                let frame = Vec2::new(canvas.display_width() as f64, canvas.height as f64);
                // G11 Follow: pinned layers drawn at their resolved place (no work and no copy when nothing follows).
                let layers: Vec<GraphicsLayer> =
                    (cx.hooks.resolve_follow)(&c, doc, local, frame, &canvas.layout_format())
                        .unwrap_or_else(|| doc.layers.clone());
                let mut next_groups = groups.to_vec();
                next_groups.push(g);
                for l in layers.iter().filter(|l| l.is_visible && l.is_shown(local)) {
                    let lc = c.graphics_layer_clip(l);
                    let lfx = lc.effects_at(t);
                    if lfx.is_empty() {
                        continue;
                    }
                    let mut r = LayerRequest::new(l.id, l.id, track.id, local);
                    r.transform = lc.render_transform(t, frame);
                    r.corner_radius = lfx.corner_radius();
                    r.groups = next_groups.clone();
                    r.generator = lc.generator.clone();
                    r.local_time = local;
                    r.effects = lfx;
                    r.blend_mode = l.blend_mode;
                    r.shape = l.shape_style(local);
                    // Item lanes: a ranged item's generator (text In/Out) runs on its range, not on the clip. The same
                    // `text_time` feeds Follow's and the monitor's measure.
                    let text_time = l.text_time(local);
                    r.local_time = text_time.local;
                    r.clip_duration = Some(text_time.duration.unwrap_or_else(|| c.duration()));
                    r.pair = pair.clone();
                    r.in_transition = in_transition;
                    out.push(r);
                }
            } else {
                let local = t - c.start;
                let mut r = LayerRequest::new(c.id, c.media, track.id, c.source_time(tq, fd));
                r.reversed = c.reversed;
                r.transform = tr;
                r.corner_radius = fx.corner_radius();
                r.groups = groups.to_vec();
                r.generator = c.generator.clone();
                r.local_time = local;
                r.color = c.render_color(local, &|e| c.has_live_mask_input(e));
                r.effects = fx;
                r.blend_mode = blend;
                r.interpolation = if c.hold_frame.is_none() && tq == t {
                    c.time_interpolation
                } else {
                    TimeInterpolation::FrameSampling
                };
                r.source_end = Some(c.source.end());
                r.source_start = Some(c.source.start);
                r.pair = pair.clone();
                r.in_transition = in_transition;
                r.shape = c.shape_style(local);
                r.motion_blur = c.motion_blur(t, fd, &canvas, *factor);
                r.gyro = c.gyroflow_options();
                out.push(r);
            }
            if !c.is_graphics()
                && let Some(stamp) =
                    (cx.hooks.date_stamp)(&c, t, &canvas.layout_format(), &tr, groups, track.id, in_transition)
            {
                out.push(stamp);
            }
        }
    }
    // C6: the tracks this level's live Picture masks read, each evaluated once at the same `t` and appended as matte layers.
    // A held transition side (and the stack under a transition layer, `below`) got its own mattes at its own time from its
    // evaluation; they carry the side's tag.
    if matte {
        return out;
    }
    let level = groups.len();
    let live: Vec<LayerRequest> = if live_role.is_empty() {
        out.clone()
    } else {
        out.iter()
            .filter(|l| l.stack_transitions.iter().all(|s| s.depth != level || live_role.get(&s.id) == Some(&s.role)))
            .cloned()
            .collect()
    };
    for id in tl.picture_matte_tracks(&live, level) {
        let layers = layers_at(tl, t, cx, groups, visiting, variant, None, Some(id), true);
        out.extend(matte_layers(&layers, id, groups.len()));
    }
    out
}

/// A solid generator of display-encoded `rgb`.
fn solid(rgb: &[u8]) -> GeneratorRef {
    GeneratorRef { kind: "solid".to_string(), payload: rgb.to_vec(), payload_version: 1 }
}

impl TimelineEvaluation for Timeline {
    fn video_layers(
        &self,
        t: Time,
        sequences: SequenceResolver,
        hooks: &LayerHooks,
        variant: Option<Id>,
    ) -> Vec<LayerRequest> {
        if variant.is_none()
            && let Some(span) = self.render_cache_spans.iter().find(|s| s.range.contains(t))
            && let Some(track) = self.tracks.iter().find(|tr| tr.kind == TrackKind::Video && tr.is_visible)
        {
            return vec![LayerRequest::new(span.media, span.media, track.id, t - span.range.start)];
        }
        let cx = Ctx { sequences, hooks };
        let visiting: BTreeSet<Id> = BTreeSet::from([self.id]);
        let v = variant_of(self, variant);
        layers_at(self, t, &cx, &[], &visiting, v.as_ref(), None, None, false)
    }

    fn picture_matte_tracks(&self, layers: &[LayerRequest], level: usize) -> Vec<Id> {
        let mut out: Vec<Id> = Vec::new();
        for l in layers.iter().filter(|l| l.matte_for.is_none()) {
            let Some((owner, ids)) = l.picture_tracks_at_level(level) else { continue };
            for id in ids {
                if !out.contains(&id) && self.accepts_picture_track(id, owner) {
                    out.push(id);
                }
            }
        }
        out
    }

    fn audio_segments(&self, range: TimeRange, sequences: SequenceResolver) -> Vec<AudioSegment> {
        audio_in(self, range, sequences, &[], &BTreeSet::from([self.id]))
    }

    fn edit_points(&self) -> Vec<Time> {
        let mut set: BTreeSet<Time> = BTreeSet::new();
        for track in &self.tracks {
            for c in track.clips() {
                set.insert(c.start);
                set.insert(c.timeline().end());
            }
        }
        set.into_iter().collect()
    }
}

fn audio_in(
    tl: &Timeline,
    range: TimeRange,
    sequences: SequenceResolver,
    nests: &[AudioNest],
    visiting: &BTreeSet<Id>,
) -> Vec<AudioSegment> {
    let audio: Vec<&Track> = tl.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
    let any_solo = audio.iter().any(|t| t.is_solo);
    let mut out: Vec<AudioSegment> = Vec::new();
    for track in audio.into_iter().filter(|t| !t.is_muted && (!any_solo || t.is_solo)) {
        let clips = track.clips();
        // Clips that can sound in `range`: those overlapping it plus one neighbor each side (handles reach into them).
        let first = track.clip_index_ending_after(range.start).saturating_sub(1);
        let mut last = first;
        while last < clips.len() && clips[last].start < range.end() {
            last += 1;
        }
        let end = clips.len().min(last + 1);
        let ids: BTreeSet<Id> = clips[first..end].iter().map(|c| c.id).collect();
        let info = track.audio_transition_info(tl.format.frame_duration, &ids);
        for i in first..end {
            let c = &clips[i];
            let x = info.get(&c.id);
            // A clip in a transition plays on into its handle: outgoing past its end, incoming before its start.
            let extended = TimeRange::from_end(
                c.start - x.map_or(Time::ZERO, |x| x.head),
                c.timeline().end() + x.map_or(Time::ZERO, |x| x.tail),
            );
            // Audible span for edge fades: a through edit into a neighbor continues the sound, so it is no edge there.
            let mut extent = extended;
            // A chain of through edits is one sound: every piece keys on the whole chain.
            if x.is_none() {
                let mut j = i;
                while j > 0 && is_through_edit(&clips[j - 1], &clips[j]) {
                    j -= 1;
                }
                extent = TimeRange::from_end(clips[j].start, extent.end());
                let mut j = i;
                while j + 1 < clips.len() && is_through_edit(&clips[j], &clips[j + 1]) {
                    j += 1;
                }
                extent = TimeRange::from_end(extent.start, clips[j].timeline().end());
            }
            if !c.is_enabled {
                continue;
            }
            let Some(r) = extended.intersection(&range) else { continue };
            if r.is_empty() {
                continue;
            }
            let a = r.start - c.start;
            let inner_start = c.source_instant(a);
            let envelopes = x.map(|x| x.envelopes.clone()).unwrap_or_default();
            if let Some(seq_id) = c.sequence {
                if visiting.contains(&seq_id) {
                    continue;
                }
                let Some(seq) = sequences(seq_id) else { continue };
                // The audio side of an Angles clip is the same view the picture uses; without the hook it plays the
                // sequence as it is.
                let inner = seq;
                let offset = c.start - c.source.start; // inner time + offset = outer time
                let mut next_visiting = visiting.clone();
                next_visiting.insert(seq_id);
                if c.is_retimed() {
                    // Retimed nested clip: query the inner range this piece plays, map each inner piece back through the
                    // clip's time mapping (both ends), and anchor the time-stretch grid at the nested clip's start.
                    let inner_range = c.source_range(a, r.end() - c.start);
                    if inner_range.is_empty() {
                        continue;
                    }
                    let mut next_nests = nests.to_vec();
                    next_nests.push(AudioNest { clip: c.clone(), track: track.id, envelopes: Vec::new() });
                    for mut s in audio_in(inner, inner_range, sequences, &next_nests, &next_visiting) {
                        let x0 = c.start + c.local_time_for_instant(s.timeline.start);
                        let y0 = c.start + c.local_time_for_instant(s.timeline.end());
                        let Some(piece) = TimeRange::from_end(x0.min(y0), x0.max(y0)).intersection(&r) else {
                            continue;
                        };
                        s.timeline = piece;
                        s.clip_start = c.start;
                        let ex = c.start + c.local_time_for_instant(s.extent.start);
                        let ey = c.start + c.local_time_for_instant(s.extent.end());
                        s.extent = TimeRange::from_end(ex.min(ey), ex.max(ey)).intersection(&extent).unwrap_or(piece);
                        out.push(s);
                    }
                    continue;
                }
                let inner_range = TimeRange::new(inner_start, r.duration);
                let mut next_nests = nests.to_vec();
                next_nests.push(AudioNest { clip: c.clone(), track: track.id, envelopes: envelopes.clone() });
                for mut s in audio_in(inner, inner_range, sequences, &next_nests, &next_visiting) {
                    s.timeline = TimeRange::new(s.timeline.start + offset, s.timeline.duration);
                    s.clip_start += offset;
                    s.extent = TimeRange::new(s.extent.start + offset, s.extent.duration)
                        .intersection(&extent)
                        .unwrap_or(s.timeline);
                    out.push(s);
                }
            } else {
                let mut source = c.source;
                if let Some(x) = x {
                    // Source time consumed before / after the range: at the speed and direction of the clip's own ends (a
                    // speed track runs on at its first / last speed).
                    let first_seg = c.speed_keys.as_ref().and_then(|k| k.segments.first());
                    let last_seg = c.speed_keys.as_ref().and_then(|k| k.segments.last());
                    let h = first_seg.map_or(c.speed, |s| s.from).scale(x.head);
                    let tl_ = last_seg.map_or(c.speed, |s| s.to).scale(x.tail);
                    let head_back = first_seg.map_or(c.reversed, |s| s.reversed);
                    let tail_back = last_seg.map_or(c.reversed, |s| s.reversed);
                    let lo = (if head_back { Time::ZERO } else { h }) + (if tail_back { tl_ } else { Time::ZERO });
                    let hi = (if head_back { h } else { Time::ZERO }) + (if tail_back { Time::ZERO } else { tl_ });
                    let mut start = Time::ZERO.max(source.start - lo);
                    let mut end = source.end() + hi;
                    if let Some(m) = c.media_duration {
                        end = end.min(m);
                    }
                    start = start.min(source.start);
                    end = end.max(source.end());
                    source = TimeRange::from_end(start, end);
                }
                out.push(AudioSegment {
                    clip: c.id,
                    media: c.audio_media_id(),
                    track: track.id,
                    timeline: r,
                    source_start: inner_start,
                    nests: nests.to_vec(),
                    speed: c.speed,
                    reversed: c.reversed,
                    keeps_pitch: c.keeps_pitch,
                    clip_start: c.start,
                    source,
                    envelopes,
                    extent,
                });
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::Timeline;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(ids: &mut SequentialIds, start: i64, dur: i64, src: i64, kind: TrackKind) -> Clip {
        use sq_core_time::IdSource;
        Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(s(src), s(dur)), s(start))
    }

    fn track(
        ids: &mut SequentialIds,
        clips: Vec<Clip>,
        kind: TrackKind,
        visible: bool,
        muted: bool,
        solo: bool,
    ) -> Track {
        use sq_core_time::IdSource;
        let mut t = Track::new(ids.next_id(), kind);
        t.is_visible = visible;
        t.is_muted = muted;
        t.is_solo = solo;
        for c in clips {
            t.overwrite(c, ids).expect("overwrite");
        }
        t
    }

    fn timeline(tracks: Vec<Track>) -> Timeline {
        use sq_core_time::IdSource;
        let mut ids = SequentialIds::default();
        for _ in 0..500 {
            ids.next_id();
        }
        Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn none(_: Id) -> Option<&'static Timeline> {
        None
    }

    fn layers(tl: &Timeline, t: Time) -> Vec<LayerRequest> {
        tl.video_layers(t, &none, &LayerHooks::plain(), None)
    }

    fn range(a: i64, d: i64) -> TimeRange {
        TimeRange::new(s(a), s(d))
    }

    #[test]
    fn gaps_yield_nothing() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 2, 2, 0, TrackKind::Video);
        let tl = timeline(vec![track(&mut ids, vec![c], TrackKind::Video, true, false, false)]);
        assert!(layers(&tl, s(1)).is_empty());
        assert!(layers(&tl, s(5)).is_empty());
        assert!(layers(&timeline(vec![]), s(0)).is_empty());
    }

    #[test]
    fn hidden_track_omitted() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 4, 0, TrackKind::Video), clip(&mut ids, 0, 4, 0, TrackKind::Video));
        let tl = timeline(vec![
            track(&mut ids, vec![a], TrackKind::Video, false, false, false),
            track(&mut ids, vec![b], TrackKind::Video, true, false, false),
        ]);
        let l = layers(&tl, s(1));
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].track, tl.tracks[1].id);
    }

    #[test]
    fn half_open_edges() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 2, 0, TrackKind::Video), clip(&mut ids, 2, 2, 0, TrackKind::Video));
        let (ai, bi) = (a.id, b.id);
        let tl = timeline(vec![track(&mut ids, vec![a, b], TrackKind::Video, true, false, false)]);
        let ids_at = |t: Time| layers(&tl, t).iter().map(|l| l.clip).collect::<Vec<_>>();
        assert_eq!(ids_at(s(0)), vec![ai]);
        assert_eq!(ids_at(Time::new(19, 10)), vec![ai]);
        assert_eq!(ids_at(s(2)), vec![bi]);
        assert!(ids_at(s(4)).is_empty());
    }

    #[test]
    fn stacked_order_bottom_to_top() {
        let mut ids = SequentialIds::default();
        let mk = |ids: &mut SequentialIds, start: i64, dur: i64| {
            let c = clip(ids, start, dur, 0, TrackKind::Video);
            track(ids, vec![c], TrackKind::Video, true, false, false)
        };
        let tl = timeline(vec![mk(&mut ids, 0, 4), mk(&mut ids, 0, 4), mk(&mut ids, 1, 2)]);
        let all: Vec<Id> = tl.tracks.iter().map(|t| t.id).collect();
        assert_eq!(layers(&tl, s(1)).iter().map(|l| l.track).collect::<Vec<_>>(), all);
        assert_eq!(layers(&tl, s(0)).iter().map(|l| l.track).collect::<Vec<_>>(), all[..2].to_vec());
    }

    #[test]
    fn source_time_after_slip() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 10, 5, 3, TrackKind::Video); // slipped: source starts at 3 s
        let media = c.media;
        let tl = timeline(vec![track(&mut ids, vec![c], TrackKind::Video, true, false, false)]);
        let l = layers(&tl, s(12));
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].source_time, s(5));
        assert_eq!(l[0].media, media);
        assert_eq!(layers(&tl, s(10))[0].source_time, s(3));
    }

    #[test]
    fn video_tracks_ignored_for_audio() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 0, 4, 0, TrackKind::Video);
        let tl = timeline(vec![track(&mut ids, vec![c], TrackKind::Video, true, false, false)]);
        assert!(tl.audio_segments(range(0, 4), &none).is_empty());
    }

    #[test]
    fn audio_clipped_to_range_with_source_start() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 2, 6, 10, TrackKind::Audio);
        let (cid, media) = (c.id, c.media);
        let tl = timeline(vec![track(&mut ids, vec![c], TrackKind::Audio, true, false, false)]);
        let segs = tl.audio_segments(range(4, 10), &none);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].timeline, TimeRange::from_end(s(4), s(8)));
        assert_eq!(segs[0].source_start, s(12));
        assert_eq!((segs[0].clip, segs[0].media), (cid, media));
        // range fully before / touching the end yields nothing
        assert!(tl.audio_segments(range(0, 2), &none).is_empty());
        assert!(tl.audio_segments(range(8, 2), &none).is_empty());
    }

    #[test]
    fn audio_spans_multiple_clips_and_tracks() {
        let mut ids = SequentialIds::default();
        let (a, b, c) = (
            clip(&mut ids, 0, 2, 0, TrackKind::Audio),
            clip(&mut ids, 2, 2, 0, TrackKind::Audio),
            clip(&mut ids, 1, 2, 0, TrackKind::Audio),
        );
        let tl = timeline(vec![
            track(&mut ids, vec![a, b], TrackKind::Audio, true, false, false),
            track(&mut ids, vec![c], TrackKind::Audio, true, false, false),
        ]);
        assert_eq!(tl.audio_segments(range(0, 4), &none).len(), 3);
    }

    #[test]
    fn muted_track_silent_and_solo_silences_others() {
        let mut ids = SequentialIds::default();
        let mut mk = |muted: bool, solo: bool| {
            let c = clip(&mut ids, 0, 4, 0, TrackKind::Audio);
            track(&mut ids, vec![c], TrackKind::Audio, true, muted, solo)
        };
        let tl = timeline(vec![mk(true, false), mk(false, false)]);
        let tracks_of =
            |tl: &Timeline| tl.audio_segments(range(0, 4), &none).iter().map(|s| s.track).collect::<Vec<_>>();
        assert_eq!(tracks_of(&tl), vec![tl.tracks[1].id]);
        let tl = timeline(vec![mk(false, false), mk(false, true), mk(true, true)]);
        assert_eq!(tracks_of(&tl), vec![tl.tracks[1].id]);
    }

    #[test]
    fn edit_points_sorted_unique_and_duration_is_end_of_last_clip() {
        let mut ids = SequentialIds::default();
        let (a, b, c) = (
            clip(&mut ids, 0, 2, 0, TrackKind::Video),
            clip(&mut ids, 2, 3, 0, TrackKind::Video),
            clip(&mut ids, 1, 4, 0, TrackKind::Audio),
        );
        let tl = timeline(vec![
            track(&mut ids, vec![a, b], TrackKind::Video, true, false, false),
            track(&mut ids, vec![c], TrackKind::Audio, true, false, false),
        ]);
        assert_eq!(tl.edit_points(), vec![s(0), s(1), s(2), s(5)]);
        assert_eq!(tl.duration(), s(5));
        assert_eq!(timeline(vec![]).duration(), Time::ZERO);
    }

    #[test]
    fn posterize_holds_the_start_of_the_interval() {
        // 8 fps: the interval of local 0.3 s starts at 2/8 s.
        assert_eq!(posterize_held_local(Time::new(3, 10), 8.0), Time::new(1, 4));
        assert_eq!(posterize_held_local(Time::new(-1, 10), 8.0), Time::new(-1, 10));
    }

    #[test]
    fn matte_layers_tag_and_drop_adjustments() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 0, 4, 0, TrackKind::Video);
        let tl = timeline(vec![track(&mut ids, vec![c], TrackKind::Video, true, false, false)]);
        let mut l = layers(&tl, s(1));
        l[0].in_transition = true;
        let track_id = tl.tracks[0].id;
        let m = matte_layers(&l, track_id, 0);
        assert_eq!(m.len(), 1);
        assert!(m[0].matte_for == Some(track_id) && m[0].matte_depth == 0 && !m[0].in_transition);
        let mut adj = l[0].clone();
        adj.generator = Some(GeneratorRef { kind: "adjustment".to_string(), payload: Vec::new(), payload_version: 1 });
        assert!(matte_layers(&[adj], track_id, 0).is_empty());
    }

    mod stage_layers {
        use super::super::*;
        use crate::effect_transform_stage::test_support::*;
        use sq_core_model::{AnimatedProperty, ClipEffect};
        use sq_core_time::Vec2;

        fn layers_of(c: Clip, t: Time) -> Vec<LayerRequest> {
            fn none(_: Id) -> Option<&'static Timeline> {
                None
            }
            timeline_of(c).video_layers(t, &none, &LayerHooks::plain(), None)
        }

        #[test]
        fn video_layers_carry_the_composed_transform() {
            let mut c = clip(vec![transform_stage(&[(ClipEffect::STAGE_SCALE_KEY, 110.0)])]);
            c.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 1.2));
            let l = layers_of(c, s(1));
            assert!(l.len() == 1 && close(l[0].transform.scale.x, 1.32, 1e-9));
            assert!(l[0].motion_blur.is_none());
        }

        #[test]
        fn shutter_angle_gives_sub_frame_samples_around_the_frame() {
            let mut e = transform_stage(&[(ClipEffect::STAGE_SHUTTER_ANGLE_KEY, 180.0)]);
            let (k, p) = ramp(ClipEffect::STAGE_POSITION_X_KEY, 0.0, 250.0, 1); // 10 px per frame at 25 fps
            e.parameters.insert(k, p);
            let l = layers_of(clip(vec![e]), Time::new(1, 2));
            let mb = l[0].motion_blur.clone().expect("motion blur");
            assert_eq!(
                mb.transforms.len() as i64,
                crate::effect_transform_stage::EffectTransformStage::sample_count(180.0)
            );
            assert_eq!(mb.format.width, 640);
            let xs: Vec<f64> = mb.transforms.iter().map(|t| t.position.x).collect();
            // Half a frame open, centered on the frame: 125 - 2.5 ... 125 + 2.5.
            assert!(close(xs[0], 122.5, 1e-6) && close(xs[xs.len() - 1], 127.5, 1e-6));
            assert!(close((xs[0] + xs[xs.len() - 1]) / 2.0, l[0].transform.position.x, 1e-6));
            assert!(xs.windows(2).all(|w| w[0] <= w[1]));
        }

        #[test]
        fn no_blur_without_shutter_or_without_motion() {
            let still = transform_stage(&[
                (ClipEffect::STAGE_SHUTTER_ANGLE_KEY, 180.0),
                (ClipEffect::STAGE_POSITION_X_KEY, 40.0),
            ]);
            assert!(layers_of(clip(vec![still.clone()]), s(1))[0].motion_blur.is_none()); // nothing moves
            let mut closed = still;
            closed.parameters.insert(ClipEffect::STAGE_SHUTTER_ANGLE_KEY.to_string(), AnimatedProperty::new(0.0));
            let (k, p) = ramp(ClipEffect::STAGE_POSITION_X_KEY, 0.0, 250.0, 1);
            closed.parameters.insert(k, p);
            assert!(layers_of(clip(vec![closed]), Time::new(1, 2))[0].motion_blur.is_none()); // shutter closed
        }

        #[test]
        fn shutter_also_blurs_the_base_motion() {
            let mut c = clip(vec![transform_stage(&[(ClipEffect::STAGE_SHUTTER_ANGLE_KEY, 360.0)])]);
            let mut ids = sq_core_time::SequentialIds::default();
            use sq_core_time::{IdSource, Keyframe, KeyframeTrack};
            let keys = KeyframeTrack::with_keys(vec![
                Keyframe::new(ids.next_id(), Time::ZERO, Vec2::ZERO),
                Keyframe::new(ids.next_id(), s(1), Vec2::new(0.0, 100.0)),
            ]);
            c.animation.position = AnimatedProperty { value: Vec2::ZERO, track: keys };
            let mb = layers_of(c, Time::new(1, 2))[0].motion_blur.clone().expect("motion blur");
            assert!(close(mb.transforms[0].position.y, 48.0, 1e-6));
            assert!(close(mb.transforms[mb.transforms.len() - 1].position.y, 52.0, 1e-6));
        }

        #[test]
        fn motion_blur_effect_reaches_the_layer_request_and_thinning_keeps_the_ends() {
            let mut c = clip(vec![stage(&[], ClipEffect::MOTION_BLUR_KIND)]);
            let mut ids = sq_core_time::SequentialIds::default();
            use sq_core_time::{IdSource, Keyframe, KeyframeTrack};
            let keys = KeyframeTrack::with_keys(vec![
                Keyframe::new(ids.next_id(), Time::ZERO, Vec2::ZERO),
                Keyframe::new(ids.next_id(), s(1), Vec2::new(100.0, 0.0)),
            ]);
            c.animation.position = AnimatedProperty { value: Vec2::ZERO, track: keys };
            let mb = layers_of(c, Time::new(1, 2))[0].motion_blur.clone().expect("motion blur");
            assert_eq!(mb.transforms.len(), 8); // Amount 50 = 180 degrees
            let ts: Vec<ClipTransform> = (0..16)
                .map(|i| ClipTransform { position: Vec2::new(f64::from(i), 0.0), ..ClipTransform::IDENTITY })
                .collect();
            let thin = MotionBlurSamples { format: canvas(), transforms: ts.clone(), local_times: vec![] }.thinned(8);
            let xs: Vec<f64> = thin.transforms.iter().map(|t| t.position.x).collect();
            assert_eq!(xs, vec![0.0, 2.0, 4.0, 6.0, 9.0, 11.0, 13.0, 15.0]);
            let short = MotionBlurSamples { format: canvas(), transforms: ts[..6].to_vec(), local_times: vec![] };
            assert_eq!(short.thinned(8).transforms.len(), 6);
        }
    }
}
