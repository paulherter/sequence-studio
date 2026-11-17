// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Transition.swift, TransitionLayer.swift (saved types, moved down; resolution, rendering and edits: later tasks)

use crate::{Timeline, Track, TrackKind};
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{EasingCurve, Id, Time};
use std::collections::BTreeMap;

/// Every transition style, video and audio. The raw names are the stored identifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransitionKind {
    /// Cross dissolve.
    CrossDissolve,
    /// Dip to black.
    DipToBlack,
    /// Dip to white.
    DipToWhite,
    /// A cross dissolve of a few frames.
    QuickFade,
    /// Push.
    Push,
    /// Slide.
    Slide,
    /// Whip.
    Whip,
    /// Zoom in.
    ZoomIn,
    /// Zoom out.
    ZoomOut,
    /// Zoom pop.
    ZoomPop,
    /// Soft wipe.
    SoftWipe,
    /// RGB split and slice displacement.
    Glitch,
    /// Iris: the incoming picture opens as a growing ellipse.
    Iris,
    /// Light leak.
    LightLeak,
    /// Both pictures blur as they mix.
    BlurDissolve,
    /// Dip to a color of your choice.
    DipToColour,
    /// A short sharp white peak over a hard cut.
    Flash,
    /// Both pictures rotate.
    Spin,
    /// Dissolve under a radial smear.
    CrossZoom,
    /// Channel-change noise.
    StaticNoise,
    /// Dissolve with drifting glow.
    LightNoise,
    /// A and B alternate hard.
    StrobeCut,
    /// Both pictures add.
    AdditiveDissolve,
    /// Clock wipe.
    ClockWipe,
    /// Box iris.
    BoxIris,
    /// Diamond iris.
    DiamondIris,
    /// Cross iris.
    CrossIris,
    /// Barn doors.
    BarnDoors,
    /// Venetian blinds.
    VenetianBlinds,
    /// Radial wipe.
    RadialWipe,
    /// Wedge wipe.
    WedgeWipe,
    /// Pinwheel.
    Pinwheel,
    /// Checker wipe.
    CheckerWipe,
    /// Zig-zag blocks.
    ZigZagBlocks,
    /// Inset wipe.
    InsetWipe,
    /// Random blocks.
    RandomBlocks,
    /// Slice wipe.
    SliceWipe,
    /// Mosaic dissolve.
    MosaicDissolve,
    /// Flip 3D.
    Flip3D,
    /// Spring.
    Spring,
    /// Fall.
    Fall,
    /// Burn.
    Burn,
    /// Flare.
    Flare,
    /// Warp.
    Warp,
    /// Shake.
    Shake,
    /// A Library clip over a hard cut.
    Stinger,
    /// Element transition: move.
    Move,
    /// Element transition: zoom.
    Zoom,
    /// Element transition: pop.
    Pop,
    /// Audio: constant power.
    ConstantPower,
    /// Audio: constant gain.
    ConstantGain,
    /// Audio: exponential fade.
    ExponentialFade,
}

/// Where a motion transition moves the picture or sweeps its edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransitionDirection {
    /// Left.
    Left,
    /// Right.
    Right,
    /// Up.
    Up,
    /// Down.
    Down,
}

/// Where the transition lies around the cut.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransitionAlignment {
    /// Center at the cut.
    Center,
    /// Starts at the cut.
    StartAtCut,
    /// Ends at the cut.
    EndAtCut,
    /// Dragged to a custom position (`Transition::custom_before` frames lie before the cut).
    Custom,
}

