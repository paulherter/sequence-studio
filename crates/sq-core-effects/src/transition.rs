// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Transition.swift (logic only; the saved types live in sq-core-model), ElementTransitions.swift,
// ProjectFile+V89.swift (reversed transitions).

//! Transition logic: what each kind is and does, how a stored transition resolves against the current clips, how a motion
//! transition looks on one frame, and the edits that apply, change and remove transitions.
//!
//! A transition is anchored to clip ids and stores the user's intent. What plays is resolved from the clips
//! (`TrackTransitions::resolve`): the cut must exist and the duration is clamped to the handles; video holds its edge frame
//! where no media is left. `sq_core_model::Track::prune_transitions` drops what no longer resolves.
//!
//! - `render`: the pure per-frame maths (`TransitionMix`, `TransitionRender`).
//! - `resolve`: `ResolvedTransition`, `Track` resolution and the evaluation helpers.
//! - `edit`: the `Timeline` verbs.
//! - `element`: Move / Zoom / Pop and Zoom In / Out parameters.

mod edit;
mod element;
mod render;
mod resolve;

pub use edit::*;
pub use element::*;
pub use render::*;
pub use resolve::*;

#[cfg(test)]
mod feel_tests;
#[cfg(test)]
mod first_cut_tests;
#[cfg(test)]
mod held_tests;
#[cfg(test)]
mod more_tests;
#[cfg(test)]
mod render_tests;
#[cfg(test)]
pub(crate) mod tests;

use crate::transition_custom_curve::TransitionEasing;
use sq_core_model::{
    TrackKind, Transition, TransitionAlignment, TransitionDirection, TransitionKind, TransitionStinger,
};
use sq_core_time::{EasingCurve, Id, Time, Vec2};

/// Every transition kind in declaration order (Swift `allCases`).
pub const ALL_TRANSITION_KINDS: &[TransitionKind] = &[
    TransitionKind::CrossDissolve,
    TransitionKind::DipToBlack,
    TransitionKind::DipToWhite,
    TransitionKind::QuickFade,
    TransitionKind::Push,
    TransitionKind::Slide,
    TransitionKind::Whip,
    TransitionKind::ZoomIn,
    TransitionKind::ZoomOut,
    TransitionKind::ZoomPop,
    TransitionKind::SoftWipe,
    TransitionKind::Glitch,
    TransitionKind::Iris,
    TransitionKind::LightLeak,
    TransitionKind::BlurDissolve,
    TransitionKind::DipToColour,
    TransitionKind::Flash,
    TransitionKind::Spin,
    TransitionKind::CrossZoom,
    TransitionKind::StaticNoise,
    TransitionKind::LightNoise,
    TransitionKind::StrobeCut,
    TransitionKind::AdditiveDissolve,
    TransitionKind::ClockWipe,
    TransitionKind::BoxIris,
    TransitionKind::DiamondIris,
    TransitionKind::CrossIris,
    TransitionKind::BarnDoors,
    TransitionKind::VenetianBlinds,
    TransitionKind::RadialWipe,
    TransitionKind::WedgeWipe,
    TransitionKind::Pinwheel,
    TransitionKind::CheckerWipe,
    TransitionKind::ZigZagBlocks,
    TransitionKind::InsetWipe,
    TransitionKind::RandomBlocks,
    TransitionKind::SliceWipe,
    TransitionKind::MosaicDissolve,
    TransitionKind::Flip3D,
    TransitionKind::Spring,
    TransitionKind::Fall,
    TransitionKind::Burn,
    TransitionKind::Flare,
    TransitionKind::Warp,
    TransitionKind::Shake,
    TransitionKind::Stinger,
    TransitionKind::Move,
    TransitionKind::Zoom,
    TransitionKind::Pop,
    TransitionKind::ConstantPower,
    TransitionKind::ConstantGain,
    TransitionKind::ExponentialFade,
];