/// A transition at a cut or clip edge, anchored to clip ids. What is stored is the user's intent; what plays is
/// resolved from the current clips.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transition {
    /// Identity.
    pub id: Id,
    /// Style.
    pub kind: TransitionKind,
    /// Requested duration, whole frames of the sequence. The resolved duration may be shorter (handles).
    pub duration: Time,
    /// Where it lies around the cut.
    pub alignment: TransitionAlignment,
    /// Used by `Custom`: the part before the cut, whole frames.
    pub custom_before: Time,
    /// Clip before the cut; `None` = fade in at the head of `incoming`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outgoing: Option<Id>,
    /// Clip after the cut; `None` = fade out at the tail of `outgoing`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub incoming: Option<Id>,
    /// Progress curve; `None` = the kind's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub easing: Option<EasingCurve>,
    /// Direction; `None` = the default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<TransitionDirection>,
    /// Travels the other way; `None` = not reversed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reversed: Option<bool>,
    /// Soft Wipe edge, 0...0.5 of the frame.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub softness: Option<f64>,
    /// Motion blur shutter in frames, 0...4.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_blur: Option<f64>,
    /// The clip a Stinger plays over the cut.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stinger: Option<TransitionStinger>,
    /// Parameters of an element transition, by motion-effect key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<BTreeMap<String, f64>>,
    /// Dip color as display-encoded RGB bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<Vec<u8>>,
    /// Border width along the moving edge, fraction of the frame (0...0.1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub border_width: Option<f64>,
    /// Border color as display-encoded RGB bytes; `None` = white.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub border_color: Option<Vec<u8>>,
}

fn half() -> f64 {
    0.5
}

/// Swift `TransitionStinger.clamp`: 0...1, anything not finite reads as 0.5.
fn clamp_cut_fraction(x: f64) -> f64 {
    if x.is_finite() { x.clamp(0.0, 1.0) } else { 0.5 }
}

fn cut_fraction<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    Ok(clamp_cut_fraction(f64::deserialize(d)?))
}

/// The Library clip of a Stinger transition. It plays from its first frame over the cut; at `cut_fraction` of its length
/// the picture underneath switches from the outgoing to the incoming clip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransitionStinger {
    /// The media item.
    pub media: Id,
    /// 0...1 of the stinger's length where the picture switches; clamped on read.
    #[serde(default = "half", deserialize_with = "cut_fraction")]
    pub cut_fraction: f64,
    /// Scale of the stinger picture; `None` = 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
}

/// The payload of a transition layer clip (`GeneratorRef` kind `transitionLayer`): a transition placed as its own clip
/// that transitions everything below its track.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransitionLayer {
    /// Style.
    pub kind: TransitionKind,
    /// The cut in the clip's own source time.
    pub cut: Time,
    /// Progress curve; `None` = the kind's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub easing: Option<EasingCurve>,
    /// Direction; `None` = the default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<TransitionDirection>,
    /// Travels the other way; `None` = not reversed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reversed: Option<bool>,
    /// Soft Wipe edge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub softness: Option<f64>,
    /// Motion blur shutter in frames.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_blur: Option<f64>,
    /// Dip color as display-encoded RGB bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<Vec<u8>>,
    /// Parameters as `Transition::params`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<BTreeMap<String, f64>>,
}

impl TransitionLayer {
    /// `GeneratorRef::kind` of a transition layer clip.
    pub const GENERATOR_KIND: &'static str = "transitionLayer";
    /// `GeneratorRef::payload_version` of the payload.
    pub const PAYLOAD_VERSION: i64 = 1;
}

impl TransitionKind {
    /// The track kind the transition belongs to: the audio fades are audio, everything else video.
    pub fn track_kind(self) -> TrackKind {
        match self {
            TransitionKind::ConstantPower | TransitionKind::ConstantGain | TransitionKind::ExponentialFade => {
                TrackKind::Audio
            }
            _ => TrackKind::Video,
        }
    }

    /// Element transitions (Move, Zoom, Pop) act on a clip's edge as a motion effect, not on the mix of two clips.
    pub fn is_element(self) -> bool {
        matches!(self, TransitionKind::Move | TransitionKind::Zoom | TransitionKind::Pop)
    }

    /// Plays a third picture over a hard cut instead of mixing A and B.
    pub fn is_stinger(self) -> bool {
        self == TransitionKind::Stinger
    }
}

/// More frames than any clip holds: "no limit" in the handle arithmetic.
const UNBOUNDED_FRAMES: i64 = 1 << 40;