/// Kinds that sweep a distance-field shape (`TransitionRender::ShapeWipe`).
const SHAPE_REVEALS: [TransitionKind; 14] = [
    TransitionKind::ClockWipe,
    TransitionKind::BoxIris,
    TransitionKind::DiamondIris,
    TransitionKind::CrossIris,
    TransitionKind::BarnDoors,
    TransitionKind::VenetianBlinds,
    TransitionKind::RadialWipe,
    TransitionKind::WedgeWipe,
    TransitionKind::Pinwheel,
    TransitionKind::CheckerWipe,
    TransitionKind::ZigZagBlocks,
    TransitionKind::InsetWipe,
    TransitionKind::RandomBlocks,
    TransitionKind::SliceWipe,
];

/// Logic of `TransitionKind` (the saved enum is in `sq-core-model`, with `track_kind`, `is_element`, `is_stinger`).
pub trait TransitionKindExt: Sized {
    /// Widest border a Push / Slide / Soft Wipe takes, fraction of the frame.
    const MAX_BORDER_WIDTH: f64 = 0.1;
    /// Soft Wipe edge: half width of the soft band, fraction of the frame.
    const DEFAULT_SOFTNESS: f64 = 0.1;
    /// Direction of a transition that stores none.
    const DEFAULT_DIRECTION: TransitionDirection = TransitionDirection::Left;

    /// Shown name.
    fn name(self) -> &'static str;
    /// The kinds of a track kind, in declaration order.
    fn kinds_for(track: TrackKind) -> Vec<Self>;
    /// Cross Dissolve for video, Constant Power for audio.
    fn default_kind_for(track: TrackKind) -> Self;
    /// Moves, scales or masks the pictures (compositor transition node) instead of mixing opacities.
    fn is_motion(&self) -> bool;
    /// Dissolves to a flat color and back through the solid dip layer.
    fn is_dip(&self) -> bool;
    /// The dip color is the user's (`Transition::color`).
    fn uses_color(self) -> bool;
    /// Has a Direction control.
    fn uses_direction(self) -> bool;
    /// Shape reveals: a distance field with a soft edge, no movement.
    fn is_shape_reveal(&self) -> bool;
    /// Push, Slide and Soft Wipe have one straight moving edge a border can follow.
    fn uses_border(self) -> bool;
    /// Has a Softness control.
    fn uses_softness(self) -> bool;
    /// Has a Motion Blur control.
    fn uses_motion_blur(self) -> bool;
    /// Has a Curve control (element transitions have their own, Zoom In / Out's speed curve is part of their look).
    fn uses_easing(self) -> bool;
    /// The curve of a transition that stores none: dissolves and dips stay linear, slides and the pop decelerate, every other
    /// motion eases in and out.
    fn default_easing(self) -> EasingCurve;
    /// Shutter of the motion blur in frames (0.5 = 180 degrees); a whip is mostly blur.
    fn default_motion_blur(self) -> f64;
    /// Length a new transition of this kind gets; `None` = the Preferences default (dissolves, dips, wipe, audio).
    fn preset_duration(self, frame_duration: Time) -> Option<Time>;
}

impl TransitionKindExt for TransitionKind {
    fn name(self) -> &'static str {
        use TransitionKind::*;
        match self {
            CrossDissolve => "Dissolve",
            DipToBlack => "Through Black",
            DipToWhite => "Through White",
            QuickFade => "Quick Fade",
            Push => "Push",
            Slide => "Slide",
            Whip => "Whip",
            ZoomIn => "Zoom In",
            ZoomOut => "Zoom Out",
            ZoomPop => "Zoom Pop",
            SoftWipe => "Soft Wipe",
            Glitch => "Glitch",
            Iris => "Iris",
            LightLeak => "Light Leak",
            BlurDissolve => "Blur Dissolve",
            DipToColour => "Through Color",
            Flash => "Flash",
            Spin => "Spin",
            CrossZoom => "Cross Zoom",
            StaticNoise => "Static",
            LightNoise => "Light Noise",
            StrobeCut => "Strobe Cut",
            AdditiveDissolve => "Additive Dissolve",
            ClockWipe => "Clock Wipe",
            BoxIris => "Box Iris",
            DiamondIris => "Diamond Iris",
            CrossIris => "Cross Iris",
            BarnDoors => "Barn Doors",
            VenetianBlinds => "Blinds",
            RadialWipe => "Radial Wipe",
            WedgeWipe => "Wedge Wipe",
            Pinwheel => "Pinwheel",
            CheckerWipe => "Checker Wipe",
            ZigZagBlocks => "Zig-Zag Blocks",
            InsetWipe => "Inset",
            RandomBlocks => "Random Blocks",
            SliceWipe => "Slice",
            MosaicDissolve => "Mosaic Dissolve",
            Flip3D => "Flip 3D",
            Spring => "Spring",
            Fall => "Fall",
            Burn => "Burn",
            Flare => "Flare",
            Warp => "Warp",
            Shake => "Shake",
            Stinger => "Stinger",
            Move => "Move",
            Zoom => "Zoom",
            Pop => "Pop",
            ConstantPower => "Smooth Crossfade",
            ConstantGain => "Steady Crossfade",
            ExponentialFade => "Exponential Fade",
        }
    }

    fn kinds_for(track: TrackKind) -> Vec<Self> {
        ALL_TRANSITION_KINDS.iter().copied().filter(|k| k.track_kind() == track).collect()
    }

    fn default_kind_for(track: TrackKind) -> Self {
        if track == TrackKind::Video { TransitionKind::CrossDissolve } else { TransitionKind::ConstantPower }
    }

    fn is_motion(&self) -> bool {
        use TransitionKind::*;
        matches!(
            self,
            Push | Slide
                | Whip
                | ZoomIn
                | ZoomOut
                | ZoomPop
                | SoftWipe
                | Glitch
                | Iris
                | LightLeak
                | BlurDissolve
                | Spin
                | CrossZoom
                | StaticNoise
                | LightNoise
                | StrobeCut
                | AdditiveDissolve
                | ClockWipe
                | BoxIris
                | DiamondIris
                | CrossIris
                | BarnDoors
                | VenetianBlinds
                | RadialWipe
                | WedgeWipe
                | Pinwheel
                | CheckerWipe
                | ZigZagBlocks
                | InsetWipe
                | RandomBlocks
                | SliceWipe
                | MosaicDissolve
                | Flip3D
                | Spring
                | Fall
                | Burn
                | Flare
                | Warp
                | Shake
        )
    }

    fn is_dip(&self) -> bool {
        use TransitionKind::*;
        matches!(self, DipToBlack | DipToWhite | DipToColour | Flash)
    }

    fn uses_color(self) -> bool {
        self == TransitionKind::DipToColour
    }

    fn uses_direction(self) -> bool {
        use TransitionKind::*;
        matches!(
            self,
            Push | Slide | Whip | SoftWipe | LightLeak | Spin | BarnDoors | Flip3D | Spring | Fall | Burn | Flare
        )
    }

    fn is_shape_reveal(&self) -> bool {
        SHAPE_REVEALS.contains(self)
    }

    fn uses_border(self) -> bool {
        use TransitionKind::*;
        matches!(self, Push | Slide | SoftWipe)
    }

    fn uses_softness(self) -> bool {
        use TransitionKind::*;
        matches!(self, SoftWipe | Iris | LightLeak) || self.is_shape_reveal()
    }

    fn uses_motion_blur(self) -> bool {
        use TransitionKind::*;
        let no_blur = matches!(
            self,
            SoftWipe
                | Glitch
                | Iris
                | LightLeak
                | BlurDissolve
                | StaticNoise
                | LightNoise
                | StrobeCut
                | AdditiveDissolve
                | MosaicDissolve
                | Flip3D
                | Burn
                | Flare
                | Warp
                | Shake
        );
        (self.is_motion() && !(self.is_shape_reveal() || no_blur)) || self.is_element()
    }

    fn uses_easing(self) -> bool {
        use TransitionKind::*;
        self.track_kind() == TrackKind::Video && !matches!(self, Stinger | ZoomIn | ZoomOut) && !self.is_element()
    }

    fn default_easing(self) -> EasingCurve {
        use TransitionKind::*;
        match self {
            Slide | ZoomPop => EasingCurve::ease_in(),
            Push | Whip | ZoomIn | ZoomOut | SoftWipe | Iris | LightLeak | BlurDissolve | Spin | CrossZoom
            | ClockWipe | BoxIris | DiamondIris | CrossIris | BarnDoors | VenetianBlinds | RadialWipe | WedgeWipe
            | Pinwheel | CheckerWipe | ZigZagBlocks | InsetWipe | RandomBlocks | SliceWipe | MosaicDissolve => {
                EasingCurve::ease_in_out()
            }
            _ => EasingCurve::linear(),
        }
    }

    fn default_motion_blur(self) -> f64 {
        use TransitionKind::*;
        match self {
            Whip => 1.5,
            ZoomIn | ZoomOut | CrossZoom | Spin => 1.0,
            Push | Slide | ZoomPop | Spring | Fall => 0.5,
            _ => 0.0,
        }
    }

    fn preset_duration(self, fd: Time) -> Option<Time> {
        use TransitionKind::*;
        let fps = fd.timescale() as f64 / fd.value() as f64;
        let seconds = |s: f64| fd * ((s * fps).round() as i64).max(1);
        match self {
            QuickFade => Some(fd * 3),
            Push => Some(seconds(0.8)),
            Slide => Some(seconds(1.0)),
            Whip => Some(seconds(0.5)),
            ZoomIn | ZoomOut => Some(seconds(0.7)),
            ZoomPop => Some(seconds(0.8)),
            Glitch => Some(seconds(0.3)),
            Iris => Some(seconds(0.8)),
            LightLeak => Some(seconds(1.0)),
            Flash => Some(seconds(0.5)),
            Spin | CrossZoom => Some(seconds(0.8)),
            StaticNoise | StrobeCut => Some(seconds(0.4)),
            LightNoise => Some(seconds(1.0)),
            Flip3D | Spring | Fall | Flare => Some(seconds(0.8)),
            Burn => Some(seconds(1.0)),
            Warp => Some(seconds(0.7)),
            Shake => Some(seconds(0.5)),
            Move | Zoom => Some(seconds(0.8)),
            Pop => Some(seconds(0.6)),
            _ => None,
        }
    }
}