impl Track {
    /// Frames before and after the cut that the handles allow `tr` right now (`Track.resolve` in Swift); `None` when the
    /// cut or clip is gone or nothing fits. `budgeted`: also respect the clip's other (earlier) transition.
    ///
    /// shortcut: only the two frame counts, not the full `ResolvedTransition` (span, easing, held frames); widen it when the
    /// transition evaluation is ported.
    fn resolved_portions(&self, tr: &Transition, fd: Time, budgeted: bool) -> Option<(i64, i64)> {
        if tr.kind.track_kind() != self.kind {
            return None;
        }
        let frames = |t: Time| t.frame_index(fd).max(0);
        let cap = |t: Option<Time>| t.map_or(UNBOUNDED_FRAMES, |t| frames(t).min(UNBOUNDED_FRAMES));
        let want = frames(tr.duration).max(1);
        let cb = frames(tr.custom_before);
        let clips = self.clips();
        let head_portion = |o: Id| {
            if !budgeted {
                return 0;
            }
            let earlier = self
                .transitions
                .iter()
                .find(|h| h.incoming == Some(o) && h.id != tr.id && h.kind.is_element() == tr.kind.is_element());
            earlier.and_then(|h| self.resolved_portions(h, fd, false)).map_or(0, |(_, after)| after)
        };
        let touching = |o: Id, i: Id| {
            let oi = clips.iter().position(|c| c.id == o)?;
            (oi + 1 < clips.len() && clips[oi + 1].id == i && clips[oi].timeline().end() == clips[oi + 1].start)
                .then_some(oi)
        };
        if tr.kind.is_stinger() {
            // The stinger never shows handle frames: A plays to the edit, B from it.
            let (Some(o), Some(i)) = (tr.outgoing, tr.incoming) else { return None };
            let oi = touching(o, i)?;
            let fraction = tr.stinger.as_ref().map_or(0.5, |s| s.cut_fraction);
            let cut = want.min((want as f64 * fraction).round() as i64);
            let b_max = (frames(clips[oi].duration()) - head_portion(o)).max(0);
            let b = cut.min(b_max);
            let a = (want - cut).min(frames(clips[oi + 1].duration()));
            return (b + a >= 1).then_some((b, a));
        }
        match (tr.outgoing, tr.incoming) {
            (Some(o), Some(i)) => {
                let oi = touching(o, i)?;
                let (out, inc) = (&clips[oi], &clips[oi + 1]);
                let out_span = (frames(out.duration()) - head_portion(o)).max(0);
                // Video without media beyond the cut on a side holds its edge frame there instead of refusing.
                let (inc_head, out_tail) = (cap(inc.head_handle()), cap(out.tail_room()));
                let hold_before = self.kind == TrackKind::Video && inc_head == 0;
                let hold_after = self.kind == TrackKind::Video && out_tail == 0;
                let b_max = (if hold_before { UNBOUNDED_FRAMES } else { inc_head }).min(out_span);
                let a_max = (if hold_after { UNBOUNDED_FRAMES } else { out_tail }).min(frames(inc.duration()));
                let max_frames = match tr.alignment {
                    TransitionAlignment::Center => (2 * b_max + 1).min(2 * a_max),
                    TransitionAlignment::StartAtCut => a_max,
                    TransitionAlignment::EndAtCut => b_max,
                    TransitionAlignment::Custom if cb <= b_max => cb + a_max,
                    TransitionAlignment::Custom => b_max,
                };
                let d = want.min(max_frames);
                if d < 1 {
                    return None;
                }
                let b = match tr.alignment {
                    TransitionAlignment::Center => d / 2,
                    TransitionAlignment::StartAtCut => 0,
                    TransitionAlignment::EndAtCut => d,
                    TransitionAlignment::Custom => cb.min(d),
                };
                Some((b, d - b))
            }
            (None, Some(i)) => {
                let c = clips.iter().find(|c| c.id == i)?;
                let d = want.min(frames(c.duration()));
                (d >= 1).then_some((0, d))
            }
            (Some(o), None) => {
                let c = clips.iter().find(|c| c.id == o)?;
                let d = want.min((frames(c.duration()) - head_portion(o)).max(0));
                (d >= 1).then_some((d, 0))
            }
            (None, None) => None,
        }
    }

    /// Drops transitions whose cut or clip no longer exists (or that nothing fits into any more).
    #[doc(hidden)]
    pub fn prune_transitions(&mut self, fd: Time) {
        if self.transitions.is_empty() {
            return;
        }
        let keep: Vec<Transition> =
            self.transitions.iter().filter(|t| self.resolved_portions(t, fd, true).is_some()).cloned().collect();
        if keep.len() != self.transitions.len() {
            self.transitions = keep;
        }
    }
}