/// Logic of `TransitionDirection`.
pub trait TransitionDirectionExt {
    /// Shown name.
    fn name(self) -> &'static str;
    /// Unit motion vector in frame fractions, y down.
    fn vector(self) -> Vec2;
    /// The way back along the same axis.
    fn opposite(self) -> TransitionDirection;
}

impl TransitionDirectionExt for TransitionDirection {
    fn name(self) -> &'static str {
        match self {
            TransitionDirection::Left => "Left",
            TransitionDirection::Right => "Right",
            TransitionDirection::Up => "Up",
            TransitionDirection::Down => "Down",
        }
    }

    fn vector(self) -> Vec2 {
        match self {
            TransitionDirection::Left => Vec2::new(-1.0, 0.0),
            TransitionDirection::Right => Vec2::new(1.0, 0.0),
            TransitionDirection::Up => Vec2::new(0.0, -1.0),
            TransitionDirection::Down => Vec2::new(0.0, 1.0),
        }
    }

    fn opposite(self) -> TransitionDirection {
        match self {
            TransitionDirection::Left => TransitionDirection::Right,
            TransitionDirection::Right => TransitionDirection::Left,
            TransitionDirection::Up => TransitionDirection::Down,
            TransitionDirection::Down => TransitionDirection::Up,
        }
    }
}

/// Shown name of a `TransitionAlignment`.
pub trait TransitionAlignmentExt {
    /// Shown name.
    fn name(self) -> &'static str;
}

impl TransitionAlignmentExt for TransitionAlignment {
    fn name(self) -> &'static str {
        match self {
            TransitionAlignment::Center => "Center at Cut",
            TransitionAlignment::StartAtCut => "Start at Cut",
            TransitionAlignment::EndAtCut => "End at Cut",
            TransitionAlignment::Custom => "Custom Start",
        }
    }
}