impl Timeline {
    /// Drops transitions whose cut is gone or whose handles hold no frame any more. `Project.edit` calls this after every
    /// edit.
    pub fn prune_transitions(&mut self) {
        let fd = self.format.frame_duration;
        for t in &mut self.tracks {
            t.prune_transitions(fd);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    const ID: &str = "00000000-0000-0000-0000-000000000001";

    fn minimal() -> serde_json::Value {
        json!({"id": ID, "kind": "flip3D", "duration": {"value": 1, "timescale": 1}, "alignment": "startAtCut",
               "customBefore": {"value": 0, "timescale": 1}})
    }

    #[test]
    fn minimal_transition_round_trips_without_optional_keys() {
        assert_round_trip::<Transition>(minimal());
    }

    #[test]
    fn full_transition_round_trips() {
        let mut t = minimal();
        t["outgoing"] = json!(ID);
        t["incoming"] = json!("00000000-0000-0000-0000-000000000002");
        t["direction"] = json!("up");
        t["reversed"] = json!(true);
        t["softness"] = json!(0.25);
        t["motionBlur"] = json!(2.0);
        t["stinger"] = json!({"media": ID, "cutFraction": 0.75, "scale": 0.5});
        t["params"] = json!({"amount": 120.0});
        t["color"] = json!([255, 0, 10]);
        t["borderWidth"] = json!(0.05);
        t["borderColor"] = json!([1, 2, 3]);
        assert_round_trip::<Transition>(t);
    }

    #[test]
    fn every_kind_name_is_the_swift_case_name() {
        for name in ["crossDissolve", "dipToColour", "staticNoise", "flip3D", "zigZagBlocks", "exponentialFade"] {
            assert_round_trip::<TransitionKind>(json!(name));
        }
    }

    #[test]
    fn stinger_cut_fraction_defaults_and_clamps() {
        let read = |v: serde_json::Value| serde_json::from_value::<TransitionStinger>(v).unwrap().cut_fraction;
        assert_eq!(read(json!({"media": ID})), 0.5);
        assert_eq!(read(json!({"media": ID, "cutFraction": 7.0})), 1.0);
        assert_eq!(read(json!({"media": ID, "cutFraction": -3.0})), 0.0);
        assert_eq!(clamp_cut_fraction(f64::NAN), 0.5);
    }

    #[test]
    fn transition_layer_round_trips() {
        assert_round_trip::<TransitionLayer>(json!({"kind": "crossDissolve", "cut": {"value": 2, "timescale": 1}}));
        assert_round_trip::<TransitionLayer>(json!({"kind": "push", "cut": {"value": 2, "timescale": 1},
            "direction": "left", "reversed": false, "color": [1, 2, 3], "params": {"amount": 1.0}}));
    }

    fn tr(n: u128, kind: &str, out: Option<u128>, inc: Option<u128>, frames: i64, alignment: &str) -> Transition {
        let mut v = json!({"id": Id::from_u128(n), "kind": kind, "duration": {"value": frames, "timescale": 30},
            "alignment": alignment,
            "customBefore": {"value": 0, "timescale": 1}});
        v["outgoing"] = json!(out.map(Id::from_u128));
        v["incoming"] = json!(inc.map(Id::from_u128));
        serde_json::from_value(v).unwrap_or_else(|e| panic!("{e}"))
    }

    /// Two touching video clips, 30 frames each, with media on both sides (`media` frames long, source from `from`).
    fn cut_track(from: i64, media: i64, transitions: Vec<Transition>) -> Track {
        let clip = |n: u128, start: i64| {
            let mut c = crate::Clip::new(
                Id::from_u128(n),
                "c",
                Id::from_u128(50),
                TrackKind::Video,
                sq_core_time::TimeRange::new(Time::new(from, 30), Time::new(30, 30)),
                Time::new(start, 30),
            );
            c.media_duration = Some(Time::new(media, 30));
            c
        };
        let mut t = Track::new(Id::from_u128(9), TrackKind::Video);
        t.set_clips(vec![clip(1, 0), clip(2, 30)]);
        t.transitions = transitions;
        t
    }

    fn kept(t: &mut Track) -> Vec<Id> {
        t.prune_transitions(Time::new(1, 30));
        t.transitions.iter().map(|x| x.id).collect()
    }

    #[test]
    fn prune_keeps_a_transition_whose_handles_hold_frames() {
        let mut t = cut_track(30, 100, vec![tr(5, "crossDissolve", Some(1), Some(2), 10, "center")]);
        assert_eq!(t.resolved_portions(&t.transitions[0], Time::new(1, 30), true), Some((5, 5)));
        assert_eq!(kept(&mut t), [Id::from_u128(5)]);
    }

    #[test]
    fn prune_drops_transitions_without_a_cut_a_clip_or_a_fitting_handle() {
        let mut gone = cut_track(30, 100, vec![tr(5, "crossDissolve", Some(1), Some(77), 10, "center")]);
        assert_eq!(kept(&mut gone), []);
        let mut audio_kind = cut_track(30, 100, vec![tr(5, "constantPower", Some(1), Some(2), 10, "center")]);
        assert_eq!(kept(&mut audio_kind), [], "an audio fade does not belong on a video track");
        let mut nothing = cut_track(30, 100, vec![tr(5, "crossDissolve", None, None, 10, "center")]);
        assert_eq!(kept(&mut nothing), []);
        let mut gap = cut_track(30, 100, vec![tr(5, "crossDissolve", Some(1), Some(2), 10, "center")]);
        gap.set_clips(vec![gap.clips()[0].clone(), {
            let mut c = gap.clips()[1].clone();
            c.start = Time::new(40, 30);
            c
        }]);
        assert_eq!(kept(&mut gap), [], "the clips no longer touch");
    }

    #[test]
    fn video_holds_its_edge_frame_when_no_media_lies_beyond_the_cut() {
        // Source runs 0..30 of a 30-frame media: no tail beyond the outgoing clip, no head before the incoming one.
        let mut t = cut_track(0, 30, vec![tr(5, "crossDissolve", Some(1), Some(2), 10, "center")]);
        assert_eq!(t.resolved_portions(&t.transitions[0], Time::new(1, 30), true), Some((5, 5)));
        assert_eq!(kept(&mut t), [Id::from_u128(5)]);
    }

    #[test]
    fn a_clip_edge_transition_needs_its_clip_and_the_second_one_gets_what_is_left() {
        let fd = Time::new(1, 30);
        let mut t = cut_track(
            30,
            100,
            vec![
                tr(5, "crossDissolve", None, Some(2), 20, "center"),
                tr(6, "crossDissolve", Some(2), None, 20, "center"),
            ],
        );
        // The head transition of clip 2 takes 20 of its 30 frames, the tail one keeps the other 10.
        assert_eq!(t.resolved_portions(&t.transitions[0], fd, true), Some((0, 20)));
        assert_eq!(t.resolved_portions(&t.transitions[1], fd, true), Some((10, 0)));
        assert_eq!(t.resolved_portions(&t.transitions[1], fd, false), Some((20, 0)));
        assert_eq!(kept(&mut t).len(), 2);
        t.transitions[0].incoming = Some(Id::from_u128(99));
        assert_eq!(kept(&mut t), [Id::from_u128(6)]);
    }

    #[test]
    fn a_stinger_needs_a_touching_cut_and_splits_by_its_cut_fraction() {
        let t = cut_track(30, 100, vec![tr(5, "stinger", Some(1), Some(2), 10, "center")]);
        assert_eq!(t.resolved_portions(&t.transitions[0], Time::new(1, 30), true), Some((5, 5)));
        let mut lone = tr(6, "stinger", Some(1), None, 10, "center");
        lone.stinger = None;
        assert_eq!(t.resolved_portions(&lone, Time::new(1, 30), true), None);
    }

    #[test]
    fn the_timeline_prunes_every_track() {
        let mut tl = Timeline::new(
            Id::from_u128(1),
            "t",
            crate::SequenceFormat::new(Time::new(1, 30)),
            vec![cut_track(30, 100, vec![tr(5, "crossDissolve", Some(1), Some(77), 10, "center")])],
        );
        tl.prune_transitions();
        assert!(tl.tracks[0].transitions.is_empty());
    }
}