/// Logic of `Transition`.
pub trait TransitionExt: Sized {
    /// A centered transition without style (all optional fields unset).
    fn new(id: Id, kind: TransitionKind, duration: Time, outgoing: Option<Id>, incoming: Option<Id>) -> Self;
    /// Own curve or the kind's default.
    fn effective_easing(&self) -> EasingCurve;
    /// Own direction or `Left`.
    fn effective_direction(&self) -> TransitionDirection;
    /// Own softness or 0.1.
    fn effective_softness(&self) -> f64;
    /// Own motion blur or the kind's default.
    fn effective_motion_blur(&self) -> f64;
    /// One side is missing (a fade at a clip edge).
    fn is_single_sided(&self) -> bool;
    /// Travels the other way (v89).
    fn is_reversed(&self) -> bool;
    /// The direction the render travels: the style's direction, turned around when reversed.
    fn render_direction(&self) -> TransitionDirection;
}

impl TransitionExt for Transition {
    fn new(id: Id, kind: TransitionKind, duration: Time, outgoing: Option<Id>, incoming: Option<Id>) -> Self {
        Transition {
            id,
            kind,
            duration,
            alignment: TransitionAlignment::Center,
            custom_before: Time::ZERO,
            outgoing,
            incoming,
            easing: None,
            direction: None,
            reversed: None,
            softness: None,
            motion_blur: None,
            stinger: None,
            params: None,
            color: None,
            border_width: None,
            border_color: None,
        }
    }

    fn effective_easing(&self) -> EasingCurve {
        self.easing.clone().unwrap_or_else(|| self.kind.default_easing())
    }

    fn effective_direction(&self) -> TransitionDirection {
        self.direction.unwrap_or(TransitionKind::DEFAULT_DIRECTION)
    }

    fn effective_softness(&self) -> f64 {
        self.softness.unwrap_or(TransitionKind::DEFAULT_SOFTNESS)
    }

    fn effective_motion_blur(&self) -> f64 {
        self.motion_blur.unwrap_or_else(|| self.kind.default_motion_blur())
    }

    fn is_single_sided(&self) -> bool {
        self.outgoing.is_none() || self.incoming.is_none()
    }

    fn is_reversed(&self) -> bool {
        self.reversed == Some(true)
    }

    fn render_direction(&self) -> TransitionDirection {
        let d = self.effective_direction();
        if self.is_reversed() { d.opposite() } else { d }
    }
}

/// Stinger helpers.
pub trait TransitionStingerExt {
    /// The stinger as a clip on the timeline for one resolved span (its id is the transition's: a layer, not a track clip).
    fn clip(&self, id: Id, span: sq_core_time::TimeRange, source_start: Time) -> sq_core_model::Clip;
}

impl TransitionStingerExt for TransitionStinger {
    fn clip(&self, id: Id, span: sq_core_time::TimeRange, source_start: Time) -> sq_core_model::Clip {
        let source = sq_core_time::TimeRange::new(source_start, span.duration);
        let mut c = sq_core_model::Clip::new(id, "Stinger", self.media, TrackKind::Video, source, span.start);
        if let Some(s) = self.scale {
            c.animation.scale = sq_core_model::AnimatedProperty::new(Vec2::new(s, s));
        }
        c
    }
}

/// Where a transition can be applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransitionPoint {
    /// Between two touching clips.
    Cut {
        /// Clip before the cut.
        outgoing: Id,
        /// Clip after the cut.
        incoming: Id,
    },
    /// The head of a clip (fade in).
    Head(Id),
    /// The tail of a clip (fade out).
    Tail(Id),
}

/// Eased incoming weight of a dissolve on frame `i` of `frames`.
pub(crate) fn dissolve_weight(easing: &EasingCurve, i: i64, frames: i64) -> f64 {
    easing.mix_weight(TransitionMix::video_weight(i, frames))
}
